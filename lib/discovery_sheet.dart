import 'package:flutter/material.dart';

import 'live_param_listener.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';

/// the discover popup shared by the main screen, sequence editor, and
/// snapshot editor - search/add found parameters, add one manually, and
/// "highlight active parameters" live listening. each caller only supplies
/// how a newly-picked [ParamControl] actually gets added to its own list.
Future<void> showDiscoveryResultsSheet(
  BuildContext context, {
  required List<DiscoveredParam> found,
  required bool autoStartLive,
  required bool fetchFailed,
  required String? failureDetail,
  required bool developerMode,
  required int avatarChangeListenPort,
  required int noiseThreshold,
  required Set<String> existingNames,
  required void Function(ParamControl control) onAdd,
}) async {
  final added = <String>{};
  var query = '';

  // "highlight active parameters" - a temporary listener, only running
  // while this popup is open, that surfaces parameters as they actually
  // change in VRChat instead of making someone hunt through a long list.
  var liveMode = false;
  final tracker = LiveParamTracker(found, noiseThreshold: noiseThreshold);
  LiveParamListener? liveListener;
  void Function(void Function())? currentSetSheetState;

  Future<bool> startLive() async {
    final listener = LiveParamListener(
      port: avatarChangeListenPort,
      onParamChanged: (name, type) {
        tracker.handleChange(name, type);
        currentSetSheetState?.call(() {});
      },
    );
    final ok = await listener.start();
    if (ok) liveListener = listener;
    return ok;
  }

  if (autoStartLive) liveMode = await startLive();
  if (!context.mounted) return;

  void addControl(String name, ParamType type, void Function(void Function()) setSheetState) {
    onAdd(ParamControl(name: name, label: name.split('/').last, type: type));
    setSheetState(() => added.add(name));
  }

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          currentSetSheetState = setSheetState;
          final base = query.isEmpty
              ? tracker.workingList
              : tracker.workingList.where((p) => p.name.toLowerCase().contains(query.toLowerCase())).toList();
          // recently-changed parameters float to the top, most recent first.
          final filtered = tracker.sorted(base);
          return DraggableScrollableSheet(
            initialChildSize: 0.7,
            expand: false,
            builder: (context, scrollController) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SearchBar(
                            hintText: 'Search found parameters',
                            leading: const Icon(Icons.search),
                            onChanged: (v) => setSheetState(() => query = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: 'Add a custom parameter path manually',
                          icon: const Icon(Icons.add),
                          onPressed: () async {
                            final result = await showParamFormDialog(context);
                            if (result == null) return;
                            onAdd(result);
                            setSheetState(() => added.add(result.name));
                          },
                        ),
                      ],
                    ),
                  ),
                  if (fetchFailed)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        "Couldn't load the full parameter list automatically - VRChat's OSCQuery "
                        'server didn\'t respond in time (this can happen with especially complex '
                        'avatars). Move something on your avatar and it\'ll show up below.'
                        '${developerMode && failureDetail != null ? '\n\n$failureDetail' : ''}',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.sensors,
                          size: 20,
                          color: liveMode ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Highlight active parameters - move something in VRChat to find its name',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        Switch(
                          value: liveMode,
                          onChanged: (v) async {
                            if (v) {
                              final ok = await startLive();
                              if (!ok) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                    content: Text('Could not start listening - the port might already be in use.'),
                                  ));
                                }
                                return;
                              }
                              setSheetState(() => liveMode = true);
                            } else {
                              liveListener?.stop();
                              liveListener = null;
                              setSheetState(() => liveMode = false);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('No matching parameters found.'))
                        : ListView(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: [
                              for (final p in filtered)
                                ListTile(
                                  leading: tracker.lastChanged.containsKey(p.name)
                                      ? Icon(Icons.circle, size: 10, color: Theme.of(context).colorScheme.tertiary)
                                      : null,
                                  title: Text(p.name.split('/').last),
                                  subtitle: Text(
                                    '${p.type == ParamType.toggle ? 'toggle' : 'slider'} - ${p.name}',
                                  ),
                                  trailing: existingNames.contains(p.name) || added.contains(p.name)
                                      ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                                      : IconButton(
                                          icon: const Icon(Icons.add_circle_outline),
                                          onPressed: () => addControl(p.name, p.type, setSheetState),
                                        ),
                                ),
                            ],
                          ),
                  ),
                ],
              );
            },
          );
        },
      );
    },
  );
  liveListener?.stop();
}
