import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../models/nostr_event.dart';
import '../../services/nostr/event_signer.dart';
import 'bitchat.dart' as bitchat;
import 'keys.dart';
import 'nip44.dart' as nip44;
import 'pq.dart' as pq;
import 'schnorr.dart';

/// NIP-59 gift wrapping, matching nym-crypto.js `nip59Wrap`, `bitchatWrap` and `unwrapGiftWrap`.

final Random _rng = Random.secure();

/// `now - rand*7200` seconds for NIP-59 metadata protection; matches `randomNow()`.
int randomNow() {
  final r = _rng.nextDouble();
  final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
  return (now - r * 7200).round();
}

Map<String, dynamic> _buildRumorMap(UnsignedEvent rumor, String senderPub) {
  final r = NostrEvent(
    pubkey: senderPub,
    createdAt: rumor.createdAt,
    kind: rumor.kind,
    tags: rumor.tags,
    content: rumor.content,
  );
  final id = r.computeId();
  // Rumor JSON: id and standard fields, no sig (NIP-59).
  return {
    'id': id,
    'pubkey': senderPub,
    'created_at': r.createdAt,
    'kind': r.kind,
    'tags': r.tags,
    'content': r.content,
  };
}

/// Returns a signed kind-1059 gift wrap for [recipientPubkey].
NostrEvent nip59Wrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  int? expiration,
}) {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

  // Seal (kind 13) signed by the real sender key.
  final ckSeal = nip44.getConversationKey(senderPrivkey, recipientPubkey);
  final seal = finalizeEvent(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: nip44.encrypt(jsonEncode(rumorMap), ckSeal),
    ),
    senderPrivkey,
  );

  // Wrap (kind 1059) signed by a fresh ephemeral key.
  final ephSk = generatePrivateKey();
  final ckWrap = nip44.getConversationKey(ephSk, recipientPubkey);
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: nip44.encrypt(jsonEncode(seal.toJson()), ckWrap),
    ),
    ephSk,
  );
}

/// Hybrid ECDH + ML-KEM-768 [nip59Wrap] (nym-crypto.js `pqNip59Wrap`); local keys only.
NostrEvent pqNip59Wrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  required Uint8List recipientKemPublicKey,
  int? expiration,
}) {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

  // Seal (kind 13) signed by the real sender key.
  final seal = finalizeEvent(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: pq.pqEncrypt(jsonEncode(rumorMap), senderPrivkey, recipientPubkey,
          recipientKemPublicKey),
    ),
    senderPrivkey,
  );

  // Wrap (kind 1059) signed by a fresh ephemeral key.
  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: pq.pqEncrypt(jsonEncode(seal.toJson()), ephSk, recipientPubkey,
          recipientKemPublicKey),
    ),
    ephSk,
  );
}

/// pq2 gift wrap: both NIP-59 layers, layered rather than combined.
Future<NostrEvent> pq2Nip59Wrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  required Uint8List recipientKemPublicKey,
  int? expiration,
}) async {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

  final seal = finalizeEvent(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: await pq.pq2Encrypt(jsonEncode(rumorMap), senderPrivkey,
          recipientPubkey, recipientKemPublicKey),
    ),
    senderPrivkey,
  );

  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: await pq.pq2Encrypt(jsonEncode(seal.toJson()), ephSk,
          recipientPubkey, recipientKemPublicKey),
    ),
    ephSk,
  );
}

/// Signer-driven [bitchatWrap]; seal content still needs the local key via `encryptBitchat`.
Future<NostrEvent> bitchatWrapAsync({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required EventSigner senderSigner,
  required String recipientPubkey,
  int? expiration,
}) async {
  // Seal content uses the local key; the seal signature goes through the signer.
  final senderPub = senderSigner.pubkey;
  final rumorMap = _buildRumorMap(rumor, senderPub);

  final seal = await senderSigner.sign(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: await bitchat.encryptBitchat(
          jsonEncode(rumorMap), senderPrivkey, recipientPubkey),
    ),
  );

  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: await bitchat.encryptBitchat(
          jsonEncode(seal.toJson()), ephSk, recipientPubkey),
    ),
    ephSk,
  );
}

