import 'dart:math';

import 'param_control.dart';

class _RuntimeState {
  final DateTime startTime;

  // random mode
  double? currentTarget;
  double? previousValue;
  DateTime? lastPick;
  double? intervalSeconds;

  // blink/random toggle mode
  bool? currentBoolState;

  // ramp with a per-repeat speed change - tracked incrementally (rather than
  // purely analytically like the rest of ramp) since each repeat's duration
  // depends on how many repeats came before it.
  double? cycleDuration;
  DateTime? cycleStart;
  int cycleIndex = 0;

  _RuntimeState(this.startTime);
}

/// drives every parameter's automation from a single periodic tick, computing
/// each one analytically from elapsed wall-clock time rather than stepping
/// state incrementally - so it's not sensitive to the exact tick rate.
class AutomationEngine {
  final _random = Random();
  final Map<String, _RuntimeState> _runtime = {};

  // drops all in-flight timing state - call this when the active parameter
  // set changes identity (e.g. switching profiles) so a same-named parameter
  // in the new set starts its automation fresh instead of picking up
  // wherever the old one's clock happened to be.
  void reset() => _runtime.clear();

  void tick(
    List<ParamControl> parameters,
    void Function(ParamControl param, double value) onSlider,
    void Function(ParamControl param, bool value) onToggle,
  ) {
    final now = DateTime.now();
    final liveNames = <String>{};

    for (final param in parameters) {
      final auto = param.automation;
      if (auto == null || !auto.enabled) continue;
      liveNames.add(param.name);
      final state = _runtime.putIfAbsent(param.name, () => _RuntimeState(now));

      if (param.type == ParamType.slider) {
        switch (auto.kind) {
          case AutomationKind.ramp:
            _tickRamp(param, auto, state, now, onSlider);
          case AutomationKind.random:
            _tickRandomSlider(param, auto, state, now, onSlider);
          case AutomationKind.blink:
            break; // blink doesn't apply to sliders
        }
      } else if (param.type == ParamType.toggle) {
        switch (auto.kind) {
          case AutomationKind.blink:
            _tickBlink(auto, state, now, (v) => onToggle(param, v));
          case AutomationKind.random:
            _tickRandomToggle(auto, state, now, (v) => onToggle(param, v));
          case AutomationKind.ramp:
            break; // ramp doesn't apply to toggles
        }
      }
    }

    // drop state for anything no longer live (disabled, deleted, or on a
    // profile we've switched away from) so re-enabling starts fresh.
    _runtime.removeWhere((key, _) => !liveNames.contains(key));
  }

  void _tickRamp(
    ParamControl param,
    Automation auto,
    _RuntimeState state,
    DateTime now,
    void Function(ParamControl, double) onSlider,
  ) {
    final duration = auto.rampDurationSeconds <= 0 ? 0.001 : auto.rampDurationSeconds;
    final count = auto.rampRepeatCount;
    double progress;
    var finished = false;

    final changesSpeed = auto.rampRepeat != RampRepeat.once && auto.rampRepeatSpeedFactor != 1.0;
    if (auto.rampRepeat == RampRepeat.once) {
      final elapsed = now.difference(state.startTime).inMicroseconds / 1e6;
      progress = (elapsed / duration).clamp(0.0, 1.0);
      finished = elapsed >= duration;
    } else if (changesSpeed) {
      (progress: progress, finished: finished) =
          _tickRampWithSpeedChange(auto, state, now, duration, count);
    } else {
      final elapsed = now.difference(state.startTime).inMicroseconds / 1e6;
      switch (auto.rampRepeat) {
        case RampRepeat.loop:
          // a repeat is one sweep from "from" to "to" - once the count is
          // hit, freeze at the end value rather than snapping back to start.
          if (count > 0 && elapsed >= duration * count) {
            progress = 1.0;
            finished = true;
          } else {
            progress = (elapsed % duration) / duration;
          }
        case RampRepeat.pingPong:
          // a repeat is one full round trip (there and back), which already
          // ends back at the start - so no special-casing needed at the
          // finish boundary the way loop needs.
          final period = duration * 2;
          if (count > 0 && elapsed >= period * count) {
            progress = 0.0;
            finished = true;
          } else {
            final cycle = elapsed % period;
            progress = cycle <= duration ? (cycle / duration) : (2 - cycle / duration);
          }
        case RampRepeat.once:
          progress = 0; // unreachable - handled above
      }
    }

    final eased = _ease(auto.easing, progress.clamp(0.0, 1.0), auto);
    onSlider(param, auto.rampFrom + (auto.rampTo - auto.rampFrom) * eased);

    if (finished) auto.enabled = false;
  }

