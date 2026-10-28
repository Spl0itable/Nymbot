import 'dart:convert';
import 'dart:typed_data';

import 'package:bech32/bech32.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

import '../../models/nostr_event.dart';
import 'keys.dart';
import 'ml_kem.dart';
import 'nip44.dart' as nip44;
import 'schnorr.dart' as schnorr;

const String channelProto = 'nymbot-chan/1';
const int channelVersion = 1;
const int channelCertKind = 25519;
const int channelAuthKind = 27235;
const String channelAuthAction = 'chan-open';
const int channelMaxLifetime = 900;
const int channelClockSkew = 120;
const int channelReplyBefore = 60;
const int channelReplyAfter = 3600;
const int channelMaxBody = 65532;
const int channelFlagMore = 1;
const String channelFingerprintHrp = 'nymchan';

const int _headerLen = 11;
const int _tagLen = 16;
const int _maxCounter = 4294967295;
const List<int> _buckets = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
const List<String> _certTags = ['v', 'p', 'nonce', 'x', 's', 'kem', 'expiration'];

class ChannelType {
  static const int turn = 0x01;
  static const int attach = 0x02;
  static const int steer = 0x03;
  static const int answer = 0x04;
  static const int approve = 0x05;
  static const int resume = 0x06;
  static const int cancel = 0x07;
  static const int join = 0x08;
  static const int accept = 0x41;
  static const int draft = 0x42;
  static const int plan = 0x43;
  static const int step = 0x44;
  static const int park = 0x46;
  static const int reply = 0x47;
  static const int error = 0x48;
  static const int close = 0x7e;
  static const int abort = 0x7f;
  static const List<int> client = [turn, attach, steer, answer, approve, resume, cancel, join, close, abort];
  static const List<int> server = [accept, draft, plan, step, park, reply, error, close, abort];
}

class ChannelError implements Exception {
  ChannelError(this.code);
  final String code;
  @override
  String toString() => 'ChannelError($code)';
}

class ChannelKeys {
  ChannelKeys({required this.c2sKey, required this.c2sIv, required this.s2cKey, required this.s2cIv});
  final Uint8List c2sKey;
  final Uint8List c2sIv;
  final Uint8List s2cKey;
  final Uint8List s2cIv;
}

class ChannelHello {
  ChannelHello._(this.hello, this._xPair);
  final Map<String, dynamic> hello;
  final SimpleKeyPair _xPair;
}

class ChannelCert {
  ChannelCert._({
    required this.id,
    required this.bot,
    required this.user,
    required this.nonce,
    required this.x,
    required this.s,
    required this.kem,
    required this.iat,
    required this.exp,
  });
  final String id;
  final String bot;
  final String user;
  final String nonce;
  final String x;
  final String s;
  final Uint8List kem;
  final int iat;
  final int exp;
}

class ChannelFinish {
  ChannelFinish._(this.kemCt, this.transcript, this.state);
  final Uint8List kemCt;
  final Uint8List transcript;
  final ChannelState state;
}

class ChannelFrame {
  ChannelFrame._(this.type, this.more, this.body);
  final int type;
  final bool more;
  final Uint8List body;
}

class ChannelState {
  ChannelState._(this.role, this.exp, this._sendKey, this._sendIv, this._recvKey, this._recvIv,
      this._sendTypes, this._recvTypes);

  factory ChannelState.fromKeys(String role, ChannelKeys keys, int exp) {
    if (role != 'client' && role != 'server') throw ChannelError('malformed');
    final c = role == 'client';
    return ChannelState._(
      role,
      exp,
      Uint8List.fromList(c ? keys.c2sKey : keys.s2cKey),
      Uint8List.fromList(c ? keys.c2sIv : keys.s2cIv),
      Uint8List.fromList(c ? keys.s2cKey : keys.c2sKey),
      Uint8List.fromList(c ? keys.s2cIv : keys.c2sIv),
      c ? ChannelType.client : ChannelType.server,
      c ? ChannelType.server : ChannelType.client,
    );
  }

  final String role;
  final int exp;
  final Uint8List _sendKey;
  final Uint8List _sendIv;
  final Uint8List _recvKey;
  final Uint8List _recvIv;
  final List<int> _sendTypes;
  final List<int> _recvTypes;
  int _sendCtr = 0;
  int _recvCtr = 0;
  bool _sentClose = false;
  bool _recvClose = false;
  bool _dead = false;

