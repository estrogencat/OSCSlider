import 'package:flutter/material.dart';

import 'param_control.dart';

Future<ParamControl?> showParamFormDialog(BuildContext context, {ParamControl? existing}) {
  return showDialog<ParamControl>(
    context: context,
    builder: (context) => ParamFormDialog(existing: existing),
  );
}

class ParamFormDialog extends StatefulWidget {
  final ParamControl? existing;
  const ParamFormDialog({super.key, this.existing});

  @override
  State<ParamFormDialog> createState() => _ParamFormDialogState();
}

class _ParamFormDialogState extends State<ParamFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _labelController;
  late final TextEditingController _categoryController;
  late final TextEditingController _minController;
  late final TextEditingController _maxController;
  late final TextEditingController _defaultController;
  late final TextEditingController _customTypeController;
  late final TextEditingController _customValueController;
  late ParamType _type;
  late NumericKind _numericKind;
  late bool _defaultBool;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.name ?? '');
    _labelController = TextEditingController(text: e?.label ?? '');
    _categoryController = TextEditingController(text: e?.category ?? '');
    _minController = TextEditingController(text: (e?.min ?? 0.0).toString());
    _maxController = TextEditingController(text: (e?.max ?? 1.0).toString());
    _defaultController = TextEditingController(text: (e?.defaultValue ?? 0.0).toString());
    _customTypeController = TextEditingController(text: e?.customTypeTag ?? 'f');
    _customValueController = TextEditingController(text: e?.customValueText ?? '0');
    _type = e?.type ?? ParamType.slider;
    _numericKind = e?.numericKind ?? NumericKind.float;
    _defaultBool = e?.defaultBool ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    _categoryController.dispose();
    _minController.dispose();
    _maxController.dispose();
    _defaultController.dispose();
    _customTypeController.dispose();
    _customValueController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final label = _labelController.text.trim().isEmpty ? name : _labelController.text.trim();
    final category = _categoryController.text.trim();

    final control = ParamControl(
      name: name,
      label: label,
      type: _type,
      category: category.isEmpty ? null : category,
      min: double.tryParse(_minController.text) ?? 0.0,
      max: double.tryParse(_maxController.text) ?? 1.0,
      defaultValue: double.tryParse(_defaultController.text) ?? 0.0,
      numericKind: _numericKind,
      defaultBool: _defaultBool,
      customTypeTag: _customTypeController.text.trim().isEmpty ? 'f' : _customTypeController.text.trim(),
      customValueText: _customValueController.text,
    );
    Navigator.of(context).pop(control);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add Parameter' : 'Edit Parameter'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'OSC address (after /avatar/parameters/)',
                  hintText: 'e.g. VF67_Mayu/Purr',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _labelController,
                decoration: const InputDecoration(labelText: 'Display label (optional)'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _categoryController,
                decoration: const InputDecoration(labelText: 'Category (optional)'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ParamType>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: ParamType.slider, child: Text('Slider')),
                  DropdownMenuItem(value: ParamType.toggle, child: Text('Toggle')),
                  DropdownMenuItem(value: ParamType.custom, child: Text('Custom (any OSC type)')),
                ],
                onChanged: (v) => setState(() => _type = v ?? ParamType.slider),
              ),
              const SizedBox(height: 8),
              if (_type == ParamType.slider) ...[
                DropdownButtonFormField<NumericKind>(
                  initialValue: _numericKind,
                  decoration: const InputDecoration(labelText: 'Numeric OSC type'),
                  items: const [
                    DropdownMenuItem(value: NumericKind.float, child: Text('Float')),
                    DropdownMenuItem(value: NumericKind.int, child: Text('Int')),
                  ],
                  onChanged: (v) => setState(() => _numericKind = v ?? NumericKind.float),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minController,
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: const InputDecoration(labelText: 'Min'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _maxController,
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: const InputDecoration(labelText: 'Max'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _defaultController,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(labelText: 'Default'),
                ),
              ] else if (_type == ParamType.toggle) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Default on'),
                  value: _defaultBool,
                  onChanged: (v) => setState(() => _defaultBool = v),
                ),
              ] else ...[
                TextField(
                  controller: _customTypeController,
                  decoration: const InputDecoration(
                    labelText: 'OSC type tag',
                    hintText: 'f, i, d, s, T, F, or anything else',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _customValueController,
                  decoration: const InputDecoration(labelText: 'Value (sent as typed, best-effort)'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
