import 'package:flutter/material.dart';

enum ParamType { slider, toggle, custom }

// only relevant for ParamType.slider - which OSC numeric type to wire-encode as.
enum NumericKind { float, int }

// ramp: glides between two values. random: picks a new value/state on an
// interval (sliders can drift smoothly toward it, toggles just flip).
// blink: toggle-only on/off cycling.
enum AutomationKind { ramp, random, blink }

enum RampRepeat { once, loop, pingPong }

enum EasingKind { linear, easeInOut, sine, custom }

class Automation {
  bool enabled;
  AutomationKind kind;

  // ramp (slider)
  double rampFrom;
  double rampTo;
  double rampDurationSeconds;
  RampRepeat rampRepeat;
  // only used when rampRepeat is loop/pingPong - 0 means repeat forever.
  int rampRepeatCount;
  // only used when rampRepeat is loop/pingPong - multiplies each repeat's
  // duration by this factor (1 = no change, <1 speeds up, >1 slows down),
  // floored at 0.05s so it can't shrink to a standstill.
  double rampRepeatSpeedFactor;
  EasingKind easing;
  // only used when easing is custom - a hand-drawn progress-over-time curve,
  // points sorted by x, each axis normalized to roughly [0,1] (points can
  // stray outside that range for overshoot).
  List<Offset> customCurvePoints;
  // whether customCurvePoints is interpolated as straight segments or a
  // smooth spline through the points.
  bool customCurveSmooth;
  // the curve editor's vertical bounds - purely an editing viewport/drag
  // range, not read by the engine (points can still carry any y value).
  double customCurveYMin;
  double customCurveYMax;

  // random - value range (sliders only) and how often a new value/flip
  // happens: a fresh random wait time is picked between the min/max interval
  // each time, so it doesn't feel mechanically regular.
  double randomValueMin;
  double randomValueMax;
  double randomIntervalMinSeconds;
  double randomIntervalMaxSeconds;
  bool randomSmooth;

  // blink (toggle)
  double blinkOnSeconds;
  double blinkOffSeconds;

  Automation({
    this.enabled = false,
    this.kind = AutomationKind.ramp,
    this.rampFrom = 0.0,
    this.rampTo = 1.0,
    this.rampDurationSeconds = 2.0,
    this.rampRepeat = RampRepeat.pingPong,
    this.rampRepeatCount = 0,
    this.rampRepeatSpeedFactor = 1.0,
    this.easing = EasingKind.easeInOut,
    List<Offset>? customCurvePoints,
    this.customCurveSmooth = false,
    this.customCurveYMin = -0.3,
    this.customCurveYMax = 1.3,
    this.randomValueMin = 0.0,
    this.randomValueMax = 1.0,
    this.randomIntervalMinSeconds = 1.0,
    this.randomIntervalMaxSeconds = 3.0,
    this.randomSmooth = true,
    this.blinkOnSeconds = 1.0,
    this.blinkOffSeconds = 1.0,
  }) : customCurvePoints = customCurvePoints ?? [const Offset(0, 0), const Offset(1, 1)];

