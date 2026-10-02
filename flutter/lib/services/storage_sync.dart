import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/crypto/pq.dart' as pq;
import '../models/nostr_event.dart';
import 'nostr/event_signer.dart';
import 'signed_body.dart';

/// [present] is decided without decrypting; [fingerprint] only when the record opened.
typedef PqRootLookup = ({bool present, String? fingerprint});

/// The account's shared Nymchat D1 rows (PQ root and profile), readable before a session.
class StorageSync {
  StorageSync({http.Client? client}) : _client = client ?? http.Client();

  /// The row naming which post-quantum root the account uses.
  static const String pqRootDTag = 'nymchat-pq-root';

  final http.Client _client;

  static String _sha256Hex(String text) =>
      crypto.sha256.convert(utf8.encode(text)).toString();

  /// Must match Nymchat's `_d1Category` byte for byte.
  static String categoryFor(String pubkey, String dTag) =>
      'nymchat-${_sha256Hex('$pubkey:d1:$dTag')}';

  Future<NostrEvent> _auth(EventSigner signer, String action, String payload) => signer.sign(
        UnsignedEvent(
          pubkey: signer.pubkey,
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          kind: 27235,
          tags: [
            const ['domain', 'nymbot-sync'],
            const ['method', 'POST'],
            ['u', NymbotConfig.storageUrl],
            ['action', action],
            ['payload', payload],
          ],
          content: 'nymbot-sync-auth',
        ),
      );

  Future<Map<String, dynamic>?> settingsGet(
    EventSigner signer, {
    int? since,
    List<String>? only,
  }) =>
      _call('settings-get', signer,
          extra: {
            'since': ?since,
            'only': ?only,
          },
          timeout: const Duration(seconds: 20));

  Future<Map<String, dynamic>?> settingsSetRaw(
          EventSigner signer, Map<String, dynamic> body) =>
      _call('settings-set', signer,
          extra: body, timeout: const Duration(seconds: 20));

  Future<bool> settingsSet(
    EventSigner signer, {
    required String category,
    required String blob,
    required String contentHash,
  }) async {
    final resp = await settingsSetRaw(signer,
        {'category': category, 'blob': blob, 'contentHash': contentHash});
    return resp != null && resp['error'] == null;
  }

  Future<({bool ok, bool conflict, String? current})> settingsPut(
    EventSigner signer, {
    required String category,
    required String blob,
    required String contentHash,
    required String baseHash,
  }) async {
    final resp = await settingsSetRaw(signer, {
      'category': category,
      'blob': blob,
      'contentHash': contentHash,
      'baseHash': baseHash,
    });
    if (resp == null) return (ok: false, conflict: false, current: null);
    if (resp['conflict'] == true) {
      final now = resp['contentHash'];
      return (ok: false, conflict: true, current: now is String ? now : '');
    }
    return (ok: resp['error'] == null, conflict: false, current: null);
  }

  Future<Map<String, dynamic>?> _call(
    String action,
    EventSigner signer, {
    Map<String, dynamic> extra = const {},
    Duration? timeout,
  }) async {
    try {
      final text = SignedBody.text({'action': action, 'pubkey': signer.pubkey, ...extra});
      final auth = await _auth(signer, action, SignedBody.hash(text))
          .timeout(const Duration(seconds: 20));
      final resp = await _client
          .post(
            Uri.parse(NymbotConfig.storageUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': NymbotConfig.userAgent,
            },
            body: SignedBody.withAuth(text, auth.toJson()),
          )
          .timeout(timeout ?? const Duration(seconds: 15));
      final decoded = jsonDecode(resp.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Null when the read did not complete, which is not the same as "no root".
  Future<PqRootLookup?> pqRootRecord(EventSigner signer) async {
    final hashed = categoryFor(signer.pubkey, pqRootDTag);
    final data =
        await _call('settings-get', signer, extra: {'only': [hashed, pqRootDTag]});
    final cats = data == null ? null : data['categories'];
    if (cats is! Map) return null;
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
      // A row we cannot open still proves a root exists.
    }
    return (present: true, fingerprint: null);
  }

  /// Never hybrid: this row tells a device which root to derive, so it cannot be sealed to a root-derived key.
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

  /// Public, unauthenticated read of the D1 profile mirror; events are returned unverified.
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
