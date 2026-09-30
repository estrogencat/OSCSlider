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

  // a stall longer than this (PC asleep, debugger paused) restarts the
  // current step's clock instead of fast-forwarding through everything missed.
  static const _maxCatchUp = Duration(seconds: 1);

  void reset() => _runtime.clear();

  /// index of the step [seq] is currently on, or null if it isn't running.
  int? currentStep(AutomationSequence seq) => _runtime[seq.id]?.stepIndex;

  void tick(
    List<AutomationSequence> sequences,
    List<ParamControl> parameters,
    Map<String, Object> currentValues,
    void Function(ParamControl param, double value) onSlider,
    void Function(ParamControl param, bool value) onToggle, {
    void Function(ParamControl param, String text)? onText,
  }) {
    final now = DateTime.now();
    final liveIds = <String>{};
    for (final seq in sequences) {
      if (!seq.enabled || seq.steps.isEmpty) continue;
      liveIds.add(seq.id);
      final state = _runtime.putIfAbsent(seq.id, () => _SeqRuntimeState(now));
      // instant steps (0s snaps, 0s waits) all run within the same tick
      // instead of one per tick, so "set A, set B" really is simultaneous.
      // bounded, so an all-instant looping sequence can't spin forever.
      for (var guard = 0; guard <= seq.steps.length && seq.enabled; guard++) {
        if (!_tickStep(seq, state, now, parameters, currentValues, onSlider, onToggle, onText)) break;
      }
    }
    _runtime.removeWhere((id, _) => !liveIds.contains(id));
  }

  ParamControl? _find(List<ParamControl> parameters, String name) {
    for (final p in parameters) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// runs the current step; true if it completed and the next one should
  /// run right away.
  bool _tickStep(
    AutomationSequence seq,
    _SeqRuntimeState state,
    DateTime now,
    List<ParamControl> parameters,
    Map<String, Object> currentValues,
    void Function(ParamControl, double) onSlider,
    void Function(ParamControl, bool) onToggle,
    void Function(ParamControl, String)? onText,
  ) {
    if (state.stepIndex >= seq.steps.length) {
      // steps were deleted out from under a running sequence.
      _advance(seq, state, now);
      return true;
    }
    final step = seq.steps[state.stepIndex];
    if (now.difference(state.stepStartTime) > _maxCatchUp + _durationOf(step.durationSeconds)) {
      state.stepStartTime = now;
    }
    final elapsed = now.difference(state.stepStartTime).inMicroseconds / 1e6;
    final duration = step.durationSeconds.isFinite && step.durationSeconds > 0 ? step.durationSeconds : 0.0;
    // the next step starts exactly when this one was due to end, not
    // whenever the tick happened to notice - no drift over long loops.
    DateTime dueEnd() => state.stepStartTime.add(_durationOf(duration));

    if (step.kind == SequenceStepKind.wait) {
      if (elapsed < duration) return false;
      _advance(seq, state, dueEnd());
      return true;
    }

    final param = _find(parameters, step.paramName);
    if (param == null || param.type == ParamType.custom) {
      // target no longer exists (renamed/deleted) or isn't a settable type - skip.
      _advance(seq, state, now);
      return true;
    }

    if (param.type == ParamType.button) {
      // held down for the step's duration (at least a brief tap, so VRChat
      // registers it), then released.
      if (!state.valueApplied) {
        onToggle(param, true);
        state.valueApplied = true;
      }
      if (elapsed < (duration < 0.05 ? 0.05 : duration)) return false;
      onToggle(param, false);
      _advance(seq, state, now);
      return true;
    } else if (param.type == ParamType.chatbox) {
      // sends the message once, then durationSeconds is how long to wait.
      if (!state.valueApplied) {
        onText?.call(param, step.text);
        state.valueApplied = true;
      }
      if (elapsed < duration) return false;
    } else if (param.type == ParamType.slider) {
      state.stepStartValue ??= sliderValueOf(currentValues, param);
      final t = duration <= 0 ? 1.0 : (elapsed / duration).clamp(0.0, 1.0);
      onSlider(param, state.stepStartValue! + (step.targetValue - state.stepStartValue!) * t);
      if (elapsed < duration) return false;
    } else {
      // toggles have no meaningful mid-transition state - snap once, then
      // durationSeconds is just how long this step holds before advancing.
      if (!state.valueApplied) {
        onToggle(param, step.targetBool);
        state.valueApplied = true;
      }
      if (elapsed < duration) return false;
    }
    _advance(seq, state, dueEnd());
    return true;
  }

  static Duration _durationOf(double seconds) =>
      Duration(microseconds: (seconds.isFinite && seconds > 0 ? seconds * 1e6 : 0).round());

  void _advance(AutomationSequence seq, _SeqRuntimeState state, DateTime nextStart) {
    state.stepIndex += 1;
    state.stepStartTime = nextStart;
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
