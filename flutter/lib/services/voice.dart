import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../features/markdown_body.dart';

class Voice extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();

  String? speakingId;

  Future<void> speak(String id, String markdown, {double rate = 1}) async {
    await stopSpeaking();
    final text = MarkdownBody.plain(markdown);
    if (text.isEmpty) return;
    speakingId = id;
    notifyListeners();
    try {
      await _tts.setSpeechRate(rate.clamp(0.1, 1.5) * 0.5);
      _tts.setCompletionHandler(() {
        speakingId = null;
        notifyListeners();
      });
      _tts.setCancelHandler(() {
        speakingId = null;
        notifyListeners();
      });
      await _tts.speak(text);
    } catch (_) {
      speakingId = null;
      notifyListeners();
    }
  }

  Future<void> stopSpeaking() async {
    if (speakingId == null) return;
    speakingId = null;
    notifyListeners();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> toggleSpeak(String id, String markdown, {double rate = 1}) =>
      speakingId == id ? stopSpeaking() : speak(id, markdown, rate: rate);

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }
}
