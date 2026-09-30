import 'package:flutter/material.dart';

import 'live_controller.dart';
import 'param_control.dart';
import 'param_form_dialog.dart' show oscTypeHasNoValue;

/// one parameter's live control (slider, toggle, or custom send box) -
/// shared by the main screen and the sequence editor so both look and
/// behave identically. [onMenu] opens the per-parameter actions.
class ParamCard extends StatelessWidget {
  final ParamControl param;
  final LiveController live;
  final Widget? automationButton;
  final void Function(Offset globalPosition)? onMenu;
  final bool dense;

  const ParamCard({
    super.key,
    required this.param,
    required this.live,
    this.automationButton,
    this.onMenu,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showAddress = param.label != param.name && param.label != param.name.split('/').last;

    final header = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(param.label, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
              if (showAddress || param.type == ParamType.custom)
                Text(
                  param.type == ParamType.custom
                      ? '${oscAddressFor(param)}  ·  ${param.customTypeTag}'
                      : param.name,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        ?automationButton,
        ..._trailing(context),
        if (onMenu != null)
          Builder(
            builder: (buttonContext) => IconButton(
              icon: const Icon(Icons.more_vert),
              tooltip: 'More',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                final box = buttonContext.findRenderObject() as RenderBox;
                onMenu!(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
              },
            ),
          ),
      ],
    );

    final body = switch (param.type) {
      ParamType.slider => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, _slider(context)],
        ),
      _ => header,
    };

    // right-click or the ⋮ button - no long-press, which would fire when
    // someone just holds a slider thumb for a moment before dragging.
    return GestureDetector(
      onSecondaryTapDown: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          // the whole card flips a toggle, not just the little switch.
          onTap: param.type == ParamType.toggle ? () => live.setToggle(param, !live.toggleValue(param)) : null,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, dense ? 4 : 8, 4, param.type == ParamType.slider ? 0 : (dense ? 4 : 8)),
            child: body,
          ),
        ),
      ),
    );
  }

  List<Widget> _trailing(BuildContext context) {
    switch (param.type) {
      case ParamType.toggle:
        return [Switch(value: live.toggleValue(param), onChanged: (v) => live.setToggle(param, v))];
      case ParamType.slider:
        return [
          SizedBox(
            width: 84,
            child: TextField(
              controller: live.sliderText[param.name],
              textAlign: TextAlign.end,
              keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: const InputDecoration(isDense: true),
              onSubmitted: (text) => live.submitSliderText(param, text),
              // leaving the box commits too, same as Enter.
              onTapOutside: (_) {
                final controller = live.sliderText[param.name];
                if (controller != null) {
                  final shown = formatParamValue(param, live.sliderValue(param), live.advancedMode);
                  if (controller.text != shown) live.submitSliderText(param, controller.text);
                }
                FocusManager.instance.primaryFocus?.unfocus();
              },
            ),
          ),
        ];
      case ParamType.custom:
        return [
          // True/False/Nil/Infinitum carry no value - just the send button.
          if (!oscTypeHasNoValue(param.customTypeTag))
            SizedBox(
              width: 140,
              child: TextField(
                controller: live.customText[param.name],
                decoration: const InputDecoration(isDense: true),
                onSubmitted: (_) => _sendCustom(context),
              ),
            ),
          IconButton(icon: const Icon(Icons.send), tooltip: 'Send', onPressed: () => _sendCustom(context)),
        ];
    }
  }

  Widget _slider(BuildContext context) {
    final (lo, hi) = param.safeRange;
    final value = live.sliderValue(param);
    final isInt = param.numericKind == NumericKind.int;
    final span = hi - lo;
    // ints snap to whole steps, as long as there aren't so many that the
    // tick marks become a solid bar.
    final divisions = isInt && span == span.roundToDouble() && span >= 1 && span <= 1000 ? span.round() : null;
    return Slider(
      value: value.clamp(lo, hi),
      min: lo,
      max: hi,
      divisions: divisions,
      label: divisions != null ? value.round().toString() : null,
      onChanged: (v) => live.setSlider(param, v),
    );
  }

  Future<void> _sendCustom(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await live.sendCustom(param);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Send failed: $e')));
    }
  }
}
