import 'dart:math';

import 'package:flutter/material.dart';

// button: momentary - pressed while held (or for a short tap), released
// after. chatbox: VRChat's /chatbox/input text box.
enum ParamType { slider, toggle, custom, button, chatbox }

// a button either stays pressed for as long as it's held, or sends a short
// press-and-release pulse per click.
enum ButtonMode { hold, tap }

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

  // null = purely manual (the Enabled switch is the only control).
  ParamTrigger? trigger;

  // sequence-scoped automations only - delays this automation's start by N
  // seconds after the sequence begins, so several can be staggered instead
  // of starting in lockstep. ignored for a parameter's own global automation.
  double startDelaySeconds;

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
    this.trigger,
    this.startDelaySeconds = 0.0,
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
      customCurvePoints: _parseCurvePoints(json['customCurvePoints']),
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
      trigger: (json['trigger'] as Map<String, dynamic>?) == null
          ? null
          : ParamTrigger.fromJson(json['trigger'] as Map<String, dynamic>),
      startDelaySeconds: (json['startDelaySeconds'] as num?)?.toDouble() ?? 0.0,
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
      'startDelaySeconds': startDelaySeconds,
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
      if (trigger != null) 'trigger': trigger!.toJson(),
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

  // timeOfDay - fires once per day at this clock time, on these weekdays
  // (DateTime.monday..sunday; empty = every day).
  int timeOfDayHour;
  int timeOfDayMinute;
  List<int> daysOfWeek;

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
    List<int>? daysOfWeek,
    this.intervalSeconds = 1800,
    this.idleSeconds = 300,
    this.countdownSeconds = 60,
    this.targetValue = 1.0,
    this.targetBool = true,
    this.revertAfterSeconds = 0,
  }) : daysOfWeek = daysOfWeek ?? [];

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
      daysOfWeek: ((json['daysOfWeek'] as List?) ?? const [])
          .whereType<num>()
          .map((d) => d.toInt())
          .where((d) => d >= 1 && d <= 7)
          .toSet()
          .toList()
        ..sort(),
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
      if (daysOfWeek.isNotEmpty) 'daysOfWeek': daysOfWeek,
      'intervalSeconds': intervalSeconds,
      'idleSeconds': idleSeconds,
      'countdownSeconds': countdownSeconds,
      'targetValue': targetValue,
      'targetBool': targetBool,
      'revertAfterSeconds': revertAfterSeconds,
    };
  }
}

// turnsOn/turnsOff fire once on that transition; whileOn/whileOff gate the
// target's enabled state to continuously match the watched toggle.
enum ToggleTriggerCondition { turnsOn, turnsOff, whileOn, whileOff }

// above/below/inRange/outOfRange gate continuously; crossesAbove/crossesBelow
// fire once at the crossing instant.
enum RangeTriggerCondition { above, below, crossesAbove, crossesBelow, inRange, outOfRange }

// starts (or, for gate conditions, continuously holds) an Automation or
// AutomationSequence based on another parameter's live value, instead of
// only being switched on by hand.
class ParamTrigger {
  bool enabled;
  String watchedParamName;

  // used when the watched parameter is a toggle.
  ToggleTriggerCondition toggleCondition;

  // used when the watched parameter is a slider.
  RangeTriggerCondition rangeCondition;
  double threshold;
  double rangeMin;
  double rangeMax;

  // "fires once" pulse conditions only - fires every Nth pulse rather than
  // every one (1 = every pulse). gate conditions ignore this entirely.
  int requiredHits;

  ParamTrigger({
    this.enabled = false,
    this.watchedParamName = '',
    this.toggleCondition = ToggleTriggerCondition.turnsOn,
    this.rangeCondition = RangeTriggerCondition.above,
    this.threshold = 0.5,
    this.rangeMin = 0.25,
    this.rangeMax = 0.75,
    this.requiredHits = 1,
  });

