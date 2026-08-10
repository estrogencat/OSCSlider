import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updater.dart';
import 'automation_dialog.dart';
import 'automation_engine.dart';
import 'automation_master_switch_dialog.dart';
import 'config_store.dart';
import 'crash_log.dart';
import 'discovery_sheet.dart';
import 'error_dialog.dart';
import 'osc_client.dart';
import 'osc_input_hub.dart';
import 'osc_listener.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'param_form_dialog.dart';
import 'schedule_engine.dart';
import 'sequence_editor_page.dart';
import 'sequence_engine.dart';
import 'sequences_page.dart';
import 'settings_page.dart';
import 'theme_notifier.dart';
import 'trigger_engine.dart';

void main() {
  // OSC/networking code (socket sends, discovery, HTTP fetches) fires
  // frequently and mostly unawaited - a transient error there would
  // otherwise be an uncaught async error that silently kills the app with
  // no trace. this is the last-resort net; see CrashLog for where it lands.
  FlutterError.onError = (details) {
    CrashLog.record(details.exception, details.stack, context: 'FlutterError');
  };
  runZonedGuarded(
    () => runApp(const OscSliderApp()),
    (error, stack) => CrashLog.record(error, stack, context: 'uncaught'),
  );
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
          theme: ThemeData(useMaterial3: true, colorScheme: settings.buildScheme(), fontFamily: 'Roboto'),
          home: const HomePage(),
        );
      },
    );
  }
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
  // developer-mode-only escape hatch: a second Discover click within 1s of a
  // "nothing found" failure opens the add menu anyway, empty.
  DateTime? _lastDiscoverFailure;
  String _searchQuery = '';

  final _searchController = TextEditingController();
  // holds double for slider params, bool for toggle params.
  final Map<String, Object> _values = {};
  final Map<String, TextEditingController> _sliderTextControllers = {};
  final Map<String, TextEditingController> _customValueControllers = {};
  StreamSubscription<OscMessage>? _avatarChangeSub;
  bool _avatarWatcherActive = false;
  final _automationEngine = AutomationEngine();
  final _scheduleEngine = ScheduleEngine();
  final _sequenceEngine = SequenceEngine();
  final _triggerEngine = TriggerEngine();
  Timer? _engineTimer;
  // last manual slider/toggle touch anywhere - drives idle schedules.
  DateTime _lastInteraction = DateTime.now();

  bool get _advancedMode => _config?.advancedMode ?? false;

  @override
  void initState() {
    super.initState();
    _reload();
    _engineTimer = Timer.periodic(const Duration(milliseconds: 33), _tickEngines);
    _checkForUpdateSilently();
    _checkForDuplicateInstance();
  }

  // silent - only shows anything if a newer release is actually found.
  Future<void> _checkForUpdateSilently() async {
    final info = await PackageInfo.fromPlatform();
    final update = await checkForUpdate(info.version);
    if (update == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('OSCSlider v${update.version} is available.'),
      action: SnackBarAction(label: 'View', onPressed: () => launchUrl(Uri.parse(update.url))),
    ));
  }

  // two copies running at once silently fight over the same OSC listening
  // ports - Auto Profile Mode or "highlight active parameters" can end up
  // receiving nothing with no visible error. warn once on launch; dismiss
  // only, no "close the other one for you" action.
  Future<void> _checkForDuplicateInstance() async {
    try {
      final exeName = Platform.resolvedExecutable.split(Platform.pathSeparator).last;
      final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq $exeName', '/FO', 'CSV', '/NH']);
      final count = exeName.allMatches(result.stdout as String).length;
      if (count <= 1 || !mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Another OSCSlider is already running'),
          content: const Text(
            'Two copies running at once can silently fight over the same OSC listening ports - '
            'Auto Profile Mode or "highlight active parameters" may stop receiving anything with '
            'no visible error. Close the other one if you run into that.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Dismiss')),
          ],
        ),
      );
    } catch (_) {
      // best-effort - if tasklist itself fails for any reason, just skip the warning.
    }
  }

  void _tickEngines(Timer timer) {
    final config = _config;
    if (config == null) return;
    // watch for auto-disable-on-completion so it gets persisted, without
    // writing config.json every tick just because a value changed.
    final wasAutomationEnabled = {
      for (final p in config.parameters)
        if (p.automation != null) p.name: p.automation!.enabled,
    };
    final wasScheduleEnabled = {
      for (final p in config.parameters)
        if (p.schedule != null) p.name: p.schedule!.enabled,
    };
    final wasSequenceEnabled = {for (final s in config.sequences) s.id: s.enabled};
    final wasSeqParamAutoEnabled = {
      for (final s in config.sequences)
        for (final entry in s.paramAutomations.entries) '${s.id}:${entry.key}': entry.value.enabled,
    };

    var changed = false;
    void onSlider(ParamControl param, double value) {
      _values[param.name] = value;
      _sliderTextControllers[param.name]?.text = formatParamNumber(value, _advancedMode);
      _sendSlider(param, value);
      changed = true;
    }

    void onToggle(ParamControl param, bool value) {
      _values[param.name] = value;
      _osc?.sendBool(oscAddressFor(param), value);
      changed = true;
    }

    // only one source may drive a parameter at a time: a sequence actively
    // driving it wins over its global automation, and that sequence's own
    // step script (if targeting the same parameter) wins over its
    // paramAutomations override. precomputed so both loops below skip
    // whichever side loses.
    final sequenceDrivenNow = <String>{};
    final seqStepTargets = <String, Set<String>>{};
    for (final seq in config.sequences) {
      if (!seq.enabled) continue;
      final stepTargets = seq.steps
          .where((s) => s.kind == SequenceStepKind.setValue)
          .map((s) => s.paramName)
          .toSet();
      seqStepTargets[seq.id] = stepTargets;
      for (final entry in seq.paramAutomations.entries) {
        if (entry.value.enabled && !stepTargets.contains(entry.key)) {
          sequenceDrivenNow.add(entry.key);
        }
      }
    }

    final automationTargets = <AutomationTarget>[];
    for (final p in config.parameters) {
      final auto = p.automation;
      if (auto != null && auto.enabled && !sequenceDrivenNow.contains(p.name)) {
        automationTargets.add(AutomationTarget(
          key: 'param:${p.name}',
          param: p,
          automation: auto,
          onFinished: () => auto.enabled = false,
        ));
      }
    }
    for (final seq in config.sequences) {
      if (!seq.enabled) continue;
      final stepTargets = seqStepTargets[seq.id]!;
      for (final entry in seq.paramAutomations.entries) {
        if (!entry.value.enabled || stepTargets.contains(entry.key)) continue;
        final param = _findParamByName(config.parameters, entry.key);
        if (param == null) continue;
        final auto = entry.value;
        automationTargets.add(AutomationTarget(
          key: 'seq:${seq.id}:${entry.key}',
          param: param,
          automation: auto,
          onFinished: () => auto.enabled = false,
        ));
      }
    }

    _triggerEngine.tick(config.parameters, config.sequences, _values);
    _automationEngine.tick(automationTargets, onSlider, onToggle);
    _scheduleEngine.tick(config.parameters, _lastInteraction, _values, onSlider, onToggle);
    _sequenceEngine.tick(config.sequences, config.parameters, _values, onSlider, onToggle);

    if (changed) setState(() {});

    final justFinished =
        config.parameters.any((p) => wasAutomationEnabled[p.name] == true && p.automation?.enabled == false) ||
            config.parameters.any((p) => wasScheduleEnabled[p.name] == true && p.schedule?.enabled == false) ||
            config.sequences.any((s) => wasSequenceEnabled[s.id] == true && !s.enabled) ||
            config.sequences.any((s) => s.paramAutomations.entries.any(
                (e) => wasSeqParamAutoEnabled['${s.id}:${e.key}'] == true && e.value.enabled == false));
    if (justFinished) _persist();
  }

  ParamControl? _findParamByName(List<ParamControl> parameters, String name) {
    for (final p in parameters) {
      if (p.name == name) return p;
    }
    return null;
  }

  // manual interaction pauses (not deletes) a running automation, and resets
  // the idle clock for idle-triggered schedules.
  void _recordInteraction(ParamControl param) {
    _lastInteraction = DateTime.now();
    final auto = param.automation;
    if (auto != null && auto.enabled) {
      auto.enabled = false;
      _persist();
    }
  }

  Future<void> _openAutomationDialog(ParamControl param) async {
    final changed = await showAutomationDialog(context, param, _config?.parameters ?? const []);
    if (!changed) return;
    _persist();
    setState(() {});
  }

  // sequences with a paramAutomations entry for this parameter - relevant
  // when the parameter has no automation of its own, since that's the only
  // other thing that can be driving its live value.
  List<AutomationSequence> _sequencesAutomating(ParamControl param) {
    final config = _config;
    if (config == null) return const [];
    return config.sequences.where((s) => s.paramAutomations.containsKey(param.name)).toList();
  }

  // true if [seq] is actually ticking its paramAutomations entry for [param]
  // right now - see sequenceActivelyDrivesParam in param_control.dart, also
  // used by the master switch's eligibility so both agree on the same
  // definition.
  bool _sequenceActivelyDrives(AutomationSequence seq, ParamControl param) =>
      sequenceActivelyDrivesParam(seq, param.name);

  // schedules are folded into the same dialog as automations now (just
  // another "Type" option), so one button covers both.
  Widget _automationButton(ParamControl param) {
    final auto = param.automation;
    final sched = param.schedule;
    final scheme = Theme.of(context).colorScheme;

    final owners = _sequencesAutomating(param);
    // only surface "linked to a sequence" while some owning sequence is
    // actually enabled - a disabled sequence's stale link shouldn't
    // permanently block reaching this parameter's own automation.
    final activeOwners = owners.where((s) => s.enabled).toList();
    final runningOwners = activeOwners.where((s) => _sequenceActivelyDrives(s, param)).toList();
    final sequenceActive = runningOwners.isNotEmpty;

    // a sequence actively driving this parameter wins over (and hides) its
    // global automation/schedule, matching _tickEngines' own suppression -
    // otherwise this button would hide that a sequence is in charge.
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
    final running = ownRunning;
    return IconButton(
      icon: Icon(running ? Icons.auto_awesome : Icons.auto_awesome_outlined),
      color: running ? scheme.primary : (configured ? scheme.onSurfaceVariant : scheme.outline),
      tooltip: running
          ? 'Automation running - tap to edit'
          : (configured ? 'Automation paused - tap to edit' : 'Add automation'),
      onPressed: () => _openAutomationDialog(param),
    );
  }

  Future<void> _manageSequenceAutomation(ParamControl param, List<AutomationSequence> owners) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final anyRunning = owners.any((s) => _sequenceActivelyDrives(s, param));
          return AlertDialog(
            title: Text('"${param.label}" automation'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    anyRunning
                        ? 'This parameter has no automation of its own - its value is '
                            'being driven by a sequence instead.'
                        : 'This parameter has no automation of its own - it\'s linked to a '
                            'sequence automation below, but nothing is currently driving it.',
                  ),
                  const SizedBox(height: 12),
                  for (final seq in owners)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        title: Text(seq.name),
                        subtitle: Text(
                          !seq.enabled
                              ? 'Sequence not running'
                              : !(seq.paramAutomations[param.name]?.enabled ?? false)
                                  ? 'Paused in this sequence'
                                  : _sequenceActivelyDrives(seq, param)
                                      ? 'Running'
                                      : 'Suppressed - a step in this sequence also targets this parameter',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: seq.paramAutomations[param.name]?.enabled ?? false,
                              onChanged: (v) {
                                setState(() => seq.paramAutomations[param.name]?.enabled = v);
                                setDialogState(() {});
                                _persist();
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.open_in_new),
                              tooltip: 'Open sequence',
                              onPressed: () {
                                Navigator.of(dialogContext).pop();
                                _openSpecificSequenceEditor(seq);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Remove automation from this sequence',
                              onPressed: () {
                                setState(() => seq.paramAutomations.remove(param.name));
                                _persist();
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

  Future<void> _openSpecificSequenceEditor(AutomationSequence sequence) async {
    final config = _config;
    if (config == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SequenceEditorPage(
        sequence: sequence,
        config: config,
        values: _values,
        sliderTextControllers: _sliderTextControllers,
        customValueControllers: _customValueControllers,
        osc: _osc,
        advancedMode: _advancedMode,
        developerMode: config.developerMode,
        onPersist: _persist,
        onInteraction: _recordInteraction,
      ),
    ));
    _reconcileAfterExternalEdit();
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
      _triggerEngine.reset();
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
              TextEditingController(text: formatParamNumber(p.defaultValue, config.advancedMode));
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
    _triggerEngine.reset();
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
      if (_avatarWatcherActive) return;
      _avatarWatcherActive = true;
      oscInputHub.acquire(_avatarChangeListenPort).then((ok) {
        // Auto Mode may have been toggled off again before this resolved -
        // the matching release() already happened in the else branch below,
        // so just bail out without subscribing to anything.
        if (!_avatarWatcherActive) return;
        if (!ok) {
          _avatarWatcherActive = false;
          if (!mounted) return;
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Auto mode: could not listen for avatar changes')));
          return;
        }
        _avatarChangeSub = oscInputHub.messages.listen((msg) {
          if (msg.address != '/avatar/change') return;
          if (msg.args.isEmpty || msg.args.first is! String) return;
          _onAvatarChanged(msg.args.first as String);
        });
      });
    } else {
      if (!_avatarWatcherActive) return;
      _avatarWatcherActive = false;
      _avatarChangeSub?.cancel();
      _avatarChangeSub = null;
      oscInputHub.release();
    }
  }

  void _onAvatarChanged(String avatarId) async {
    final config = _config;
    if (config == null) return;
    if (config.activeProfile.avatarId == avatarId) return;

    // snapshot profiles are static saves, never candidates for auto mode's
    // avatar-based matching/creation.
    final matchIndex = config.profiles.indexWhere((p) => !p.isSnapshot && p.avatarId == avatarId);
    if (matchIndex != -1) {
      _switchProfile(config.profiles[matchIndex].id);
    } else {
      final name = await _avatarProfileName(avatarId);
      if (!mounted) return;
      final profile = Profile(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
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

  // OSC only ever gives the avatar ID, not its name - looked up separately.
  // suffix is always added, even with a real name, to avoid collisions.
  Future<String> _avatarProfileName(String avatarId) async {
    final suffix = _randomSuffix();
    final realName = await _lookupAvatarName(avatarId);
    if (realName != null && realName.isNotEmpty) return '$realName #$suffix';
    final shortId = avatarId.length > 8 ? avatarId.substring(avatarId.length - 8) : avatarId;
    return 'Avatar $shortId #$suffix';
  }

  Future<String?> _lookupAvatarName(String avatarId) async {
    try {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null) return null;
      // LocalLow is a sibling of Local under AppData, not nested inside it.
      final appData = Directory(localAppData).parent.path;
      final oscDir = Directory('$appData\\LocalLow\\VRChat\\VRChat\\OSC');
      if (!await oscDir.exists()) return null;
      await for (final userDir in oscDir.list()) {
        if (userDir is! Directory) continue;
        final file = File('${userDir.path}\\Avatars\\$avatarId.json');
        if (!await file.exists()) continue;
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic> && json['name'] is String) {
          return json['name'] as String;
        }
      }
    } catch (_) {
      // caller falls back to the id-based name.
    }
    return null;
  }

  String _randomSuffix() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    return List.generate(4, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  Future<void> _persist() async {
    if (_config != null) await ConfigStore.save(_config!);
  }

  void _onSliderChanged(ParamControl param, double value) {
    _recordInteraction(param);
    setState(() {
      _values[param.name] = value;
    });
    _sliderTextControllers[param.name]?.text = formatParamNumber(value, _advancedMode);
    // sent immediately on every change - no smoothing/rate limiting.
    _sendSlider(param, value);
  }

  void _sendSlider(ParamControl param, double value) {
    final address = oscAddressFor(param);
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
          formatParamNumber(_values[param.name] as double? ?? param.defaultValue, _advancedMode);
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
    _sliderTextControllers[param.name]?.text = formatParamNumber(value, _advancedMode);
    _sendSlider(param, value);
  }

  void _onToggleChanged(ParamControl param, bool value) {
    _recordInteraction(param);
    setState(() {
      _values[param.name] = value;
    });
    _osc?.sendBool(oscAddressFor(param), value);
  }

  Future<void> _sendCustom(ParamControl param) async {
    final text = _customValueControllers[param.name]?.text ?? param.customValueText;
    try {
      await _osc?.sendCustom(oscAddressFor(param), param.customTypeTag, text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send failed: $e')));
    }
  }

  // pushes a snapshot's saved values onto the active profile (a restore, not
  // a switch) - parameters the profile is missing get added fresh with the
  // snapshot's full definition, rather than silently skipped.
  void _applySnapshot(Profile snapshot) {
    final config = _config;
    if (config == null) return;
    setState(() {
      for (final saved in snapshot.parameters) {
        ParamControl? live;
        for (final p in config.parameters) {
          if (p.name == saved.name) {
            live = p;
            break;
          }
        }
        if (live == null) {
          live = ParamControl.fromJson(saved.toJson());
          config.parameters.add(live);
        }
        if (live.type == ParamType.toggle) {
          _values[live.name] = saved.defaultBool;
          _osc?.sendBool(oscAddressFor(live), saved.defaultBool);
        } else if (live.type == ParamType.slider) {
          _values[live.name] = saved.defaultValue;
          final controller = _sliderTextControllers[live.name];
          if (controller != null) {
            controller.text = formatParamNumber(saved.defaultValue, _advancedMode);
          } else {
            _sliderTextControllers[live.name] =
                TextEditingController(text: formatParamNumber(saved.defaultValue, _advancedMode));
          }
          _sendSlider(live, saved.defaultValue);
        }
      }
    });
    _persist();
  }

  Future<void> _openSettings() async {
    final config = _config;
    if (config == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsPage(config: config, values: _values, onApplySnapshot: _applySnapshot),
    ));
    _reconcileAfterExternalEdit();
  }

  // sequences moved out of Settings into their own space since each one now
  // embeds a full parameter/automation panel - too much to bury in a scroll
  // section. shares the same live values/controllers/OSC client as the main
  // screen so editing a parameter there behaves identically to editing it here.
  Future<void> _openSequencesPage() async {
    final config = _config;
    if (config == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SequencesPage(
        config: config,
        values: _values,
        sliderTextControllers: _sliderTextControllers,
        customValueControllers: _customValueControllers,
        osc: _osc,
        advancedMode: _advancedMode,
        developerMode: config.developerMode,
        onPersist: _persist,
        onInteraction: _recordInteraction,
      ),
    ));
    _reconcileAfterExternalEdit();
  }

  // settings mutates the same AppConfig instance in place - no need to
  // reread config.json, and a full _reload() would reset every parameter to
  // its default. only add/drop entries that actually changed; everything
  // else keeps its live value and controller untouched.
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
          _sliderTextControllers[p.name] = TextEditingController(text: formatParamNumber(p.defaultValue, _advancedMode));
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
      items: [
        const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (param.type != ParamType.custom) const PopupMenuItem(value: 'fetch', child: Text('Fetch value')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (selected == 'delete') {
      await _deleteParam(param);
    } else if (selected == 'edit') {
      await _editParam(param);
    } else if (selected == 'fetch') {
      await _fetchValue(param);
    }
  }

  // pulls the parameter's current live value from VRChat's OSCQuery tree and
  // snaps the local display to it - read-only, nothing is sent back over OSC.
  Future<void> _fetchValue(ParamControl param) async {
    final messenger = ScaffoldMessenger.of(context);
    final fetchTimeout = Duration(seconds: _config?.oscQueryFetchTimeoutSeconds ?? 5);
    final result = await OscQueryClient.findVrchatInstances(
      anyOscQueryService: _config?.developerMode ?? false,
      timeout: fetchTimeout,
    );
    if (!mounted) return;
    if (result.instances.isEmpty) {
      await showErrorDialog(context, 'No OSCQuery service found', result.error ?? oscNotFoundExplanation);
      return;
    }
    final (host, port) = result.instances.first;
    final Object? value;
    try {
      value = await OscQueryClient.fetchParameterValue(host, port, param.name, timeout: fetchTimeout);
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(context, 'Could not fetch "${param.label}"', e.toString());
      return;
    }
    if (!mounted) return;
    if (value == null) {
      await showErrorDialog(
        context,
        'Parameter not found',
        'Could not find "${param.label}" on the avatar - it may not exist under that name.',
      );
      return;
    }
    _recordInteraction(param);
    if (param.type == ParamType.toggle && value is bool) {
      final boolValue = value;
      setState(() => _values[param.name] = boolValue);
    } else if (param.type == ParamType.slider && value is double) {
      final doubleValue = value;
      setState(() => _values[param.name] = doubleValue);
      _sliderTextControllers[param.name]?.text = formatParamNumber(doubleValue, _advancedMode);
    } else {
      messenger.showSnackBar(SnackBar(content: Text('"${param.label}" is a different type on the avatar - not applied.')));
    }
  }

  Future<void> _openDiscoverySheet(
    List<DiscoveredParam> found, {
    bool fetchFailed = false,
    String? failureDetail,
  }) async {
    final config = _config;
    if (config == null) return;
    await showDiscoveryResultsSheet(
      context,
      found: found,
      autoStartLive: fetchFailed,
      fetchFailed: fetchFailed,
      failureDetail: failureDetail,
      developerMode: config.developerMode,
      avatarChangeListenPort: config.port + 1,
      noiseThreshold: config.liveParamNoiseThreshold,
      existingNames: config.parameters.map((p) => p.name).toSet(),
      onAdd: (control) => _addDiscoveredControl(config, control),
    );
  }

  Future<void> _discover() async {
    final devMode = _config?.developerMode ?? false;
    // check the shortcut BEFORE running mDNS again (it has its own multi-
    // second timeout, driven by the same OSCQuery fetch timeout setting) -
    // otherwise "within 1s" would never actually be reachable, since that
    // much time alone would already have passed by the time a second search
    // finishes.
    if (devMode &&
        _lastDiscoverFailure != null &&
        DateTime.now().difference(_lastDiscoverFailure!) <= const Duration(seconds: 1)) {
      _lastDiscoverFailure = null;
      await _openDiscoverySheet(const []);
      return;
    }

    setState(() => _discovering = true);
    try {
      final fetchTimeout = Duration(seconds: _config?.oscQueryFetchTimeoutSeconds ?? 5);
      final result = await OscQueryClient.findVrchatInstances(anyOscQueryService: devMode, timeout: fetchTimeout);
      if (!mounted) return;
      if (result.instances.isEmpty) {
        _lastDiscoverFailure = devMode ? DateTime.now() : null;
        await showErrorDialog(
          context,
          'No OSCQuery service found',
          (result.error ?? oscNotFoundExplanation) +
              (devMode ? '\n\nClick Discover again within 1s to bring up the add menu anyway (developer mode).' : ''),
        );
        return;
      }
      final (host, port) = result.instances.first;
      List<DiscoveredParam> found;
      var fetchFailed = false;
      String? failureDetail;
      try {
        found = await OscQueryClient.fetchAvatarParameters(host, port, perAttemptTimeout: fetchTimeout);
      } catch (e) {
        // some avatars hang VRChat's OSCQuery server outright - fall back to
        // building the list from live OSC traffic instead.
        found = const [];
        fetchFailed = true;
        failureDetail = e.toString();
      }
      if (!mounted) return;
      await _openDiscoverySheet(found, fetchFailed: fetchFailed, failureDetail: failureDetail);
    } catch (e) {
      if (!mounted) return;
      await showErrorDialog(context, 'Discovery failed', e.toString());
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  void _addDiscoveredControl(AppConfig config, ParamControl control) {
    config.parameters.add(control);
    _values[control.name] = control.type == ParamType.toggle ? control.defaultBool : control.defaultValue;
    if (control.type == ParamType.slider) {
      _sliderTextControllers[control.name] =
          TextEditingController(text: formatParamNumber(control.defaultValue, _advancedMode));
    } else if (control.type == ParamType.custom) {
      _customValueControllers[control.name] = TextEditingController(text: control.customValueText);
    }
    ConfigStore.save(config);
    setState(() {});
  }

  @override
  void dispose() {
    _engineTimer?.cancel();
    _osc?.dispose();
    _avatarChangeSub?.cancel();
    if (_avatarWatcherActive) {
      _avatarWatcherActive = false;
      oscInputHub.release();
    }
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
                  // snapshot profiles aren't selectable as the active
                  // profile - only regular profiles show up here.
                  for (final p in _config!.profiles.where((p) => !p.isSnapshot))
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
            icon: const Icon(Icons.playlist_play),
            tooltip: 'Sequences',
            onPressed: _config == null ? null : _openSequencesPage,
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
          child: Row(
            children: [
              Expanded(
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
              if (config.showAutomationMasterSwitch) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Automation Master Switch - flips every automation it covers at once',
                  child: Switch(
                    value: automationMasterSwitchAggregate(config),
                    onChanged: (v) {
                      setState(() => applyAutomationMasterSwitch(config, v));
                      _persist();
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
