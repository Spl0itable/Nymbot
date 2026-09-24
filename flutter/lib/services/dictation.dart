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
}
