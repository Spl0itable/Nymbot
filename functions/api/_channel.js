import { ml_kem768 } from "./_mlkem.js";
import {
  getPublicKey,
  getEventHash,
  schnorr,
  hkdfExpand,
  hmac,
  sha256,
  bytesToHex,
  hexToBytes,
  utf8ToBytes,
  concatBytes,
  randomBytes,
  verifyClientAuth,
  nip44ConversationKey,
  nip44Decrypt
} from "./_shared.js";
import {
  b64uEncode,
  b64uDecode,
  pqKeypairFromRoot,
  chacha20poly1305Encrypt,
  chacha20poly1305Decrypt
} from "./_pq.js";

var PROTO = "nymbot-chan/1";
var VERSION = 1;
var CERT_KIND = 25519;
var AUTH_ACTION = "chan-open";
var MAX_LIFETIME = 900;
var HEADER_LEN = 11;
var TAG_LEN = 16;
var BUCKETS = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
var MAX_BODY = 65532;
var MAX_COUNTER = 4294967295;
var KEM_PK_LEN = 1184;
var KEM_CT_LEN = 1088;
var FLAG_MORE = 1;
var TYPES = {
  TURN: 0x01, ATTACH: 0x02, STEER: 0x03, ANSWER: 0x04, APPROVE: 0x05, RESUME: 0x06, CANCEL: 0x07, JOIN: 0x08,
  ACCEPT: 0x41, DRAFT: 0x42, PLAN: 0x43, STEP: 0x44, PARK: 0x46, REPLY: 0x47, ERROR: 0x48,
  CLOSE: 0x7e, ABORT: 0x7f
};
var CLIENT_TYPES = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x7e, 0x7f];
var SERVER_TYPES = [0x41, 0x42, 0x43, 0x44, 0x46, 0x47, 0x48, 0x7e, 0x7f];
var CERT_TAGS = ["v", "p", "nonce", "x", "s", "kem", "expiration"];
var AUTH_TAGS = "action,method,payload,u";
var HEX64 = /^[0-9a-f]{64}$/;
var RUN_ID = /^[\x21-\x7e]{1,128}$/;
var RUN_PHASES = ["live", "park", "done"];
var ASK_KINDS = ["question", "plan", "tool", "connector"];
var RUN_TAGS = ["nymbot-run", "nymbot-ctl", "nymbot-resume", "nymbot-ask"];
var CTL_DIRS = ["c2s", "s2c"];
var PKCS8_X25519 = hexToBytes("302e020100300506032b656e04220420");
var X25519 = { name: "X25519" };

function chanError(code) {
  var e = new Error("channel: " + code);
  e.code = code;
  return e;
}

function nowSec() {
  return Math.floor(Date.now() / 1000);
}

function label(s) {
  return utf8ToBytes(PROTO + s);
}

function be32(n) {
  return new Uint8Array([(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
}

function be64(n) {
  return concatBytes(be32(Math.floor(n / 4294967296)), be32(n >>> 0));
}

function readBe32(b, i) {
  return ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];
}

async function x25519Pair(sk) {
  if (sk !== undefined && sk !== null) {
    if (!(sk instanceof Uint8Array) || sk.length !== 32) throw chanError("malformed");
    var priv = await crypto.subtle.importKey("pkcs8", concatBytes(PKCS8_X25519, sk), X25519, true, ["deriveBits"]);
    var jwk = await crypto.subtle.exportKey("jwk", priv);
    return { priv: priv, pub: b64uDecode(jwk.x) };
  }
  var kp = await crypto.subtle.generateKey(X25519, false, ["deriveBits"]);
  return { priv: kp.privateKey, pub: new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey)) };
}

async function x25519Dh(priv, peer) {
  if (!(peer instanceof Uint8Array) || peer.length !== 32) throw chanError("malformed");
  var bits;
  try {
    var pub = await crypto.subtle.importKey("raw", peer, X25519, false, []);
    bits = new Uint8Array(await crypto.subtle.deriveBits({ name: "X25519", public: pub }, priv, 256));
  } catch (e) {
    throw chanError("low-order");
  }
  var acc = 0;
  for (var i = 0; i < bits.length; i++) acc |= bits[i];
  if (acc === 0) throw chanError("low-order");
  return bits;
}