/// Bitchat transport: seal and wrap content both use `encryptBitchat`.
Future<NostrEvent> bitchatWrap({
  required UnsignedEvent rumor,
  required Uint8List senderPrivkey,
  required String recipientPubkey,
  int? expiration,
}) async {
  final senderPub = getPublicKeyHex(senderPrivkey);
  final rumorMap = _buildRumorMap(rumor, senderPub);

  final seal = finalizeEvent(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: await bitchat.encryptBitchat(
          jsonEncode(rumorMap), senderPrivkey, recipientPubkey),
    ),
    senderPrivkey,
  );

  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
  ];
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: await bitchat.encryptBitchat(
          jsonEncode(seal.toJson()), ephSk, recipientPubkey),
    ),
    ephSk,
  );
}

/// A decrypt candidate; one with null KEM material simply cannot match a `pq1.` payload.
typedef UnwrapCandidate = ({
  Uint8List sk,
  bool bitchat,
  Uint8List? kemSk,
  Uint8List? kemPk,
});

UnwrapCandidate classicalCandidate(Uint8List sk, {bool bitchat = false}) =>
    (sk: sk, bitchat: bitchat, kemSk: null, kemPk: null);

bool _isV2(String? content) => content != null && content.startsWith('v2:');

/// Transport is chosen from the payload prefix (`pq1.`, `v2:`, else NIP-44), never from a tag; null if none match.
Future<
    ({
      NostrEvent seal,
      Map<String, dynamic> rumor,
      bool isBitchat,
      bool isPq
    })?> unwrapGiftWrap(
    NostrEvent wrap, List<UnwrapCandidate> candidates) async {
  for (final cand in candidates) {
    final sk = cand.sk;
    try {
      NostrEvent seal;
      Map<String, dynamic> rumor;
      var isBitchat = false;
      var isPq = false;

      if (pq.isPq2Payload(wrap.content)) {
        final kemSk = cand.kemSk, kemPk = cand.kemPk;
        if (kemSk == null || kemPk == null) continue;
        final self =
            pq.PqIdentity(privkey: sk, kemSecretKey: kemSk, kemPublicKey: kemPk);
        seal = NostrEvent.fromJson(
            jsonDecode(await pq.pq2Decrypt(wrap.content, wrap.pubkey, self))
                as Map<String, dynamic>);
        // A NIP-44 seal stays readable, as in the pq1 branch.
        final rumorJson = pq.isPq2Payload(seal.content)
            ? await pq.pq2Decrypt(seal.content, seal.pubkey, self)
            : nip44.decrypt(
                seal.content, nip44.getConversationKey(sk, seal.pubkey));
        rumor = jsonDecode(rumorJson) as Map<String, dynamic>;
        isPq = true;
      } else if (pq.isPqPayload(wrap.content)) {
        final kemSk = cand.kemSk, kemPk = cand.kemPk;
        if (kemSk == null || kemPk == null) continue;
        final self =
            pq.PqIdentity(privkey: sk, kemSecretKey: kemSk, kemPublicKey: kemPk);
        seal = NostrEvent.fromJson(
            jsonDecode(pq.pqDecrypt(wrap.content, wrap.pubkey, self))
                as Map<String, dynamic>);
        // Also accept a NIP-44 seal so a wrap-only variant stays readable.
        final rumorJson = pq.isPqPayload(seal.content)
            ? pq.pqDecrypt(seal.content, seal.pubkey, self)
            : nip44.decrypt(
                seal.content, nip44.getConversationKey(sk, seal.pubkey));
        rumor = jsonDecode(rumorJson) as Map<String, dynamic>;
        isPq = true;
      } else if (cand.bitchat && _isV2(wrap.content)) {
        final sealJson =
            await bitchat.decryptBitchat(wrap.content, wrap.pubkey, sk);
        seal =
            NostrEvent.fromJson(jsonDecode(sealJson) as Map<String, dynamic>);
        final rumorJson = _isV2(seal.content)
            ? await bitchat.decryptBitchat(seal.content, seal.pubkey, sk)
            : nip44.decrypt(
                seal.content,
                nip44.getConversationKey(sk, seal.pubkey),
              );
        rumor = jsonDecode(rumorJson) as Map<String, dynamic>;
        isBitchat = true;
      } else {
        final ckWrap = nip44.getConversationKey(sk, wrap.pubkey);
        seal = NostrEvent.fromJson(
            jsonDecode(nip44.decrypt(wrap.content, ckWrap))
                as Map<String, dynamic>);
        final ckSeal = nip44.getConversationKey(sk, seal.pubkey);
        rumor = jsonDecode(nip44.decrypt(seal.content, ckSeal))
            as Map<String, dynamic>;
      }

      return (seal: seal, rumor: rumor, isBitchat: isBitchat, isPq: isPq);
    } catch (_) {
    }
  }
  return null;
}

