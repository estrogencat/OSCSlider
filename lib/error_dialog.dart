import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// shown whenever an OSCQuery search completed cleanly but found nothing -
/// there's no lower-level error to show in this case (mDNS genuinely just
/// got zero responses), so this is the most specific true statement available.
const oscNotFoundExplanation =
    'No response within the search window. Is VRChat (or your OSC program) running with OSC enabled? '
    'In VRChat: Action Menu > Options > OSC > Enabled.';

/// shows a full, unabridged error in a scrollable, selectable dialog instead
/// of a snackbar - a toast clips/wraps long technical error text awkwardly
/// and offers no way to read or copy all of it.
Future<void> showErrorDialog(BuildContext context, String title, String message) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(child: SelectableText(message)),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: '$title\n$message')),
          child: const Text('Copy'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    ),
  );
}

/// a plain yes/no confirmation - true only if confirmed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
