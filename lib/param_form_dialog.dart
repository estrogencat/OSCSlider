import 'package:flutter/material.dart';

import 'osc_client.dart';
import 'param_control.dart';

/// add/edit form. [takenNames] are names already used in the same list -
/// saving under one of those (other than the parameter's own) is refused,
/// since two entries sharing a name would share one live value.
Future<ParamControl?> showParamFormDialog(
  BuildContext context, {
  ParamControl? existing,
  Set<String> takenNames = const {},
}) {
  return showDialog<ParamControl>(
    context: context,
    builder: (context) => ParamFormDialog(existing: existing, takenNames: takenNames),
  );
}

class ParamFormDialog extends StatefulWidget {
  final ParamControl? existing;
  final Set<String> takenNames;
  const ParamFormDialog({super.key, this.existing, this.takenNames = const {}});

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
  late String _customType;
  late final TextEditingController _customValueController;
  late ParamType _type;
  late NumericKind _numericKind;
  late bool _defaultBool;
  String? _nameError;
  String? _rangeError;
  String? _defaultError;
  String? _customError;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.name ?? '');
    _labelController = TextEditingController(text: e?.label ?? '');
    _categoryController = TextEditingController(text: e?.category ?? '');
    _minController = TextEditingController(text: _fmt(e?.min ?? 0.0));
    _maxController = TextEditingController(text: _fmt(e?.max ?? 1.0));
    _defaultController = TextEditingController(text: _fmt(e?.defaultValue ?? 0.0));
    _customType = oscTypeTags.contains(e?.customTypeTag) ? e!.customTypeTag : 'f';
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
    _customValueController.dispose();
    super.dispose();
  }

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(1) : v.toString();

  static double? _parse(String text) => parseUserDouble(text);

  void _save() {
    final e = widget.existing;
    final name = normalizeParamName(_nameController.text);
    var nameError = validateParamName(name);
    if (nameError == null && name != e?.name && widget.takenNames.contains(name)) {
      nameError = 'There\'s already a parameter with this address';
    }
    final min = _parse(_minController.text);
    final max = _parse(_maxController.text);
    final def = _parse(_defaultController.text);
    String? rangeError;
    String? defaultError;
    String? customError;
    if (_type == ParamType.slider) {
      if (min == null || max == null) {
        rangeError = 'Min and max must be numbers';
      } else if (min >= max) {
        rangeError = 'Min has to be less than max';
      }
      if (def == null) defaultError = 'Default must be a number';
    } else if (_type == ParamType.custom && !oscTypeHasNoValue(_customType)) {
      try {
        OscClient.encodeCustomArgument(_customType, _customValueController.text);
      } catch (err) {
        customError = err.toString();
      }
    }
    setState(() {
      _nameError = nameError;
      _rangeError = rangeError;
      _defaultError = defaultError;
      _customError = customError;
    });
    if (nameError != null || rangeError != null || defaultError != null || customError != null) return;

    final label = _labelController.text.trim().isEmpty ? name.split('/').last : _labelController.text.trim();
    final category = _categoryController.text.trim();

    // editing keeps the parameter's automation/schedule - only dropped when
    // the new type can't run it (e.g. a ramp on what's now a toggle).
    final sameType = e != null && e.type == _type;
    final keepsValues = e != null && _type != ParamType.custom && e.type != ParamType.custom;
    final automation = e?.automation;
    final control = ParamControl(
      name: name,
      label: label,
      type: _type,
      category: category.isEmpty ? null : category,
      min: min ?? 0.0,
      max: max ?? 1.0,
      defaultValue: def ?? 0.0,
      numericKind: _numericKind,
      defaultBool: _defaultBool,
      customTypeTag: _customType,
      customValueText: _customValueController.text,
      automation: sameType || (keepsValues && automation?.kind == AutomationKind.random) ? automation : null,
      schedule: sameType || keepsValues ? e.schedule : null,
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
                autofocus: widget.existing == null,
                decoration: InputDecoration(
                  labelText: 'OSC address',
                  hintText: 'e.g. VF67_Mayu/Purr, or /any/full/osc/address',
                  helperText: 'No leading "/" is shorthand for /avatar/parameters/<this>. '
                      'Start with "/" to send to that exact address instead.',
                  helperMaxLines: 2,
                  errorText: _nameError,
                  errorMaxLines: 2,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
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
                if (_numericKind == NumericKind.int)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'VRChat int parameters go from 0 to 255.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minController,
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: InputDecoration(labelText: 'Min', errorText: _rangeError),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _maxController,
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: InputDecoration(labelText: 'Max', errorText: _rangeError == null ? null : ''),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _defaultController,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: InputDecoration(labelText: 'Default', errorText: _defaultError),
                ),
              ] else if (_type == ParamType.toggle) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Default on'),
                  value: _defaultBool,
                  onChanged: (v) => setState(() => _defaultBool = v),
                ),
              ] else ...[
                DropdownButtonFormField<String>(
                  initialValue: _customType,
                  decoration: const InputDecoration(labelText: 'OSC type'),
                  items: [
                    for (final tag in oscTypeTags)
                      DropdownMenuItem(value: tag, child: Text(oscTypeLabel(tag))),
                  ],
                  onChanged: (v) => setState(() => _customType = v ?? 'f'),
                ),
                if (!oscTypeHasNoValue(_customType)) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _customValueController,
                    decoration: InputDecoration(
                      labelText: 'Value',
                      hintText: oscTypeValueHint(_customType),
                      errorText: _customError,
                      errorMaxLines: 2,
                    ),
                  ),
                ],
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

// every OSC 1.0/1.1 type tag except arrays ("[","]") - arrays group multiple
// values into one argument slot, which doesn't fit this app's
// one-parameter-one-value model.
const oscTypeTags = ['f', 'i', 'd', 'h', 's', 'S', 'c', 'r', 'm', 'b', 't', 'T', 'F', 'N', 'I'];

String oscTypeLabel(String tag) => switch (tag) {
      'f' => 'Float32',
      'i' => 'Int32',
      'd' => 'Float64 (double)',
      'h' => 'Int64',
      's' => 'String',
      'S' => 'Symbol (like string)',
      'c' => 'Char',
      'r' => 'RGBA color',
      'm' => 'MIDI message',
      'b' => 'Blob (raw bytes)',
      't' => 'Time tag',
      'T' => 'True',
      'F' => 'False',
      'N' => 'Nil',
      'I' => 'Infinitum',
      _ => tag,
    };

// True/False/Nil/Infinitum carry no payload bytes - the type tag itself is
// the whole value, so there's nothing for the user to type in.
bool oscTypeHasNoValue(String tag) => const {'T', 'F', 'N', 'I'}.contains(tag);

String oscTypeValueHint(String tag) => switch (tag) {
      'f' || 'd' => 'e.g. 1.5',
      'i' || 'h' => 'e.g. 42',
      's' || 'S' => 'any text',
      'c' => 'a single character',
      'r' => '8 hex digits: RRGGBBAA',
      'm' => '8 hex digits: port, status, data1, data2',
      'b' => 'hex bytes, e.g. DEADBEEF',
      't' => 'seconds since 1900, or "immediate"',
      _ => '',
    };
