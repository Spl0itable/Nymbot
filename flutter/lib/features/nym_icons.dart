import 'package:flutter/material.dart';

/// The app's robot-head mark, drawn rather than shipped as a bitmap.
class NymbotMark extends StatelessWidget {
  const NymbotMark({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _MarkPainter(color ?? Theme.of(context).colorScheme.primary),
        ),
      );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);

  final Color color;

  /// Traced from images/nymbot-icon.png (700x700) scaled by 1/29.1667 into a 24-unit box.
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      // Strokes widened from the artwork's 16/700 to stay visible; coordinates are as measured.
      ..strokeWidth = 1 * k
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter;

    void line(double x1, double y1, double x2, double y2) {
      canvas.drawLine(Offset(x1 * k, y1 * k), Offset(x2 * k, y2 * k), paint);
    }

    line(7.96, 1.37, 9.57, 5.07);
    line(15.98, 1.37, 14.40, 5.07);

    line(3.87, 5.98, 20.09, 5.98);
    line(3.87, 20.47, 20.09, 20.47);
    for (final x in [2.76, 21.20]) {
      line(x, 6.41, x, 8.40);
      line(x, 9.57, x, 14.26);
      line(x, 15.40, x, 20.02);
    }

    final left = Path()
      ..moveTo(6.79 * k, 9.32 * k)
      ..lineTo(5.85 * k, 9.32 * k)
      ..lineTo(5.85 * k, 13.17 * k)
      ..lineTo(6.79 * k, 13.17 * k);
    final right = Path()
      ..moveTo(17.18 * k, 9.32 * k)
      ..lineTo(18.12 * k, 9.32 * k)
      ..lineTo(18.12 * k, 13.17 * k)
      ..lineTo(17.18 * k, 13.17 * k);
    final eyeA = Path()
      ..moveTo(8.16 * k, 11.31 * k)
      ..lineTo(9.10 * k, 9.26 * k)
      ..lineTo(10.05 * k, 11.31 * k);
    final eyeB = Path()
      ..moveTo(13.92 * k, 11.31 * k)
      ..lineTo(14.93 * k, 9.26 * k)
      ..lineTo(15.94 * k, 11.31 * k);
    for (final p in [left, right, eyeA, eyeB]) {
      canvas.drawPath(p, paint);
    }

    for (final y in [16.05, 17.01]) {
      line(8.33, y, 10.39, y);
      line(10.94, y, 13.03, y);
      line(13.58, y, 15.64, y);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}
