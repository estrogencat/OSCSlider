import 'package:flutter/material.dart';

import 'error_dialog.dart';
import 'live_controller.dart';
import 'param_control.dart';
import 'sequence_editor_page.dart';

/// hub page listing the active profile's sequences - moved out of Settings
/// since each sequence's editor embeds a full parameter/automation panel
/// and needed its own dedicated space instead of a scroll section.
class SequencesPage extends StatefulWidget {
  final LiveController live;

  const SequencesPage({super.key, required this.live});

  @override
  State<SequencesPage> createState() => _SequencesPageState();
}

class _SequencesPageState extends State<SequencesPage> {
  LiveController get live => widget.live;
  AppConfig get config => live.config;

  void _addSequence() {
    final sequence = AutomationSequence(id: newId(), name: 'Sequence ${config.sequences.length + 1}');
    config.sequences.add(sequence);
    live.persist();
    _openSequenceEditor(sequence);
  }

  Future<void> _openSequenceEditor(AutomationSequence sequence) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SequenceEditorPage(sequence: sequence, live: live),
    ));
    live.persist();
    live.reconcile();
  }

  void _duplicate(AutomationSequence sequence) {
    final copy = AutomationSequence.fromJson(sequence.toJson())
      ..id = newId()
      ..name = '${sequence.name} (copy)'
      ..enabled = false;
    config.sequences.insert(config.sequences.indexOf(sequence) + 1, copy);
    live.persist();
    live.reconcile();
  }

  Future<void> _deleteSequence(AutomationSequence sequence) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete sequence?',
      message: 'Remove "${sequence.name}" and its ${sequence.steps.length} steps?',
    );
    if (!ok) return;
    config.sequences.remove(sequence);
    live.persist();
    live.reconcile();
  }

  String _summary(AutomationSequence s) {
    final parts = <String>[
      '${s.steps.length} step${s.steps.length == 1 ? '' : 's'}',
      if (s.repeatMode == SequenceRepeatMode.loop) s.repeatCount == 0 ? 'loops forever' : 'loops ${s.repeatCount}x',
      if (s.paramAutomations.isNotEmpty) '${s.paramAutomations.length} automation${s.paramAutomations.length == 1 ? '' : 's'}',
      if (s.trigger?.enabled ?? false) 'triggered by ${s.trigger!.watchedParamName}',
    ];
    return parts.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text('Sequences - ${config.activeProfile.name}')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _addSequence,
          icon: const Icon(Icons.add),
          label: const Text('New sequence'),
        ),
        body: config.sequences.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No sequences yet.\nA sequence scripts several parameter changes in order - set a value, '
                    'wait, set another...',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              )
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    children: [
                      for (final sequence in config.sequences)
                        Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: ListTile(
                            onTap: () => _openSequenceEditor(sequence),
                            leading: Icon(
                              sequence.enabled ? Icons.play_circle : Icons.playlist_play,
                              color: sequence.enabled ? Theme.of(context).colorScheme.primary : null,
                            ),
                            title: Text(sequence.name),
                            subtitle: Text(_summary(sequence)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: sequence.enabled,
                                  onChanged: (v) {
                                    sequence.enabled = v;
                                    live.persist();
                                    live.reconcile();
                                  },
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'duplicate') _duplicate(sequence);
                                    if (v == 'delete') _deleteSequence(sequence);
                                  },
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
