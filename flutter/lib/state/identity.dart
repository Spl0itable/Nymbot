import 'dart:typed_data';

import 'package:convert/convert.dart' as convert;

import '../core/crypto/bech32_codec.dart' as bech32;
import '../core/crypto/keys.dart';
import '../core/crypto/ml_kem.dart';
import '../core/crypto/pq.dart' as pq;
import '../services/nostr/event_signer.dart';
import 'store.dart';
import '../features/i18n/i18n.dart';

/// The key, and the post-quantum root the ML-KEM keypair is derived from.
///
/// The root is generated independently of the signing key on purpose: the
/// signing pubkey is published on every wrap, so a KEM key derived from it
/// would fall with secp256k1.
class Identity {
  Identity(this._store);

  static const _skKey = 'nymbot_sk';
  static const _rootKey = 'nymbot_pq_root';

  final Store _store;

  Uint8List? _sk;
  Uint8List? _root;
  MlKemKeyPair? _kem;
  String? _pubkey;

  /// True when the account already advertises a KEM key this device cannot
  /// derive. Announcing over it would strand every other device, so we do not,
  /// and replies come back classical until the root is linked.
  bool rootLocked = false;

  bool get present => _sk != null;
  String get pubkey => _pubkey ?? '';
  Uint8List? get privkey => _sk;
  Uint8List? get kemPublicKey => _kem?.publicKey;
  MlKemKeyPair? get kem => _kem;
  LocalSigner get signer => LocalSigner(_sk!);

  pq.PqIdentity? get pqIdentity {
    final sk = _sk, kem = _kem;
    if (sk == null || kem == null) return null;
    return pq.PqIdentity(
      privkey: sk,
      kemSecretKey: kem.secretKey,
      kemPublicKey: kem.publicKey,
    );
  }

  Future<bool> restore() async {
    final skHex = await _store.secret(_skKey);
    if (skHex == null || skHex.isEmpty) return false;
    _adopt(Uint8List.fromList(convert.hex.decode(skHex)), await _readRoot());
    return true;
  }

  Future<Uint8List> _readRoot() async {
    final code = await _store.secret(_rootKey);
    if (code != null && code.isNotEmpty) {
      try {
        return bech32.decodeNymPq(code);
      } catch (_) {
        // Unreadable is not "no root": generating over it would split the
        // account. Fall through and let the announcement check lock us.
      }
    }
    final fresh = pq.pqGenerateRoot();
    await _store.setSecret(_rootKey, bech32.encodeNymPq(fresh));
    return fresh;
  }

  Future<String> generate() async {
    final sk = generatePrivateKey();
    final root = pq.pqGenerateRoot();
    await _persist(sk, root);
    _adopt(sk, root);
    return rootCode;
  }

  /// Accepts an `nsec1…` or a raw 64-character hex key.
  Future<void> import(String input) async {
    final text = input.trim();
    Uint8List sk;
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) {
      sk = Uint8List.fromList(convert.hex.decode(text.toLowerCase()));
    } else if (text.startsWith('nsec1')) {
      sk = bech32.decodeNsec(text);
    } else {
      throw FormatException(t('Paste an nsec, or its 64-character hex form.'));
    }
    final root = await _readRoot();
    await _persist(sk, root);
    _adopt(sk, root);
  }

  Future<void> _persist(Uint8List sk, Uint8List root) async {
    await _store.setSecret(_skKey, convert.hex.encode(sk));
    await _store.setSecret(_rootKey, bech32.encodeNymPq(root));
  }

  void _adopt(Uint8List sk, Uint8List root) {
    _sk = sk;
    _root = root;
    _pubkey = getPublicKeyHex(sk);
    try {
      _kem = pq.pqKeypairFromRoot(root, 0);
    } catch (_) {
      _kem = null;
    }
  }

  String get nsec => _sk == null ? '' : bech32.encodeNsecBytes(_sk!);
  String get npub => _pubkey == null ? '' : bech32.encodeNpub(_pubkey!);
  String get rootCode => _root == null ? '' : bech32.encodeNymPq(_root!);
  String get rootFingerprint =>
      _root == null ? '' : pq.pqRootFingerprint(_root!);

  /// Links this device to an existing account's root, pasted from the other
  /// app's identity settings.
  Future<void> adoptRootCode(String code) async {
    final bytes = bech32.decodeNymPq(code.trim());
    _root = bytes;
    _kem = pq.pqKeypairFromRoot(bytes, 0);
    rootLocked = false;
    await _store.setSecret(_rootKey, bech32.encodeNymPq(bytes));
  }

  void forget() {
    _sk = null;
    _root = null;
    _kem = null;
    _pubkey = null;
    rootLocked = false;
  }
}
