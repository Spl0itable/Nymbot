import 'dart:math' as math;

import 'package:flutter/material.dart';

class DictationWave extends StatelessWidget {
  const DictationWave({super.key, required this.levels, this.quiet = false});

  final List<double> levels;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = quiet ? theme.hintColor : theme.colorScheme.primary;
    final calm = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (calm) {
      return SizedBox(
        key: const ValueKey('dictation-level'),
        height: 28,
        child: Center(
          child: LinearProgressIndicator(
            value: levels.isEmpty ? 0 : levels.last,
            minHeight: 6,
            color: color,
            backgroundColor: color.withValues(alpha: 0.15),
          ),
        ),
      );
    }
    return ExcludeSemantics(
      child: SizedBox(
        height: 28,
        width: double.infinity,
        child: CustomPaint(
          key: const ValueKey('dictation-bars'),
          painter: WavePainter(List.of(levels), color),
        ),
      ),
    );
  }
}

class WavePainter extends CustomPainter {
  WavePainter(this.levels, this.color);

  final List<double> levels;
  final Color color;

  static const step = 5.0;
  static const bar = 3.0;

  int barsFor(Size size) => math.max(0, (size.width / step).floor());

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final count = barsFor(size);
    for (var i = 0; i < count; i++) {
      final at = levels.length - count + i;
      final level = at >= 0 && at < levels.length ? levels[at] : 0.0;
      final h = math.max(2.0, level * size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * step, (size.height - h) / 2, bar, h),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WavePainter old) =>
      old.color != color || !_same(old.levels, levels);

  static bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