  bool get dead => _dead;

  void _kill() {
    _dead = true;
    _sendKey.fillRange(0, _sendKey.length, 0);
    _recvKey.fillRange(0, _recvKey.length, 0);
    _sendIv.fillRange(0, _sendIv.length, 0);
    _recvIv.fillRange(0, _recvIv.length, 0);
  }
}

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _runId = RegExp(r'^[\x21-\x7e]{1,128}$');
const List<String> channelRunPhases = ['live', 'park', 'done'];
const List<String> channelAskKinds = ['question', 'plan', 'tool', 'connector'];
const List<String> _runTags = ['nymbot-run', 'nymbot-ctl', 'nymbot-resume', 'nymbot-ask'];
final RegExp _b64uChars = RegExp(r'^[A-Za-z0-9_-]+$');
final RegExp _expiry = RegExp(r'^[1-9][0-9]{0,11}$');
final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();

int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _label(String s) => _utf8(channelProto + s);

Uint8List _concat(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.toBytes();
}

Uint8List _sha256(List<int> data) => Uint8List.fromList(hash.sha256.convert(data).bytes);

Uint8List _be32(int n) => Uint8List.fromList([(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255]);

Uint8List _be64(int n) => _concat([_be32(n ~/ 4294967296), _be32(n % 4294967296)]);

int _readBe32(Uint8List b, int i) => (b[i] << 24) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];

String _b64uEncode(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List _b64uDecode(String s) {
  if (!_b64uChars.hasMatch(s)) throw const FormatException('base64url');
  return base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));
}

Future<SimpleKeyPair> _xPair(Uint8List? sk) async {
  if (sk == null) return _x25519.newKeyPair();
  if (sk.length != 32) throw ChannelError('malformed');
  return _x25519.newKeyPairFromSeed(sk);
}

Future<Uint8List> _xDh(SimpleKeyPair kp, Uint8List peer) async {
  if (peer.length != 32) throw ChannelError('malformed');
  List<int> bits;
  try {
    final s = await _x25519.sharedSecretKey(
        keyPair: kp, remotePublicKey: SimplePublicKey(peer, type: KeyPairType.x25519));
    bits = await s.extractBytes();
  } catch (_) {
    throw ChannelError('low-order');
  }
  if (bits.every((b) => b == 0)) throw ChannelError('low-order');
  return Uint8List.fromList(bits);
}

Future<Uint8List> channelX25519Public(Uint8List sk) async {
  final pub = await (await _xPair(sk)).extractPublicKey();
  return Uint8List.fromList(pub.bytes);
}

Future<Uint8List> channelX25519Shared(Uint8List sk, Uint8List peer) async => _xDh(await _xPair(sk), peer);

String channelCanonicalHello(Map<String, dynamic> h) =>
    jsonEncode({'n': h['n'], 'u': h['u'], 'v': h['v'], 'x': h['x']});

String channelHelloPayload(Map<String, dynamic> h) => bytesToHex(_sha256(utf8.encode(channelCanonicalHello(h))));

Future<ChannelHello> channelNewHello(String userPk, {Uint8List? xSk, Uint8List? nonce}) async {
  if (!_hex64.hasMatch(userPk)) throw ChannelError('malformed');
  final kp = await _xPair(xSk);
  final pub = await kp.extractPublicKey();
  final n = nonce ?? randomBytes(32);
  if (n.length != 32) throw ChannelError('malformed');
  return ChannelHello._({
    'v': channelVersion,
    'x': bytesToHex(pub.bytes),
    'n': bytesToHex(n),
    'u': userPk,
  }, kp);
}

Map<String, dynamic> channelAuthTemplate(Map<String, dynamic> hello, String url, int? createdAt) => {
      'kind': channelAuthKind,
      'pubkey': hello['u'],
      'created_at': createdAt ?? _nowSec(),
      'tags': [
        ['u', url],
        ['method', 'POST'],
        ['action', channelAuthAction],
        ['payload', channelHelloPayload(hello)],
      ],
      'content': '',
    };

