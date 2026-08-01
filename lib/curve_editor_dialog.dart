import 'package:flutter/material.dart';

import 'param_control.dart';

typedef CurveEditResult = ({List<Offset> points, bool smooth, double yMin, double yMax});

/// opens the custom-curve point editor. returns the edited points, smoothing
/// flag, and vertical bounds, or null if cancelled.
Future<CurveEditResult?> showCurveEditorDialog(
  BuildContext context,
  List<Offset> points,
  bool smooth,
  double yMin,
  double yMax,
) {
  return showDialog<CurveEditResult>(
    context: context,
    builder: (context) => CurveEditorDialog(
      initialPoints: points,
      initialSmooth: smooth,
      initialYMin: yMin,
      initialYMax: yMax,
    ),
  );
}

class CurveEditorDialog extends StatefulWidget {
  final List<Offset> initialPoints;
  final bool initialSmooth;
  final double initialYMin;
  final double initialYMax;
  const CurveEditorDialog({
    super.key,
    required this.initialPoints,
    required this.initialSmooth,
    required this.initialYMin,
    required this.initialYMax,
  });

  @override
  State<CurveEditorDialog> createState() => _CurveEditorDialogState();
}

class _CurveEditorDialogState extends State<CurveEditorDialog> {
  late List<Offset> _points;
  late bool _smooth;
  late double _yMin;
  late double _yMax;
  late final TextEditingController _yMinController;
  late final TextEditingController _yMaxController;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _points = [...widget.initialPoints]..sort((a, b) => a.dx.compareTo(b.dx));
    if (_points.length < 2) {
      _points = [const Offset(0, 0), const Offset(1, 1)];
    }
    _smooth = widget.initialSmooth;
    _yMin = widget.initialYMin;
    _yMax = widget.initialYMax;
    _yMinController = TextEditingController(text: _fmt(_yMin));
    _yMaxController = TextEditingController(text: _fmt(_yMax));
  }

  @override
  void dispose() {
    _yMinController.dispose();
    _yMaxController.dispose();
    super.dispose();
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  void _applyRange() {
    final min = double.tryParse(_yMinController.text) ?? _yMin;
    final max = double.tryParse(_yMaxController.text) ?? _yMax;
    if (max <= min) {
      _yMinController.text = _fmt(_yMin);
      _yMaxController.text = _fmt(_yMax);
      return;
    }
    setState(() {
      _yMin = min;
      _yMax = max;
      // shrinking the range would strand existing points outside the now-
      // clipped, now-undraggable area - pull them back inside.
      _points = _points.map((p) => Offset(p.dx, p.dy.clamp(_yMin, _yMax))).toList();
    });
  }

  Offset _toCurveSpace(Offset local, Size size) {
    final x = (local.dx / size.width).clamp(0.0, 1.0);
    final y = _yMax - (local.dy / size.height) * (_yMax - _yMin);
    return Offset(x, y.clamp(_yMin, _yMax));
  }

  Offset _toLocalSpace(Offset curve, Size size) {
    final dx = curve.dx * size.width;
    final dy = (_yMax - curve.dy) / (_yMax - _yMin) * size.height;
    return Offset(dx, dy);
  }

  int? _hitTestPoint(Offset local, Size size) {
    for (var i = 0; i < _points.length; i++) {
      if ((_toLocalSpace(_points[i], size) - local).distance < 18) return i;
    }
    return null;
  }

  void _addPoint(Offset local, Size size) {
    final p = _toCurveSpace(local, size);
    setState(() {
      _points.add(p);
      _points.sort((a, b) => a.dx.compareTo(b.dx));
      _selected = _points.indexOf(p);
    });
  }

  void _dragPoint(int index, Offset local, Size size) {
    final p = _toCurveSpace(local, size);
    setState(() {
      // endpoints stay pinned to x=0/x=1 so the curve always spans the full
      // duration; interior points can't cross their neighbors, keeping the
      // curve a proper function of x.
      if (index == 0 || index == _points.length - 1) {
        _points[index] = Offset(_points[index].dx, p.dy);
        return;
      }
      final minX = _points[index - 1].dx + 0.01;
      final maxX = _points[index + 1].dx - 0.01;
      _points[index] = Offset(p.dx.clamp(minX, maxX), p.dy);
    });
  }

  void _deleteSelected() {
    if (_selected == null || _points.length <= 2) return;
    setState(() {
      _points.removeAt(_selected!);
      _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Custom curve'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tap empty space to add a point, drag a point to move it. '
              'This shapes progress over the ramp duration - flat sections '
              'pause, and going above/below the target overshoots it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: 16 / 10,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(constraints.maxWidth, constraints.maxHeight);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      final hit = _hitTestPoint(details.localPosition, size);
                      setState(() => _selected = hit);
                      if (hit == null) _addPoint(details.localPosition, size);
                    },
                    onPanStart: (details) {
                      setState(() => _selected = _hitTestPoint(details.localPosition, size));
                    },
                    onPanUpdate: (details) {
                      final sel = _selected;
                      if (sel != null) _dragPoint(sel, details.localPosition, size);
                    },
                    child: CustomPaint(
                      size: size,
                      painter: _CurvePainter(
                        points: _points,
                        selected: _selected,
                        smooth: _smooth,
                        toLocal: (p) => _toLocalSpace(p, size),
                        curveColor: scheme.primary,
                        gridColor: scheme.outlineVariant,
                        surfaceColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_selected == null ? 'No point selected' : 'Point ${_selected! + 1} selected'),
                TextButton.icon(
                  onPressed: _selected == null || _points.length <= 2 ? null : _deleteSelected,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete point'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Smooth curve'),
              subtitle: const Text('Spline through the points instead of straight segments'),
              value: _smooth,
              onChanged: (v) => setState(() => _smooth = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _yMinController,
                    keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                    decoration: const InputDecoration(labelText: 'Graph min'),
                    onSubmitted: (_) => _applyRange(),
                    onTapOutside: (_) => _applyRange(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _yMaxController,
                    keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                    decoration: const InputDecoration(labelText: 'Graph max'),
                    onSubmitted: (_) => _applyRange(),
                    onTapOutside: (_) => _applyRange(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            _applyRange();
            Navigator.of(context).pop((points: _points, smooth: _smooth, yMin: _yMin, yMax: _yMax));
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _CurvePainter extends CustomPainter {
  final List<Offset> points;
  final int? selected;
  final bool smooth;
  final Offset Function(Offset) toLocal;
  final Color curveColor;
  final Color gridColor;
  final Color surfaceColor;

  _CurvePainter({
    required this.points,
    required this.selected,
    required this.smooth,
    required this.toLocal,
    required this.curveColor,
    required this.gridColor,
    required this.surfaceColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // a smooth spline can swing past yMin/yMax between two steep neighboring
    // points even though every point itself is clamped into range - clip so
    // that overshoot stays inside the box instead of drawing over the rest
    // of the dialog.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = surfaceColor);

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final zeroY = toLocal(const Offset(0, 0)).dy;
    final oneY = toLocal(const Offset(0, 1)).dy;
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), gridPaint);
    canvas.drawLine(Offset(0, oneY), Offset(size.width, oneY), gridPaint);

    final sorted = [...points]..sort((a, b) => a.dx.compareTo(b.dx));
    final path = Path();
    if (smooth) {
      // sample the same spline the engine evaluates, so the preview always
      // matches what the automation actually does.
      const steps = 60;
      for (var i = 0; i <= steps; i++) {
        final t = sorted.first.dx + (sorted.last.dx - sorted.first.dx) * i / steps;
        final local = toLocal(Offset(t, evalCustomCurve(sorted, true, t)));
        if (i == 0) {
          path.moveTo(local.dx, local.dy);
        } else {
          path.lineTo(local.dx, local.dy);
        }
      }
    } else {
      for (var i = 0; i < sorted.length; i++) {
        final local = toLocal(sorted[i]);
        if (i == 0) {
          path.moveTo(local.dx, local.dy);
        } else {
          path.lineTo(local.dx, local.dy);
        }
      }
    }
    canvas.drawPath(path, Paint()
      ..color = curveColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke);

    for (var i = 0; i < points.length; i++) {
      final local = toLocal(points[i]);
      final isSelected = i == selected;
      canvas.drawCircle(local, isSelected ? 8 : 6,
          Paint()..color = isSelected ? curveColor : curveColor.withValues(alpha: 0.7));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CurvePainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.selected != selected || oldDelegate.smooth != smooth;
}
