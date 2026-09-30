import 'package:flutter/material.dart';

import 'osc_client.dart';
import 'param_control.dart';
import 'vrchat_controls.dart';

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
  late final TextEditingController _stepController;
  late bool _springBack;
  late ButtonMode _buttonMode;
  late bool _buttonSendsInt;
  late final TextEditingController _tapMsController;
  late bool _chatSendNow;
  late bool _chatNotify;
  late bool _chatTyping;
  String? _chatDraft;
  // bumped when a preset fills the form, so dropdowns pick up the new value.
  int _formVersion = 0;
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
    _stepController = TextEditingController(text: (e?.step ?? 0) > 0 ? _fmt(e!.step) : '');
    _springBack = e?.springBack ?? false;
    _buttonMode = e?.buttonMode ?? ButtonMode.hold;
    _buttonSendsInt = e?.buttonSendsInt ?? false;
    _tapMsController = TextEditingController(text: '${e?.tapMillis ?? 100}');
    _chatSendNow = e?.chatboxSendImmediately ?? true;
    _chatNotify = e?.chatboxNotify ?? true;
    _chatTyping = e?.chatboxTypingIndicator ?? true;
    if (e?.type == ParamType.chatbox) _chatDraft = e!.customValueText;
  }

  // fills the form from one of VRChat's built-in controls.
  void _applyTemplate(ParamControl t) {
    setState(() {
      _nameController.text = t.name;
      _labelController.text = t.label;
      _categoryController.text = t.category ?? '';
      _type = t.type;
      _numericKind = t.numericKind;
      _minController.text = _fmt(t.min);
      _maxController.text = _fmt(t.max);
      _defaultController.text = _fmt(t.defaultValue);
      _stepController.text = t.step > 0 ? _fmt(t.step) : '';
      _springBack = t.springBack;
      _buttonMode = t.buttonMode;
      _buttonSendsInt = t.buttonSendsInt;
      _tapMsController.text = '${t.tapMillis}';
      _chatSendNow = t.chatboxSendImmediately;
      _chatNotify = t.chatboxNotify;
      _chatTyping = t.chatboxTypingIndicator;
      _nameError = null;
      _formVersion++;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    _categoryController.dispose();
    _minController.dispose();
    _maxController.dispose();
    _defaultController.dispose();
    _stepController.dispose();
    _tapMsController.dispose();
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
    final step = _stepController.text.trim().isEmpty ? 0.0 : parseUserDouble(_stepController.text);
    final tapMs = int.tryParse(_tapMsController.text.trim());
    if (_type == ParamType.slider) {
      if (step == null || step < 0) defaultError = 'Step must be a number, 0 or more';
      if (min == null || max == null) {
        rangeError = 'Min and max must be numbers';
      } else if (min >= max) {
        rangeError = 'Min has to be less than max';
      }
      if (def == null) defaultError = 'Default must be a number';
    } else if (_type == ParamType.button) {
      if (_buttonMode == ButtonMode.tap && (tapMs == null || tapMs < 10 || tapMs > 10000)) {
        customError = 'Press length must be 10 - 10000 ms';
      }
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
      step: _type == ParamType.slider ? (step ?? 0) : 0,
      springBack: _type == ParamType.slider && _springBack,
      customTypeTag: _customType,
      customValueText: _type == ParamType.chatbox ? (_chatDraft ?? '') : _customValueController.text,
      buttonMode: _buttonMode,
      buttonSendsInt: _buttonSendsInt,
      tapMillis: (tapMs ?? 100).clamp(10, 10000),
      chatboxSendImmediately: _chatSendNow,
      chatboxNotify: _chatNotify,
      chatboxTypingIndicator: _chatTyping,
      automation: sameType || (keepsValues && automation?.kind == AutomationKind.random) ? automation : null,
      schedule: sameType || keepsValues ? e.schedule : null,
    );
    Navigator.of(context).pop(control);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // wraps the button under the title on a narrow screen.
      title: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(widget.existing == null ? 'Add Parameter' : 'Edit Parameter'),
          if (widget.existing == null)
            TextButton.icon(
              icon: const Icon(Icons.videogame_asset_outlined),
              label: const Text('VRChat controls'),
              onPressed: () async {
                final t = await showVrchatControlPicker(context, takenNames: widget.takenNames);
                if (t != null) _applyTemplate(t);
              },
            ),
        ],
      ),
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
                  helperText:
                      'No leading "/" is shorthand for /avatar/parameters/<this>. '
                      'Start with "/" to send to that exact address instead.',
                  helperMaxLines: 4,
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
                isExpanded: true,
                key: ValueKey('type-$_formVersion'),
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: ParamType.slider, child: Text('Slider')),
                  DropdownMenuItem(value: ParamType.toggle, child: Text('Toggle')),
                  DropdownMenuItem(value: ParamType.button, child: Text('Button (momentary)')),
                  DropdownMenuItem(value: ParamType.chatbox, child: Text('Chatbox message')),
                  DropdownMenuItem(value: ParamType.custom, child: Text('Custom (any OSC type)')),
                ],
                onChanged: (v) => setState(() {
                  _type = v ?? ParamType.slider;
                  // VRChat's chatbox lives at one fixed address.
                  if (_type == ParamType.chatbox && _nameController.text.trim().isEmpty) {
                    _nameController.text = '/chatbox/input';
                  }
                }),
              ),
              const SizedBox(height: 8),
              if (_type == ParamType.slider) ...[
                DropdownButtonFormField<NumericKind>(
                  isExpanded: true,
                  key: ValueKey('kind-$_formVersion'),
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
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _defaultController,
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: InputDecoration(labelText: 'Default', errorText: _defaultError),
                      ),
                    ),
                    if (_numericKind == NumericKind.float) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _stepController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Snap to steps of', hintText: 'off'),
                        ),
                      ),
                    ],
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Spring back when released'),
                  subtitle: const Text('Returns to the default when you let go - like a joystick'),
                  value: _springBack,
                  onChanged: (v) => setState(() => _springBack = v),
                ),
              ] else if (_type == ParamType.button) ...[
                SegmentedButton<ButtonMode>(
                  segments: const [
                    ButtonSegment(value: ButtonMode.hold, label: Text('Hold'), icon: Icon(Icons.touch_app_outlined)),
                    ButtonSegment(value: ButtonMode.tap, label: Text('Tap'), icon: Icon(Icons.ads_click)),
                  ],
                  selected: {_buttonMode},
                  onSelectionChanged: (s) => setState(() => _buttonMode = s.first),
                ),
                const SizedBox(height: 4),
                Text(
                  _buttonMode == ButtonMode.hold
                      ? 'Pressed for as long as you hold it down.'
                      : 'Each click sends a quick press and release.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_buttonMode == ButtonMode.tap) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _tapMsController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: 'Press length (ms)', errorText: _customError),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Send 1 / 0 instead of true / false'),
                  subtitle: const Text('VRChat\'s /input buttons need numbers; avatar bool parameters need true/false'),
                  value: _buttonSendsInt,
                  onChanged: (v) => setState(() => _buttonSendsInt = v),
                ),
              ] else if (_type == ParamType.chatbox) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Send immediately'),
                  subtitle: const Text('Off: opens the in-game keyboard with the text instead'),
                  value: _chatSendNow,
                  onChanged: (v) => setState(() => _chatSendNow = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Notification sound'),
                  value: _chatNotify,
                  onChanged: (v) => setState(() => _chatNotify = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show the typing bubble while writing'),
                  value: _chatTyping,
                  onChanged: (v) => setState(() => _chatTyping = v),
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
                  isExpanded: true,
                  initialValue: _customType,
                  decoration: const InputDecoration(labelText: 'OSC type'),
                  items: [for (final tag in oscTypeTags) DropdownMenuItem(value: tag, child: Text(oscTypeLabel(tag)))],
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
