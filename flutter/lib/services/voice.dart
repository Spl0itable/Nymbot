import 'dart:async';

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

  /// The platform recognisers stream the audio to a service — Google's on
  /// Android, Apple's on iOS — and answer "network" wherever that service cannot
  bool _preferOnDevice = false;

  /// Set while a network failure is being retried on-device, so the retry is not
  /// reported to the user as a failure of its own.
  bool _retrying = false;

  /// What the last attempt was handed, so a retry can pick it back up.
  void Function(String text)? _onText;

  /// True when dictation is running on the device's own recogniser.
  bool get onDevice => _preferOnDevice;

  /// Why dictation stopped, when it stopped for a reason worth saying. Every
  /// one of these used to end as a button that turned itself off again with
  /// nothing said, which is indistinguishable from a broken button.
  String? lastError;

  static String? reasonFor(String code) {
    switch (code) {
      case 'error_permission':
      case 'error_speech_timeout_permission':
        return 'Dictation needs permission to use the microphone. Allow it in '
            'the app settings and try again.';
      case 'error_audio':
      case 'error_audio_error':
        return 'No microphone was found.';
      case 'error_network':
      case 'error_network_timeout':
        return 'Dictation could not reach the speech service, and this device '
            'has no offline recogniser to fall back on. Check the connection, '
            'or install your language for offline speech in the system '
            'settings.';
      case 'error_no_match':
      case 'error_speech_timeout':
        return 'Nothing was heard.';
      case 'error_busy':
        return 'The microphone is still busy from the last time. Try again in '
            'a moment.';
      case 'error_client':
        return null;
      default:
        return 'Dictation stopped unexpectedly.';
    }
  }

  Future<bool> canListen() async {
    if (_sttChecked) return _sttReady;
    _sttChecked = true;
    try {
      _sttReady = await _stt.initialize(onStatus: (s) {
        if (s == 'done' || s == 'notListening') {
          if (_retrying) return;
          listening = false;
          notifyListeners();
        }
      }, onError: (e) {
        final code = e.errorMsg;
        // A service that cannot be reached will not be reached by trying again the same way.
        if (!_preferOnDevice &&
            (code == 'error_network' || code == 'error_network_timeout')) {
          _preferOnDevice = true;
          _retrying = true;
          unawaited(_relisten());
          return;
        }
        _retrying = false;
        lastError = reasonFor(code);
        listening = false;
        notifyListeners();
      });
      if (!_sttReady) {
        lastError = 'Dictation is not available on this device.';
      }
    } catch (_) {
      _sttReady = false;
      lastError = 'Dictation is not available on this device.';
    }
    return _sttReady;
  }

  Future<void> startListening(void Function(String text) onText) async {
    lastError = null;
    if (!await canListen() || listening) return;
    _onText = onText;
    listening = true;
    notifyListeners();
    await _listen();
  }

  Future<void> _listen() async {
    final onText = _onText;
    if (onText == null) return;
    try {
      await _stt.listen(
        onResult: (r) => onText(r.recognizedWords),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          onDevice: _preferOnDevice,
        ),
      );
    } catch (_) {
      _retrying = false;
      lastError = reasonFor('error_busy');
      listening = false;
      notifyListeners();
    }
  }

  /// Starts again on the device's own recogniser after the service one failed.
  Future<void> _relisten() async {
    try {
      await _stt.cancel();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!listening) {
      _retrying = false;
      return;
    }
    await _listen();
    _retrying = false;
    // The device's recogniser would not start either: say what is wrong rather
    // than leaving a button that turned itself off.
    if (!listening && lastError == null) {
      lastError = reasonFor('error_network');
      notifyListeners();
    }
  }

  Future<void> stopListening() async {
    if (!listening) return;
    _retrying = false;
    _onText = null;
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
