import 'dart:convert';
import 'dart:typed_data';

import '../config.dart';
import '../core/crypto/ml_kem.dart';
import '../core/crypto/pq.dart' as pq;
import '../core/crypto/schnorr.dart' as schnorr;
import '../models/nostr_event.dart';
import 'nostr/event_signer.dart';
import 'relay_pool.dart';

typedef PqKey = ({Uint8List pk, String fmt});

/// Post-quantum capability announcements (kind 30078, d-tag `nym-pq`).
///
/// Each side publishes the ML-KEM public key it can decapsulate with; the other
/// seals to it. Ours also rides along with every worker request, signed, so the
/// reply is sealed to it deterministically instead of depending on a lookup
/// that could lose a race and leave the answer classical.
class PqAnnounce {
  PqAnnounce(this.relays);

  static const int _kemPkLen = 1184;

  final RelayPool relays;

  PqKey? botKey;
  NostrEvent? selfAnnouncement;
  int _lastTs = 0;

  Uint8List? _readKey(dynamic raw) {
    if (raw == null) return null;
    try {
      final k = pq.b64uDecode(raw as String);
      return k.length == _kemPkLen ? k : null;
    } catch (_) {
      return null;
    }
  }

  /// The newest signed, id-valid announcement by [author]. Relays are never
  /// trusted for key material.
  NostrEvent? _verifiedNewest(List<NostrEvent> events, String author) {
    NostrEvent? newest;
    for (final evt in events) {
      if (evt.pubkey != author || evt.kind != 30078 || evt.sig.isEmpty) continue;
      if (newest != null && evt.createdAt <= newest.createdAt) continue;
      if (!schnorr.verifyEvent(evt)) continue;
      newest = evt;
    }
    return newest;
  }

  PqKey? _parse(NostrEvent event) {
    try {
      final payload = jsonDecode(event.content) as Map<String, dynamic>;
      if (payload['alg'] != NymbotConfig.pqAlg) return null;
      if (payload['retracted'] == true) return null;
      final exp = (payload['exp'] as num?)?.toInt() ?? 0;
      if (exp <= DateTime.now().millisecondsSinceEpoch ~/ 1000) return null;
      final pk2 = _readKey(payload['pk2']);
      if (pk2 != null) return (pk: pk2, fmt: 'pq2');
      final pk1 = _readKey(payload['pk']);
      if (pk1 != null) return (pk: pk1, fmt: 'pq1');
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<PqKey?> resolve(String pubkey) async {
    final events = await relays.fetch({
      'kinds': [30078],
      'authors': [pubkey],
      '#d': [NymbotConfig.pqDTag],
      'limit': 3,
    });
    final newest = _verifiedNewest(events, pubkey);
    return newest == null ? null : _parse(newest);
  }

  Future<PqKey?> resolveBot() async {
    botKey = await resolve(NymbotConfig.botPubkey);
    return botKey;
  }

  /// Builds a signed announcement for [kem], signed by [signer].
  Future<NostrEvent> build(EventSigner signer, MlKemKeyPair kem,
      {int epoch = 0}) async {
    final nowSec = [
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      _lastTs + 1,
    ].reduce((a, b) => a > b ? a : b);
    _lastTs = nowSec;
    final exp = nowSec + NymbotConfig.pqTtlSec;
    final b64 = pq.b64uEncode(kem.publicKey);
    return signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: nowSec,
      kind: 30078,
      tags: [
        const ['d', NymbotConfig.pqDTag],
        const ['t', NymbotConfig.pqDTag],
        ['expiration', '$exp'],
      ],
      content: jsonEncode({
        'v': 2,
        'src': 'root',
        'alg': NymbotConfig.pqAlg,
        'nym': 1,
        'epoch': epoch,
        'pk': b64,
        'pk2': b64,
        'exp': exp,
        'devices': const [],
      }),
    ));
  }

  /// Publishes our announcement, unless the account already advertises a key we
  /// cannot derive — that one belongs to another device holding a different
  /// root, and kind 30078 is replaceable, so publishing over it would strand
  /// every message sealed to it.
  ///
  /// Returns false when it withheld, which the caller surfaces as a locked
  /// identity rather than a silent downgrade.
  Future<bool> announce(EventSigner signer, MlKemKeyPair kem,
      {int epoch = 0}) async {
    final existing = await resolve(signer.pubkey);
    if (existing != null && !_sameBytes(existing.pk, kem.publicKey)) {
      return false;
    }
    final event = await build(signer, kem, epoch: epoch);
    await relays.publish(event);
    selfAnnouncement = event;
    return true;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
