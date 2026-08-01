import 'param_control.dart';

class _ScheduleRuntimeState {
  // timeOfDay - "yyyy-mm-dd" of the last day it fired, so it only fires once
  // per matching minute rather than on every tick throughout that minute.
  String? lastFiredDate;
  // interval/countdown - when the next (or, for countdown, the only) fire is due.
  DateTime? nextFireTime;
  // idle - whether this idle stretch has already fired, so it only fires
  // once per stretch rather than every tick while still idle.
  bool firedForCurrentIdleStretch = false;
}

class _PendingRevert {
  final DateTime at;
  final double? toValue;
  final bool? toBool;
  _PendingRevert(this.at, {this.toValue, this.toBool});
}

/// drives every parameter's schedule from a periodic tick - independent of
/// AutomationEngine since schedules are trigger-once/trigger-on-a-timer
/// rather than continuously-generated values.
class ScheduleEngine {
  final Map<String, _ScheduleRuntimeState> _runtime = {};
  final Map<String, _PendingRevert> _pendingReverts = {};

  void reset() {
    _runtime.clear();
    _pendingReverts.clear();
  }

  void tick(
    List<ParamControl> parameters,
    DateTime lastInteraction,
    Map<String, Object> currentValues,
    void Function(ParamControl param, double value) onSlider,
    void Function(ParamControl param, bool value) onToggle,
  ) {
    final now = DateTime.now();

    // reverts always run to completion even if the schedule that queued them
    // has since disabled itself (e.g. a countdown schedule is one-shot and
    // disables right after firing).
    for (final name in _pendingReverts.keys.toList()) {
      final pending = _pendingReverts[name]!;
      if (now.isBefore(pending.at)) continue;
      _pendingReverts.remove(name);
      final param = _find(parameters, name);
      if (param == null) continue;
      if (pending.toValue != null) onSlider(param, pending.toValue!);
      if (pending.toBool != null) onToggle(param, pending.toBool!);
    }

    final liveNames = <String>{};
    for (final param in parameters) {
      final sched = param.schedule;
      if (sched == null || !sched.enabled) continue;
      liveNames.add(param.name);
      final state = _runtime.putIfAbsent(param.name, () => _ScheduleRuntimeState());

      switch (sched.kind) {
        case ScheduleKind.timeOfDay:
          _tickTimeOfDay(param, sched, state, now, currentValues, onSlider, onToggle);
        case ScheduleKind.interval:
          _tickInterval(param, sched, state, now, currentValues, onSlider, onToggle);
        case ScheduleKind.idle:
          _tickIdle(param, sched, state, now, lastInteraction, currentValues, onSlider, onToggle);
        case ScheduleKind.countdown:
          _tickCountdown(param, sched, state, now, currentValues, onSlider, onToggle);
      }
    }
    _runtime.removeWhere((key, _) => !liveNames.contains(key));
  }

  ParamControl? _find(List<ParamControl> parameters, String name) {
    for (final p in parameters) {
      if (p.name == name) return p;
    }
    return null;
  }

  void _fire(
    ParamControl param,
    ParamSchedule sched,
    Map<String, Object> currentValues,
    DateTime now,
    void Function(ParamControl, double) onSlider,
    void Function(ParamControl, bool) onToggle,
  ) {
    if (param.type == ParamType.slider) {
      final before = currentValues[param.name] as double? ?? param.defaultValue;
      onSlider(param, sched.targetValue);
      if (sched.revertAfterSeconds > 0) {
        _pendingReverts[param.name] = _PendingRevert(
          now.add(Duration(microseconds: (sched.revertAfterSeconds * 1e6).round())),
          toValue: before,
        );
      }
    } else if (param.type == ParamType.toggle) {
      final before = currentValues[param.name] as bool? ?? param.defaultBool;
      onToggle(param, sched.targetBool);
      if (sched.revertAfterSeconds > 0) {
        _pendingReverts[param.name] = _PendingRevert(
          now.add(Duration(microseconds: (sched.revertAfterSeconds * 1e6).round())),
          toBool: before,
        );
      }
    }
  }

  void _tickTimeOfDay(
    ParamControl param,
    ParamSchedule sched,
    _ScheduleRuntimeState state,
    DateTime now,
    Map<String, Object> currentValues,
    void Function(ParamControl, double) onSlider,
    void Function(ParamControl, bool) onToggle,
  ) {
    if (now.hour != sched.timeOfDayHour || now.minute != sched.timeOfDayMinute) return;
    final todayKey = '${now.year}-${now.month}-${now.day}';
    if (state.lastFiredDate == todayKey) return;
    state.lastFiredDate = todayKey;
    _fire(param, sched, currentValues, now, onSlider, onToggle);
  }

  void _tickInterval(
    ParamControl param,
    ParamSchedule sched,
    _ScheduleRuntimeState state,
    DateTime now,
    Map<String, Object> currentValues,
    void Function(ParamControl, double) onSlider,
    void Function(ParamControl, bool) onToggle,
  ) {
    final interval = sched.intervalSeconds <= 0 ? 1.0 : sched.intervalSeconds;
    state.nextFireTime ??= now.add(Duration(microseconds: (interval * 1e6).round()));
    if (now.isBefore(state.nextFireTime!)) return;
    state.nextFireTime = now.add(Duration(microseconds: (interval * 1e6).round()));
    _fire(param, sched, currentValues, now, onSlider, onToggle);
  }

  void _tickIdle(
    ParamControl param,
    ParamSchedule sched,
    _ScheduleRuntimeState state,
    DateTime now,
    DateTime lastInteraction,
    Map<String, Object> currentValues,
    void Function(ParamControl, double) onSlider,
    void Function(ParamControl, bool) onToggle,
  ) {
    final idleSeconds = now.difference(lastInteraction).inMicroseconds / 1e6;
    if (idleSeconds < sched.idleSeconds) {
      state.firedForCurrentIdleStretch = false;
      return;
    }
    if (state.firedForCurrentIdleStretch) return;
    state.firedForCurrentIdleStretch = true;
    _fire(param, sched, currentValues, now, onSlider, onToggle);
  }

  void _tickCountdown(
    ParamControl param,
    ParamSchedule sched,
    _ScheduleRuntimeState state,
    DateTime now,
    Map<String, Object> currentValues,
    void Function(ParamControl, double) onSlider,
    void Function(ParamControl, bool) onToggle,
  ) {
    final countdown = sched.countdownSeconds <= 0 ? 0.001 : sched.countdownSeconds;
    state.nextFireTime ??= now.add(Duration(microseconds: (countdown * 1e6).round()));
    if (now.isBefore(state.nextFireTime!)) return;
    _fire(param, sched, currentValues, now, onSlider, onToggle);
    sched.enabled = false;
  }
}
