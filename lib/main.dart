import 'dart:async';

import 'package:flutter/material.dart';

import 'automation_dialog.dart';
import 'automation_engine.dart';
import 'config_store.dart';
import 'osc_client.dart';
import 'osc_listener.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';
import 'schedule_dialog.dart';
import 'schedule_engine.dart';
import 'sequence_engine.dart';
import 'settings_page.dart';
import 'theme_notifier.dart';

void main() {
  runApp(const OscSliderApp());
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
          theme: ThemeData(useMaterial3: true, colorScheme: settings.buildScheme(), fontFamily: 'Roboto'),
          home: const HomePage(),
        );
      },
    );
  }
}

// simple mode shows 3 decimal places (e.g. "1.234"); advanced mode shows full
// precision. either way this only affects the textbox display - the value
// actually stored/sent over OSC always keeps full precision.
String _formatNumber(double v, bool advanced) {
  if (advanced) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }
  return v.toStringAsFixed(3);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppConfig? _config;
  OscClient? _osc;
  String? _error;
  bool _discovering = false;
  String _searchQuery = '';

  final _searchController = TextEditingController();
  // holds double for slider params, bool for toggle params.
  final Map<String, Object> _values = {};
  final Map<String, TextEditingController> _sliderTextControllers = {};
  final Map<String, TextEditingController> _customValueControllers = {};
  AvatarChangeListener? _avatarWatcher;
  final _automationEngine = AutomationEngine();
  final _scheduleEngine = ScheduleEngine();
  final _sequenceEngine = SequenceEngine();
  Timer? _engineTimer;
  // tracks the last time a slider/toggle was touched by hand anywhere in the
  // app - drives "idle" schedules. starts at "now" so a fresh launch doesn't
  // read as having been idle since 1970.
  DateTime _lastInteraction = DateTime.now();

  bool get _advancedMode => _config?.advancedMode ?? false;

  @override
  void initState() {
    super.initState();
    _reload();
    _engineTimer = Timer.periodic(const Duration(milliseconds: 33), _tickEngines);
  }

  void _tickEngines(Timer timer) {
    final config = _config;
    if (config == null) return;
    // automations/schedules can disable themselves on completion (a ramp's
    // Once repeat, a countdown schedule, a sequence finishing) - watch for
    // those transitions so they can be persisted, without writing
    // config.json on every tick just because a value changed.
    final wasAutomationEnabled = {
      for (final p in config.parameters)
        if (p.automation != null) p.name: p.automation!.enabled,
    };
    final wasScheduleEnabled = {
      for (final p in config.parameters)
        if (p.schedule != null) p.name: p.schedule!.enabled,
    };
    final wasSequenceEnabled = {for (final s in config.sequences) s.id: s.enabled};

    var changed = false;
    void onSlider(ParamControl param, double value) {
      _values[param.name] = value;
      _sliderTextControllers[param.name]?.text = _formatNumber(value, _advancedMode);
      _sendSlider(param, value);
      changed = true;
    }

    void onToggle(ParamControl param, bool value) {
      _values[param.name] = value;
      _osc?.sendBool('/avatar/parameters/${param.name}', value);
      changed = true;
    }

    _automationEngine.tick(config.parameters, onSlider, onToggle);
    _scheduleEngine.tick(config.parameters, _lastInteraction, _values, onSlider, onToggle);
    _sequenceEngine.tick(config.sequences, config.parameters, _values, onSlider, onToggle);

    if (changed) setState(() {});

    final justFinished =
        config.parameters.any((p) => wasAutomationEnabled[p.name] == true && p.automation?.enabled == false) ||
            config.parameters.any((p) => wasScheduleEnabled[p.name] == true && p.schedule?.enabled == false) ||
            config.sequences.any((s) => wasSequenceEnabled[s.id] == true && !s.enabled);
    if (justFinished) _persist();
  }

  // manual interaction always wins - flipping a slider/toggle by hand while
  // its automation is running pauses (not deletes) that automation, so the
  // user can resume it later from the same dialog instead of re-entering it.
  // also marks the app as "not idle" for idle-triggered schedules.
  void _recordInteraction(ParamControl param) {
    _lastInteraction = DateTime.now();
    final auto = param.automation;
    if (auto != null && auto.enabled) {
      auto.enabled = false;
      _persist();
    }
  }

  Future<void> _openAutomationDialog(ParamControl param) async {
    final changed = await showAutomationDialog(context, param);
    if (!changed) return;
    _persist();
    setState(() {});
  }

  Future<void> _openScheduleDialog(ParamControl param) async {
    final changed = await showScheduleDialog(context, param);
    if (!changed) return;
    _persist();
    setState(() {});
  }

  Widget _automationButton(ParamControl param) {
    final auto = param.automation;
    final running = auto != null && auto.enabled;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(running ? Icons.auto_awesome : Icons.auto_awesome_outlined),
      color: running ? scheme.primary : (auto != null ? scheme.onSurfaceVariant : scheme.outline),
      tooltip: running
          ? 'Automation running - tap to edit'
          : (auto != null ? 'Automation paused - tap to edit' : 'Add automation'),
      onPressed: () => _openAutomationDialog(param),
    );
  }

  Widget _scheduleButton(ParamControl param) {
    final sched = param.schedule;
    final running = sched != null && sched.enabled;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(running ? Icons.schedule : Icons.schedule_outlined),
      color: running ? scheme.primary : (sched != null ? scheme.onSurfaceVariant : scheme.outline),
      tooltip: running
          ? 'Schedule active - tap to edit'
          : (sched != null ? 'Schedule paused - tap to edit' : 'Add schedule'),
      onPressed: () => _openScheduleDialog(param),
    );
  }

  void _disposeControllers() {
    for (final c in _sliderTextControllers.values) {
      c.dispose();
    }
    for (final c in _customValueControllers.values) {
      c.dispose();
    }
    _sliderTextControllers.clear();
    _customValueControllers.clear();
  }

  Future<void> _reload() async {
    setState(() {
      _error = null;
    });
    try {
      final config = await ConfigStore.load();
      setState(() {
        _config = config;
      });
      // reconcile rather than hard-reset - on first launch _values is empty
      // so this initializes everything just like a full reset would, but on
      // a manual refresh (or any later reload) it preserves whatever's
      // already live instead of snapping every parameter back to default.
      _reconcileAfterExternalEdit();
      _automationEngine.reset();
      _scheduleEngine.reset();
      _sequenceEngine.reset();
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  // (re)builds _values/controllers from scratch for whichever profile is
  // currently active - used on load and whenever you deliberately switch to
  // a different profile, where starting fresh is exactly what you want.
  void _resetControllersForActiveProfile() {
    final config = _config;
    if (config == null) return;
    _disposeControllers();
    final values = <String, Object>{};
    for (final p in config.parameters) {
      switch (p.type) {
        case ParamType.toggle:
          values[p.name] = p.defaultBool;
        case ParamType.slider:
          values[p.name] = p.defaultValue;
          _sliderTextControllers[p.name] =
              TextEditingController(text: _formatNumber(p.defaultValue, config.advancedMode));
        case ParamType.custom:
          _customValueControllers[p.name] = TextEditingController(text: p.customValueText);
      }
    }
    setState(() {
      _values
        ..clear()
        ..addAll(values);
    });
  }

  void _switchProfile(String profileId) {
    final config = _config;
    if (config == null || config.activeProfileId == profileId) return;
    setState(() => config.activeProfileId = profileId);
    _persist();
    _resetControllersForActiveProfile();
    // a same-named parameter in the new profile should start its automation
    // fresh, not inherit timing from whatever was running under this name a
    // moment ago on the old profile.
    _automationEngine.reset();
    _scheduleEngine.reset();
    _sequenceEngine.reset();
  }

  // VRChat's default OSC layout always pairs a send port N with a receive
  // port N+1 (e.g. 9000/9001) - derive the listen port from the configured
  // send port rather than hardcoding it, so a customized VRChat OSC setup
  // still works.
  int get _avatarChangeListenPort => (_config?.port ?? 9000) + 1;

  void _startOrStopAvatarWatcher() {
    final config = _config;
    if (config == null) return;
    if (config.autoProfileMode) {
      if (_avatarWatcher != null) return;
      final watcher = AvatarChangeListener();
      _avatarWatcher = watcher;
      watcher.start(_avatarChangeListenPort, _onAvatarChanged).catchError((Object e) {
        if (_avatarWatcher != watcher) return;
        _avatarWatcher = null;
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Auto mode: could not listen for avatar changes ($e)')));
      });
    } else {
      _avatarWatcher?.stop();
      _avatarWatcher = null;
    }
  }

  void _onAvatarChanged(String avatarId) {
    final config = _config;
    if (config == null) return;
    if (config.activeProfile.avatarId == avatarId) return;

    final matchIndex = config.profiles.indexWhere((p) => p.avatarId == avatarId);
    if (matchIndex != -1) {
      _switchProfile(config.profiles[matchIndex].id);
    } else {
      final shortId = avatarId.length > 8 ? avatarId.substring(avatarId.length - 8) : avatarId;
      final profile = Profile(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: 'Avatar $shortId',
        avatarId: avatarId,
      );
      setState(() => config.profiles.add(profile));
      _switchProfile(profile.id);
    }

    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Auto mode: switched to "${config.activeProfile.name}"')));
    }
  }

  Future<void> _persist() async {
    if (_config != null) await ConfigStore.save(_config!);
  }

  void _onSliderChanged(ParamControl param, double value) {
    _recordInteraction(param);
    setState(() {
      _values[param.name] = value;
    });
    _sliderTextControllers[param.name]?.text = _formatNumber(value, _advancedMode);
    // sent immediately on every change - no smoothing/rate limiting.
    _sendSlider(param, value);
  }

  void _sendSlider(ParamControl param, double value) {
    final address = '/avatar/parameters/${param.name}';
    if (param.numericKind == NumericKind.int) {
      _osc?.sendInt(address, value.round());
    } else {
      _osc?.sendFloat(address, value);
    }
  }

  void _onSliderTextSubmitted(ParamControl param, String text) {
    final value = double.tryParse(text);
    if (value == null) {
      // revert to last known-good value on unparsable input.
      _sliderTextControllers[param.name]?.text =
          _formatNumber(_values[param.name] as double? ?? param.defaultValue, _advancedMode);
      return;
    }
    _recordInteraction(param);
    setState(() {
      // no limiter on the value itself - the textbox never touches min/max,
      // it only ever sets what gets sent. the slider thumb just clamps its
      // own displayed position when the real value falls outside its range.
      _values[param.name] = value;
    });
    // re-format to the current precision mode after a manual edit (the true
    // value stored/sent above always keeps whatever precision was typed).
    _sliderTextControllers[param.name]?.text = _formatNumber(value, _advancedMode);
    _sendSlider(param, value);
  }

  void _onToggleChanged(ParamControl param, bool value) {
    _recordInteraction(param);
    setState(() {
      _values[param.name] = value;
    });
    _osc?.sendBool('/avatar/parameters/${param.name}', value);
  }

  Future<void> _sendCustom(ParamControl param) async {
    final text = _customValueControllers[param.name]?.text ?? param.customValueText;
    try {
      await _osc?.sendCustom('/avatar/parameters/${param.name}', param.customTypeTag, text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send failed: $e')));
    }
  }

  Future<void> _openSettings() async {
    final config = _config;
    if (config == null) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SettingsPage(config: config)));
    _reconcileAfterExternalEdit();
  }

  // settings mutates the same AppConfig instance in place, so there's no
  // need to reread config.json - doing a full _reload() would reset every
  // parameter back to its default, wiping out whatever the user currently
  // has set (e.g. mid-drag). instead, only add entries for genuinely new
  // parameters and drop entries for removed ones; everything unchanged keeps
  // its live value and controller untouched.
  void _reconcileAfterExternalEdit() {
    final config = _config;
    if (config == null) return;

    _osc?.dispose();
    _osc = OscClient(host: config.host, port: config.port);
    themeSettingsNotifier.value = ThemeSettings.fromConfig(config);
    _startOrStopAvatarWatcher();

    final currentNames = config.parameters.map((p) => p.name).toSet();
    for (final key in _values.keys.toList()) {
      if (!currentNames.contains(key)) {
        _values.remove(key);
        _sliderTextControllers.remove(key)?.dispose();
        _customValueControllers.remove(key)?.dispose();
      }
    }

    for (final p in config.parameters) {
      final matchesSlider = p.type == ParamType.slider && _sliderTextControllers.containsKey(p.name);
      final matchesCustom = p.type == ParamType.custom && _customValueControllers.containsKey(p.name);
      final matchesToggle = p.type == ParamType.toggle && _values.containsKey(p.name);
      if (matchesSlider || matchesCustom || matchesToggle) continue;

      // new parameter, or one whose type changed - (re)initialize just this one.
      _sliderTextControllers.remove(p.name)?.dispose();
      _customValueControllers.remove(p.name)?.dispose();
      switch (p.type) {
        case ParamType.toggle:
          _values[p.name] = p.defaultBool;
        case ParamType.slider:
          _values[p.name] = p.defaultValue;
          _sliderTextControllers[p.name] = TextEditingController(text: _formatNumber(p.defaultValue, _advancedMode));
        case ParamType.custom:
          _customValueControllers[p.name] = TextEditingController(text: p.customValueText);
      }
    }

    setState(() {});
  }

  Future<void> _deleteParam(ParamControl param) async {
    final config = _config;
    if (config == null) return;
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
    setState(() {
      config.parameters.remove(param);
      _sliderTextControllers.remove(param.name)?.dispose();
      _customValueControllers.remove(param.name)?.dispose();
      _values.remove(param.name);
    });
    _persist();
  }

  Future<void> _editParam(ParamControl param) async {
    final result = await showParamFormDialog(context, existing: param);
    if (result == null) return;
    final config = _config;
    if (config == null) return;
    final index = config.parameters.indexOf(param);
    if (index != -1) config.parameters[index] = result;
    _persist();
    // the edited param's name/type may have changed, so drop its old
    // controller/value first - reconcile will reinitialize just that one and
    // leave every other still-live parameter untouched.
    _sliderTextControllers.remove(param.name)?.dispose();
    _customValueControllers.remove(param.name)?.dispose();
    _values.remove(param.name);
    _reconcileAfterExternalEdit();
  }

  Future<void> _showContextMenu(BuildContext context, Offset globalPosition, ParamControl param) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(value: 'edit', child: Text('Edit')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (selected == 'delete') {
      await _deleteParam(param);
    } else if (selected == 'edit') {
      await _editParam(param);
    }
  }

  Future<void> _discover() async {
    setState(() => _discovering = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final instances = await OscQueryClient.findVrchatInstances();
      if (instances.isEmpty) {
        messenger.showSnackBar(const SnackBar(
          content: Text('No VRChat OSCQuery service found. Is VRChat running with OSC enabled?'),
        ));
        return;
      }
      final (host, port) = instances.first;
      final found = await OscQueryClient.fetchAvatarParameters(host, port);
      if (!mounted) return;
      await _showDiscoveryResults(found);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Discovery failed: $e')));
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _showDiscoveryResults(List<DiscoveredParam> found) async {
    final config = _config;
    if (config == null) return;
    final existingNames = config.parameters.map((p) => p.name).toSet();
    final added = <String>{};
    var query = '';

    void addControl(String name, ParamType type, void Function(void Function()) setSheetState) {
      final control = ParamControl(name: name, label: name.split('/').last, type: type);
      config.parameters.add(control);
      _values[control.name] = type == ParamType.toggle ? control.defaultBool : control.defaultValue;
      if (type == ParamType.slider) {
        _sliderTextControllers[name] =
            TextEditingController(text: _formatNumber(control.defaultValue, _advancedMode));
      } else if (type == ParamType.custom) {
        _customValueControllers[name] = TextEditingController(text: control.customValueText);
      }
      ConfigStore.save(config);
      setSheetState(() => added.add(name));
      setState(() {});
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final filtered = query.isEmpty
                ? found
                : found.where((p) => p.name.toLowerCase().contains(query.toLowerCase())).toList();
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              expand: false,
              builder: (context, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: SearchBar(
                              hintText: 'Search found parameters',
                              leading: const Icon(Icons.search),
                              onChanged: (v) => setSheetState(() => query = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            tooltip: 'Add a custom parameter path manually',
                            icon: const Icon(Icons.add),
                            onPressed: () async {
                              final result = await showParamFormDialog(context);
                              if (result == null) return;
                              config.parameters.add(result);
                              _values[result.name] =
                                  result.type == ParamType.toggle ? result.defaultBool : result.defaultValue;
                              if (result.type == ParamType.slider) {
                                _sliderTextControllers[result.name] =
                                    TextEditingController(text: _formatNumber(result.defaultValue, _advancedMode));
                              } else if (result.type == ParamType.custom) {
                                _customValueControllers[result.name] =
                                    TextEditingController(text: result.customValueText);
                              }
                              await ConfigStore.save(config);
                              setSheetState(() => added.add(result.name));
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('No matching parameters found.'))
                          : ListView(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              children: [
                                for (final p in filtered)
                                  ListTile(
                                    title: Text(p.name.split('/').last),
                                    subtitle: Text(
                                      '${p.type == ParamType.toggle ? 'toggle' : 'slider'} - ${p.name}',
                                    ),
                                    trailing: existingNames.contains(p.name) || added.contains(p.name)
                                        ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                                        : IconButton(
                                            icon: const Icon(Icons.add_circle_outline),
                                            onPressed: () => addControl(p.name, p.type, setSheetState),
                                          ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _engineTimer?.cancel();
    _osc?.dispose();
    _avatarWatcher?.stop();
    _searchController.dispose();
    _disposeControllers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _config == null
            ? const Text('OSCSlider')
            : PopupMenuButton<String>(
                tooltip: 'Switch profile',
                onSelected: _switchProfile,
                itemBuilder: (context) => [
                  for (final p in _config!.profiles)
                    PopupMenuItem(
                      value: p.id,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 24,
                            child: p.id == _config!.activeProfileId ? const Icon(Icons.check, size: 18) : null,
                          ),
                          Text(p.name),
                        ],
                      ),
                    ),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(_config!.activeProfile.name, overflow: TextOverflow.ellipsis)),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
        actions: [
          IconButton(
            icon: _discovering
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find),
            tooltip: 'Discover parameters from running VRChat (OSCQuery)',
            onPressed: _discovering ? null : _discover,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload config.json',
            onPressed: _reload,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _config == null ? null : _openSettings,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Failed to load config.json', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            SelectableText(_error!),
            const SizedBox(height: 8),
            SelectableText('Config path: ${ConfigStore.path}'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _reload, child: const Text('Retry')),
          ],
        ),
      );
    }

    final config = _config;
    if (config == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (config.parameters.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No parameters configured. Tap the discover icon while VRChat is running, '
          'or open Settings to add one manually.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }

    final query = _searchQuery.toLowerCase();
    final filtered = query.isEmpty
        ? config.parameters
        : config.parameters
            .where((p) => p.label.toLowerCase().contains(query) || p.name.toLowerCase().contains(query))
            .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SearchBar(
            controller: _searchController,
            hintText: 'Search parameters',
            leading: const Icon(Icons.search),
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
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No parameters match your search.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: _buildGroupedList(context, filtered),
                ),
        ),
      ],
    );
  }

  List<Widget> _buildGroupedList(BuildContext context, List<ParamControl> params) {
    // default is no categories: uncategorized params render as a flat list
    // with no headers at all. named categories get a header + their items.
    final uncategorized = <ParamControl>[];
    final byCategory = <String, List<ParamControl>>{};
    for (final p in params) {
      if (p.category == null || p.category!.isEmpty) {
        uncategorized.add(p);
      } else {
        byCategory.putIfAbsent(p.category!, () => []).add(p);
      }
    }

    final widgets = <Widget>[];
    for (final p in uncategorized) {
      widgets.add(_buildParamCard(context, p));
    }
    for (final entry in byCategory.entries) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(entry.key, style: Theme.of(context).textTheme.titleMedium),
      ));
      for (final p in entry.value) {
        widgets.add(_buildParamCard(context, p));
      }
    }
    return widgets;
  }

  Widget _buildParamCard(BuildContext context, ParamControl param) {
    Widget child;
    switch (param.type) {
      case ParamType.toggle:
        final value = _values[param.name] as bool? ?? param.defaultBool;
        child = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Expanded(child: Text(param.label, style: Theme.of(context).textTheme.titleMedium)),
              _automationButton(param),
              _scheduleButton(param),
              Switch(value: value, onChanged: (v) => _onToggleChanged(param, v)),
            ],
          ),
        );
      case ParamType.custom:
        final controller = _customValueControllers[param.name];
        child = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(param.label, style: Theme.of(context).textTheme.titleMedium),
                    Text('custom - type "${param.customTypeTag}"',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              SizedBox(
                width: 140,
                child: TextField(controller: controller, decoration: const InputDecoration(isDense: true)),
              ),
              IconButton(icon: const Icon(Icons.send), onPressed: () => _sendCustom(param)),
            ],
          ),
        );
      case ParamType.slider:
        final value = _values[param.name] as double? ?? param.defaultValue;
        final textController = _sliderTextControllers[param.name];
        child = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text(param.label, style: Theme.of(context).textTheme.titleMedium)),
                  _automationButton(param),
                  _scheduleButton(param),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: textController,
                      textAlign: TextAlign.end,
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                      decoration: const InputDecoration(isDense: true),
                      onSubmitted: (text) => _onSliderTextSubmitted(param, text),
                    ),
                  ),
                ],
              ),
              Slider(
                value: value.clamp(param.min, param.max),
                min: param.min,
                max: param.max,
                onChanged: (v) => _onSliderChanged(param, v),
              ),
            ],
          ),
        );
    }

    return GestureDetector(
      onSecondaryTapDown: (details) => _showContextMenu(context, details.globalPosition, param),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: child,
      ),
    );
  }
}