ChannelCert _parseCert(Object? raw, String botPk) {
  if (raw is! Map || raw['kind'] != channelCertKind || raw['content'] != '' || raw['tags'] is! List) {
    throw ChannelError('malformed');
  }
  final tags = raw['tags'] as List;
  if (tags.length != _certTags.length) throw ChannelError('malformed');
  final t = <String, String>{};
  final tagList = <List<String>>[];
  for (final tag in tags) {
    if (tag is! List || tag.length != 2 || tag[0] is! String || tag[1] is! String) throw ChannelError('malformed');
    final name = tag[0] as String;
    if (!_certTags.contains(name) || t.containsKey(name)) throw ChannelError('malformed');
    t[name] = tag[1] as String;
    tagList.add([name, tag[1] as String]);
  }
  if (!_hex64.hasMatch(t['p']!) || !_hex64.hasMatch(t['nonce']!) || !_hex64.hasMatch(t['x']!) ||
      !_hex64.hasMatch(t['s']!) || !_expiry.hasMatch(t['expiration']!) || !_b64uChars.hasMatch(t['kem']!)) {
    throw ChannelError('malformed');
  }
  final pubkey = raw['pubkey'];
  final iat = raw['created_at'];
  final id = raw['id'];
  final sig = raw['sig'];
  if (pubkey is! String || !_hex64.hasMatch(pubkey) || iat is! int || iat <= 0 || id is! String || sig is! String) {
    throw ChannelError('malformed');
  }
  if (pubkey != botPk) throw ChannelError('wrong-bot');
  final ev = NostrEvent(
      id: id, pubkey: pubkey, createdAt: iat, kind: channelCertKind, tags: tagList, content: '', sig: sig);
  if (!_hex64.hasMatch(id) || ev.computeId() != id || !schnorr.verifyEvent(ev)) throw ChannelError('bad-sig');
  if (t['v'] != '$channelVersion') throw ChannelError('version');
  Uint8List kem;
  try {
    kem = _b64uDecode(t['kem']!);
  } catch (_) {
    throw ChannelError('bad-kem');
  }
  if (kem.length != mlKemPublicKeyLength) throw ChannelError('bad-kem');
  final exp = int.parse(t['expiration']!);
  if (exp <= iat || exp - iat > channelMaxLifetime) throw ChannelError('lifetime');
  return ChannelCert._(
      id: id, bot: pubkey, user: t['p']!, nonce: t['nonce']!, x: t['x']!, s: t['s']!, kem: kem, iat: iat, exp: exp);
}

ChannelCert channelVerifyCert(Map<String, dynamic> cert,
    {required String botPk, required String userPk, required String nonce, int? now}) {
  final c = _parseCert(cert, botPk);
  if (c.user != userPk) throw ChannelError('wrong-user');
  if (c.nonce != nonce) throw ChannelError('wrong-nonce');
  final t = now ?? _nowSec();
  if (c.iat > t + channelClockSkew) throw ChannelError('future');
  if (t >= c.exp) throw ChannelError('expired');
  return c;
}

bool _sealOk(NostrEvent? seal, String s) {
  if (seal == null || seal.kind != 13 || seal.pubkey != s) return false;
  try {
    return seal.computeId() == seal.id && schnorr.verifyEvent(seal);
  } catch (_) {
    return false;
  }
}

ChannelCert channelCheckReplyCert(Map<String, dynamic> rumor,
    {required String botPk, required String userPk, required NostrEvent? seal}) {
  final tags = rumor['tags'];
  final at = rumor['created_at'];
  if (tags is! List || at is! int) throw ChannelError('malformed');
  final found = tags.where((t) => t is List && t.isNotEmpty && t[0] == 'nymbot-cert').toList();
  if (found.length != 1 || (found.first as List).length < 2 || (found.first as List)[1] is! String) {
    throw ChannelError('malformed');
  }
  Object? cert;
  try {
    cert = jsonDecode((found.first as List)[1] as String);
  } catch (_) {
    throw ChannelError('malformed');
  }
  final c = _parseCert(cert, botPk);
  if (c.user != userPk) throw ChannelError('wrong-user');
  if (rumor['pubkey'] != c.s) throw ChannelError('wrong-seal');
  if (!_sealOk(seal, c.s)) throw ChannelError('wrong-seal');
  if (at < c.iat - channelReplyBefore || at > c.exp + channelReplyAfter) throw ChannelError('window');
  return c;
}

