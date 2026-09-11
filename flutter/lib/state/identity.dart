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
  static const _epochKey = 'nymbot_pq_epoch';

  final Store _store;

  Uint8List? _sk;
  Uint8List? _root;
  MlKemKeyPair? _kem;
  String? _pubkey;

  /// Which epoch of the root this account's KEM key is derived at. Rotation
  /// happens in Nymchat; this device follows whatever the account advertises.
  int _epoch = 0;

  /// True when the account already advertises a KEM key this device cannot
  /// derive. Announcing over it would strand every other device, so we do not,
  /// and replies come back classical until the root is linked.
  bool rootLocked = false;

  bool get present => _sk != null;
  String get pubkey => _pubkey ?? '';
  Uint8List? get privkey => _sk;
  Uint8List? get root => _root;
  int get epoch => _epoch;
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
    _epoch = _store.getInt(_epochKey);
    _adopt(Uint8List.fromList(convert.hex.decode(skHex)), await _readRoot());
    return true;
  }

  /// The root this device already holds, or null. Deliberately does not mint
  /// one: minting is a decision about the ACCOUNT, and it belongs to whoever
  /// has asked D1 whether the account already has one.
  Future<Uint8List?> _readRoot() async {
    final code = await _store.secret(_rootKey);
    if (code == null || code.isEmpty) return null;
    try {
      return bech32.decodeNymPq(code);
    } catch (_) {
      // Unreadable is not "no root": generating over it would split the
      // account. Say nothing and let the record check decide.
      return null;
    }
  }

  /// Whether this device has settled what the account's root is — either it
  /// holds it, or it knows it must be given the code.
  bool get rootSettled => _root != null || rootLocked;

  Future<String> generate() async {
    final sk = generatePrivateKey();
    final root = pq.pqGenerateRoot();
    _epoch = 0;
    await _persist(sk, root);
    _adopt(sk, root);
    return rootCode;
  }

  /// Accepts an `nsec1…` or a raw 64-character hex key.
  ///
  /// [root] decides the post-quantum half. Minting one unasked is wrong for a
  /// key that has been used before: the account's announcement is replaceable,
  /// so a second root published over the first strands every settings row,
  /// every synced conversation and every reply sealed to the one it replaced.
  /// The caller looks the account up first and passes null to say "not yet".
  Future<void> import(String input, {Uint8List? root, int epoch = 0}) async {
    final text = input.trim();
    Uint8List sk;
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) {
      sk = Uint8List.fromList(convert.hex.decode(text.toLowerCase()));
    } else if (text.startsWith('nsec1')) {
      sk = bech32.decodeNsec(text);
    } else {
      throw FormatException(t('Paste an nsec, or its 64-character hex form.'));
    }
    _epoch = epoch < 0 ? 0 : epoch;
    await _persist(sk, root);
    _adopt(sk, root);
    rootLocked = root == null;
  }

  /// Reads a key without adopting it, so the caller can ask what the account
  /// already has before deciding what root to give it.
  Uint8List readSecret(String input) {
    final text = input.trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) {
      return Uint8List.fromList(convert.hex.decode(text.toLowerCase()));
    }
    if (text.startsWith('nsec1')) return bech32.decodeNsec(text);
    throw FormatException(t('Paste an nsec, or its 64-character hex form.'));
  }

  /// Mints one now, for an account that turns out not to have one.
  Future<String> mintRoot() async {
    final root = pq.pqGenerateRoot();
    _epoch = 0;
    await _store.setInt(_epochKey, 0);
    await _store.setSecret(_rootKey, bech32.encodeNymPq(root));
    _root = root;
    _deriveKem();
    rootLocked = false;
    return rootCode;
  }

  Future<void> _persist(Uint8List sk, Uint8List? root) async {
    await _store.setSecret(_skKey, convert.hex.encode(sk));
    await _store.setInt(_epochKey, _epoch);
    if (root == null) {
      // A root left over from another identity opens nothing this one saved.
      await _store.dropSecret(_rootKey);
      return;
    }
    await _store.setSecret(_rootKey, bech32.encodeNymPq(root));
  }

  void _adopt(Uint8List sk, Uint8List? root) {
    _sk = sk;
    _root = root;
    _pubkey = getPublicKeyHex(sk);
    _deriveKem();
  }

  void _deriveKem() {
    final root = _root;
    if (root == null) {
      _kem = null;
      return;
    }
    try {
      _kem = pq.pqKeypairFromRoot(root, _epoch);
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
  Future<void> adoptRootCode(String code, {int? epoch}) async {
    final bytes = bech32.decodeNymPq(code.trim());
    if (epoch != null) _epoch = epoch < 0 ? 0 : epoch;
    _root = bytes;
    _deriveKem();
    rootLocked = false;
    await _store.setInt(_epochKey, _epoch);
    await _store.setSecret(_rootKey, bech32.encodeNymPq(bytes));
  }

  /// The root a pasted `nympq1…` code carries, or null on a wrong prefix, bad
  /// checksum or wrong length. Adopting a wrong root is worse than adopting
  /// none.
  static Uint8List? rootFromCode(String code) {
    try {
      final bytes = bech32.decodeNymPq(code.trim());
      return bytes.length == pq.pqRootLength ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  /// The fingerprint a pasted code would carry, without adopting it — so it can
  /// be checked against the one the account recorded.
  static String? fingerprintOfCode(String code) {
    try {
      return pq.pqRootFingerprint(bech32.decodeNymPq(code.trim()));
    } catch (_) {
      return null;
    }
  }

  /// The KEM key a given code would produce at [epoch], without adopting it —
  /// so a pasted code can be checked against what the account advertises.
  static Uint8List? kemForCode(String code, int epoch) {
    try {
      return pq
          .pqKeypairFromRoot(bech32.decodeNymPq(code.trim()), epoch)
          .publicKey;
    } catch (_) {
      return null;
    }
  }

  void forget() {
    _sk = null;
    _root = null;
    _kem = null;
    _pubkey = null;
    _epoch = 0;
    rootLocked = false;
  }
}
