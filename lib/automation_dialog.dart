import 'dart:collection';

import 'package:flutter/material.dart';

import 'curve_editor_dialog.dart';
import 'param_control.dart';
import 'trigger_fields.dart';

/// shows the automation editor for [param]. mutates param.automation and/or
/// param.schedule directly and returns true if something changed (saved or
/// removed), false if the user cancelled - the caller just needs to
/// persist+refresh on true.
Future<bool> showAutomationDialog(BuildContext context, ParamControl param, List<ParamControl> allParameters) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AutomationDialog(param: param, allParameters: allParameters),
  );
  return result ?? false;
}

/// shows a simplified automation editor scoped to a sequence's own
/// per-parameter automation override - no Enabled switch (the sequence's
/// own Running state controls it instead), no schedule kinds, no trigger
/// section, and it never reads or writes the parameter's own (global)
/// automation. `changed` is false for Cancel/dismiss (ignore `automation`);
/// true with `automation: null` for an explicit Remove; true with a value
/// for Save.
Future<({bool changed, Automation? automation})> showSequenceParamAutomationDialog(
  BuildContext context,
  ParamControl param,
  List<ParamControl> allParameters,
  Automation? initial,
) async {
  final result = await showDialog<({bool changed, Automation? automation})>(
    context: context,
    builder: (context) => AutomationDialog(
      param: param,
      allParameters: allParameters,
      simpleMode: true,
      initialAutomation: initial,
    ),
  );
  return result ?? (changed: false, automation: null);
}

// schedules are folded in here as "just another Type" rather than a fully
// separate feature - only one of Automation/ParamSchedule is ever active at
// once through this dialog, whichever Type is currently selected.
enum _UnifiedKind { ramp, random, blink, timeOfDay, interval, idle, countdown }

bool _isScheduleKind(_UnifiedKind k) =>
    k == _UnifiedKind.timeOfDay || k == _UnifiedKind.interval || k == _UnifiedKind.idle || k == _UnifiedKind.countdown;

class AutomationDialog extends StatefulWidget {
  final ParamControl param;
  final List<ParamControl> allParameters;
  // true for a sequence's per-parameter automation override - see
  // showSequenceParamAutomationDialog.
  final bool simpleMode;
  final Automation? initialAutomation;
  const AutomationDialog({
    super.key,
    required this.param,
    required this.allParameters,
    this.simpleMode = false,
    this.initialAutomation,
  });

  @override
  State<AutomationDialog> createState() => _AutomationDialogState();
}

class _AutomationDialogState extends State<AutomationDialog> {
  late bool _enabled;
  late _UnifiedKind _kind;

  // automation fields
  late final TextEditingController _rampFrom;
  late final TextEditingController _rampTo;
  late final TextEditingController _rampDuration;
  late RampRepeat _rampRepeat;
  late final TextEditingController _rampRepeatCount;
  late final TextEditingController _rampRepeatSpeedFactor;
  late EasingKind _easing;
  late List<Offset> _customCurvePoints;
  late bool _customCurveSmooth;
  late double _customCurveYMin;
  late double _customCurveYMax;
  late final TextEditingController _randomValueMin;
  late final TextEditingController _randomValueMax;
  late final TextEditingController _randomIntervalMin;
  late final TextEditingController _randomIntervalMax;
  late bool _randomSmooth;
  late final TextEditingController _blinkOn;
  late final TextEditingController _blinkOff;

  // schedule fields
  late final TextEditingController _hour;
  late final TextEditingController _minute;
  late Set<int> _days;
  late final TextEditingController _intervalSeconds;
  late final TextEditingController _idleSeconds;
  late final TextEditingController _countdownSeconds;
  late final TextEditingController _scheduleTargetValue;
  late bool _scheduleTargetBool;
  late final TextEditingController _revertAfterSeconds;

  // trigger fields - automation-only, schedules don't support this.
  late bool _triggerEnabled;
  late String? _watchedParamName;
  late ToggleTriggerCondition _toggleCondition;
  late RangeTriggerCondition _rangeCondition;
  late final TextEditingController _triggerThreshold;
  late final TextEditingController _triggerRangeMin;
  late final TextEditingController _triggerRangeMax;
  late final TextEditingController _triggerRequiredHits;