class ChannelAsk {
  ChannelAsk({required this.kind, required this.q, required this.body});
  final String kind;
  final String q;
  final Map<String, dynamic> body;
}

class ChannelRun {
  ChannelRun({required this.cert, required this.run, required this.phase, this.ctl, this.resume, this.ask, this.text});
  final ChannelCert cert;
  final String run;
  final String phase;
  final String? ctl;
  final String? resume;
  final ChannelAsk? ask;
  final String? text;
}

String? _runKey(List? t) {
  if (t == null) return null;
  if (t.length != 2 || t[1] is! String || !_hex64.hasMatch(t[1] as String)) throw ChannelError('malformed');
  return t[1] as String;
}

ChannelRun channelReadRunRumor(Map<String, dynamic> rumor,
    {required String botPk, required String userPk, required NostrEvent? seal}) {
  final cert = channelCheckReplyCert(rumor, botPk: botPk, userPk: userPk, seal: seal);
  final tags = rumor['tags'];
  final content = rumor['content'];
  if (tags is! List || content is! String) throw ChannelError('malformed');
  final seen = <String, List>{};
  for (final t in tags) {
    if (t is List && t.isNotEmpty && _runTags.contains(t[0])) {
      if (seen.containsKey(t[0])) throw ChannelError('malformed');
      seen[t[0] as String] = t;
    }
  }
  final r = seen['nymbot-run'];
  if (r == null || r.length != 3 || r[1] is! String || !_runId.hasMatch(r[1] as String) || !channelRunPhases.contains(r[2])) {
    throw ChannelError('malformed');
  }
  final phase = r[2] as String;
  final ctl = _runKey(seen['nymbot-ctl']);
  final resume = _runKey(seen['nymbot-resume']);
  final a = seen['nymbot-ask'];
  ChannelAsk? ask;
  if (a != null) {
    if (a.length != 3 || !channelAskKinds.contains(a[1]) || a[2] is! String || (a[2] as String).isEmpty) {
      throw ChannelError('malformed');
    }
    Object? body;
    try {
      body = jsonDecode(content);
    } catch (_) {
      throw ChannelError('malformed');
    }
    if (body is! Map<String, dynamic>) throw ChannelError('malformed');
    ask = ChannelAsk(kind: a[1] as String, q: a[2] as String, body: body);
  }
  final waiting = phase == 'live';
  if (waiting != (ctl != null) ||
      (waiting && resume != null) ||
      (phase == 'park' && resume == null) ||
      (phase == 'park') != (ask != null)) {
    throw ChannelError('malformed');
  }
  return ChannelRun(
      cert: cert, run: r[1] as String, phase: phase, ctl: ctl, resume: resume, ask: ask, text: phase == 'done' ? content : null);
}

NostrEvent channelSealTurn(Map<String, dynamic> rumor, Uint8List userSk, ChannelCert cert, {Uint8List? nonce, int? createdAt}) {
  if (rumor['kind'] != 14 || !_hex64.hasMatch(cert.s)) throw ChannelError('malformed');
  final userPk = getPublicKeyHex(userSk);
  if (rumor['pubkey'] != userPk) throw ChannelError('wrong-user');
  final content = nip44.encrypt(jsonEncode(rumor), nip44.getConversationKey(userSk, cert.s), nonce: nonce);
  return schnorr.finalizeEvent(
      UnsignedEvent(pubkey: userPk, createdAt: createdAt ?? _nowSec(), kind: 13, content: content), userSk);
}

Uint8List _fingerprintBytes(ChannelCert c) =>
    Uint8List.sublistView(_sha256(_concat([_label('/fp'), hexToBytes(c.x), hexToBytes(c.s), c.kem])), 0, 16);

String channelFingerprintHex(ChannelCert c) => bytesToHex(_fingerprintBytes(c));

String channelFingerprint(ChannelCert c) {
  final words = <int>[];
  var acc = 0;
  var bits = 0;
  for (final b in _fingerprintBytes(c)) {
    acc = ((acc << 8) | b) & 0xffff;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      words.add((acc >> bits) & 31);
    }
  }
  if (bits > 0) words.add((acc << (5 - bits)) & 31);
  return const Bech32Codec().encode(Bech32(channelFingerprintHrp, words));
}

