import 'package:flutter/material.dart';

import 'param_control.dart';

/// full-page editor for one sequence's steps. mutates [sequence] directly -
/// the caller (Settings) persists after this page is popped.
class SequenceEditorPage extends StatefulWidget {
  final AutomationSequence sequence;
  final List<ParamControl> parameters;
  const SequenceEditorPage({super.key, required this.sequence, required this.parameters});

  @override
  State<SequenceEditorPage> createState() => _SequenceEditorPageState();
}

class _SequenceEditorPageState extends State<SequenceEditorPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _repeatCountController;

  AutomationSequence get seq => widget.sequence;

  // only sliders/toggles are settable step targets - custom-type params have
  // no single "value" this app can drive.
  List<ParamControl> get _eligibleParams =>
      widget.parameters.where((p) => p.type == ParamType.slider || p.type == ParamType.toggle).toList();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: seq.name);
    _repeatCountController = TextEditingController(text: '${seq.repeatCount}');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _repeatCountController.dispose();
    super.dispose();
  }

  void _renameSequence(String value) {
    setState(() => seq.name = value.trim().isEmpty ? seq.name : value.trim());
  }

  void _setRepeatMode(SequenceRepeatMode mode) {
    setState(() => seq.repeatMode = mode);
  }

  void _setRepeatCount(String value) {
    setState(() => seq.repeatCount = int.tryParse(value)?.clamp(0, 1000000) ?? 0);
  }

  void _setEnabled(bool value) {
    setState(() => seq.enabled = value);
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final step = seq.steps.removeAt(oldIndex);
      seq.steps.insert(newIndex, step);
    });
  }

  Future<void> _addStep() async {
    if (_eligibleParams.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No slider/toggle parameters to target yet.')));
      return;
    }
    final step = await _showStepDialog(context, null, _eligibleParams);
    if (step != null) setState(() => seq.steps.add(step));
  }

  Future<void> _editStep(int index) async {
    final result = await _showStepDialog(context, seq.steps[index], _eligibleParams);
    if (result == null) return;
    // mutate the existing step in place (rather than replacing it) so its
    // identity - and the reorderable list's key for it - stays stable.
    setState(() {
      final step = seq.steps[index];
      step.kind = result.kind;
      step.paramName = result.paramName;
      step.targetValue = result.targetValue;
      step.targetBool = result.targetBool;
      step.durationSeconds = result.durationSeconds;
    });
  }

  void _deleteStep(int index) {
    setState(() => seq.steps.removeAt(index));
  }

  String _stepSummary(SequenceStep step) {
    if (step.kind == SequenceStepKind.wait) {
      return 'Wait ${_fmt(step.durationSeconds)}s';
    }
    final param = _eligibleParams.where((p) => p.name == step.paramName).firstOrNull;
    final label = param?.label ?? step.paramName;
    if (param?.type == ParamType.toggle) {
      return 'Set "$label" to ${step.targetBool ? 'on' : 'off'}, hold ${_fmt(step.durationSeconds)}s';
    }
    return 'Set "$label" to ${_fmt(step.targetValue)} over ${_fmt(step.durationSeconds)}s';
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Sequence')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                    onSubmitted: _renameSequence,
                    onTapOutside: (_) => _renameSequence(_nameController.text),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(child: Text('Running')),
                      Switch(value: seq.enabled, onChanged: _setEnabled),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<SequenceRepeatMode>(
                    initialValue: seq.repeatMode,
                    decoration: const InputDecoration(labelText: 'Repeat'),
                    items: const [
                      DropdownMenuItem(value: SequenceRepeatMode.once, child: Text('Once through')),
                      DropdownMenuItem(value: SequenceRepeatMode.loop, child: Text('Loop from step 1')),
                    ],
                    onChanged: (v) => _setRepeatMode(v ?? SequenceRepeatMode.once),
                  ),
                  if (seq.repeatMode == SequenceRepeatMode.loop) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _repeatCountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Repeat count (0 = forever)'),
                      onSubmitted: _setRepeatCount,
                      onTapOutside: (_) => _setRepeatCount(_repeatCountController.text),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Steps', style: Theme.of(context).textTheme.titleLarge),
                      TextButton.icon(onPressed: _addStep, icon: const Icon(Icons.add), label: const Text('Add step')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (seq.steps.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No steps yet - add one to start scripting this sequence.'),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverReorderableList(
                itemCount: seq.steps.length,
                onReorderItem: _reorder,
                itemBuilder: (context, index) {
                  final step = seq.steps[index];
                  return Card(
                    key: ValueKey(identityHashCode(step)),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: const Icon(Icons.drag_handle),
                      ),
                      title: Text('${index + 1}. ${_stepSummary(step)}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(icon: const Icon(Icons.edit), onPressed: () => _editStep(index)),
                          IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteStep(index)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

Future<SequenceStep?> _showStepDialog(
  BuildContext context,
  SequenceStep? existing,
  List<ParamControl> eligibleParams,
) {
  return showDialog<SequenceStep>(
    context: context,
    builder: (context) => _StepDialog(existing: existing, eligibleParams: eligibleParams),
  );
}

class _StepDialog extends StatefulWidget {
  final SequenceStep? existing;
  final List<ParamControl> eligibleParams;
  const _StepDialog({required this.existing, required this.eligibleParams});

  @override
  State<_StepDialog> createState() => _StepDialogState();
}

class _StepDialogState extends State<_StepDialog> {
  late SequenceStepKind _kind;
  late String _paramName;
  late final TextEditingController _targetValue;
  late bool _targetBool;
  late final TextEditingController _duration;

  ParamControl? get _param => widget.eligibleParams.where((p) => p.name == _paramName).firstOrNull;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? SequenceStepKind.setValue;
    _paramName = e?.paramName ?? widget.eligibleParams.first.name;
    _targetValue = TextEditingController(text: _fmt(e?.targetValue ?? widget.eligibleParams.first.max));
    _targetBool = e?.targetBool ?? true;
    _duration = TextEditingController(text: _fmt(e?.durationSeconds ?? 1.0));
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _targetValue.dispose();
    _duration.dispose();
    super.dispose();
  }

  void _save() {
    final param = _param;
    Navigator.of(context).pop(SequenceStep(
      kind: _kind,
      paramName: _kind == SequenceStepKind.setValue ? _paramName : '',
      targetValue: double.tryParse(_targetValue.text) ?? param?.max ?? 1.0,
      targetBool: _targetBool,
      durationSeconds: (double.tryParse(_duration.text) ?? 1.0).abs(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final param = _param;
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Step' : 'Edit Step'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<SequenceStepKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Step type'),
              items: const [
                DropdownMenuItem(value: SequenceStepKind.setValue, child: Text('Set a parameter\'s value')),
                DropdownMenuItem(value: SequenceStepKind.wait, child: Text('Wait')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            if (_kind == SequenceStepKind.setValue) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _paramName,
                decoration: const InputDecoration(labelText: 'Parameter'),
                items: [
                  for (final p in widget.eligibleParams) DropdownMenuItem(value: p.name, child: Text(p.label)),
                ],
                onChanged: (v) => setState(() => _paramName = v ?? _paramName),
              ),
              const SizedBox(height: 8),
              if (param?.type == ParamType.toggle)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Set to'),
                  subtitle: Text(_targetBool ? 'On' : 'Off'),
                  value: _targetBool,
                  onChanged: (v) => setState(() => _targetBool = v),
                )
              else
                TextField(
                  controller: _targetValue,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(labelText: 'Target value'),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _duration,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: param?.type == ParamType.toggle ? 'Hold for (seconds)' : 'Glide over (seconds)',
                  helperText: param?.type == ParamType.toggle
                      ? 'Toggles snap instantly, then this step holds before advancing'
                      : '0 = snap instantly',
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              TextField(
                controller: _duration,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Duration (seconds)'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
