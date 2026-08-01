import 'package:flutter/material.dart';

import 'hue_wheel.dart';
import 'param_control.dart';
import 'theme_notifier.dart';

Future<void> showCustomThemeDialog(BuildContext context, AppConfig config) {
  return showDialog(
    context: context,
    builder: (context) => CustomThemeDialog(config: config),
  );
}

class CustomThemeDialog extends StatefulWidget {
  final AppConfig config;
  const CustomThemeDialog({super.key, required this.config});

  @override
  State<CustomThemeDialog> createState() => _CustomThemeDialogState();
}

class _CustomThemeDialogState extends State<CustomThemeDialog> {
  late HSVColor _seed;
  bool _advanced = false;

  bool _primaryCustom = false;
  bool _secondaryCustom = false;
  bool _tertiaryCustom = false;
  bool _errorCustom = false;
  late HSVColor _primary;
  late HSVColor _secondary;
  late HSVColor _tertiary;
  late HSVColor _error;

  // snapshot so Cancel can restore exactly what the theme looked like before opening.
  late final AppConfig _snapshot;

  AppConfig get config => widget.config;

  @override
  void initState() {
    super.initState();
    _snapshot = AppConfig(
      host: config.host,
      port: config.port,
      parameters: const [],
      themeSeedColor: config.themeSeedColor,
      primaryOverride: config.primaryOverride,
      secondaryOverride: config.secondaryOverride,
      tertiaryOverride: config.tertiaryOverride,
      errorOverride: config.errorOverride,
    );

    _seed = HSVColor.fromColor(config.themeSeedColor);
    _primaryCustom = config.primaryOverride != null;
    _secondaryCustom = config.secondaryOverride != null;
    _tertiaryCustom = config.tertiaryOverride != null;
    _errorCustom = config.errorOverride != null;
    _primary = HSVColor.fromColor(config.primaryOverride ?? const Color(0xFF4285F4));
    _secondary = HSVColor.fromColor(config.secondaryOverride ?? const Color(0xFF9AA0A6));
    _tertiary = HSVColor.fromColor(config.tertiaryOverride ?? const Color(0xFFA142F4));
    _error = HSVColor.fromColor(config.errorOverride ?? const Color(0xFFB3261E));
  }

  void _applyLive() {
    config.themeSeedColor = _seed.toColor();
    config.primaryOverride = _primaryCustom ? _primary.toColor() : null;
    config.secondaryOverride = _secondaryCustom ? _secondary.toColor() : null;
    config.tertiaryOverride = _tertiaryCustom ? _tertiary.toColor() : null;
    config.errorOverride = _errorCustom ? _error.toColor() : null;
    themeSettingsNotifier.value = ThemeSettings.fromConfig(config);
  }

  void _cancel() {
    config.themeSeedColor = _snapshot.themeSeedColor;
    config.primaryOverride = _snapshot.primaryOverride;
    config.secondaryOverride = _snapshot.secondaryOverride;
    config.tertiaryOverride = _snapshot.tertiaryOverride;
    config.errorOverride = _snapshot.errorOverride;
    themeSettingsNotifier.value = ThemeSettings.fromConfig(config);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Custom Theme'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Simple')),
                  ButtonSegment(value: true, label: Text('Advanced')),
                ],
                selected: {_advanced},
                onSelectionChanged: (s) => setState(() => _advanced = s.first),
              ),
              const SizedBox(height: 16),
              _advanced ? _buildAdvanced() : _buildSimple(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            _applyLive();
            Navigator.of(context).pop();
          },
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _buildSimple() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: HueWheel(
            hue: _seed.hue,
            saturation: _seed.saturation,
            onChanged: (h, s) => setState(() {
              _seed = _seed.withHue(h).withSaturation(s);
              _applyLive();
            }),
          ),
        ),
        const SizedBox(height: 8),
        _preview(),
      ],
    );
  }

  Widget _buildAdvanced() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _preview(),
        const SizedBox(height: 12),
        _roleEditor('Primary', _primaryCustom, _primary, (c) => setState(() => _primaryCustom = c),
            (h) => setState(() => _primary = h)),
        _roleEditor('Secondary', _secondaryCustom, _secondary, (c) => setState(() => _secondaryCustom = c),
            (h) => setState(() => _secondary = h)),
        _roleEditor('Tertiary', _tertiaryCustom, _tertiary, (c) => setState(() => _tertiaryCustom = c),
            (h) => setState(() => _tertiary = h)),
        _roleEditor('Error', _errorCustom, _error, (c) => setState(() => _errorCustom = c),
            (h) => setState(() => _error = h)),
      ],
    );
  }

  Widget _roleEditor(
    String label,
    bool custom,
    HSVColor value,
    ValueChanged<bool> onCustomChanged,
    ValueChanged<HSVColor> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: Theme.of(context).textTheme.titleMedium)),
            Text(custom ? 'Custom' : 'Auto-generated', style: Theme.of(context).textTheme.bodySmall),
            Switch(
              value: custom,
              onChanged: (v) {
                onCustomChanged(v);
                _applyLive();
              },
            ),
          ],
        ),
        if (custom) ...[
          Center(
            child: HueWheel(
              hue: value.hue,
              saturation: value.saturation,
              size: 140,
              onChanged: (h, s) {
                onChanged(value.withHue(h).withSaturation(s));
                _applyLive();
              },
            ),
          ),
        ],
        const Divider(),
      ],
    );
  }

  Widget _preview() {
    final scheme = ThemeSettings.fromConfig(config).buildScheme();
    return Theme(
      data: Theme.of(context).copyWith(colorScheme: scheme),
      child: Builder(
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(onPressed: () {}, child: const Text('Filled')),
                OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
                Switch(value: true, onChanged: (_) {}),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                  onPressed: () {},
                  child: const Text('Error'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // explicit swatches for every role - some (secondary/tertiary) have
            // no built-in widget above that visibly reacts to them, so this is
            // the only reliable way to see a role's actual current color.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _swatch('Primary', scheme.primaryContainer, scheme.onPrimaryContainer),
                _swatch('Secondary', scheme.secondaryContainer, scheme.onSecondaryContainer),
                _swatch('Tertiary', scheme.tertiaryContainer, scheme.onTertiaryContainer),
                _swatch('Error', scheme.errorContainer, scheme.onErrorContainer),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _swatch(String label, Color background, Color foreground) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(color: foreground, fontSize: 12)),
    );
  }
}
