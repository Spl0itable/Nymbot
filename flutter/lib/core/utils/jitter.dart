import 'dart:math' as math;

class Jitter {
  static Duration max = const Duration(milliseconds: 2000);
  static void Function()? seen;
  static final math.Random _rng = math.Random.secure();

  static Duration next([Duration? cap]) {
    seen?.call();
    final top = math.min((cap ?? max).inMilliseconds, max.inMilliseconds);
    if (top <= 0) return Duration.zero;
    final low = top ~/ 4;
    return Duration(milliseconds: low + _rng.nextInt(top - low + 1));
  }

  static Future<void> wait([Duration? cap]) async {
    final d = next(cap);
    if (d > Duration.zero) await Future<void>.delayed(d);
  }
}
