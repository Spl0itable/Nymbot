import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;

/// Translation at runtime, from a pack shipped as an asset.
///
/// The packs are generated from the same cache the marketing site and the web
/// app read (`npm run build` writes `assets/i18n/`), keyed by the English
/// string. So a sentence two surfaces share is translated once, and the same
/// extractor finds `t('…')` here as it does in the web app's modules.
class I18n {
  I18n._();

  static const _dir = 'assets/i18n';

  static String lang = 'en';
  static Map<String, String>? _pack;
  static List<LanguageOption> available = const [];

  /// Loads the index and, when there is a match, the pack itself. Never
  /// throws: a missing or unreadable pack leaves the app in English, which is
  /// what a checkout with no build looks like.
  static Future<void> load({String? preferred}) async {
    available = await _index();
    lang = _pick(preferred, available.map((l) => l.code).toList());
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

  /// The stored choice, else the closest published match for the device's
  /// locales, else English.
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

  /// One string, with `{name}` placeholders filled from [vars].
  ///
  /// Untranslated text is returned as it came in, so a pack missing an entry
  /// degrades to English rather than to a key. The whole sentence is the unit
  /// on purpose: a translator handed fragments to join cannot reorder them,
  /// and word order is most of what changes.
  static String translate(String text, [Map<String, Object?>? vars]) {
    final hit = _pack?[text] ?? text;
    if (vars == null) return hit;
    return hit.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final key = m.group(1)!;
      return vars.containsKey(key) ? '${vars[key]}' : m.group(0)!;
    });
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

  /// The endonym, so a reader who cannot read the current language can still
  /// find their own in the list.
  String get label => native ?? name;
}

/// The shorthand every call site uses, and the shape the extractor looks for.
String t(String text, [Map<String, Object?>? vars]) => I18n.translate(text, vars);

/// A figure with its thousands separated, and nothing else done to it.
///
/// Never abbreviated, however long it gets: these are balances and prices, and
/// rounding 12,500 credits to "12.5k" throws away digits the reader is entitled
/// to. Separators are all the legibility a figure needs when every one of them
/// has to stay.
///
/// The grouping is written out rather than left to a locale formatter so it is
/// deterministic: the same figure however the app has been translated, and
/// whatever the device's own locale happens to be.
String creditFigure(num? value) {
  if (value == null) return '…';
  final n = value.toDouble();
  if (n == n.roundToDouble()) return figure(n.round());
  if (n > 0 && n < 0.01) return '<0.01';
  var two = n.toStringAsFixed(2);
  while (two.endsWith('0')) {
    two = two.substring(0, two.length - 1);
  }
  if (two.endsWith('.')) two = two.substring(0, two.length - 1);
  return two;
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

