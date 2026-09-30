import 'package:flutter_test/flutter_test.dart';
import 'package:osc_slider/automation_engine.dart';
import 'package:osc_slider/live_param_listener.dart';
import 'package:osc_slider/oscquery_client.dart';
import 'package:osc_slider/param_control.dart';
import 'package:osc_slider/schedule_engine.dart';
import 'package:osc_slider/sequence_engine.dart';
import 'package:osc_slider/trigger_engine.dart';

void main() {
  final slider = ParamControl(name: 'S', label: 'S', type: ParamType.slider);
  final toggleA = ParamControl(name: 'A', label: 'A', type: ParamType.toggle);
  final toggleB = ParamControl(name: 'B', label: 'B', type: ParamType.toggle);

  group('SequenceEngine', () {
    test('instant steps all run in the same tick', () {
      final seq = AutomationSequence(id: '1', name: 'x', enabled: true, steps: [
        SequenceStep(kind: SequenceStepKind.setValue, paramName: 'A', targetBool: true, durationSeconds: 0),
        SequenceStep(kind: SequenceStepKind.setValue, paramName: 'B', targetBool: true, durationSeconds: 0),
        SequenceStep(kind: SequenceStepKind.setValue, paramName: 'S', targetValue: 0.7, durationSeconds: 0),
      ]);
      final sent = <String>[];
      SequenceEngine().tick([seq], [slider, toggleA, toggleB], {}, (p, v) => sent.add('${p.name}=$v'),
          (p, v) => sent.add('${p.name}=$v'));
      expect(sent, ['A=true', 'B=true', 'S=0.7']);
      // a "once" sequence switches itself off when it finishes.
      expect(seq.enabled, false);
    });

    test('an all-instant looping sequence is bounded per tick', () {
      final seq = AutomationSequence(
        id: '1',
        name: 'x',
        enabled: true,
        repeatMode: SequenceRepeatMode.loop,
        steps: [SequenceStep(kind: SequenceStepKind.wait, durationSeconds: 0)],
      );
      final engine = SequenceEngine();
      engine.tick([seq], [], {}, (_, _) {}, (_, _) {});
      expect(seq.enabled, true);
    });

    test('a timed step holds the sequence until it elapses', () {
      final seq = AutomationSequence(id: '1', name: 'x', enabled: true, steps: [
        SequenceStep(kind: SequenceStepKind.setValue, paramName: 'A', targetBool: true, durationSeconds: 10),
        SequenceStep(kind: SequenceStepKind.setValue, paramName: 'B', targetBool: true, durationSeconds: 0),
      ]);
      final engine = SequenceEngine();
      final sent = <String>[];
      engine.tick([seq], [toggleA, toggleB], {}, (_, _) {}, (p, v) => sent.add(p.name));
      engine.tick([seq], [toggleA, toggleB], {}, (_, _) {}, (p, v) => sent.add(p.name));
      expect(sent, ['A']);
      expect(engine.currentStep(seq), 0);
    });
  });

  group('ScheduleEngine', () {
    test('a pulse firing again before its revert still reverts to the original value', () async {
      final p = ParamControl(name: 'T', label: 'T', type: ParamType.toggle)
        ..schedule = ParamSchedule(
          enabled: true,
          kind: ScheduleKind.countdown,
          countdownSeconds: 0.01,
          targetBool: true,
          revertAfterSeconds: 0.2,
        );
      final values = <String, Object>{'T': false};
      final engine = ScheduleEngine();
      void onToggle(ParamControl param, bool v) => values[param.name] = v;
      engine.tick([p], DateTime.now(), values, (_, _) {}, onToggle);
      await Future.delayed(const Duration(milliseconds: 30));
      engine.tick([p], DateTime.now(), values, (_, _) {}, onToggle);
      expect(values['T'], true);
      // fire again while the first revert is pending.
      p.schedule!.enabled = true;
      await Future.delayed(const Duration(milliseconds: 30));
      engine.tick([p], DateTime.now(), values, (_, _) {}, onToggle);
      engine.tick([p], DateTime.now(), values, (_, _) {}, onToggle);
      await Future.delayed(const Duration(milliseconds: 250));
      engine.tick([p], DateTime.now(), values, (_, _) {}, onToggle);
      expect(values['T'], false);
    });
  });

  group('AutomationEngine', () {
    test('a sequence-scoped ramp holds when finished instead of pausing itself', () async {
      final auto = Automation(enabled: true, rampRepeat: RampRepeat.once, rampDurationSeconds: 0.01, easing: EasingKind.linear);
      final engine = AutomationEngine();
      final sent = <double>[];
      await Future.delayed(Duration.zero);
      final target = AutomationTarget(key: 'seq:1:S', param: slider, automation: auto);
      engine.tick([target], (_, v) => sent.add(v), (_, _) {});
      await Future.delayed(const Duration(milliseconds: 30));
      engine.tick([target], (_, v) => sent.add(v), (_, _) {});
      final count = sent.length;
      engine.tick([target], (_, v) => sent.add(v), (_, _) {});
      expect(sent.last, 1.0);
      expect(sent.length, count, reason: 'no more sends once finished');
      expect(auto.enabled, true, reason: 'the user\'s pause switch is left alone');
    });
  });

  group('TriggerEngine', () {
    test('survives a watched parameter whose live value has the wrong type', () {
      final watched = ParamControl(name: 'W', label: 'W', type: ParamType.toggle);
      final target = ParamControl(name: 'X', label: 'X', type: ParamType.slider)
        ..automation = Automation(trigger: ParamTrigger(enabled: true, watchedParamName: 'W', toggleCondition: ToggleTriggerCondition.whileOn));
      final engine = TriggerEngine();
      // a stale double left over from when W was a slider.
      engine.tick([watched, target], [], {'W': 0.5});
      expect(target.automation!.enabled, false);
      engine.tick([watched, target], [], {'W': true});
      expect(target.automation!.enabled, true);
    });
  });

  group('LiveParamTracker', () {
    test('a short burst stays highlighted; sustained chatter is filtered', () {
      final tracker = LiveParamTracker(const [], noiseThreshold: 10);
      final start = DateTime(2026, 1, 1, 12);
      // one physbone wiggle: 20 updates in half a second.
      for (var i = 0; i < 20; i++) {
        tracker.handleChange('Tail_Angle', DiscoveredKind.float, at: start.add(Duration(milliseconds: i * 25)));
      }
      expect(tracker.lastChanged.containsKey('Tail_Angle'), true);
      // Voice-style chatter: 15/sec for 4 seconds.
      for (var i = 0; i < 60; i++) {
        tracker.handleChange('Voice', DiscoveredKind.float, at: start.add(Duration(milliseconds: i * 66)));
      }
      expect(tracker.isNoisy('Voice'), true);
      expect(tracker.lastChanged.containsKey('Voice'), false);
      expect(tracker.isNoisy('Tail_Angle'), false);
    });
  });
}
