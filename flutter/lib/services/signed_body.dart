import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

class SignedBody {
  SignedBody._();

  static final _index = RegExp(r'^(0|[1-9][0-9]*)$');
  static const _indexMax = 4294967294;

  static bool _isIndex(String key) =>
      _index.hasMatch(key) && key.length <= 10 && int.parse(key) <= _indexMax;

  static Object? _plain(Object? v) {
    if (v is double) {
      if (v.isFinite && v == v.truncateToDouble() && v.abs() < 1e21) return v.toInt();
      return v;
    }
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList();
      final indexes = keys.where(_isIndex).toList()
        ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));
      final others = keys.where((k) => !_isIndex(k));
      final byKey = {for (final e in v.entries) '${e.key}': e.value};
      return {for (final k in [...indexes, ...others]) k: _plain(byKey[k])};
    }
    if (v is List) return [for (final item in v) _plain(item)];
    return v;
  }

  static String text(Map<String, dynamic> fields) {
    final keys = fields.keys.where((k) => k != 'auth').toList()..sort();
    return jsonEncode(_plain({for (final k in keys) k: fields[k]}));
  }

  static String hash(String text) => crypto.sha256.convert(utf8.encode(text)).toString();

  static String withAuth(String text, Map<String, dynamic> auth) {
    final tail = '"auth":${jsonEncode(auth)}}';
    return text == '{}' ? '{$tail' : '${text.substring(0, text.length - 1)},$tail';
  }
}
