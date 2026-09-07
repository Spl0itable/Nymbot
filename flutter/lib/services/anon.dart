import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart' as convert;

import '../core/crypto/keys.dart';
import '../core/crypto/ml_kem.dart';
import '../core/crypto/pq.dart' as pq;
import '../core/crypto/voucher.dart';
import '../models/nostr_event.dart';
import '../state/store.dart';
import 'nostr/event_signer.dart';
import 'nymbot_api.dart';
import 'pq_announce.dart';
import '../features/i18n/i18n.dart';

/// Anonymous mode: a throwaway key the whole conversation runs under, and blind
/// vouchers that move credits onto it without handing the worker the link.
///
/// Ported from the Nymchat client so both apps agree byte for byte — the domain
/// constants, the hash-to-curve, the DLEQ check and the denominations are all
/// part of the wire format (docs/ANON-NYMBOT-SPEC.md in nym-staging).
class AnonMode {
  AnonMode(this._store, this._api, this._pq);

  static const _stateKey = 'nymbot_anon_state';
  static const _keysetKey = 'nymbot_anon_keyset';
  static const _enabledKey = 'anon_enabled';
  static const _prevMax = 4;

  final Store _store;
  final NymbotApi _api;
  final PqAnnounce _pq;

  Map<String, dynamic> _state = {'current': null, 'prev': [], 'tokens': [], 'pending': null};
  Map<String, dynamic>? _keyset;
  NostrEvent? _annCache;

  /// Asked before using a keyset that changed since credits last moved: a
  /// per-user keyset is exactly how a mint would tag its users, so it is the
  /// user's call, not ours.
  Future<bool> Function(String oldId, String newId)? onKeysetChange;

  bool get enabled => _store.getBool(_enabledKey);
  bool get ready => enabled && _state['current'] != null;
  String? get pubkey => (_state['current'] as Map?)?['pk'] as String?;

