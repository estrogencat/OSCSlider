import 'package:flutter/material.dart';

import 'curve_editor_dialog.dart';
import 'param_control.dart';

/// shows the automation editor for [param]. mutates param.automation
/// directly and returns true if something changed (saved or removed), false
/// if the user cancelled - the caller just needs to persist+refresh on true.
Future<bool> showAutomationDialog(BuildContext context, ParamControl param) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AutomationDialog(param: param),
  );
  return result ?? false;
}

class AutomationDialog extends StatefulWidget {
  final ParamControl param;
  const AutomationDialog({super.key, required this.param});

  @override
  State<AutomationDialog> createState() => _AutomationDialogState();
}

class _AutomationDialogState extends State<AutomationDialog> {
  late bool _enabled;
  late AutomationKind _kind;
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

  bool get _isSlider => widget.param.type == ParamType.slider;

  @override
  void initState() {
    super.initState();
    final existing = widget.param.automation;
    _enabled = existing?.enabled ?? false;
    _kind = existing?.kind ?? (_isSlider ? AutomationKind.ramp : AutomationKind.blink);
    _rampFrom = TextEditingController(text: _fmt(existing?.rampFrom ?? widget.param.min));
    _rampTo = TextEditingController(text: _fmt(existing?.rampTo ?? widget.param.max));
    _rampDuration = TextEditingController(text: _fmt(existing?.rampDurationSeconds ?? 2.0));
    _rampRepeat = existing?.rampRepeat ?? RampRepeat.pingPong;
    _rampRepeatCount = TextEditingController(text: '${existing?.rampRepeatCount ?? 0}');
    _rampRepeatSpeedFactor = TextEditingController(text: _fmt(existing?.rampRepeatSpeedFactor ?? 1.0));
    _easing = existing?.easing ?? EasingKind.easeInOut;
    _customCurvePoints = [...?existing?.customCurvePoints];
    if (_customCurvePoints.length < 2) {
      _customCurvePoints = [const Offset(0, 0), const Offset(1, 1)];
    }
    _customCurveSmooth = existing?.customCurveSmooth ?? false;
    _customCurveYMin = existing?.customCurveYMin ?? -0.3;
    _customCurveYMax = existing?.customCurveYMax ?? 1.3;
    _randomValueMin = TextEditingController(text: _fmt(existing?.randomValueMin ?? widget.param.min));
    _randomValueMax = TextEditingController(text: _fmt(existing?.randomValueMax ?? widget.param.max));
    _randomIntervalMin = TextEditingController(text: _fmt(existing?.randomIntervalMinSeconds ?? 1.0));
    _randomIntervalMax = TextEditingController(text: _fmt(existing?.randomIntervalMaxSeconds ?? 3.0));
    _randomSmooth = existing?.randomSmooth ?? true;
    _blinkOn = TextEditingController(text: _fmt(existing?.blinkOnSeconds ?? 1.0));
    _blinkOff = TextEditingController(text: _fmt(existing?.blinkOffSeconds ?? 1.0));
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
    super.dispose();
  }

  double _num(TextEditingController c, double fallback) => double.tryParse(c.text) ?? fallback;

  double _positive(TextEditingController c, double fallback) {
    final v = _num(c, fallback).abs();
    return v < 0.05 ? 0.05 : v;
  }

  int _nonNegativeInt(TextEditingController c) {
    final v = int.tryParse(c.text) ?? 0;
    return v < 0 ? 0 : v;
  }

  double _speedFactor(TextEditingController c) {
    final v = _num(c, 1.0).abs();
    return v < 0.01 ? 0.01 : v;
  }

  void _save() {
    widget.param.automation = Automation(
      enabled: _enabled,
      kind: _kind,
      rampFrom: _num(_rampFrom, 0),
      rampTo: _num(_rampTo, 1),
      rampDurationSeconds: _positive(_rampDuration, 2),
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
      randomIntervalMinSeconds: _positive(_randomIntervalMin, 1),
      randomIntervalMaxSeconds: _positive(_randomIntervalMax, 3),
      randomSmooth: _randomSmooth,
      blinkOnSeconds: _positive(_blinkOn, 1),
      blinkOffSeconds: _positive(_blinkOff, 1),
    );
    Navigator.of(context).pop(true);
  }

  void _remove() {
    widget.param.automation = null;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final kindOptions = _isSlider
        ? const [AutomationKind.ramp, AutomationKind.random]
        : const [AutomationKind.blink, AutomationKind.random];

    return AlertDialog(
      title: Text('Automate "${widget.param.label}"'),
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
              const SizedBox(height: 8),
              DropdownButtonFormField<AutomationKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final k in kindOptions)
                    DropdownMenuItem(value: k, child: Text(_kindLabel(k))),
                ],
                onChanged: (v) => setState(() => _kind = v ?? _kind),
              ),
              const SizedBox(height: 12),
              if (_kind == AutomationKind.ramp) _buildRamp(),
              if (_kind == AutomationKind.random) _buildRandom(),
              if (_kind == AutomationKind.blink) _buildBlink(),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.param.automation != null)
          TextButton(
            onPressed: _remove,
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Remove'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  String _kindLabel(AutomationKind k) => switch (k) {
        AutomationKind.ramp => 'Ramp',
        AutomationKind.random => 'Random',
        AutomationKind.blink => 'Blink',
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
}
