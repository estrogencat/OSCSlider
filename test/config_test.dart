import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/config_store.dart';
import 'package:osc_slider/param_control.dart';

void main() {
  group('AppConfig parsing', () {
    test('round trips', () {
      final config = AppConfig(
        host: '127.0.0.1',
        port: 9000,
        parameters: [
          ParamControl(name: 'A', label: 'A', type: ParamType.slider, automation: Automation(enabled: true)),
        ],
      );
      final again = AppConfig.fromJson(jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);
      expect(again.parameters.single.automation!.enabled, true);
      expect(again.syncFromVrchat, true);
    });

    test('an all-snapshot profile list still gets a usable active profile', () {
      final config = AppConfig.fromJson({
        'profiles': [
          {'id': 's', 'name': 'Snap', 'isSnapshot': true, 'parameters': []},
        ],
        'activeProfileId': 's',
      });
      expect(config.activeProfile.isSnapshot, false);
      expect(config.profiles.length, 2);
    });

    test('missing ids, duplicate ids and bad ports are repaired', () {
      final config = AppConfig.fromJson({
        'port': 99999,
        'host': '  ',
        'profiles': [
          {
            'name': 'One',
            'parameters': [
              {'name': 'X'},
              {'label': 'nameless'},
            ],
          },
          {'id': 'dup', 'name': 'Two', 'parameters': []},
          {'id': 'dup', 'name': 'Three', 'parameters': []},
        ],
      });
      expect(config.port, 9000);
      expect(config.host, '127.0.0.1');
      expect(config.profiles.map((p) => p.id).toSet().length, 3);
      expect(config.profiles.first.parameters.map((p) => p.name), ['X']);
    });

    test('bad curve points fall back instead of throwing', () {
      final auto = Automation.fromJson({
        'customCurvePoints': [
          [0, 0],
          'junk',
          [1],
        ],
      });
      expect(auto.customCurvePoints.length, 2);
    });
  });

  group('renaming', () {
    test('follows a rename through sequences and triggers', () {
      final watcher = ParamControl(name: 'W', label: 'W', type: ParamType.slider)
        ..automation = Automation(trigger: ParamTrigger(watchedParamName: 'Old'));
      final seq = AutomationSequence(
        id: '1',
        name: 's',
        steps: [SequenceStep(kind: SequenceStepKind.setValue, paramName: 'Old')],
        trigger: ParamTrigger(watchedParamName: 'Old'),
        paramAutomations: {'Old': Automation()},
      );
      final config = AppConfig(host: 'h', port: 1, parameters: [watcher], automationMasterSwitchParams: ['Old']);
      config.sequences.add(seq);
      config.renameParamReferences('Old', 'New');
      expect(seq.steps.single.paramName, 'New');
      expect(seq.trigger!.watchedParamName, 'New');
      expect(seq.paramAutomations.keys, ['New']);
      expect(watcher.automation!.trigger!.watchedParamName, 'New');
      expect(config.automationMasterSwitchParams, ['New']);
    });
  });

  group('helpers', () {
    test('parameter names', () {
      expect(normalizeParamName(' /avatar/parameters/Ears '), 'Ears');
      expect(normalizeParamName('/custom/address'), '/custom/address');
      expect(validateParamName(''), isNotNull);
      expect(validateParamName('Bad#Name'), isNotNull);
      expect(validateParamName('trailing/'), isNotNull);
      expect(validateParamName('VF67_Mayu/Purr'), isNull);
      expect(validateParamName('しっぽ'), isNull);
    });

    test('values of the wrong type fall back to defaults', () {
      final s = ParamControl(name: 'S', label: 'S', type: ParamType.slider, defaultValue: 0.3);
      final t = ParamControl(name: 'T', label: 'T', type: ParamType.toggle, defaultBool: true);
      expect(sliderValueOf({'S': true}, s), 0.3);
      expect(sliderValueOf({'S': double.nan}, s), 0.3);
      expect(toggleValueOf({'T': 0.5}, t), true);
    });

    test('safeRange never hands Slider min >= max', () {
      expect((ParamControl(name: 'a', label: 'a', type: ParamType.slider, min: 1, max: 1)).safeRange, (1.0, 2.0));
      expect((ParamControl(name: 'a', label: 'a', type: ParamType.slider, min: 5, max: 0)).safeRange, (0.0, 5.0));
    });

    test('int parameters display as whole numbers', () {
      final p = ParamControl(name: 'i', label: 'i', type: ParamType.slider, numericKind: NumericKind.int);
      expect(formatParamValue(p, 3.6, false), '4');
    });
  });

  group('ConfigStore', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('oscslider_test');
      ConfigStore.directoryOverride = dir.path;
    });
    tearDown(() async {
      await ConfigStore.flush();
      ConfigStore.directoryOverride = null;
      await dir.delete(recursive: true);
    });

    File file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

    test('first launch writes a default config', () async {
      final config = await ConfigStore.load();
      expect(config.parameters.map((p) => p.name), ['ExampleRadial', 'ExampleToggle']);
      expect(await file('config.json.bak').exists(), true);
    });

    test('a burst of saves lands as valid JSON with the latest state', () async {
      final config = await ConfigStore.load();
      final futures = <Future<void>>[];
      for (var i = 0; i < 50; i++) {
        config.host = 'host$i';
        futures.add(ConfigStore.save(config));
      }
      await Future.wait(futures);
      final json = jsonDecode(await file('config.json').readAsString()) as Map<String, dynamic>;
      expect(json['host'], 'host49');
      expect(await file('config.json.tmp').exists(), false);
    });

    test('a byte order mark is tolerated', () async {
      await file('config.json').writeAsString('\uFEFF{"host":"10.0.0.2","port":9000}');
      final config = await ConfigStore.load();
      expect(config.host, '10.0.0.2');
    });

    test('a broken config offers the last good one back', () async {
      await ConfigStore.load();
      await file('config.json').writeAsString('{"host": "trunc');
      try {
        await ConfigStore.load();
        fail('should not load');
      } on ConfigLoadException catch (e) {
        expect(e.backupAvailable, true);
      }
      final restored = await ConfigStore.restoreBackup();
      expect(restored.parameters, isNotEmpty);
      final broken = dir.listSync().whereType<File>().where((f) => f.path.contains('config.broken-'));
      expect(broken, hasLength(1), reason: 'the broken file is kept, not deleted');
    });

    test('an empty file is an error, not a crash', () async {
      await file('config.json').writeAsString('');
      expect(ConfigStore.load(), throwsA(isA<ConfigLoadException>()));
    });
  });

  test('only brand new configs start the tour', () async {
    expect(AppConfig.fromJson({'host': '127.0.0.1', 'port': 9000}).tutorialSeen, true);
    final dir = await Directory.systemTemp.createTemp('oscslider_tour');
    ConfigStore.directoryOverride = dir.path;
    try {
      expect((await ConfigStore.load()).tutorialSeen, false);
    } finally {
      ConfigStore.directoryOverride = null;
      await dir.delete(recursive: true);
    }
  });

  test('keep screen on survives a save', () {
    final config = AppConfig(host: '127.0.0.1', port: 9000)..keepScreenOn = true;
    expect(AppConfig.fromJson(jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>).keepScreenOn, true);
    expect(AppConfig.fromJson({}).keepScreenOn, false);
  });
}
