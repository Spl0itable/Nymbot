import 'dart:convert';

import '../core/crypto/keys.dart';
import '../features/i18n/i18n.dart';

class GiftRecord {
  const GiftRecord({
    required this.id,
    required this.tier,
    required this.amount,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
    required this.doneAt,
    required this.own,
  });

  final String id;
  final String tier;
  final int amount;
  final String state;
  final int createdAt;
  final int expiresAt;
  final int doneAt;
  final bool own;

  bool get open => state == 'open';

  static GiftRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    int n(Object? v) => v is num ? v.toInt() : 0;
    return GiftRecord(
      id: id,
      tier: raw['tier'] == 'pro' ? 'pro' : 'standard',
      amount: n(raw['amount']),
      state: const {'open', 'redeemed', 'canceled', 'expired'}.contains(raw['state'])
          ? raw['state'] as String
          : 'open',
      createdAt: n(raw['createdAt']),
      expiresAt: n(raw['expiresAt']),
      doneAt: n(raw['doneAt']),
      own: raw['own'] == true,
    );
  }
}

class Gifts {
  const Gifts._();

  static const presets = <String, List<int>>{
    'standard': [50, 100, 250, 500, 1000],
    'pro': [1, 5, 10, 25, 50],
  };
  static const minimum = <String, int>{'standard': 10, 'pro': 1};
  static const origin = 'https://nymbot.ai';
  static const keptKey = 'giftCodes';
  static const keptMax = 50;
  static final _code = RegExp(r'^GIFT-[0-9A-F]{32}$');

  static String? codeOf(String? raw) {
    var s = (raw ?? '').trim();
    final at = s.toLowerCase().indexOf('gift=');
    if (at != -1) s = s.substring(at + 5);
    s = s.split(RegExp(r'[&\s]')).first;
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {}
    s = s.trim().toUpperCase();
    return _code.hasMatch(s) ? s : null;
  }

  static String newCode() => 'GIFT-${bytesToHex(randomBytes(16)).toUpperCase()}';

  static String link(String code) => '$origin/app/#gift=$code';

  static int available(double? balance) =>
      balance == null || balance <= 0 ? 0 : balance.floor();

  static int minOf(String tier, [Map<String, int>? min]) =>
      (min?[tier] ?? 0) > 0 ? min![tier]! : (minimum[tier] ?? 1);

  static String credits(String tier, num n) => tier == 'pro'
      ? t('{n} Pro credits', {'n': figure(n)})
      : t('{n} credits', {'n': figure(n)});

  static String? problem(String text, String tier, int most, [Map<String, int>? min]) {
    final raw = text.trim();
    if (!RegExp(r'^\d+$').hasMatch(raw)) return t('Enter a whole number of credits.');
    final n = int.parse(raw);
    final floor = minOf(tier, min);
    if (n < floor) return t('A gift is at least {n}.', {'n': credits(tier, floor)});
    if (n > most) return t('You have {n} free to give.', {'n': credits(tier, most)});
    return null;
  }

  static String day(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static String stateLine(GiftRecord g) {
    switch (g.state) {
      case 'redeemed':
        return t('Claimed {date}', {'date': day(g.doneAt)});
      case 'canceled':
        return t('Canceled, credits returned {date}', {'date': day(g.doneAt)});
      case 'expired':
        return t('Expired, credits returned {date}',
            {'date': day(g.doneAt > 0 ? g.doneAt : g.expiresAt)});
      default:
        return t('Not claimed yet · until {date}', {'date': day(g.expiresAt)});
    }
  }

  static Map<String, String> keptFrom(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (e.key is String && e.value is String && _code.hasMatch(e.value as String))
            e.key as String: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  static String keptWith(Map<String, String> kept, String id, String code) {
    final next = <String, String>{id: code};
    for (final e in kept.entries) {
      if (next.length >= keptMax) break;
      if (e.key != id) next[e.key] = e.value;
    }
    return jsonEncode(next);
  }
}
