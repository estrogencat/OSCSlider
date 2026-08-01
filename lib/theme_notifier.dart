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
    var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
    // overriding just the bare role color (e.g. "secondary") left every widget
    // that actually reads the container/on-color roles derived from it (most
    // of them) unaffected - regenerate the whole tonal family for whichever
    // role is customized instead of a single flat swatch.
    if (primary != null) {
      final s = ColorScheme.fromSeed(seedColor: primary!, brightness: Brightness.dark);
      scheme = scheme.copyWith(
        primary: s.primary,
        onPrimary: s.onPrimary,
        primaryContainer: s.primaryContainer,
        onPrimaryContainer: s.onPrimaryContainer,
      );
    }
    if (secondary != null) {
      final s = ColorScheme.fromSeed(seedColor: secondary!, brightness: Brightness.dark);
      scheme = scheme.copyWith(
        secondary: s.secondary,
        onSecondary: s.onSecondary,
        secondaryContainer: s.secondaryContainer,
        onSecondaryContainer: s.onSecondaryContainer,
      );
    }
    if (tertiary != null) {
      final s = ColorScheme.fromSeed(seedColor: tertiary!, brightness: Brightness.dark);
      scheme = scheme.copyWith(
        tertiary: s.tertiary,
        onTertiary: s.onTertiary,
        tertiaryContainer: s.tertiaryContainer,
        onTertiaryContainer: s.onTertiaryContainer,
      );
    }
    if (error != null) {
      final s = ColorScheme.fromSeed(seedColor: error!, brightness: Brightness.dark);
      scheme = scheme.copyWith(
        error: s.error,
        onError: s.onError,
        errorContainer: s.errorContainer,
        onErrorContainer: s.onErrorContainer,
      );
    }
    return scheme;
  }
}

// shared across the app so Settings can retheme the running MaterialApp live.
final ValueNotifier<ThemeSettings> themeSettingsNotifier =
    ValueNotifier(const ThemeSettings(seed: defaultThemeSeedColor));