  factory Automation.fromJson(Map<String, dynamic> json) {
    return Automation(
      enabled: (json['enabled'] as bool?) ?? false,
      kind: switch (json['kind'] as String?) {
        'random' => AutomationKind.random,
        'blink' => AutomationKind.blink,
        _ => AutomationKind.ramp,
      },
      rampFrom: (json['rampFrom'] as num?)?.toDouble() ?? 0.0,
      rampTo: (json['rampTo'] as num?)?.toDouble() ?? 1.0,
      rampDurationSeconds: (json['rampDurationSeconds'] as num?)?.toDouble() ?? 2.0,
      rampRepeat: switch (json['rampRepeat'] as String?) {
        'once' => RampRepeat.once,
        'loop' => RampRepeat.loop,
        _ => RampRepeat.pingPong,
      },
      rampRepeatCount: (json['rampRepeatCount'] as num?)?.toInt() ?? 0,
      rampRepeatSpeedFactor: (json['rampRepeatSpeedFactor'] as num?)?.toDouble() ?? 1.0,
      easing: switch (json['easing'] as String?) {
        'linear' => EasingKind.linear,
        'sine' => EasingKind.sine,
        'custom' => EasingKind.custom,
        _ => EasingKind.easeInOut,
      },
      customCurvePoints: (json['customCurvePoints'] as List?)
          ?.map((e) => Offset((e[0] as num).toDouble(), (e[1] as num).toDouble()))
          .toList(),
      customCurveSmooth: (json['customCurveSmooth'] as bool?) ?? false,
      customCurveYMin: (json['customCurveYMin'] as num?)?.toDouble() ?? -0.3,
      customCurveYMax: (json['customCurveYMax'] as num?)?.toDouble() ?? 1.3,
      randomValueMin: (json['randomValueMin'] as num?)?.toDouble() ?? 0.0,
      randomValueMax: (json['randomValueMax'] as num?)?.toDouble() ?? 1.0,
      randomIntervalMinSeconds: (json['randomIntervalMinSeconds'] as num?)?.toDouble() ?? 1.0,
      randomIntervalMaxSeconds: (json['randomIntervalMaxSeconds'] as num?)?.toDouble() ?? 3.0,
      randomSmooth: (json['randomSmooth'] as bool?) ?? true,
      blinkOnSeconds: (json['blinkOnSeconds'] as num?)?.toDouble() ?? 1.0,
      blinkOffSeconds: (json['blinkOffSeconds'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'kind': switch (kind) {
        AutomationKind.ramp => 'ramp',
        AutomationKind.random => 'random',
        AutomationKind.blink => 'blink',
      },
      'rampFrom': rampFrom,
      'rampTo': rampTo,
      'rampDurationSeconds': rampDurationSeconds,
      'rampRepeat': switch (rampRepeat) {
        RampRepeat.once => 'once',
        RampRepeat.loop => 'loop',
        RampRepeat.pingPong => 'pingPong',
      },
      'rampRepeatCount': rampRepeatCount,
      'rampRepeatSpeedFactor': rampRepeatSpeedFactor,
      'easing': switch (easing) {
        EasingKind.linear => 'linear',
        EasingKind.sine => 'sine',
        EasingKind.easeInOut => 'easeInOut',
        EasingKind.custom => 'custom',
      },
      'customCurvePoints': customCurvePoints.map((p) => [p.dx, p.dy]).toList(),
      'customCurveSmooth': customCurveSmooth,
      'customCurveYMin': customCurveYMin,
      'customCurveYMax': customCurveYMax,
      'randomValueMin': randomValueMin,
      'randomValueMax': randomValueMax,
      'randomIntervalMinSeconds': randomIntervalMinSeconds,
      'randomIntervalMaxSeconds': randomIntervalMaxSeconds,
      'randomSmooth': randomSmooth,
      'blinkOnSeconds': blinkOnSeconds,
      'blinkOffSeconds': blinkOffSeconds,
    };
  }
}

// timeOfDay/interval: recurring, fire repeatedly. idle: fires once after no
// manual interaction with the app for a while, resets when interaction
// resumes. countdown: fires once, N seconds after being enabled, then
// disables itself.
enum ScheduleKind { timeOfDay, interval, idle, countdown }

class ParamSchedule {
  bool enabled;
  ScheduleKind kind;

  // timeOfDay - fires once per day at this clock time.
  int timeOfDayHour;
  int timeOfDayMinute;

  // interval - fires every N seconds, repeating.
  double intervalSeconds;

  // idle - fires after this many seconds with no manual slider/toggle
  // interaction anywhere in the app.
  double idleSeconds;

  // countdown - fires once, this many seconds after being enabled.
  double countdownSeconds;

  // what firing sets the parameter to.
  double targetValue;
  bool targetBool;

  // if >0, automatically restores whatever the value was right before firing,
  // this many seconds later (a "pulse" instead of a permanent change).
  double revertAfterSeconds;

  ParamSchedule({
    this.enabled = false,
    this.kind = ScheduleKind.timeOfDay,
    this.timeOfDayHour = 21,
    this.timeOfDayMinute = 0,
    this.intervalSeconds = 1800,
    this.idleSeconds = 300,
    this.countdownSeconds = 60,
    this.targetValue = 1.0,
    this.targetBool = true,
    this.revertAfterSeconds = 0,
  });

  factory ParamSchedule.fromJson(Map<String, dynamic> json) {
    return ParamSchedule(
      enabled: (json['enabled'] as bool?) ?? false,
      kind: switch (json['kind'] as String?) {
        'interval' => ScheduleKind.interval,
        'idle' => ScheduleKind.idle,
        'countdown' => ScheduleKind.countdown,
        _ => ScheduleKind.timeOfDay,
      },
      timeOfDayHour: (json['timeOfDayHour'] as num?)?.toInt() ?? 21,
      timeOfDayMinute: (json['timeOfDayMinute'] as num?)?.toInt() ?? 0,
      intervalSeconds: (json['intervalSeconds'] as num?)?.toDouble() ?? 1800,
      idleSeconds: (json['idleSeconds'] as num?)?.toDouble() ?? 300,
      countdownSeconds: (json['countdownSeconds'] as num?)?.toDouble() ?? 60,
      targetValue: (json['targetValue'] as num?)?.toDouble() ?? 1.0,
      targetBool: (json['targetBool'] as bool?) ?? true,
      revertAfterSeconds: (json['revertAfterSeconds'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'kind': switch (kind) {
        ScheduleKind.timeOfDay => 'timeOfDay',
        ScheduleKind.interval => 'interval',
        ScheduleKind.idle => 'idle',
        ScheduleKind.countdown => 'countdown',
      },
      'timeOfDayHour': timeOfDayHour,
      'timeOfDayMinute': timeOfDayMinute,
      'intervalSeconds': intervalSeconds,
      'idleSeconds': idleSeconds,
      'countdownSeconds': countdownSeconds,
      'targetValue': targetValue,
      'targetBool': targetBool,
      'revertAfterSeconds': revertAfterSeconds,
    };
  }
}

class ParamControl {
  String name;
  String label;
  ParamType type;
  String? category;

  // slider fields
  double min;
  double max;
  double defaultValue;
  NumericKind numericKind;

  // toggle fields
  bool defaultBool;

  // custom fields - a free-typed OSC type tag (e.g. "f","i","d","s","T","F")
  // and its value as text, for types this app has no dedicated widget for.
  String customTypeTag;
  String customValueText;

  // null = no automation/schedule configured. sliders and toggles only.
  Automation? automation;
  ParamSchedule? schedule;

  ParamControl({
    required this.name,
    required this.label,
    required this.type,
    this.category,
    this.min = 0.0,
    this.max = 1.0,
    this.defaultValue = 0.0,
    this.numericKind = NumericKind.float,
    this.defaultBool = false,
    this.customTypeTag = 'f',
    this.customValueText = '0',
    this.automation,
    this.schedule,
  });

  factory ParamControl.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String;
    final typeStr = json['type'] as String?;
    final type = switch (typeStr) {
      'toggle' => ParamType.toggle,
      'custom' => ParamType.custom,
      _ => ParamType.slider,
    };
    final rawDefault = json['default'];
    final category = json['category'] as String?;
    final rawAutomation = json['automation'] as Map<String, dynamic>?;
    final rawSchedule = json['schedule'] as Map<String, dynamic>?;
    return ParamControl(
      name: name,
      label: (json['label'] as String?) ?? name,
      type: type,
      category: (category == null || category.isEmpty) ? null : category,
      min: (json['min'] as num?)?.toDouble() ?? 0.0,
      max: (json['max'] as num?)?.toDouble() ?? 1.0,
      defaultValue: rawDefault is num ? rawDefault.toDouble() : 0.0,
      numericKind: (json['numericKind'] as String?) == 'int' ? NumericKind.int : NumericKind.float,
      defaultBool: rawDefault is bool ? rawDefault : false,
      customTypeTag: (json['customTypeTag'] as String?) ?? 'f',
      customValueText: (json['customValueText'] as String?) ?? '0',
      automation: rawAutomation == null ? null : Automation.fromJson(rawAutomation),
      schedule: rawSchedule == null ? null : ParamSchedule.fromJson(rawSchedule),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'label': label,
      'type': switch (type) {
        ParamType.toggle => 'toggle',
        ParamType.custom => 'custom',
        ParamType.slider => 'slider',
      },
      if (category != null) 'category': category,
      if (type == ParamType.slider) 'min': min,
      if (type == ParamType.slider) 'max': max,
      if (type == ParamType.slider) 'numericKind': numericKind == NumericKind.int ? 'int' : 'float',
      if (type == ParamType.custom) 'customTypeTag': customTypeTag,
      if (type == ParamType.custom) 'customValueText': customValueText,
      if (automation != null) 'automation': automation!.toJson(),
      if (schedule != null) 'schedule': schedule!.toJson(),
      'default': type == ParamType.toggle ? defaultBool : defaultValue,
    };
  }
}

// the seed color the app launches with before any config/preference is loaded.
const defaultThemeSeedColor = Color(0xFF6750A4);

// setValue: snaps (or, for sliders, glides over transitionSeconds) a
// parameter to a target and then advances. wait: a pure pause with no
// parameter action, for spacing steps out.
enum SequenceStepKind { setValue, wait }

enum SequenceRepeatMode { once, loop }

class SequenceStep {
  SequenceStepKind kind;
  // which parameter this step targets - ignored (and empty) for wait steps.
  String paramName;
  double targetValue;
  bool targetBool;
  // setValue: 0 = snap instantly, >0 = glide (sliders) or hold-then-advance
  // (toggles, which have no meaningful mid-transition state).
  // wait: how long to pause before advancing.
  double durationSeconds;

  SequenceStep({
    required this.kind,
    this.paramName = '',
    this.targetValue = 0.0,
    this.targetBool = false,
    this.durationSeconds = 1.0,
  });

  factory SequenceStep.fromJson(Map<String, dynamic> json) {
    return SequenceStep(
      kind: (json['kind'] as String?) == 'wait' ? SequenceStepKind.wait : SequenceStepKind.setValue,
      paramName: (json['paramName'] as String?) ?? '',
      targetValue: (json['targetValue'] as num?)?.toDouble() ?? 0.0,
      targetBool: (json['targetBool'] as bool?) ?? false,
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'kind': kind == SequenceStepKind.wait ? 'wait' : 'setValue',
      'paramName': paramName,
      'targetValue': targetValue,
      'targetBool': targetBool,
      'durationSeconds': durationSeconds,
    };
  }
}

// a named, ordered script of steps across (potentially) many parameters -
// "combine multiple automations" as a little visual program rather than
// each parameter running its automation in isolation.
class AutomationSequence {
  String id;
  String name;
  bool enabled;
  SequenceRepeatMode repeatMode;
  // only used when repeatMode is loop - 0 means repeat forever.
  int repeatCount;
  List<SequenceStep> steps;

  AutomationSequence({
    required this.id,
    required this.name,
    this.enabled = false,
    this.repeatMode = SequenceRepeatMode.once,
    this.repeatCount = 0,
    List<SequenceStep>? steps,
  }) : steps = steps ?? [];

  factory AutomationSequence.fromJson(Map<String, dynamic> json) {
    final rawSteps = (json['steps'] as List?) ?? const [];
    return AutomationSequence(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? 'Sequence',
      enabled: (json['enabled'] as bool?) ?? false,
      repeatMode: (json['repeatMode'] as String?) == 'loop' ? SequenceRepeatMode.loop : SequenceRepeatMode.once,
      repeatCount: (json['repeatCount'] as num?)?.toInt() ?? 0,
      steps: rawSteps.cast<Map<String, dynamic>>().map(SequenceStep.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'enabled': enabled,
      'repeatMode': repeatMode == SequenceRepeatMode.loop ? 'loop' : 'once',
      'repeatCount': repeatCount,
      'steps': steps.map((s) => s.toJson()).toList(),
    };
  }
}

// a profile is one avatar's set of parameters. avatarId is set when the
// profile was created (or matched) via auto mode; manually-made profiles
// leave it null and just get switched to by hand.
class Profile {
  String id;
  String name;
  String? avatarId;
  final List<ParamControl> parameters;
  final List<AutomationSequence> sequences;

  Profile({
    required this.id,
    required this.name,
    this.avatarId,
    List<ParamControl>? parameters,
    List<AutomationSequence>? sequences,
  })  : parameters = parameters ?? [],
        sequences = sequences ?? [];

  factory Profile.fromJson(Map<String, dynamic> json) {
    final rawParams = (json['parameters'] as List?) ?? const [];
    final rawSequences = (json['sequences'] as List?) ?? const [];
    return Profile(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? 'Profile',
      avatarId: json['avatarId'] as String?,
      parameters: rawParams.cast<Map<String, dynamic>>().map(ParamControl.fromJson).toList(),
      sequences: rawSequences.cast<Map<String, dynamic>>().map(AutomationSequence.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (avatarId != null) 'avatarId': avatarId,
      'parameters': parameters.map((p) => p.toJson()).toList(),
      'sequences': sequences.map((s) => s.toJson()).toList(),
    };
  }
}

class AppConfig {
  String host;
  int port;
  Color themeSeedColor;
  bool advancedMode;
  bool autoProfileMode;

  final List<Profile> profiles;
  String activeProfileId;

  // per-role overrides layered on top of ColorScheme.fromSeed(themeSeedColor).
  // null means "keep the auto-generated tone for this role".
  Color? primaryOverride;
  Color? secondaryOverride;
  Color? tertiaryOverride;
  Color? errorOverride;

  AppConfig({
    required this.host,
    required this.port,
    List<ParamControl>? parameters,
    List<Profile>? profiles,
    String? activeProfileId,
    this.themeSeedColor = defaultThemeSeedColor,
    this.advancedMode = false,
    this.autoProfileMode = false,
    this.primaryOverride,
    this.secondaryOverride,
    this.tertiaryOverride,
    this.errorOverride,
  })  : profiles = profiles ?? [Profile(id: 'default', name: 'Default', parameters: parameters ?? [])],
        activeProfileId = activeProfileId ??
            (profiles != null && profiles.isNotEmpty ? profiles.first.id : 'default');

  Profile get activeProfile => profiles.firstWhere(
        (p) => p.id == activeProfileId,
        orElse: () => profiles.first,
      );

  // most of the app just reads/mutates "the current parameters" - proxy
  // straight through to whichever profile is active so that code doesn't
  // need to know profiles exist.
  List<ParamControl> get parameters => activeProfile.parameters;
  List<AutomationSequence> get sequences => activeProfile.sequences;

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    List<Profile> profiles;
    String activeProfileId;

    final rawProfiles = json['profiles'] as List?;
    if (rawProfiles != null && rawProfiles.isNotEmpty) {
      profiles = rawProfiles.cast<Map<String, dynamic>>().map(Profile.fromJson).toList();
      activeProfileId = (json['activeProfileId'] as String?) ?? profiles.first.id;
    } else {
      // migrate a pre-profiles config's flat "parameters" list into a single profile.
      final legacyParams = ((json['parameters'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(ParamControl.fromJson)
          .toList();
      profiles = [Profile(id: 'default', name: 'Default', parameters: legacyParams)];
      activeProfileId = 'default';
    }

    return AppConfig(
      host: (json['host'] as String?) ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? 9000,
      profiles: profiles,
      activeProfileId: activeProfileId,
      themeSeedColor: colorFromHex(json['themeColor'] as String?) ?? defaultThemeSeedColor,
      advancedMode: (json['advancedMode'] as bool?) ?? false,
      // off by default for anyone upgrading from a pre-auto-mode config, and
      // off on a brand new config too - this is an explicit opt-in feature
      // since it passively listens for which avatar you're wearing.
      autoProfileMode: (json['autoProfileMode'] as bool?) ?? false,
      primaryOverride: colorFromHex(json['primaryOverride'] as String?),
      secondaryOverride: colorFromHex(json['secondaryOverride'] as String?),
      tertiaryOverride: colorFromHex(json['tertiaryOverride'] as String?),
      errorOverride: colorFromHex(json['errorOverride'] as String?),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'host': host,
      'port': port,
      'themeColor': colorToHex(themeSeedColor),
      'advancedMode': advancedMode,
      'autoProfileMode': autoProfileMode,
      if (primaryOverride != null) 'primaryOverride': colorToHex(primaryOverride!),
      if (secondaryOverride != null) 'secondaryOverride': colorToHex(secondaryOverride!),
      if (tertiaryOverride != null) 'tertiaryOverride': colorToHex(tertiaryOverride!),
      if (errorOverride != null) 'errorOverride': colorToHex(errorOverride!),
      'activeProfileId': activeProfileId,
      'profiles': profiles.map((p) => p.toJson()).toList(),
    };
  }
}

Color? colorFromHex(String? hex) {
  if (hex == null) return null;
  final cleaned = hex.replaceFirst('#', '');
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return null;
  return Color(0xFF000000 | value);
}

String colorToHex(Color color) {
  final argb = (color.a * 255).round() << 24 |
      (color.r * 255).round() << 16 |
      (color.g * 255).round() << 8 |
      (color.b * 255).round();
  return '#${argb.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

/// evaluates a hand-drawn curve at x=[t], shared by the automation engine
/// and the curve editor's live preview so they never disagree. [unsorted]
/// need not be sorted by x. Holds the nearest endpoint's y outside the
/// drawn range.
double evalCustomCurve(List<Offset> unsorted, bool smooth, double t) {
  if (unsorted.isEmpty) return t;
  if (unsorted.length == 1) return unsorted.first.dy;
  final points = [...unsorted]..sort((a, b) => a.dx.compareTo(b.dx));
  if (t <= points.first.dx) return points.first.dy;
  if (t >= points.last.dx) return points.last.dy;

  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i];
    final b = points[i + 1];
    if (t < a.dx || t > b.dx) continue;
    final span = b.dx - a.dx;
    final localT = span <= 0 ? 0.0 : (t - a.dx) / span;
    if (!smooth) return a.dy + (b.dy - a.dy) * localT;

    // cubic Hermite spline with Catmull-Rom-style finite-difference tangents,
    // computed w.r.t. x so uneven point spacing doesn't cause overshoot -
    // falls back to duplicating the endpoint when there's no neighbor.
    final prev = i == 0 ? a : points[i - 1];
    final next = i + 2 >= points.length ? b : points[i + 2];
    final tangentA = (b.dx - prev.dx) <= 0 ? 0.0 : (b.dy - prev.dy) / (b.dx - prev.dx);
    final tangentB = (next.dx - a.dx) <= 0 ? 0.0 : (next.dy - a.dy) / (next.dx - a.dx);

    final t2 = localT * localT;
    final t3 = t2 * localT;
    final h00 = 2 * t3 - 3 * t2 + 1;
    final h10 = t3 - 2 * t2 + localT;
    final h01 = -2 * t3 + 3 * t2;
    final h11 = t3 - t2;
    return h00 * a.dy + h10 * span * tangentA + h01 * b.dy + h11 * span * tangentB;
  }
  return points.last.dy;
}
