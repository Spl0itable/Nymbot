import 'dart:typed_data';

import '../../core/crypto/keys.dart' as keys;
import '../../core/crypto/nip44.dart' as nip44;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../models/nostr_event.dart';

/// Abstracts how the active identity signs events and runs NIP-44
/// encrypt/decrypt for its *own* key. Mirrors the PWA's `signEvent` dispatch by
/// `nostrLoginMethod` (nostr-core.js): a local secret key signs with
/// `finalizeEvent` / NIP-44 directly, while a NIP-46 remote signer round-trips
/// the `sign_event` / `nip44_encrypt` / `nip44_decrypt` RPCs.
///
/// The crypto is synchronous; the methods are async so the wrap paths read the
/// same whatever holds the key.
abstract class EventSigner {
  /// The identity (author) pubkey events are signed as. 64-char hex.
  String get pubkey;

  /// Signs [unsigned] with the identity key, returning the signed event.
  Future<NostrEvent> sign(UnsignedEvent unsigned);

  /// NIP-44 encrypts [plaintext] to [peerPubkey] using the identity key's
  /// conversation key (the PWA's `nip44.encrypt(getConversationKey(sk, peer))`
  /// for local, or the `nip44_encrypt` RPC for remote).
  Future<String> nip44Encrypt(String peerPubkey, String plaintext);

  /// NIP-44 decrypts [ciphertext] from [peerPubkey] using the identity key.
  Future<String> nip44Decrypt(String peerPubkey, String ciphertext);

  /// Always false here; the wrap paths branch on it.
  bool get isRemote;
}

/// Local-key signer: `sign` = `schnorr.finalizeEvent`, NIP-44 via
/// `getConversationKey(privkey, peer)` + encrypt/decrypt. The crypto is
/// synchronous; we wrap it in a resolved Future to satisfy [EventSigner].
class LocalSigner implements EventSigner {
  LocalSigner(this._privkey) : _pubkey = keys.getPublicKeyHex(_privkey);

  final Uint8List _privkey;
  final String _pubkey;

  /// The underlying secret key. Exposed so the wrap path (and unwrap
  /// candidate list) can keep using the local key directly where the PWA does.
  Uint8List get privkey => _privkey;

  @override
  String get pubkey => _pubkey;

  @override
  bool get isRemote => false;

  @override
  Future<NostrEvent> sign(UnsignedEvent unsigned) async =>
      schnorr.finalizeEvent(unsigned, _privkey);

  @override
  Future<String> nip44Encrypt(String peerPubkey, String plaintext) async {
    final ck = nip44.getConversationKey(_privkey, peerPubkey);
    return nip44.encrypt(plaintext, ck);
  }

  @override
  Future<String> nip44Decrypt(String peerPubkey, String ciphertext) async {
    final ck = nip44.getConversationKey(_privkey, peerPubkey);
    return nip44.decrypt(ciphertext, ck);
  }
}
