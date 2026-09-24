import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../features/markdown_body.dart';

typedef VoiceOption = ({String name, String locale});

class Voice extends ChangeNotifier {
  Voice({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  String? speakingId;
  int _run = 0;
  List<VoiceOption>? _voices;

  static const _maxChunk = 220;

  static List<String> chunks(String text, {int max = _maxChunk}) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return const [];
    final sentences = RegExp(r'[^.!?。！？]+(?:[.!?。！？]+["”’)\]]*|$)')
        .allMatches(clean)
        .map((m) => m.group(0)!.trim())
        .where((s) => s.isNotEmpty);
    final out = <String>[];
    var held = '';
    void push(String piece) {
      if (held.isEmpty) {
        held = piece;
      } else if (held.length + 1 + piece.length <= max) {
        held = '$held $piece';
      } else {
        out.add(held);
        held = piece;
      }
    }

    for (final sentence in sentences) {
      if (sentence.length <= max) {
        push(sentence);
        continue;
      }
      var rest = sentence;
      while (rest.length > max) {
        var cut = rest.lastIndexOf(RegExp(r'[,;:] '), max - 1);
        if (cut >= max ~/ 3) {
          cut += 1;
        } else {
          cut = rest.lastIndexOf(' ', max);
          if (cut < max ~/ 3) cut = max;
        }
        push(rest.substring(0, cut).trim());
        rest = rest.substring(cut).trim();
      }
      if (rest.isNotEmpty) push(rest);
    }
    if (held.isNotEmpty) out.add(held);
    return out;
  }

  static String languageFor(String text, String appLanguage) {
    int count(RegExp pattern) => pattern.allMatches(text).length;
    final letters = count(RegExp(r'\p{L}', unicode: true));
    if (letters == 0) return appLanguage;
    bool mostly(RegExp pattern) => count(pattern) * 3 >= letters;
    if (count(RegExp(r'[぀-ヿ]')) > 0 && mostly(RegExp(r'[぀-ヿ一-鿿]'))) {
      return 'ja';
    }
    if (mostly(RegExp(r'[가-힯]'))) return 'ko';
    if (mostly(RegExp(r'[一-鿿]'))) {
      return appLanguage.startsWith('zh') ? appLanguage : 'zh';
    }
    if (mostly(RegExp(r'[Ѐ-ӿ]'))) {
      return const {'uk', 'be', 'bg', 'sr', 'mk', 'kk'}.contains(appLanguage)
          ? appLanguage
          : 'ru';
    }
    if (mostly(RegExp(r'[؀-ۿ]'))) {
      return const {'fa', 'ur', 'ps'}.contains(appLanguage) ? appLanguage : 'ar';
    }
    if (mostly(RegExp(r'[֐-׿]'))) return 'he';
    if (mostly(RegExp(r'[Ͱ-Ͽ]'))) return 'el';
    if (mostly(RegExp(r'[ऀ-ॿ]'))) {
      return const {'mr', 'ne'}.contains(appLanguage) ? appLanguage : 'hi';
    }
    if (mostly(RegExp(r'[฀-๿]'))) return 'th';
    return appLanguage;
  }

  Future<List<VoiceOption>> voices() async {
    final held = _voices;
    if (held != null) return held;
    try {
      final raw = await _tts.getVoices;
      final list = <VoiceOption>[
        if (raw is List)
          for (final v in raw)
            if (v is Map && v['name'] != null)
              (name: '${v['name']}', locale: '${v['locale'] ?? ''}'),
      ]..sort((a, b) => a.locale == b.locale
          ? a.name.compareTo(b.name)
          : a.locale.compareTo(b.locale));
      return _voices = list;
    } catch (_) {
      return _voices = const [];
    }
  }

  Future<void> speak(
    String id,
    String markdown, {
    double rate = 1,
    String? voice,
    String language = 'en',
  }) async {
    await stopSpeaking();
    final parts = chunks(MarkdownBody.plain(markdown));
    if (parts.isEmpty) return;
    final run = ++_run;
    speakingId = id;
    notifyListeners();
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(rate.clamp(0.1, 1.5) * 0.5);
      final chosen = voice == null || voice.isEmpty
          ? null
          : (await voices()).where((v) => v.name == voice).firstOrNull;
      if (chosen != null) {
        await _tts.setVoice({'name': chosen.name, 'locale': chosen.locale});
      } else {
        await _tts.setLanguage(language);
      }
      for (final part in parts) {
        if (run != _run) return;
        await _tts.speak(part);
      }
    } catch (_) {}
    if (run == _run && speakingId == id) {
      speakingId = null;
      notifyListeners();
    }
  }

  Future<void> stopSpeaking() async {
    _run++;
    if (speakingId == null) return;
    speakingId = null;
    notifyListeners();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> toggleSpeak(
    String id,
    String markdown, {
    double rate = 1,
    String? voice,
    String language = 'en',
  }) =>
      speakingId == id
          ? stopSpeaking()
          : speak(id, markdown, rate: rate, voice: voice, language: language);

  @override
  void dispose() {
    _run++;
    _tts.stop().catchError((_) => null);
    super.dispose();
  }
}
