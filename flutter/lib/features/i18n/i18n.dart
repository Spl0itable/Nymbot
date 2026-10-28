import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../config.dart';

/// Runtime translation from asset packs keyed by English string, shared with the web app.
class I18n {
  I18n._();

  static const _dir = 'assets/i18n';

  static String lang = 'en';
  static Map<String, String>? _pack;
  static List<LanguageOption> available = const [];
  static const _noCatalog = '00000000';
  static String catalog = _noCatalog;
  static String keyFor(String hash) => 'c$hash';
  static String get cacheKey => keyFor(catalog);
  static Future<List<String?>?> Function(List<String> texts, String target) fetcher = _proxy;
  static const protectedNames = {
    'Nymbot', 'Nymchat', 'Nostr', 'Zapstore', 'App Store', 'Google Play', 'TestFlight', '21 Million LLC'
  };
  static const _mtBatch = 25;
  static const _mtChars = 18000;
  static const _mtMax = 5000;
  static const _mtContext = 'Nymbot app interface';
  static final _token = RegExp(r'\{\w+\}|<[^<>]+>|&[#\w]+;');
  static final _mark = RegExp('\u27e6(\\d+)\u27e7');
  static Map<String, String> _mt = {};
  static Set<String> _tried = {};
  static List<String> _queue = [];
  static bool _flushing = false;
  static int _epoch = 0;
  static const _shownMax = 3000;
  static final _shown = <String, ({String source, Map<String, Object?>? vars})>{};
  static final revision = ValueNotifier<int>(0);