async function x25519Public(sk) {
  return (await x25519Pair(sk)).pub;
}

async function x25519Shared(sk, peer) {
  return x25519Dh((await x25519Pair(sk)).priv, peer);
}

function canonicalHello(h) {
  return JSON.stringify({ n: h.n, u: h.u, v: h.v, x: h.x });
}

function helloPayload(h) {
  return bytesToHex(sha256(utf8ToBytes(canonicalHello(h))));
}

function checkHelloShape(h) {
  if (!h || typeof h !== "object" || Array.isArray(h)) throw chanError("malformed");
  var keys = Object.keys(h).sort().join(",");
  if (keys !== "n,u,v,x" || !Number.isSafeInteger(h.v)) throw chanError("malformed");
  if (h.v !== VERSION) throw chanError("version");
  if (!HEX64.test(h.x) || !HEX64.test(h.n) || !HEX64.test(h.u)) throw chanError("malformed");
}

function verifyHello(hello, auth, url) {
  checkHelloShape(hello);
  var tags = auth && Array.isArray(auth.tags) ? auth.tags : [];
  var names = tags.map(function (t) { return Array.isArray(t) && t.length === 2 && typeof t[1] === "string" ? String(t[0]) : "!"; });
  if (names.slice().sort().join(",") !== AUTH_TAGS) throw chanError("auth");
  if (!verifyClientAuth(auth, hello.u, { action: AUTH_ACTION, url: url, body: hello })) throw chanError("auth");
  return true;
}

function eventSigOk(evt) {
  try {
    return getEventHash(evt) === evt.id && schnorr.verify(evt.sig, evt.id, evt.pubkey);
  } catch (e) {
    return false;
  }
}

function parseCert(cert, botPk) {
  if (!cert || typeof cert !== "object" || cert.kind !== CERT_KIND || cert.content !== "" ||
    !Array.isArray(cert.tags) || cert.tags.length !== CERT_TAGS.length) throw chanError("malformed");
  var t = {};
  for (var i = 0; i < cert.tags.length; i++) {
    var tag = cert.tags[i];
    if (!Array.isArray(tag) || tag.length !== 2 || typeof tag[0] !== "string" || typeof tag[1] !== "string" ||
      CERT_TAGS.indexOf(tag[0]) < 0 || Object.prototype.hasOwnProperty.call(t, tag[0])) throw chanError("malformed");
    t[tag[0]] = tag[1];
  }
  if (!HEX64.test(t.p) || !HEX64.test(t.nonce) || !HEX64.test(t.x) || !HEX64.test(t.s) ||
    !/^[1-9][0-9]{0,11}$/.test(t.expiration) || !/^[A-Za-z0-9_-]+$/.test(t.kem)) throw chanError("malformed");
  if (typeof cert.pubkey !== "string" || !HEX64.test(cert.pubkey) || !Number.isSafeInteger(cert.created_at) ||
    cert.created_at <= 0 || typeof cert.id !== "string" || typeof cert.sig !== "string") throw chanError("malformed");
  if (botPk !== undefined && cert.pubkey !== botPk) throw chanError("wrong-bot");
  if (!eventSigOk(cert)) throw chanError("bad-sig");
  if (t.v !== String(VERSION)) throw chanError("version");
  var kem;
  try { kem = b64uDecode(t.kem); } catch (e) { throw chanError("bad-kem"); }
  if (kem.length !== KEM_PK_LEN) throw chanError("bad-kem");
  var iat = cert.created_at;
  var exp = Number(t.expiration);
  if (exp <= iat || exp - iat > MAX_LIFETIME) throw chanError("lifetime");
  return { id: cert.id, bot: cert.pubkey, user: t.p, nonce: t.nonce, x: t.x, s: t.s, kem: kem, iat: iat, exp: exp };
}

function fingerprintHex(c) {
  return bytesToHex(sha256(concatBytes(label("/fp"), hexToBytes(c.x), hexToBytes(c.s), c.kem)).subarray(0, 16));
}

