import 'param_control.dart';

class _SeqRuntimeState {
  int stepIndex = 0;
  DateTime stepStartTime;
  // sliders: captured value a glide started from. toggles: whether this
  // step's snap has already been applied (so it only fires once per step).
  double? stepStartValue;
  bool valueApplied = false;
  int completedLoops = 0;

  _SeqRuntimeState(this.stepStartTime);
}

/// drives every enabled sequence's step-by-step script from a periodic tick -
/// a sequence is a "combine multiple automations" script: an ordered list of
/// set-value/wait steps, each potentially targeting a different parameter.
class SequenceEngine {
  final Map<String, _SeqRuntimeState> _runtime = {};

  void reset() => _runtime.clear();

  void tick(
    List<AutomationSequence> sequences,
    List<ParamControl> parameters,
    Map<String, Object> currentValues,
    void Function(ParamControl param, double value) onSlider,
    void Function(ParamControl param, bool value) onToggle,
  ) {
    final now = DateTime.now();
    final liveIds = <String>{};
    for (final seq in sequences) {
      if (!seq.enabled || seq.steps.isEmpty) continue;
      liveIds.add(seq.id);
      final state = _runtime.putIfAbsent(seq.id, () => _SeqRuntimeState(now));
      _tickSequence(seq, state, now, parameters, currentValues, onSlider, onToggle);
    }
    _runtime.removeWhere((id, _) => !liveIds.contains(id));
  }

  ParamControl? _find(List<ParamControl> parameters, String name) {
    for (final p in parameters) {
      if (p.name == name) return p;
    }
    return null;
  }

  void _tickSequence(
    AutomationSequence seq,
    _SeqRuntimeState state,
    DateTime now,
    List<ParamControl> parameters,
    Map<String, Object> currentValues,
    void Function(ParamControl, double) onSlider,
    void Function(ParamControl, bool) onToggle,
  ) {
    if (state.stepIndex >= seq.steps.length) {
      _advance(seq, state, now);
      return;
    }
    final step = seq.steps[state.stepIndex];
    final elapsed = now.difference(state.stepStartTime).inMicroseconds / 1e6;

    if (step.kind == SequenceStepKind.wait) {
      if (elapsed >= step.durationSeconds) _advance(seq, state, now);
      return;
    }

    final param = _find(parameters, step.paramName);
    if (param == null || param.type == ParamType.custom) {
      // target no longer exists (renamed/deleted) or isn't a settable type - skip.
      _advance(seq, state, now);
      return;
    }

    if (param.type == ParamType.slider) {
      state.stepStartValue ??= currentValues[param.name] as double? ?? param.defaultValue;
      final dur = step.durationSeconds <= 0 ? 0.001 : step.durationSeconds;
      final t = (elapsed / dur).clamp(0.0, 1.0);
      onSlider(param, state.stepStartValue! + (step.targetValue - state.stepStartValue!) * t);
      if (elapsed >= dur) _advance(seq, state, now);
    } else {
      // toggles have no meaningful mid-transition state - snap once, then
      // durationSeconds is just how long this step holds before advancing.
      if (!state.valueApplied) {
        onToggle(param, step.targetBool);
        state.valueApplied = true;
      }
      if (elapsed >= step.durationSeconds) _advance(seq, state, now);
    }
  }

  void _advance(AutomationSequence seq, _SeqRuntimeState state, DateTime now) {
    state.stepIndex += 1;
    state.stepStartTime = now;
    state.stepStartValue = null;
    state.valueApplied = false;
    if (state.stepIndex < seq.steps.length) return;

    if (seq.repeatMode == SequenceRepeatMode.once) {
      seq.enabled = false;
      return;
    }
    state.completedLoops += 1;
    if (seq.repeatCount > 0 && state.completedLoops >= seq.repeatCount) {
      seq.enabled = false;
      return;
    }
    state.stepIndex = 0;
  }
}
