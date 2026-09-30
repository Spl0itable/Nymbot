import 'dart:convert';

import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart';
import '../core/crypto/schnorr.dart' as schnorr;
import '../models/nostr_event.dart';
import '../state/store.dart';
import 'nostr/event_signer.dart';
import 'relay_pool.dart';

const String kSupportChatId = 'support';

const int kSupportSlackSeconds = 2 * 24 * 60 * 60;

const String kSupportCursorKey = 'support_cursor';

const String kSupportTokensKey = 'support_tokens';

const String kSupportSeenKey = 'support_seen';

const String kSupportTag = 'nymbot-support';

const int kSupportTokensMax = 4;

const int kSupportSeenMax = 1000;

typedef SupportMessage = ({String id, bool mine, String content, int at});

int supportMessageAt(Object? message) {
  if (message is! Map) return 0;
  final ts = message['ts'];
  if (ts is num && ts != 0) return ts.toInt();
  final at = message['at'];
  return at is num ? at.toInt() : 0;
}

int supportOutlivesGrave(Map<String, int> graves, Iterable<Object?> lists) {
  final at = graves[kSupportChatId] ?? 0;
  if (at <= 0) return 0;
  for (final list in lists) {
    if (list is List && list.any((m) => supportMessageAt(m) > at)) return at;
  }
  return 0;
}

class SupportRelays {
  const SupportRelays({
    required this.publish,
    required this.fetch,
    required this.subscribe,
  });

  factory SupportRelays.pool(RelayPool pool) => SupportRelays(
        publish: pool.publish,
        fetch: pool.fetch,
        subscribe: pool.subscribe,
      );

  final Future<int> Function(NostrEvent event, {Duration? timeout}) publish;
  final Future<List<NostrEvent>> Function(Map<String, dynamic> filter,
      {Duration? timeout}) fetch;
  final void Function() Function(
          Map<String, dynamic> filter, void Function(NostrEvent) onEvent)
      subscribe;
}

Map<String, dynamic> supportFilter(
        String pubkey, List<String> tokens, int since) =>
    {
      'kinds': [1059],
      '#p': [pubkey],
      '#t': tokens,
      'since': since < 0 ? 0 : since,
    };

class SupportTokens {
  const SupportTokens._();

  static final RegExp _hex = RegExp(r'^[0-9a-f]{64}$');

  static List<Map<String, dynamic>> _clean(Object? raw) {
    final out = <Map<String, dynamic>>[];
    if (raw is! List) return out;
    for (final e in raw) {
      if (e is! Map) continue;
      final token = e['token'];
      final at = e['at'];
      if (token is! String || !_hex.hasMatch(token)) continue;
      out.add({'token': token, 'at': at is num ? at.toInt() : 0});
    }
    return out;
  }

  static List<Map<String, dynamic>> merge(Object? mine, Object? theirs) {
    final byToken = <String, int>{};
    for (final e in [..._clean(mine), ..._clean(theirs)]) {
      final token = e['token'] as String;
      final at = e['at'] as int;
      final held = byToken[token];
      if (held == null || at < held) byToken[token] = at;
    }
    final list = [
      for (final e in byToken.entries) {'token': e.key, 'at': e.value}
    ]..sort((a, b) {
        final byAt = (b['at'] as int).compareTo(a['at'] as int);
        return byAt != 0
            ? byAt
            : (a['token'] as String).compareTo(b['token'] as String);
      });
    return list.take(kSupportTokensMax).toList();
  }

  static List<Map<String, dynamic>> entries(Store store) {
    final raw = store.getString(kSupportTokensKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return merge(jsonDecode(raw), const []);
    } catch (_) {
      return const [];
    }
  }

  static List<String> of(Store store) =>
      [for (final e in entries(store)) e['token'] as String];

  static Future<void> save(Store store, List<Map<String, dynamic>> list) =>
      store.setString(kSupportTokensKey, jsonEncode(merge(list, const [])));

  static Future<bool> absorb(Store store, Object? remote) async {
    final mine = entries(store);
    final merged = merge(mine, remote);
    if (jsonEncode(merged) == jsonEncode(mine)) return false;
    await save(store, merged);
    return true;
  }

  static Future<String> ensure(Store store) async {
    final held = of(store);
    if (held.isNotEmpty) return held.first;
    final token = bytesToHex(randomBytes(32));
    await save(store, [
      {'token': token, 'at': DateTime.now().millisecondsSinceEpoch}
    ]);
    return token;
  }
}

List<String> _values(Object? tags, String name) {
  final out = <String>[];
  if (tags is! List) return out;
  for (final t in tags) {
    if (t is List && t.length > 1 && t[0] == name && t[1] is String) {
      out.add(t[1] as String);
    }
  }
  return out;
}

Future<SupportMessage?> openSupportWrap(
  NostrEvent wrap, {
  required EventSigner signer,
  required List<giftwrap.KemPair> kems,
  required List<String> tokens,
  required String developer,
}) async {
  if (wrap.kind != 1059) return null;
  final me = signer.pubkey;
  if (!_values(wrap.tags, 'p').contains(me)) return null;
  if (!_values(wrap.tags, 't').any(tokens.contains)) return null;
  if (!schnorr.verifyEvent(wrap)) return null;
  final opened = await giftwrap.unwrapWith(wrap, signer, kems);
  if (opened == null) return null;
  final seal = opened.seal;
  final rumor = opened.rumor;
  if (seal.kind != 13 || !schnorr.verifyEvent(seal)) return null;
  if (rumor['pubkey'] != seal.pubkey || rumor['kind'] != 14) return null;
  final createdAt = rumor['created_at'];
  final content = rumor['content'];
  final rawTags = rumor['tags'];
  if (createdAt is! num || content is! String || rawTags is! List) return null;
  final List<List<String>> tags;
  try {
    tags = [
      for (final t in rawTags) [for (final v in t as List) v as String]
    ];
  } catch (_) {
    return null;
  }
  final id = NostrEvent(
    pubkey: seal.pubkey,
    createdAt: createdAt.toInt(),
    kind: 14,
    tags: tags,
    content: content,
  ).computeId();
  if (rumor['id'] != id) return null;
  final ps = _values(tags, 'p');
  final bool mine;
  if (seal.pubkey == developer && developer != me) {
    if (!ps.contains(me)) return null;
    mine = false;
  } else if (seal.pubkey == me && ps.contains(developer)) {
    mine = true;
  } else {
    return null;
  }
  final seconds = createdAt.toInt();
  var at = seconds * 1000;
  final ms = int.tryParse(_values(tags, 'ms').firstOrNull ?? '');
  if (ms != null && (ms ~/ 1000 - seconds).abs() <= 600) at = ms;
  return (id: id, mine: mine, content: content, at: at);
}
