import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';

import 'automation_engine.dart';
import 'config_store.dart';
import 'osc_client.dart';
import 'osc_input_hub.dart';
import 'osc_listener.dart';
import 'oscquery_client.dart';
import 'param_control.dart';
import 'schedule_engine.dart';
import 'sequence_engine.dart';
import 'theme_notifier.dart';
import 'trigger_engine.dart';
import 'vrchat_files.dart';

/// everything live about the active profile - current values, their text
/// fields, the OSC client, and the single tick loop driving every engine.
/// shared by the main screen, the sequence editor and Settings (they all
/// listen to it), so a value changed in one place shows up everywhere and
/// no screen ever holds a stale copy.
class LiveController extends ChangeNotifier {
  AppConfig config;

  /// double for sliders, bool for toggles - read through [sliderValue] /
  /// [toggleValue], which never throw on a stale entry of the wrong type.
  final Map<String, Object> values = {};
  final Map<String, TextEditingController> sliderText = {};
  final Map<String, TextEditingController> customText = {};

  OscClient _osc;
  OscClient get osc => _osc;

  final automationEngine = AutomationEngine();
  final scheduleEngine = ScheduleEngine();
  final sequenceEngine = SequenceEngine();
  final triggerEngine = TriggerEngine();
  Timer? _timer;
  Timer? _persistTimer;

  /// last manual slider/toggle touch anywhere - drives idle schedules.
  DateTime lastInteraction = DateTime.now();
  final Map<String, DateTime> _userTouched = {};
  final Map<String, DateTime> _engineTouched = {};
  final Map<String, (double, DateTime)> _lastSentSlider = {};
  Map<String, ParamControl> _byAddress = {};
  bool _dirty = false;

  StreamSubscription<OscMessage>? _inputSub;
  bool _inputAcquired = false;
  bool _disposed = false;
  bool _pulling = false;
  String? _knownVrchat;
  bool _wasAutoMode = false;
  bool _wasSyncing = false;
  Timer? _pullAfterChange;

  /// transient messages for the user (e.g. auto mode switching profile).
  void Function(String message)? onNotice;

