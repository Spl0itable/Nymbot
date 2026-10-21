(function (root) {
    'use strict';

    const NT = () => root.NostrTools;
    const KEM = () => root.NymMlKem.ml_kem768;
    const enc = new TextEncoder();

    const PROTO = 'nymbot-chan/1';
    const VERSION = 1;
    const CERT_KIND = 25519;
    const AUTH_KIND = 27235;
    const AUTH_ACTION = 'chan-open';
    const MAX_LIFETIME = 900;
    const CLOCK_SKEW = 120;
    const REPLY_BEFORE = 60;
    const REPLY_AFTER = 3600;
    const HEADER_LEN = 11;
    const TAG_LEN = 16;
    const BUCKETS = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];
    const MAX_BODY = 65532;
    const MAX_COUNTER = 4294967295;
    const KEM_PK_LEN = 1184;
    const FLAG_MORE = 1;
    const FP_HRP = 'nymchan';
    const TYPES = Object.freeze({
        TURN: 0x01, ATTACH: 0x02, STEER: 0x03, ANSWER: 0x04, APPROVE: 0x05, RESUME: 0x06, CANCEL: 0x07, JOIN: 0x08,
        ACCEPT: 0x41, DRAFT: 0x42, PLAN: 0x43, STEP: 0x44, PARK: 0x46, REPLY: 0x47, ERROR: 0x48,
        CLOSE: 0x7e, ABORT: 0x7f
    });
    const CLIENT_TYPES = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x7e, 0x7f];
    const SERVER_TYPES = [0x41, 0x42, 0x43, 0x44, 0x46, 0x47, 0x48, 0x7e, 0x7f];
    const CERT_TAGS = ['v', 'p', 'nonce', 'x', 's', 'kem', 'expiration'];
    const HEX64 = /^[0-9a-f]{64}$/;
    const RUN_ID = /^[\x21-\x7e]{1,128}$/;
    const RUN_PHASES = ['live', 'park', 'done'];
    const ASK_KINDS = ['question', 'plan', 'tool', 'connector'];
    const RUN_TAGS = ['nymbot-run', 'nymbot-ctl', 'nymbot-resume', 'nymbot-ask'];
    const X25519 = { name: 'X25519' };

    function chanError(code) {
        const e = new Error('channel: ' + code);
        e.code = code;
        return e;
    }

    const nowSec = () => Math.floor(Date.now() / 1000);
    const label = (s) => enc.encode(PROTO + s);
    const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    const unhex = (s) => {
        const out = new Uint8Array(s.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
        return out;
    };
    const concat = (...parts) => {
        const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
        let o = 0;
        for (const p of parts) { out.set(p, o); o += p.length; }
        return out;
    };
    const b64uEncode = (b) => {
        let s = '';
        for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
        return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    };
    const b64uDecode = (str) => {
        let s = String(str).replace(/-/g, '+').replace(/_/g, '/');
        while (s.length % 4) s += '=';
        const bin = atob(s);
        const out = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    };
    const be32 = (n) => new Uint8Array([(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
    const be64 = (n) => concat(be32(Math.floor(n / 4294967296)), be32(n >>> 0));
    const readBe32 = (b, i) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];
    const sha256 = (b) => NT()._sha256(b);
    const random = (n) => crypto.getRandomValues(new Uint8Array(n));
    const PKCS8_X25519 = unhex('302e020100300506032b656e04220420');

    async function x25519Pair(sk) {
        if (sk !== undefined && sk !== null) {
            if (!(sk instanceof Uint8Array) || sk.length !== 32) throw chanError('malformed');
            const priv = await crypto.subtle.importKey('pkcs8', concat(PKCS8_X25519, sk), X25519, true, ['deriveBits']);
            const jwk = await crypto.subtle.exportKey('jwk', priv);
            return { priv, pub: b64uDecode(jwk.x) };
        }
        const kp = await crypto.subtle.generateKey(X25519, false, ['deriveBits']);
        return { priv: kp.privateKey, pub: new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey)) };
    }

    async function x25519Dh(priv, peer) {
        if (!(peer instanceof Uint8Array) || peer.length !== 32) throw chanError('malformed');
        let bits;
        try {
            const pub = await crypto.subtle.importKey('raw', peer, X25519, false, []);
            bits = new Uint8Array(await crypto.subtle.deriveBits({ name: 'X25519', public: pub }, priv, 256));
        } catch (_) {
            throw chanError('low-order');
        }
        if (bits.every((b) => b === 0)) throw chanError('low-order');
        return bits;
    }

    const x25519Public = async (sk) => (await x25519Pair(sk)).pub;
    const x25519Shared = async (sk, peer) => x25519Dh((await x25519Pair(sk)).priv, peer);

    const canonicalHello = (h) => JSON.stringify({ n: h.n, u: h.u, v: h.v, x: h.x });
    const helloPayload = (h) => hex(sha256(enc.encode(canonicalHello(h))));

    async function newHello(userPk, opts) {
        const o = opts || {};
        if (!HEX64.test(userPk)) throw chanError('malformed');
        const xp = await x25519Pair(o.xSk);
        const nonce = o.nonce || random(32);
        if (!(nonce instanceof Uint8Array) || nonce.length !== 32) throw chanError('malformed');
        return { hello: { v: VERSION, x: hex(xp.pub), n: hex(nonce), u: userPk }, secret: { xPriv: xp.priv } };
    }

    function authTemplate(hello, url, createdAt) {
        return {
            kind: AUTH_KIND,
            pubkey: hello.u,
            created_at: createdAt === undefined ? nowSec() : createdAt,
            tags: [['u', url], ['method', 'POST'], ['action', AUTH_ACTION], ['payload', helloPayload(hello)]],
            content: ''
        };
    }

    function eventSigOk(evt) {
        try {
            const copy = { kind: evt.kind, pubkey: evt.pubkey, created_at: evt.created_at, tags: evt.tags, content: evt.content, id: evt.id, sig: evt.sig };
            return NT().getEventHash(copy) === evt.id && NT().verifyEvent(copy) === true;
        } catch (_) {
            return false;
        }
    }

    function parseCert(cert, botPk) {
        if (!cert || typeof cert !== 'object' || cert.kind !== CERT_KIND || cert.content !== '' ||
            !Array.isArray(cert.tags) || cert.tags.length !== CERT_TAGS.length) throw chanError('malformed');
        const t = {};
        for (const tag of cert.tags) {
            if (!Array.isArray(tag) || tag.length !== 2 || typeof tag[0] !== 'string' || typeof tag[1] !== 'string' ||
                !CERT_TAGS.includes(tag[0]) || Object.prototype.hasOwnProperty.call(t, tag[0])) throw chanError('malformed');
            t[tag[0]] = tag[1];
        }
        if (!HEX64.test(t.p) || !HEX64.test(t.nonce) || !HEX64.test(t.x) || !HEX64.test(t.s) ||
            !/^[1-9][0-9]{0,11}$/.test(t.expiration) || !/^[A-Za-z0-9_-]+$/.test(t.kem)) throw chanError('malformed');
        if (typeof cert.pubkey !== 'string' || !HEX64.test(cert.pubkey) || !Number.isSafeInteger(cert.created_at) ||
            cert.created_at <= 0 || typeof cert.id !== 'string' || typeof cert.sig !== 'string') throw chanError('malformed');
        if (cert.pubkey !== botPk) throw chanError('wrong-bot');
        if (!eventSigOk(cert)) throw chanError('bad-sig');
        if (t.v !== String(VERSION)) throw chanError('version');
        let kem;
        try { kem = b64uDecode(t.kem); } catch (_) { throw chanError('bad-kem'); }
        if (kem.length !== KEM_PK_LEN) throw chanError('bad-kem');
        const iat = cert.created_at;
        const exp = Number(t.expiration);
        if (exp <= iat || exp - iat > MAX_LIFETIME) throw chanError('lifetime');
        return { id: cert.id, bot: cert.pubkey, user: t.p, nonce: t.nonce, x: t.x, s: t.s, kem, iat, exp };
    }

    function verifyCert(cert, o) {
        const c = parseCert(cert, o.botPk);
        if (c.user !== o.userPk) throw chanError('wrong-user');
        if (c.nonce !== o.nonce) throw chanError('wrong-nonce');
        const now = o.now === undefined ? nowSec() : o.now;
        if (c.iat > now + CLOCK_SKEW) throw chanError('future');
        if (now >= c.exp) throw chanError('expired');
        return c;
    }

    function checkReplyCert(rumor, o) {
        if (!rumor || typeof rumor !== 'object' || !Array.isArray(rumor.tags) || !Number.isSafeInteger(rumor.created_at)) throw chanError('malformed');
        const found = rumor.tags.filter((t) => Array.isArray(t) && t[0] === 'nymbot-cert');
        if (found.length !== 1 || typeof found[0][1] !== 'string') throw chanError('malformed');
        let cert;
        try { cert = JSON.parse(found[0][1]); } catch (_) { throw chanError('malformed'); }
        const c = parseCert(cert, o.botPk);
        if (c.user !== o.userPk) throw chanError('wrong-user');
        if (rumor.pubkey !== c.s) throw chanError('wrong-seal');
        const seal = o.seal;
        if (!seal || typeof seal !== 'object' || seal.kind !== 13 || seal.pubkey !== c.s || !eventSigOk(seal)) throw chanError('wrong-seal');
        if (rumor.created_at < c.iat - REPLY_BEFORE || rumor.created_at > c.exp + REPLY_AFTER) throw chanError('window');
        return c;
    }

    function runKey(t) {
        if (!t) return null;
        if (t.length !== 2 || !HEX64.test(t[1])) throw chanError('malformed');
        return t[1];
    }

    function readRunTags(rumor) {
        if (!rumor || !Array.isArray(rumor.tags) || typeof rumor.content !== 'string') throw chanError('malformed');
        const seen = {};
        for (const t of rumor.tags) {
            if (Array.isArray(t) && RUN_TAGS.includes(t[0])) {
                if (seen[t[0]]) throw chanError('malformed');
                seen[t[0]] = t;
            }
        }
        const r = seen['nymbot-run'];
        if (!r || r.length !== 3 || typeof r[1] !== 'string' || !RUN_ID.test(r[1]) || !RUN_PHASES.includes(r[2])) throw chanError('malformed');
        const phase = r[2];
        const ctl = runKey(seen['nymbot-ctl']);
        const resume = runKey(seen['nymbot-resume']);
        const a = seen['nymbot-ask'];
        let ask = null;
        if (a) {
            if (a.length !== 3 || !ASK_KINDS.includes(a[1]) || typeof a[2] !== 'string' || !a[2]) throw chanError('malformed');
            let body;
            try { body = JSON.parse(rumor.content); } catch (_) { throw chanError('malformed'); }
            if (!body || typeof body !== 'object' || Array.isArray(body)) throw chanError('malformed');
            ask = { kind: a[1], q: a[2], body };
        }
        const waiting = phase === 'live';
        if (waiting !== !!ctl || (waiting && resume) || (phase === 'park' && !resume) || (phase === 'park') !== !!ask) {
            throw chanError('malformed');
        }
        return { run: r[1], phase, ctl, resume, ask, text: phase === 'done' ? rumor.content : null };
    }

    function readRunRumor(rumor, o) {
        const cert = checkReplyCert(rumor, o);
        return { cert, ...readRunTags(rumor) };
    }

    function sealTurn(rumor, userSk, c, opts) {
        const o = opts || {};
        const T = NT();
        if (!rumor || typeof rumor !== 'object' || rumor.kind !== 14 || !c || !HEX64.test(String(c.s))) throw chanError('malformed');
        if (rumor.pubkey !== T.getPublicKey(userSk)) throw chanError('wrong-user');
        const conv = T.nip44.getConversationKey(userSk, c.s);
        const json = JSON.stringify(rumor);
        const content = o.nonce ? T.nip44.v2.encrypt(json, conv, o.nonce) : T.nip44.v2.encrypt(json, conv);
        return T.finalizeEvent({ kind: 13, created_at: o.createdAt === undefined ? nowSec() : o.createdAt, tags: [], content }, userSk);
    }

    const fingerprintBytes = (c) => sha256(concat(label('/fp'), unhex(c.x), unhex(c.s), c.kem)).subarray(0, 16);
    const fingerprintHex = (c) => hex(fingerprintBytes(c));
    const fingerprint = (c) => NT().nip19.encodeBytes(FP_HRP, fingerprintBytes(c));

    function transcript(f) {
        return sha256(concat(
            label('/th'), new Uint8Array([VERSION]),
            unhex(f.user), unhex(f.cx), unhex(f.nonce), unhex(f.authId),
            unhex(f.botPk), unhex(f.certId), unhex(f.x), unhex(f.s), f.kem,
            be64(f.iat), be64(f.exp), f.kemCt
        ));
    }

    function deriveKeys(th, dh, kemSs) {
        const T = NT();
        const ikm = concat(dh, kemSs);
        const prk = T._hkdfExtract(T._sha256, ikm, th);
        const ex = (info, n) => T._hkdfExpand(T._sha256, prk, label(info), n);
        const keys = { c2sKey: ex(' c2s key', 32), c2sIv: ex(' c2s iv', 12), s2cKey: ex(' s2c key', 32), s2cIv: ex(' s2c iv', 12) };
        ikm.fill(0);
        prk.fill(0);
        return keys;
    }

    async function clientFinish(o) {
        const c = o.cert;
        const hello = o.hello;
        if (c.bot !== o.botPk) throw chanError('wrong-bot');
        if (!HEX64.test(o.authId)) throw chanError('malformed');
        const dh = await x25519Dh(o.secret.xPriv, unhex(c.x));
        let kem;
        try { kem = KEM().encapsulate(c.kem, o.kemMsg); } catch (_) { throw chanError('bad-kem'); }
        const kemCt = kem.cipherText;
        const th = transcript({
            user: hello.u, cx: hello.x, nonce: hello.n, authId: o.authId, botPk: c.bot, certId: c.id,
            x: c.x, s: c.s, kem: c.kem, iat: c.iat, exp: c.exp, kemCt
        });
        const keys = deriveKeys(th, dh, kem.sharedSecret);
        dh.fill(0);
        kem.sharedSecret.fill(0);
        const state = stateFromKeys('client', keys, c.exp);
        for (const k of [keys.c2sKey, keys.c2sIv, keys.s2cKey, keys.s2cIv]) k.fill(0);
        o.secret.xPriv = null;
        return { kemCt, transcript: th, state };
    }

    function stateFromKeys(role, keys, exp) {
        if (role !== 'client' && role !== 'server') throw chanError('malformed');
        const c = role === 'client';
        return {
            role,
            exp,
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

    const bucketFor = (n) => BUCKETS.find((b) => b >= n + 4) || 0;
    const header = (type, flags, ctr) => concat(new Uint8Array([VERSION, type, flags]), be64(ctr));
    function nonceFor(iv, ctr) {
        const n = iv.slice();
        const c = be64(ctr);
        for (let i = 0; i < 8; i++) n[4 + i] ^= c[i];
        return n;
    }

    function sealFrame(st, type, body, opts) {
        const o = opts || {};
        if (st.dead) throw chanError('dead');
        if (st.sentClose) throw chanError('closed');
        const flags = o.flags !== undefined ? o.flags : (o.more ? FLAG_MORE : 0);
        if (!Number.isInteger(flags) || (flags & ~FLAG_MORE) !== 0) throw chanError('malformed');
        if (!st.sendTypes.includes(type)) throw chanError('type');
        if ((type === TYPES.CLOSE || type === TYPES.ABORT) && (flags & FLAG_MORE)) throw chanError('malformed');
        if (!(body instanceof Uint8Array)) throw chanError('malformed');
        if (body.length > MAX_BODY) throw chanError('oversize');
        const now = o.now === undefined ? nowSec() : o.now;
        if (now >= st.exp) { kill(st); throw chanError('expired'); }
        if (st.sendCtr > MAX_COUNTER) { kill(st); throw chanError('exhausted'); }
        const p = new Uint8Array(bucketFor(body.length));
        p.set(be32(body.length), 0);
        p.set(body, 4);
        const h = header(type, flags, st.sendCtr);
        const out = concat(h, NT()._chacha20poly1305(st.sendKey, nonceFor(st.sendIv, st.sendCtr), h).encrypt(p));
        st.sendCtr++;
        if (type === TYPES.CLOSE) st.sentClose = true;
        if (type === TYPES.ABORT) kill(st);
        return out;
    }

    function openFrame(st, frame, now) {
        if (st.dead) throw chanError('dead');
        if (st.recvClose) throw chanError('closed');
        const t = now === undefined ? nowSec() : now;
        try {
            if (!(frame instanceof Uint8Array) || !BUCKETS.includes(frame.length - HEADER_LEN - TAG_LEN)) throw chanError('malformed');
            if (frame[0] !== VERSION) throw chanError('version');
            const type = frame[1];
            const flags = frame[2];
            if ((flags & ~FLAG_MORE) !== 0) throw chanError('malformed');
            const ctr = readBe32(frame, 3) * 4294967296 + readBe32(frame, 7);
            if (ctr !== st.recvCtr) throw chanError('counter');
            if (!st.recvTypes.includes(type)) throw chanError('type');
            if ((type === TYPES.CLOSE || type === TYPES.ABORT) && (flags & FLAG_MORE)) throw chanError('malformed');
            if (t >= st.exp) throw chanError('expired');
            let p;
            try {
                p = NT()._chacha20poly1305(st.recvKey, nonceFor(st.recvIv, ctr), frame.subarray(0, HEADER_LEN)).decrypt(frame.subarray(HEADER_LEN));
            } catch (_) {
                throw chanError('tamper');
            }
            const len = readBe32(p, 0);
            if (len > p.length - 4) throw chanError('padding');
            for (let i = 4 + len; i < p.length; i++) if (p[i] !== 0) throw chanError('padding');
            st.recvCtr++;
            const out = { type, more: (flags & FLAG_MORE) !== 0, body: p.slice(4, 4 + len) };
            if (type === TYPES.CLOSE) st.recvClose = true;
            if (type === TYPES.ABORT) kill(st);
            return out;
        } catch (e) {
            kill(st);
            throw e;
        }
    }

    const encodeFrame = (frame) => b64uEncode(frame);
    function decodeFrame(text) {
        if (typeof text !== 'string' || !/^[A-Za-z0-9_-]+$/.test(text)) throw chanError('malformed');
        try { return b64uDecode(text); } catch (_) { throw chanError('malformed'); }
    }

    root.NymbotChannel = Object.freeze({
        PROTO, TYPES, FLAG_MORE, MAX_BODY, MAX_LIFETIME,
        x25519Public, x25519Shared,
        canonicalHello, helloPayload, newHello, authTemplate,
        parseCert, verifyCert, checkReplyCert, readRunRumor, sealTurn, fingerprint, fingerprintHex,
        clientFinish, stateFromKeys, sealFrame, openFrame, encodeFrame, decodeFrame
    });
})(typeof self !== 'undefined' ? self : this);

(function (root) {
    const HEX64 = /^[0-9a-f]{64}$/;
    const TOKEN = /^[0-9a-f]{128}$/;
    const WINDOW = 48;
    const THREAD_WINDOW = 40;
    const KEEP = 40;
    const FOLD_MAX = 40;
    const OPEN_MS = 12000;
    const RENEW_S = 90;
    const JOIN_TRIES = 3;
    const CLAIM_TRIES = 40;
    const LIVE_MS = 6 * 3600 * 1000;
    const nowSec = () => Math.floor(Date.now() / 1000);
    const P = () => root.NymbotChannel;
    const later = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const within = (p, ms) => Promise.race([p, later(ms).then(() => null)]);

    function fail(code) {
        const e = new Error('channel: ' + code);
        e.code = code;
        e.chan = true;
        return e;
    }

    function tagOf(rumor, name) {
        const tags = rumor && Array.isArray(rumor.tags) ? rumor.tags : [];
        return tags.find((x) => Array.isArray(x) && x[0] === name) || null;
    }

    function reference(a) {
        const image = !!a && (a.kind === 'image' || /^image\//.test(String(a.mime || '')));
        return '[' + (image ? 'image' : 'file') + ': ' + String((a && a.name) || (image ? 'image' : 'file')) + ']';
    }

    const BANG = /^\s*!\s*\S/;
    const SEED_HEAD = '[earlier in this conversation]\n';

    function quoted(q) {
        return q ? '> ' + String(q).split('\n').join('\n> ') + '\n\n' : '';
    }

    function historyFor(list, summary, threaded) {
        const size = threaded ? THREAD_WINDOW : WINDOW;
        const upto = summary && Number(summary.upto) > 0 ? Number(summary.upto) : 0;
        const rows = [];
        let skipping = false;
        for (const m of list || []) {
            if (!m) continue;
            if (m.role === 'user') {
                skipping = BANG.test(typeof m.content === 'string' ? m.content : '');
                if (skipping) continue;
            } else if (m.role !== 'assistant' || skipping) continue;
            let body = typeof m.content === 'string' ? m.content : '';
            if (m.role === 'user') body = (m.seed ? SEED_HEAD + m.seed + '\n\n' : '') + quoted(m.quote) + body;
            const refs = Array.isArray(m.attachments) ? m.attachments.map(reference) : [];
            const content = [body].concat(refs).filter(Boolean).join('\n');
            if (!content) continue;
            const at = Number(m.at) || 0;
            if (upto && at <= upto) continue;
            rows.push({ role: m.role, content, at });
        }
        const text = summary && typeof summary.text === 'string' && summary.text ? summary.text : null;
        return { history: rows.slice(-size), fold: rows.slice(0, Math.max(0, rows.length - KEEP)).slice(0, FOLD_MAX), summary: text };
    }

    function contextFor(input) {
        const o = input || {};
        if (o.seed) return { history: [], fold: [], summary: null };
        const list = Array.isArray(o.messages) ? o.messages : [];
        let start = 0;
        for (let i = list.length - 1; i >= 0; i--) {
            if (list[i] && list[i].role === 'user' && list[i].seed) { start = i; break; }
        }
        let summary = null;
        for (let i = list.length - 1; i >= start; i--) {
            const s = list[i] && list[i].role === 'assistant' ? list[i].summary : null;
            if (s && typeof s.text === 'string' && s.text) { summary = s; break; }
        }
        return historyFor(list.slice(start), summary, !!o.threaded);
    }

    const PULL_CAP_MS = 300;

    const pullAllowed = (conv) => !!conv && !conv.anon && !conv.support;

    async function preTurn(o) {
        const opts = o || {};
        const open = Promise.resolve().then(() => (typeof opts.open === 'function' ? opts.open() : null));
        const work = [];
        if (!opts.fresh && typeof opts.fetch === 'function') work.push(Promise.resolve().then(() => opts.fetch()).catch(() => null));
        if (!opts.anon && !opts.fresh && typeof opts.pull === 'function') work.push(Promise.resolve().then(() => opts.pull()).catch(() => null));
        if (!work.length) return await open;
        const cap = Number(opts.cap) > 0 ? Number(opts.cap) : PULL_CAP_MS;
        let timer = null;
        const capped = Promise.race([Promise.all(work), new Promise((r) => { timer = setTimeout(r, cap); })]).finally(() => clearTimeout(timer));
        const both = await Promise.all([open, capped]);
        return both[0];
    }

    function storeRows(list, exclude) {
        const out = [];
        for (const m of list || []) {
            if (!m || (m.role !== 'self' && m.role !== 'bot') || m.pending) continue;
            if (exclude && m.wire === exclude) continue;
            const r = { role: m.role === 'self' ? 'user' : 'assistant', content: typeof m.content === 'string' ? m.content : '', at: Number(m.ts) || 0 };
            if (m.quote) r.quote = String(m.quote);
            if (m.seed) r.seed = String(m.seed);
            if (Array.isArray(m.attachments) && m.attachments.length) r.attachments = m.attachments.map((x) => ({ kind: x && x.kind, name: x && x.name, mime: x && x.mime }));
            const cs = m.chanSummary;
            if (cs && typeof cs.text === 'string' && cs.text) r.summary = { text: cs.text, upto: Number(cs.upto) || 0 };
            out.push(r);
        }
        return out;
    }

    const tokenFor = (run, k) => (HEX64.test(String(run)) && HEX64.test(String(k)) ? run + k : null);
    const splitToken = (t) => (typeof t === 'string' && TOKEN.test(t) ? { run: t.slice(0, 64), k: t.slice(64) } : null);

    function runOf(rumor) {
        const x = tagOf(rumor, 'x');
        return x && HEX64.test(String(x[1])) ? String(x[1]) : String(rumor && rumor.id || '');
    }

    function dataOf(fin) {
        const rumor = fin.opened.rumor;
        const r = fin.opened.run;
        let meta = {};
        const mt = tagOf(rumor, 'nymbot-meta');
        if (mt) {
            try {
                const v = JSON.parse(mt[1]);
                if (v && typeof v === 'object' && !Array.isArray(v)) meta = v;
            } catch (_) { }
        }
        const data = Object.assign({}, meta, fin.info || {}, { event: fin.wrap, chanRun: r.run });
        let shown = rumor;
        if (r.phase === 'park') {
            const body = r.ask && r.ask.body ? r.ask.body : {};
            shown = Object.assign({}, rumor, { content: typeof body.text === 'string' ? body.text : '' });
            if (body.pending && typeof body.pending === 'object') data.pendingTool = body.pending;
        }
        if (r.resume) {
            data.resumeToken = tokenFor(r.run, r.resume);
            data.resumable = true;
        }
        const st = tagOf(rumor, 'nymbot-summary');
        if (st && typeof st[1] === 'string' && st[1]) data.chanSummary = { text: st[1], upto: Number(st[2]) || 0 };
        data.chanOpened = { seal: fin.opened.seal, rumor: shown };
        return data;
    }

    function concat(parts) {
        if (parts.length === 1) return parts[0];
        const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
        let at = 0;
        for (const p of parts) { out.set(p, at); at += p.length; }
        return out;
    }

    function create(deps) {
        const pools = new Map();
        const current = new Map();
        const runs = new Map();
        const kept = new Map();
        const store = deps.store || { get: () => null, set: () => { } };
        const botPk = () => (typeof deps.botPk === 'function' ? deps.botPk() : deps.botPk);
        const url = () => (typeof deps.url === 'function' ? deps.url() : deps.url);
        const openMs = Number(deps.openMs) > 0 ? Number(deps.openMs) : OPEN_MS;

        const offered = () => store.get('offered') === true;
        const markOffered = () => { if (!offered()) store.set('offered', true); };

        function liveAll() {
            const all = store.get('live');
            return all && typeof all === 'object' ? all : {};
        }

        function liveSave(run, u, c) {
            const all = liveAll();
            const now = Date.now();
            for (const k of Object.keys(all)) if (!all[k] || now - Number(all[k].at) > LIVE_MS) delete all[k];
            if (c) all[run] = { u, c, at: now };
            else delete all[run];
            store.set('live', all);
        }

        function pool(u) {
            const had = pools.get(u);
            if (had && !had.dead) return had;
            const ws = deps.socket(url());
            const p = { ws, dead: false, chans: new Map() };
            p.opened = new Promise((resolve) => {
                ws.onopen = () => resolve(true);
                ws.onerror = () => resolve(false);
                ws.onclose = () => {
                    resolve(false);
                    p.dead = true;
                    if (pools.get(u) === p) pools.delete(u);
                    for (const ch of p.chans.values()) drop(ch);
                };
            });
            ws.onmessage = (ev) => {
                let m;
                try { m = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data)); } catch (_) { return; }
                if (!Array.isArray(m) || typeof m[1] !== 'string') return;
                const ch = p.chans.get(m[1]);
                if (ch) ch.feed(m);
            };
            pools.set(u, p);
            return p;
        }

        async function open(key) {
            const p = pool(key.pubkey);
            if (!(await within(p.opened, openMs))) {
                try { p.ws.close(); } catch (_) { }
                throw fail('unreachable');
            }
            const C = P();
            const h = await C.newHello(key.pubkey);
            const auth = await key.sign(C.authTemplate(h.hello, url(), nowSec()));
            const ch = { n: h.hello.n, key, p, cert: null, state: null, dead: false, runs: new Set(), buf: [] };
            const answer = new Promise((resolve) => {
                ch.feed = (m) => { if (m[0] === 'CHAN_CERT' || m[0] === 'CHAN_ERR') resolve(m); };
            });
            p.chans.set(ch.n, ch);
            p.ws.send(JSON.stringify(['CHAN_OPEN', h.hello, auth]));
            const m = await within(answer, openMs);
            if (!m) {
                p.chans.delete(ch.n);
                throw fail(p.dead ? 'unreachable' : 'timeout');
            }
            markOffered();
            if (m[0] === 'CHAN_ERR') {
                p.chans.delete(ch.n);
                throw fail(String(m[2] || 'unavailable'));
            }
            let fin;
            try {
                ch.cert = C.verifyCert(m[2], { botPk: botPk(), userPk: key.pubkey, nonce: h.hello.n });
                fin = await C.clientFinish({ secret: h.secret, hello: h.hello, authId: auth.id, cert: ch.cert, botPk: botPk() });
            } catch (e) {
                p.chans.delete(ch.n);
                throw fail((e && e.code) || 'bad-cert');
            }
            ch.state = fin.state;
            ch.feed = (msg) => frame(ch, msg);
            p.ws.send(JSON.stringify(['CHAN_KEY', ch.n, C.encodeFrame(fin.kemCt)]));
            return ch;
        }

        async function channel(key) {
            const held = current.get(key.pubkey);
            if (held) {
                const ch = await held.catch(() => null);
                if (ch && !ch.dead && !ch.p.dead && ch.cert.exp - nowSec() > RENEW_S) return ch;
                if (current.get(key.pubkey) === held) current.delete(key.pubkey);
            }
            const fresh = open(key);
            current.set(key.pubkey, fresh);
            fresh.catch(() => { if (current.get(key.pubkey) === fresh) current.delete(key.pubkey); });
            return fresh;
        }

        function sendOn(ch, type, obj) {
            const C = P();
            const bytes = new TextEncoder().encode(JSON.stringify(obj));
            let at = 0;
            do {
                const part = bytes.subarray(at, at + C.MAX_BODY);
                at += C.MAX_BODY;
                const sealed = C.sealFrame(ch.state, type, part, { more: at < bytes.length });
                ch.p.ws.send(JSON.stringify(['CHAN', ch.n, C.encodeFrame(sealed)]));
            } while (at < bytes.length);
        }

        function frame(ch, m) {
            if (m[0] !== 'CHAN' || ch.dead) return;
            const C = P();
            let fr;
            try {
                fr = C.openFrame(ch.state, C.decodeFrame(m[2]));
            } catch (_) {
                drop(ch);
                return;
            }
            if (fr.type === C.TYPES.CLOSE || fr.type === C.TYPES.ABORT) {
                drop(ch);
                return;
            }
            ch.buf.push(fr.body);
            if (fr.more) return;
            const parts = ch.buf;
            ch.buf = [];
            let body;
            try { body = JSON.parse(new TextDecoder().decode(concat(parts))); } catch (_) { return; }
            const r = body && typeof body.run === 'string' ? runs.get(body.run) : null;
            if (r && r.ch === ch) r.push(fr.type, body);
        }

        function drop(ch) {
            if (ch.dead && !ch.runs.size) return;
            ch.dead = true;
            for (const run of [...ch.runs]) {
                const r = runs.get(run);
                if (r && !r.ended) rejoin(r);
            }
        }

        function attach(r, ch) {
            if (r.ch && r.ch !== ch) r.ch.runs.delete(r.run);
            r.ch = ch;
            ch.runs.add(r.run);
        }

        function track(key, run, hooks) {
            const had = runs.get(run);
            if (had) {
                if (hooks) had.hooks = hooks;
                return had;
            }
            const r = { run, key, hooks: hooks || {}, ch: null, c: null, draft: null, plan: null, steps: [], n: 0, q: Promise.resolve(), ended: false };
            r.done = new Promise((resolve) => { r.resolve = resolve; });
            r.push = (type, body) => { r.q = r.q.then(() => handle(r, type, body)).catch(() => { }); };
            runs.set(run, r);
            return r;
        }

        function end(r, out) {
            if (r.ended) return;
            r.ended = true;
            runs.delete(r.run);
            if (r.ch) r.ch.runs.delete(r.run);
            if (out && out.info && out.info.background && r.c) kept.set(r.run, r);
            else liveSave(r.run, null, null);
            r.resolve(out);
        }

        async function openRun(wrap, key) {
            const o = await deps.open(wrap, key);
            if (!o || !o.rumor || !o.seal) throw fail('tamper');
            return { seal: o.seal, rumor: o.rumor, run: P().readRunRumor(o.rumor, { botPk: botPk(), userPk: key.pubkey, seal: o.seal }) };
        }

        async function settleWith(r, type, body) {
            let o;
            try {
                o = await openRun(body.wrap, r.key);
            } catch (e) {
                end(r, { error: (e && e.code) || 'tamper' });
                return;
            }
            if (o.run.run !== r.run || (o.run.phase !== 'done' && o.run.phase !== 'park')) {
                end(r, { error: 'malformed' });
                return;
            }
            end(r, { phase: o.run.phase, wrap: body.wrap, info: body.info || {}, opened: o });
        }

        async function handle(r, type, body) {
            const T = P().TYPES;
            const hk = r.hooks || {};
            if (r.ended) return;
            if (type === T.ACCEPT) {
                r.joining = false;
                if (body.wrap) {
                    const o = await openRun(body.wrap, r.key).catch(() => null);
                    if (o && o.run.run === r.run && o.run.ctl) {
                        r.c = o.run.ctl;
                        liveSave(r.run, r.key.pubkey, r.c);
                    }
                }
                if (hk.onAccept) hk.onAccept(r.run);
            } else if (type === T.DRAFT) {
                if (typeof body.text === 'string') {
                    r.draft = { text: body.text, seq: Number(body.seq) || 0 };
                    if (hk.onDraft) hk.onDraft(r.draft);
                }
            } else if (type === T.PLAN) {
                r.plan = body.plan || null;
                if (hk.onPlan) hk.onPlan(r.plan);
            } else if (type === T.STEP) {
                if (body.step && typeof body.step === 'object') {
                    const s = Object.assign({}, body.step, { n: ++r.n });
                    r.steps.push(s);
                    if (r.steps.length > 200) r.steps.shift();
                    if (hk.onStep) hk.onStep(s);
                }
            } else if (type === T.REPLY || type === T.PARK) {
                await settleWith(r, type, body);
            } else if (type === T.ERROR) {
                if (body.code === 'no-run') {
                    if (r.joining) {
                        r.joining = false;
                        await claimEnd(r);
                    }
                    return;
                }
                end(r, { error: String(body.code || 'failed'), info: body.info || {} });
            }
        }

        async function claimOnce(r) {
            let got = null;
            try { got = await deps.claim(r.run, r.key); } catch (_) { got = null; }
            const wraps = got && Array.isArray(got.wraps) ? got.wraps : [];
            const last = wraps.filter((w) => w && (w.phase === 'done' || w.phase === 'park')).pop();
            if (last) {
                await settleWith(r, last.phase === 'park' ? P().TYPES.PARK : P().TYPES.REPLY, { run: r.run, wrap: last.wrap, info: (got && got.info) || {} });
                return true;
            }
            if (!r.c) {
                const live = wraps.filter((w) => w && w.phase === 'live').pop();
                const o = live ? await openRun(live.wrap, r.key).catch(() => null) : null;
                if (o && o.run.run === r.run && o.run.ctl) r.c = o.run.ctl;
            }
            return false;
        }

        async function claimEnd(r) {
            for (let i = 0; i < CLAIM_TRIES && !r.ended; i++) {
                if (await claimOnce(r)) return;
                await later(Math.min(15000, 1000 * (i + 1)));
            }
            if (!r.ended) end(r, { error: 'lost' });
        }

        async function rejoin(r) {
            if (r.ended || r.rejoining) return;
            r.rejoining = true;
            try {
                await later(200);
                for (let i = 0; i < JOIN_TRIES && !r.ended; i++) {
                    if (!r.c && await claimOnce(r)) return;
                    if (!r.c) break;
                    let ch = null;
                    try { ch = await channel(r.key); } catch (_) { ch = null; }
                    if (!ch) { await later(1000 * (i + 1)); continue; }
                    attach(r, ch);
                    r.joining = true;
                    sendOn(ch, P().TYPES.JOIN, { run: r.run, c: r.c });
                    return;
                }
                if (!r.ended) await claimEnd(r);
            } finally {
                r.rejoining = false;
            }
        }

        async function sealFor(key, rumor, cert) {
            if (key.sk) return P().sealTurn(rumor, key.sk, cert);
            const content = await key.encrypt(cert.s, JSON.stringify(rumor));
            return key.sign({ kind: 13, created_at: nowSec(), tags: [], content });
        }

        function watchAbort(run, signal) {
            if (signal && typeof signal.addEventListener === 'function') signal.addEventListener('abort', () => cancel(run), { once: true });
        }

        async function turn(key, body, hooks) {
            const run = runOf(body.rumor);
            const r = track(key, run, hooks);
            let lastErr = null;
            for (let i = 0; i < 2; i++) {
                let ch;
                try {
                    ch = await channel(key);
                    const parts = Array.isArray(body.rumors) && body.rumors.length > 1 ? body.rumors : null;
                    const seal = parts ? await Promise.all(parts.map((x) => sealFor(key, x, ch.cert))) : await sealFor(key, body.rumor, ch.cert);
                    attach(r, ch);
                    sendOn(ch, P().TYPES.TURN, {
                        seal, history: body.history || [], summary: body.summary || null, fold: body.fold || [],
                        attachments: body.attachments || [], pq: body.pq || null, opts: body.opts || {}
                    });
                    lastErr = null;
                    break;
                } catch (e) {
                    lastErr = e;
                    if (ch) ch.dead = true;
                    if (!e || !e.chan || e.code === 'timeout' || e.code === 'unreachable') break;
                }
            }
            if (lastErr) {
                runs.delete(run);
                throw lastErr.chan ? lastErr : fail(lastErr.code || 'dead');
            }
            watchAbort(run, hooks && hooks.signal);
            return r.done;
        }

        async function resume(key, token, then, opts, pq, hooks) {
            const t = splitToken(token);
            if (!t) throw fail('malformed');
            const ch = await channel(key);
            const r = track(key, t.run, hooks);
            attach(r, ch);
            const T = P().TYPES;
            sendOn(ch, T.RESUME, { run: t.run, k: t.k, opts: opts || {}, pq: pq || null, go: !then });
            if (then) sendOn(ch, then.approve ? T.APPROVE : T.ANSWER, Object.assign({ run: t.run }, then.body));
            watchAbort(t.run, hooks && hooks.signal);
            return r.done;
        }

        function join(key, run, hooks) {
            const r = track(key, run, hooks);
            const live = liveAll()[run];
            if (!r.c && live && live.u === key.pubkey && HEX64.test(String(live.c))) r.c = live.c;
            rejoin(r);
            watchAbort(run, hooks && hooks.signal);
            return r.done;
        }

        function holder(run) {
            const r = runs.get(run) || kept.get(run);
            return r && r.c && r.ch && !r.ch.dead ? r : null;
        }

        function steer(run, text) {
            const r = holder(run);
            if (!r) return false;
            try { sendOn(r.ch, P().TYPES.STEER, { run, text: String(text || '') }); return true; } catch (_) { return false; }
        }

        async function steerFrom(key, run, text) {
            if (steer(run, text)) return true;
            if (runs.has(run) || kept.has(run)) return false;
            let got = null;
            try { got = await deps.claim(run, key); } catch (_) { got = null; }
            const wraps = got && Array.isArray(got.wraps) ? got.wraps : [];
            if (wraps.some((w) => w && (w.phase === 'done' || w.phase === 'park'))) return false;
            const live = wraps.filter((w) => w && w.phase === 'live').pop();
            const o = live ? await openRun(live.wrap, key).catch(() => null) : null;
            if (!o || o.run.run !== run || !o.run.ctl) return false;
            let accepted = null;
            const ok = new Promise((resolve) => { accepted = resolve; });
            const r = track(key, run, { onAccept: () => accepted(true) });
            r.c = o.run.ctl;
            let ch = null;
            try { ch = await channel(key); } catch (_) { ch = null; }
            if (!ch) { end(r, { error: 'lost' }); return false; }
            attach(r, ch);
            r.joining = true;
            try { sendOn(ch, P().TYPES.JOIN, { run, c: r.c }); } catch (_) { end(r, { error: 'lost' }); return false; }
            if (!(await within(ok, OPEN_MS))) { end(r, { error: 'lost' }); return false; }
            return steer(run, text);
        }

        function cancel(run) {
            const r = holder(run);
            if (!r) return false;
            try { sendOn(r.ch, P().TYPES.CANCEL, { run }); return true; } catch (_) { return false; }
        }

        function progress(run) {
            const r = runs.get(run);
            return r ? { steps: r.steps.slice(), draft: r.draft, plan: r.plan } : null;
        }

        function warm(key) {
            if (key && key.pubkey) channel(key).catch(() => { });
        }

        async function stored(key, run) {
            if (!key || !run || runs.has(run) || kept.has(run)) return null;
            let got = null;
            try { got = await deps.claim(run, key); } catch (_) { got = null; }
            const last = (got && Array.isArray(got.wraps) ? got.wraps : []).filter((w) => w && (w.phase === 'done' || w.phase === 'park')).pop();
            if (!last || runs.has(run) || kept.has(run)) return null;
            const r = track(key, run, {});
            await settleWith(r, last.phase === 'park' ? P().TYPES.PARK : P().TYPES.REPLY, { run, wrap: last.wrap, info: (got && got.info) || {} });
            return r.done;
        }

        function sockets() {
            return [...pools.entries()].map(([u, p]) => ({ u, dead: p.dead, chans: p.chans.size }));
        }

        return {
            offered, markOffered, warm, channel, turn, resume, join, stored, steer, steerFrom, cancel, progress, sockets,
            holds: (run) => runs.has(run) || kept.has(run),
            forget: (run) => { kept.delete(run); liveSave(run, null, null); },
            live: (run) => liveAll()[run] || null
        };
    }

    root.NymbotChanClient = Object.freeze({ create, historyFor, contextFor, storeRows, preTurn, pullAllowed, PULL_CAP_MS, tokenFor, splitToken, runOf, dataOf, WINDOW, THREAD_WINDOW, KEEP, FOLD_MAX });
})(typeof self !== 'undefined' ? self : this);