  // each repeat's duration is scaled by rampRepeatSpeedFactor from the last
  // (floored at 0.05s so it can't shrink to a standstill) - tracked
  // incrementally in `state` since that scaling has no closed form from
  // elapsed time alone the way the fixed-speed cases above do.
  ({double progress, bool finished}) _tickRampWithSpeedChange(
    Automation auto,
    _RuntimeState state,
    DateTime now,
    double baseDuration,
    int count,
  ) {
    state.cycleDuration ??= baseDuration;
    state.cycleStart ??= state.startTime;

    var cycleElapsed = now.difference(state.cycleStart!).inMicroseconds / 1e6;
    while (cycleElapsed >= state.cycleDuration!) {
      cycleElapsed -= state.cycleDuration!;
      state.cycleStart = state.cycleStart!.add(
        Duration(microseconds: (state.cycleDuration! * 1e6).round()),
      );
      state.cycleIndex += 1;
      final next = state.cycleDuration! * auto.rampRepeatSpeedFactor;
      state.cycleDuration = next < 0.05 ? 0.05 : next;
    }

    final dur = state.cycleDuration!;
    double progress;
    if (auto.rampRepeat == RampRepeat.loop) {
      progress = (cycleElapsed / dur).clamp(0.0, 1.0);
    } else {
      // pingPong - each cycle here is one leg (there or back), alternating.
      final legProgress = (cycleElapsed / dur).clamp(0.0, 1.0);
      progress = state.cycleIndex.isOdd ? 1.0 - legProgress : legProgress;
    }

    if (count <= 0) return (progress: progress, finished: false);
    final completedRepeats = auto.rampRepeat == RampRepeat.pingPong ? state.cycleIndex ~/ 2 : state.cycleIndex;
    if (completedRepeats < count) return (progress: progress, finished: false);
    return (progress: auto.rampRepeat == RampRepeat.loop ? 1.0 : 0.0, finished: true);
  }

  double _ease(EasingKind kind, double t, Automation auto) {
    switch (kind) {
      case EasingKind.linear:
        return t;
      case EasingKind.sine:
        return 0.5 - 0.5 * cos(pi * t);
      case EasingKind.easeInOut:
        if (t < 0.5) return 2 * t * t;
        final f = -2 * t + 2;
        return 1 - (f * f) / 2;
      case EasingKind.custom:
        return evalCustomCurve(auto.customCurvePoints, auto.customCurveSmooth, t);
    }
  }

  void _tickRandomSlider(
    ParamControl param,
    Automation auto,
    _RuntimeState state,
    DateTime now,
    void Function(ParamControl, double) onSlider,
  ) {
    final sinceLastPick =
        state.lastPick == null ? double.infinity : now.difference(state.lastPick!).inMicroseconds / 1e6;
    if (state.lastPick == null || sinceLastPick >= (state.intervalSeconds ?? 0)) {
      state.previousValue = state.currentTarget ?? _randomIn(auto.randomValueMin, auto.randomValueMax);
      state.currentTarget = _randomIn(auto.randomValueMin, auto.randomValueMax);
      state.lastPick = now;
      state.intervalSeconds = _randomIn(auto.randomIntervalMinSeconds, auto.randomIntervalMaxSeconds);
    }

    if (!auto.randomSmooth) {
      onSlider(param, state.currentTarget!);
      return;
    }

    final interval = state.intervalSeconds! <= 0 ? 0.001 : state.intervalSeconds!;
    final t = ((now.difference(state.lastPick!).inMicroseconds / 1e6) / interval).clamp(0.0, 1.0);
    onSlider(param, state.previousValue! + (state.currentTarget! - state.previousValue!) * t);
  }

  void _tickBlink(Automation auto, _RuntimeState state, DateTime now, void Function(bool) onToggle) {
    final onDur = max(auto.blinkOnSeconds, 0.05);
    final offDur = max(auto.blinkOffSeconds, 0.05);
    final elapsed = now.difference(state.startTime).inMicroseconds / 1e6;
    final phase = elapsed % (onDur + offDur);
    final isOn = phase < onDur;
    if (state.currentBoolState != isOn) {
      state.currentBoolState = isOn;
      onToggle(isOn);
    }
  }

  void _tickRandomToggle(Automation auto, _RuntimeState state, DateTime now, void Function(bool) onToggle) {
    final sinceLastPick =
        state.lastPick == null ? double.infinity : now.difference(state.lastPick!).inMicroseconds / 1e6;
    if (state.lastPick == null || sinceLastPick >= (state.intervalSeconds ?? 0)) {
      state.lastPick = now;
      state.intervalSeconds = _randomIn(auto.randomIntervalMinSeconds, auto.randomIntervalMaxSeconds);
      final next = _random.nextBool();
      if (state.currentBoolState != next) {
        state.currentBoolState = next;
        onToggle(next);
      }
    }
  }

  double _randomIn(double min, double max) {
    if (max <= min) return min;
    return min + _random.nextDouble() * (max - min);
  }
}