function transcript(f) {
  return sha256(concatBytes(
    label("/th"), new Uint8Array([VERSION]),
    hexToBytes(f.user), hexToBytes(f.cx), hexToBytes(f.nonce), hexToBytes(f.authId),
    hexToBytes(f.botPk), hexToBytes(f.certId), hexToBytes(f.x), hexToBytes(f.s), f.kem,
    be64(f.iat), be64(f.exp), f.kemCt
  ));
}

function deriveKeys(th, dh, kemSs) {
  var ikm = concatBytes(dh, kemSs);
  var prk = hmac(sha256, th, ikm);
  var keys = {
    c2sKey: hkdfExpand(prk, label(" c2s key"), 32),
    c2sIv: hkdfExpand(prk, label(" c2s iv"), 12),
    s2cKey: hkdfExpand(prk, label(" s2c key"), 32),
    s2cIv: hkdfExpand(prk, label(" s2c iv"), 12)
  };
  ikm.fill(0);
  prk.fill(0);
  return keys;
}

function wipeKeys(keys) {
  keys.c2sKey.fill(0);
  keys.c2sIv.fill(0);
  keys.s2cKey.fill(0);
  keys.s2cIv.fill(0);
}

function certEvent(botSk, now, exp, f, aux) {
  var cert = {
    kind: CERT_KIND,
    pubkey: getPublicKey(botSk),
    created_at: now,
    tags: [
      ["v", String(VERSION)], ["p", f.user], ["nonce", f.nonce], ["x", f.x],
      ["s", f.s], ["kem", f.kem], ["expiration", String(exp)]
    ],
    content: ""
  };
  cert.id = getEventHash(cert);
  cert.sig = bytesToHex(schnorr.sign(cert.id, botSk, aux || randomBytes(32)));
  return cert;
}

function pqFromRoot(given) {
  var root = given || randomBytes(32);
  var kp = pqKeypairFromRoot(root, 0);
  root.fill(0);
  return kp;
}

function newSealKey() {
  for (;;) {
    var sk = bytesToHex(randomBytes(32));
    try { getPublicKey(sk); return sk; } catch (e) {}
  }
}

async function serverAccept(o) {
  var ttl = o.ttl === undefined ? MAX_LIFETIME : o.ttl;
  if (!Number.isSafeInteger(ttl) || ttl <= 0 || ttl > MAX_LIFETIME) throw chanError("lifetime");
  var hello = o.hello;
  checkHelloShape(hello);
  if (!HEX64.test(o.authId)) throw chanError("malformed");
  var now = o.now === undefined ? nowSec() : o.now;
  var xp = await x25519Pair(o.xSk);
  var dh = await x25519Dh(xp.priv, hexToBytes(hello.x));
  var kp = pqFromRoot(o.root);
  var sSk = o.sSk || newSealKey();
  var sPk = getPublicKey(sSk);
  var exp = now + ttl;
  var cert = certEvent(o.botSk, now, exp, {
    user: hello.u, nonce: hello.n, x: bytesToHex(xp.pub), s: sPk, kem: b64uEncode(kp.publicKey)
  }, o.aux);
  xp.priv = null;
  return {
    cert: cert,
    secret: {
      hello: hello, authId: o.authId, botPk: cert.pubkey, certId: cert.id, iat: now, exp: exp,
      xPriv: null, dh: dh, xPub: bytesToHex(xp.pub), kemSk: kp.secretKey, kemPk: kp.publicKey, sSk: sSk, sPk: sPk,
      finished: false
    }
  };
}

async function sealCert(o) {
  if (!HEX64.test(String(o.userPk))) throw chanError("malformed");
  var now = o.now === undefined ? nowSec() : o.now;
  var xp = await x25519Pair();
  xp.priv = null;
  var kp = pqFromRoot();
  kp.secretKey.fill(0);
  var sSk = newSealKey();
  var cert = certEvent(o.botSk, now, now + MAX_LIFETIME, {
    user: o.userPk, nonce: bytesToHex(randomBytes(32)), x: bytesToHex(xp.pub), s: getPublicKey(sSk), kem: b64uEncode(kp.publicKey)
  });
  return { cert: cert, sSk: sSk };
}

function dropSeal(secret) {
  if (secret) secret.sSk = null;
}