  LiveController(this.config) : _osc = OscClient(host: config.host, port: config.port) {
    _inputSub = oscInputHub.messages.listen(_onOscMessage);
    oscInputHub.status.addListener(_onLinkStatus);
    reconcile();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) => tick());
  }

  bool get advancedMode => config.advancedMode;
  List<ParamControl> get parameters => config.parameters;
  List<AutomationSequence> get sequences => config.sequences;

  double sliderValue(ParamControl p) => sliderValueOf(values, p);
  bool toggleValue(ParamControl p) => toggleValueOf(values, p);

  @override
  void dispose() {
    _disposed = true;
    oscInputHub.status.removeListener(_onLinkStatus);
    _pullAfterChange?.cancel();
    _timer?.cancel();
    _persistTimer?.cancel();
    _inputSub?.cancel();
    if (_inputAcquired) oscInputHub.release();
    _osc.dispose();
    for (final c in [...sliderText.values, ...customText.values]) {
      c.dispose();
    }
    super.dispose();
  }

  // --- persistence ---

  Future<void> persist() => ConfigStore.save(config);

  // engine-originated changes (a countdown finishing, a trigger gate
  // flipping) can happen many times a second - batch those writes.
  void _persistSoon() {
    _persistTimer ??= Timer(const Duration(seconds: 1), () {
      _persistTimer = null;
      persist();
    });
  }

  /// replaces the whole config (a reload from disk).
  void replaceConfig(AppConfig next) {
    config = next;
    automationEngine.reset();
    scheduleEngine.reset();
    sequenceEngine.reset();
    triggerEngine.reset();
    reconcile();
  }

  // --- manual edits ---

  // manual interaction pauses (not deletes) a running automation, and resets
  // the idle clock for idle-triggered schedules.
  void recordInteraction(ParamControl param) {
    final now = DateTime.now();
    lastInteraction = now;
    _userTouched[param.name] = now;
    final auto = param.automation;
    if (auto != null && auto.enabled) {
      auto.enabled = false;
      persist();
    }
  }

  void setSlider(ParamControl param, double value) {
    if (!value.isFinite) return;
    recordInteraction(param);
    values[param.name] = value;
    _setSliderText(param, value);
    _sendSlider(param, value);
    notifyListeners();
  }

  /// the slider's text box - no limiter on the value itself, the box never
  /// touches min/max; the slider thumb just clamps its own display.
  void submitSliderText(ParamControl param, String text) {
    final value = parseUserDouble(text);
    if (value == null) {
      // revert to last known-good value on unparsable input (incl. "NaN").
      _setSliderText(param, sliderValue(param));
      return;
    }
    setSlider(param, value);
  }

  /// shows a value read back from VRChat - display only, nothing is sent,
  /// and a running automation on it is paused like any manual change.
  void setLocalValue(ParamControl param, Object value) {
    recordInteraction(param);
    if (param.type == ParamType.toggle && value is bool) {
      values[param.name] = value;
    } else if (param.type == ParamType.slider && value is num && value.isFinite) {
      values[param.name] = value.toDouble();
      _lastSentSlider.remove(param.name);
      _setSliderText(param, value.toDouble());
    } else {
      return;
    }
    notifyListeners();
  }

  void setToggle(ParamControl param, bool value) {
    recordInteraction(param);
    values[param.name] = value;
    _osc.sendBool(oscAddressFor(param), value);
    notifyListeners();
  }

  /// throws with a readable message if the value can't be encoded/sent.
  Future<void> sendCustom(ParamControl param) async {
    final text = customText[param.name]?.text ?? param.customValueText;
    recordInteraction(param);
    await _osc.sendCustom(oscAddressFor(param), param.customTypeTag, text);
  }

  /// re-sends a parameter's current value - handy after an avatar reload.
  void resend(ParamControl param) {
    switch (param.type) {
      case ParamType.slider:
        _sendSlider(param, sliderValue(param), force: true);
      case ParamType.toggle:
        _osc.sendBool(oscAddressFor(param), toggleValue(param));
      case ParamType.custom:
        sendCustom(param).catchError((_) {});
    }
  }

  void _setSliderText(ParamControl param, double value) {
    final controller = sliderText[param.name];
    final text = formatParamValue(param, value, advancedMode);
    if (controller != null && controller.text != text) controller.text = text;
  }

  void _sendSlider(ParamControl param, double value, {bool force = false}) {
    final now = DateTime.now();
    // engines re-send an unchanged value every tick while holding - keep a
    // once-a-second refresh, but don't flood VRChat 30 times a second.
    final last = _lastSentSlider[param.name];
    if (!force && last != null && last.$1 == value && now.difference(last.$2) < const Duration(seconds: 1)) return;
    _lastSentSlider[param.name] = (value, now);
    final address = oscAddressFor(param);
    if (param.numericKind == NumericKind.int) {
      _osc.sendInt(address, value.round().clamp(-2147483648, 2147483647));
    } else {
      _osc.sendFloat(address, value);
    }
  }

  // --- structure ---

  bool hasParam(String name) => parameters.any((p) => p.name == name);

  bool addParam(ParamControl param) {
    if (hasParam(param.name)) return false;
    parameters.add(param);
    _initParam(param);
    _rebuildIndex();
    persist();
    notifyListeners();
    return true;
  }

  void removeParam(ParamControl param) {
    parameters.remove(param);
    if (!hasParam(param.name)) _dropParamState(param.name);
    _rebuildIndex();
    persist();
    notifyListeners();
  }

  /// swaps [old] for [updated] (an edit), following a rename through every
  /// reference to it and keeping its live value when the type still fits.
  void replaceParam(ParamControl old, ParamControl updated) {
    final index = parameters.indexOf(old);
    if (index == -1) return;
    parameters[index] = updated;
    final live = values[old.name];
    final renamed = old.name != updated.name;
    if (renamed) {
      config.renameParamReferences(old.name, updated.name);
      _dropParamState(old.name);
    } else {
      _dropParamState(old.name);
    }
    _initParam(updated);
    if (old.type == updated.type) {
      if (updated.type == ParamType.toggle && live is bool) values[updated.name] = live;
      if (updated.type == ParamType.slider && live is double) {
        values[updated.name] = live;
        _setSliderText(updated, live);
      }
    }
    _rebuildIndex();
    persist();
    notifyListeners();
  }

  void reorderParam(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= parameters.length) return;
    final item = parameters.removeAt(oldIndex);
    parameters.insert(newIndex.clamp(0, parameters.length), item);
    persist();
    notifyListeners();
  }

  void switchProfile(String profileId) {
    if (config.activeProfileId == profileId) return;
    if (!config.profiles.any((p) => p.id == profileId && !p.isSnapshot)) return;
    config.activeProfileId = profileId;
    // a same-named parameter in the new profile should start its automation
    // fresh, not inherit timing from whatever was running under this name a
    // moment ago on the old profile - and start from its own default.
    for (final name in values.keys.toList()) {
      _dropParamState(name);
    }
    automationEngine.reset();
    scheduleEngine.reset();
    sequenceEngine.reset();
    triggerEngine.reset();
    persist();
    reconcile();
  }

  /// brings live state in line with [config] after it was edited somewhere
  /// else (Settings, a reload) - only entries that actually changed are
  /// touched, everything else keeps its live value and text field.
  void reconcile() {
    if (_osc.host != config.host || _osc.port != config.port) {
      _osc.dispose();
      _osc = OscClient(host: config.host, port: config.port);
      _lastSentSlider.clear();
    }
    applyThemeFromConfig(config);
    oscInputHub.setLegacyPort(config.port + 1);
    _updateInputAcquire();

    final current = {for (final p in parameters) p.name};
    for (final key in {...values.keys, ...sliderText.keys, ...customText.keys}) {
      if (!current.contains(key)) _dropParamState(key);
    }
    for (final p in parameters) {
      final ok = switch (p.type) {
        ParamType.slider => values[p.name] is double && sliderText.containsKey(p.name),
        ParamType.toggle => values[p.name] is bool,
        ParamType.custom => customText.containsKey(p.name),
      };
      if (ok) {
        if (p.type == ParamType.slider) _setSliderText(p, sliderValue(p));
        continue;
      }
      // new parameter, or one whose type changed - (re)initialize just this one.
      _dropParamState(p.name);
      _initParam(p);
    }
    _rebuildIndex();
    notifyListeners();
  }

  void _initParam(ParamControl p) {
    switch (p.type) {
      case ParamType.toggle:
        values[p.name] = p.defaultBool;
      case ParamType.slider:
        final v = p.defaultValue.isFinite ? p.defaultValue : 0.0;
        values[p.name] = v;
        sliderText[p.name] ??= TextEditingController(text: formatParamValue(p, v, advancedMode));
      case ParamType.custom:
        customText[p.name] ??= TextEditingController(text: p.customValueText);
    }
  }

  void _dropParamState(String name) {
    values.remove(name);
    _lastSentSlider.remove(name);
    final a = sliderText.remove(name);
    final b = customText.remove(name);
    // a text field may still be showing these until the next frame builds.
    if (a != null || b != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        a?.dispose();
        b?.dispose();
      });
    }
  }

  void _rebuildIndex() {
    _byAddress = {for (final p in parameters) oscAddressFor(p): p};
  }

  void _updateInputAcquire() {
    // only Auto Mode needs the legacy fixed port as a fallback - live value
    // sync is happy with whatever arrives via OSCQuery, and holding the
    // fixed port just in case would block other OSC apps from it.
    final want = config.autoProfileMode;
    // /avatar/change only fires on a CHANGE - switching auto mode (or live
    // sync) on while already wearing an avatar has to ask for the current
    // one instead of waiting for the next swap.
    final autoTurnedOn = want && !_wasAutoMode;
    final syncTurnedOn = config.syncFromVrchat && !_wasSyncing;
    _wasAutoMode = want;
    _wasSyncing = config.syncFromVrchat;
    if (autoTurnedOn || syncTurnedOn) {
      scheduleMicrotask(() => pullFromVrchat(avatar: autoTurnedOn, values: syncTurnedOn));
    }
    if (want && !_inputAcquired) {
      _inputAcquired = true;
      oscInputHub.acquire();
    } else if (!want && _inputAcquired) {
      _inputAcquired = false;
      oscInputHub.release();
    }
  }

  // --- snapshots / bulk ---

  // pushes a snapshot's saved values onto the active profile (a restore, not
  // a switch) - parameters the profile is missing get added fresh with the
  // snapshot's full definition, rather than silently skipped.
  void applySnapshot(Profile snapshot) {
    for (final saved in snapshot.parameters) {
      var live = config.activeProfile.param(saved.name);
      if (live == null) {
        live = saved.copy();
        parameters.add(live);
        _initParam(live);
      }
      if (live.type == ParamType.toggle && saved.type == ParamType.toggle) {
        values[live.name] = saved.defaultBool;
        _osc.sendBool(oscAddressFor(live), saved.defaultBool);
      } else if (live.type == ParamType.slider && saved.type == ParamType.slider) {
        values[live.name] = saved.defaultValue;
        sliderText[live.name] ??= TextEditingController();
        _setSliderText(live, saved.defaultValue);
        _sendSlider(live, saved.defaultValue, force: true);
      }
    }
    _rebuildIndex();
    persist();
    notifyListeners();
  }

  /// copies live values VRChat reported (e.g. from a full OSCQuery fetch)
  /// onto matching parameters - display only, nothing is sent. returns how
  /// many were updated.
  int applyReportedValues(List<DiscoveredParam> found) {
    var count = 0;
    for (final d in found) {
      final param = config.activeProfile.param(d.name);
      if (param == null || d.value == null) continue;
      if (_applyIncoming(param, d.value!)) count++;
    }
    if (count > 0) notifyListeners();
    return count;
  }

  // --- incoming OSC ---

  /// catches up with what VRChat is doing right now - the current avatar
  /// (for auto mode) and every parameter's value (for live sync). only runs
  /// once VRChat is actually known, so it never kicks off a slow search.
  Future<void> pullFromVrchat({bool avatar = true, bool values = true}) async {
    if (_pulling || _disposed) return;
    avatar = avatar && config.autoProfileMode;
    values = values && config.syncFromVrchat;
    if (!avatar && !values) return;
    // the hub may already have heard an /avatar/change while auto mode was off.
    final heard = oscInputHub.lastAvatarId;
    if (avatar && heard != null) {
      await _onAvatarChanged(heard);
      avatar = false;
      if (!values) return;
    }
    if (oscInputHub.status.value.vrchat == null) return;
    _pulling = true;
    try {
      final timeout = Duration(seconds: config.oscQueryFetchTimeoutSeconds);
      final lookup = await OscQueryClient.findVrchat(anyOscQueryService: config.developerMode, timeout: timeout);
      final endpoint = lookup.endpoint;
      if (endpoint == null || _disposed) return;
      if (avatar && config.autoProfileMode) {
        final id = await OscQueryClient.fetchAvatarId(endpoint);
        if (id != null && !_disposed) {
          oscInputHub.lastAvatarId = id;
          await _onAvatarChanged(id);
        }
      }
      if (values && config.syncFromVrchat && !_disposed) {
        final found = await OscQueryClient.fetchAvatarParameters(endpoint, maxAttempts: 1, perAttemptTimeout: timeout);
        if (!_disposed) applyReportedValues(found);
      }
    } catch (_) {
      // best effort - live changes still arrive as they happen.
    } finally {
      _pulling = false;
    }
  }

  void _onLinkStatus() {
    final peer = oscInputHub.status.value.vrchat;
    final key = peer == null ? null : '${peer.host}:${peer.port}';
    if (key == _knownVrchat) return;
    _knownVrchat = key;
    // VRChat just showed up (app started after it, or it restarted).
    if (key != null) pullFromVrchat();
  }

  void _onOscMessage(OscMessage msg) {
    if (msg.address == '/avatar/change') {
      if (msg.args.isEmpty || msg.args.first is! String) return;
      if (config.autoProfileMode) _onAvatarChanged(msg.args.first as String);
      // a freshly loaded avatar starts from its own defaults - re-read
      // them once it's had a moment to load.
      if (config.syncFromVrchat) {
        _pullAfterChange?.cancel();
        _pullAfterChange = Timer(const Duration(seconds: 2), () => pullFromVrchat(avatar: false));
      }
      return;
    }
    if (!config.syncFromVrchat || msg.args.isEmpty) return;
    final param = _byAddress[msg.address];
    if (param == null) return;
    final now = DateTime.now();
    bool recent(DateTime? t, int ms) => t != null && now.difference(t).inMilliseconds < ms;
    // our own sends echo back from VRChat a moment later - ignore anything
    // arriving while the user or an engine is actively moving this value.
    if (recent(_userTouched[param.name], 400) || recent(_engineTouched[param.name], 300)) return;
    if (_applyIncoming(param, msg.args.first)) _dirty = true;
  }

  bool _applyIncoming(ParamControl param, Object raw) {
    switch (param.type) {
      case ParamType.toggle:
        final v = raw is bool ? raw : (raw is num ? raw != 0 : null);
        if (v == null || values[param.name] == v) return false;
        values[param.name] = v;
        return true;
      case ParamType.slider:
        final v = raw is num ? raw.toDouble() : (raw is bool ? (raw ? 1.0 : 0.0) : null);
        if (v == null || !v.isFinite) return false;
        final old = values[param.name];
        if (old is double && (old - v).abs() < 1e-6) return false;
        values[param.name] = v;
        _lastSentSlider.remove(param.name);
        _setSliderText(param, v);
        return true;
      case ParamType.custom:
        return false;
    }
  }

  Future<void> _onAvatarChanged(String avatarId) async {
    if (_disposed || !config.autoProfileMode || config.activeProfile.avatarId == avatarId) return;
    // snapshot profiles are static saves, never candidates for auto mode's
    // avatar-based matching/creation.
    final match = config.profiles.where((p) => !p.isSnapshot && p.avatarId == avatarId).firstOrNull;
    if (match != null) {
      switchProfile(match.id);
    } else {
      final name = await _avatarProfileName(avatarId);
      // another change may have landed while the name lookup ran.
      if (_disposed || config.profiles.any((p) => !p.isSnapshot && p.avatarId == avatarId)) return;
      final profile = Profile(id: newId(), name: name, avatarId: avatarId);
      config.profiles.add(profile);
      switchProfile(profile.id);
    }
    onNotice?.call('Auto mode: switched to "${config.activeProfile.name}"');
  }

  // OSC only ever gives the avatar ID, not its name - looked up separately.
  // suffix is always added, even with a real name, to avoid collisions.
  Future<String> _avatarProfileName(String avatarId) async {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random();
    final suffix = List.generate(4, (_) => chars[rand.nextInt(chars.length)]).join();
    final realName = await VrchatFiles.avatarName(avatarId);
    if (realName != null) return '$realName #$suffix';
    final shortId = avatarId.length > 8 ? avatarId.substring(avatarId.length - 8) : avatarId;
    return 'Avatar $shortId #$suffix';
  }

  // --- the tick loop ---

  /// names of parameters some sequence is driving right now through its
  /// own per-parameter automation (so the global one stands down).
  Set<String> sequenceDrivenNames() {
    final out = <String>{};
    for (final seq in sequences) {
      for (final name in seq.paramAutomations.keys) {
        if (sequenceActivelyDrivesParam(seq, name)) out.add(name);
      }
    }
    return out;
  }

  @visibleForTesting
  void tick() {
    final params = parameters;
    final seqs = sequences;
    final now = DateTime.now();

    String flags() => [
          for (final p in params) '${p.automation?.enabled}${p.schedule?.enabled}',
          for (final s in seqs) '${s.enabled}${s.paramAutomations.values.map((a) => a.enabled).join()}',
        ].join();
    final wasEnabled = flags();

    var changed = false;
    void onSlider(ParamControl param, double value) {
      _engineTouched[param.name] = now;
      if (!value.isFinite) return;
      final old = values[param.name];
      if (old is! double || old != value) {
        values[param.name] = value;
        _setSliderText(param, value);
        changed = true;
      }
      _sendSlider(param, value);
    }

    void onToggle(ParamControl param, bool value) {
      _engineTouched[param.name] = now;
      values[param.name] = value;
      _osc.sendBool(oscAddressFor(param), value);
      changed = true;
    }

    // triggers go first, so whatever they switch on/off this tick is what
    // the engines below actually run.
    triggerEngine.tick(params, seqs, values);

    // only one source may drive a parameter at a time: a sequence actively
    // driving it wins over its global automation, and that sequence's own
    // step script (if targeting the same parameter) wins over its
    // paramAutomations override.
    final sequenceDriven = sequenceDrivenNames();
    final targets = <AutomationTarget>[];
    for (final p in params) {
      final auto = p.automation;
      if (auto != null && auto.enabled && !sequenceDriven.contains(p.name)) {
        targets.add(AutomationTarget(
          key: 'param:${p.name}',
          param: p,
          automation: auto,
          onFinished: () => auto.enabled = false,
        ));
      }
    }
    for (final seq in seqs) {
      if (!seq.enabled) continue;
      for (final entry in seq.paramAutomations.entries) {
        if (!sequenceActivelyDrivesParam(seq, entry.key)) continue;
        final param = config.activeProfile.param(entry.key);
        if (param == null) continue;
        targets.add(AutomationTarget(key: 'seq:${seq.id}:${entry.key}', param: param, automation: entry.value));
      }
    }

    automationEngine.tick(targets, onSlider, onToggle);
    scheduleEngine.tick(params, lastInteraction, values, onSlider, onToggle);
    sequenceEngine.tick(seqs, params, values, onSlider, onToggle);

    final flagsChanged = flags() != wasEnabled;
    if (flagsChanged) _persistSoon();
    if (changed || flagsChanged || _dirty) {
      _dirty = false;
      notifyListeners();
    }
  }
}
