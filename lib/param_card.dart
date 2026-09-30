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
              if (showAddress || param.type == ParamType.custom || param.type == ParamType.button)
                Text(
                  switch (param.type) {
                    ParamType.custom => '${oscAddressFor(param)}  ·  ${param.customTypeTag}',
                    ParamType.button =>
                      '${param.buttonMode == ButtonMode.hold ? 'hold' : 'tap'}  ·  ${oscAddressFor(param)}',
                    _ => param.name,
                  },
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
      ParamType.chatbox => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, _chatbox(context)],
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
            padding: EdgeInsets.fromLTRB(
              16,
              dense ? 4 : 8,
              param.type == ParamType.chatbox ? 12 : 4,
              param.type == ParamType.slider ? 0 : (dense ? 4 : 8),
            ),
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
      case ParamType.button:
        return [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _PushButton(param: param, live: live)),
        ];
      case ParamType.chatbox:
        return const [];
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
    // ints snap to whole steps (and floats to their step, if one is set), as
    // long as there aren't so many that the tick marks become a solid bar.
    final step = isInt ? (param.step >= 1 ? param.step.roundToDouble() : 1.0) : param.step;
    final count = step > 0 ? span / step : 0.0;
    final divisions = step > 0 && (count - count.round()).abs() < 1e-6 && count >= 1 && count <= 1000
        ? count.round()
        : null;
    return Slider(
      value: value.clamp(lo, hi),
      min: lo,
      max: hi,
      divisions: divisions,
      label: divisions != null ? formatParamValue(param, value, live.advancedMode) : null,
      onChanged: (v) => live.setSlider(param, v),
      onChangeEnd: (_) => live.releaseSlider(param),
    );
  }

  Widget _chatbox(BuildContext context) {
    final controller = live.customText[param.name];
    Future<void> send() async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await live.sendChatbox(param);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              // VRChat shows at most 144 characters.
              maxLength: 144,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                isDense: true,
                hintText: param.chatboxSendImmediately ? 'Message' : 'Opens the in-game keyboard with this text',
              ),
              onChanged: (text) {
                param.customValueText = text;
                live.chatboxTyping(param, text.isNotEmpty);
              },
              onSubmitted: (_) => send(),
            ),
          ),
          IconButton(icon: const Icon(Icons.send), tooltip: 'Send to chatbox', onPressed: send),
        ],
      ),
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

/// a momentary button - held down while pressed (hold mode), or a short
/// press-and-release pulse per click (tap mode).
class _PushButton extends StatelessWidget {
  final ParamControl param;
  final LiveController live;
  const _PushButton({required this.param, required this.live});

  @override
  Widget build(BuildContext context) {
    final pressed = live.toggleValue(param);
    final scheme = Theme.of(context).colorScheme;
    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 80),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: pressed ? scheme.primary : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        param.buttonMode == ButtonMode.hold ? 'Hold' : 'Press',
        style: TextStyle(
          color: pressed ? scheme.onPrimary : scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (param.buttonMode == ButtonMode.tap) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: () => live.tapButton(param), child: button),
      );
    }
    // raw pointer events, so it stays down for exactly as long as it's held
    // (a gesture detector would wait to decide between tap and drag).
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        onPointerDown: (_) => live.pressButton(param, true),
        onPointerUp: (_) => live.pressButton(param, false),
        onPointerCancel: (_) => live.pressButton(param, false),
        child: button,
      ),
    );
  }
}