  // simple mode only - see param_control.dart's Automation.startDelaySeconds.
  late final TextEditingController _startDelaySeconds;

  bool get _isSlider => widget.param.type == ParamType.slider;

  List<ParamControl> get _eligibleWatchParams => widget.allParameters
      .where((p) => p.name != widget.param.name && (p.type == ParamType.slider || p.isBoolLike))
      .toList();

  @override
  void initState() {
    super.initState();
    // a param could carry both from before schedules were folded in here -
    // prefer the automation if so, since only one is reachable going forward.
    // simple mode never reads the parameter's own automation/schedule at
    // all - only the sequence-scoped value passed in.
    final auto = widget.simpleMode ? widget.initialAutomation : widget.param.automation;
    final sched = widget.simpleMode ? null : widget.param.schedule;

    if (auto != null) {
      _enabled = auto.enabled;
      _kind = switch (auto.kind) {
        AutomationKind.ramp => _UnifiedKind.ramp,
        AutomationKind.random => _UnifiedKind.random,
        AutomationKind.blink => _UnifiedKind.blink,
      };
    } else if (sched != null) {
      _enabled = sched.enabled;
      _kind = switch (sched.kind) {
        ScheduleKind.timeOfDay => _UnifiedKind.timeOfDay,
        ScheduleKind.interval => _UnifiedKind.interval,
        ScheduleKind.idle => _UnifiedKind.idle,
        ScheduleKind.countdown => _UnifiedKind.countdown,
      };
    } else {
      // a brand-new automation is being set up to run - start it switched on.
      _enabled = true;
      _kind = _isSlider ? _UnifiedKind.ramp : _UnifiedKind.blink;
    }

    _rampFrom = TextEditingController(text: _fmt(auto?.rampFrom ?? widget.param.min));
    _rampTo = TextEditingController(text: _fmt(auto?.rampTo ?? widget.param.max));
    _rampDuration = TextEditingController(text: _fmt(auto?.rampDurationSeconds ?? 2.0));
    _rampRepeat = auto?.rampRepeat ?? RampRepeat.pingPong;
    _rampRepeatCount = TextEditingController(text: '${auto?.rampRepeatCount ?? 0}');
    _rampRepeatSpeedFactor = TextEditingController(text: _fmt(auto?.rampRepeatSpeedFactor ?? 1.0));
    _easing = auto?.easing ?? EasingKind.easeInOut;
    _customCurvePoints = [...?auto?.customCurvePoints];
    if (_customCurvePoints.length < 2) {
      _customCurvePoints = [const Offset(0, 0), const Offset(1, 1)];
    }
    _customCurveSmooth = auto?.customCurveSmooth ?? false;
    _customCurveYMin = auto?.customCurveYMin ?? -0.3;
    _customCurveYMax = auto?.customCurveYMax ?? 1.3;
    _randomValueMin = TextEditingController(text: _fmt(auto?.randomValueMin ?? widget.param.min));
    _randomValueMax = TextEditingController(text: _fmt(auto?.randomValueMax ?? widget.param.max));
    _randomIntervalMin = TextEditingController(text: _fmt(auto?.randomIntervalMinSeconds ?? 1.0));
    _randomIntervalMax = TextEditingController(text: _fmt(auto?.randomIntervalMaxSeconds ?? 3.0));
    _randomSmooth = auto?.randomSmooth ?? true;
    _blinkOn = TextEditingController(text: _fmt(auto?.blinkOnSeconds ?? 1.0));
    _blinkOff = TextEditingController(text: _fmt(auto?.blinkOffSeconds ?? 1.0));

    _hour = TextEditingController(text: '${sched?.timeOfDayHour ?? 21}');
    _minute = TextEditingController(text: '${sched?.timeOfDayMinute ?? 0}');
    _days = {...?sched?.daysOfWeek};
    _intervalSeconds = TextEditingController(text: _fmt(sched?.intervalSeconds ?? 1800));
    _idleSeconds = TextEditingController(text: _fmt(sched?.idleSeconds ?? 300));
    _countdownSeconds = TextEditingController(text: _fmt(sched?.countdownSeconds ?? 60));
    _scheduleTargetValue = TextEditingController(text: _fmt(sched?.targetValue ?? widget.param.max));
    _scheduleTargetBool = sched?.targetBool ?? true;
    _revertAfterSeconds = TextEditingController(text: _fmt(sched?.revertAfterSeconds ?? 0));

    final trigger = auto?.trigger;
    _triggerEnabled = trigger?.enabled ?? false;
    _watchedParamName = trigger?.watchedParamName;
    _toggleCondition = trigger?.toggleCondition ?? ToggleTriggerCondition.turnsOn;
    _rangeCondition = trigger?.rangeCondition ?? RangeTriggerCondition.above;
    _triggerThreshold = TextEditingController(text: _fmt(trigger?.threshold ?? 0.5));
    _triggerRangeMin = TextEditingController(text: _fmt(trigger?.rangeMin ?? 0.25));
    _triggerRangeMax = TextEditingController(text: _fmt(trigger?.rangeMax ?? 0.75));
    _triggerRequiredHits = TextEditingController(text: '${trigger?.requiredHits ?? 1}');
    _startDelaySeconds = TextEditingController(text: _fmt(auto?.startDelaySeconds ?? 0.0));
    // a watched parameter that's since been deleted/renamed - the picker
    // falls back to showing the first eligible one, so store that too
    // instead of silently saving a trigger that watches nothing.
    final eligible = _eligibleWatchParams;
    if (eligible.isNotEmpty && !eligible.any((p) => p.name == _watchedParamName)) {
      _watchedParamName = eligible.first.name;
    }
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _rampFrom.dispose();
    _rampTo.dispose();
    _rampDuration.dispose();
    _rampRepeatCount.dispose();
    _rampRepeatSpeedFactor.dispose();
    _randomValueMin.dispose();
    _randomValueMax.dispose();
    _randomIntervalMin.dispose();
    _randomIntervalMax.dispose();
    _blinkOn.dispose();
    _blinkOff.dispose();
    _hour.dispose();
    _minute.dispose();
    _intervalSeconds.dispose();
    _idleSeconds.dispose();
    _countdownSeconds.dispose();
    _scheduleTargetValue.dispose();
    _revertAfterSeconds.dispose();
    _triggerThreshold.dispose();
    _triggerRangeMin.dispose();
    _triggerRangeMax.dispose();
    _triggerRequiredHits.dispose();
    _startDelaySeconds.dispose();
    super.dispose();
  }

