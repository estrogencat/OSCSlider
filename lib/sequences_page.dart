import 'package:flutter/material.dart';

import 'osc_client.dart';
import 'param_control.dart';
import 'sequence_editor_page.dart';

/// hub page listing the active profile's sequences - moved out of Settings
/// since each sequence's editor now embeds a full parameter/automation
/// panel and needed its own dedicated space instead of a scroll section.
class SequencesPage extends StatefulWidget {
  final AppConfig config;
  // shared with the main screen - the same live values/controllers/OSC
  // client, so editing a parameter from in here behaves identically to
  // editing it there.
  final Map<String, Object> values;
  final Map<String, TextEditingController> sliderTextControllers;
  final Map<String, TextEditingController> customValueControllers;
  final OscClient? osc;
  final bool advancedMode;
  final bool developerMode;
  final VoidCallback onPersist;
  final void Function(ParamControl param) onInteraction;

  const SequencesPage({
    super.key,
    required this.config,
    required this.values,
    required this.sliderTextControllers,
    required this.customValueControllers,
    required this.osc,
    required this.advancedMode,
    required this.developerMode,
    required this.onPersist,
    required this.onInteraction,
  });

  @override
  State<SequencesPage> createState() => _SequencesPageState();
}

class _SequencesPageState extends State<SequencesPage> {
  AppConfig get config => widget.config;

  void _addSequence() {
    final sequence = AutomationSequence(id: DateTime.now().millisecondsSinceEpoch.toString(), name: 'New Sequence');
    setState(() => config.sequences.add(sequence));
    widget.onPersist();
    _openSequenceEditor(sequence);
  }

  Future<void> _openSequenceEditor(AutomationSequence sequence) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SequenceEditorPage(
        sequence: sequence,
        config: config,
        values: widget.values,
        sliderTextControllers: widget.sliderTextControllers,
        customValueControllers: widget.customValueControllers,
        osc: widget.osc,
        advancedMode: widget.advancedMode,
        developerMode: widget.developerMode,
        onPersist: widget.onPersist,
        onInteraction: widget.onInteraction,
      ),
    ));
    // the editor mutates the sequence in place via setState only (name,
    // repeat, trigger, steps) - this is the one point that actually saves it.
    setState(() {});
    widget.onPersist();
  }

  void _setSequenceEnabled(AutomationSequence sequence, bool value) {
    setState(() => sequence.enabled = value);
    widget.onPersist();
  }

  Future<void> _deleteSequence(AutomationSequence sequence) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete sequence?'),
        content: Text('Remove "${sequence.name}" and its ${sequence.steps.length} steps?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => config.sequences.remove(sequence));
    widget.onPersist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sequences'),
        actions: [
          IconButton(onPressed: _addSequence, icon: const Icon(Icons.add), tooltip: 'New sequence'),
        ],
      ),
      body: config.sequences.isEmpty
          ? const Center(child: Text('No sequences yet. Tap + to create one.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final sequence in config.sequences)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      onTap: () => _openSequenceEditor(sequence),
                      title: Text(sequence.name),
                      subtitle: Text('${sequence.steps.length} steps'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: sequence.enabled,
                            onChanged: (v) => _setSequenceEnabled(sequence, v),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteSequence(sequence),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
