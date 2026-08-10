import 'param_control.dart';

class _TriggerRuntimeState {
  // previous tick's watched value, for edge-detecting pulse conditions
  // (gate conditions just compare against the current value every tick).
  Object? previousValue;
  // how many pulses have landed since the last time this trigger actually
  // fired - only touched by the "fires once" conditions.
  int hitCount = 0;
}

/// evaluates each Automation/AutomationSequence's trigger against its watched
/// parameter's live value, and starts (or, for gate conditions, continuously
/// holds) the target - independent of the engines that actually drive it.
class TriggerEngine {
  final Map<String, _TriggerRuntimeState> _runtime = {};

  void reset() => _runtime.clear();

  void tick(
    List<ParamControl> parameters,
    List<AutomationSequence> sequences,
    Map<String, Object> currentValues,
  ) {
    final liveKeys = <String>{};
    for (final param in parameters) {
      final auto = param.automation;
      final trig = auto?.trigger;
      if (auto == null || trig == null || !trig.enabled) continue;
      final key = 'auto:${param.name}';
      liveKeys.add(key);
      _evaluate(key, trig, parameters, currentValues, (v) => auto.enabled = v);
    }
    for (final seq in sequences) {
      final trig = seq.trigger;
      if (trig == null || !trig.enabled) continue;
      final key = 'seq:${seq.id}';
      liveKeys.add(key);
      _evaluate(key, trig, parameters, currentValues, (v) => seq.enabled = v);
    }
    _runtime.removeWhere((k, _) => !liveKeys.contains(k));
  }

  ParamControl? _find(List<ParamControl> parameters, String name) {
    for (final p in parameters) {
      if (p.name == name) return p;
    }
    return null;
  }

  // counts one pulse toward trig.requiredHits, only actually firing (and
  // resetting the count) once enough pulses have landed - so "requires 3
  // hits" fires on the 3rd, 6th, 9th... pulse rather than every single one.
  void _pulse(_TriggerRuntimeState state, ParamTrigger trig, void Function(bool) setEnabled) {
    state.hitCount += 1;
    if (state.hitCount < trig.requiredHits) return;
    state.hitCount = 0;
    setEnabled(true);
  }

  void _evaluate(
    String key,
    ParamTrigger trig,
    List<ParamControl> parameters,
    Map<String, Object> currentValues,
    void Function(bool) setEnabled,
  ) {
    final watched = _find(parameters, trig.watchedParamName);
    if (watched == null) return;
    final state = _runtime.putIfAbsent(key, () => _TriggerRuntimeState());

    if (watched.type == ParamType.toggle) {
      final value = currentValues[watched.name] as bool? ?? watched.defaultBool;
      final previous = state.previousValue as bool?;
      state.previousValue = value;
      switch (trig.toggleCondition) {
        case ToggleTriggerCondition.whileOn:
          setEnabled(value);
        case ToggleTriggerCondition.whileOff:
          setEnabled(!value);
        case ToggleTriggerCondition.turnsOn:
          if (previous == false && value) _pulse(state, trig, setEnabled);
        case ToggleTriggerCondition.turnsOff:
          if (previous == true && !value) _pulse(state, trig, setEnabled);
      }
    } else if (watched.type == ParamType.slider) {
      final value = currentValues[watched.name] as double? ?? watched.defaultValue;
      final previous = state.previousValue as double?;
      state.previousValue = value;
      final isAbove = value > trig.threshold;
      final isBelow = value < trig.threshold;
      switch (trig.rangeCondition) {
        case RangeTriggerCondition.above:
          setEnabled(isAbove);
        case RangeTriggerCondition.below:
          setEnabled(isBelow);
        case RangeTriggerCondition.crossesAbove:
          if (previous != null && previous <= trig.threshold && isAbove) _pulse(state, trig, setEnabled);
        case RangeTriggerCondition.crossesBelow:
          if (previous != null && previous >= trig.threshold && isBelow) _pulse(state, trig, setEnabled);
        case RangeTriggerCondition.inRange:
          setEnabled(value >= trig.rangeMin && value <= trig.rangeMax);
        case RangeTriggerCondition.outOfRange:
          setEnabled(value < trig.rangeMin || value > trig.rangeMax);
      }
    }
  }
}
