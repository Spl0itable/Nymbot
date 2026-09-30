import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

/// Runtime translation from asset packs keyed by English string, shared with the web app.
class I18n {
  I18n._();

  static const _dir = 'assets/i18n';

  static String lang = 'en';
  static Map<String, String>? _pack;
  static List<LanguageOption> available = const [];

  /// Never throws; a missing pack leaves the app in English.
  static Future<void> load({String? preferred}) async {
    available = await _index();
    lang = _pick(preferred, available.map((l) => l.code).toList());
    _pack = null;
    if (lang == 'en') return;
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
    final hit = _pack?[text] ?? text;
    if (vars == null) return hit;
    return hit.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final key = m.group(1)!;
      return vars.containsKey(key) ? '${vars[key]}' : m.group(0)!;
    });
  }

  @visibleForTesting
  static void usePack(String code, Map<String, String> pack) {
    lang = code;
    _pack = pack;
  }

  static bool get isRtl => const {
        'ar', 'he', 'fa', 'ur', 'ps', 'sd', 'ckb', 'yi', 'dv'
      }.contains(lang);
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

