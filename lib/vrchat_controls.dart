import 'package:flutter/material.dart';

import 'param_control.dart';

/// a ready-made control for one of VRChat's built-in OSC endpoints (from
/// docs.vrchat.com "OSC as Input Controller" and "OSC Avatar Scaling").
class VrchatControl {
  final String group;
  final String address;
  final String label;
  final String description;
  final ParamControl Function() build;
  const VrchatControl(this.group, this.address, this.label, this.description, this.build);
}

// axes expect -1..1 and must return to 0, or VRChat keeps acting on them.
VrchatControl _axis(String name, String label, String description) => VrchatControl(
      'Movement axes',
      '/input/$name',
      label,
      description,
      () => ParamControl(
        name: '/input/$name',
        label: label,
        type: ParamType.slider,
        category: 'VRChat input',
        min: -1,
        max: 1,
        defaultValue: 0,
        springBack: true,
      ),
    );

// buttons expect an int 1 while pressed and 0 on release.
VrchatControl _button(String group, String name, String label, String description, {bool hold = false}) =>
    VrchatControl(
      group,
      '/input/$name',
      label,
      description,
      () => ParamControl(
        name: '/input/$name',
        label: label,
        type: ParamType.button,
        category: 'VRChat input',
        buttonMode: hold ? ButtonMode.hold : ButtonMode.tap,
        buttonSendsInt: true,
      ),
    );

final vrchatControls = <VrchatControl>[
  VrchatControl(
    'Chatbox',
    '/chatbox/input',
    'Chatbox',
    'Type a message into your chatbox, with the typing bubble while you write',
    () => ParamControl(name: '/chatbox/input', label: 'Chatbox', type: ParamType.chatbox, customValueText: ''),
  ),
  VrchatControl(
    'Avatar',
    '/avatar/eyeheight',
    'Avatar height',
    'Your avatar\'s eye height in meters (VRChat supports 0.1 - 100)',
    () => ParamControl(
      name: '/avatar/eyeheight',
      label: 'Avatar height (m)',
      type: ParamType.slider,
      category: 'VRChat',
      min: 0.1,
      max: 5,
      defaultValue: 1.6,
      step: 0.01,
    ),
  ),
  _axis('Vertical', 'Move forward / back', 'Forward (1) or backward (-1)'),
  _axis('Horizontal', 'Move right / left', 'Right (1) or left (-1)'),
  _axis('LookHorizontal', 'Look left / right', 'Smooth turn on desktop, snap turn in VR with comfort turning'),
  _axis('UseAxisRight', 'Use held item (axis)', 'Use the item in your right hand'),
  _axis('GrabAxisRight', 'Grab (axis)', 'Grab with your right hand'),
  _axis('MoveHoldFB', 'Move held object', 'Push a held object away (1) or pull it closer (-1)'),
  _axis('SpinHoldCwCcw', 'Spin held object', 'Clockwise or counter-clockwise'),
  _axis('SpinHoldUD', 'Tilt held object', 'Spin up or down'),
  _axis('SpinHoldLR', 'Turn held object', 'Spin left or right'),
  _button('Movement buttons', 'MoveForward', 'Move forward', 'Moves while held', hold: true),
  _button('Movement buttons', 'MoveBackward', 'Move backward', 'Moves while held', hold: true),
  _button('Movement buttons', 'MoveLeft', 'Strafe left', 'Moves while held', hold: true),
  _button('Movement buttons', 'MoveRight', 'Strafe right', 'Moves while held', hold: true),
  _button('Movement buttons', 'LookLeft', 'Turn left', 'Turns while held', hold: true),
  _button('Movement buttons', 'LookRight', 'Turn right', 'Turns while held', hold: true),
  _button('Movement buttons', 'Jump', 'Jump', 'If the world allows it'),
  _button('Movement buttons', 'Run', 'Run', 'Walk faster while held, if the world allows it', hold: true),
  _button('Movement buttons', 'ComfortLeft', 'Snap turn left', 'VR only'),
  _button('Movement buttons', 'ComfortRight', 'Snap turn right', 'VR only'),
  _button('Hands', 'UseRight', 'Use (right hand)', 'VR only'),
  _button('Hands', 'GrabRight', 'Grab (right hand)', 'VR only', hold: true),
  _button('Hands', 'DropRight', 'Drop (right hand)', 'VR only'),
  _button('Hands', 'UseLeft', 'Use (left hand)', 'VR only'),
  _button('Hands', 'GrabLeft', 'Grab (left hand)', 'VR only', hold: true),
  _button('Hands', 'DropLeft', 'Drop (left hand)', 'VR only'),
  _button('Menus & voice', 'Voice', 'Voice', 'Toggle mute (or push-to-mute, depending on your settings)'),
  _button('Menus & voice', 'QuickMenuToggleLeft', 'Quick Menu (left)', 'Opens or closes the Quick Menu'),
  _button('Menus & voice', 'QuickMenuToggleRight', 'Quick Menu (right)', 'Opens or closes the Quick Menu'),
  _button('Menus & voice', 'PanicButton', 'Safe Mode', 'Turns on Safe Mode'),
];

/// a picker for [vrchatControls]; returns a fresh control, or null.
Future<ParamControl?> showVrchatControlPicker(BuildContext context, {Set<String> takenNames = const {}}) {
  return showDialog<ParamControl>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final groups = <String, List<VrchatControl>>{};
      for (final c in vrchatControls) {
        groups.putIfAbsent(c.group, () => []).add(c);
      }
      return AlertDialog(
        title: const Text('VRChat controls'),
        contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        content: SizedBox(
          width: 440,
          height: 520,
          child: ListView(
            children: [
              for (final entry in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(entry.key, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
                ),
                for (final c in entry.value)
                  ListTile(
                    dense: true,
                    enabled: !takenNames.contains(c.address),
                    leading: Icon(switch (c.build().type) {
                      ParamType.button => Icons.radio_button_checked,
                      ParamType.chatbox => Icons.chat_bubble_outline,
                      _ => Icons.linear_scale,
                    }),
                    title: Text(c.label),
                    subtitle: Text(
                      takenNames.contains(c.address) ? 'Already added  ·  ${c.address}' : '${c.description}  ·  ${c.address}',
                    ),
                    onTap: () => Navigator.of(context).pop(c.build()),
                  ),
              ],
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
      );
    },
  );
}