Uint8List _transcript({
  required String user,
  required String cx,
  required String nonce,
  required String authId,
  required String botPk,
  required String certId,
  required String x,
  required String s,
  required Uint8List kem,
  required int iat,
  required int exp,
  required Uint8List kemCt,
}) =>
    _sha256(_concat([
      _label('/th'),
      [channelVersion],
      hexToBytes(user),
      hexToBytes(cx),
      hexToBytes(nonce),
      hexToBytes(authId),
      hexToBytes(botPk),
      hexToBytes(certId),
      hexToBytes(x),
      hexToBytes(s),
      kem,
      _be64(iat),
      _be64(exp),
      kemCt,
    ]));

ChannelKeys _deriveKeys(Uint8List th, Uint8List dh, Uint8List kemSs) {
  final ikm = _concat([dh, kemSs]);
  final prk = nip44.hkdfExtract(th, ikm);
  final keys = ChannelKeys(
    c2sKey: nip44.hkdfExpand(prk, _label(' c2s key'), 32),
    c2sIv: nip44.hkdfExpand(prk, _label(' c2s iv'), 12),
    s2cKey: nip44.hkdfExpand(prk, _label(' s2c key'), 32),
    s2cIv: nip44.hkdfExpand(prk, _label(' s2c iv'), 12),
  );
  ikm.fillRange(0, ikm.length, 0);
  prk.fillRange(0, prk.length, 0);
  return keys;
}

Future<ChannelFinish> channelClientFinish({
  required ChannelHello hello,
  required String authId,
  required ChannelCert cert,
  required String botPk,
  Uint8List? kemMsg,
}) async {
  if (cert.bot != botPk) throw ChannelError('wrong-bot');
  if (!_hex64.hasMatch(authId)) throw ChannelError('malformed');
  final dh = await _xDh(hello._xPair, hexToBytes(cert.x));
  MlKemEncapsulation kem;
  try {
    kem = mlKem768.encapsulate(cert.kem, kemMsg ?? randomBytes(32));
  } catch (_) {
    throw ChannelError('bad-kem');
  }
  final h = hello.hello;
  final th = _transcript(
    user: h['u'] as String,
    cx: h['x'] as String,
    nonce: h['n'] as String,
    authId: authId,
    botPk: cert.bot,
    certId: cert.id,
    x: cert.x,
    s: cert.s,
    kem: cert.kem,
    iat: cert.iat,
    exp: cert.exp,
    kemCt: kem.cipherText,
  );
  final keys = _deriveKeys(th, dh, kem.sharedSecret);
  dh.fillRange(0, dh.length, 0);
  kem.sharedSecret.fillRange(0, kem.sharedSecret.length, 0);
  final state = ChannelState.fromKeys('client', keys, cert.exp);
  for (final k in [keys.c2sKey, keys.c2sIv, keys.s2cKey, keys.s2cIv]) {
    k.fillRange(0, k.length, 0);
  }
  return ChannelFinish._(kem.cipherText, th, state);
}

int _bucketFor(int n) => _buckets.firstWhere((b) => b >= n + 4, orElse: () => 0);

Uint8List _header(int type, int flags, int ctr) => _concat([
      [channelVersion, type, flags],
      _be64(ctr)
    ]);

Uint8List _nonceFor(Uint8List iv, int ctr) {
  final n = Uint8List.fromList(iv);
  final c = _be64(ctr);
  for (var i = 0; i < 8; i++) {
    n[4 + i] ^= c[i];
  }
  return n;
}

Future<Uint8List> channelSealFrame(ChannelState st, int type, Uint8List body,
    {bool more = false, int? flags, int? now}) async {
  if (st._dead) throw ChannelError('dead');
  if (st._sentClose) throw ChannelError('closed');
  final f = flags ?? (more ? channelFlagMore : 0);
  if ((f & ~channelFlagMore) != 0) throw ChannelError('malformed');
  if (!st._sendTypes.contains(type)) throw ChannelError('type');
  if ((type == ChannelType.close || type == ChannelType.abort) && (f & channelFlagMore) != 0) {
    throw ChannelError('malformed');
  }
  if (body.length > channelMaxBody) throw ChannelError('oversize');
  if ((now ?? _nowSec()) >= st.exp) {
    st._kill();
    throw ChannelError('expired');
  }
  if (st._sendCtr > _maxCounter) {
    st._kill();
    throw ChannelError('exhausted');
  }
  final p = Uint8List(_bucketFor(body.length))
    ..setRange(0, 4, _be32(body.length))
    ..setRange(4, 4 + body.length, body);
  final ctr = st._sendCtr++;
  final h = _header(type, f, ctr);
  final key = Uint8List.fromList(st._sendKey);
  final nonce = _nonceFor(st._sendIv, ctr);
  if (type == ChannelType.close) st._sentClose = true;
  if (type == ChannelType.abort) st._dead = true;
  final box = await _aead.encrypt(p, secretKey: SecretKey(key), nonce: nonce, aad: h);
  if (type == ChannelType.abort) st._kill();
  return _concat([h, box.cipherText, box.mac.bytes]);
}

