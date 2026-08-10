import 'package:flutter/material.dart';

/// shown whenever an OSCQuery search completed cleanly but found nothing -
/// there's no lower-level error to show in this case (mDNS genuinely just
/// got zero responses), so this is the most specific true statement available.
const oscNotFoundExplanation =
    'No response within the search window. Is your VRC/OSC program running with OSC enabled?';

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
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    ),
  );
}
