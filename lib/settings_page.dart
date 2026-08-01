import 'package:flutter/material.dart';

import 'config_store.dart';
import 'custom_theme_dialog.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';
import 'theme_notifier.dart';

class SettingsPage extends StatefulWidget {
  final AppConfig config;
  const SettingsPage({super.key, required this.config});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;

  AppConfig get config => widget.config;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    await ConfigStore.save(config);
  }

  void _saveConnection() {
    setState(() {
      config.host = _hostController.text.trim().isEmpty ? '127.0.0.1' : _hostController.text.trim();
      config.port = int.tryParse(_portController.text) ?? config.port;
    });
    _persist();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connection saved')));
  }

  void _pickColor(Color color) {
    setState(() {
      config.themeSeedColor = color;
      // a plain preset resets any per-role custom overrides made earlier.
      config.primaryOverride = null;
      config.secondaryOverride = null;
      config.tertiaryOverride = null;
      config.errorOverride = null;
    });
    themeSettingsNotifier.value = ThemeSettings.fromConfig(config);
    _persist();
  }

  Future<void> _openCustomTheme() async {
    await showCustomThemeDialog(context, config);
    setState(() {});
    _persist();
  }

  void _setAdvancedMode(bool value) {
    setState(() => config.advancedMode = value);
    _persist();
  }

  void _setAutoProfileMode(bool value) {
    setState(() => config.autoProfileMode = value);
    _persist();
  }

  void _switchProfile(String id) {
    setState(() => config.activeProfileId = id);
    _persist();
  }

  Future<void> _addProfile() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Profile'),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final profile = Profile(id: DateTime.now().millisecondsSinceEpoch.toString(), name: name);
    setState(() {
      config.profiles.add(profile);
      config.activeProfileId = profile.id;
    });
    _persist();
  }

  Future<void> _renameProfile(Profile profile) async {
    final controller = TextEditingController(text: profile.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Profile'),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => profile.name = name);
    _persist();
  }

  Future<void> _deleteProfile(Profile profile) async {
    if (config.profiles.length <= 1) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('At least one profile has to stick around.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text('This removes "${profile.name}" and its ${profile.parameters.length} parameters.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      config.profiles.remove(profile);
      if (config.activeProfileId == profile.id) {
        config.activeProfileId = config.profiles.first.id;
      }
    });
    _persist();
  }

  Future<void> _editParam(ParamControl param) async {
    final result = await showParamFormDialog(context, existing: param);
    if (result == null) return;
    setState(() {
      final index = config.parameters.indexOf(param);
      if (index != -1) config.parameters[index] = result;
    });
    _persist();
  }

  Future<void> _deleteParam(ParamControl param) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete parameter?'),
        content: Text('Remove "${param.label}" from the dashboard?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => config.parameters.remove(param));
    _persist();
  }

  Future<void> _deleteAll() async {
    final count = config.parameters.length;
    if (count == 0) return;

    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all parameters?'),
        content: Text('This will remove all $count parameters from the dashboard. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (firstConfirm != true) return;
    if (!mounted) return;

    final secondConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Are you absolutely sure?'),
        content: Text(
          'Last chance - all $count parameters will be permanently deleted from config.json.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );
    if (secondConfirm != true) return;

    setState(() => config.parameters.clear());
    _persist();
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final item = config.parameters.removeAt(oldIndex);
      config.parameters.insert(newIndex, item);
    });
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(child: _buildHeader(context)),
          ),
          if (config.parameters.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No parameters yet.'),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverReorderableList(
                itemCount: config.parameters.length,
                onReorderItem: _reorder,
                itemBuilder: (context, index) {
                  final param = config.parameters[index];
                  return Card(
                    key: ValueKey(param.name),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: const Icon(Icons.drag_handle),
                      ),
                      title: Text(param.label),
                      subtitle: Text(
                        '${param.name}'
                        '${param.category != null ? '  ·  ${param.category}' : ''}'
                        '  ·  ${_typeLabel(param)}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(icon: const Icon(Icons.edit), onPressed: () => _editParam(param)),
                          IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteParam(param)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: _buildFooter(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Connection', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostController,
                decoration: const InputDecoration(labelText: 'Host'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _saveConnection, child: const Text('Save')),
          ],
        ),
        const SizedBox(height: 24),
        Text('Theme Color', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final swatch in Colors.primaries)
              _ColorSwatch(
                color: swatch,
                selected: config.primaryOverride == null &&
                    config.secondaryOverride == null &&
                    config.tertiaryOverride == null &&
                    config.errorOverride == null &&
                    swatch.toARGB32() == config.themeSeedColor.toARGB32(),
                onTap: () => _pickColor(swatch),
              ),
            _CustomSwatch(
              hue: HSLColor.fromColor(config.themeSeedColor).hue,
              selected: config.primaryOverride != null ||
                  config.secondaryOverride != null ||
                  config.tertiaryOverride != null ||
                  config.errorOverride != null,
              onTap: _openCustomTheme,
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            const Expanded(
              child: Text('Advanced Mode'),
            ),
            Switch(value: config.advancedMode, onChanged: _setAdvancedMode),
          ],
        ),
        Text(
          'Shows full-precision slider values instead of rounding the textbox to 3 decimals.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Profiles', style: Theme.of(context).textTheme.titleLarge),
            TextButton.icon(onPressed: _addProfile, icon: const Icon(Icons.add), label: const Text('New')),
          ],
        ),
        RadioGroup<String>(
          groupValue: config.activeProfileId,
          onChanged: (id) => _switchProfile(id!),
          child: Column(
            children: [
              for (final profile in config.profiles)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: RadioListTile<String>(
                    value: profile.id,
                    title: Text(profile.name),
                    subtitle: Text(
                      '${profile.parameters.length} parameters'
                      '${profile.avatarId != null ? '  ·  auto-linked' : ''}',
                    ),
                    secondary: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(icon: const Icon(Icons.edit), onPressed: () => _renameProfile(profile)),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteProfile(profile),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(child: Text('Auto Mode')),
            Switch(value: config.autoProfileMode, onChanged: _setAutoProfileMode),
          ],
        ),
        Text(
          'Watches for VRChat avatar changes and automatically switches to (or '
          'creates) the matching profile. Off by default since it passively '
          'listens for which avatar you\'re wearing.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Parameters', style: Theme.of(context).textTheme.titleLarge),
            Text('${config.parameters.length} total  ·  drag to reorder'),
          ],
        ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Danger Zone', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 18)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          onPressed: _deleteAll,
          icon: const Icon(Icons.delete_forever),
          label: const Text('Delete All Parameters'),
        ),
      ],
    );
  }

  String _typeLabel(ParamControl param) {
    return switch (param.type) {
      ParamType.slider => 'slider (${param.numericKind == NumericKind.int ? 'int' : 'float'})',
      ParamType.toggle => 'toggle',
      ParamType.custom => 'custom (${param.customTypeTag})',
    };
  }
}

class _ColorSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorSwatch({required this.color, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected ? Border.all(color: Colors.white, width: 3) : null,
        ),
        child: selected ? const Icon(Icons.check, color: Colors.white) : null,
      ),
    );
  }
}

class _CustomSwatch extends StatelessWidget {
  final double hue;
  final bool selected;
  final VoidCallback onTap;

  const _CustomSwatch({required this.hue, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 40,
        height: 40,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: selected ? Border.all(color: Colors.white, width: 3) : null,
        ),
        child: CustomPaint(painter: _MiniHuePainter(), child: const SizedBox.expand()),
      ),
    );
  }
}

class _MiniHuePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final rainbow = SweepGradient(
      colors: List.generate(13, (i) => HSVColor.fromAHSV(1, i * 30.0, 1, 1).toColor()),
    );
    canvas.drawCircle(center, radius, Paint()..shader = rainbow.createShader(rect));
    final whiteFade = const RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]);
    canvas.drawCircle(center, radius, Paint()..shader = whiteFade.createShader(rect));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