Future<ChannelFrame> channelOpenFrame(ChannelState st, Uint8List frame, int? now) async {
  if (st._dead) throw ChannelError('dead');
  if (st._recvClose) throw ChannelError('closed');
  try {
    if (!_buckets.contains(frame.length - _headerLen - _tagLen)) throw ChannelError('malformed');
    if (frame[0] != channelVersion) throw ChannelError('version');
    final type = frame[1];
    final flags = frame[2];
    if ((flags & ~channelFlagMore) != 0) throw ChannelError('malformed');
    final ctr = _readBe32(frame, 3) * 4294967296 + _readBe32(frame, 7);
    if (ctr != st._recvCtr) throw ChannelError('counter');
    if (!st._recvTypes.contains(type)) throw ChannelError('type');
    if ((type == ChannelType.close || type == ChannelType.abort) && (flags & channelFlagMore) != 0) {
      throw ChannelError('malformed');
    }
    if ((now ?? _nowSec()) >= st.exp) throw ChannelError('expired');
    st._recvCtr++;
    if (type == ChannelType.close) st._recvClose = true;
    final key = Uint8List.fromList(st._recvKey);
    final nonce = _nonceFor(st._recvIv, ctr);
    final h = Uint8List.sublistView(frame, 0, _headerLen);
    final sealed = Uint8List.sublistView(frame, _headerLen);
    List<int> p;
    try {
      p = await _aead.decrypt(
        SecretBox(Uint8List.sublistView(sealed, 0, sealed.length - _tagLen),
            nonce: nonce, mac: Mac(Uint8List.sublistView(sealed, sealed.length - _tagLen))),
        secretKey: SecretKey(key),
        aad: h,
      );
    } catch (_) {
      throw ChannelError('tamper');
    }
    final plain = Uint8List.fromList(p);
    final len = _readBe32(plain, 0);
    if (len > plain.length - 4) throw ChannelError('padding');
    for (var i = 4 + len; i < plain.length; i++) {
      if (plain[i] != 0) throw ChannelError('padding');
    }
    if (type == ChannelType.abort) st._kill();
    return ChannelFrame._(type, (flags & channelFlagMore) != 0, Uint8List.fromList(plain.sublist(4, 4 + len)));
  } catch (e) {
    st._kill();
    rethrow;
  }
}

String channelEncodeFrame(Uint8List frame) => _b64uEncode(frame);

Uint8List channelDecodeFrame(String text) {
  try {
    return _b64uDecode(text);
  } catch (_) {
    throw ChannelError('malformed');
  }
}

Future<String> channelControlOpen({
  required Uint8List c,
  required String dir,
  required String run,
  required String userPk,
  required String blob,
}) async {
  if (c.length != 32 || (dir != 'c2s' && dir != 's2c') || run.isEmpty || !_hex64.hasMatch(userPk)) {
    throw ChannelError('malformed');
  }
  final b = channelDecodeFrame(blob);
  if (b.length < 1 + 12 + _tagLen || b[0] != channelVersion) throw ChannelError('malformed');
  final aad = _concat([_label('/ctl $dir'), hexToBytes(userPk), _utf8(run)]);
  List<int> out;
  try {
    out = await _aead.decrypt(
      SecretBox(Uint8List.sublistView(b, 13, b.length - _tagLen),
          nonce: Uint8List.sublistView(b, 1, 13), mac: Mac(Uint8List.sublistView(b, b.length - _tagLen))),
      secretKey: SecretKey(c),
      aad: aad,
    );
  } catch (_) {
    throw ChannelError('tamper');
  }
  return utf8.decode(out, allowMalformed: true);
}