  double _num(TextEditingController c, double fallback) {
    return parseUserDouble(c.text) ?? fallback;
  }

  double _positive(TextEditingController c, double fallback) {
    final v = _num(c, fallback).abs();
    return v < 0.05 ? 0.05 : v;
  }

  // automation duration fields have no artificial minimum - unlike
  // schedules (_positive above), the automation engine already treats <=0
  // as an effectively-instant 0.001s on its own, so there's nothing left
  // for a UI-level floor to protect against.
  double _unclamped(TextEditingController c, double fallback) => _num(c, fallback).abs();

  int _nonNegativeInt(TextEditingController c) {
    final v = int.tryParse(c.text) ?? 0;
    return v < 0 ? 0 : v;
  }

  double _speedFactor(TextEditingController c) {
    final v = _num(c, 1.0).abs();
    return v < 0.01 ? 0.01 : v;
  }

  int _clampInt(TextEditingController c, int fallback, int min, int max) {
    final v = int.tryParse(c.text) ?? fallback;
    return v.clamp(min, max);
  }

  Automation _buildAutomation(ParamTrigger? trigger) {
    return Automation(
      // in simple mode this is a pause/resume within the sequence - it still
      // needs the sequence itself running to actually tick.
      enabled: _enabled,
      kind: switch (_kind) {
        _UnifiedKind.random => AutomationKind.random,
        _UnifiedKind.blink => AutomationKind.blink,
        _ => AutomationKind.ramp, // ramp, plus unreachable schedule kinds
      },
      rampFrom: _num(_rampFrom, 0),
      rampTo: _num(_rampTo, 1),
      rampDurationSeconds: _unclamped(_rampDuration, 2),
      rampRepeat: _rampRepeat,
      rampRepeatCount: _nonNegativeInt(_rampRepeatCount),
      rampRepeatSpeedFactor: _speedFactor(_rampRepeatSpeedFactor),
      easing: _easing,
      customCurvePoints: _customCurvePoints,
      customCurveSmooth: _customCurveSmooth,
      customCurveYMin: _customCurveYMin,
      customCurveYMax: _customCurveYMax,
      randomValueMin: _num(_randomValueMin, 0),
      randomValueMax: _num(_randomValueMax, 1),
      randomIntervalMinSeconds: _unclamped(_randomIntervalMin, 1),
      randomIntervalMaxSeconds: _unclamped(_randomIntervalMax, 3),
      randomSmooth: _randomSmooth,
      blinkOnSeconds: _unclamped(_blinkOn, 1),
      blinkOffSeconds: _unclamped(_blinkOff, 1),
      trigger: trigger,
      // only ever settable in simple mode - always 0 (starts immediately)
      // for a parameter's own automation.
      startDelaySeconds: widget.simpleMode ? _num(_startDelaySeconds, 0).abs() : 0.0,
    );
  }

