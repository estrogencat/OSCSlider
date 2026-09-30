import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'android_platform.dart';
import 'app_updater.dart';
import 'automation_master_switch_dialog.dart';
import 'config_store.dart';
import 'connection_status.dart';
import 'custom_theme_dialog.dart';
import 'developer_mode_dialog.dart';
import 'error_dialog.dart';
import 'hidden_features_dialog.dart';
import 'live_controller.dart';
import 'osc_input_hub.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';
import 'platform_paths.dart';
import 'save_parameters_dialog.dart';
import 'snapshot_editor_page.dart';
import 'theme_notifier.dart';
import 'update_dialog.dart';

const _repoUrl = 'https://github.com/estrogencat/OSCSlider';

String _plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

class SettingsPage extends StatefulWidget {
  final LiveController live;

  const SettingsPage({super.key, required this.live});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _liveParamNoiseThresholdController;
  late final TextEditingController _oscQueryFetchTimeoutController;
  late final TextEditingController _listenPortController;
  String? _listenPortError;
  String? _hostError;
  String? _portError;
  String _appVersion = '';
  bool _checkingUpdate = false;
  int _versionTapCount = 0;

  LiveController get live => widget.live;
  AppConfig get config => live.config;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
    _liveParamNoiseThresholdController = TextEditingController(text: config.liveParamNoiseThreshold.toString());
    _oscQueryFetchTimeoutController = TextEditingController(text: config.oscQueryFetchTimeoutSeconds.toString());
    _listenPortController = TextEditingController(text: config.listenPort?.toString() ?? '');
    currentAppVersion().then((v) {
      if (mounted) setState(() => _appVersion = v);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _liveParamNoiseThresholdController.dispose();
    _oscQueryFetchTimeoutController.dispose();
    _listenPortController.dispose();
    super.dispose();
  }

  void _persist() => live.persist();

  // structural edits here go through the shared controller, which keeps
  // the main screen's live values in step immediately.
  void _changed() {
    _persist();
    live.reconcile();
  }

  void _saveConnection() {
    final host = _hostController.text.trim().isEmpty ? '127.0.0.1' : _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final isIp = InternetAddress.tryParse(host) != null;
    final hostError = !isIp && (RegExp(r'[\s/\\]').hasMatch(host) || host.contains(':'))
        ? 'Just the IP or host name - no spaces, "/" or ":port"'
        : null;
    final portError = port == null || port < 1 || port > 65535 ? 'Port must be 1-65535' : null;
    setState(() {
      _hostError = hostError;
      _portError = portError;
    });
    if (hostError != null || portError != null) return;
    config.host = host;
    config.port = port!;
    _hostController.text = host;
    _changed();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Connection saved')));
  }

  // 0 = never filter noisy parameters out of the discover popup's "highlight
  // active parameters" top spot.
  void _setLiveParamNoiseThreshold(String text) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || parsed < 0) {
      _liveParamNoiseThresholdController.text = config.liveParamNoiseThreshold.toString();
      return;
    }
    if (parsed == config.liveParamNoiseThreshold) return;
    setState(() => config.liveParamNoiseThreshold = parsed);
    _persist();
  }

  void _setListenPort(String text) {
    final trimmed = text.trim();
    final port = trimmed.isEmpty ? null : int.tryParse(trimmed);
    if (trimmed.isNotEmpty && (port == null || port < 1 || port > 65535)) {
      setState(() => _listenPortError = 'Port must be 1-65535, or empty for the default');
      return;
    }
    if (_listenPortError != null) setState(() => _listenPortError = null);
    if (port == config.listenPort) return;
    config.listenPort = port;
    _changed();
  }

  Future<void> _editForwardTarget(ForwardTarget? existing) async {
    final label = TextEditingController(text: existing?.label ?? '');
    final host = TextEditingController(text: existing?.host ?? '127.0.0.1');
    final port = TextEditingController(text: existing?.port.toString() ?? '');
    var direction = existing?.direction ?? ForwardDirection.incoming;
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Forward to another app' : 'Edit forwarding'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(controller: label, decoration: const InputDecoration(labelText: 'Name (optional)')),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(flex: 3, child: TextField(controller: host, decoration: const InputDecoration(labelText: 'Host'))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<ForwardDirection>(
                  segments: const [
                    ButtonSegment(value: ForwardDirection.incoming, label: Text('VRChat output')),
                    ButtonSegment(value: ForwardDirection.outgoing, label: Text('My sends')),
                    ButtonSegment(value: ForwardDirection.both, label: Text('Both')),
                  ],
                  selected: {direction},
                  onSelectionChanged: (s) => setDialogState(() => direction = s.first),
                ),
                const SizedBox(height: 6),
                Text(
                  switch (direction) {
                    ForwardDirection.incoming =>
                      'Everything VRChat sends out (parameter changes, avatar changes) is copied here - point '
                          'an old OSC app at this port instead of 9001.',
                    ForwardDirection.outgoing =>
                      'Everything this app sends to VRChat is copied here too - e.g. a second PC or a lighting rig.',
                    ForwardDirection.both => 'Both of the above.',
                  },
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final p = int.tryParse(port.text.trim());
                final h = host.text.trim();
                if (h.isEmpty || h.contains(' ') || h.contains('/')) {
                  setDialogState(() => error = 'Enter an IP address or host name');
                } else if (p == null || p < 1 || p > 65535) {
                  setDialogState(() => error = 'Port must be 1-65535');
                } else if (direction != ForwardDirection.outgoing &&
                    (h == '127.0.0.1' || h == 'localhost') &&
                    p == config.port) {
                  // VRChat's own input port - its output would loop straight back in.
                  setDialogState(() => error = 'That\'s VRChat\'s input port - its output would loop back into it');
                } else {
                  Navigator.of(context).pop(true);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      final target = existing ?? ForwardTarget(host: '', port: 0);
      target
        ..label = label.text.trim()
        ..host = host.text.trim()
        ..port = int.parse(port.text.trim())
        ..direction = direction;
      if (existing == null) config.forwardTargets.add(target);
      _changed();
    }
    label.dispose();
    host.dispose();
    port.dispose();
  }

  // developer-mode-only since the server it targets can hang outright.
  void _setOscQueryFetchTimeout(String text) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || parsed < 1 || parsed > 120) {
      _oscQueryFetchTimeoutController.text = config.oscQueryFetchTimeoutSeconds.toString();
      return;
    }
    if (parsed == config.oscQueryFetchTimeoutSeconds) return;
    setState(() => config.oscQueryFetchTimeoutSeconds = parsed);
    _persist();
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
    _changed();
  }

  Future<void> _openAutomationMasterSwitchDialog() async {
    final changed = await showAutomationMasterSwitchDialog(context, config);
    if (!changed) return;
    _changed();
  }

  Future<void> _handleVersionTap() async {
    _versionTapCount++;
    if (_versionTapCount < 5) return;
    _versionTapCount = 0;

    if (config.developerModeUnlocked) {
      final confirmed = await showDisableDeveloperModeDialog(context);
      if (confirmed != true) return;
      config.developerMode = false;
      config.developerModeUnlocked = false;
      _changed();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Developer Mode disabled and hidden.')));
      }
    } else {
      config.developerModeUnlocked = true;
      _changed();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Developer Mode unlocked.')));
    }
  }

  Future<void> _setDeveloperMode(bool value) async {
    if (value && !config.developerModeWarningDismissed) {
      final dontShowAgain = await showDeveloperModeDialog(context);
      if (dontShowAgain == null) return; // cancelled
      if (dontShowAgain) config.developerModeWarningDismissed = true;
    }
    config.developerMode = value;
    _changed();
  }

  // ---- profiles ----

  Future<String?> _askName(String title, String initial, String action) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text.trim()), child: Text(action)),
        ],
      ),
    );
    controller.dispose();
    return (name == null || name.isEmpty) ? null : name;
  }

  Future<void> _saveParametersSnapshot() async {
    final snapshot = await showSaveParametersDialog(context, config.parameters, live.values);
    if (snapshot == null) return;
    config.profiles.add(snapshot);
    _changed();
  }

  void _applySnapshot(Profile snapshot) {
    live.applySnapshot(snapshot);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Applied "${snapshot.name}" to the active profile.')));
  }

  Future<void> _openSnapshotEditor(Profile snapshot) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SnapshotEditorPage(snapshot: snapshot, config: config, onPersist: _persist),
    ));
    if (mounted) setState(() {});
    _persist();
  }

  Future<void> _addProfile() async {
    final name = await _askName('New profile', '', 'Create');
    if (name == null) return;
    final profile = Profile(id: newId(), name: name);
    config.profiles.add(profile);
    live.switchProfile(profile.id);
  }

  Future<void> _duplicateProfile(Profile profile) async {
    final name = await _askName('Duplicate profile', '${profile.name} (copy)', 'Duplicate');
    if (name == null) return;
    final copy = Profile.fromJson(profile.toJson())
      ..id = newId()
      ..name = name
      // two profiles claiming one avatar would make auto mode ambiguous.
      ..avatarId = null;
    config.profiles.insert(config.profiles.indexOf(profile) + 1, copy);
    _changed();
  }

  Future<void> _renameProfile(Profile profile) async {
    final name = await _askName('Rename profile', profile.name, 'Save');
    if (name == null) return;
    profile.name = name;
    _changed();
  }

  void _unlinkProfile(Profile profile) {
    profile.avatarId = null;
    _changed();
  }

  Future<void> _exportProfile(Profile profile) async {
    await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(profile.toJson())));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Copied "${profile.name}" to the clipboard as JSON.')));
    }
  }

  Future<void> _importProfile() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic> || json['parameters'] is! List) {
        throw const FormatException('the clipboard doesn\'t hold an exported profile');
      }
      final profile = Profile.fromJson(json)
        ..id = newId()
        ..avatarId = null
        ..isSnapshot = false;
      if (config.profiles.any((p) => p.name == profile.name)) profile.name = '${profile.name} (imported)';
      config.profiles.add(profile);
      _changed();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported "${profile.name}" (${profile.parameters.length} parameters).')),
        );
      }
    } catch (e) {
      if (mounted) {
        await showErrorDialog(
          context,
          'Nothing to import',
          'Copy a profile\'s JSON (Export in its menu) to the clipboard first.\n\n$e',
        );
      }
    }
  }

  Future<void> _deleteProfile(Profile profile) async {
    // snapshots don't count toward (or need) the "at least one" minimum -
    // they're never required for the app to function.
    if (!profile.isSnapshot && config.profiles.where((p) => !p.isSnapshot).length <= 1) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('At least one profile has to stick around.')));
      return;
    }
    final ok = await confirmDialog(
      context,
      title: profile.isSnapshot ? 'Delete snapshot?' : 'Delete profile?',
      message: 'This removes "${profile.name}" and its ${profile.parameters.length} parameters.',
    );
    if (!ok) return;
    final wasActive = config.activeProfileId == profile.id;
    config.profiles.remove(profile);
    if (wasActive) {
      live.switchProfile(config.profiles.firstWhere((p) => !p.isSnapshot).id);
    } else {
      _changed();
    }
  }

  Future<void> _showProfileMenu(Profile profile, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: [
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
        const PopupMenuItem(value: 'export', child: Text('Export (copy JSON)')),
        if (profile.avatarId != null) const PopupMenuItem(value: 'unlink', child: Text('Unlink from avatar')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    switch (selected) {
      case 'rename':
        await _renameProfile(profile);
      case 'duplicate':
        await _duplicateProfile(profile);
      case 'export':
        await _exportProfile(profile);
      case 'unlink':
        _unlinkProfile(profile);
      case 'delete':
        await _deleteProfile(profile);
    }
  }

  // ---- parameters ----

  Future<void> _addParam() async {
    final result = await showParamFormDialog(context, takenNames: {for (final p in config.parameters) p.name});
    if (result == null) return;
    live.addParam(result);
  }

  Future<void> _editParam(ParamControl param) async {
    final result = await showParamFormDialog(
      context,
      existing: param,
      takenNames: {for (final p in config.parameters) p.name},
    );
    if (result == null) return;
    live.replaceParam(param, result);
  }

  Future<void> _deleteParam(ParamControl param) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete parameter?',
      message: 'Remove "${param.label}" from this profile?',
    );
    if (ok) live.removeParam(param);
  }

  // shared two-step "are you sure / are you REALLY sure" flow for every
  // Danger Zone action - true only if the user confirmed both dialogs.
  Future<bool> _confirmDangerAction({
    required String title,
    required String warning,
    required String finalWarning,
    required String confirmLabel,
  }) async {
    if (!await confirmDialog(context, title: title, message: warning, confirmLabel: 'Continue')) return false;
    if (!mounted) return false;
    return confirmDialog(context, title: 'Are you absolutely sure?', message: finalWarning, confirmLabel: confirmLabel);
  }

  Future<void> _deleteAll() async {
    final count = config.parameters.length;
    if (count == 0) return;
    final confirmed = await _confirmDangerAction(
      title: 'Delete all parameters?',
      warning: 'This will remove all $count parameters from "${config.activeProfile.name}". This cannot be undone.',
      finalWarning: 'Last chance - all $count parameters will be permanently deleted from config.json.',
      confirmLabel: 'Delete Everything',
    );
    if (!confirmed) return;
    config.parameters.clear();
    _changed();
  }

  Future<void> _deleteAllProfiles() async {
    final count = config.profiles.length;
    final confirmed = await _confirmDangerAction(
      title: 'Delete all profiles?',
      warning: 'This removes all $count profiles and everything in them - parameters, automations, '
          'sequences, snapshots - replacing them with a single empty "Default" profile. This cannot be undone.',
      finalWarning: 'Last chance - all $count profiles will be permanently deleted from config.json.',
      confirmLabel: 'Delete Everything',
    );
    if (!confirmed) return;
    config.profiles
      ..clear()
      ..add(Profile(id: newId(), name: 'Default'));
    config.sanitize();
    live.replaceConfig(config);
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
    final fresh = AppConfig(host: '127.0.0.1', port: 9000, parameters: []);
    live.replaceConfig(fresh);
    _hostController.text = fresh.host;
    _portController.text = fresh.port.toString();
    _liveParamNoiseThresholdController.text = fresh.liveParamNoiseThreshold.toString();
    _oscQueryFetchTimeoutController.text = fresh.oscQueryFetchTimeoutSeconds.toString();
    _listenPortController.text = '';
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(child: _centered(_buildHeader(context))),
            ),
            if (config.parameters.isEmpty)
              SliverToBoxAdapter(
                child: _centered(const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('No parameters in this profile yet.'),
                )),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverReorderableList(
                  itemCount: config.parameters.length,
                  onReorderItem: live.reorderParam,
                  itemBuilder: (context, index) {
                    final param = config.parameters[index];
                    return _centered(
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        child: ListTile(
                          dense: true,
                          leading: ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle)),
                          title: Text(param.label),
                          subtitle: Text(
                            '${param.name}'
                            '${param.category != null ? '  ·  ${param.category}' : ''}'
                            '  ·  ${_typeLabel(param)}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editParam(param)),
                              IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteParam(param)),
                            ],
                          ),
                        ),
                      ),
                      key: ValueKey('settings-param:${param.name}'),
                    );
                  },
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(child: _centered(_buildFooter(context))),
            ),
          ],
        ),
      ),
    );
  }

  // settings read better as a column than stretched across a wide window.
  Widget _centered(Widget child, {Key? key}) => Align(
        key: key,
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: child),
      );

  Widget _sectionTitle(BuildContext context, String text, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Row(
          children: [
            Expanded(child: Text(text, style: Theme.of(context).textTheme.titleLarge)),
            ?trailing,
          ],
        ),
      );

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, 'Connection', trailing: ConnectionChip(live: live)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostController,
                decoration: InputDecoration(
                  labelText: 'Send to host',
                  helperText: PlatformPaths.isMobile
                      ? 'The IP of the PC or Quest running VRChat'
                      : '127.0.0.1 for VRChat on this PC, or a Quest\'s IP',
                  errorText: _hostError,
                ),
                onSubmitted: (_) => _saveConnection(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 1,
              child: TextField(
                controller: _portController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'Port', helperText: 'VRChat: 9000', errorText: _portError),
                onSubmitted: (_) => _saveConnection(),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton(onPressed: _saveConnection, child: const Text('Save')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (Platform.isAndroid)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep the screen on'),
            subtitle: const Text('Handy when using this phone as a remote. Automations pause when the screen is off.'),
            value: config.keepScreenOn,
            onChanged: (v) {
              setState(() => config.keepScreenOn = v);
              AndroidPlatform.keepScreenOn(v);
              _persist();
            },
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sync values from VRChat'),
          subtitle: const Text(
            'Mirror changes made in-game (radial menu, contacts, physbones) onto the dashboard, so it always '
            'shows the avatar\'s real state and triggers can react to them.',
          ),
          value: config.syncFromVrchat,
          onChanged: (v) {
            config.syncFromVrchat = v;
            _changed();
          },
        ),
        Text(
          PlatformPaths.isMobile
              ? 'Receiving: VRChat only sends its output to apps on its own computer. To get it here, forward '
                    'it from OSCSlider on your PC (Settings > Other OSC apps) to this phone, port '
                    '${effectiveListenPort(config)}.'
              : 'Receiving: this app advertises its own OSCQuery service, so VRChat sends to it directly - '
                    'no fixed port needed, and other OSC apps (face tracking, VRCOSC...) keep working alongside it.'
                    '${oscInputHub.service?.oscPort != null ? ' (listening on port ${oscInputHub.service!.oscPort})' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        _sectionTitle(
          context,
          'Other OSC apps',
          trailing: TextButton.icon(
            onPressed: () => _editForwardTarget(null),
            icon: const Icon(Icons.add),
            label: const Text('Forward to...'),
          ),
        ),
        Text(
          'Relay VRChat\'s output on to apps that can\'t use OSCQuery (so they don\'t need port 9001 to '
          'themselves), and/or copy everything this app sends to another device.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        for (final target in config.forwardTargets)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 3),
            child: ListTile(
              dense: true,
              leading: Switch(
                value: target.enabled,
                onChanged: (v) {
                  target.enabled = v;
                  _changed();
                },
              ),
              title: Text(target.label.isEmpty ? '${target.host}:${target.port}' : target.label),
              subtitle: Text([
                if (target.label.isNotEmpty) '${target.host}:${target.port}',
                switch (target.direction) {
                  ForwardDirection.incoming => 'VRChat\'s output → here',
                  ForwardDirection.outgoing => 'this app\'s sends → here',
                  ForwardDirection.both => 'both directions → here',
                },
              ].join('  ·  ')),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editForwardTarget(target)),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      config.forwardTargets.remove(target);
                      _changed();
                    },
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _listenPortController,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Fallback listen port',
            hintText: '${config.port + 1} (send port + 1)',
            helperText: 'Only used for OSC software without OSCQuery - VRChat doesn\'t need it. Change it if '
                'you launch VRChat with a custom --osc output port.',
            helperMaxLines: 4,
            errorText: _listenPortError,
          ),
          onSubmitted: _setListenPort,
          onTapOutside: (_) {
            _setListenPort(_listenPortController.text);
            FocusManager.instance.primaryFocus?.unfocus();
          },
        ),
        _sectionTitle(context, 'Theme Color'),
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
              selected: !Colors.primaries.any((c) => c.toARGB32() == config.themeSeedColor.toARGB32()) ||
                  config.primaryOverride != null ||
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
          _sectionTitle(context, 'Unlocked Features'),
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
        _sectionTitle(
          context,
          'Profiles',
          trailing: Wrap(
            children: [
              TextButton.icon(onPressed: _importProfile, icon: const Icon(Icons.content_paste), label: const Text('Import')),
              TextButton.icon(onPressed: _addProfile, icon: const Icon(Icons.add), label: const Text('New')),
            ],
          ),
        ),
        RadioGroup<String>(
          groupValue: config.activeProfileId,
          onChanged: (id) {
            if (id != null) live.switchProfile(id);
          },
          child: Column(
            children: [
              for (final profile in config.profiles.where((p) => !p.isSnapshot))
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  child: RadioListTile<String>(
                    value: profile.id,
                    title: Text(profile.name),
                    subtitle: Text(
                      '${_plural(profile.parameters.length, 'parameter')}'
                      '${profile.sequences.isNotEmpty ? '  ·  ${_plural(profile.sequences.length, 'sequence')}' : ''}'
                      '${profile.avatarId != null ? '  ·  linked to an avatar' : ''}',
                    ),
                    secondary: Builder(
                      builder: (buttonContext) => IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () {
                          final box = buttonContext.findRenderObject() as RenderBox;
                          _showProfileMenu(profile, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto Mode'),
          subtitle: const Text(
            'Watches for VRChat avatar changes and automatically switches to (or creates) the matching '
            'profile. Off by default since it passively listens for which avatar you\'re wearing.',
          ),
          value: config.autoProfileMode,
          onChanged: (v) {
            config.autoProfileMode = v;
            _changed();
          },
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.only(left: 16),
          title: const Text('Create profiles for new avatars'),
          subtitle: const Text('Off: only switch between profiles you\'ve already linked to an avatar'),
          value: config.autoProfileCreate,
          onChanged: config.autoProfileMode
              ? (v) {
                  config.autoProfileCreate = v;
                  _changed();
                }
              : null,
        ),
        _sectionTitle(
          context,
          'Saved Snapshots',
          trailing: TextButton.icon(
            onPressed: _saveParametersSnapshot,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save current values'),
          ),
        ),
        Text(
          'Static saves of parameter values - never auto-switched to, never touched by live avatar changes. '
          'Apply pushes their saved values onto whatever profile is active now.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        for (final profile in config.profiles.where((p) => p.isSnapshot))
          Card(
            margin: const EdgeInsets.symmetric(vertical: 3),
            child: ListTile(
              onTap: () => _openSnapshotEditor(profile),
              leading: const Icon(Icons.bookmark_outline),
              title: Text(profile.name),
              subtitle: Text(_plural(profile.parameters.length, 'parameter')),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.tonal(onPressed: () => _applySnapshot(profile), child: const Text('Apply')),
                  IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _openSnapshotEditor(profile)),
                  IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteProfile(profile)),
                ],
              ),
            ),
          ),
        _sectionTitle(
          context,
          'Parameters',
          trailing: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text('${config.parameters.length} in "${config.activeProfile.name}"  ·  drag to reorder',
                  style: theme.textTheme.bodySmall),
              TextButton.icon(onPressed: _addParam, icon: const Icon(Icons.add), label: const Text('Add')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, 'Miscellaneous'),
        TextField(
          controller: _liveParamNoiseThresholdController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Highlight noise filter (changes/sec)',
            helperText: 'In the discover popup\'s "highlight active" mode, a parameter that keeps changing at '
                'least this often for several seconds is treated as noise and stops jumping to the top '
                '(0 = never filter).',
            helperMaxLines: 4,
          ),
          onSubmitted: _setLiveParamNoiseThreshold,
          onTapOutside: (_) {
            _setLiveParamNoiseThreshold(_liveParamNoiseThresholdController.text);
            FocusManager.instance.primaryFocus?.unfocus();
          },
        ),
        if (config.developerMode) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _oscQueryFetchTimeoutController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'OSCQuery fetch timeout (seconds)',
              helperText: 'How long Discover waits on VRChat\'s OSCQuery server for the full parameter '
                  'list before falling back. Some avatars make VRChat hang on this outright, so lower it '
                  'to fall back faster.',
              helperMaxLines: 4,
            ),
            onSubmitted: _setOscQueryFetchTimeout,
            onTapOutside: (_) {
              _setOscQueryFetchTimeout(_oscQueryFetchTimeoutController.text);
              FocusManager.instance.primaryFocus?.unfocus();
            },
          ),
        ],
        _sectionTitle(
          context,
          'Updates',
          trailing: _checkingUpdate
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton.icon(
                  onPressed: _checkForUpdate,
                  icon: const Icon(Icons.system_update_alt),
                  label: const Text('Check now'),
                ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Check for updates when OSCSlider starts'),
          value: config.checkUpdatesOnStartup,
          onChanged: (v) {
            setState(() => config.checkUpdatesOnStartup = v);
            _persist();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include pre-releases'),
          subtitle: const Text('Betas get new features first, but may have bugs'),
          value: config.includePrereleaseUpdates,
          onChanged: (v) {
            setState(() => config.includePrereleaseUpdates = v);
            _persist();
          },
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              // main screen starts the tour once settings is closed.
              onPressed: () => Navigator.of(context).pop('tour'),
              icon: const Icon(Icons.school_outlined),
              label: const Text('Show the tour again'),
            ),
            if (!PlatformPaths.isMobile)
              TextButton.icon(
                onPressed: () => launchUrl(Uri.directory(ConfigStore.directory)),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Open config folder'),
              ),
          ],
        ),
        const SizedBox(height: 16),
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
            'Full-precision slider values, a configurable OSCQuery timeout, and discovery/fetching from any '
            'OSCQuery service instead of only VRChat.',
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

  // a manual check ignores "skip this version" and reports failures.
  Future<void> _checkForUpdate() async {
    setState(() => _checkingUpdate = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final current = await currentAppVersion();
      final update = await checkForUpdate(current, includePrereleases: config.includePrereleaseUpdates);
      if (!mounted) return;
      if (update == null) {
        messenger.showSnackBar(SnackBar(content: Text('You\'re on the latest version (v$current).')));
      } else {
        await showUpdateDialog(context, info: update, currentVersion: current, live: live);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t check for updates: $e')));
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  String _typeLabel(ParamControl param) {
    return switch (param.type) {
      ParamType.slider => 'slider (${param.numericKind == NumericKind.int ? 'int' : 'float'})',
      ParamType.toggle => 'toggle',
      ParamType.custom => 'custom (${param.customTypeTag})',
      ParamType.button => 'button (${param.buttonMode == ButtonMode.hold ? 'hold' : 'tap'})',
      ParamType.chatbox => 'chatbox',
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
  final bool selected;
  final VoidCallback onTap;

  const _CustomSwatch({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Custom color',
      child: InkWell(
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
