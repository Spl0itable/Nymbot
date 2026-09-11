import 'package:flutter/material.dart';

/// The app's own mark, drawn rather than shipped as a bitmap: the same robot
/// head the icon and the ASCII wordmark use, so the drawer, the tab and the
/// avatar are recognisably one thing.
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

  /// Traced off images/nymbot-icon.png at 700x700 and divided by 29.1667 into
  /// a 24-unit box, so this and the web app's mark are the same drawing rather
  /// than two impressions of it.
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      // The artwork's own strokes are 16/700 of the canvas, which is under a
      // pixel at this size. Widened just enough to survive it; every
      // coordinate below is the measured one.
      ..strokeWidth = 1 * k
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter;

    void line(double x1, double y1, double x2, double y2) {
      canvas.drawLine(Offset(x1 * k, y1 * k), Offset(x2 * k, y2 * k), paint);
    }

    // Antennae.
    line(7.96, 1.37, 9.57, 5.07);
    line(15.98, 1.37, 14.40, 5.07);

    // The head: one bar top and bottom, three dashes down each side.
    line(3.87, 5.98, 20.09, 5.98);
    line(3.87, 20.47, 20.09, 20.47);
    for (final x in [2.76, 21.20]) {
      line(x, 6.41, x, 8.40);
      line(x, 9.57, x, 14.26);
      line(x, 15.40, x, 20.02);
    }

    // [ ^   ^ ]
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

    // The mouth: two rows of three dashes.
    for (final y in [16.05, 17.01]) {
      line(8.33, y, 10.39, y);
      line(10.94, y, 13.03, y);
      line(13.58, y, 15.64, y);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}