  void _save() {
    if (widget.simpleMode) {
      // no schedule kinds, no trigger - kindOptions excludes schedules in
      // this mode, and the trigger section is hidden entirely.
      Navigator.of(context).pop((changed: true, automation: _buildAutomation(null)));
      return;
    }
    if (_isScheduleKind(_kind)) {
      widget.param.schedule = ParamSchedule(
        enabled: _enabled,
        kind: switch (_kind) {
          _UnifiedKind.timeOfDay => ScheduleKind.timeOfDay,
          _UnifiedKind.interval => ScheduleKind.interval,
          _UnifiedKind.idle => ScheduleKind.idle,
          _UnifiedKind.countdown => ScheduleKind.countdown,
          _ => ScheduleKind.timeOfDay, // unreachable
        },
        timeOfDayHour: _clampInt(_hour, 21, 0, 23),
        timeOfDayMinute: _clampInt(_minute, 0, 0, 59),
        // all seven picked is the same as "every day".
        daysOfWeek: _days.length == 7 ? [] : (_days.toList()..sort()),
        intervalSeconds: _positive(_intervalSeconds, 1800),
        idleSeconds: _positive(_idleSeconds, 300),
        countdownSeconds: _positive(_countdownSeconds, 60),
        targetValue: _num(_scheduleTargetValue, widget.param.max),
        targetBool: _scheduleTargetBool,
        revertAfterSeconds: _num(_revertAfterSeconds, 0).abs(),
      );
      widget.param.automation = null;
    } else {
      final isNew = widget.param.automation == null;
      final automation = _buildAutomation(
        _watchedParamName == null
            ? null
            : ParamTrigger(
                enabled: _triggerEnabled,
                watchedParamName: _watchedParamName!,
                toggleCondition: _toggleCondition,
                rangeCondition: _rangeCondition,
                threshold: _num(_triggerThreshold, 0.5),
                rangeMin: _num(_triggerRangeMin, 0.25),
                rangeMax: _num(_triggerRangeMax, 0.75),
                requiredHits: _clampInt(_triggerRequiredHits, 1, 1, 999999),
              ),
      );
      // a new automation that waits for a "fires once" trigger shouldn't
      // also start running the moment it's saved.
      if (isNew && _triggerEnabled && _isPulseTrigger()) automation.enabled = false;
      widget.param.automation = automation;
      widget.param.schedule = null;
    }
    Navigator.of(context).pop(true);
  }

  bool _isPulseTrigger() {
    final watched = _eligibleWatchParams.where((p) => p.name == _watchedParamName).firstOrNull;
    if (watched == null) return false;
    return watched.isBoolLike
        ? _toggleCondition == ToggleTriggerCondition.turnsOn || _toggleCondition == ToggleTriggerCondition.turnsOff
        : _rangeCondition == RangeTriggerCondition.crossesAbove || _rangeCondition == RangeTriggerCondition.crossesBelow;
  }