  factory ParamTrigger.fromJson(Map<String, dynamic> json) {
    return ParamTrigger(
      enabled: (json['enabled'] as bool?) ?? false,
      watchedParamName: (json['watchedParamName'] as String?) ?? '',
      toggleCondition: switch (json['toggleCondition'] as String?) {
        'turnsOff' => ToggleTriggerCondition.turnsOff,
        'whileOn' => ToggleTriggerCondition.whileOn,
        'whileOff' => ToggleTriggerCondition.whileOff,
        _ => ToggleTriggerCondition.turnsOn,
      },
      rangeCondition: switch (json['rangeCondition'] as String?) {
        'below' => RangeTriggerCondition.below,
        'crossesAbove' => RangeTriggerCondition.crossesAbove,
        'crossesBelow' => RangeTriggerCondition.crossesBelow,
        'inRange' => RangeTriggerCondition.inRange,
        'outOfRange' => RangeTriggerCondition.outOfRange,
        _ => RangeTriggerCondition.above,
      },
      threshold: (json['threshold'] as num?)?.toDouble() ?? 0.5,
      rangeMin: (json['rangeMin'] as num?)?.toDouble() ?? 0.25,
      rangeMax: (json['rangeMax'] as num?)?.toDouble() ?? 0.75,
      requiredHits: (json['requiredHits'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'watchedParamName': watchedParamName,
      'toggleCondition': switch (toggleCondition) {
        ToggleTriggerCondition.turnsOn => 'turnsOn',
        ToggleTriggerCondition.turnsOff => 'turnsOff',
        ToggleTriggerCondition.whileOn => 'whileOn',
        ToggleTriggerCondition.whileOff => 'whileOff',
      },
      'rangeCondition': switch (rangeCondition) {
        RangeTriggerCondition.above => 'above',
        RangeTriggerCondition.below => 'below',
        RangeTriggerCondition.crossesAbove => 'crossesAbove',
        RangeTriggerCondition.crossesBelow => 'crossesBelow',
        RangeTriggerCondition.inRange => 'inRange',
        RangeTriggerCondition.outOfRange => 'outOfRange',
      },
      'threshold': threshold,
      'rangeMin': rangeMin,
      'rangeMax': rangeMax,
      'requiredHits': requiredHits,
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

  // slider extras: snap to multiples of [step] (0 = continuous), and jump
  // back to [defaultValue] when released - for VRChat's /input axes, which
  // keep moving you until they're reset to 0.
  double step;
  bool springBack;

  // custom fields - a free-typed OSC type tag (e.g. "f","i","d","s","T","F")
  // and its value as text, for types this app has no dedicated widget for.
  // chatbox params keep their draft message in customValueText too.
  String customTypeTag;
  String customValueText;

  // button fields. VRChat's /input buttons want an int 1/0, avatar bool
  // parameters want true/false.
  ButtonMode buttonMode;
  bool buttonSendsInt;
  int tapMillis;

  // chatbox fields - see VRChat's /chatbox/input s b n.
  bool chatboxSendImmediately;
  bool chatboxNotify;
  bool chatboxTypingIndicator;

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
    this.step = 0,
    this.springBack = false,
    this.customTypeTag = 'f',
    this.customValueText = '0',
    this.buttonMode = ButtonMode.hold,
    this.buttonSendsInt = true,
    this.tapMillis = 100,
    this.chatboxSendImmediately = true,
    this.chatboxNotify = true,
    this.chatboxTypingIndicator = true,
    this.automation,
    this.schedule,
  });

  /// what a trigger, sequence or snapshot sees this parameter as - buttons
  /// behave like toggles (pressed/released), chatboxes have no value.
  bool get isBoolLike => type == ParamType.toggle || type == ParamType.button;

  /// sliders and toggles can carry an automation/schedule.
  bool get isAutomatable => type == ParamType.slider || type == ParamType.toggle;

  factory ParamControl.fromJson(Map<String, dynamic> json) {
    final name = '${json['name'] ?? ''}';
    final typeStr = json['type'] as String?;
    final type = switch (typeStr) {
      'toggle' => ParamType.toggle,
      'custom' => ParamType.custom,
      'button' => ParamType.button,
      'chatbox' => ParamType.chatbox,
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
      step: ((json['step'] as num?)?.toDouble() ?? 0).abs(),
      springBack: (json['springBack'] as bool?) ?? false,
      customTypeTag: (json['customTypeTag'] as String?) ?? 'f',
      customValueText: (json['customValueText'] as String?) ?? (type == ParamType.chatbox ? '' : '0'),
      buttonMode: (json['buttonMode'] as String?) == 'tap' ? ButtonMode.tap : ButtonMode.hold,
      buttonSendsInt: (json['buttonSendsInt'] as bool?) ?? true,
      tapMillis: ((json['tapMillis'] as num?)?.toInt() ?? 100).clamp(10, 10000),
      chatboxSendImmediately: (json['chatboxSendImmediately'] as bool?) ?? true,
      chatboxNotify: (json['chatboxNotify'] as bool?) ?? true,
      chatboxTypingIndicator: (json['chatboxTypingIndicator'] as bool?) ?? true,
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
        ParamType.button => 'button',
        ParamType.chatbox => 'chatbox',
      },
      if (category != null) 'category': category,
      if (type == ParamType.slider) 'min': min,
      if (type == ParamType.slider) 'max': max,
      if (type == ParamType.slider) 'numericKind': numericKind == NumericKind.int ? 'int' : 'float',
      if (type == ParamType.slider && step > 0) 'step': step,
      if (type == ParamType.slider && springBack) 'springBack': true,
      if (type == ParamType.custom) 'customTypeTag': customTypeTag,
      if (type == ParamType.custom || type == ParamType.chatbox) 'customValueText': customValueText,
      if (type == ParamType.button) 'buttonMode': buttonMode == ButtonMode.tap ? 'tap' : 'hold',
      if (type == ParamType.button) 'buttonSendsInt': buttonSendsInt,
      if (type == ParamType.button) 'tapMillis': tapMillis,
      if (type == ParamType.chatbox) 'chatboxSendImmediately': chatboxSendImmediately,
      if (type == ParamType.chatbox) 'chatboxNotify': chatboxNotify,
      if (type == ParamType.chatbox) 'chatboxTypingIndicator': chatboxTypingIndicator,
      if (automation != null) 'automation': automation!.toJson(),
      if (schedule != null) 'schedule': schedule!.toJson(),
      'default': type == ParamType.toggle ? defaultBool : defaultValue,
    };
  }

  /// a fully independent deep copy (automation curves etc. included).
  ParamControl copy() => ParamControl.fromJson(toJson());

  /// the slider's range, safe to hand to a Slider widget - a hand-edited
  /// config with min >= max (or NaN) would otherwise throw during layout.
  (double, double) get safeRange {
    final lo = min.isFinite ? min : 0.0;
    final hi = max.isFinite ? max : 1.0;
    if (hi > lo) return (lo, hi);
    if (hi < lo) return (hi, lo);
    return (lo, lo + 1);
  }
}

// the seed color the app launches with before any config/preference is loaded.
const defaultThemeSeedColor = Color(0xFF6750A4);

// simple mode shows 3 decimal places (e.g. "1.234"); advanced mode shows full
// precision. either way this only affects the textbox display - the value
// actually stored/sent over OSC always keeps full precision.
String formatParamNumber(double v, bool advanced) {
  if (!v.isFinite) return v.toString();
  if (advanced) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }
  return v.toStringAsFixed(3);
}

