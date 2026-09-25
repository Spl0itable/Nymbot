import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class Dictation {
  const Dictation._();

  static const channel = MethodChannel('ai.nymbot/dictate');
  static const limit = Duration(minutes: 2);
  static const maxBytes = 3 * 1024 * 1024;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> start() => channel.invokeMethod<Object?>('start');

  static Future<Uint8List?> stop() => channel.invokeMethod<Uint8List>('stop');

  static Future<void> cancel() async {
    try {
      await channel.invokeMethod<Object?>('cancel');
    } catch (_) {}
  }

  static Future<double?> level() async {
    try {
      final value = await channel.invokeMethod<Object?>('level');
      if (value is num && value.isFinite) {
        return value.toDouble().clamp(0.0, 1.0).toDouble();
      }
    } catch (_) {}
    return null;
  }
}

class DictationMeter {
  DictationMeter({this.hintAfter = const Duration(seconds: 3)});

  static const interval = Duration(milliseconds: 60);
  static const soundLevel = 0.1;
  static const history = 64;
  static const minSamples = 10;

  final Duration hintAfter;
  final List<double> levels = [];
  int ticks = 0;
  int samples = 0;
  bool heard = false;

  void add(double? level) {
    ticks++;
    if (level == null || !level.isFinite) return;
    samples++;
    if (level >= soundLevel) heard = true;
    levels.add(level.clamp(0.0, 1.0).toDouble());
    if (levels.length > history) levels.removeAt(0);
  }

  double get level => levels.isEmpty ? 0 : levels.last;

  bool get metering => samples >= minSamples;

  bool get noSound =>
      !heard &&
      metering &&
      ticks * interval.inMilliseconds >= hintAfter.inMilliseconds;

  bool get silentClip => !heard && metering && samples * 2 >= ticks;
}
