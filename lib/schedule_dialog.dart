import 'package:flutter/material.dart';

import 'param_control.dart';

/// shows the schedule editor for [param]. mutates param.schedule directly
/// and returns true if something changed (saved or removed), false if the
/// user cancelled - the caller just needs to persist+refresh on true.
Future<bool> showScheduleDialog(BuildContext context, ParamControl param) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => ScheduleDialog(param: param),
  );
  return result ?? false;
}

class ScheduleDialog extends StatefulWidget {
  final ParamControl param;
  const ScheduleDialog({super.key, required this.param});

  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  late bool _enabled;
  late ScheduleKind _kind;
  late final TextEditingController _hour;
  late final TextEditingController _minute;
  late final TextEditingController _intervalSeconds;
  late final TextEditingController _idleSeconds;
  late final TextEditingController _countdownSeconds;
  late final TextEditingController _targetValue;
  late bool _targetBool;
  late final TextEditingController _revertAfterSeconds;

  bool get _isSlider => widget.param.type == ParamType.slider;

  @override
  void initState() {
    super.initState();
    final e = widget.param.schedule;
    _enabled = e?.enabled ?? false;
    _kind = e?.kind ?? ScheduleKind.timeOfDay;
    _hour = TextEditingController(text: '${e?.timeOfDayHour ?? 21}');
    _minute = TextEditingController(text: '${e?.timeOfDayMinute ?? 0}');
    _intervalSeconds = TextEditingController(text: _fmt(e?.intervalSeconds ?? 1800));
    _idleSeconds = TextEditingController(text: _fmt(e?.idleSeconds ?? 300));
    _countdownSeconds = TextEditingController(text: _fmt(e?.countdownSeconds ?? 60));
    _targetValue = TextEditingController(text: _fmt(e?.targetValue ?? widget.param.max));
    _targetBool = e?.targetBool ?? true;
    _revertAfterSeconds = TextEditingController(text: _fmt(e?.revertAfterSeconds ?? 0));
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _hour.dispose();
    _minute.dispose();
    _intervalSeconds.dispose();
    _idleSeconds.dispose();
    _countdownSeconds.dispose();
    _targetValue.dispose();
    _revertAfterSeconds.dispose();
    super.dispose();
  }

  double _num(TextEditingController c, double fallback) => double.tryParse(c.text) ?? fallback;

  double _positive(TextEditingController c, double fallback) {
    final v = _num(c, fallback).abs();
    return v < 0.05 ? 0.05 : v;
  }

  int _clampInt(TextEditingController c, int fallback, int min, int max) {
    final v = int.tryParse(c.text) ?? fallback;
    return v.clamp(min, max);
  }

  void _save() {
    widget.param.schedule = ParamSchedule(
      enabled: _enabled,
      kind: _kind,
      timeOfDayHour: _clampInt(_hour, 21, 0, 23),
      timeOfDayMinute: _clampInt(_minute, 0, 0, 59),
      intervalSeconds: _positive(_intervalSeconds, 1800),
      idleSeconds: _positive(_idleSeconds, 300),
      countdownSeconds: _positive(_countdownSeconds, 60),
      targetValue: _num(_targetValue, widget.param.max),
      targetBool: _targetBool,
      revertAfterSeconds: _num(_revertAfterSeconds, 0).abs(),
    );
    Navigator.of(context).pop(true);
  }

  void _remove() {
    widget.param.schedule = null;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Schedule "${widget.param.label}"'),
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
              DropdownButtonFormField<ScheduleKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Trigger'),
                items: const [
                  DropdownMenuItem(value: ScheduleKind.timeOfDay, child: Text('Time of day (once daily)')),
                  DropdownMenuItem(value: ScheduleKind.interval, child: Text('Interval (repeating)')),
                  DropdownMenuItem(value: ScheduleKind.idle, child: Text('Idle (no interaction for a while)')),
                  DropdownMenuItem(value: ScheduleKind.countdown, child: Text('Countdown (once, after a delay)')),
                ],
                onChanged: (v) => setState(() => _kind = v ?? _kind),
              ),
              const SizedBox(height: 8),
              ..._kindFields(),
              const Divider(height: 24),
              if (_isSlider)
                TextField(
                  controller: _targetValue,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(labelText: 'Set value to'),
                )
              else
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Set to'),
                  subtitle: Text(_targetBool ? 'On' : 'Off'),
                  value: _targetBool,
                  onChanged: (v) => setState(() => _targetBool = v),
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
          ),
        ),
      ),
      actions: [
        if (widget.param.schedule != null)
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

  List<Widget> _kindFields() {
    switch (_kind) {
      case ScheduleKind.timeOfDay:
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
        ];
      case ScheduleKind.interval:
        return [
          TextField(
            controller: _intervalSeconds,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Every (seconds)'),
          ),
        ];
      case ScheduleKind.idle:
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
      case ScheduleKind.countdown:
        return [
          TextField(
            controller: _countdownSeconds,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Fire once after (seconds)'),
          ),
        ];
    }
  }
}
