import 'package:flutter/material.dart';

import 'param_control.dart';

class ThemeSettings {
  final Color seed;
  final Color? primary;
  final Color? secondary;
  final Color? tertiary;
  final Color? error;

  const ThemeSettings({
    required this.seed,
    this.primary,
    this.secondary,
    this.tertiary,
    this.error,
  });

  factory ThemeSettings.fromConfig(AppConfig config) {
    return ThemeSettings(
      seed: config.themeSeedColor,
      primary: config.primaryOverride,
      secondary: config.secondaryOverride,
      tertiary: config.tertiaryOverride,
      error: config.errorOverride,
    );
  }

  ColorScheme buildScheme() {
    final base = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
    return base.copyWith(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      error: error,
    );
  }
}

// shared across the app so Settings can retheme the running MaterialApp live.
final ValueNotifier<ThemeSettings> themeSettingsNotifier =
    ValueNotifier(const ThemeSettings(seed: defaultThemeSeedColor));
