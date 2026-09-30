import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../../core/crypto/keys.dart' as keys;
import '../../core/crypto/nip44.dart' as nip44;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../features/i18n/i18n.dart';
import '../../models/nostr_event.dart';

/// Signs and runs NIP-44 for the active identity, locally or via a NIP-46 remote signer.
abstract class EventSigner {
  /// 64-char hex author pubkey.
  String get pubkey;

  Future<NostrEvent> sign(UnsignedEvent unsigned);

  Future<String> nip44Encrypt(String peerPubkey, String plaintext);

  Future<String> nip44Decrypt(String peerPubkey, String ciphertext);

  /// Always false here; the wrap paths branch on it.
  bool get isRemote;
}

class LocalSigner implements EventSigner {
  LocalSigner(this._privkey) : _pubkey = keys.getPublicKeyHex(_privkey);

  final Uint8List _privkey;
  final String _pubkey;

  /// Exposed so the wrap and unwrap paths can use the local key directly.
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

abstract class RemoteSigner implements EventSigner {
  String get method;

  Map<String, dynamic> get session;

  Future<void> close();
}

class SignerFailure implements Exception {
  const SignerFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

NostrEvent checkSigned(UnsignedEvent asked, NostrEvent got, String pubkey) {
  final same = got.pubkey == pubkey &&
      got.kind == asked.kind &&
      got.createdAt == asked.createdAt &&
      got.content == asked.content &&
      jsonEncode(got.tags) == jsonEncode(asked.tags);
  if (!same || got.id != got.computeId() || !schnorr.verifyEvent(got)) {
    throw SignerFailure(
        t('Your signer returned a signature that does not match, so it was not used.'));
  }
  return got;
}

class QueuedSigner implements EventSigner {
  QueuedSigner(this.inner, {ValueNotifier<bool>? waiting, this.slow = const Duration(seconds: 1)})
      : waiting = waiting ?? ValueNotifier<bool>(false);

  final RemoteSigner inner;
  final ValueNotifier<bool> waiting;
  final Duration slow;

  Future<void> _tail = Future<void>.value();
  int _late = 0;

  @override
  String get pubkey => inner.pubkey;

  @override
  bool get isRemote => true;

  Future<T> _queued<T>(Future<T> Function() body) {
    var counted = false;
    final timer = Timer(slow, () {
      counted = true;
      _late++;
      waiting.value = true;
    });
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (_) {});
    return run.whenComplete(() {
      timer.cancel();
      if (counted) {
        _late--;
        if (_late == 0) waiting.value = false;
      }
    });
  }

  @override
  Future<NostrEvent> sign(UnsignedEvent unsigned) => _queued(() async {
        final asked = UnsignedEvent(
          pubkey: inner.pubkey,
          createdAt: unsigned.createdAt,
          kind: unsigned.kind,
          tags: unsigned.tags,
          content: unsigned.content,
        );
        return checkSigned(asked, await inner.sign(asked), inner.pubkey);
      });

  @override
  Future<String> nip44Encrypt(String peerPubkey, String plaintext) =>
      _queued(() => inner.nip44Encrypt(peerPubkey, plaintext));

  @override
  Future<String> nip44Decrypt(String peerPubkey, String ciphertext) =>
      _queued(() => inner.nip44Decrypt(peerPubkey, ciphertext));
}
