import 'package:flutter/material.dart';

import 'param_control.dart';

/// toggles for features that are off by default. mutates [config] directly
/// and returns true if something changed, false if cancelled - the caller
/// just needs to persist+refresh on true.
Future<bool> showHiddenFeaturesDialog(BuildContext context, AppConfig config) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => HiddenFeaturesDialog(config: config),
  );
  return result ?? false;
}

class HiddenFeaturesDialog extends StatefulWidget {
  final AppConfig config;
  const HiddenFeaturesDialog({super.key, required this.config});

  @override
  State<HiddenFeaturesDialog> createState() => _HiddenFeaturesDialogState();
}

class _HiddenFeaturesDialogState extends State<HiddenFeaturesDialog> {
  late bool _automationMasterSwitch;

  @override
  void initState() {
    super.initState();
    _automationMasterSwitch = widget.config.showAutomationMasterSwitch;
  }

  void _save() {
    widget.config.showAutomationMasterSwitch = _automationMasterSwitch;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Hidden Features'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Automation Master Switch'),
              subtitle: const Text('Adds a settings entry for enabling/disabling many automations at once.'),
              value: _automationMasterSwitch,
              onChanged: (v) => setState(() => _automationMasterSwitch = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