  /// Never throws; a missing pack leaves the app in English.
  static Future<void> load({String? preferred}) async {
    available = await _index();
    catalog = await _readCatalog();
    final was = lang;
    lang = _pick(preferred, available.map((l) => l.code).toList());
    _pack = null;
    _reset();
    if (lang == 'en') {
      if (was != lang) _changed();
      return;
    }
    try {
      final raw = await rootBundle.loadString('$_dir/$lang.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _pack = decoded.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {
      _pack = null;
    }
    if (_pack == null) lang = 'en';
    if (lang != 'en') _mt = await _loadMt(lang);
    _changed();
  }

  static void _reset() {
    _epoch++;
    _mt = {};
    _tried = {};
    _queue = [];
  }

  static Future<String> _readCatalog() async {
    try {
      final decoded = jsonDecode(await rootBundle.loadString('$_dir/catalog.json'));
      final hash = decoded is Map ? decoded['hash'] : null;
      if (hash is String && RegExp(r'^[0-9a-f]{8}$').hasMatch(hash)) return hash;
    } catch (_) {}
    return _noCatalog;
  }

  static String _mtKey(String code) => 'i18n_mt_$code';

  @visibleForTesting
  static Future<Map<String, String>> storedMt(String code) => _loadMt(code);

  static Future<Map<String, String>> _loadMt(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_mtKey(code));
      if (raw == null) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['v'] == cacheKey && decoded['m'] is Map) {
        return (decoded['m'] as Map).map((k, v) => MapEntry('$k', '$v'));
      }
      await prefs.remove(_mtKey(code));
    } catch (_) {}
    return {};
  }

  static Future<void> _saveMt(String code, Map<String, String> mt) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_mtKey(code), jsonEncode({'v': cacheKey, 'm': mt}));
    } catch (_) {}
  }

  static ({String text, List<String> tokens}) shield(String source) {
    final tokens = <String>[];
    final text = source.replaceAllMapped(_token, (m) {
      tokens.add(m.group(0)!);
      return '\u27e6${tokens.length - 1}\u27e7';
    });
    return (text: text, tokens: tokens);
  }

  static String? unshield(String? out, List<String> tokens) {
    if (out == null || out.trim().isEmpty) return null;
    final marks = _mark.allMatches(out).toList();
    if (marks.length != tokens.length) return null;
    final seen = <int>{};
    for (final m in marks) {
      final i = int.parse(m.group(1)!);
      if (i >= tokens.length || !seen.add(i)) return null;
    }
    final back = out.replaceAllMapped(_mark, (m) => tokens[int.parse(m.group(1)!)]);
    return RegExp('[\u27e6\u27e7]').hasMatch(back) ? null : back;
  }

  static bool _wordy(String text) =>
      text.length <= _mtMax &&
      !protectedNames.contains(text) &&
      RegExp(r'\p{L}{2}', unicode: true).hasMatch(text.replaceAll(_token, ' '));

  static void _want(String source) {
    if (lang == 'en' || _pack == null) return;
    if (_tried.contains(source) || !_wordy(source)) return;
    _tried.add(source);
    _queue.add(source);
    if (!_flushing) {
      _flushing = true;
      scheduleMicrotask(_flush);
    }
  }

  static void _flush() {
    _flushing = false;
    final code = lang;
    final epoch = _epoch;
    final wires = <String, List<String>>{};
    for (final source in _queue) {
      wires.putIfAbsent(shield(source).text, () => []).add(source);
    }
    _queue = [];
    final texts = wires.keys.toList();
    var at = 0;
    while (at < texts.length) {
      final batch = <String>[];
      var chars = 0;
      while (at < texts.length && batch.length < _mtBatch) {
        final next = texts[at];
        if (batch.isNotEmpty && chars + next.length > _mtChars) break;
        batch.add(next);
        chars += next.length;
        at++;
      }
      unawaited(_send(batch, {for (final w in batch) w: wires[w]!}, code, epoch));
    }
  }

  static Future<void> _send(
      List<String> batch, Map<String, List<String>> sources, String code, int epoch) async {
    List<String?>? out;
    try {
      out = await fetcher(batch, code);
    } catch (_) {
      out = null;
    }
    if (out == null || epoch != _epoch || code != lang) return;
    var got = 0;
    for (var i = 0; i < batch.length && i < out.length; i++) {
      for (final source in sources[batch[i]]!) {
        final back = unshield(out[i], shield(source).tokens);
        if (back != null) {
          _mt[source] = back;
          got++;
        }
      }
    }
    if (got == 0) return;
    await _saveMt(code, Map.of(_mt));
    _changed();
  }

  static void _changed() {
    revision.value++;
    _refresh();
  }

  static Future<List<String?>?> _proxy(List<String> texts, String target) async {
    try {
      final resp = await http.post(
        Uri.parse('https://${NymbotConfig.apiHost}/api/proxy?action=translate'),
        headers: {'Content-Type': 'application/json', 'User-Agent': NymbotConfig.userAgent},
        body: jsonEncode({
          'texts': texts,
          'source': 'en',
          'target': target,
          'contexts': [for (final _ in texts) _mtContext],
        }),
      );
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      final list = data is Map ? data['translations'] : null;
      if (list is! List) return null;
      return [for (final x in list) x is String ? x : null];
    } catch (_) {
      return null;
    }
  }

  static void _refresh() {
    final WidgetsBinding binding;
    try {
      binding = WidgetsBinding.instance;
    } catch (_) {
      return;
    }
    final root = binding.rootElement;
    if (root == null) return;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) => _refresh());
      return;
    }
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    mark(root);
  }

  static Future<List<LanguageOption>> _index() async {
    try {
      final raw = await rootBundle.loadString('$_dir/index.json');
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => LanguageOption(
                code: '${m['code']}',
                name: '${m['name'] ?? m['code']}',
                native: m['native'] as String?,
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// The stored choice, else the closest published device locale, else English.
  static String _pick(String? preferred, List<String> published) {
    if (preferred != null && (preferred == 'en' || published.contains(preferred))) {
      return preferred;
    }
    for (final locale in PlatformDispatcher.instance.locales) {
      final full = locale.countryCode == null || locale.countryCode!.isEmpty
          ? locale.languageCode
          : '${locale.languageCode}-${locale.countryCode}';
      if (published.contains(full)) return full;
      if (locale.languageCode == 'en') return 'en';
      if (published.contains(locale.languageCode)) return locale.languageCode;
    }
    return 'en';
  }

  /// Fills `{name}` placeholders; untranslated text falls back to English.
  static String translate(String text, [Map<String, Object?>? vars]) {
    final pack = _pack;
    final hit = pack?[text] ?? _mt[text];
    if (hit != null) return _fill(hit, vars);
    final out = _fill(text, vars);
    if (lang != 'en' && pack != null) {
      _want(text);
      _remember(out, text, vars);
    }
    return out;
  }

  static String _fill(String text, Map<String, Object?>? vars) {
    if (vars == null) return text;
    return text.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final key = m.group(1)!;
      return vars.containsKey(key) ? '${vars[key]}' : m.group(0)!;
    });
  }

  static void _remember(String out, String source, Map<String, Object?>? vars) {
    _shown.remove(out);
    _shown[out] = (source: source, vars: vars == null ? null : Map.of(vars));
    if (_shown.length > _shownMax) _shown.remove(_shown.keys.first);
  }

  static String relive(String shown) {
    final was = _shown[shown];
    if (was == null) return shown;
    final hit = _pack?[was.source] ?? _mt[was.source];
    return hit == null ? shown : _fill(hit, was.vars);
  }

  @visibleForTesting
  static void usePack(String code, Map<String, String> pack) {
    lang = code;
    _pack = pack;
    _reset();
  }

  static bool get isRtl => const {
        'ar', 'he', 'fa', 'ur', 'ps', 'sd', 'ckb', 'yi', 'dv'
      }.contains(lang);
}

