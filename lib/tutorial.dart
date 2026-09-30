import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// one stop on the tour. with no [target] (or one that isn't on screen)
/// the card is shown centred instead.
class TourStep {
  final GlobalKey? target;
  final IconData icon;
  final String title;
  final String body;
  // skip the step entirely when its target isn't on screen.
  final bool needsTarget;
  const TourStep({this.target, required this.icon, required this.title, required this.body, this.needsTarget = false});
}

/// dims the screen, spotlights each step's target and explains it. true if
/// the tour was finished, false if skipped.
Future<bool> showTour(BuildContext context, List<TourStep> steps) async {
  final done = await Navigator.of(context).push<bool>(
    PageRouteBuilder(
      opaque: false,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, _, _) => _Tour(steps: steps),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
  return done ?? false;
}

class _Tour extends StatefulWidget {
  final List<TourStep> steps;
  const _Tour({required this.steps});

  @override
  State<_Tour> createState() => _TourState();
}

class _TourState extends State<_Tour> {
  int _index = 0;
  final _focus = FocusNode();

  List<TourStep> get steps => widget.steps;

  @override
  void initState() {
    super.initState();
    _index = _nearestUsable(0, 1) ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  bool _usable(TourStep s) => !s.needsTarget || s.target?.currentContext != null;

  int? _nearestUsable(int from, int direction) {
    for (var i = from; i >= 0 && i < steps.length; i += direction) {
      if (_usable(steps[i])) return i;
    }
    return null;
  }

  void _go(int direction) {
    final next = _nearestUsable(_index + direction, direction);
    if (next == null) {
      if (direction > 0) Navigator.of(context).pop(true);
      return;
    }
    setState(() => _index = next);
    _reveal();
  }

  // scrolls a target that's partly off screen into view.
  void _reveal() {
    final ctx = steps[_index].target?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.3,
      duration: const Duration(milliseconds: 250),
    ).then((_) => mounted ? setState(() {}) : null);
  }

  Rect? _targetRect() {
    final box = steps[_index].target?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop(false);
    } else if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      _go(1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final step = steps[_index];
    final target = _targetRect();
    final hole = target?.inflate(6);
    final isFirst = _nearestUsable(_index - 1, -1) == null;
    final isLast = _nearestUsable(_index + 1, 1) == null;
    final shown = [
      for (var i = 0; i < steps.length; i++)
        if (i == _index || _usable(steps[i])) i,
    ];
    final position = shown.indexOf(_index);

    final cardWidth = min(400.0, size.width - 32);
    const gap = 14.0, margin = 12.0;
    // the card goes on the roomier side of the target, and is capped to fit
    // there (its text scrolls). if neither side has room it goes over the
    // middle of the screen, so the buttons are never off-screen.
    final spaceBelow = hole == null ? 0.0 : size.height - hole.bottom - gap - margin;
    final spaceAbove = hole == null ? 0.0 : hole.top - gap - margin;
    final fitsBeside = hole != null && max(spaceBelow, spaceAbove) >= 210;
    final maxHeight = fitsBeside ? max(spaceBelow, spaceAbove) : size.height - 2 * margin;
    final card = _TourCard(
      step: step,
      width: cardWidth,
      maxHeight: maxHeight,
      position: position,
      count: shown.length,
      isFirst: isFirst,
      isLast: isLast,
      onBack: () => _go(-1),
      onNext: () => _go(1),
      onSkip: () => Navigator.of(context).pop(false),
    );

    Widget placed;
    if (!fitsBeside) {
      placed = Center(child: card);
    } else {
      final left = (hole.center.dx - cardWidth / 2).clamp(16.0, max(16.0, size.width - cardWidth - 16)).toDouble();
      placed = spaceBelow >= spaceAbove
          ? Positioned(left: left, top: hole.bottom + gap, child: card)
          : Positioned(left: left, bottom: size.height - hole.top + gap, child: card);
    }

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // soaks up clicks, so the app underneath can't be used mid-tour.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                // centred steps shrink the spotlight to nothing mid-screen, so
                // moving on to a button grows it out from there.
                child: TweenAnimationBuilder<Rect?>(
                  tween: RectTween(end: hole ?? Rect.fromCenter(center: size.center(Offset.zero), width: 0, height: 0)),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  builder: (_, rect, _) => CustomPaint(
                    size: size,
                    painter: _SpotlightPainter(hole: rect, ring: theme.colorScheme.primary),
                  ),
                ),
              ),
            ),
            placed,
          ],
        ),
      ),
    );
  }
}

class _TourCard extends StatelessWidget {
  final TourStep step;
  final double width;
  final double maxHeight;
  final int position;
  final int count;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  const _TourCard({
    required this.step,
    required this.width,
    required this.maxHeight,
    required this.position,
    required this.count,
    required this.isFirst,
    required this.isLast,
    required this.onBack,
    required this.onNext,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints.tightFor(width: width).copyWith(maxHeight: maxHeight),
      child: Card(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(step.icon, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(step.title, style: theme.textTheme.titleLarge)),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(step.body, style: theme.textTheme.bodyLarge?.copyWith(height: 1.4)),
                ),
              ),
              const SizedBox(height: 16),
              // progress dots
              Row(
                children: [
                  for (var i = 0; i < count; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.only(right: 5),
                      width: i == position ? 18 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: i <= position ? scheme.primary : scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  const Spacer(),
                  Text('${position + 1} of $count', style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: isLast
                          ? null
                          : TextButton(
                              onPressed: onSkip,
                              child: const Text('Skip tour', overflow: TextOverflow.ellipsis),
                            ),
                    ),
                  ),
                  if (!isFirst) TextButton(onPressed: onBack, child: const Text('Back')),
                  const SizedBox(width: 4),
                  FilledButton(onPressed: onNext, child: Text(isFirst ? 'Show me around' : (isLast ? 'Done' : 'Next'))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect? hole;
  final Color ring;
  _SpotlightPainter({required this.hole, required this.ring});

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Offset.zero & size;
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.62);
    final h = hole;
    if (h == null || h.isEmpty) {
      canvas.drawRect(screen, shade);
      return;
    }
    final rr = RRect.fromRectAndRadius(h, const Radius.circular(14));
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(screen)
        ..addRRect(rr),
      shade,
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) => old.hole != hole || old.ring != ring;
}
