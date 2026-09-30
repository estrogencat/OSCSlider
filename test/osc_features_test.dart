import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/config_store.dart';
import 'package:osc_slider/live_controller.dart';
import 'package:osc_slider/osc_client.dart';
import 'package:osc_slider/osc_listener.dart';
import 'package:osc_slider/param_control.dart';
import 'package:osc_slider/schedule_engine.dart';
import 'package:osc_slider/sequence_engine.dart';

/// a UDP socket standing in for VRChat, collecting what it receives.
class _Receiver {
  final RawDatagramSocket socket;
  final List<OscMessage> got = [];
  _Receiver(this.socket) {
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg != null) got.addAll(parseOscPacket(dg.data));
    });
  }
  static Future<_Receiver> bind() async => _Receiver(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));
  int get port => socket.port;

  Future<void> waitFor(int count) async {
    for (var i = 0; i < 100 && got.length < count; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }
}

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('oscslider_features');
    ConfigStore.directoryOverride = dir.path;
  });
  tearDownAll(() async {
    await ConfigStore.flush();
    ConfigStore.directoryOverride = null;
    await dir.delete(recursive: true);
  });

  group('new parameter types', () {
    late _Receiver vrchat;
    late LiveController live;
    final jump = ParamControl(
      name: '/input/Jump',
      label: 'Jump',
      type: ParamType.button,
      buttonMode: ButtonMode.tap,
      buttonSendsInt: true,
      tapMillis: 30,
    );
    final ears = ParamControl(name: 'Ears', label: 'Ears', type: ParamType.button, buttonSendsInt: false);
    final chat = ParamControl(name: '/chatbox/input', label: 'Chat', type: ParamType.chatbox, customValueText: '');
    final move = ParamControl(
      name: '/input/Vertical',
      label: 'Move',
      type: ParamType.slider,
      min: -1,
      max: 1,
      springBack: true,
    );

    setUp(() async {
      vrchat = await _Receiver.bind();
      live = LiveController(AppConfig(
        host: '127.0.0.1',
        port: vrchat.port,
        parameters: [jump, ears, chat, move],
      )..syncFromVrchat = false);
    });
    tearDown(() {
      live.dispose();
      vrchat.socket.close();
    });

    test('a tap button sends 1 then 0 as ints', () async {
      live.tapButton(jump);
      await vrchat.waitFor(2);
      expect(vrchat.got.map((m) => '${m.address}=${m.args.single}'), ['/input/Jump=1', '/input/Jump=0']);
    });

    test('a hold button follows press and release, as bools when asked', () async {
      live.pressButton(ears, true);
      live.pressButton(ears, true); // a repeat while held sends nothing new
      live.pressButton(ears, false);
      await vrchat.waitFor(2);
      expect(vrchat.got.map((m) => m.args.single), [true, false]);
    });

    test('chatbox sends text with its two flags and clears the draft', () async {
      live.customText['/chatbox/input']!.text = 'hello ✨';
      live.chatboxTyping(chat, true);
      expect(await live.sendChatbox(chat), true);
      await vrchat.waitFor(2);
      expect(vrchat.got.first.address, '/chatbox/typing');
      expect(vrchat.got.first.args, [true]);
      final msg = vrchat.got.last;
      expect(msg.address, '/chatbox/input');
      expect(msg.args, ['hello ✨', true, true]);
      expect(live.customText['/chatbox/input']!.text, isEmpty);
      expect(await live.sendChatbox(chat), false, reason: 'nothing left to send');
    });

    test('a spring-back slider returns to its default when released', () async {
      live.setSlider(move, 1);
      live.releaseSlider(move);
      await vrchat.waitFor(2);
      expect(vrchat.got.map((m) => m.args.single), [1.0, 0.0]);
      expect(live.sliderValue(move), 0);
    });
  });

  group('sequence steps for the new types', () {
    test('a button step presses, holds and releases; a chatbox step sends once', () async {
      final button = ParamControl(name: 'B', label: 'B', type: ParamType.button);
      final chat = ParamControl(name: '/chatbox/input', label: 'C', type: ParamType.chatbox);
      final seq = AutomationSequence(id: 's', name: 's', enabled: true, steps: [
        SequenceStep(kind: SequenceStepKind.setValue, paramName: '/chatbox/input', text: 'hi', durationSeconds: 0),
        SequenceStep(kind: SequenceStepKind.setValue, paramName: 'B', durationSeconds: 0),
      ]);
      final events = <String>[];
      final engine = SequenceEngine();
      void tick() => engine.tick([seq], [button, chat], {}, (_, _) {}, (p, v) => events.add('${p.name}=$v'),
          onText: (p, t) => events.add('${p.name}:$t'));
      tick();
      expect(events, ['/chatbox/input:hi', 'B=true']);
      await Future.delayed(const Duration(milliseconds: 60));
      tick();
      expect(events.last, 'B=false');
      expect(seq.enabled, false);
    });
  });

  group('time-of-day schedules on chosen weekdays', () {
    test('only fire on a selected day', () {
      final now = DateTime.now();
      ParamControl make(List<int> days) => ParamControl(name: 'T', label: 'T', type: ParamType.toggle)
        ..schedule = ParamSchedule(
          enabled: true,
          timeOfDayHour: now.hour,
          timeOfDayMinute: now.minute,
          daysOfWeek: days,
          targetBool: true,
        );
      final otherDay = now.weekday % 7 + 1;
      var fired = false;
      ScheduleEngine().tick([make([otherDay])], now, {}, (_, _) {}, (_, _) => fired = true);
      expect(fired, false);
      ScheduleEngine().tick([make([now.weekday])], now, {}, (_, _) {}, (_, _) => fired = true);
      expect(fired, true);
    });
  });

  group('forwarding', () {
    test('outgoing sends are mirrored to extra targets', () async {
      final vrchat = await _Receiver.bind();
      final mirror = await _Receiver.bind();
      final client = OscClient(host: '127.0.0.1', port: vrchat.port);
      client.mirror.targets = [('127.0.0.1', mirror.port)];
      await client.sendFloat('/avatar/parameters/Hue', 0.5);
      await vrchat.waitFor(1);
      await mirror.waitFor(1);
      expect(vrchat.got.single.args.single, 0.5);
      expect(mirror.got.single.address, '/avatar/parameters/Hue');
      client.dispose();
      vrchat.socket.close();
      mirror.socket.close();
    });
  });

  group('config', () {
    test('new fields survive a save/load round trip', () {
      final config = AppConfig(host: 'h', port: 9000, parameters: [
        ParamControl(name: '/input/Jump', label: 'J', type: ParamType.button, buttonMode: ButtonMode.tap, tapMillis: 250),
        ParamControl(name: '/chatbox/input', label: 'C', type: ParamType.chatbox, chatboxNotify: false),
        ParamControl(name: 'S', label: 'S', type: ParamType.slider, step: 0.25, springBack: true)
          ..schedule = ParamSchedule(daysOfWeek: [DateTime.saturday, DateTime.sunday]),
      ])
        ..autoProfileCreate = false
        ..listenPort = 9005
        ..forwardTargets.add(ForwardTarget(host: '192.168.1.5', port: 8000, direction: ForwardDirection.both));
      // through real JSON text, like config.json.
      final again = AppConfig.fromJson(jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);
      final [button, chat, slider] = again.parameters;
      expect(button.type, ParamType.button);
      expect(button.buttonMode, ButtonMode.tap);
      expect(button.tapMillis, 250);
      expect(chat.type, ParamType.chatbox);
      expect(chat.chatboxNotify, false);
      expect(slider.step, 0.25);
      expect(slider.springBack, true);
      expect(slider.schedule!.daysOfWeek, [6, 7]);
      expect(again.autoProfileCreate, false);
      expect(again.listenPort, 9005);
      expect(effectiveListenPort(again), 9005);
      expect(again.forwardTargets.single.direction, ForwardDirection.both);
    });
  });
}