class UiText extends StatelessWidget {
  const UiText(this.data,
      {super.key, this.style, this.textAlign, this.maxLines, this.overflow, this.softWrap});

  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;

  @override
  Widget build(BuildContext context) => Text(I18n.relive(data),
      style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow, softWrap: softWrap);
}

class LanguageOption {
  const LanguageOption({required this.code, required this.name, this.native});

  final String code;
  final String name;
  final String? native;

  /// The endonym, so a reader can find their own language.
  String get label => native ?? name;
}

/// The shorthand the i18n extractor looks for.
String t(String text, [Map<String, Object?>? vars]) => I18n.translate(text, vars);

/// Thousands-separated and never abbreviated, grouped by hand to stay locale-independent.
String creditFigure(num? value) {
  if (value == null) return '…';
  final n = value.toDouble();
  if (n == n.roundToDouble()) return figure(n.round());
  if (n > 0 && n < 0.01) return '<0.01';
  return decimalFigure(n, 2);
}

String decimalFigure(num value, [int places = 2]) {
  final fixed = value.toDouble().toStringAsFixed(places);
  final negative = fixed.startsWith('-');
  final body = negative ? fixed.substring(1) : fixed;
  final dot = body.indexOf('.');
  final whole = dot < 0 ? body : body.substring(0, dot);
  var frac = dot < 0 ? '' : body.substring(dot + 1);
  while (frac.endsWith('0')) {
    frac = frac.substring(0, frac.length - 1);
  }
  final grouped = figure(int.parse(whole));
  final signed = negative && (whole != '0' || frac.isNotEmpty) ? '-$grouped' : grouped;
  return frac.isEmpty ? signed : '$signed.$frac';
}

String creditAmount(double value, bool metered) {
  if (!metered) return figure(value.round());
  if (value >= 10) return figure(value.round());
  if (value >= 1) {
    final one = value.toStringAsFixed(1);
    return one.endsWith('.0') ? one.substring(0, one.length - 2) : one;
  }
  final two = value.toStringAsFixed(2);
  return two.endsWith('0') ? two.substring(0, two.length - 1) : two;
}

String figure(Object? value) {
  final n = value is int
      ? value
      : (value is num ? value.round() : (int.tryParse('$value') ?? 0));
  final digits = n.abs().toString();
  final buffer = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