async function serverFinish(o) {
  var s = o.secret;
  if (!s || s.finished || !s.dh) throw chanError("malformed");
  s.finished = true;
  if (!(o.kemCt instanceof Uint8Array) || o.kemCt.length !== KEM_CT_LEN) {
    s.dh.fill(0);
    s.dh = null;
    s.kemSk.fill(0);
    throw chanError("bad-kem");
  }
  var dh = s.dh;
  var kemSs = ml_kem768.decapsulate(o.kemCt, s.kemSk);
  var th = transcript({
    user: s.hello.u, cx: s.hello.x, nonce: s.hello.n, authId: s.authId, botPk: s.botPk, certId: s.certId,
    x: s.xPub, s: s.sPk, kem: s.kemPk, iat: s.iat, exp: s.exp, kemCt: o.kemCt
  });
  var keys = deriveKeys(th, dh, kemSs);
  dh.fill(0);
  s.dh = null;
  kemSs.fill(0);
  s.kemSk.fill(0);
  s.xPriv = null;
  var state = stateFromKeys("server", keys, s.exp);
  wipeKeys(keys);
  return { transcript: th, state: state };
}

function stateFromKeys(role, keys, exp) {
  if (role !== "client" && role !== "server") throw chanError("malformed");
  var c = role === "client";
  return {
    role: role,
    exp: exp,
    sendKey: (c ? keys.c2sKey : keys.s2cKey).slice(),
    sendIv: (c ? keys.c2sIv : keys.s2cIv).slice(),
    recvKey: (c ? keys.s2cKey : keys.c2sKey).slice(),
    recvIv: (c ? keys.s2cIv : keys.c2sIv).slice(),
    sendTypes: c ? CLIENT_TYPES : SERVER_TYPES,
    recvTypes: c ? SERVER_TYPES : CLIENT_TYPES,
    sendCtr: 0,
    recvCtr: 0,
    sentClose: false,
    recvClose: false,
    dead: false
  };
}

function kill(st) {
  st.dead = true;
  st.sendKey.fill(0);
  st.recvKey.fill(0);
  st.sendIv.fill(0);
  st.recvIv.fill(0);
}

function bucketFor(n) {
  for (var i = 0; i < BUCKETS.length; i++) if (BUCKETS[i] >= n + 4) return BUCKETS[i];
  return 0;
}

function nonceFor(iv, ctr) {
  var n = iv.slice();
  var c = be64(ctr);
  for (var i = 0; i < 8; i++) n[4 + i] ^= c[i];
  return n;
}

function header(type, flags, ctr) {
  return concatBytes(new Uint8Array([VERSION, type, flags]), be64(ctr));
}

function sealFrame(st, type, body, opts) {
  opts = opts || {};
  if (st.dead) throw chanError("dead");
  if (st.sentClose) throw chanError("closed");
  var flags = opts.flags !== undefined ? opts.flags : (opts.more ? FLAG_MORE : 0);
  if (!Number.isInteger(flags) || (flags & ~FLAG_MORE) !== 0) throw chanError("malformed");
  if (st.sendTypes.indexOf(type) < 0) throw chanError("type");
  if ((type === TYPES.CLOSE || type === TYPES.ABORT) && (flags & FLAG_MORE)) throw chanError("malformed");
  if (!(body instanceof Uint8Array)) throw chanError("malformed");
  if (body.length > MAX_BODY) throw chanError("oversize");
  var now = opts.now === undefined ? nowSec() : opts.now;
  if (now >= st.exp) { kill(st); throw chanError("expired"); }
  if (st.sendCtr > MAX_COUNTER) { kill(st); throw chanError("exhausted"); }
  var p = new Uint8Array(bucketFor(body.length));
  p.set(be32(body.length), 0);
  p.set(body, 4);
  var h = header(type, flags, st.sendCtr);
  var out = concatBytes(h, chacha20poly1305Encrypt(st.sendKey, nonceFor(st.sendIv, st.sendCtr), p, h));
  st.sendCtr++;
  if (type === TYPES.CLOSE) st.sentClose = true;
  if (type === TYPES.ABORT) kill(st);
  return out;
}

