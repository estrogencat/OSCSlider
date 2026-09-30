import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updater.dart';
import 'automation_dialog.dart';
import 'automation_master_switch_dialog.dart';
import 'config_store.dart';
import 'connection_status.dart';
import 'crash_log.dart';
import 'discovery_flow.dart';
import 'discovery_sheet.dart';
import 'error_dialog.dart';
import 'live_controller.dart';
import 'osc_input_hub.dart';
import 'param_card.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';
import 'sequence_editor_page.dart';
import 'sequences_page.dart';
import 'settings_page.dart';
import 'theme_notifier.dart';
import 'tutorial.dart';
import 'update_dialog.dart';

void main() {
  // OSC/networking code (socket sends, discovery, HTTP fetches) fires
  // frequently and mostly unawaited - a transient error there would
  // otherwise be an uncaught async error that silently kills the app with
  // no trace. this is the last-resort net; see CrashLog for where it lands.
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      CrashLog.record(details.exception, details.stack, context: 'FlutterError');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      CrashLog.record(error, stack, context: 'platform');
      return true;
    };
    runApp(const OscSliderApp());
  }, (error, stack) => CrashLog.record(error, stack, context: 'uncaught'));
}

class OscSliderApp extends StatelessWidget {
  const OscSliderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeSettings>(
      valueListenable: themeSettingsNotifier,
      builder: (context, settings, _) {
        return MaterialApp(
          title: 'OSCSlider',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(settings.buildScheme()),
          home: const HomePage(),
        );
      },
    );
  }
}

ThemeData buildAppTheme(ColorScheme scheme) => ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Roboto',
      // hints under fields wrap instead of trailing off on narrow screens.
      inputDecorationTheme: const InputDecorationThemeData(helperMaxLines: 4, errorMaxLines: 3),
    );

