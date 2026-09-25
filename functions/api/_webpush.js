export const WEBPUSH_TTL_S = 900;
export const WEBPUSH_RECORD_SIZE = 4096;
export const WEBPUSH_JWT_MAX_AGE_S = 12 * 60 * 60;
export const WEBPUSH_DEFAULT_SUBJECT = "https://nymbot.ai";
export const WEBPUSH_DEFAULT_TEXT = "Your reply is ready";
export const WEBPUSH_MAX_SUB = 1024;

const WEBPUSH_HOSTS = [
  /^fcm\.googleapis\.com$/,
  /^android\.googleapis\.com$/,
  /^updates\.push\.services\.mozilla\.com$/,
  /^push\.services\.mozilla\.com$/,
  /^web\.push\.apple\.com$/,
  /^[a-z0-9-]+\.push\.apple\.com$/,
  /^[a-z0-9-]+\.notify\.windows\.com$/
];

const enc = new TextEncoder();
const memo = new Map();
const keys = { raw: "", key: null };

export function webPushForget() {
  memo.clear();
  keys.raw = "";
  keys.key = null;
}

export function b64url(input) {
  const bytes = typeof input === "string" ? enc.encode(input) : new Uint8Array(input);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function unb64url(s) {
  if (typeof s !== "string" || !/^[A-Za-z0-9_-]*={0,2}$/.test(s)) return null;
  const t = s.replace(/=+$/, "").replace(/-/g, "+").replace(/_/g, "/");
  try {
    return Uint8Array.from(atob(t + "===".slice((t.length + 3) % 4)), (c) => c.charCodeAt(0));
  } catch (e) {
    return null;
  }
}

function concat(...parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

async function hmac(key, data) {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

export function webPushPublicKey(env) {
  const raw = unb64url(String((env && env.VAPID_PUBLIC_KEY) || "").trim());
  return raw && raw.length === 65 && raw[0] === 4 ? b64url(raw) : "";
}

export function webPushConfigured(env) {
  const d = unb64url(String((env && env.VAPID_PRIVATE_KEY) || "").trim());
  return !!(webPushPublicKey(env) && d && d.length === 32);
}

async function vapidKey(env) {
  const pub = webPushPublicKey(env);
  const priv = String(env.VAPID_PRIVATE_KEY || "").trim();
  const id = pub + "." + priv;
  if (keys.key && keys.raw === id) return keys.key;
  const raw = unb64url(pub);
  const jwk = {
    kty: "EC",
    crv: "P-256",
    x: b64url(raw.slice(1, 33)),
    y: b64url(raw.slice(33, 65)),
    d: b64url(unb64url(priv)),
    ext: true
  };
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  keys.raw = id;
  keys.key = key;
  return key;
}

export async function webPushVapidToken(env, audience, nowS) {
  const subject = String(env.VAPID_SUBJECT || "").trim() || WEBPUSH_DEFAULT_SUBJECT;
  const id = audience + "|" + subject + "|" + webPushPublicKey(env);
  const hit = memo.get(id);
  if (hit && nowS - hit.iat < WEBPUSH_JWT_MAX_AGE_S - 600 && hit.iat <= nowS + 60) return hit.jwt;
  const input = b64url(JSON.stringify({ typ: "JWT", alg: "ES256" })) + "." +
    b64url(JSON.stringify({ aud: audience, exp: nowS + WEBPUSH_JWT_MAX_AGE_S, sub: subject }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await vapidKey(env), enc.encode(input));
  const jwt = input + "." + b64url(sig);
  memo.set(id, { jwt, iat: nowS });
  return jwt;
}

export function webPushEndpointOk(endpoint) {
  let u;
  try { u = new URL(endpoint); } catch (e) { return false; }
  if (u.protocol !== "https:" || u.username || u.password || (u.port && u.port !== "443")) return false;
  return WEBPUSH_HOSTS.some((re) => re.test(u.hostname));
}

export function webPushParseSubscription(input) {
  let sub = input;
  if (typeof sub === "string") {
    if (sub.length > WEBPUSH_MAX_SUB) return null;
    try { sub = JSON.parse(sub); } catch (e) { return null; }
  }
  if (!sub || typeof sub !== "object") return null;
  const endpoint = sub.endpoint;
  const k = sub.keys || {};
  if (typeof endpoint !== "string" || endpoint.length > 800 || /["\\\s]/.test(endpoint) || !webPushEndpointOk(endpoint)) return null;
  const p256dh = unb64url(k.p256dh);
  const auth = unb64url(k.auth);
  if (!p256dh || p256dh.length !== 65 || p256dh[0] !== 4) return null;
  if (!auth || auth.length !== 16) return null;
  return { endpoint, keys: { p256dh: b64url(p256dh), auth: b64url(auth) } };
}

export function webPushToken(sub) {
  const s = webPushParseSubscription(sub);
  return s ? JSON.stringify(s) : "";
}

export async function webPushEncrypt(sub, payload, opts) {
  const o = opts || {};
  const uaPublic = unb64url(sub.keys.p256dh);
  const authSecret = unb64url(sub.keys.auth);
  const pair = o.keyPair || await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, pair.privateKey, 256));
  const prkKey = await hmac(authSecret, shared);
  const keyInfo = concat(enc.encode("WebPush: info\0"), uaPublic, asPublic, new Uint8Array([1]));
  const ikm = await hmac(prkKey, keyInfo);
  const salt = o.salt || crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(enc.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, concat(enc.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);
  const plain = concat(typeof payload === "string" ? enc.encode(payload) : payload, new Uint8Array([2]));
  const aes = await crypto.subtle.importKey("raw", cek, { name: "AES-GCM" }, false, ["encrypt"]);
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, aes, plain));
  const head = new Uint8Array(21);
  head.set(salt, 0);
  new DataView(head.buffer).setUint32(16, WEBPUSH_RECORD_SIZE);
  head[20] = asPublic.length;
  return concat(head, asPublic, sealed);
}

export function webPushReplyPayload(chat, text) {
  const body = typeof text === "string" && text.trim() ? text.trim().slice(0, 80) : WEBPUSH_DEFAULT_TEXT;
  return { title: "Nymbot", body: body, chat: chat };
}

export async function webPushSendReply(env, reg, fetchFn) {
  if (!reg || !webPushConfigured(env)) return { skipped: true };
  const sub = webPushParseSubscription(reg.token);
  if (!sub) return { skipped: true };
  const send = fetchFn || fetch;
  let jwt, body;
  try {
    jwt = await webPushVapidToken(env, new URL(sub.endpoint).origin, Math.floor(Date.now() / 1000));
    body = await webPushEncrypt(sub, JSON.stringify(webPushReplyPayload(reg.chat, reg.text)));
  } catch (e) {
    return { status: 0, reason: "key" };
  }
  let res;
  try {
    res = await send(sub.endpoint, {
      method: "POST",
      headers: {
        "authorization": "vapid t=" + jwt + ", k=" + webPushPublicKey(env),
        "content-encoding": "aes128gcm",
        "content-type": "application/octet-stream",
        "ttl": String(WEBPUSH_TTL_S),
        "urgency": "high",
        "topic": String(reg.chat || "reply").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 32) || "reply"
      },
      body: body
    });
  } catch (e) {
    return { status: 0, reason: "network" };
  }
  if (res.status === 401 || res.status === 403) webPushForget();
  return { status: res.status };
}
