import 'package:flutter/material.dart';

enum ParamType { slider, toggle, custom }

// only relevant for ParamType.slider - which OSC numeric type to wire-encode as.
enum NumericKind { float, int }

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
      'default': type == ParamType.toggle ? defaultBool : defaultValue,
    };
  }
}

// the seed color the app launches with before any config/preference is loaded.
const defaultThemeSeedColor = Color(0xFF6750A4);

// a profile is one avatar's set of parameters. avatarId is set when the
// profile was created (or matched) via auto mode; manually-made profiles
// leave it null and just get switched to by hand.
class Profile {
  String id;
  String name;
  String? avatarId;
  final List<ParamControl> parameters;

  Profile({
    required this.id,
    required this.name,
    this.avatarId,
    List<ParamControl>? parameters,
  }) : parameters = parameters ?? [];

  factory Profile.fromJson(Map<String, dynamic> json) {
    final rawParams = (json['parameters'] as List?) ?? const [];
    return Profile(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? 'Profile',
      avatarId: json['avatarId'] as String?,
      parameters: rawParams.cast<Map<String, dynamic>>().map(ParamControl.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (avatarId != null) 'avatarId': avatarId,
      'parameters': parameters.map((p) => p.toJson()).toList(),
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