class HomePage extends StatefulWidget {
  /// tests skip the network-y startup bits (update check, OSCQuery) and
  /// hand in a config instead of reading config.json.
  final bool startServices;
  final AppConfig? initialConfig;
  const HomePage({super.key, this.startServices = true, this.initialConfig});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  LiveController? _live;
  ConfigLoadException? _loadError;
  bool _discovering = false;
  bool _pulling = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final Set<String> _collapsedCategories = {};
  AppLifecycleListener? _lifecycle;
  bool _touring = false;
  final _tourChipKey = GlobalKey();
  final _tourDiscoverKey = GlobalKey();
  final _tourProfileKey = GlobalKey();
  final _tourCardKey = GlobalKey();
  final _tourAutomationKey = GlobalKey();
  final _tourAddKey = GlobalKey();
  final _tourSequencesKey = GlobalKey();
  final _tourMoreKey = GlobalKey();
  final _tourSettingsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    final initial = widget.initialConfig;
    if (initial != null) {
      _live = LiveController(initial)..onNotice = _notice;
    } else {
      _load();
    }
    if (widget.startServices) {
      _checkForUpdateSilently();
      _checkForDuplicateInstance();
    }
  }

  // closing the window: let any pending config write land, and tell VRChat
  // (via an mDNS goodbye) to stop sending to this app's OSCQuery port.
  Future<AppExitResponse> _onExitRequested() async {
    try {
      await Future.wait([ConfigStore.flush(), oscInputHub.stop()]).timeout(const Duration(seconds: 2));
    } catch (_) {}
    return AppExitResponse.exit;
  }

  Future<void> _load({Future<AppConfig> Function()? loader}) async {
    try {
      final config = await (loader ?? ConfigStore.load)();
      if (!mounted) return;
      setState(() {
        _loadError = null;
        final live = _live;
        if (live == null) {
          _live = LiveController(config)..onNotice = _notice;
        } else {
          // reconcile rather than hard-reset - values that still fit keep
          // what's live instead of snapping back to their defaults.
          live.replaceConfig(config);
        }
      });
      if (widget.startServices && !config.tutorialSeen) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _startTour());
      }
      if (widget.startServices) {
        // reconciling again once the service is up lets forwarding skip
        // this app's own (now known) ports.
        unawaited(oscInputHub.start(legacyPort: effectiveListenPort(config)).then((_) => _live?.reconcile()));
      }
    } on ConfigLoadException catch (e) {
      if (mounted) setState(() => _loadError = e);
    } catch (e) {
      if (mounted) setState(() => _loadError = ConfigLoadException(e.toString(), backupAvailable: false));
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // silent - only shows anything if a newer release is actually found.
  Future<void> _checkForUpdateSilently() async {
    try {
      // config loads asynchronously, and the check shouldn't slow startup.
      await Future.delayed(const Duration(seconds: 3));
      final live = _live;
      if (live == null || !live.config.checkUpdatesOnStartup) return;
      final current = await currentAppVersion();
      if (isDevVersion(current)) return;
      final update = await checkForUpdate(current, includePrereleases: live.config.includePrereleaseUpdates);
      if (update == null || update.version == live.config.skippedUpdateVersion || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('OSCSlider v${update.version} is available.'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Details',
            onPressed: () => showUpdateDialog(context, info: update, currentVersion: current, live: live),
          ),
        ),
      );
    } catch (_) {}
  }

  // two copies running at once would both drive the same parameters and
  // fight over them. warn once on launch; dismiss only.
  Future<void> _checkForDuplicateInstance() async {
    if (!Platform.isWindows) return;
    try {
      final exeName = Platform.resolvedExecutable.split(Platform.pathSeparator).last;
      final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq $exeName', '/FO', 'CSV', '/NH']);
      final count = exeName.toLowerCase().allMatches((result.stdout as String).toLowerCase()).length;
      if (count <= 1 || !mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Another OSCSlider is already running'),
          content: const Text(
            'Both copies will send to VRChat independently - automations or sequences running in '
            'both will fight over the same parameters, and they\'ll overwrite each other\'s '
            'config.json. Close one of them if that isn\'t what you meant.',
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Dismiss'))],
        ),
      );
    } catch (_) {
      // best-effort - if tasklist itself fails for any reason, just skip the warning.
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _live?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ---- automation button / sequence links ----

  Future<void> _openAutomationDialog(ParamControl param) async {
    final live = _live!;
    final changed = await showAutomationDialog(context, param, live.parameters);
    if (!changed) return;
    live.persist();
    live.reconcile();
  }

  // schedules are folded into the same dialog as automations now (just
  // another "Type" option), so one button covers both.
  Widget _automationButton(ParamControl param) {
    final live = _live!;
    final auto = param.automation;
    final sched = param.schedule;
    final scheme = Theme.of(context).colorScheme;

    final owners = live.sequences.where((s) => s.paramAutomations.containsKey(param.name)).toList();
    // only surface "linked to a sequence" while some owning sequence is
    // actually enabled - a disabled sequence's stale link shouldn't
    // permanently block reaching this parameter's own automation.
    final activeOwners = owners.where((s) => s.enabled).toList();
    final runningOwners = activeOwners.where((s) => sequenceActivelyDrivesParam(s, param.name)).toList();
    final sequenceActive = runningOwners.isNotEmpty;

    // a sequence actively driving this parameter wins over (and hides) its
    // global automation/schedule, matching the tick loop's own suppression.
    final ownRunning = !sequenceActive && ((auto?.enabled ?? false) || (sched?.enabled ?? false));

    if (!ownRunning && activeOwners.isNotEmpty) {
      final name = sequenceActive ? runningOwners.first.name : activeOwners.first.name;
      final verb = sequenceActive ? 'Driven' : 'Linked (not running)';
      return IconButton(
        icon: Icon(sequenceActive ? Icons.auto_awesome : Icons.auto_awesome_outlined),
        color: sequenceActive ? scheme.tertiary : scheme.onSurfaceVariant,
        tooltip: activeOwners.length == 1
            ? '$verb by sequence "$name" - tap to manage'
            : '$verb by ${activeOwners.length} sequences - tap to manage',
        // the management dialog still lists every linked sequence, including
        // disabled ones, so a stale link can be found and removed there too.
        onPressed: () => _manageSequenceAutomation(param, owners),
      );
    }

    final configured = auto != null || sched != null;
    return IconButton(
      icon: Icon(ownRunning ? Icons.auto_awesome : Icons.auto_awesome_outlined),
      color: ownRunning ? scheme.primary : (configured ? scheme.onSurfaceVariant : scheme.outline),
      tooltip: ownRunning
          ? 'Automation running - tap to edit'
          : (configured ? 'Automation paused - tap to edit' : 'Add automation'),
      onPressed: () => _openAutomationDialog(param),
    );
  }

  Future<void> _manageSequenceAutomation(ParamControl param, List<AutomationSequence> owners) async {
    final live = _live!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => ListenableBuilder(
        listenable: live,
        builder: (dialogContext, _) {
          final anyRunning = owners.any((s) => sequenceActivelyDrivesParam(s, param.name));
          return AlertDialog(
            title: Text('"${param.label}" automation'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    anyRunning
                        ? 'Its value is being driven by a sequence\'s own automation right now.'
                        : 'It\'s linked to a sequence automation below, but nothing is currently driving it.',
                  ),
                  const SizedBox(height: 12),
                  for (final seq in owners.where((s) => s.paramAutomations.containsKey(param.name)))
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        title: Text(seq.name),
                        subtitle: Text(
                          !seq.enabled
                              ? 'Sequence not running'
                              : !(seq.paramAutomations[param.name]?.enabled ?? false)
                              ? 'Paused in this sequence'
                              : sequenceActivelyDrivesParam(seq, param.name)
                              ? 'Running'
                              : 'Suppressed - a step in this sequence also targets this parameter',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: seq.paramAutomations[param.name]?.enabled ?? false,
                              onChanged: (v) {
                                seq.paramAutomations[param.name]?.enabled = v;
                                live.persist();
                                live.reconcile();
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.open_in_new),
                              tooltip: 'Open sequence',
                              onPressed: () {
                                Navigator.of(dialogContext).pop();
                                _openSequenceEditor(seq);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.link_off),
                              tooltip: 'Remove this automation from the sequence',
                              onPressed: () {
                                seq.paramAutomations.remove(param.name);
                                live.persist();
                                live.reconcile();
                                Navigator.of(dialogContext).pop();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              // only offered while nothing here is actively driving the
              // parameter - otherwise turning the global automation on
              // would need pausing every active sequence link first.
              if (!anyRunning)
                TextButton.icon(
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit global automation'),
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    _openAutomationDialog(param);
                  },
                ),
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
            ],
          );
        },
      ),
    );
  }

  // ---- navigation ----

  Future<void> _openSequenceEditor(AutomationSequence sequence) async {
    final live = _live;
    if (live == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SequenceEditorPage(sequence: sequence, live: live),
      ),
    );
    live.persist();
    live.reconcile();
  }

  Future<void> _openSettings() async {
    final live = _live;
    if (live == null) return;
    final result = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => SettingsPage(live: live)));
    live.persist();
    live.reconcile();
    if (result == 'tour') _startTour();
  }

  // ---- tour ----

  Future<void> _startTour() async {
    final live = _live;
    if (live == null || _touring || !mounted) return;
    _touring = true;
    final seqInMenu = _tourSequencesKey.currentContext == null;
    try {
      await showTour(context, [
        const TourStep(
          icon: Icons.waving_hand_outlined,
          title: 'Welcome to OSCSlider!',
          body:
              'OSCSlider lets you control your VRChat avatar from your computer.\n\n'
              'This quick tour shows you what each button does. It takes about a minute.',
        ),
        TourStep(
          target: _tourChipKey,
          icon: Icons.wifi_tethering,
          title: 'Connection',
          body:
              'This shows if OSCSlider can find VRChat. Green means it\'s connected.\n\n'
              'Not green? In VRChat, open the Action Menu, go to Options, then OSC, and turn it on.',
        ),
        TourStep(
          target: _tourDiscoverKey,
          icon: Icons.wifi_find,
          title: 'Find your avatar\'s parameters',
          body:
              'Press this while VRChat is running. It lists everything your avatar can do, '
              'like toggles and sliders. Tick the ones you want, then add them.',
        ),
        TourStep(
          target: _tourCardKey,
          needsTarget: true,
          icon: Icons.tune,
          title: 'Controls',
          body:
              'Each card controls one thing on your avatar. Move the slider or flip the switch, '
              'and your avatar changes right away.\n\n'
              'Right-click a card (or press its three dots) to edit or delete it.',
        ),
        TourStep(
          target: _tourAutomationKey,
          needsTarget: true,
          icon: Icons.auto_mode,
          title: 'Make it move by itself',
          body:
              'This button makes a control move on its own. It can fade back and forth, '
              'pick random values, blink, or change at a set time.',
        ),
        TourStep(
          target: _tourAddKey,
          needsTarget: true,
          icon: Icons.add,
          title: 'Add your own',
          body:
              'Add a control by hand. There\'s also a list of VRChat\'s own controls, '
              'like jump, walking and the chatbox.',
        ),
        TourStep(
          target: _tourProfileKey,
          icon: Icons.person_outline,
          title: 'Profiles',
          body:
              'Each avatar can have its own set of controls. Click here to switch between them.\n\n'
              'Turn on Auto Mode in Settings, and it switches for you when you change avatar.',
        ),
        TourStep(
          // on a narrow screen Sequences lives in the ⋮ menu.
          target: seqInMenu ? _tourMoreKey : _tourSequencesKey,
          icon: Icons.playlist_play,
          title: 'Sequences',
          body:
              'A sequence does several things in order, like a little script. '
              'For example: turn on the ears, wait 2 seconds, then wave.'
              '${seqInMenu ? '\n\nYou\'ll find Sequences in this menu.' : ''}',
        ),
        TourStep(
          target: _tourMoreKey,
          icon: Icons.more_vert,
          title: 'More options',
          body: 'Grab your avatar\'s current values from VRChat, or send all of yours again.',
        ),
        TourStep(
          target: _tourSettingsKey,
          icon: Icons.settings_outlined,
          title: 'Settings',
          body:
              'Connection options, profiles, colours and updates are in here.\n\n'
              'You can watch this tour again from Settings at any time.',
        ),
      ]);
    } finally {
      _touring = false;
      if (!live.config.tutorialSeen) {
        live.config.tutorialSeen = true;
        live.persist();
      }
    }
  }

  // sequences moved out of Settings into their own space since each one now
  // embeds a full parameter/automation panel - too much to bury in a scroll
  // section.
  Future<void> _openSequencesPage() async {
    final live = _live;
    if (live == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SequencesPage(live: live)));
    live.persist();
    live.reconcile();
  }

  // ---- parameter actions ----

  Future<void> _addParamManually() async {
    final live = _live;
    if (live == null) return;
    final control = await showParamFormDialog(context, takenNames: {for (final p in live.parameters) p.name});
    if (control == null) return;
    live.addParam(control);
  }

  Future<void> _editParam(ParamControl param) async {
    final live = _live!;
    final result = await showParamFormDialog(
      context,
      existing: param,
      takenNames: {for (final p in live.parameters) p.name},
    );
    if (result == null) return;
    live.replaceParam(param, result);
  }

  Future<void> _deleteParam(ParamControl param) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete parameter?',
      message: 'Remove "${param.label}" from this profile? Its automation goes with it.',
    );
    if (ok) _live?.removeParam(param);
  }

  Future<void> _showParamMenu(Offset globalPosition, ParamControl param) async {
    final live = _live!;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: [
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit')),
        ),
        if (param.isAutomatable)
          const PopupMenuItem(
            value: 'automation',
            child: ListTile(leading: Icon(Icons.auto_awesome_outlined), title: Text('Automation...')),
          ),
        if (param.isAutomatable)
          const PopupMenuItem(
            value: 'fetch',
            child: ListTile(leading: Icon(Icons.download_outlined), title: Text('Fetch value from VRChat')),
          ),
        if (param.type != ParamType.chatbox)
          const PopupMenuItem(
            value: 'resend',
            child: ListTile(leading: Icon(Icons.replay), title: Text('Resend value')),
          ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete')),
        ),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case 'edit':
        await _editParam(param);
      case 'automation':
        await _openAutomationDialog(param);
      case 'fetch':
        await _fetchValue(param);
      case 'resend':
        live.resend(param);
      case 'delete':
        await _deleteParam(param);
    }
  }

  // pulls the parameter's current live value from VRChat's OSCQuery tree and
  // snaps the local display to it - read-only, nothing is sent back over OSC.
  Future<void> _fetchValue(ParamControl param) async {
    final live = _live!;
    final value = await fetchLiveValue(
      context,
      param,
      developerMode: live.config.developerMode,
      timeout: Duration(seconds: live.config.oscQueryFetchTimeoutSeconds),
    );
    if (value == null || !mounted) return;
    if ((param.type == ParamType.toggle && value is bool) || (param.type == ParamType.slider && value is double)) {
      live.setLocalValue(param, value);
    } else {
      _notice('"${param.label}" is a different type on the avatar - not applied.');
    }
  }

  Future<void> _pullAllValues() async {
    final live = _live;
    if (live == null) return;
    setState(() => _pulling = true);
    try {
      final found = await fetchAllLiveValues(
        developerMode: live.config.developerMode,
        timeout: Duration(seconds: live.config.oscQueryFetchTimeoutSeconds),
      );
      final count = live.applyReportedValues(found);
      _notice(count == 0 ? 'Everything already matches VRChat.' : 'Updated $count parameters from VRChat.');
    } catch (e) {
      if (mounted) await showErrorDialog(context, 'Could not read values from VRChat', e.toString());
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
  }

  Future<void> _discover() async {
    final live = _live;
    if (live == null) return;
    setState(() => _discovering = true);
    try {
      final result = await loadDiscovery(
        developerMode: live.config.developerMode,
        timeout: Duration(seconds: live.config.oscQueryFetchTimeoutSeconds),
      );
      if (!mounted) return;
      setState(() => _discovering = false);
      await showDiscoveryResultsSheet(
        context,
        result: result,
        noiseThreshold: live.config.liveParamNoiseThreshold,
        existingNames: {for (final p in live.parameters) p.name},
        onAdd: live.addParam,
      );
    } catch (e) {
      if (mounted) await showErrorDialog(context, 'Discovery failed', e.toString());
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _onMenu(String value) async {
    final live = _live;
    switch (value) {
      case 'pull':
        await _pullAllValues();
      case 'resend':
        if (live == null) return;
        for (final p in live.parameters) {
          if (p.isAutomatable) live.resend(p);
        }
        _notice('Resent ${live.parameters.where((p) => p.isAutomatable).length} values.');
      case 'reload':
        await _load();
        _notice('Reloaded config.json');
      case 'folder':
        await launchUrl(Uri.directory(ConfigStore.directory));
      case 'tour':
        await _startTour();
      case 'sequences':
        await _openSequencesPage();
    }
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final live = _live;
    // phones and small windows: the chip shrinks to a dot and Sequences
    // moves into the ⋮ menu, so the profile name still fits.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        title: live == null ? const Text('OSCSlider') : _buildProfileSwitcher(live),
        actions: [
          if (live != null)
            KeyedSubtree(
              key: _tourChipKey,
              child: ConnectionChip(live: live, compact: narrow),
            ),
          IconButton(
            key: _tourDiscoverKey,
            icon: _discovering
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_find),
            tooltip: 'Discover parameters from VRChat',
            onPressed: _discovering || live == null ? null : _discover,
          ),
          if (!narrow)
            IconButton(
              key: _tourSequencesKey,
              icon: const Icon(Icons.playlist_play),
              tooltip: 'Sequences',
              onPressed: live == null ? null : _openSequencesPage,
            ),
          IconButton(
            key: _tourSettingsKey,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: live == null ? null : _openSettings,
          ),
          PopupMenuButton<String>(
            key: _tourMoreKey,
            tooltip: 'More',
            enabled: live != null,
            onSelected: _onMenu,
            itemBuilder: (context) => [
              if (narrow) ...[
                const PopupMenuItem(
                  value: 'sequences',
                  child: ListTile(leading: Icon(Icons.playlist_play), title: Text('Sequences')),
                ),
                const PopupMenuDivider(),
              ],
              PopupMenuItem(
                value: 'pull',
                enabled: !_pulling,
                child: const ListTile(
                  leading: Icon(Icons.download_outlined),
                  title: Text('Pull current values from VRChat'),
                ),
              ),
              const PopupMenuItem(
                value: 'resend',
                child: ListTile(leading: Icon(Icons.upload_outlined), title: Text('Resend all values')),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'reload',
                child: ListTile(leading: Icon(Icons.refresh), title: Text('Reload config.json')),
              ),
              const PopupMenuItem(
                value: 'folder',
                child: ListTile(leading: Icon(Icons.folder_open_outlined), title: Text('Open config folder')),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'tour',
                child: ListTile(leading: Icon(Icons.school_outlined), title: Text('Show the tour')),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: live == null
          ? null
          : ListenableBuilder(
              listenable: live,
              // the empty state has its own add button.
              builder: (context, _) => live.parameters.isEmpty
                  ? const SizedBox.shrink()
                  : FloatingActionButton.extended(
                      key: _tourAddKey,
                      onPressed: _addParamManually,
                      icon: const Icon(Icons.add),
                      label: const Text('Add parameter'),
                    ),
            ),
      body: Column(
        children: [
          ValueListenableBuilder<String?>(
            valueListenable: ConfigStore.lastSaveError,
            builder: (context, error, _) => error == null
                ? const SizedBox.shrink()
                : MaterialBanner(
                    backgroundColor: Theme.of(context).colorScheme.errorContainer,
                    leading: const Icon(Icons.save_outlined),
                    content: Text('Couldn\'t save config.json - changes may be lost.\n$error'),
                    actions: [TextButton(onPressed: () => _live?.persist(), child: const Text('Retry'))],
                  ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildProfileSwitcher(LiveController live) {
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) => PopupMenuButton<String>(
        key: _tourProfileKey,
        tooltip: 'Switch profile',
        onSelected: (id) {
          if (id == '__manage') {
            _openSettings();
          } else {
            live.switchProfile(id);
          }
        },
        itemBuilder: (context) => [
          // snapshot profiles aren't selectable as the active profile.
          for (final p in live.config.profiles.where((p) => !p.isSnapshot))
            PopupMenuItem(
              value: p.id,
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: p.id == live.config.activeProfileId ? const Icon(Icons.check, size: 18) : null,
                  ),
                  Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                  if (p.avatarId != null) ...[const SizedBox(width: 6), const Icon(Icons.link, size: 14)],
                ],
              ),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: '__manage', child: Text('Manage profiles...')),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(live.config.activeProfile.name, overflow: TextOverflow.ellipsis)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final loadError = _loadError;
    if (loadError != null) return _buildLoadError(context, loadError);

    final live = _live;
    if (live == null) return const Center(child: CircularProgressIndicator());

    return ListenableBuilder(
      listenable: live,
      builder: (context, _) {
        final config = live.config;
        if (config.parameters.isEmpty) return _buildEmpty(context);

        final query = _searchQuery.toLowerCase();
        final filtered = query.isEmpty
            ? config.parameters
            : config.parameters
                  .where(
                    (p) =>
                        p.label.toLowerCase().contains(query) ||
                        p.name.toLowerCase().contains(query) ||
                        (p.category?.toLowerCase().contains(query) ?? false),
                  )
                  .toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: SearchBar(
                      controller: _searchController,
                      hintText: 'Search parameters',
                      leading: const Icon(Icons.search),
                      elevation: const WidgetStatePropertyAll(0),
                      trailing: _searchQuery.isEmpty
                          ? null
                          : [
                              IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              ),
                            ],
                      onChanged: (v) => setState(() => _searchQuery = v),
                    ),
                  ),
                  if (config.showAutomationMasterSwitch) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: 'Automation Master Switch - flips every automation it covers at once',
                      child: Switch(
                        value: automationMasterSwitchAggregate(config),
                        onChanged: (v) {
                          applyAutomationMasterSwitch(config, v);
                          live.persist();
                          live.reconcile();
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No parameters match your search.'))
                  : _buildGrid(context, live, filtered),
            ),
          ],
        );
      },
    );
  }

  Widget _buildGrid(BuildContext context, LiveController live, List<ParamControl> params) {
    // default is no categories: uncategorized params render with no header
    // at all. named categories get a collapsible header + their items.
    final uncategorized = <ParamControl>[];
    final byCategory = <String, List<ParamControl>>{};
    for (final p in params) {
      final c = p.category;
      if (c == null || c.isEmpty) {
        uncategorized.add(p);
      } else {
        byCategory.putIfAbsent(c, () => []).add(p);
      }
    }

    // the tour points at whichever card is drawn first.
    final firstShown = uncategorized.isNotEmpty
        ? uncategorized.first
        : byCategory.entries.where((e) => !_collapsedCategories.contains(e.key)).firstOrNull?.value.first;

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        const minCardWidth = 340.0;
        final width = constraints.maxWidth - 32;
        // as many columns as fit - a wide window shouldn't be one long
        // stretched-out list.
        final columns = max(1, ((width + spacing) / (minCardWidth + spacing)).floor());
        final cardWidth = (width - spacing * (columns - 1)) / columns;

        Widget wrap(List<ParamControl> items) => Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final p in items)
              SizedBox(
                key: identical(p, firstShown) ? _tourCardKey : null,
                width: cardWidth,
                child: ParamCard(
                  key: ValueKey('card:${p.name}'),
                  param: p,
                  live: live,
                  automationButton: !p.isAutomatable
                      ? null
                      : identical(p, firstShown)
                      ? KeyedSubtree(key: _tourAutomationKey, child: _automationButton(p))
                      : _automationButton(p),
                  onMenu: (pos) => _showParamMenu(pos, p),
                ),
              ),
          ],
        );

        return ListView(
          // room under the last card for the floating add button.
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            if (uncategorized.isNotEmpty) wrap(uncategorized),
            for (final entry in byCategory.entries) ...[
              _categoryHeader(context, entry.key, entry.value.length),
              if (!_collapsedCategories.contains(entry.key)) wrap(entry.value),
            ],
          ],
        );
      },
    );
  }

  Widget _categoryHeader(BuildContext context, String name, int count) {
    final collapsed = _collapsedCategories.contains(name);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => collapsed ? _collapsedCategories.remove(name) : _collapsedCategories.add(name)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
              const SizedBox(width: 4),
              Text(name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              Text('$count', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 12),
              const Expanded(child: Divider()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tune, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('No parameters yet', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'With VRChat running (and OSC enabled), Discover lists your current avatar\'s '
                'parameters. You can also add any OSC address by hand.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _discovering ? null : _discover,
                    icon: const Icon(Icons.wifi_find),
                    label: const Text('Discover from VRChat'),
                  ),
                  OutlinedButton.icon(
                    key: _tourAddKey,
                    onPressed: _addParamManually,
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Add by hand'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadError(BuildContext context, ConfigLoadException error) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 40, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text('config.json couldn\'t be loaded', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              SelectableText(error.message),
              const SizedBox(height: 8),
              SelectableText('Config path: ${ConfigStore.path}', style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              Text(
                'Nothing has been overwritten. Fix the file and retry, or pick one of the options below - '
                'the broken file is kept next to it either way.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(onPressed: _load, child: const Text('Retry')),
                  if (error.backupAvailable)
                    FilledButton.tonal(
                      onPressed: () => _load(loader: ConfigStore.restoreBackup),
                      child: const Text('Restore last working config'),
                    ),
                  OutlinedButton(
                    onPressed: () async {
                      final ok = await confirmDialog(
                        context,
                        title: 'Start fresh?',
                        message: 'The broken config.json is renamed (not deleted) and a new empty one is created.',
                        confirmLabel: 'Start fresh',
                      );
                      if (ok) await _load(loader: ConfigStore.startFresh);
                    },
                    child: const Text('Start fresh'),
                  ),
                  TextButton(
                    onPressed: () => launchUrl(Uri.directory(ConfigStore.directory)),
                    child: const Text('Open folder'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
