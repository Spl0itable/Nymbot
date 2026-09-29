import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart' as convert;

import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart';
import '../core/crypto/ml_kem.dart';
import '../core/crypto/pq.dart' as pq;
import '../core/crypto/voucher.dart';
import '../models/conversation.dart';
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
  static const _balancesKey = 'nymbot_anon_balances';
  static const _keysetKey = 'nymbot_anon_keyset';
  static const _enabledKey = 'anon_enabled';
  static const _prevMax = 4;
  static const syncKeysMax = 32;
  static const syncTokensMax = 512;
  static const syncSpentMax = 1024;

  final Store _store;
  final NymbotApi _api;
  final PqAnnounce _pq;

  Map<String, dynamic> _state = {'current': null, 'prev': [], 'tokens': [], 'pending': null};
  Map<String, dynamic>? _keyset;
  final Map<String, NostrEvent> _annCache = {};

  /// Asked before using a keyset that changed since credits last moved: a
  /// per-user keyset is exactly how a mint would tag its users, so it is the
  /// user's call, not ours.
  Future<bool> Function(String oldId, String newId)? onKeysetChange;

  bool get enabled => _store.getBool(_enabledKey);
  bool get ready => enabled && _state['current'] != null;
  String? get pubkey => (_state['current'] as Map?)?['pk'] as String?;

  Future<void> load() async {
    final known = await _store.secret(_balancesKey);
    if (known != null && known.isNotEmpty) {
      try {
        _balances = (jsonDecode(known) as Map).cast<String, dynamic>();
      } catch (_) {}
    }
    final raw = await _store.secret(_stateKey);
    if (raw == null || raw.isEmpty) return;
    try {
      _state = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
  }

  Map<String, dynamic> _balances = {};

  ({double? standard, double? pro}) lastBalance(String? pk) {
    final held = pk == null ? null : _balances[pk];
    if (held is! Map) return (standard: null, pro: null);
    return (
      standard: (held['standard'] as num?)?.toDouble(),
      pro: (held['pro'] as num?)?.toDouble(),
    );
  }

  Future<void> noteBalance(String? pk, {double? standard, double? pro}) async {
    if (pk == null || (standard == null && pro == null)) return;
    final was = _balances[pk];
    final entry = was is Map ? was.cast<String, dynamic>() : <String, dynamic>{};
    _balances[pk] = {
      ...entry,
      if (standard != null) 'standard': standard,
      if (pro != null) 'pro': pro,
    };
    try {
      await _store.setSecret(_balancesKey, jsonEncode(_balances));
    } catch (_) {}
  }

  Future<void> noteBalanceData(String? pk, Map<String, dynamic> data) {
    num? pick(String a, String b) =>
        (data[a] is num ? data[a] : data[b]) as num?;
    return noteBalance(pk,
        standard: pick('balanceCredits', 'balance')?.toDouble(),
        pro: pick('proBalanceCredits', 'proBalance')?.toDouble());
  }

  Future<void> _noteTier(String pk, String tier, Map<String, dynamic> data,
      {int delta = 0}) {
    final carried = (data['balanceCredits'] ?? data['balance']) as Object?;
    final known = tier == 'pro' ? lastBalance(pk).pro : lastBalance(pk).standard;
    final value = carried is num
        ? carried.toDouble()
        : (known == null || delta == 0 ? null : known + delta);
    return tier == 'pro'
        ? noteBalance(pk, pro: value)
        : noteBalance(pk, standard: value);
  }

  ({double? standard, double? pro}) knownTotals() {
    double? standard, pro;
    for (final id in held) {
      final last = lastBalance(id['pk'] as String?);
      if (last.standard != null) standard = (standard ?? 0) + last.standard!;
      if (last.pro != null) pro = (pro ?? 0) + last.pro!;
    }
    return (standard: standard, pro: pro);
  }

  Future<void> _save() =>
      _store.setSyncedSecret(_stateKey, jsonEncode(_state));

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

  static List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : <Map<String, dynamic>>[];

  List<Map<String, dynamic>> get held {
    final current = _state['current'];
    return [
      if (current is Map) current.cast<String, dynamic>(),
      ..._maps(_state['prev']),
    ];
  }

  Map<String, dynamic>? heldFor(String? pk) {
    if (pk == null || pk.isEmpty) return null;
    for (final id in held) {
      if (id['pk'] == pk) return id;
    }
    return null;
  }

  Future<Map<String, dynamic>> identityFor(String? pk) async =>
      heldFor(pk) ?? await ensure();

  Future<Map<String, dynamic>> bind(Conversation conv) async {
    final id = await identityFor(conv.anonPk);
    conv.anonPk = id['pk'] as String;
    return id;
  }

  Set<String> referenced() => {
        for (final c in _store.conversations())
          if (c.anonPk != null) c.anonPk!,
      };

  Uint8List _skOf(Map<String, dynamic> id) =>
      Uint8List.fromList(convert.hex.decode(id['sk'] as String));

  LocalSigner signerOf(Map<String, dynamic> id) => LocalSigner(_skOf(id));

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

  Future<LocalSigner> signer({String? pk}) async =>
      signerOf(await identityFor(pk));

  Future<pq.PqIdentity?> recipient({String? pk}) async {
    final id = await identityFor(pk);
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
  Future<NostrEvent?> announcement({String? pk}) async {
    final id = await identityFor(pk);
    final kem = kemOf(id);
    if (kem == null) return null;
    final cached = _annCache[id['pk']];
    if (cached != null) {
      final exp = int.tryParse(
              cached.tags.firstWhere((t) => t.first == 'expiration',
                  orElse: () => const ['expiration', '0'])[1]) ??
          0;
      if (exp > DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600) {
        return cached;
      }
    }
    final built = await _pq.build(signerOf(id), kem);
    _annCache[id['pk'] as String] = built;
    return built;
  }

  Future<({NostrEvent seal, Map<String, dynamic> rumor, bool isPq})?> open(
      NostrEvent wrap,
      {String? pk}) async {
    final to = wrap.tags
        .where((t) => t.length > 1 && t.first == 'p')
        .map((t) => t[1])
        .toSet();
    final ids = held;
    int rank(Map<String, dynamic> id) =>
        to.contains(id['pk']) ? 0 : (id['pk'] == pk ? 1 : 2);
    final order = [...ids]..sort((a, b) => rank(a).compareTo(rank(b)));
    for (final id in order) {
      final kem = kemOf(id);
      final opened = await giftwrap.unwrapWith(wrap, signerOf(id), [
        if (kem != null) (kemSk: kem.secretKey, kemPk: kem.publicKey),
      ]);
      if (opened != null) return opened;
    }
    return null;
  }

  List<Map<String, dynamic>> _kept(List<Map<String, dynamic>> prev, int max) {
    final keep = referenced();
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    var at = 0;
    for (final id in prev) {
      final pk = id['pk'];
      if (pk is! String || !seen.add(pk)) continue;
      if (at++ < max || keep.contains(pk)) out.add(id);
    }
    return out;
  }

  Future<int> rotate({bool sweep = true}) async {
    final old = _state['current'] as Map<String, dynamic>?;
    if (old != null) {
      _state['prev'] = _kept([old, ..._maps(_state['prev'])], _prevMax);
    }
    _state['current'] = _newIdentity();
    await _save();
    if (!sweep || old == null) return 0;
    return _sweep(old);
  }

  static int _chunk(int left) {
    var sum = 0;
    var count = 0;
    for (var i = voucherDenoms.length - 1; i >= 0; i--) {
      final d = voucherDenoms[i];
      while (left - sum >= d && count < voucherMaxOutputs) {
        sum += d;
        count++;
      }
    }
    return sum;
  }

  Future<int> _sweep(Map<String, dynamic> from) async {
    final signer = signerOf(from);
    final res = await _api.balance(signer);
    final data = res.data;
    if (res.status >= 400 || data['error'] != null) return 0;
    await noteBalanceData(signer.pubkey, data);
    var issued = 0;
    for (final tier in const ['standard', 'pro']) {
      final have = tier == 'pro'
          ? (data['proBalanceCredits'] ?? data['proBalance'])
          : (data['balanceCredits'] ?? data['balance']);
      var left = have is num ? have.floor() : 0;
      while (left > 0) {
        final chunk = _chunk(left);
        if (chunk <= 0) break;
        try {
          await _issue(signer, chunk, tier, held: true);
        } catch (_) {
          break;
        }
        issued += chunk;
        left -= chunk;
      }
    }
    return issued;
  }

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  static bool _derives(Map<String, dynamic> id) {
    final pk = id['pk'];
    final sk = id['sk'];
    if (pk is! String || sk is! String) return false;
    if (!_hex64.hasMatch(pk) || !_hex64.hasMatch(sk)) return false;
    try {
      return getPublicKeyHex(Uint8List.fromList(convert.hex.decode(sk))) == pk;
    } catch (_) {
      return false;
    }
  }

  static int _createdAt(Map<String, dynamic> id) =>
      (id['createdAt'] as num?)?.toInt() ?? 0;

  static int _newer(Map<String, dynamic> a, Map<String, dynamic> b) {
    final at = _createdAt(b).compareTo(_createdAt(a));
    return at != 0 ? at : (b['pk'] as String).compareTo(a['pk'] as String);
  }

  static Map<String, dynamic> _keyWire(Map<String, dynamic> id) => {
        'pk': id['pk'],
        'sk': id['sk'],
        'root': id['root'],
        'createdAt': _createdAt(id),
      };

  static Map<String, dynamic> _tokenWire(Map<String, dynamic> t) => {
        'd': t['d'],
        'x': t['x'],
        'C': t['C'],
        'tier': t['tier'] ?? 'standard',
      };

  static bool _validToken(Map<String, dynamic> t) {
    final d = t['d'];
    final x = t['x'];
    return d is int &&
        voucherDenoms.contains(d) &&
        x is String &&
        _hex64.hasMatch(x) &&
        t['C'] is String &&
        (t['tier'] == 'standard' || t['tier'] == 'pro');
  }

  List<Map<String, dynamic>> _tokenList() =>
      (_state['tokens'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  List<String> _spentList() =>
      (_state['spent'] as List? ?? const []).whereType<String>().toList();

  Map<String, dynamic>? syncValue() {
    final ids = held.where(_derives).toList()..sort(_newer);
    final tokens = _tokenList().where((t) => t['redeemId'] == null).toList()
      ..sort((a, b) => '${a['x']}'.compareTo('${b['x']}'));
    final spent = _spentList()..sort();
    if (ids.isEmpty && tokens.isEmpty && spent.isEmpty) return null;
    final current = pubkey;
    final keep = {...referenced(), if (current != null) current};
    final keys = [
      for (var i = 0; i < ids.length; i++)
        if (i < syncKeysMax || keep.contains(ids[i]['pk'])) _keyWire(ids[i])
    ];
    return {
      'v': 1,
      'current': current,
      'keys': keys,
      'tokens': [
        for (final t in tokens.take(syncTokensMax)) _tokenWire(t)
      ],
      'spent': spent.take(syncSpentMax).toList(),
    };
  }

  String _syncPrint() => jsonEncode({
        'current': pubkey,
        'prev': [for (final id in _maps(_state['prev'])) '${id['pk']}']..sort(),
        'tokens': [for (final t in _tokenList()) '${t['x']}']..sort(),
        'spent': _spentList()..sort(),
      });

  Future<bool> mergeSync(Object? remote) async {
    if (remote is! Map || remote['v'] != 1) return false;
    final before = _syncPrint();
    final byPk = <String, Map<String, dynamic>>{};
    for (final id in held) {
      final pk = id['pk'];
      if (pk is String) byPk[pk] = id;
    }
    for (final id in _maps(remote['keys'])) {
      if (byPk.containsKey(id['pk']) || !_derives(id)) continue;
      byPk[id['pk'] as String] = {
        'sk': id['sk'],
        'pk': id['pk'],
        if (id['root'] is String) 'root': id['root'],
        'createdAt': _createdAt(id),
      };
    }
    final mine = _state['current'] is Map
        ? (_state['current'] as Map).cast<String, dynamic>()
        : null;
    final theirs = byPk[remote['current']];
    final winner = mine == null
        ? theirs
        : theirs == null
            ? mine
            : (_newer(mine, theirs) <= 0 ? mine : theirs);
    if (winner != null) _state['current'] = winner;
    final rest = byPk.values.where((id) => id['pk'] != winner?['pk']).toList()
      ..sort(_newer);
    _state['prev'] = _kept(rest, syncKeysMax - 1);

    final spent = _spentList();
    final gone = {...spent};
    for (final x in (remote['spent'] as List? ?? const []).whereType<String>()) {
      if (gone.add(x)) spent.add(x);
    }
    _state['spent'] = spent.take(syncSpentMax).toList();
    final tokens =
        _tokenList().where((t) => !gone.contains(t['x'])).toList();
    final have = {for (final t in tokens) t['x']};
    final arriving = <Map<String, dynamic>>[];
    for (final t in _maps(remote['tokens'])) {
      if (!_validToken(t) || gone.contains(t['x']) || !have.add(t['x'])) {
        continue;
      }
      arriving.add({..._tokenWire(t), 'held': true});
    }
    _state['tokens'] = [...tokens, ...arriving.reversed];

    if (_syncPrint() == before) return false;
    await _save();
    return true;
  }

  // --- vouchers ---------------------------------------------------------------

  Future<Map<String, dynamic>> keyset({bool force = false}) async {
    final cached = _keyset;
    if (cached != null && !force) return cached;
    final res = await _api.voucherKeys();
    final data = res.data;
    if (res.status >= 400 || data['error'] != null || data['keys'] == null) {
      throw StateError((data['error'] as String?) ?? 'Voucher keys are unavailable.');
    }
    final keys = voucherKeysetKeys(data['keys']);
    if (keys == null) throw StateError(t('Voucher keyset rejected.'));
    final id = voucherKeysetId(keys);
    if (data['keysetId'] != id) throw StateError(t('Voucher keyset rejected.'));
    final pinned = _store.getString(_keysetKey);
    if (pinned != null && pinned != id) {
      final ok = await (onKeysetChange?.call(pinned, id) ?? Future.value(false));
      if (!ok) throw StateError(t('Voucher keyset rejected.'));
    }
    await _store.setString(_keysetKey, id);
    final verified = <String, dynamic>{...data, 'keysetId': id, 'keys': keys};
    _keyset = verified;
    return verified;
  }

  List<Map<String, dynamic>> _tokens(String tier, {bool? held}) => _tokenList()
      .where((t) =>
          (t['tier'] ?? 'standard') == tier &&
          (held == null || (t['held'] == true) == held))
      .toList();

  int heldCredits(String tier) =>
      _tokens(tier).fold(0, (n, t) => n + ((t['d'] as num?)?.toInt() ?? 0));

  Future<void> _spend(List<Map<String, dynamic>> batch) async {
    final gone = batch.map((t) => t['x']).whereType<String>().toSet();
    _state['tokens'] =
        _tokenList().where((t) => !gone.contains(t['x'])).toList();
    final spent = _spentList().where((x) => !gone.contains(x)).toList();
    _state['spent'] = [...gone, ...spent].take(syncSpentMax).toList();
    await _save();
  }

  EventSigner _pendingSigner(Map<String, dynamic> pending, EventSigner identity) {
    final from = heldFor(pending['from'] as String?);
    return from == null ? identity : signerOf(from);
  }

  /// Finishes an issuance whose response was lost: the same reqId and the same
  /// outputs re-sign without a second debit.
  Future<void> _finishIssue(
      EventSigner identity, Map<String, dynamic> pending) async {
    final keys = await keyset();
    final tier = pending['tier'] as String;
    final outputs = (pending['outputs'] as List).cast<Map<String, dynamic>>();
    final res = await _api.voucherIssue(identity, {
      'tier': tier,
      'reqId': pending['reqId'],
      'outputs': outputs.map((o) => {'d': o['d'], 'B': o['B']}).toList(),
    });
    final data = res.data;
    if (heldFor(identity.pubkey) != null) {
      await _noteTier(identity.pubkey, tier, data,
          delta: data['insufficient'] == true || data['error'] != null
              ? 0
              : -outputs.fold<int>(0, (n, o) => n + (o['d'] as int)));
    }
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
      final vars = {
        'have': creditFigure(data['balance'] as num?),
        'need': creditFigure(data['required'] as num?)
      };
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
        if (pending['held'] == true) 'held': true,
      });
    }
    _state['tokens'] = [..._tokenList(), ...tokens];
    _state['pending'] = null;
    await _save();
  }

  Future<int> _redeem(
      String tier, List<Map<String, dynamic>> pool, String? pk) async {
    if (pool.isEmpty) return 0;
    final claimed = pool.where((t) => t['redeemId'] != null).toList();
    String redeemId;
    List<Map<String, dynamic>> batch;
    if (claimed.isNotEmpty) {
      redeemId = claimed.first['redeemId'] as String;
      batch = pool.where((t) => t['redeemId'] == redeemId).take(voucherMaxOutputs).toList();
    } else {
      redeemId = bytesToHex(randomBytes(32));
      batch = pool.take(voucherMaxOutputs).toList();
      for (final t in batch) {
        t['redeemId'] = redeemId;
      }
      await _save();
    }
    final into = await identityFor(pk);
    final res = await _api.voucherRedeem(signerOf(into), {
      'tier': tier,
      'redeemId': redeemId,
      'tokens': batch.map((t) => {'d': t['d'], 'x': t['x'], 'C': t['C']}).toList(),
    });
    final data = res.data;
    if (res.status >= 400 || data['error'] != null) {
      if (data['alreadySpent'] == true) await _spend(batch);
      throw StateError((data['error'] as String?) ?? 'Could not redeem vouchers.');
    }
    await _spend(batch);
    final credited = (data['credited'] as num?)?.toInt() ?? 0;
    await _noteTier(into['pk'] as String, tier, data, delta: credited);
    return credited;
  }

  static List<Map<String, dynamic>> _pick(
      List<Map<String, dynamic>> pool, int want) {
    int d(Map<String, dynamic> t) => (t['d'] as num?)?.toInt() ?? 0;
    final sorted = [...pool]..sort((a, b) => d(b).compareTo(d(a)));
    final out = <Map<String, dynamic>>[];
    var left = want;
    for (final t in sorted) {
      if (out.length >= voucherMaxOutputs || left <= 0) break;
      if (d(t) <= left) {
        out.add(t);
        left -= d(t);
      }
    }
    if (left > 0 && out.length < voucherMaxOutputs) {
      final rest = sorted.where((t) => !out.contains(t)).toList().reversed;
      final over = rest.where((t) => d(t) >= left).firstOrNull;
      if (over != null) {
        out.add(over);
      } else {
        out.addAll(rest.take(voucherMaxOutputs - out.length));
      }
    }
    return out;
  }

  Future<int> redeemHeld(String tier, {String? pk, required int want}) async {
    var credited = 0;
    while (credited < want) {
      final pool = _tokens(tier);
      if (pool.isEmpty) break;
      final claimed = pool.where((t) => t['redeemId'] != null).toList();
      final got = await _redeem(
          tier, claimed.isNotEmpty ? claimed : _pick(pool, want - credited), pk);
      if (got <= 0) break;
      credited += got;
    }
    return credited;
  }

  /// Resumes anything a previous session left half-done.
  Future<void> flush({EventSigner? identity}) async {
    if (!ready || identity == null) return;
    if (_state['pending'] == null &&
        _tokens('standard', held: false).isEmpty &&
        _tokens('pro', held: false).isEmpty) {
      return;
    }
    try {
      final pending = _state['pending'] as Map<String, dynamic>?;
      if (pending != null) {
        await _finishIssue(_pendingSigner(pending, identity), pending);
      }
      for (final tier in const ['standard', 'pro']) {
        while (_tokens(tier, held: false).isNotEmpty) {
          await _redeem(tier, _tokens(tier, held: false), null);
        }
      }
    } catch (_) {
      // Left in place; the next flush picks it up.
    }
  }

  Future<void> _issue(EventSigner identity, int amount, String tier,
      {bool held = false}) async {
    final denoms = voucherSplitAmount(amount);
    if (denoms == null) {
      throw StateError(t('That amount needs too many vouchers — move a smaller amount.'));
    }
    await ensure();
    await keyset();
    final stale = _state['pending'] as Map<String, dynamic>?;
    if (stale != null) await _finishIssue(_pendingSigner(stale, identity), stale);

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
      'from': identity.pubkey,
      if (held) 'held': true,
    };
    await _save();
    await _finishIssue(identity, _state['pending'] as Map<String, dynamic>);
  }

  Future<int> moveCredits(EventSigner identity, int amount, String tier,
      {String? pk}) async {
    if (amount <= 0) throw StateError(t('Enter how many credits to move.'));
    await _issue(identity, amount, tier);
    var credited = 0;
    while (_tokens(tier, held: false).isNotEmpty) {
      credited += await _redeem(tier, _tokens(tier, held: false), pk);
    }
    return credited;
  }
}
