import 'dart:convert';

import '../features/i18n/i18n.dart';

/// What one gift wrap can carry, and how a question too long for one is cut up.
///
/// NIP-44 v2 refuses a plaintext over 65535 bytes, and the wrap's plaintext is
/// the serialized seal — which holds the base64 of the sealed rumor. So a
/// message pays for base64 expansion (4/3), NIP-44's padding (up to 1/8) and
/// the envelope's own fields, twice over. The post-quantum layer adds an ML-KEM
/// ciphertext to each of those two encryptions, which is the other fifth.
///
/// Measured rather than guessed: the largest message that wraps is 40,537 bytes
/// over NIP-44 alone and 32,345 with pq2, falling to 26,460 when every
/// character needs a JSON escape. The cap below is that worst case with room
/// left, and is applied to the escaped UTF-8 length so a message of quotes and
/// newlines is measured as what it will really cost.
class WireLimits {
  WireLimits._();

  static const int bodyMax = 24000;

  /// How many wraps one question may be split across. A message past this is
  /// not a message, and eight of them is roughly 180 KB.
  static const int partsMax = 8;

  /// What [text] costs on the wire: its JSON-escaped length in UTF-8 bytes. A
  /// quote or a newline is two bytes there, not one, and an emoji is four.
  static int bodyCost(String text) {
    final quoted = jsonEncode(text);
    return utf8.encode(quoted).length - 2;
  }

  static bool fits(String text) => bodyCost(text) <= bodyMax;

  /// Cuts [text] into pieces each of which fits in one wrap.
  ///
  /// The cut is taken at the last line break inside the budget rather than at
  /// the byte, so a split lands between lines and a fenced block or a sentence
  /// is not sawn in half. A single line longer than a whole wrap has nowhere
  /// better to go and is cut where it must be.
  static List<String> split(String text) {
    if (bodyCost(text) <= bodyMax) return [text];
    final parts = <String>[];
    var rest = text;
    while (rest.isNotEmpty) {
      if (bodyCost(rest) <= bodyMax) {
        parts.add(rest);
        break;
      }
      // The largest prefix that still fits. Budget is spent in escaped UTF-8
      // bytes, so the walk is a search on the character count rather than a
      // count of characters.
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
      // Back up to a line break, but not so far that a part is mostly empty —
      // a long unbroken run has to be cut somewhere.
      final nl = rest.lastIndexOf('\n', cut - 1);
      if (nl > cut ~/ 2) cut = nl + 1;
      parts.add(rest.substring(0, cut));
      rest = rest.substring(cut);
    }
    return parts;
  }

  /// A question too long for one wrap travels as several, and the worker
  /// charges a credit for each extra one. Splitting is a transport detail, but
  /// the input it carries is real and the published price has never charged
  /// for input — so the surcharge is counted here too, and quoted before it is
  /// spent rather than after.
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