/// like [formatParamNumber], but int parameters show as whole numbers -
/// that's what actually gets sent for them.
String formatParamValue(ParamControl param, double v, bool advanced) {
  if (param.type == ParamType.slider && param.numericKind == NumericKind.int && v.isFinite) {
    return v.round().toString();
  }
  return formatParamNumber(v, advanced);
}

/// the live value map holds a double for sliders and a bool for toggles,
/// but a parameter's type can change underneath it (edited, or a config
/// reload) - these never throw on a stale entry of the wrong type.
double sliderValueOf(Map<String, Object> values, ParamControl param) {
  final v = values[param.name];
  if (v is double && v.isFinite) return v;
  if (v is num && v.isFinite) return v.toDouble();
  return param.defaultValue;
}

bool toggleValueOf(Map<String, Object> values, ParamControl param) {
  final v = values[param.name];
  return v is bool ? v : param.defaultBool;
}

/// unique enough for profile/sequence ids - a bare millisecond timestamp
/// could collide when two get created in the same instant.
String newId() {
  final rand = Random();
  return '${DateTime.now().millisecondsSinceEpoch}-${rand.nextInt(1 << 30).toRadixString(36)}';
}

List<Offset>? _parseCurvePoints(Object? raw) {
  if (raw is! List) return null;
  final points = <Offset>[];
  for (final e in raw) {
    if (e is List && e.length >= 2 && e[0] is num && e[1] is num) {
      points.add(Offset((e[0] as num).toDouble(), (e[1] as num).toDouble()));
    }
  }
  return points.length >= 2 ? points : null;
}