function openFrame(st, frame, now) {
  if (st.dead) throw chanError("dead");
  if (st.recvClose) throw chanError("closed");
  if (now === undefined) now = nowSec();
  try {
    if (!(frame instanceof Uint8Array) || BUCKETS.indexOf(frame.length - HEADER_LEN - TAG_LEN) < 0) throw chanError("malformed");
    if (frame[0] !== VERSION) throw chanError("version");
    var type = frame[1];
    var flags = frame[2];
    if ((flags & ~FLAG_MORE) !== 0) throw chanError("malformed");
    var ctr = readBe32(frame, 3) * 4294967296 + readBe32(frame, 7);
    if (ctr !== st.recvCtr) throw chanError("counter");
    if (st.recvTypes.indexOf(type) < 0) throw chanError("type");
    if ((type === TYPES.CLOSE || type === TYPES.ABORT) && (flags & FLAG_MORE)) throw chanError("malformed");
    if (now >= st.exp) throw chanError("expired");
    var p;
    try {
      p = chacha20poly1305Decrypt(st.recvKey, nonceFor(st.recvIv, ctr), frame.subarray(HEADER_LEN), frame.subarray(0, HEADER_LEN));
    } catch (e) {
      throw chanError("tamper");
    }
    var len = readBe32(p, 0);
    if (len > p.length - 4) throw chanError("padding");
    for (var i = 4 + len; i < p.length; i++) if (p[i] !== 0) throw chanError("padding");
    st.recvCtr++;
    var out = { type: type, more: (flags & FLAG_MORE) !== 0, body: p.slice(4, 4 + len) };
    if (type === TYPES.CLOSE) st.recvClose = true;
    if (type === TYPES.ABORT) kill(st);
    return out;
  } catch (e) {
    kill(st);
    throw e;
  }
}

function encodeFrame(frame) {
  return b64uEncode(frame);
}

function decodeFrame(text) {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]+$/.test(text)) throw chanError("malformed");
  try { return b64uDecode(text); } catch (e) { throw chanError("malformed"); }
}

function resumeAad(run, userPk) {
  if (typeof run !== "string" || !run || !HEX64.test(userPk)) throw chanError("malformed");
  return concatBytes(label("/resume"), hexToBytes(userPk), utf8ToBytes(run));
}

function controlAad(dir, run, userPk) {
  if (CTL_DIRS.indexOf(dir) < 0 || typeof run !== "string" || !run || !HEX64.test(userPk)) throw chanError("malformed");
  return concatBytes(label("/ctl " + dir), hexToBytes(userPk), utf8ToBytes(run));
}

function newResumeKey() {
  return randomBytes(32);
}

function blobSeal(k, nonce, text, aad) {
  if (!(k instanceof Uint8Array) || k.length !== 32 || typeof text !== "string") throw chanError("malformed");
  var n = nonce || randomBytes(12);
  return b64uEncode(concatBytes(new Uint8Array([VERSION]), n, chacha20poly1305Encrypt(k, n, utf8ToBytes(text), aad)));
}

function blobOpen(k, blob, aad) {
  if (!(k instanceof Uint8Array) || k.length !== 32) throw chanError("malformed");
  var b = decodeFrame(blob);
  if (b.length < 1 + 12 + TAG_LEN || b[0] !== VERSION) throw chanError("malformed");
  try {
    return new TextDecoder().decode(chacha20poly1305Decrypt(k, b.subarray(1, 13), b.subarray(13), aad));
  } catch (e) {
    throw chanError("tamper");
  }
}

function resumeSeal(o) {
  return blobSeal(o.k, o.nonce, o.state, resumeAad(o.run, o.userPk));
}

function resumeOpen(o) {
  if (!(o.k instanceof Uint8Array) || o.k.length !== 32) throw chanError("malformed");
  return blobOpen(o.k, o.blob, resumeAad(o.run, o.userPk));
}

function controlSeal(o) {
  return blobSeal(o.c, o.nonce, o.body, controlAad(o.dir, o.run, o.userPk));
}

function controlOpen(o) {
  if (!(o.c instanceof Uint8Array) || o.c.length !== 32) throw chanError("malformed");
  return blobOpen(o.c, o.blob, controlAad(o.dir, o.run, o.userPk));
}

function controlId(c) {
  if (!(c instanceof Uint8Array) || c.length !== 32) throw chanError("malformed");
  return bytesToHex(sha256(concatBytes(label("/ctl-id"), c)));
}

