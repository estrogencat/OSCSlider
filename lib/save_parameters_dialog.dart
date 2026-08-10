import 'package:flutter/material.dart';

import 'param_control.dart';

/// snapshots the checked parameters' current live values into a new,
/// isSnapshot profile - a static save, not touched by auto mode or live
/// reconciliation, meant to be restored later via a snapshot's Apply button.
/// returns the new profile, or null if cancelled.
Future<Profile?> showSaveParametersDialog(
  BuildContext context,
  List<ParamControl> parameters,
  Map<String, Object> values,
) {
  return showDialog<Profile>(
    context: context,
    builder: (context) => SaveParametersDialog(parameters: parameters, values: values),
  );
}

class SaveParametersDialog extends StatefulWidget {
  final List<ParamControl> parameters;
  final Map<String, Object> values;
  const SaveParametersDialog({super.key, required this.parameters, required this.values});

  @override
  State<SaveParametersDialog> createState() => _SaveParametersDialogState();
}

class _SaveParametersDialogState extends State<SaveParametersDialog> {
  late final TextEditingController _nameController;
  late Set<String> _selected;
  String? _nameError;

  // only slider/toggle values are actually tracked live - custom-type
  // parameters have no single "value" this snapshot mechanism can capture.
  List<ParamControl> get _eligible =>
      widget.parameters.where((p) => p.type == ParamType.slider || p.type == ParamType.toggle).toList();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _selected = _eligible.map((p) => p.name).toSet();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _allSelected => _eligible.isNotEmpty && _selected.length == _eligible.length;

  void _toggleAll(bool? value) {
    setState(() {
      if (value ?? false) {
        _selected = _eligible.map((p) => p.name).toSet();
      } else {
        _selected.clear();
      }
    });
  }

  // was: a silent no-op on an empty name/selection, which looked like the
  // Save button just didn't work - now it says exactly what's missing.
  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Enter a name');
      return;
    }
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Select at least one parameter to save.')));
      return;
    }
    final params = <ParamControl>[];
    for (final p in _eligible) {
      if (!_selected.contains(p.name)) continue;
      // deep-clone through JSON so the snapshot never shares mutable state
      // (curve points, controllers, etc.) with the live parameter.
      final clone = ParamControl.fromJson(p.toJson());
      final live = widget.values[p.name];
      if (clone.type == ParamType.toggle && live is bool) {
        clone.defaultBool = live;
      } else if (clone.type == ParamType.slider && live is double) {
        clone.defaultValue = live;
      }
      params.add(clone);
    }
    Navigator.of(context).pop(Profile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      isSnapshot: true,
      parameters: params,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final eligible = _eligible;
    return AlertDialog(
      title: const Text('Save Parameters'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Name', errorText: _nameError),
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
            ),
            const SizedBox(height: 8),
            if (eligible.isEmpty)
              const Expanded(child: Center(child: Text('No slider/toggle parameters to save yet.')))
            else
              Expanded(
                child: ListView(
                  children: [
                    for (final p in eligible)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(p.label),
                        value: _selected.contains(p.name),
                        onChanged: (v) => setState(() {
                          if (v ?? false) {
                            _selected.add(p.name);
                          } else {
                            _selected.remove(p.name);
                          }
                        }),
                      ),
                    const Divider(),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Select all'),
                      value: _allSelected,
                      onChanged: _toggleAll,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: eligible.isEmpty ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
