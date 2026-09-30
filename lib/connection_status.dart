import 'package:flutter/material.dart';

import 'error_dialog.dart';
import 'live_controller.dart';
import 'osc_input_hub.dart';

bool _isLoopbackHost(String host) {
  final h = host.trim().toLowerCase();
  return h == 'localhost' || h.startsWith('127.') || h == '::1';
}

/// VRChat reported a different input port than the one this app sends to -
/// only meaningful when sending to this same PC.
int? portMismatch(LiveController live, LinkStatus status) {
  final vrcPort = status.vrchatInputPort;
  if (vrcPort == null || vrcPort == 0 || !_isLoopbackHost(live.config.host)) return null;
  return vrcPort == live.config.port ? null : vrcPort;
}

/// the little "is VRChat there" chip in the app bar - OSC itself has no
/// connection, so this combines what the app can actually observe: OSC
/// traffic arriving, VRChat's OSCQuery service answering, and send errors.
class ConnectionChip extends StatelessWidget {
  final LiveController live;
  // just the status dot, for narrow windows.
  final bool compact;

  const ConnectionChip({super.key, required this.live, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([oscInputHub.status, live.osc.lastError, live]),
      builder: (context, _) {
        final status = oscInputHub.status.value;
        final sendError = live.osc.lastError.value;
        final mismatch = portMismatch(live, status);
        final scheme = Theme.of(context).colorScheme;
        final (Color color, String label, String tooltip) = sendError != null
            ? (scheme.error, 'Send error', sendError)
            : mismatch != null
            ? (
                Colors.amber,
                'Port mismatch',
                'VRChat listens on port $mismatch, but you\'re sending to ${live.config.port}',
              )
            : status.receiving
            ? (Colors.green, 'VRChat', 'Receiving OSC from VRChat')
            : status.vrchat != null
            ? (Colors.green, 'VRChat', 'VRChat found (OSCQuery) - no parameter changes received yet')
            : (scheme.outline, 'Not detected', 'VRChat not detected yet - is OSC enabled in VRChat?');
        final dot = Container(
          width: compact ? 14 : 10,
          height: compact ? 14 : 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        );
        if (compact) {
          return IconButton(
            tooltip: '$label - $tooltip',
            icon: dot,
            onPressed: () => showConnectionDetails(context, live),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Tooltip(
            message: tooltip,
            child: ActionChip(
              avatar: dot,
              label: Text(label),
              visualDensity: VisualDensity.compact,
              onPressed: () => showConnectionDetails(context, live),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showConnectionDetails(BuildContext context, LiveController live) {
  oscInputHub.refreshNow();
  return showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([oscInputHub.status, live.osc.lastError]),
      builder: (context, _) {
        final status = oscInputHub.status.value;
        final service = oscInputHub.service;
        final sendError = live.osc.lastError.value;
        final mismatch = portMismatch(live, status);
        final theme = Theme.of(context);

        Widget row(IconData icon, String title, String body, {Color? color, Widget? action}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color ?? theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    SelectableText(body, style: theme.textTheme.bodySmall),
                    ?action,
                  ],
                ),
              ),
            ],
          ),
        );

        final receiving = status.receiving
            ? (status.viaOscQuery
                  ? 'Receiving VRChat\'s output via OSCQuery (port ${service?.oscPort}) - shared nicely with any other OSC apps.'
                  : 'Receiving on port ${oscInputHub.legacyPort} (the classic fixed port).')
            : 'Nothing received yet. VRChat only sends when a parameter changes.';

        final oscQueryLine = service == null
            ? 'Not started.'
            : service.isAdvertising
            ? 'Advertised as "${service.instanceName}" - VRChat sends its output to port ${service.oscPort}.'
            : 'Not fully running:\n${service.error ?? 'unknown error'}';

        return AlertDialog(
          title: const Text('Connection'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row(
                    Icons.north_east,
                    'Sending to ${live.config.host}:${live.config.port}',
                    sendError ?? 'OSC is fire-and-forget, so "no errors" is the best this can confirm.',
                    color: sendError != null ? theme.colorScheme.error : null,
                  ),
                  row(
                    Icons.videogame_asset_outlined,
                    status.vrchat != null ? 'VRChat found' : 'VRChat not found (yet)',
                    status.vrchat != null
                        ? 'OSCQuery at ${status.vrchat!.host}:${status.vrchat!.port}'
                              '${status.vrchatInputPort != null ? ', taking input on port ${status.vrchatInputPort}' : ''}.'
                        : 'VRChat announces itself over mDNS when OSC is enabled. If VRChat is running, check '
                              'Action Menu > Options > OSC > Enabled.',
                    color: status.vrchat != null ? Colors.green : null,
                    action: mismatch == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: FilledButton.tonal(
                              onPressed: () {
                                live.config.port = mismatch;
                                live.persist();
                                live.reconcile();
                              },
                              child: Text('Send to port $mismatch instead'),
                            ),
                          ),
                  ),
                  row(
                    Icons.south_west,
                    status.receiving ? 'Receiving' : 'Not receiving',
                    receiving,
                    color: status.receiving ? Colors.green : null,
                  ),
                  row(Icons.cell_tower, 'This app\'s OSCQuery service', oscQueryLine),
                  if (!status.viaOscQuery && (oscInputHub.legacyListening || oscInputHub.legacyError != null))
                    row(
                      Icons.settings_ethernet,
                      'Fixed port ${oscInputHub.legacyPort}',
                      oscInputHub.legacyListening
                          ? 'Also listening here, for OSC apps without OSCQuery. Released automatically once '
                                'VRChat is found via OSCQuery.'
                          : oscInputHub.legacyError!,
                    ),
                ],
              ),
            ),
          ),
          actions: [
            if (sendError != null)
              TextButton(
                onPressed: () => showErrorDialog(context, 'Send error', sendError),
                child: const Text('Error details'),
              ),
            TextButton(onPressed: oscInputHub.refreshNow, child: const Text('Refresh')),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ],
        );
      },
    ),
  );
}
