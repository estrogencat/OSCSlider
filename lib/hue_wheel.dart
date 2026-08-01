import 'dart:math';

import 'package:flutter/material.dart';

/// a classic HSV color wheel: angle = hue, distance from center = saturation
/// (center fades to white, rim is fully saturated). value/brightness is a
/// separate dimension - use a slider alongside this widget for that.
class HueWheel extends StatelessWidget {
  final double hue;
  final double saturation;
  final void Function(double hue, double saturation) onChanged;
  final double size;

  const HueWheel({
    super.key,
    required this.hue,
    required this.saturation,
    required this.onChanged,
    this.size = 180,
  });

  void _handle(Offset localPosition) {
    final center = Offset(size / 2, size / 2);
    final delta = localPosition - center;
    var degrees = atan2(delta.dy, delta.dx) * 180 / pi;
    if (degrees < 0) degrees += 360;
    final sat = (delta.distance / (size / 2)).clamp(0.0, 1.0);
    onChanged(degrees, sat);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) => _handle(d.localPosition),
      onPanUpdate: (d) => _handle(d.localPosition),
      onTapDown: (d) => _handle(d.localPosition),
      child: CustomPaint(
        size: Size(size, size),
        painter: _HueWheelPainter(hue: hue, saturation: saturation),
      ),
    );
  }
}

class _HueWheelPainter extends CustomPainter {
  final double hue;
  final double saturation;
  _HueWheelPainter({required this.hue, required this.saturation});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // base layer: full-saturation rainbow at every angle.
    final rainbow = SweepGradient(
      colors: List.generate(13, (i) => HSVColor.fromAHSV(1, i * 30.0, 1, 1).toColor()),
    );
    canvas.drawCircle(center, radius, Paint()..shader = rainbow.createShader(rect));

    // overlay: white fading to transparent from center to rim. blending a
    // pure hue with white this way is mathematically equivalent to lowering
    // HSV saturation while keeping value at 1, which is what we want.
    final whiteFade = const RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]);
    canvas.drawCircle(center, radius, Paint()..shader = whiteFade.createShader(rect));

    // indicator dot at (hue, saturation).
    final angle = hue * pi / 180;
    final r = saturation * radius;
    final dotCenter = center + Offset(cos(angle), sin(angle)) * r;
    canvas.drawCircle(dotCenter, 9, Paint()..color = Colors.white);
    canvas.drawCircle(
      dotCenter,
      9,
      Paint()
        ..color = Colors.black26
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(dotCenter, 5, Paint()..color = HSVColor.fromAHSV(1, hue, saturation, 1).toColor());
  }

  @override
  bool shouldRepaint(covariant _HueWheelPainter oldDelegate) =>
      oldDelegate.hue != hue || oldDelegate.saturation != saturation;
}
