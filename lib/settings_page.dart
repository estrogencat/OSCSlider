import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updater.dart';
import 'automation_master_switch_dialog.dart';
import 'config_store.dart';
import 'custom_theme_dialog.dart';
import 'developer_mode_dialog.dart';
import 'error_dialog.dart';
import 'hidden_features_dialog.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';
import 'save_parameters_dialog.dart';
import 'snapshot_editor_page.dart';
import 'theme_notifier.dart';

const _repoUrl = 'https://github.com/estrogencat/OSCSlider';

enum _OscStatus { unknown, checking, connected, disconnected }

class SettingsPage extends StatefulWidget {
  final AppConfig config;
  // live parameter values, keyed by name - needed so "Save Parameters" can
  // snapshot what's actually on screen right now, not just configured defaults.
  final Map<String, Object> values;
  // applies a snapshot profile's saved values onto the active profile -
  // lives in main.dart since only it can push to the live UI/controllers
  // and actually send the result back out over OSC.
  final void Function(Profile snapshot) onApplySnapshot;

  const SettingsPage({
    super.key,
    required this.config,
    required this.values,
    required this.onApplySnapshot,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _liveParamNoiseThresholdController;
  late final TextEditingController _oscQueryFetchTimeoutController;
  String _appVersion = '';
  bool _checkingUpdate = false;
  _OscStatus _oscStatus = _OscStatus.unknown;
  // set only when the search itself failed outright (not just "found
  // nothing") - shown as a tooltip on the status dot.
  String? _oscStatusError;
  int _versionTapCount = 0;

  AppConfig get config => widget.config;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
    _liveParamNoiseThresholdController = TextEditingController(text: config.liveParamNoiseThreshold.toString());
    _oscQueryFetchTimeoutController = TextEditingController(text: config.oscQueryFetchTimeoutSeconds.toString());
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = info.version);
    });
  }

  // OSC has no real "connection" - this checks for a VRChat OSCQuery service
  // via mDNS as a proxy. manual only (the refresh button): running it
  // automatically on every Settings visit used to collide with Discover and
  // make VRChat's own responses flakier under the extra query traffic.
  Future<void> _checkOscStatus() async {
    setState(() => _oscStatus = _OscStatus.checking);
    final result = await OscQueryClient.findVrchatInstances(
      anyOscQueryService: config.developerMode,
      timeout: Duration(seconds: config.oscQueryFetchTimeoutSeconds),
    );
    if (!mounted) return;
    setState(() {
      _oscStatus = result.instances.isEmpty ? _OscStatus.disconnected : _OscStatus.connected;
      _oscStatusError = result.error;
    });
    if (result.instances.isEmpty) {
      await showErrorDialog(context, 'No OSCQuery service found', result.error ?? oscNotFoundExplanation);
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _liveParamNoiseThresholdController.dispose();
    _oscQueryFetchTimeoutController.dispose();
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

  // 0 = never filter noisy parameters out of the discover popup's "highlight
  // active parameters" top spot.
  void _setLiveParamNoiseThreshold(String text) {
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < 0) {
      _liveParamNoiseThresholdController.text = config.liveParamNoiseThreshold.toString();
      return;
    }
    setState(() => config.liveParamNoiseThreshold = parsed);
    _persist();
  }

  // developer-mode-only since the server it targets can hang outright.
  void _setOscQueryFetchTimeout(String text) {
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < 1) {
      _oscQueryFetchTimeoutController.text = config.oscQueryFetchTimeoutSeconds.toString();
      return;
    }
    setState(() => config.oscQueryFetchTimeoutSeconds = parsed);
    _persist();
  }

  Widget _buildOscStatus(BuildContext context) {
    final (color, label) = switch (_oscStatus) {
      _OscStatus.unknown => (Colors.grey, 'Not checked'),
      _OscStatus.checking => (Colors.amber, 'Checking...'),
      _OscStatus.connected => (Colors.green, 'Connected'),
      _OscStatus.disconnected => (Colors.red, _oscStatusError != null ? 'Not found (search failed)' : 'Not found'),
    };
    final dot = Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _oscStatus == _OscStatus.disconnected && _oscStatusError != null
            ? Tooltip(message: _oscStatusError!, child: dot)
            : dot,
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Check connection',
          onPressed: _oscStatus == _OscStatus.checking ? null : _checkOscStatus,
        ),
      ],
    );
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

  Future<void> _openHiddenFeaturesDialog() async {
    final changed = await showHiddenFeaturesDialog(context, config);
    if (!changed) return;
    _persist();
    setState(() {});
  }

  Future<void> _openAutomationMasterSwitchDialog() async {
    final changed = await showAutomationMasterSwitchDialog(context, config);
    if (!changed) return;
    _persist();
    setState(() {});
  }

  void _setAutoProfileMode(bool value) {
    setState(() => config.autoProfileMode = value);
    _persist();
  }

  Future<void> _handleVersionTap() async {
    _versionTapCount++;
    if (_versionTapCount < 5) return;
    _versionTapCount = 0;

    if (config.developerModeUnlocked) {
      final confirmed = await showDisableDeveloperModeDialog(context);
      if (confirmed != true) return;
      setState(() {
        config.developerMode = false;
        config.developerModeUnlocked = false;
      });
      _persist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Developer Mode disabled and hidden.')));
      }
    } else {
      setState(() => config.developerModeUnlocked = true);
      _persist();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Developer Mode unlocked.')));
    }
  }

  Future<void> _setDeveloperMode(bool value) async {
    if (value && !config.developerModeWarningDismissed) {
      final dontShowAgain = await showDeveloperModeDialog(context);
      if (dontShowAgain == null) return; // cancelled
      if (dontShowAgain) config.developerModeWarningDismissed = true;
    }
    setState(() => config.developerMode = value);
    _persist();
  }

  void _switchProfile(String id) {
    setState(() => config.activeProfileId = id);
    _persist();
  }

  Future<void> _saveParametersSnapshot() async {
    final snapshot = await showSaveParametersDialog(context, config.parameters, widget.values);
    if (snapshot == null) return;
    setState(() => config.profiles.add(snapshot));
    _persist();
  }

  void _applySnapshot(Profile snapshot) {
    widget.onApplySnapshot(snapshot);
    // Apply can add parameters the active profile was missing - refresh so
    // its "N parameters" count is right without having to leave and reopen.
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Applied "${snapshot.name}" to the active profile.')));
  }

  Future<void> _openSnapshotEditor(Profile snapshot) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SnapshotEditorPage(
        snapshot: snapshot,
        developerMode: config.developerMode,
        oscPort: config.port,
        liveParamNoiseThreshold: config.liveParamNoiseThreshold,
        oscQueryFetchTimeoutSeconds: config.oscQueryFetchTimeoutSeconds,
        onPersist: _persist,
      ),
    ));
    // the editor mutates the snapshot in place via setState only (name,
    // saved values) - this is the one point that actually saves it.
    setState(() {});
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
    // snapshots don't count toward (or need) the "at least one" minimum -
    // they're never required for the app to function.
    if (!profile.isSnapshot && config.profiles.where((p) => !p.isSnapshot).length <= 1) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('At least one profile has to stick around.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(profile.isSnapshot ? 'Delete snapshot?' : 'Delete profile?'),
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
        config.activeProfileId = config.profiles.firstWhere((p) => !p.isSnapshot).id;
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

  // shared two-step "are you sure / are you REALLY sure" flow for every
  // Danger Zone action - true only if the user confirmed both dialogs.
  Future<bool> _confirmDangerAction({
    required String title,
    required String warning,
    required String finalWarning,
    required String confirmLabel,
  }) async {
    final firstConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(warning),
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
    if (firstConfirm != true) return false;
    if (!mounted) return false;

    final secondConfirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Are you absolutely sure?'),
        content: Text(finalWarning),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return secondConfirm == true;
  }

  Future<void> _deleteAll() async {
    final count = config.parameters.length;
    if (count == 0) return;
    final confirmed = await _confirmDangerAction(
      title: 'Delete all parameters?',
      warning: 'This will remove all $count parameters from the dashboard. This cannot be undone.',
      finalWarning: 'Last chance - all $count parameters will be permanently deleted from config.json.',
      confirmLabel: 'Delete Everything',
    );
    if (!confirmed) return;
    setState(() => config.parameters.clear());
    _persist();
  }

  Future<void> _deleteAllProfiles() async {
    final count = config.profiles.length;
    final confirmed = await _confirmDangerAction(
      title: 'Delete all profiles?',
      warning: 'This removes all $count profiles and everything in them - parameters, automations, '
          'sequences - replacing them with a single empty "Default" profile. This cannot be undone.',
      finalWarning: 'Last chance - all $count profiles will be permanently deleted from config.json.',
      confirmLabel: 'Delete Everything',
    );
    if (!confirmed) return;
    setState(() {
      config.profiles.clear();
      config.profiles.add(Profile(id: 'default', name: 'Default'));
      config.activeProfileId = 'default';
    });
    _persist();
  }

  Future<void> _clearConfig() async {
    final confirmed = await _confirmDangerAction(
      title: 'Clear config?',
      warning: 'This resets everything - connection, theme, profiles, parameters, and all settings - '
          'back to a blank slate. This cannot be undone.',
      finalWarning: 'Last chance - config.json will be permanently reset to defaults.',
      confirmLabel: 'Clear Everything',
    );
    if (!confirmed) return;
    setState(() {
      config.host = '127.0.0.1';
      config.port = 9000;
      config.themeSeedColor = defaultThemeSeedColor;
      config.primaryOverride = null;
      config.secondaryOverride = null;
      config.tertiaryOverride = null;
      config.errorOverride = null;
      config.autoProfileMode = false;
      config.developerMode = false;
      config.developerModeWarningDismissed = false;
      config.developerModeUnlocked = false;
      config.showAutomationMasterSwitch = false;
      config.automationMasterSwitchAll = true;
      config.automationMasterSwitchParams = [];
      config.liveParamNoiseThreshold = 10;
      config.oscQueryFetchTimeoutSeconds = 5;
      config.profiles.clear();
      config.profiles.add(Profile(id: 'default', name: 'Default'));
      config.activeProfileId = 'default';
    });
    _hostController.text = config.host;
    _portController.text = config.port.toString();
    _liveParamNoiseThresholdController.text = config.liveParamNoiseThreshold.toString();
    _oscQueryFetchTimeoutController.text = config.oscQueryFetchTimeoutSeconds.toString();
    themeSettingsNotifier.value = ThemeSettings.fromConfig(config);
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
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Connection', style: Theme.of(context).textTheme.titleLarge),
            _buildOscStatus(context),
          ],
        ),
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
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _openHiddenFeaturesDialog,
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          child: const Text('Features that are disabled by default'),
        ),
        if (config.showAutomationMasterSwitch) ...[
          const SizedBox(height: 24),
          Text('Unlocked Features', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              title: const Text('Automation Master Switch'),
              subtitle: const Text('Enable or disable many automations at once.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openAutomationMasterSwitchDialog,
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Profiles', style: Theme.of(context).textTheme.titleLarge),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: _saveParametersSnapshot,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save Parameters'),
                ),
                TextButton.icon(onPressed: _addProfile, icon: const Icon(Icons.add), label: const Text('New')),
              ],
            ),
          ],
        ),
        RadioGroup<String>(
          groupValue: config.activeProfileId,
          onChanged: (id) => _switchProfile(id!),
          child: Column(
            children: [
              for (final profile in config.profiles.where((p) => !p.isSnapshot))
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
        if (config.profiles.any((p) => p.isSnapshot)) ...[
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          Text('Saved Snapshots', style: Theme.of(context).textTheme.titleMedium),
          Text(
            'Static saves from "Save Parameters" - never auto-switched to, never touched by live '
            'avatar changes. Apply pushes their saved values onto whatever profile is active now.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          for (final profile in config.profiles.where((p) => p.isSnapshot))
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                onTap: () => _openSnapshotEditor(profile),
                title: Text(profile.name),
                subtitle: Text('${profile.parameters.length} parameters'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(onPressed: () => _applySnapshot(profile), child: const Text('Apply')),
                    IconButton(icon: const Icon(Icons.edit), onPressed: () => _openSnapshotEditor(profile)),
                    IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteProfile(profile)),
                  ],
                ),
              ),
            ),
        ],
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
        Text('Miscellaneous', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        TextField(
          controller: _liveParamNoiseThresholdController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Highlight noise filter (changes/sec)',
            helperText: 'In the discover popup\'s "highlight active parameters" toggle, a parameter '
                'stops jumping to the top once it changes this many times within one second '
                '(0 = never filter).',
            helperMaxLines: 2,
          ),
          onSubmitted: _setLiveParamNoiseThreshold,
          onTapOutside: (_) => _setLiveParamNoiseThreshold(_liveParamNoiseThresholdController.text),
        ),
        if (config.developerMode) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _oscQueryFetchTimeoutController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'OSCQuery fetch timeout (seconds)',
              helperText: 'How long Discover waits on VRChat\'s OSCQuery server for the full parameter '
                  'list or current-avatar lookup before giving up on it. Some avatars make VRChat '
                  'hang on this outright, so lower it to fall back faster.',
              helperMaxLines: 3,
            ),
            onSubmitted: _setOscQueryFetchTimeout,
            onTapOutside: (_) => _setOscQueryFetchTimeout(_oscQueryFetchTimeoutController.text),
          ),
        ],
        const SizedBox(height: 24),
        Text('Danger Zone', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 18)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: _deleteAll,
              icon: const Icon(Icons.delete_forever),
              label: const Text('Delete All Parameters'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: _deleteAllProfiles,
              icon: const Icon(Icons.delete_forever),
              label: const Text('Delete All Profiles'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: _clearConfig,
              icon: const Icon(Icons.delete_forever),
              label: const Text('Clear Config'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Center(child: _buildVersionFooter(context)),
        if (config.developerModeUnlocked) ...[
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.code, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Developer Mode',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              Switch(value: config.developerMode, onChanged: _setDeveloperMode),
            ],
          ),
          Text(
            'Check GitHub to see what this switch does',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _buildVersionFooter(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      children: [
        InkWell(
          onTap: _handleVersionTap,
          child: Text(_appVersion.isEmpty ? 'OSCSlider' : 'OSCSlider v$_appVersion', style: style),
        ),
        InkWell(
          onTap: () => launchUrl(Uri.parse(_repoUrl)),
          child: Text('GitHub', style: style?.copyWith(decoration: TextDecoration.underline)),
        ),
        _checkingUpdate
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : InkWell(
                onTap: _checkForUpdate,
                child: Text('Check for updates', style: style?.copyWith(decoration: TextDecoration.underline)),
              ),
      ],
    );
  }

  Future<void> _checkForUpdate() async {
    setState(() => _checkingUpdate = true);
    final messenger = ScaffoldMessenger.of(context);
    final update = await checkForUpdate(_appVersion);
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (update == null) {
      messenger.showSnackBar(const SnackBar(content: Text('No update found.')));
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text('OSCSlider v${update.version} is available.'),
        action: SnackBarAction(label: 'View', onPressed: () => launchUrl(Uri.parse(update.url))),
      ));
    }
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
