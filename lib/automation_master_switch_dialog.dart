import 'package:flutter/material.dart';

import 'param_control.dart';

/// params a sequence is ACTUALLY driving right now (see
/// sequenceActivelyDrivesParam) - the master switch must never touch these,
/// since enabling the parameter's own global automation would fight the
/// sequence for the same value. paused/disabled entries don't count, so
/// they're still fair game.
Set<String> _sequenceDrivenParamNames(AppConfig config) => {
      for (final s in config.sequences)
        for (final entry in s.paramAutomations.entries)
          if (sequenceActivelyDrivesParam(s, entry.key)) entry.key,
    };

// true for "holds" conditions (whileOn/whileOff/above/below/inRange/
// outOfRange) - these continuously re-force enabled to match the watched
// value, which would silently undo the master switch right after it runs.
bool _isGateTrigger(ParamTrigger trig, List<ParamControl> parameters) {
  ParamControl? watched;
  for (final p in parameters) {
    if (p.name == trig.watchedParamName) {
      watched = p;
      break;
    }
  }
  if (watched == null) return false;
  if (watched.type == ParamType.toggle) {
    return trig.toggleCondition == ToggleTriggerCondition.whileOn ||
        trig.toggleCondition == ToggleTriggerCondition.whileOff;
  }
  if (watched.type == ParamType.slider) {
    return trig.rangeCondition == RangeTriggerCondition.above ||
        trig.rangeCondition == RangeTriggerCondition.below ||
        trig.rangeCondition == RangeTriggerCondition.inRange ||
        trig.rangeCondition == RangeTriggerCondition.outOfRange;
  }
  return false;
}

/// every parameter with a global automation, minus anything a sequence is
/// (or could be) driving instead, and minus anything a "holds" trigger is
/// already continuously controlling - the pool the master switch is allowed
/// to pick from at all.
List<ParamControl> _eligibleAutomatedParams(AppConfig config) {
  final sequenceDriven = _sequenceDrivenParamNames(config);
  return config.parameters.where((p) {
    final auto = p.automation;
    if (auto == null || sequenceDriven.contains(p.name)) return false;
    final trig = auto.trigger;
    if (trig != null && trig.enabled && _isGateTrigger(trig, config.parameters)) return false;
    return true;
  }).toList();
}

/// the parameters the master switch currently covers - every eligible
/// automated parameter, or just the saved subset, depending on
/// automationMasterSwitchAll.
List<ParamControl> automationMasterSwitchTargets(AppConfig config) {
  final eligible = _eligibleAutomatedParams(config);
  if (config.automationMasterSwitchAll) return eligible;
  return eligible.where((p) => config.automationMasterSwitchParams.contains(p.name)).toList();
}

/// true only if every covered automation is currently enabled - so the
/// switch reads as "on" exactly when it would be a no-op to flip it on.
bool automationMasterSwitchAggregate(AppConfig config) {
  final targets = automationMasterSwitchTargets(config);
  if (targets.isEmpty) return false;
  return targets.every((p) => p.automation!.enabled);
}

/// one-time bulk action, not a persistent override - each automation's own
/// Enabled switch still works normally again right after this runs.
void applyAutomationMasterSwitch(AppConfig config, bool value) {
  for (final p in automationMasterSwitchTargets(config)) {
    p.automation!.enabled = value;
  }
}

/// bulk enable/disable for every automation (or a chosen subset) in the
/// active profile - a one-time action, not a persistent override, so each
/// automation's own Enabled switch still works normally afterward. mutates
/// [config] directly and returns true if saved, false if cancelled.
Future<bool> showAutomationMasterSwitchDialog(BuildContext context, AppConfig config) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AutomationMasterSwitchDialog(config: config),
  );
  return result ?? false;
}

class AutomationMasterSwitchDialog extends StatefulWidget {
  final AppConfig config;
  const AutomationMasterSwitchDialog({super.key, required this.config});

  @override
  State<AutomationMasterSwitchDialog> createState() => _AutomationMasterSwitchDialogState();
}

class _AutomationMasterSwitchDialogState extends State<AutomationMasterSwitchDialog> {
  late bool _all;
  late Set<String> _selected;
  late bool _switchOn;

  AppConfig get config => widget.config;
  List<ParamControl> get _automatedParams => _eligibleAutomatedParams(config);

  @override
  void initState() {
    super.initState();
    _all = config.automationMasterSwitchAll;
    _selected = config.automationMasterSwitchParams.toSet();
    _switchOn = _computeAggregate();
  }

  List<ParamControl> _targets() =>
      _all ? _automatedParams : _automatedParams.where((p) => _selected.contains(p.name)).toList();

  bool _computeAggregate() {
    final targets = _targets();
    if (targets.isEmpty) return false;
    return targets.every((p) => p.automation!.enabled);
  }

  void _save() {
    config.automationMasterSwitchAll = _all;
    config.automationMasterSwitchParams = _selected.toList();
    applyAutomationMasterSwitch(config, _switchOn);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final automated = _automatedParams;
    return AlertDialog(
      title: const Text('Automation Master Switch'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (automated.isEmpty)
                const Text(
                  'No parameters have a global automation configured yet (parameters only driven by a '
                  'sequence, or continuously held by a "while on/off"-style trigger, don\'t count - '
                  'manage those directly instead).',
                )
              else ...[
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('All automations')),
                    ButtonSegment(value: false, label: Text('Specific')),
                  ],
                  selected: {_all},
                  onSelectionChanged: (s) => setState(() {
                    _all = s.first;
                    _switchOn = _computeAggregate();
                  }),
                ),
                if (!_all)
                  ...automated.map((p) => CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(p.label),
                        value: _selected.contains(p.name),
                        onChanged: (v) => setState(() {
                          if (v ?? false) {
                            _selected.add(p.name);
                          } else {
                            _selected.remove(p.name);
                          }
                          _switchOn = _computeAggregate();
                        }),
                      )),
                const Divider(height: 24),
                Row(
                  children: [
                    const Expanded(child: Text('Automations enabled')),
                    Switch(value: _switchOn, onChanged: (v) => setState(() => _switchOn = v)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        if (automated.isNotEmpty) FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
