import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart' as convert;
import 'package:flutter/foundation.dart' show ValueNotifier;

import '../core/crypto/bech32_codec.dart' as bech32;
import '../core/crypto/keys.dart';
import '../core/crypto/ml_kem.dart';
import '../core/crypto/pq.dart' as pq;
import '../services/nostr/event_signer.dart';
import 'store.dart';
import '../features/i18n/i18n.dart';

/// The PQ root is independent of the signing key, so the KEM key does not fall with secp256k1.
typedef SignerRestore = RemoteSigner? Function(Map<String, dynamic> session);

class Identity {
  Identity(this._store, {SignerRestore? restoreSigner})
      : _restoreSigner = restoreSigner ?? ((_) => null);

  static const _skKey = 'nymbot_sk';
  static const _signerKey = 'nymbot_signer';
  static const _rootKey = 'nymbot_pq_root';
  static const _epochKey = 'nymbot_pq_epoch';

  final Store _store;
  final SignerRestore _restoreSigner;

  final ValueNotifier<bool> waiting = ValueNotifier<bool>(false);

  Uint8List? _sk;
  RemoteSigner? _remote;
  QueuedSigner? _queued;
  Uint8List? _root;
  MlKemKeyPair? _kem;
  String? _pubkey;

  /// Root epoch the KEM key is derived at; rotation happens in Nymchat.
  int _epoch = 0;

  /// The account advertises a KEM key we cannot derive; we do not announce over it.
  bool rootLocked = false;

  bool _rootUnreadable = false;

  bool get rootUnreadable => _rootUnreadable;

  static const int epochScan = 12;
  static const int previousEpochs = 3;

  bool get present => _sk != null || _remote != null;
  bool get hasNsec => _sk != null;
  String get method => _sk != null ? 'local' : (_remote?.method ?? '');
  String get pubkey => _pubkey ?? '';
  Uint8List? get privkey => _sk;
  Uint8List? get root => _root;
  int get epoch => _epoch;
  Uint8List? get kemPublicKey => _kem?.publicKey;
  MlKemKeyPair? get kem => _kem;
  EventSigner get signer => _sk != null ? LocalSigner(_sk!) : _queued!;