/// a number typed by a person - trims, accepts a decimal comma ("0,5"), and
/// rejects NaN/Infinity (which double.tryParse happily accepts).
double? parseUserDouble(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', '.'));
  return v != null && v.isFinite ? v : null;
}

/// typing the full "/avatar/parameters/Foo" is the same parameter as "Foo" -
/// normalized so both spellings match discovery, triggers and live sync.
String normalizeParamName(String raw) {
  final trimmed = raw.trim();
  const root = '/avatar/parameters/';
  if (trimmed.startsWith(root) && trimmed.length > root.length) return trimmed.substring(root.length);
  return trimmed;
}

/// null if [name] is usable as a parameter name / OSC address, otherwise
/// why not.
String? validateParamName(String name) {
  if (name.isEmpty) return 'Enter an OSC address';
  if (name == '/') return 'That\'s not a full address';
  if (name.endsWith('/')) return 'An address can\'t end with "/"';
  if (name.contains('//')) return 'An address can\'t contain an empty "//" segment';
  if (RegExp(r'[#*,?\[\]{}]').hasMatch(name)) {
    return 'OSC addresses can\'t contain any of # * , ? [ ] { }';
  }
  return null;
}

// most parameter names are a bare suffix under VRChat's avatar-parameters
// root; typing a full path starting with "/" sends to that address exactly,
// unrestricted.
String oscAddressFor(ParamControl param) =>
    param.name.startsWith('/') ? param.name : '/avatar/parameters/${param.name}';

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
  // chatbox targets: the message this step sends.
  String text;

  SequenceStep({
    required this.kind,
    this.paramName = '',
    this.targetValue = 0.0,
    this.targetBool = false,
    this.durationSeconds = 1.0,
    this.text = '',
  });

  factory SequenceStep.fromJson(Map<String, dynamic> json) {
    return SequenceStep(
      kind: (json['kind'] as String?) == 'wait' ? SequenceStepKind.wait : SequenceStepKind.setValue,
      paramName: (json['paramName'] as String?) ?? '',
      targetValue: (json['targetValue'] as num?)?.toDouble() ?? 0.0,
      targetBool: (json['targetBool'] as bool?) ?? false,
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble() ?? 1.0,
      text: (json['text'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'kind': kind == SequenceStepKind.wait ? 'wait' : 'setValue',
      'paramName': paramName,
      'targetValue': targetValue,
      'targetBool': targetBool,
      'durationSeconds': durationSeconds,
      if (text.isNotEmpty) 'text': text,
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
  // null = purely manual (the Running switch is the only control).
  ParamTrigger? trigger;
  // per-parameter automations owned by this sequence, not the parameter -
  // separate from that parameter's own (global) automation, so configuring
  // one here never touches or enables the other. runs continuously for as
  // long as this sequence is enabled/running, keyed by parameter name.
  Map<String, Automation> paramAutomations;

  AutomationSequence({
    required this.id,
    required this.name,
    this.enabled = false,
    this.repeatMode = SequenceRepeatMode.once,
    this.repeatCount = 0,
    List<SequenceStep>? steps,
    this.trigger,
    Map<String, Automation>? paramAutomations,
  })  : steps = steps ?? [],
        paramAutomations = paramAutomations ?? {};

  factory AutomationSequence.fromJson(Map<String, dynamic> json) {
    final rawSteps = (json['steps'] as List?) ?? const [];
    final rawParamAutomations = json['paramAutomations'] as Map<String, dynamic>?;
    return AutomationSequence(
      id: (json['id'] as String?) ?? newId(),
      name: (json['name'] as String?) ?? 'Sequence',
      enabled: (json['enabled'] as bool?) ?? false,
      repeatMode: (json['repeatMode'] as String?) == 'loop' ? SequenceRepeatMode.loop : SequenceRepeatMode.once,
      repeatCount: (json['repeatCount'] as num?)?.toInt() ?? 0,
      steps: rawSteps.whereType<Map<String, dynamic>>().map(SequenceStep.fromJson).toList(),
      trigger: (json['trigger'] as Map<String, dynamic>?) == null
          ? null
          : ParamTrigger.fromJson(json['trigger'] as Map<String, dynamic>),
      paramAutomations: {
        for (final entry in (rawParamAutomations ?? const <String, dynamic>{}).entries)
          if (entry.value is Map<String, dynamic>) entry.key: Automation.fromJson(entry.value as Map<String, dynamic>),
      },
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
      if (trigger != null) 'trigger': trigger!.toJson(),
      if (paramAutomations.isNotEmpty)
        'paramAutomations': paramAutomations.map((k, v) => MapEntry(k, v.toJson())),
    };
  }
}

/// true if [seq] is actually driving [paramName] right now via its
/// paramAutomations override - enabled sequence, entry itself enabled (not
/// paused), and not superseded by that sequence's own step script targeting
/// the same parameter. shared by the main screen's automation button and the
/// master switch so both agree on the same definition.
bool sequenceActivelyDrivesParam(AutomationSequence seq, String paramName) {
  if (!seq.enabled) return false;
  final entry = seq.paramAutomations[paramName];
  if (entry == null || !entry.enabled) return false;
  return !seq.steps.any((s) => s.kind == SequenceStepKind.setValue && s.paramName == paramName);
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
  // a static "Save Parameters" snapshot rather than a regular avatar
  // profile - never picked/created by auto mode, never touched by live
  // parameter reconciliation, and not selectable as the active profile;
  // only manual edits (or its Apply button, which pushes its saved values
  // onto the currently active profile) can change anything through it.
  bool isSnapshot;

  Profile({
    required this.id,
    required this.name,
    this.avatarId,
    List<ParamControl>? parameters,
    List<AutomationSequence>? sequences,
    this.isSnapshot = false,
  })  : parameters = parameters ?? [],
        sequences = sequences ?? [];

  factory Profile.fromJson(Map<String, dynamic> json) {
    final rawParams = (json['parameters'] as List?) ?? const [];
    final rawSequences = (json['sequences'] as List?) ?? const [];
    return Profile(
      id: (json['id'] as String?) ?? newId(),
      name: (json['name'] as String?) ?? 'Profile',
      avatarId: json['avatarId'] as String?,
      parameters: rawParams
          .whereType<Map<String, dynamic>>()
          .map(ParamControl.fromJson)
          .where((p) => p.name.isNotEmpty)
          .toList(),
      sequences: rawSequences.whereType<Map<String, dynamic>>().map(AutomationSequence.fromJson).toList(),
      isSnapshot: (json['isSnapshot'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (avatarId != null) 'avatarId': avatarId,
      'parameters': parameters.map((p) => p.toJson()).toList(),
      'sequences': sequences.map((s) => s.toJson()).toList(),
      if (isSnapshot) 'isSnapshot': true,
    };
  }

  ParamControl? param(String name) {
    for (final p in parameters) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// follows a parameter rename through everything in this profile that
  /// refers to it by name - sequence steps, per-sequence automations, and
  /// triggers - instead of silently orphaning them.
  void renameParamReferences(String oldName, String newName) {
    if (oldName == newName) return;
    for (final p in parameters) {
      final trig = p.automation?.trigger;
      if (trig != null && trig.watchedParamName == oldName) trig.watchedParamName = newName;
    }
    for (final seq in sequences) {
      for (final step in seq.steps) {
        if (step.paramName == oldName) step.paramName = newName;
      }
      final auto = seq.paramAutomations.remove(oldName);
      if (auto != null) seq.paramAutomations[newName] = auto;
      if (seq.trigger?.watchedParamName == oldName) seq.trigger!.watchedParamName = newName;
    }
  }
}

class AppConfig {
  String host;
  int port;
  Color themeSeedColor;
  bool autoProfileMode;

  // a standalone bottom-of-settings toggle rather than a "hidden feature" -
  // meant to grow more sub-features over time (currently: full-precision
  // slider display, and treating any OSCQuery service as usable for
  // discovery/fetch instead of requiring one that self-identifies as VRChat).
  bool developerMode;
  bool developerModeWarningDismissed;
  // the switch itself stays hidden until unlocked by tapping the version
  // number 5 times - once true, stays true until config.json is wiped.
  bool developerModeUnlocked;

  // hidden-by-default features - off unless explicitly unlocked in Settings.
  bool showAutomationMasterSwitch;
  // true = every automated parameter; false = only automationMasterSwitchParams.
  bool automationMasterSwitchAll;
  List<String> automationMasterSwitchParams;

  // discover popup's "highlight active parameters" listener stops promoting
  // a parameter to the top once it's changed this many times within one
  // second - keeps constantly-firing animator/tracking params from
  // permanently burying anything else. Settings > Miscellaneous.
  int liveParamNoiseThreshold;

  // mirror parameter changes VRChat reports (radial menu, contacts,
  // physbones...) onto the dashboard, so it shows what the avatar is really
  // doing and triggers can react to in-game changes.
  bool syncFromVrchat;

  // Auto Mode: also make a new profile the first time an avatar is seen
  // (false = only switch between profiles that are already linked).
  bool autoProfileCreate;

  // the classic fixed listen port, used only as a fallback for OSC apps
  // without OSCQuery. null = send port + 1 (VRChat's 9000/9001 pairing).
  int? listenPort;

  // extra destinations: VRChat's output relayed on to other apps, and/or
  // this app's own sends mirrored to them.
  final List<ForwardTarget> forwardTargets;

  // the first-launch tour. configs from before it existed count as seen,
  // so it only pops up for new users (Settings can replay it).
  bool tutorialSeen;

  // Android: stop the screen sleeping while the app is open.
  bool keepScreenOn;

  // updates: check on launch, offer pre-releases, and a version the user
  // chose to skip (only silences the launch check).
  bool checkUpdatesOnStartup;
  bool includePrereleaseUpdates;
  String? skippedUpdateVersion;

  // how long to wait on VRChat's OSCQuery server before falling back to
  // something else - it's been observed to hang outright for some avatars.
  // Settings > Miscellaneous, developer mode only.
  int oscQueryFetchTimeoutSeconds;

  final List<Profile> profiles;
  String activeProfileId;

  // per-role overrides layered on top of ColorScheme.fromSeed(themeSeedColor).
  // null means "keep the auto-generated tone for this role".
  Color? primaryOverride;
  Color? secondaryOverride;
  Color? tertiaryOverride;
  Color? errorOverride;

  // full-precision slider display is entirely a developer-mode effect now -
  // no separate switch or persisted state for it.
  bool get advancedMode => developerMode;

  AppConfig({
    required this.host,
    required this.port,
    List<ParamControl>? parameters,
    List<Profile>? profiles,
    String? activeProfileId,
    this.themeSeedColor = defaultThemeSeedColor,
    this.autoProfileMode = false,
    this.developerMode = false,
    this.developerModeWarningDismissed = false,
    this.developerModeUnlocked = false,
    this.showAutomationMasterSwitch = false,
    this.automationMasterSwitchAll = true,
    List<String>? automationMasterSwitchParams,
    this.liveParamNoiseThreshold = 10,
    this.syncFromVrchat = true,
    this.autoProfileCreate = true,
    this.listenPort,
    List<ForwardTarget>? forwardTargets,
    this.tutorialSeen = true,
    this.keepScreenOn = false,
    this.checkUpdatesOnStartup = true,
    this.includePrereleaseUpdates = false,
    this.skippedUpdateVersion,
    this.oscQueryFetchTimeoutSeconds = 5,
    this.primaryOverride,
    this.secondaryOverride,
    this.tertiaryOverride,
    this.errorOverride,
  })  : profiles = profiles ?? [Profile(id: 'default', name: 'Default', parameters: parameters ?? [])],
        activeProfileId = activeProfileId ??
            (profiles != null && profiles.isNotEmpty ? profiles.first.id : 'default'),
        automationMasterSwitchParams = automationMasterSwitchParams ?? [],
        forwardTargets = forwardTargets ?? [] {
    sanitize();
  }

  /// keeps the invariants the rest of the app relies on: at least one
  /// regular (non-snapshot) profile, the active id pointing at one, and no
  /// two profiles sharing an id. cheap - call after any bulk change.
  void sanitize() {
    if (!profiles.any((p) => !p.isSnapshot)) {
      profiles.insert(0, Profile(id: newId(), name: 'Default'));
    }
    final seen = <String>{};
    for (final p in profiles) {
      if (!seen.add(p.id)) p.id = newId();
      seen.add(p.id);
    }
    final active = profiles.where((p) => p.id == activeProfileId && !p.isSnapshot);
    if (active.isEmpty) activeProfileId = profiles.firstWhere((p) => !p.isSnapshot).id;
  }

  Profile get activeProfile => profiles.firstWhere(
        (p) => p.id == activeProfileId && !p.isSnapshot,
        orElse: () => profiles.firstWhere((p) => !p.isSnapshot, orElse: () => profiles.first),
      );

  /// renames a parameter in the active profile and everything that refers
  /// to it (see [Profile.renameParamReferences]).
  void renameParamReferences(String oldName, String newName) {
    activeProfile.renameParamReferences(oldName, newName);
    final i = automationMasterSwitchParams.indexOf(oldName);
    if (i != -1) automationMasterSwitchParams[i] = newName;
  }

  // most of the app just reads/mutates "the current parameters" - proxy
  // straight through to whichever profile is active so that code doesn't
  // need to know profiles exist.
  List<ParamControl> get parameters => activeProfile.parameters;
  List<AutomationSequence> get sequences => activeProfile.sequences;

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    List<Profile> profiles;
    String activeProfileId;

    final rawProfiles = json['profiles'] as List?;
    if (rawProfiles != null && rawProfiles.whereType<Map<String, dynamic>>().isNotEmpty) {
      profiles = rawProfiles.whereType<Map<String, dynamic>>().map(Profile.fromJson).toList();
      activeProfileId = (json['activeProfileId'] as String?) ?? profiles.first.id;
    } else {
      // migrate a pre-profiles config's flat "parameters" list into a single profile.
      final legacyParams = ((json['parameters'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ParamControl.fromJson)
          .where((p) => p.name.isNotEmpty)
          .toList();
      profiles = [Profile(id: 'default', name: 'Default', parameters: legacyParams)];
      activeProfileId = 'default';
    }

    return AppConfig(
      host: _nonEmpty(json['host'] as String?) ?? '127.0.0.1',
      port: _validPort((json['port'] as num?)?.toInt()) ?? 9000,
      profiles: profiles,
      activeProfileId: activeProfileId,
      themeSeedColor: colorFromHex(json['themeColor'] as String?) ?? defaultThemeSeedColor,
      // off by default for anyone upgrading from a pre-auto-mode config, and
      // off on a brand new config too - this is an explicit opt-in feature
      // since it passively listens for which avatar you're wearing.
      autoProfileMode: (json['autoProfileMode'] as bool?) ?? false,
      // migrates a pre-developer-mode config's standalone "advancedMode" flag
      // so upgrading doesn't silently change the slider display precision -
      // also unlocking the switch itself, so it isn't left on but invisible.
      developerMode: (json['developerMode'] as bool?) ?? (json['advancedMode'] as bool?) ?? false,
      developerModeWarningDismissed: (json['developerModeWarningDismissed'] as bool?) ?? false,
      developerModeUnlocked:
          (json['developerModeUnlocked'] as bool?) ?? (json['advancedMode'] as bool?) ?? false,
      showAutomationMasterSwitch: (json['showAutomationMasterSwitch'] as bool?) ?? false,
      automationMasterSwitchAll: (json['automationMasterSwitchAll'] as bool?) ?? true,
      automationMasterSwitchParams:
          ((json['automationMasterSwitchParams'] as List?) ?? const []).whereType<String>().toList(),
      liveParamNoiseThreshold: (json['liveParamNoiseThreshold'] as num?)?.toInt() ?? 10,
      syncFromVrchat: (json['syncFromVrchat'] as bool?) ?? true,
      autoProfileCreate: (json['autoProfileCreate'] as bool?) ?? true,
      listenPort: _validPort((json['listenPort'] as num?)?.toInt()),
      forwardTargets: ((json['forwardTargets'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ForwardTarget.fromJson)
          .whereType<ForwardTarget>()
          .toList(),
      tutorialSeen: (json['tutorialSeen'] as bool?) ?? true,
      keepScreenOn: (json['keepScreenOn'] as bool?) ?? false,
      checkUpdatesOnStartup: (json['checkUpdatesOnStartup'] as bool?) ?? true,
      includePrereleaseUpdates: (json['includePrereleaseUpdates'] as bool?) ?? false,
      skippedUpdateVersion: _nonEmpty(json['skippedUpdateVersion'] as String?),
      oscQueryFetchTimeoutSeconds: (json['oscQueryFetchTimeoutSeconds'] as num?)?.toInt() ?? 5,
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
      'autoProfileMode': autoProfileMode,
      'developerMode': developerMode,
      'developerModeWarningDismissed': developerModeWarningDismissed,
      'developerModeUnlocked': developerModeUnlocked,
      'showAutomationMasterSwitch': showAutomationMasterSwitch,
      'automationMasterSwitchAll': automationMasterSwitchAll,
      'automationMasterSwitchParams': automationMasterSwitchParams,
      'liveParamNoiseThreshold': liveParamNoiseThreshold,
      'syncFromVrchat': syncFromVrchat,
      'autoProfileCreate': autoProfileCreate,
      if (listenPort != null) 'listenPort': listenPort,
      if (forwardTargets.isNotEmpty) 'forwardTargets': forwardTargets.map((t) => t.toJson()).toList(),
      'tutorialSeen': tutorialSeen,
      'keepScreenOn': keepScreenOn,
      'checkUpdatesOnStartup': checkUpdatesOnStartup,
      'includePrereleaseUpdates': includePrereleaseUpdates,
      if (skippedUpdateVersion != null) 'skippedUpdateVersion': skippedUpdateVersion,
      'oscQueryFetchTimeoutSeconds': oscQueryFetchTimeoutSeconds,
      if (primaryOverride != null) 'primaryOverride': colorToHex(primaryOverride!),
      if (secondaryOverride != null) 'secondaryOverride': colorToHex(secondaryOverride!),
      if (tertiaryOverride != null) 'tertiaryOverride': colorToHex(tertiaryOverride!),
      if (errorOverride != null) 'errorOverride': colorToHex(errorOverride!),
      'activeProfileId': activeProfileId,
      'profiles': profiles.map((p) => p.toJson()).toList(),
    };
  }
}

/// the fixed listen port actually in use - see [AppConfig.listenPort].
int effectiveListenPort(AppConfig config) => config.listenPort ?? (config.port >= 65535 ? 9001 : config.port + 1);

/// which way a [ForwardTarget] relays.
enum ForwardDirection { incoming, outgoing, both }

/// another OSC app to relay traffic to - handy for tools that can't use
/// OSCQuery and would otherwise need port 9001 to themselves.
class ForwardTarget {
  String host;
  int port;
  bool enabled;
  ForwardDirection direction;
  String label;

  ForwardTarget({
    required this.host,
    required this.port,
    this.enabled = true,
    this.direction = ForwardDirection.incoming,
    this.label = '',
  });

  bool get relaysIncoming => enabled && direction != ForwardDirection.outgoing;
  bool get mirrorsOutgoing => enabled && direction != ForwardDirection.incoming;

  static ForwardTarget? fromJson(Map<String, dynamic> json) {
    final port = _validPort((json['port'] as num?)?.toInt());
    final host = _nonEmpty(json['host'] as String?);
    if (port == null || host == null) return null;
    return ForwardTarget(
      host: host,
      port: port,
      enabled: (json['enabled'] as bool?) ?? true,
      direction: switch (json['direction'] as String?) {
        'outgoing' => ForwardDirection.outgoing,
        'both' => ForwardDirection.both,
        _ => ForwardDirection.incoming,
      },
      label: (json['label'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'enabled': enabled,
        'direction': direction.name,
        if (label.isNotEmpty) 'label': label,
      };
}

String? _nonEmpty(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

int? _validPort(int? port) => (port != null && port >= 1 && port <= 65535) ? port : null;

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
