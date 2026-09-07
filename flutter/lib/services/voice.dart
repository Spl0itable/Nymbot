import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../features/markdown_body.dart';

class Voice extends ChangeNotifier {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _sttReady = false;
  bool _sttChecked = false;
  bool listening = false;
  String? speakingId;

  Future<bool> canListen() async {
    if (_sttChecked) return _sttReady;
    _sttChecked = true;
    try {
      _sttReady = await _stt.initialize(onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          listening = false;
          notifyListeners();
        }
      }, onError: (_) {
        listening = false;
        notifyListeners();
      });
    } catch (_) {
      _sttReady = false;
    }
    return _sttReady;
  }

  Future<void> startListening(void Function(String text) onText) async {
    if (!await canListen() || listening) return;
    listening = true;
    notifyListeners();
    try {
      await _stt.listen(
        onResult: (r) => onText(r.recognizedWords),
        listenOptions: SpeechListenOptions(partialResults: true),
      );
    } catch (_) {
      listening = false;
      notifyListeners();
    }
  }

  Future<void> stopListening() async {
    if (!listening) return;
    listening = false;
    notifyListeners();
    try {
      await _stt.stop();
    } catch (_) {}
  }

  Future<void> toggleListening(void Function(String text) onText) =>
      listening ? stopListening() : startListening(onText);

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
    _stt.cancel();
    super.dispose();
  }
}
