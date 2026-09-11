import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/crypto/pq.dart' as pq;
import '../models/nostr_event.dart';
import 'nostr/event_signer.dart';

/// What the account's post-quantum root row says. [present] is the row's
/// existence, decided without decrypting: a row this device cannot open is
/// still proof a root exists. [fingerprint] is filled in only when the record
/// itself opened and parsed.
typedef PqRootLookup = ({bool present, String? fingerprint});

/// The account's shared rows in D1, as they matter before there is a session:
/// which post-quantum root the account uses, and the profile it publishes.
///
/// The worker is Nymchat's, so these are Nymchat's rows. The root row in
/// particular is written under the name Nymchat gives it, hashed the way
/// Nymchat hashes it — one account, one root, whichever app reached it first.
class StorageSync {
  StorageSync({http.Client? client}) : _client = client ?? http.Client();

  /// The row that says which post-quantum root the ACCOUNT uses.
  static const String pqRootDTag = 'nymchat-pq-root';

  final http.Client _client;

  static String _sha256Hex(String text) =>
      crypto.sha256.convert(utf8.encode(text)).toString();

  /// Byte-for-byte Nymchat's `_d1Category`, or the root row is invisible to
  /// whichever app did not write it.
  static String categoryFor(String pubkey, String dTag) =>
      'nymchat-${_sha256Hex('$pubkey:d1:$dTag')}';

  Future<NostrEvent> _auth(EventSigner signer, String action) => signer.sign(
        UnsignedEvent(
          pubkey: signer.pubkey,
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          kind: 27235,
          tags: [
            const ['domain', 'nymbot-sync'],
            const ['method', 'POST'],
            ['u', NymbotConfig.storageUrl],
            ['action', action],
          ],
          content: 'nymbot-sync-auth',
        ),
      );

  Future<Map<String, dynamic>?> _call(
    String action,
    EventSigner signer, {
    Map<String, dynamic> extra = const {},
    Duration? timeout,
  }) async {
    try {
      final auth = await _auth(signer, action);
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.storageUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode({
              'action': action,
              'pubkey': signer.pubkey,
              'auth': auth.toJson(),
              ...extra,
            }),
          )
          .timeout(timeout ?? const Duration(seconds: 15));
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Null when the read did not complete — which is not the same answer as
  /// "there is no root", and the caller must not treat it as one.
  Future<PqRootLookup?> pqRootRecord(EventSigner signer) async {
    final data = await _call('settings-get', signer);
    final cats = data == null ? null : data['categories'];
    if (cats is! Map) return null;
    final hashed = categoryFor(signer.pubkey, pqRootDTag);
    String? blob;
    for (final name in [hashed, pqRootDTag]) {
      final entry = cats[name];
      if (entry is Map && entry['blob'] is String && (entry['blob'] as String).isNotEmpty) {
        blob = entry['blob'] as String;
        break;
      }
    }
    if (blob == null) return (present: false, fingerprint: null);
    try {
      final plain = await signer.nip44Decrypt(signer.pubkey, blob);
      final payload = jsonDecode(plain);
      if (payload is Map &&
          payload['v'] == 2 &&
          payload['fp'] is String &&
          (payload['fp'] as String).isNotEmpty) {
        return (present: true, fingerprint: payload['fp'] as String);
      }
    } catch (_) {
      // A row we cannot open is still a row.
    }
    return (present: true, fingerprint: null);
  }

  /// Writes the row for the root this device holds. Without it every other
  /// device reads "no root" and mints a rival one.
  ///
  /// Never hybrid, whatever this device can do: this is the one row that may
  /// not be sealed to a root-derived key, since it is what tells a device which
  /// root to derive.
  Future<bool> publishPqRootRecord(EventSigner signer, Uint8List root) async {
    final plain = jsonEncode({
      'v': 2,
      'fp': pq.pqRootFingerprint(root),
      'wraps': const [],
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      '__cat': pqRootDTag,
    });
    String blob;
    try {
      blob = await signer.nip44Encrypt(signer.pubkey, plain);
    } catch (_) {
      return false;
    }
    final resp = await _call('settings-set', signer, extra: {
      'category': categoryFor(signer.pubkey, pqRootDTag),
      'blob': blob,
      'contentHash': _sha256Hex('${signer.pubkey}|c|$plain'),
    });
    return resp != null && resp['error'] == null;
  }

  /// A public batch read of the D1 profile mirror. No identity and no auth: a
  /// kind 0 is public by definition, and this has to answer before the relays
  /// are up. Null when the read did not complete. The events are returned
  /// unverified; the caller is the one that knows what it will do with them.
  Future<Map<String, NostrEvent>?> profileEvents(List<String> pubkeys) async {
    final hex = RegExp(r'^[0-9a-f]{64}$');
    final wanted = pubkeys
        .map((pk) => pk.toLowerCase())
        .where(hex.hasMatch)
        .take(100)
        .toList();
    if (wanted.isEmpty) return {};
    try {
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.storageUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: jsonEncode({'action': 'profile-get', 'pubkeys': wanted}),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final out = <String, NostrEvent>{};
      for (final line in const LineSplitter().convert(resp.body)) {
        if (line.trim().isEmpty) continue;
        dynamic item;
        try {
          item = jsonDecode(line);
        } catch (_) {
          continue;
        }
        if (item is! List || item.length < 2) continue;
        final rec = item[1];
        if (rec is! Map || rec['event'] is! Map) continue;
        try {
          out[item[0] as String] =
              NostrEvent.fromJson(Map<String, dynamic>.from(rec['event'] as Map));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}
