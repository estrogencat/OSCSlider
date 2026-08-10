import 'package:flutter/material.dart';

/// confirmation shown the first time Developer Mode is turned on. returns
/// null if cancelled, or the "don't show again" checkbox's final state if
/// confirmed (always non-null on confirm, even when left unchecked).
Future<bool?> showDeveloperModeDialog(BuildContext context) {
  return showDialog<bool>(context: context, builder: (context) => const _DeveloperModeDialog());
}

/// confirmation shown when tapping the version number 5 more times while
/// Developer Mode is already unlocked - true if the user chose to disable
/// and re-hide it, false/null if cancelled.
Future<bool?> showDisableDeveloperModeDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Disable Developer Mode?'),
      content: const Text(
        'This turns Developer Mode off and hides its switch again. Tap the '
        'version number 5 times to bring it back.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Disable & Hide')),
      ],
    ),
  );
}

class _DeveloperModeDialog extends StatefulWidget {
  const _DeveloperModeDialog();

  @override
  State<_DeveloperModeDialog> createState() => _DeveloperModeDialogState();
}

class _DeveloperModeDialogState extends State<_DeveloperModeDialog> {
  bool _dontShowAgain = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enable Developer Mode?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Shows full-precision slider values, and lets parameter discovery and '
            'fetching find any OSCQuery-advertising program instead of requiring '
            'one that identifies itself as VRChat - useful for testing against '
            'other OSC tools. More developer features will land here over time.',
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text("Don't show this again"),
            value: _dontShowAgain,
            onChanged: (v) => setState(() => _dontShowAgain = v ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_dontShowAgain), child: const Text('Enable')),
      ],
    );
  }
}
