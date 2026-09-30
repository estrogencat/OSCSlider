import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// the app's navigator, so the keyboard easter egg can open its page from
/// anywhere.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// the "无信号" easter egg (Backrooms). typing "nosignal" anywhere outside a
/// text field opens it, and so does holding the version number in Settings
/// for 10 seconds.
class NoSignal {
  static const _code = 'nosignal';

  /// off in tests, which have no audio backend.
  static bool soundEnabled = true;
  static String _typed = '';
  static bool _open = false;

  /// for HardwareKeyboard.instance.addHandler.
  static bool handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || _open) return false;
    final char = event.character?.toLowerCase();
    if (char == null || char.length != 1) return false;
    // typing into a field shouldn't trigger it.
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText || focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      _typed = '';
      return false;
    }
    _typed = (_typed + char);
    if (_typed.length > _code.length) _typed = _typed.substring(_typed.length - _code.length);
    if (_typed == _code) {
      _typed = '';
      open();
    }
    return false;
  }

  static Future<void> open({NavigatorState? navigator}) async {
    final nav = navigator ?? appNavigatorKey.currentState;
    if (nav == null || _open) return;
    _open = true;
    try {
      await nav.push(PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 120),
        pageBuilder: (_, _, _) => NoSignalPage(playSound: soundEnabled),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
      ));
    } finally {
      _open = false;
    }
  }
}

/// wraps the version number: holding it for 10 seconds opens the page.
class NoSignalHold extends StatefulWidget {
  final Widget child;
  const NoSignalHold({super.key, required this.child});

  @override
  State<NoSignalHold> createState() => _NoSignalHoldState();
}

class _NoSignalHoldState extends State<NoSignalHold> {
  Timer? _timer;
  Offset? _start;

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  // raw pointer events, so it doesn't compete with the version's own taps.
  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (e) {
          _start = e.position;
          _cancel();
          _timer = Timer(const Duration(seconds: 10), () => NoSignal.open(navigator: Navigator.of(context)));
        },
        onPointerMove: (e) {
          if (_start != null && (e.position - _start!).distance > 24) _cancel();
        },
        onPointerUp: (_) => _cancel(),
        onPointerCancel: (_) => _cancel(),
        child: widget.child,
      );
}

class NoSignalPage extends StatefulWidget {
  final bool playSound;
  const NoSignalPage({super.key, this.playSound = true});

  @override
  State<NoSignalPage> createState() => _NoSignalPageState();
}

class _NoSignalPageState extends State<NoSignalPage> {
  AudioPlayer? _player;

  @override
  void initState() {
    super.initState();
    if (widget.playSound) _play();
  }

  Future<void> _play() async {
    try {
      final player = _player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.play(AssetSource('easter/nosignal.mp3'), volume: 0.6);
    } catch (_) {
      // no audio backend (e.g. GStreamer missing on Linux) - it's still a page.
    }
  }

  @override
  void dispose() {
    final player = _player;
    if (player != null) unawaited(player.dispose().catchError((_) {}));
    super.dispose();
  }

  static const _blue = Color(0xFF1025E6);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _blue,
      body: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              // an old CRT: brighter in the middle, a little dimmer at the edges.
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: 1.1,
                      colors: [Color(0xFF1A30F2), _blue, Color(0xFF0A18B8)],
                      stops: [0, 0.6, 1],
                    ),
                  ),
                ),
              ),
              Center(
                child: Text(
                  '无信号',
                  style: TextStyle(
                    fontFamily: 'NoSignalCJK',
                    fontSize: 64,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 10,
                    color: const Color(0xFFF2F2FF),
                    shadows: [Shadow(color: Colors.white.withValues(alpha: 0.55), blurRadius: 6)],
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