Future<NostrEvent> sealAndWrap({
  required UnsignedEvent rumor,
  required EventSigner signer,
  required String recipientPubkey,
  Uint8List? recipientKemPublicKey,
  int? expiration,
  List<List<String>> extraTags = const [],
}) async {
  final senderPub = signer.pubkey;
  final rumorJson = jsonEncode(_buildRumorMap(rumor, senderPub));
  final kem = recipientKemPublicKey;
  final inner = await signer.nip44Encrypt(recipientPubkey, rumorJson);
  final seal = await signer.sign(
    UnsignedEvent(
      pubkey: senderPub,
      createdAt: randomNow(),
      kind: 13,
      tags: const [],
      content: kem == null
          ? inner
          : await pq.pq2Seal(inner, senderPub, recipientPubkey, kem),
    ),
  );

  final ephSk = generatePrivateKey();
  final tags = <List<String>>[
    ['p', recipientPubkey],
    if (expiration != null && expiration != 0) ['expiration', '$expiration'],
    ...extraTags,
  ];
  final sealJson = jsonEncode(seal.toJson());
  return finalizeEvent(
    UnsignedEvent(
      pubkey: getPublicKeyHex(ephSk),
      createdAt: randomNow(),
      kind: 1059,
      tags: tags,
      content: kem == null
          ? nip44.encrypt(
              sealJson, nip44.getConversationKey(ephSk, recipientPubkey))
          : await pq.pq2Encrypt(sealJson, ephSk, recipientPubkey, kem),
    ),
    ephSk,
  );
}

typedef KemPair = ({Uint8List kemSk, Uint8List kemPk});

Future<({NostrEvent seal, Map<String, dynamic> rumor, bool isPq})?> unwrapWith(
    NostrEvent wrap, EventSigner signer, List<KemPair> kems) async {
  if (signer is LocalSigner) {
    final opened = await unwrapGiftWrap(wrap, [
      for (final k in kems)
        (sk: signer.privkey, bitchat: false, kemSk: k.kemSk, kemPk: k.kemPk),
      if (kems.isEmpty) classicalCandidate(signer.privkey),
    ]);
    return opened == null
        ? null
        : (seal: opened.seal, rumor: opened.rumor, isPq: opened.isPq);
  }
  Future<String> open(String content, String senderPk) async {
    if (pq.isPq2Payload(content)) {
      String? inner;
      for (final k in kems) {
        try {
          inner = await pq.pq2Open(
              content, senderPk, signer.pubkey, k.kemSk, k.kemPk);
          break;
        } catch (_) {}
      }
      if (inner == null) throw StateError('no kem key opened it');
      return signer.nip44Decrypt(senderPk, inner);
    }
    if (pq.isPqPayload(content)) throw StateError('pq1 needs a local key');
    return signer.nip44Decrypt(senderPk, content);
  }

  try {
    final seal = NostrEvent.fromJson(
        jsonDecode(await open(wrap.content, wrap.pubkey)) as Map<String, dynamic>);
    final rumor =
        jsonDecode(await open(seal.content, seal.pubkey)) as Map<String, dynamic>;
    return (seal: seal, rumor: rumor, isPq: pq.isPq2Payload(wrap.content));
  } catch (_) {
    return null;
  }
}
