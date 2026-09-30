import 'dart:convert';

import '../features/i18n/i18n.dart';

/// Per-wrap size budget: NIP-44 v2 caps plaintext at 65535 bytes, and seal, base64, padding and pq2 eat into it.
class WireLimits {
  WireLimits._();

  static const int bodyMax = 24000;

  /// Most wraps one question may span (roughly 180 KB).
  static const int partsMax = 8;

  /// JSON-escaped UTF-8 byte length, as it costs on the wire.
  static int bodyCost(String text) {
    final quoted = jsonEncode(text);
    return utf8.encode(quoted).length - 2;
  }

  static bool fits(String text) => bodyCost(text) <= bodyMax;

  /// Splits [text] into wrap-sized parts, cutting at line breaks where possible.
  static List<String> split(String text) {
    if (bodyCost(text) <= bodyMax) return [text];
    final parts = <String>[];
    var rest = text;
    while (rest.isNotEmpty) {
      if (bodyCost(rest) <= bodyMax) {
        parts.add(rest);
        break;
      }
      // Binary search on character count, since the budget is in escaped UTF-8 bytes.
      var lo = 1;
      var hi = rest.length;
      while (lo < hi) {
        final mid = (lo + hi + 1) ~/ 2;
        if (bodyCost(rest.substring(0, mid)) <= bodyMax) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      var cut = lo;
      // Back up to a line break unless that would leave the part mostly empty.
      final nl = rest.lastIndexOf('\n', cut - 1);
      if (nl > cut ~/ 2) cut = nl + 1;
      parts.add(rest.substring(0, cut));
      rest = rest.substring(cut);
    }
    return parts;
  }

  /// The worker charges a credit per extra wrap, so the surcharge is quoted before sending.
  static int partSurcharge(String wireText) {
    final n = split(wireText).length;
    return n > 1 ? n - 1 : 0;
  }

  static String overLimitMessage(String wireText) {
    final kb = (bodyCost(wireText) / 1024).round();
    final max = ((bodyMax * partsMax) / 1024).round();
    return t(
        'This message is {n} KB, and the most one question can carry is about {max} KB. Put a long file in a workspace instead, where the whole of it is searched rather than sent.',
        {'n': kb, 'max': max});
  }
}
