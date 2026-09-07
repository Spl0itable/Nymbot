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