  RemoteSigner? get remote => _remote;

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
    if (skHex == null || skHex.isEmpty) return _restoreRemote();
    _epoch = _store.getInt(_epochKey);
    _adopt(Uint8List.fromList(convert.hex.decode(skHex)), await _readRoot());
    return true;
  }

  Future<bool> _restoreRemote() async {
    final raw = await _store.secret(_signerKey);
    if (raw == null || raw.isEmpty) return false;
    RemoteSigner? made;
    try {
      final session = jsonDecode(raw);
      if (session is Map<String, dynamic>) made = _restoreSigner(session);
    } catch (_) {
      made = null;
    }
    if (made == null || made.pubkey.isEmpty) return false;
    _epoch = _store.getInt(_epochKey);
    _adoptRemote(made, await _readRoot());
    return true;
  }

  Future<void> useSigner(RemoteSigner remote, {Uint8List? root, int epoch = 0}) async {
    _epoch = epoch < 0 ? 0 : epoch;
    await _store.dropSecret(_skKey);
    await _store.setSecret(_signerKey, jsonEncode(remote.session));
    await _store.setInt(_epochKey, _epoch);
    if (root == null) {
      await _store.dropSecret(_rootKey);
    } else {
      await _store.setSecret(_rootKey, bech32.encodeNymPq(root));
    }
    _adoptRemote(remote, root);
    rootLocked = root == null;
  }

  Future<void> disconnect() async {
    await _store.dropSecret(_signerKey);
    forget();
  }

  void _adoptRemote(RemoteSigner remote, Uint8List? root) {
    _sk = null;
    _remote = remote;
    _queued = QueuedSigner(remote, waiting: waiting);
    _root = root;
    _pubkey = remote.pubkey;
    _deriveKem();
  }

  /// Never mints: that decision belongs to whoever asked D1 about the account.
  Future<Uint8List?> _readRoot() async {
    final code = await _store.secret(_rootKey);
    _rootUnreadable = false;
    if (code == null || code.isEmpty) return null;
    try {
      return bech32.decodeNymPq(code);
    } catch (_) {
      // Unreadable is not "no root": generating over it would split the account.
      _rootUnreadable = true;
      return null;
    }
  }

  Uint8List? kemAt(int epoch) {
    final root = _root;
    if (root == null) return null;
    try {
      return pq.pqKeypairFromRoot(root, epoch < 0 ? 0 : epoch).publicKey;
    } catch (_) {
      return null;
    }
  }

  int? epochMatching(Uint8List announced, {int? hint}) {
    if (_root == null) return null;
    final order = <int>[
      if (hint != null && hint >= 0) hint,
      for (var e = 0; e <= epochScan; e++) e,
    ];
    final tried = <int>{};
    for (final epoch in order) {
      if (!tried.add(epoch)) continue;
      final pk = kemAt(epoch);
      if (pk != null && _sameBytes(pk, announced)) return epoch;
    }
    return null;
  }

  Future<void> adoptEpoch(int epoch) async {
    final next = epoch < 0 ? 0 : epoch;
    if (next == _epoch && _kem != null) return;
    _epoch = next;
    _deriveKem();
    await _store.setInt(_epochKey, _epoch);
  }

  List<({Uint8List kemSk, Uint8List kemPk})> kemCandidates() {
    final out = <({Uint8List kemSk, Uint8List kemPk})>[];
    final floor = _epoch - previousEpochs < 0 ? 0 : _epoch - previousEpochs;
    final root = _root;
    if (root != null) {
      for (var e = _epoch; e >= floor; e--) {
        try {
          final kp = pq.pqKeypairFromRoot(root, e);
          out.add((kemSk: kp.secretKey, kemPk: kp.publicKey));
        } catch (_) {}
      }
    }
    final sk = _sk;
    if (sk != null) {
      for (var e = _epoch; e >= floor; e--) {
        try {
          final kp = pq.pqKeypairFromPrivkey(sk, e);
          out.add((kemSk: kp.secretKey, kemPk: kp.publicKey));
        } catch (_) {}
      }
    }
    return out;
  }

  List<pq.PqIdentity> pqCandidates() {
    final sk = _sk;
    if (sk == null) return const [];
    return [
      for (final c in kemCandidates())
        pq.PqIdentity(privkey: sk, kemSecretKey: c.kemSk, kemPublicKey: c.kemPk),
    ];
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Either holds the root or knows it needs the code.
  bool get rootSettled => _root != null || rootLocked;

  Future<String> generate({Uint8List? secret, Uint8List? root}) async {
    final sk = secret ?? generatePrivateKey();
    root ??= pq.pqGenerateRoot();
    _epoch = 0;
    await _persist(sk, root);
    _adopt(sk, root);
    return rootCode;
  }

  /// Accepts `nsec1…` or 64-char hex; a null [root] means the account has not been checked yet.
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

  /// Reads a key without adopting it.
  Uint8List readSecret(String input) {
    final text = input.trim();
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(text)) {
      return Uint8List.fromList(convert.hex.decode(text.toLowerCase()));
    }
    if (text.startsWith('nsec1')) return bech32.decodeNsec(text);
    throw FormatException(t('Paste an nsec, or its 64-character hex form.'));
  }

  /// Mints a root for an account confirmed to have none.
  Future<String> mintRoot() async {
    final root = pq.pqGenerateRoot();
    _rootUnreadable = false;
    _epoch = 0;
    await _store.setInt(_epochKey, 0);
    await _store.setSecret(_rootKey, bech32.encodeNymPq(root));
    _root = root;
    _deriveKem();
    rootLocked = false;
    return rootCode;
  }

  Future<void> _persist(Uint8List sk, Uint8List? root) async {
    await _store.dropSecret(_signerKey);
    await _store.setSecret(_skKey, convert.hex.encode(sk));
    await _store.setInt(_epochKey, _epoch);
    if (root == null) {
      // A root left from another identity opens nothing of this one.
      await _store.dropSecret(_rootKey);
      return;
    }
    await _store.setSecret(_rootKey, bech32.encodeNymPq(root));
  }

  void _adopt(Uint8List sk, Uint8List? root) {
    _dropRemote();
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

  /// Links this device to an existing root pasted from the other app.
  Future<void> adoptRootCode(String code, {int? epoch}) async {
    final bytes = bech32.decodeNymPq(code.trim());
    if (epoch != null) _epoch = epoch < 0 ? 0 : epoch;
    _root = bytes;
    _rootUnreadable = false;
    _deriveKem();
    rootLocked = false;
    await _store.setInt(_epochKey, _epoch);
    await _store.setSecret(_rootKey, bech32.encodeNymPq(bytes));
  }

  /// Null on a wrong prefix, bad checksum or wrong length.
  static Uint8List? rootFromCode(String code) {
    try {
      final bytes = bech32.decodeNymPq(code.trim());
      return bytes.length == pq.pqRootLength ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  /// Fingerprint of a pasted code, without adopting it.
  static String? fingerprintOfCode(String code) {
    try {
      return pq.pqRootFingerprint(bech32.decodeNymPq(code.trim()));
    } catch (_) {
      return null;
    }
  }

  /// KEM key a code would produce at [epoch], without adopting it.
  static Uint8List? kemForCode(String code, int epoch) {
    try {
      return pq
          .pqKeypairFromRoot(bech32.decodeNymPq(code.trim()), epoch)
          .publicKey;
    } catch (_) {
      return null;
    }
  }

  void _dropRemote() {
    final remote = _remote;
    _remote = null;
    _queued = null;
    waiting.value = false;
    if (remote != null) unawaited(remote.close().catchError((_) {}));
  }

  void forget() {
    _dropRemote();
    _sk = null;
    _root = null;
    _kem = null;
    _pubkey = null;
    _epoch = 0;
    _rootUnreadable = false;
    rootLocked = false;
  }
}