  Future<void> load() async {
    final raw = await _store.secret(_stateKey);
    if (raw == null || raw.isEmpty) return;
    try {
      _state = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
  }

  Future<void> _save() => _store.setSecret(_stateKey, jsonEncode(_state));

  Future<void> setEnabled(bool on) async {
    await _store.setBool(_enabledKey, on);
    if (on) await ensure();
  }

  Map<String, dynamic> _newIdentity() {
    final sk = generatePrivateKey();
    return {
      'sk': convert.hex.encode(sk),
      'pk': getPublicKeyHex(sk),
      'root': convert.hex.encode(pq.pqGenerateRoot()),
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<Map<String, dynamic>> ensure() async {
    if (_state['current'] == null) {
      _state['current'] = _newIdentity();
      await _save();
    }
    return _state['current'] as Map<String, dynamic>;
  }

  Uint8List _skOf(Map<String, dynamic> id) =>
      Uint8List.fromList(convert.hex.decode(id['sk'] as String));

  /// Separate entropy from the signing key on purpose: the throwaway pubkey is
  /// published on every wrap, so a KEM key derived from it would fall with
  /// secp256k1.
  MlKemKeyPair? kemOf(Map<String, dynamic> id) {
    try {
      return pq.pqKeypairFromRoot(
          Uint8List.fromList(convert.hex.decode(id['root'] as String)), 0);
    } catch (_) {
      return null;
    }
  }

  Future<LocalSigner> signer() async => LocalSigner(_skOf(await ensure()));

  Future<pq.PqIdentity?> recipient() async {
    final id = await ensure();
    final kem = kemOf(id);
    if (kem == null) return null;
    return pq.PqIdentity(
      privkey: _skOf(id),
      kemSecretKey: kem.secretKey,
      kemPublicKey: kem.publicKey,
    );
  }

  /// A signed announcement carrying the throwaway KEM key, handed to the worker
  /// with each request so the reply comes back hybrid without a lookup that
  /// would have nothing to find.
  Future<NostrEvent?> announcement() async {
    final id = await ensure();
    final kem = kemOf(id);
    if (kem == null) return null;
    final cached = _annCache;
    if (cached != null && cached.pubkey == id['pk']) {
      final exp = int.tryParse(
              cached.tags.firstWhere((t) => t.first == 'expiration',
                  orElse: () => const ['expiration', '0'])[1]) ??
          0;
      if (exp > DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600) {
        return cached;
      }
    }
    final built = await _pq.build(LocalSigner(_skOf(id)), kem);
    _annCache = built;
    return built;
  }

  Future<int> rotate({bool sweep = true}) async {
    final old = _state['current'] as Map<String, dynamic>?;
    if (old != null) {
      final prev = List<dynamic>.from(_state['prev'] as List? ?? const []);
      prev.insert(0, old);
      _state['prev'] = prev.take(_prevMax).toList();
    }
    _state['current'] = _newIdentity();
    _annCache = null;
    await _save();
    if (!sweep || old == null) return 0;
    // The worker sees one anonymous key paying another, which is the
    // documented limit of this mode.
    final res = await _api.transferCredits(
        LocalSigner(_skOf(old)), (_state['current'] as Map)['pk'] as String);
    return res.data['error'] == null ? 1 : 0;
  }

  // --- vouchers ---------------------------------------------------------------

  Future<Map<String, dynamic>> keyset(EventSigner identity,
      {bool force = false}) async {
    final cached = _keyset;
    if (cached != null && !force) return cached;
    final res = await _api.voucherKeys(identity);
    final data = res.data;
    if (res.status >= 400 || data['error'] != null || data['keys'] == null) {
      throw StateError((data['error'] as String?) ?? 'Voucher keys are unavailable.');
    }
    final pinned = _store.getString(_keysetKey);
    final id = data['keysetId'] as String;
    if (pinned != null && pinned != id) {
      final ok = await (onKeysetChange?.call(pinned, id) ?? Future.value(false));
      if (!ok) throw StateError(t('Voucher keyset rejected.'));
    }
    await _store.setString(_keysetKey, id);
    _keyset = data;
    return data;
  }

  List<Map<String, dynamic>> _tokens(String tier) =>
      (_state['tokens'] as List? ?? const [])
          .cast<Map<String, dynamic>>()
          .where((t) => (t['tier'] ?? 'standard') == tier)
          .toList();

  Future<void> _dropTokens(List<Map<String, dynamic>> batch) async {
    final gone = batch.map((t) => t['x']).toSet();
    _state['tokens'] = (_state['tokens'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .where((t) => !gone.contains(t['x']))
        .toList();
    await _save();
  }

  /// Finishes an issuance whose response was lost: the same reqId and the same
  /// outputs re-sign without a second debit.
  Future<void> _finishIssue(
      EventSigner identity, Map<String, dynamic> pending) async {
    final keys = await keyset(identity);
    final tier = pending['tier'] as String;
    final outputs = (pending['outputs'] as List).cast<Map<String, dynamic>>();
    final res = await _api.voucherIssue(identity, {
      'tier': tier,
      'reqId': pending['reqId'],
      'outputs': outputs.map((o) => {'d': o['d'], 'B': o['B']}).toList(),
    });
    final data = res.data;
    if (res.status >= 400 || data['error'] != null) {
      if (res.status >= 400 && res.status < 500 && data['insufficient'] != true) {
        _state['pending'] = null;
        await _save();
      }
      throw StateError((data['error'] as String?) ?? 'Could not issue vouchers.');
    }
    if (data['insufficient'] == true) {
      _state['pending'] = null;
      await _save();
      final vars = {'have': data['balance'], 'need': data['required']};
      throw StateError(tier == 'pro'
          ? t('Not enough Pro credits on your nym — {have} left, {need} needed.',
              vars)
          : t('Not enough credits on your nym — {have} left, {need} needed.',
              vars));
    }
    final sigs = (data['signatures'] as List? ?? const []).cast<Map<String, dynamic>>();
    if (sigs.length != outputs.length) {
      throw StateError(t('The voucher response did not match the request.'));
    }
    final tokens = <Map<String, dynamic>>[];
    for (var i = 0; i < sigs.length; i++) {
      final out = outputs[i];
      final sig = sigs[i];
      if ((sig['d'] as num).toInt() != out['d']) {
        throw StateError(t('Voucher denomination mismatch.'));
      }
      final keyHex = ((keys['keys'] as Map)[tier] as Map?)?['${out['d']}'] as String?;
      if (keyHex == null) throw StateError(t('Unknown voucher denomination.'));
      final proven = voucherVerifyDleq(
        keyHex: keyHex,
        blindedHex: out['B'] as String,
        signatureHex: sig['C'] as String,
        e: sig['e'] as String,
        s: sig['s'] as String,
      );
      if (!proven) {
        throw StateError(t('Nymbot returned a voucher signature it could not prove. '
            'Refusing it — an unprovable signature can be used to tag you. '
            'Nothing was spent anonymously.'));
      }
      final unblinded = voucherUnblind(
        voucherPointFromHex(sig['C'] as String),
        voucherPointFromHex(keyHex),
        BigInt.parse(out['r'] as String, radix: 16),
      );
      tokens.add({
        'd': out['d'],
        'x': out['x'],
        'C': voucherPointHex(unblinded),
        'tier': tier,
      });
    }
    _state['tokens'] =
        [...(_state['tokens'] as List? ?? const []), ...tokens];
    _state['pending'] = null;
    await _save();
  }

  Future<int> _redeem(String tier) async {
    final tokens = _tokens(tier);
    if (tokens.isEmpty) return 0;
    final claimed = tokens.where((t) => t['redeemId'] != null).toList();
    String redeemId;
    List<Map<String, dynamic>> batch;
    if (claimed.isNotEmpty) {
      redeemId = claimed.first['redeemId'] as String;
      batch = tokens.where((t) => t['redeemId'] == redeemId).take(voucherMaxOutputs).toList();
    } else {
      redeemId = bytesToHex(randomBytes(32));
      batch = tokens.take(voucherMaxOutputs).toList();
      for (final t in batch) {
        t['redeemId'] = redeemId;
      }
      await _save();
    }
    final res = await _api.voucherRedeem(await signer(), {
      'tier': tier,
      'redeemId': redeemId,
      'tokens': batch.map((t) => {'d': t['d'], 'x': t['x'], 'C': t['C']}).toList(),
    });
    final data = res.data;
    if (res.status >= 400 || data['error'] != null) {
      if (data['alreadySpent'] == true) await _dropTokens(batch);
      throw StateError((data['error'] as String?) ?? 'Could not redeem vouchers.');
    }
    await _dropTokens(batch);
    return (data['credited'] as num?)?.toInt() ?? 0;
  }

  /// Resumes anything a previous session left half-done.
  Future<void> flush({EventSigner? identity}) async {
    if (!ready || identity == null) return;
    if (_state['pending'] == null && _tokens('standard').isEmpty && _tokens('pro').isEmpty) {
      return;
    }
    try {
      final pending = _state['pending'] as Map<String, dynamic>?;
      if (pending != null) await _finishIssue(identity, pending);
      for (final tier in const ['standard', 'pro']) {
        while (_tokens(tier).isNotEmpty) {
          await _redeem(tier);
        }
      }
    } catch (_) {
      // Left in place; the next flush picks it up.
    }
  }

  Future<int> moveCredits(EventSigner identity, int amount, String tier) async {
    if (amount <= 0) throw StateError(t('Enter how many credits to move.'));
    final denoms = voucherSplitAmount(amount);
    if (denoms == null) {
      throw StateError(t('That amount needs too many vouchers — move a smaller amount.'));
    }
    await ensure();
    await keyset(identity);
    final stale = _state['pending'] as Map<String, dynamic>?;
    if (stale != null) await _finishIssue(identity, stale);

    final outputs = denoms.map((d) {
      final x = randomBytes(32);
      final r = voucherRandomScalar();
      return {
        'd': d,
        'x': bytesToHex(x),
        'r': voucherScalarHex(r),
        'B': voucherPointHex(voucherBlind(x, r)),
      };
    }).toList();

    // Persisted BEFORE the call: a lost response has to be retried with the
    // same reqId and the same outputs, or it pays twice.
    _state['pending'] = {
      'tier': tier,
      'reqId': bytesToHex(randomBytes(32)),
      'outputs': outputs,
    };
    await _save();
    await _finishIssue(identity, _state['pending'] as Map<String, dynamic>);

    var credited = 0;
    while (_tokens(tier).isNotEmpty) {
      credited += await _redeem(tier);
    }
    return credited;
  }
}
