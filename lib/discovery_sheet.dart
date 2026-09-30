import 'package:flutter/material.dart';

import 'discovery_flow.dart';
import 'error_dialog.dart';
import 'live_param_listener.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';

/// the discover popup shared by the main screen, sequence editor, and
/// snapshot editor - search/add found parameters, add one manually, and
/// "highlight active parameters" live listening. each caller only supplies
/// how a newly-picked [ParamControl] actually gets added to its own list
/// ([onAdd] returns false if that name is already there).
Future<void> showDiscoveryResultsSheet(
  BuildContext context, {
  required DiscoveryResult result,
  required int noiseThreshold,
  required Set<String> existingNames,
  required bool Function(ParamControl control) onAdd,
}) async {
  final added = <String>{};
  var query = '';
  var showReadOnly = false;

  // "highlight active parameters" - a temporary listener, only running
  // while this popup is open, that surfaces parameters as they actually
  // change in VRChat instead of making someone hunt through a long list.
  var liveMode = false;
  final tracker = LiveParamTracker(result.params, noiseThreshold: noiseThreshold);
  LiveParamListener? liveListener;
  void Function(void Function())? currentSetSheetState;

  Future<bool> startLive() async {
    final listener = LiveParamListener(
      onParamChanged: (name, kind) {
        if (tracker.handleChange(name, kind)) currentSetSheetState?.call(() {});
      },
    );
    final ok = await listener.start();
    if (ok) liveListener = listener;
    return ok;
  }

  // the list isn't the authoritative live one - help find things by moving them.
  if (result.source != DiscoverySource.oscQuery) liveMode = await startLive();
  if (!context.mounted) {
    liveListener?.stop();
    return;
  }

  bool isAdded(String name) => existingNames.contains(name) || added.contains(name);

  void addOne(DiscoveredParam p) {
    if (onAdd(p.toControl())) added.add(p.name);
  }

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 760),
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          currentSetSheetState = setSheetState;
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final lower = query.toLowerCase();
          final base = tracker.workingList
              .where((p) => showReadOnly || !p.readOnly || tracker.lastChanged.containsKey(p.name))
              .where((p) => lower.isEmpty || p.name.toLowerCase().contains(lower))
              .toList();
          // recently-changed parameters float to the top, most recent first.
          final filtered = tracker.sorted(base);
          final addable = filtered.where((p) => !isAdded(p.name) && !p.readOnly).toList();
          final hiddenReadOnly = showReadOnly ? 0 : tracker.workingList.where((p) => p.readOnly).length;

          return DraggableScrollableSheet(
            initialChildSize: 0.8,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            expand: false,
            builder: (context, scrollController) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        Expanded(child: Text('Discover parameters', style: theme.textTheme.titleLarge)),
                        _SourceChip(result: result),
                      ],
                    ),
                  ),
                  if (result.problem != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                        decoration: BoxDecoration(
                          color: result.source == DiscoverySource.none
                              ? scheme.errorContainer
                              : scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              result.source == DiscoverySource.none ? Icons.error_outline : Icons.info_outline,
                              size: 20,
                              color: result.source == DiscoverySource.none
                                  ? scheme.onErrorContainer
                                  : scheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                result.problem!,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: result.source == DiscoverySource.none
                                      ? scheme.onErrorContainer
                                      : scheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                            if (result.detail != null)
                              TextButton(
                                onPressed: () => showErrorDialog(context, 'Details', result.detail!),
                                child: const Text('Details'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SearchBar(
                            hintText: 'Search found parameters',
                            leading: const Icon(Icons.search),
                            elevation: const WidgetStatePropertyAll(0),
                            onChanged: (v) => setSheetState(() => query = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          tooltip: 'Add a parameter by hand',
                          icon: const Icon(Icons.edit_note),
                          onPressed: () async {
                            final control = await showParamFormDialog(
                              context,
                              takenNames: {...existingNames, ...added},
                            );
                            if (control == null) return;
                            if (onAdd(control)) setSheetState(() => added.add(control.name));
                          },
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilterChip(
                          avatar: Icon(Icons.sensors, size: 18, color: liveMode ? scheme.onSecondaryContainer : null),
                          label: const Text('Highlight active'),
                          tooltip: 'Move something on your avatar in VRChat and its parameter jumps to the top',
                          selected: liveMode,
                          showCheckmark: false,
                          onSelected: (v) async {
                            if (v) {
                              final ok = await startLive();
                              if (!ok) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                    content: Text('Could not start listening for VRChat\'s OSC output.'),
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
                        FilterChip(
                          label: Text(showReadOnly || hiddenReadOnly == 0
                              ? 'Built-ins shown'
                              : 'Show $hiddenReadOnly built-ins'),
                          tooltip: 'VRChat\'s own read-only parameters (Grounded, AFK, Velocity...) - '
                              'can\'t be set, but work as trigger sources',
                          selected: showReadOnly,
                          onSelected: (v) => setSheetState(() => showReadOnly = v),
                        ),
                        if (addable.length > 1)
                          TextButton.icon(
                            icon: const Icon(Icons.playlist_add),
                            label: Text('Add all ${addable.length}'),
                            onPressed: () => setSheetState(() {
                              for (final p in addable) {
                                addOne(p);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                liveMode
                                    ? 'Listening... move something on your avatar in VRChat.'
                                    : 'No matching parameters found.',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final p = filtered[i];
                              final done = isAdded(p.name);
                              final highlighted = tracker.lastChanged.containsKey(p.name);
                              return ListTile(
                                dense: true,
                                leading: SizedBox(
                                  width: 24,
                                  child: highlighted
                                      ? Icon(Icons.circle, size: 10, color: scheme.tertiary)
                                      : Icon(_kindIcon(p.kind), size: 20, color: scheme.onSurfaceVariant),
                                ),
                                title: Text(p.name.split('/').last),
                                subtitle: Text(
                                  [
                                    _kindLabel(p.kind),
                                    if (p.readOnly) 'read-only',
                                    if (p.value != null) '= ${_valueLabel(p.value!)}',
                                    if (p.name.contains('/')) p.name,
                                  ].join('  ·  '),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: done ? null : () => setSheetState(() => addOne(p)),
                                trailing: done
                                    ? Icon(Icons.check, color: scheme.primary)
                                    : IconButton(
                                        icon: const Icon(Icons.add_circle_outline),
                                        tooltip: 'Add',
                                        onPressed: () => setSheetState(() => addOne(p)),
                                      ),
                              );
                            },
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
  currentSetSheetState = null;
  liveListener?.stop();
}

IconData _kindIcon(DiscoveredKind kind) => switch (kind) {
      DiscoveredKind.bool => Icons.toggle_on_outlined,
      DiscoveredKind.int => Icons.pin_outlined,
      DiscoveredKind.float => Icons.linear_scale,
    };

String _kindLabel(DiscoveredKind kind) => switch (kind) {
      DiscoveredKind.bool => 'toggle',
      DiscoveredKind.int => 'int',
      DiscoveredKind.float => 'float',
    };

String _valueLabel(Object v) {
  if (v is double) return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(3);
  if (v is bool) return v ? 'on' : 'off';
  return '$v';
}

class _SourceChip extends StatelessWidget {
  final DiscoveryResult result;
  const _SourceChip({required this.result});

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (result.source) {
      DiscoverySource.oscQuery => (Icons.wifi_tethering, 'Live from VRChat'),
      DiscoverySource.avatarFile => (
          Icons.description_outlined,
          result.avatarName != null ? 'Saved config: ${result.avatarName}' : 'Saved avatar config',
        ),
      DiscoverySource.none => (Icons.search_off, 'Nothing loaded'),
    };
    return Chip(
      avatar: Icon(icon, size: 18),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Text(label, overflow: TextOverflow.ellipsis),
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}