  void _remove() {
    if (widget.simpleMode) {
      Navigator.of(context).pop((changed: true, automation: null));
      return;
    }
    widget.param.automation = null;
    widget.param.schedule = null;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final kindOptions = [
      if (_isSlider) _UnifiedKind.ramp,
      _UnifiedKind.random,
      if (!_isSlider) _UnifiedKind.blink,
      if (!widget.simpleMode) ...[
        _UnifiedKind.timeOfDay,
        _UnifiedKind.interval,
        _UnifiedKind.idle,
        _UnifiedKind.countdown,
      ],
    ];

    return AlertDialog(
      title: Text(
        widget.simpleMode ? 'Automate "${widget.param.label}" (in this sequence)' : 'Automate "${widget.param.label}"',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Enabled')),
                  Switch(value: _enabled, onChanged: (v) => setState(() => _enabled = v)),
                ],
              ),
              if (widget.simpleMode)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Pauses this automation without removing its settings - stays off even while the sequence runs.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 8),
              DropdownButtonFormField<_UnifiedKind>(
                isExpanded: true,
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final k in kindOptions) DropdownMenuItem(value: k, child: Text(_kindLabel(k))),
                ],
                onChanged: (v) => setState(() => _kind = v ?? _kind),
              ),
              if (widget.simpleMode) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _startDelaySeconds,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Start delay (seconds)',
                    helperText: 'Holds off starting this one until this long after the sequence starts running '
                        '(0 = immediately) - stagger several automations instead of starting in lockstep',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (_kind == _UnifiedKind.ramp) _buildRamp(),
              if (_kind == _UnifiedKind.random) _buildRandom(),
              if (_kind == _UnifiedKind.blink) _buildBlink(),
              if (_isScheduleKind(_kind)) _buildSchedule(),
              if (!_isScheduleKind(_kind) && !widget.simpleMode) ...[
                const Divider(height: 24),
                Row(
                  children: [
                    const Expanded(child: Text('Triggered by another parameter')),
                    Switch(value: _triggerEnabled, onChanged: (v) => setState(() => _triggerEnabled = v)),
                  ],
                ),
                if (_triggerEnabled) ...[
                  const SizedBox(height: 8),
                  TriggerFields(
                    eligibleParams: _eligibleWatchParams,
                    watchedParamName: _watchedParamName,
                    toggleCondition: _toggleCondition,
                    rangeCondition: _rangeCondition,
                    thresholdController: _triggerThreshold,
                    rangeMinController: _triggerRangeMin,
                    rangeMaxController: _triggerRangeMax,
                    requiredHitsController: _triggerRequiredHits,
                    onWatchedParamChanged: (v) => setState(() => _watchedParamName = v),
                    onToggleConditionChanged: (v) => setState(() => _toggleCondition = v),
                    onRangeConditionChanged: (v) => setState(() => _rangeCondition = v),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.simpleMode ? widget.initialAutomation != null : (widget.param.automation != null || widget.param.schedule != null))
          TextButton(
            onPressed: _remove,
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            widget.simpleMode ? (changed: false, automation: null) : false,
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  String _kindLabel(_UnifiedKind k) => switch (k) {
        _UnifiedKind.ramp => 'Ramp',
        _UnifiedKind.random => 'Random',
        _UnifiedKind.blink => 'Blink',
        _UnifiedKind.timeOfDay => 'Time of day (once daily)',
        _UnifiedKind.interval => 'Interval (repeating)',
        _UnifiedKind.idle => 'Idle (no interaction for a while)',
        _UnifiedKind.countdown => 'Countdown (once, after a delay)',
      };

  Widget _buildRamp() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _rampFrom,
                keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                decoration: const InputDecoration(labelText: 'From'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _rampTo,
                keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                decoration: const InputDecoration(labelText: 'To'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _rampDuration,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Duration (seconds)'),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<RampRepeat>(
          isExpanded: true,
          initialValue: _rampRepeat,
          decoration: const InputDecoration(labelText: 'Repeat'),
          items: const [
            DropdownMenuItem(value: RampRepeat.once, child: Text('Once')),
            DropdownMenuItem(value: RampRepeat.loop, child: Text('Loop (restart from "From")')),
            DropdownMenuItem(value: RampRepeat.pingPong, child: Text('Ping-pong (bounce back and forth)')),
          ],
          onChanged: (v) => setState(() => _rampRepeat = v ?? _rampRepeat),
        ),
        if (_rampRepeat != RampRepeat.once) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _rampRepeatCount,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Repeat count (0 = forever)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _rampRepeatSpeedFactor,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Speed change per repeat',
              helperText: '1 = no change, <1 speeds up, >1 slows down',
            ),
          ),
        ],
        const SizedBox(height: 8),
        DropdownButtonFormField<EasingKind>(
          isExpanded: true,
          initialValue: _easing,
          decoration: const InputDecoration(labelText: 'Easing'),
          items: const [
            DropdownMenuItem(value: EasingKind.linear, child: Text('Linear')),
            DropdownMenuItem(value: EasingKind.easeInOut, child: Text('Ease in/out')),
            DropdownMenuItem(value: EasingKind.sine, child: Text('Sine (smooth, good for ping-pong)')),
            DropdownMenuItem(value: EasingKind.custom, child: Text('Custom curve')),
          ],
          onChanged: (v) => setState(() => _easing = v ?? _easing),
        ),
        if (_easing == EasingKind.custom) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final result = await showCurveEditorDialog(
                context,
                _customCurvePoints,
                _customCurveSmooth,
                _customCurveYMin,
                _customCurveYMax,
              );
              if (result != null) {
                setState(() {
                  _customCurvePoints = result.points;
                  _customCurveSmooth = result.smooth;
                  _customCurveYMin = result.yMin;
                  _customCurveYMax = result.yMax;
                });
              }
            },
            icon: const Icon(Icons.show_chart),
            label: const Text('Edit curve'),
          ),
        ],
      ],
    );
  }

  Widget _buildRandom() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isSlider) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _randomValueMin,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(labelText: 'Value min'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _randomValueMax,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(labelText: 'Value max'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _randomIntervalMin,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Interval min (s)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _randomIntervalMax,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Interval max (s)'),
              ),
            ),
          ],
        ),
        if (_isSlider)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Smooth drift'),
            subtitle: const Text('Glide to each new value instead of snapping'),
            value: _randomSmooth,
            onChanged: (v) => setState(() => _randomSmooth = v),
          ),
      ],
    );
  }

  Widget _buildBlink() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _blinkOn,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'On (seconds)'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _blinkOff,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Off (seconds)'),
          ),
        ),
      ],
    );
  }

  Widget _buildSchedule() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ..._scheduleKindFields(),
        const Divider(height: 24),
        if (_isSlider)
          TextField(
            controller: _scheduleTargetValue,
            keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
            decoration: const InputDecoration(labelText: 'Set value to'),
          )
        else
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Set to'),
            subtitle: Text(_scheduleTargetBool ? 'On' : 'Off'),
            value: _scheduleTargetBool,
            onChanged: (v) => setState(() => _scheduleTargetBool = v),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _revertAfterSeconds,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Revert after (seconds, 0 = stay)',
            helperText: 'Restores the previous value automatically - use for a pulse instead of a permanent change',
          ),
        ),
      ],
    );
  }

  List<Widget> _scheduleKindFields() {
    switch (_kind) {
      case _UnifiedKind.timeOfDay:
        return [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _hour,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Hour (0-23)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _minute,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Minute (0-59)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (day, label) in const [
                (DateTime.monday, 'Mon'),
                (DateTime.tuesday, 'Tue'),
                (DateTime.wednesday, 'Wed'),
                (DateTime.thursday, 'Thu'),
                (DateTime.friday, 'Fri'),
                (DateTime.saturday, 'Sat'),
                (DateTime.sunday, 'Sun'),
              ])
                FilterChip(
                  label: Text(label),
                  selected: _days.contains(day),
                  onSelected: (v) => setState(() => v ? _days.add(day) : _days.remove(day)),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _days.isEmpty || _days.length == 7 ? 'Every day' : 'Only on the selected days',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ];
      case _UnifiedKind.interval:
        return [
          TextField(
            controller: _intervalSeconds,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Every (seconds)'),
          ),
        ];
      case _UnifiedKind.idle:
        return [
          TextField(
            controller: _idleSeconds,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'After idle for (seconds)',
              helperText: 'Idle = no slider/toggle touched by hand anywhere in the app',
            ),
          ),
        ];
      case _UnifiedKind.countdown:
        return [
          TextField(
            controller: _countdownSeconds,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Fire once after (seconds)'),
          ),
        ];
      case _UnifiedKind.ramp:
      case _UnifiedKind.random:
      case _UnifiedKind.blink:
        return const []; // unreachable - _buildSchedule only shows for schedule kinds
    }
  }
}
