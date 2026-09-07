import 'package:flutter/material.dart';

class NymIcons {
  const NymIcons._();

  static const persona = <String, IconData>{
    'tools': Icons.handyman_outlined,
    'search': Icons.plagiarism_outlined,
    'pen': Icons.edit_note_outlined,
    'graduation': Icons.school_outlined,
    'chart': Icons.insights_outlined,
    'terse': Icons.short_text,
    'robot': Icons.smart_toy_outlined,
    'model': Icons.auto_awesome,
    'person': Icons.person_outline,
    'bolt': Icons.bolt,
  };

  static const personaOrder = <String>[
    'tools', 'search', 'pen', 'graduation', 'chart',
    'terse', 'robot', 'model', 'person', 'bolt',
  ];

  static IconData forPersona(String? name) =>
      persona[name] ?? Icons.smart_toy_outlined;
}

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

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * k
      ..strokeCap = StrokeCap.square;

    void line(double x1, double y1, double x2, double y2) {
      canvas.drawLine(Offset(x1 * k, y1 * k), Offset(x2 * k, y2 * k), paint);
    }

    line(8, 2.4, 9.8, 6);
    line(16, 2.4, 14.2, 6);
    line(3.6, 6.6, 20.4, 6.6);
    line(2.4, 8.6, 2.4, 15.6);
    line(21.6, 8.6, 21.6, 15.6);
    line(4.8, 8.8, 4.8, 17.4);
    line(19.2, 8.8, 19.2, 17.4);
    line(3.6, 19.6, 20.4, 19.6);

    final left = Path()
      ..moveTo(8.6 * k, 9.6 * k)
      ..lineTo(7.4 * k, 9.6 * k)
      ..lineTo(7.4 * k, 13.8 * k)
      ..lineTo(8.6 * k, 13.8 * k);
    final right = Path()
      ..moveTo(15.4 * k, 9.6 * k)
      ..lineTo(16.6 * k, 9.6 * k)
      ..lineTo(16.6 * k, 13.8 * k)
      ..lineTo(15.4 * k, 13.8 * k);
    final eyeA = Path()
      ..moveTo(9.2 * k, 12.6 * k)
      ..lineTo(10.3 * k, 10.8 * k)
      ..lineTo(11.4 * k, 12.6 * k);
    final eyeB = Path()
      ..moveTo(12.6 * k, 12.6 * k)
      ..lineTo(13.7 * k, 10.8 * k)
      ..lineTo(14.8 * k, 12.6 * k);
    for (final p in [left, right, eyeA, eyeB]) {
      canvas.drawPath(p, paint);
    }

    line(9, 16.2, 11.2, 16.2);
    line(12.8, 16.2, 15, 16.2);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}