function openTurnSeal(o) {
  var s = o.secret;
  var seal = o.seal;
  if (!seal || typeof seal !== "object" || seal.kind !== 13 || typeof seal.content !== "string" || !HEX64.test(String(seal.pubkey))) {
    throw chanError("malformed");
  }
  if (!eventSigOk(seal)) throw chanError("bad-sig");
  if (seal.pubkey !== s.hello.u) throw chanError("wrong-user");
  if (!s.sSk) throw chanError("dead");
  var json;
  try {
    json = nip44Decrypt(seal.content, nip44ConversationKey(s.sSk, seal.pubkey));
  } catch (e) {
    throw chanError("tamper");
  }
  var rumor;
  try {
    rumor = JSON.parse(json);
  } catch (e) {
    throw chanError("malformed");
  }
  if (!rumor || typeof rumor !== "object" || rumor.kind !== 14 || typeof rumor.content !== "string" || !Array.isArray(rumor.tags)) {
    throw chanError("malformed");
  }
  if (rumor.pubkey !== seal.pubkey) throw chanError("wrong-user");
  return rumor;
}

function runKey(t) {
  if (!t) return null;
  if (t.length !== 2 || !HEX64.test(t[1])) throw chanError("malformed");
  return t[1];
}

function readRunTags(rumor) {
  if (!rumor || !Array.isArray(rumor.tags) || typeof rumor.content !== "string") throw chanError("malformed");
  var seen = {};
  for (var i = 0; i < rumor.tags.length; i++) {
    var t = rumor.tags[i];
    if (Array.isArray(t) && RUN_TAGS.indexOf(t[0]) >= 0) {
      if (seen[t[0]]) throw chanError("malformed");
      seen[t[0]] = t;
    }
  }
  var r = seen["nymbot-run"];
  if (!r || r.length !== 3 || typeof r[1] !== "string" || !RUN_ID.test(r[1]) || RUN_PHASES.indexOf(r[2]) < 0) throw chanError("malformed");
  var phase = r[2];
  var ctl = runKey(seen["nymbot-ctl"]);
  var resume = runKey(seen["nymbot-resume"]);
  var a = seen["nymbot-ask"];
  var ask = null;
  if (a) {
    if (a.length !== 3 || ASK_KINDS.indexOf(a[1]) < 0 || typeof a[2] !== "string" || !a[2]) throw chanError("malformed");
    var body;
    try {
      body = JSON.parse(rumor.content);
    } catch (e) {
      throw chanError("malformed");
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) throw chanError("malformed");
    ask = { kind: a[1], q: a[2], body: body };
  }
  var waiting = phase === "live";
  if (waiting !== !!ctl || (waiting && resume) || (phase === "park" && !resume) || (phase === "park") !== !!ask) {
    throw chanError("malformed");
  }
  return { run: r[1], phase: phase, ctl: ctl, resume: resume, ask: ask, text: phase === "done" ? rumor.content : null };
}

function runRumor(o) {
  var c = parseCert(o.cert);
  var tags = [["p", c.user], ["nymbot-cert", JSON.stringify(o.cert)], ["nymbot-run", o.run, o.phase]];
  if (o.ctl) tags.push(["nymbot-ctl", o.ctl]);
  if (o.resume) tags.push(["nymbot-resume", o.resume]);
  if (o.ask) tags.push(["nymbot-ask", o.ask[0], o.ask[1]]);
  var rumor = {
    kind: 14,
    pubkey: c.s,
    created_at: o.createdAt === undefined ? nowSec() : o.createdAt,
    tags: tags,
    content: o.content === undefined ? "" : o.content
  };
  readRunTags(rumor);
  return rumor;
}

export {
  PROTO,
  TYPES,
  FLAG_MORE,
  MAX_BODY,
  MAX_LIFETIME,
  x25519Public,
  x25519Shared,
  canonicalHello,
  helloPayload,
  verifyHello,
  parseCert,
  fingerprintHex,
  serverAccept,
  serverFinish,
  sealCert,
  dropSeal,
  stateFromKeys,
  sealFrame,
  openFrame,
  encodeFrame,
  decodeFrame,
  newResumeKey,
  resumeSeal,
  resumeOpen,
  controlSeal,
  controlOpen,
  controlId,
  openTurnSeal,
  readRunTags,
  runRumor
};
