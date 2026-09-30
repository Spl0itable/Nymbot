import { sha256, hmac, bytesToHex, hexToBytes, utf8ToBytes, randomBytes, bolt11PaymentHash, bolt11ExpiresAt } from "./_shared.js";
import { noteUsage } from "./_usage.js";
import { botCreditInvoice, BOT_SATS_PER_CREDIT, BOT_PRO_SATS_PER_CREDIT, BOT_MIN_CHARGE_MILLI } from "./bot.js";
import { ApiError, apiBad, apiIso, apiJson, apiRound, apiRateHit, apiRateLimit, apiIpBucket, apiBufferMultipart, API_MULTIPART_MAX_BYTES, API_EMPTY_BODY_SHA256 } from "./_apihttp.js";
import { apiAuthKey } from "./_apiauth.js";
import {
  l402RefundToken, l402RefundHash, l402RefundNew, l402RefundMint, l402RefundMintHash, l402RefundSpend, l402RefundCredit, l402RefundPeek,
  l402RefundRedeem, l402RefundGet, l402IssuedPut, l402IssuedGet, l402IssuedUse
} from "./_l402refund.js";

export const API_L402_REALM = "nymbot";
export const API_L402_TTL_MS = 15 * 60 * 1000;
export const API_L402_LIMITS = { perIp: 30, noIp: 10, global: 600, windowMs: 60000 };
export const API_L402_CHALLENGE_LIMIT = API_L402_LIMITS.perIp;
export const API_L402_CHALLENGE_WINDOW_MS = API_L402_LIMITS.windowMs;
export const API_L402_PROBLEM = "https://paymentauth.org/problems/payment-required";

const CREDENTIAL_RE = /(?:^|[\s,])(L402|LSAT)\s+([A-Za-z0-9+/=_-]+(?:,[A-Za-z0-9+/=_-]+)*):([0-9a-fA-F]{64})(?=$|[\s,])/;
const PAYMENT_RE = /(?:^|,)\s*Payment\s+([A-Za-z0-9_-]+={0,2})\s*(?=$|,)/i;
const CAVEATS = ["nymbot_endpoint", "nymbot_body_sha256", "nymbot_content_type", "nymbot_amount_sats", "nymbot_valid_until"];
const CONTENT_TYPE_MAX = 200;

export const API_L402_SECRET_MIN_BYTES = 32;
const weakNoted = new Set();

export function apiL402SecretStrong(raw) {
  const t = typeof raw === "string" ? raw.trim() : "";
  let bytes = 0;
  if (/^[0-9a-fA-F]+$/.test(t)) bytes = Math.floor(t.length / 2);
  else if (/^[A-Za-z0-9+/_-]+={0,2}$/.test(t)) bytes = Math.floor(t.replace(/=+$/, "").length * 3 / 4);
  return bytes >= API_L402_SECRET_MIN_BYTES && new Set(t.toLowerCase()).size >= 10;
}

function strongOf(env, name) {
  const raw = env && env[name];
  const t = typeof raw === "string" ? raw.trim() : "";
  if (!t) return null;
  if (apiL402SecretStrong(t)) return t;
  if (!weakNoted.has(name)) {
    weakNoted.add(name);
    try {
      console.error(name + " is too weak: it needs at least " + API_L402_SECRET_MIN_BYTES + " random bytes as hex or base64 " +
        "(generate one with `openssl rand -hex 32`). " + (name === "API_L402_SECRET" ? "L402 payments are disabled." : "It is ignored."));
    } catch (e) { }
  }
  return null;
}

function secretOf(env) {
  return strongOf(env, "API_L402_SECRET");
}

function secretsOf(env) {
  const now = secretOf(env);
  if (!now) return [];
  const before = strongOf(env, "API_L402_SECRET_PREVIOUS");
  return before && before !== now ? [now, before] : [now];
}

export function apiL402Enabled(env) {
  return !!secretOf(env);
}

function keyFor(env, purpose, secret) {
  return hmac(sha256, utf8ToBytes(secret || secretOf(env)), utf8ToBytes("nymbot-l402:" + purpose));
}

function b64url(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64std(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

function fromB64(str) {
  const clean = String(str || "").replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  const bin = atob(clean + "===".slice((clean.length + 3) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function jcs(v) {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map(jcs).join(",") + "]";
  return "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + jcs(v[k])).join(",") + "}";
}

function sameBytes(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

function sameText(a, b) {
  return sameBytes(utf8ToBytes(String(a)), utf8ToBytes(String(b)));
}

export function apiL402Sats(milli, tier) {
  const per = tier === "pro" ? BOT_PRO_SATS_PER_CREDIT : BOT_SATS_PER_CREDIT;
  const m = Math.max(BOT_MIN_CHARGE_MILLI, Math.ceil(Number(milli) || 0));
  return Math.max(1, Math.ceil(m * per / 1000));
}

function endpointOf(api) {
  return api.request.method.toUpperCase() + " " + api.route.path;
}

function contentTypeOf(request) {
  const parts = String(request.headers.get("Content-Type") || "").split(";");
  const type = parts[0].trim().toLowerCase();
  let boundary = "";
  for (const p of parts.slice(1)) {
    const at = p.indexOf("=");
    if (at < 0 || p.slice(0, at).trim().toLowerCase() !== "boundary") continue;
    boundary = p.slice(at + 1).trim().replace(/^"(.*)"$/, "$1");
  }
  const out = boundary ? type + ";boundary=" + boundary : type;
  return out.length > CONTENT_TYPE_MAX || /[^\x20-\x7e]/.test(out) ? "sha-256:" + bytesToHex(sha256(utf8ToBytes(out))) : out;
}

const unauth = (code, message) => new ApiError(401, "authentication_error", message, { code });
const badCredential = () => unauth("invalid_payment_credential", "The payment credential is malformed or was not issued by Nymbot. Send the request again without it to get a new invoice.");
const badPreimage = () => unauth("invalid_preimage", "The preimage does not match the invoice's payment hash. Send the 32-byte preimage your wallet returned, in hex.");
const expired = () => unauth("payment_expired", "This payment challenge expired (they last 15 minutes).");
const mismatch = () => unauth("payment_mismatch", "This payment was made for a different request: a paid credential only works for the exact endpoint, Content-Type and body it was issued for.");
const underpaid = (paid, price) => unauth("payment_mismatch", "This payment covers " + paid + " sats, and this request now costs " + price + " sats.");
const used = () => unauth("payment_already_used", "This payment was already used, and every paid request needs its own.");
const STALE = { payment_expired: "payment-expired", payment_mismatch: "invalid-challenge", payment_already_used: "invalid-challenge" };
const ledgerDown = () => new ApiError(503, "api_error", "Payments are temporarily unavailable. Try again shortly.", { code: "service_unavailable", headers: { "Retry-After": "30" } });

function varint(n) {
  const out = [];
  let v = n;
  while (v >= 128) { out.push((v & 127) | 128); v = Math.floor(v / 128); }
  out.push(v);
  return out;
}

function macField(out, type, data) {
  out.push(type, ...varint(data.length));
  for (let i = 0; i < data.length; i++) out.push(data[i]);
}

function macSig(env, id, caveats, secret) {
  const root = hmac(sha256, utf8ToBytes("macaroons-key-generator"), keyFor(env, "macaroon", secret));
  let sig = hmac(sha256, root, id);
  for (const c of caveats) sig = hmac(sha256, sig, utf8ToBytes(c));
  return sig;
}

function macMint(env, hash, caveats) {
  const id = new Uint8Array(66);
  id.set(hexToBytes(hash), 2);
  id.set(randomBytes(32), 34);
  const out = [2];
  macField(out, 2, id);
  out.push(0);
  for (const c of caveats) { macField(out, 2, utf8ToBytes(c)); out.push(0); }
  out.push(0);
  macField(out, 6, macSig(env, id, caveats));
  return b64std(new Uint8Array(out));
}

function macSection(b, at) {
  const fields = [];
  let i = at;
  while (i < b.length) {
    const type = b[i++];
    if (type === 0) return { fields, next: i };
    let len = 0;
    let shift = 1;
    while (true) {
      if (i >= b.length) return null;
      const x = b[i++];
      len += (x & 127) * shift;
      shift *= 128;
      if (!(x & 128)) break;
      if (shift > 2 ** 28) return null;
    }
    if (i + len > b.length) return null;
    fields.push({ type, data: b.subarray(i, i + len) });
    i += len;
  }
  return null;
}

function macParse(b64) {
  let b;
  try { b = fromB64(b64); } catch (e) { return null; }
  if (!b.length || b[0] !== 2) return null;
  let s = macSection(b, 1);
  if (!s) return null;
  let head = s.fields;
  if (head.length && head[0].type === 1) head = head.slice(1);
  if (head.length !== 1 || head[0].type !== 2) return null;
  const id = head[0].data;
  const caveats = [];
  let at = s.next;
  while (true) {
    s = macSection(b, at);
    if (!s) return null;
    at = s.next;
    if (!s.fields.length) break;
    let f = s.fields;
    if (f[0].type === 1) return null;
    if (f.length !== 1 || f[0].type !== 2) return null;
    caveats.push(new TextDecoder().decode(f[0].data));
  }
  if (at + 2 > b.length || b[at] !== 6 || b[at + 1] !== 32 || at + 34 !== b.length) return null;
  return { id, caveats, sig: b.subarray(at + 2, at + 34) };
}

function networkOf(pr) {
  const s = String(pr || "").toLowerCase();
  if (s.startsWith("lnbcrt")) return "regtest";
  if (s.startsWith("lntbs")) return "signet";
  return "mainnet";
}

function paymentId(env, p, secret) {
  const input = [p.realm, p.method, p.intent, p.request, p.expires || "", p.digest || ""];
  if (p.header !== undefined) input.push(p.header);
  input.push(p.opaque || "");
  return b64url(hmac(sha256, keyFor(env, "payment", secret), utf8ToBytes(input.join("|"))));
}

function quote(v) {
  return "\"" + String(v).replace(/[\\"]/g, "\\$&") + "\"";
}

async function rateHit(env, bucket, limit) {
  const wait = await apiRateHit(env, "l402", bucket, { limit, windowMs: API_L402_LIMITS.windowMs });
  if (wait < 0) throw ledgerDown();
  return wait > 0 ? Math.max(1, Math.ceil(wait / 1000)) : 0;
}

function tooMany(secs, message) {
  return new ApiError(429, "rate_limit_error", message + " Retry in " + secs + " s, or use an API key.",
    { code: "rate_limit_exceeded", headers: { "Retry-After": String(secs) } });
}

async function challengeLimit(api) {
  if (api.l402Limited) return;
  api.l402Limited = true;
  const ip = apiIpBucket(api);
  const limit = ip ? API_L402_LIMITS.perIp : API_L402_LIMITS.noIp;
  const own = await rateHit(api.env, ip ? "ip/" + ip : "noip", limit);
  if (own) {
    throw tooMany(own, ip
      ? "Too many payment challenges from this address: " + limit + " a minute."
      : "Too many payment challenges from clients without a known address: " + limit + " a minute, shared.");
  }
}

async function globalLimit(api) {
  const all = await rateHit(api.env, "global", API_L402_LIMITS.global);
  if (all) throw tooMany(all, "Nymbot is issuing too many payment challenges right now.");
}

export async function apiL402Limit(api) {
  if (!apiL402Enabled(api.env)) return;
  await challengeLimit(api);
}

async function challenge(api, q) {
  await challengeLimit(api);
  await globalLimit(api);
  const made = await botCreditInvoice(api.env, null, q.sats, q.tier, { store: false });
  if (!made || made.error || !made.pr) {
    throw new ApiError(502, "api_error", "Could not create a Lightning invoice right now. Try again shortly, or use an API key.",
      { code: "invoice_unavailable", headers: { "Retry-After": "30" } });
  }
  const pr = made.pr;
  const hash = bolt11PaymentHash(pr);
  if (!hash) throw new ApiError(502, "api_error", "The Lightning wallet returned an unreadable invoice. Try again shortly.", { code: "invoice_unavailable" });
  const now = Date.now();
  const invoiceExp = bolt11ExpiresAt(pr);
  const until = Math.min(now + API_L402_TTL_MS, invoiceExp || now + API_L402_TTL_MS);
  let stored = false;
  try { stored = await l402IssuedPut(api.env, hash, q.sats, until); } catch (e) { stored = false; }
  if (!stored) throw ledgerDown();
  const expires = new Date(until).toISOString();
  const macaroon = macMint(api.env, hash, [
    "nymbot_endpoint=" + q.endpoint, "nymbot_body_sha256=" + q.bodyHex, "nymbot_content_type=" + q.contentType,
    "nymbot_amount_sats=" + q.sats, "nymbot_valid_until=" + Math.floor(until / 1000)
  ]);
  const p = {
    realm: API_L402_REALM, method: "lightning", intent: "charge",
    request: b64url(utf8ToBytes(jcs({ amount: String(q.sats), currency: "sat", methodDetails: { invoice: pr, network: networkOf(pr), paymentHash: hash } }))),
    description: "Nymbot API " + q.endpoint + " (" + q.sats + " sats)",
    digest: "sha-256=:" + b64std(hexToBytes(q.bodyHex)) + ":",
    expires,
    opaque: b64url(utf8ToBytes(jcs({ endpoint: q.endpoint, content_type: q.contentType })))
  };
  p.id = paymentId(api.env, p);
  const pay = "Payment " + ["id", "realm", "method", "intent", "request", "description", "digest", "expires", "opaque"]
    .map((k) => k + "=" + quote(p[k])).join(", ");
  const l402 = "macaroon=" + quote(macaroon) + ", invoice=" + quote(pr);
  const headers = new Headers({ "Content-Type": "application/problem+json; charset=utf-8", "Cache-Control": "no-store" });
  headers.append("WWW-Authenticate", "L402 " + l402);
  headers.append("WWW-Authenticate", "LSAT " + l402);
  headers.append("WWW-Authenticate", pay);
  const back = q.refund ? " The " + q.refund.sats + " sats you paid are on refund token " + q.refund.token +
    ": send it as `Authorization: Bearer <token>` to pay for this request, or redeem it into a nym balance in the Nymbot app." : "";
  const ask = "This request costs " + q.sats + " sats. Pay the Lightning invoice, then send the identical request again with " +
    "`Authorization: L402 <macaroon>:<preimage>` or the Payment credential. Or use an API key.";
  const detail = q.reason ? q.reason.message + back + " " + ask : ask;
  const code = q.reason ? q.reason.code : "payment_required";
  const body = {
    type: q.reason ? "https://paymentauth.org/problems/" + STALE[q.reason.code] : API_L402_PROBLEM,
    title: "Payment Required", status: 402, detail, challengeId: p.id,
    amount_sats: q.sats, invoice: pr, payment_hash: hash, expires_at: expires,
    error: { message: detail, type: "payment_required", code, param: null }
  };
  if (q.refund) {
    const extra = { refund_token: q.refund.token, refund_sats: q.refund.sats, refund_expires_at: apiIso(q.refund.expiresAt) };
    Object.assign(body, extra);
    Object.assign(body.error, extra);
  }
  const err = new ApiError(402, "payment_required", detail, { code: "payment_required" });
  err.response = new Response(JSON.stringify(body), { status: 402, headers });
  return err;
}

function parseCaveats(list) {
  const out = {};
  for (const c of list) {
    const at = c.indexOf("=");
    if (at < 1) return null;
    const k = c.slice(0, at).trim();
    if (!CAVEATS.includes(k)) return null;
    (out[k] = out[k] || []).push(c.slice(at + 1).trim());
  }
  return out;
}

function checkPreimage(preimage, hash) {
  if (!/^[0-9a-f]{64}$/i.test(preimage || "")) throw badPreimage();
  if (bytesToHex(sha256(hexToBytes(preimage.toLowerCase()))) !== hash) throw badPreimage();
}

function authenticL402(env, pay) {
  const m = macParse(pay.macaroon);
  if (!m || m.id.length !== 66 || m.id[0] !== 0 || m.id[1] !== 0) throw badCredential();
  if (!secretsOf(env).some((s) => sameBytes(macSig(env, m.id, m.caveats, s), m.sig))) throw badCredential();
  const cav = parseCaveats(m.caveats);
  if (!cav || m.caveats.length < CAVEATS.length || CAVEATS.some((k, i) => !m.caveats[i].startsWith(k + "="))) throw badCredential();
  const sats = Number(cav.nymbot_amount_sats[0]);
  if (!Number.isSafeInteger(sats) || sats <= 0 || cav.nymbot_amount_sats.some((v) => v !== cav.nymbot_amount_sats[0])) throw badCredential();
  const hash = bytesToHex(m.id.subarray(2, 34));
  checkPreimage(pay.preimage, hash);
  return {
    kind: "l402", sats, hash, challengeId: null,
    late: () => cav.nymbot_valid_until.some((v) => !(Number(v) * 1000 > Date.now())),
    bound: (q) => !(cav.nymbot_endpoint.some((v) => v !== q.endpoint) || cav.nymbot_body_sha256.some((v) => v !== q.bodyHex) ||
      cav.nymbot_content_type.some((v) => v !== q.contentType))
  };
}

function authenticPayment(env, pay) {
  let cred;
  try { cred = JSON.parse(new TextDecoder().decode(fromB64(pay.token))); } catch (e) { throw badCredential(); }
  const ch = cred && typeof cred === "object" ? cred.challenge : null;
  if (!ch || typeof ch !== "object") throw badCredential();
  for (const k of ["id", "realm", "method", "intent", "request"]) if (typeof ch[k] !== "string" || !ch[k]) throw badCredential();
  for (const k of ["expires", "digest", "opaque", "header"]) if (ch[k] !== undefined && typeof ch[k] !== "string") throw badCredential();
  if (!secretsOf(env).some((s) => sameText(paymentId(env, ch, s), ch.id))) throw badCredential();
  if (ch.realm !== API_L402_REALM || ch.method !== "lightning" || ch.intent !== "charge") throw badCredential();
  let req, opaque;
  try {
    req = JSON.parse(new TextDecoder().decode(fromB64(ch.request)));
    opaque = ch.opaque ? JSON.parse(new TextDecoder().decode(fromB64(ch.opaque))) : {};
  } catch (e) { throw badCredential(); }
  const hash = req && req.methodDetails && String(req.methodDetails.paymentHash || "").toLowerCase();
  const sats = Number(req && req.amount);
  if (!/^[0-9a-f]{64}$/.test(hash || "") || req.currency !== "sat" || !Number.isSafeInteger(sats) || sats <= 0) throw badCredential();
  const payload = cred.payload && typeof cred.payload === "object" ? cred.payload : null;
  if (!payload || typeof payload.preimage !== "string") throw badCredential();
  checkPreimage(payload.preimage, hash);
  return {
    kind: "payment", sats, hash, challengeId: ch.id,
    late: () => !(Date.parse(ch.expires || "") > Date.now()),
    bound: (q) => !!opaque && opaque.endpoint === q.endpoint && opaque.content_type === q.contentType &&
      ch.digest === "sha-256=:" + b64std(hexToBytes(q.bodyHex)) + ":"
  };
}

async function authenticPaid(env, pay) {
  const paid = pay.kind === "l402" ? authenticL402(env, pay) : authenticPayment(env, pay);
  const issued = await l402IssuedGet(env, paid.hash);
  if (issued.unavailable) throw ledgerDown();
  if (!issued.ok) throw badCredential();
  return paid;
}

export const apiL402RefundHooks = [];

async function refundHooks(api, hash) {
  let pending = false;
  for (const fn of apiL402RefundHooks) {
    try { if (await fn(api, hash)) pending = true; } catch (e) { }
  }
  return pending;
}

async function refundTokenCheck(api, token) {
  const hash = l402RefundHash(token);
  const wait = await apiRateHit(api.env, "refundToken", hash);
  if (wait > 0) {
    const secs = Math.max(1, Math.ceil(wait / 1000));
    throw new ApiError(429, "rate_limit_error", "Too many requests with this refund token: at most 60 a minute. Retry in " + secs + " s.",
      { code: "rate_limit_exceeded", headers: { "Retry-After": String(secs) } });
  }
  let row = await l402RefundGet(api.env, token);
  if (!row) {
    await refundHooks(api, hash);
    row = await l402RefundGet(api.env, token);
  }
  if (!row) throw unauth("invalid_refund_token", "Unknown refund token.");
  if (Number(row.expires_at) <= Date.now()) throw unauth("refund_token_expired", "This refund token expired.");
  return row;
}

function credentialOf(header) {
  const h = String(header || "");
  const l = CREDENTIAL_RE.exec(h);
  if (l) return { kind: "l402", macaroon: l[2].split(",")[0], preimage: l[3] };
  const p = PAYMENT_RE.exec(h);
  if (p) return { kind: "payment", token: p[1] };
  if (/(?:^|[\s,])(L402|LSAT|Payment)\s/i.test(h)) return { kind: "bad" };
  return null;
}

export async function apiAuthPaid(api) {
  const env = api.env;
  const h = api.request.headers;
  const auth = h.get("Authorization") || "";
  const other = (h.get("x-api-key") || h.get("api-key") || "").trim();
  if (!apiL402Enabled(env) || other) return apiAuthKey(api);
  const bearer = /^\s*Bearer\s+(\S+)\s*$/i.exec(auth);
  let pay = null;
  if (bearer) {
    const token = l402RefundToken(bearer[1]);
    if (!token) return apiAuthKey(api);
    pay = { kind: "refund", token };
  } else if (auth.trim()) {
    pay = credentialOf(auth);
    if (!pay) return apiAuthKey(api);
    if (pay.kind === "bad") throw badCredential();
  }
  if (!pay) await challengeLimit(api);
  else if (pay.kind === "refund") await refundTokenCheck(api, pay.token);
  else pay.paid = await authenticPaid(env, pay);
  if (api.route.opts.body === "multipart") await apiBufferMultipart(api, api.route.opts.maxBytes || API_MULTIPART_MAX_BYTES, true);
  api.auth = { via: "l402", pubkey: null, keyId: null, key: null, pay };
  api.l402 = { bill: null, refund: null, receipt: null };
  return api.auth;
}

export async function apiL402Open(api, o) {
  const tier = o.tier === "pro" ? "pro" : "standard";
  const satsPer = tier === "pro" ? BOT_PRO_SATS_PER_CREDIT : BOT_SATS_PER_CREDIT;
  const price = apiL402Sats(o.l402Milli != null ? o.l402Milli : o.reserveMilli, tier);
  const bound = { endpoint: endpointOf(api), bodyHex: api.bodyHex || API_EMPTY_BODY_SHA256, contentType: contentTypeOf(api.request) };
  const ask = (extra) => challenge(api, Object.assign({ sats: price, tier }, bound, extra || {}));
  const pay = api.auth.pay;
  if (!pay) throw await ask();
  let paid;
  if (pay.kind === "refund") {
    const spent = await l402RefundSpend(api.env, pay.token, price);
    if (spent.unavailable) throw ledgerDown();
    if (spent.unknown) throw unauth("invalid_refund_token", "Unknown refund token.");
    if (spent.expired) throw unauth("refund_token_expired", "This refund token expired.");
    if (!spent.ok) {
      throw new ApiError(402, "insufficient_quota", "This request costs " + price + " sats and the refund token holds " + spent.have +
        ". Send the request without it to pay by Lightning, or redeem the token into a nym balance in the Nymbot app.",
        { code: "refund_insufficient", extra: { required_sats: price, refund_token_sats: spent.have } });
    }
    paid = { kind: "refund", sats: price, token: pay.token, left: spent.left, expiresAt: spent.expiresAt };
  } else {
    try {
      paid = pay.paid || await authenticPaid(api.env, pay);
      const late = paid.late();
      if (!late && !paid.bound(bound)) throw mismatch();
      const fresh = await l402IssuedUse(api.env, paid.hash);
      if (fresh == null) throw ledgerDown();
      if (!fresh) throw used();
      if (late) {
        const gone = expired();
        gone.refundSats = paid.sats;
        gone.refundHash = paid.hash;
        throw gone;
      }
      if (paid.sats < price) {
        const short = underpaid(paid.sats, price);
        short.refundSats = paid.sats;
        throw short;
      }
    } catch (e) {
      if (!(e instanceof ApiError) || !STALE[e.code]) throw e;
      let refund = null;
      if (e.refundSats) {
        try { refund = await l402RefundMint(api.env, e.refundSats); } catch (x) { refund = null; }
        if (!refund && e.refundHash) {
          try { await l402IssuedUse(api.env, e.refundHash, true); } catch (x) { }
          throw ledgerDown();
        }
      }
      let fresh;
      try { fresh = await ask({ reason: { code: e.code, message: e.message }, refund }); } catch (x) {
        if (!refund) throw e;
        throw new ApiError(e.status, e.type, e.message + " The " + refund.sats + " sats you paid are on refund token " + refund.token + ".", {
          code: e.code, extra: { refund_token: refund.token, refund_sats: refund.sats, refund_expires_at: apiIso(refund.expiresAt) }
        });
      }
      throw fresh;
    }
    if (paid.kind === "payment") {
      api.l402.receipt = { challengeId: paid.challengeId, method: "lightning", reference: paid.hash, status: "success", timestamp: new Date().toISOString() };
    }
  }
  const bill = {
    id: bytesToHex(randomBytes(16)), tier, satsPer, holdCredits: 0, pubkey: null, keyId: null, keyLimited: false, keyOpen: false, done: false,
    l402: { kind: paid.kind, paidSats: paid.sats, price, hash: paid.hash || null, token: paid.token || null, left: paid.left, partial: !!o.l402Partial }
  };
  api.l402.bill = bill;
  return bill;
}

export async function apiL402GiveBack(api, bill, sats) {
  const back = Math.floor(Number(sats) || 0);
  if (back <= 0) return null;
  let got = null;
  try {
    if (bill.l402.kind === "refund") got = await l402RefundCredit(api.env, bill.l402.token, back);
    else got = await l402RefundMint(api.env, back);
  } catch (e) { got = null; }
  if (!got) return null;
  if (bill.l402.kind === "refund") bill.l402.left = got.sats;
  api.l402.refund = { token: got.token, sats: back, expiresAt: got.expiresAt, toToken: bill.l402.kind === "refund" };
  return api.l402.refund;
}

export async function apiL402Settle(api, bill, milliIn, opts) {
  if (bill.done) return { chargedMilli: 0, balance: null, dust: null };
  bill.done = true;
  const milli = Math.max(0, Math.ceil(Number(milliIn) || 0));
  const paid = bill.l402.paidSats;
  let charged = 0;
  if (milli > 0) {
    charged = bill.l402.partial || (opts && opts.l402Partial)
      ? Math.min(paid, Math.max(1, Math.ceil(milli * bill.satsPer / 1000)))
      : Math.min(paid, bill.l402.price || paid);
  }
  bill.l402.chargedSats = charged;
  await apiL402GiveBack(api, bill, paid - charged);
  return { chargedMilli: charged * 1000 / bill.satsPer, balance: null, dust: null };
}

export function apiL402Cost(api, bill, settled, usd) {
  const charged = apiRound((settled.chargedMilli || 0) * bill.satsPer / 1000);
  const out = { payment: bill.l402.kind === "refund" ? "refund" : "l402", tier: bill.tier, paid_sats: bill.l402.paidSats, charged_sats: charged, charged_usd: usd(charged) };
  const r = api.l402 && api.l402.refund;
  if (r && !r.toToken) {
    out.refund_token = r.token;
    out.refund_sats = r.sats;
    out.refund_expires_at = apiIso(r.expiresAt);
  }
  if (bill.l402.kind === "refund") out.refund_token_sats = bill.l402.left;
  return out;
}

export function apiL402Usage(api, row) {
  try {
    noteUsage(api.context || { env: api.env }, Object.assign({}, row, { pubkey: "", client: "api-l402" }));
  } catch (e) { }
}

export async function apiL402Finish(api, res) {
  const st = api.l402;
  if (!st || !st.receipt || res.status < 200 || res.status >= 300) return res;
  try { res.headers.set("Payment-Receipt", b64url(utf8ToBytes(jcs(st.receipt)))); } catch (e) {
    const headers = new Headers(res.headers);
    headers.set("Payment-Receipt", b64url(utf8ToBytes(jcs(st.receipt))));
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
  }
  return res;
}

export async function apiL402Failed(api, err) {
  const st = api && api.l402;
  if (!st) return err;
  if (st.bill && !st.bill.done) {
    try { await apiL402Settle(api, st.bill, 0); } catch (e) { }
  }
  const r = st.refund;
  if (!r || !(err instanceof ApiError) || err.response) return err;
  const note = r.toToken
    ? " The " + r.sats + " sats went back to your refund token."
    : " The " + r.sats + " sats you paid are on refund token " + r.token + ": send it as `Authorization: Bearer <token>` to pay for another request, " +
      "or redeem it into a nym balance in the Nymbot app. It expires on " + apiIso(r.expiresAt) + ".";
  return new ApiError(err.status, err.type, err.message + note, {
    code: err.code, param: err.param, headers: err.headers,
    extra: Object.assign({}, err.extra || {}, { refund_token: r.token, refund_sats: r.sats, refund_expires_at: apiIso(r.expiresAt) })
  });
}

function statusSig(env, id, exp, secret) {
  return b64url(hmac(sha256, keyFor(env, "status", secret), utf8ToBytes(id + "." + exp)));
}

export function apiL402StatusUrl(api, id, expiresAt) {
  if (!apiL402Enabled(api.env)) return null;
  const exp = Math.floor(Number(expiresAt) / 1000);
  const base = api.url.origin + api.url.pathname.replace(/\/videos\/?$/, "");
  return base + "/videos/" + encodeURIComponent(id) + "?exp=" + exp + "&sig=" + statusSig(api.env, id, exp);
}

export async function apiAuthKeyOrSigned(api) {
  const q = api.url.searchParams;
  if (!q.has("sig")) return apiAuthKey(api);
  const id = String(api.params.id || "");
  const exp = Number(q.get("exp"));
  const bad = unauth("invalid_status_url", "This status URL is invalid or expired. Status URLs last 24 hours.");
  if (!apiL402Enabled(api.env) || !Number.isSafeInteger(exp) || exp * 1000 <= Date.now()) throw bad;
  if (!secretsOf(api.env).some((s) => sameText(statusSig(api.env, id, exp, s), q.get("sig") || ""))) throw bad;
  api.auth = { via: "signed", pubkey: null, keyId: null, key: null, videoId: id };
  return api.auth;
}

export function apiL402VideoToken(env, id) {
  if (!apiL402Enabled(env)) return null;
  return "REFUND-" + bytesToHex(hmac(sha256, keyFor(env, "refund"), utf8ToBytes("video/" + id))).toUpperCase();
}

export function apiL402VideoRefundToken() {
  const token = l402RefundNew();
  return { token, hash: l402RefundHash(token) };
}

export async function apiL402VideoRefund(env, id, sats, hash) {
  if (hash) return l402RefundMintHash(env, hash, sats);
  const token = apiL402VideoToken(env, id);
  if (!token) return null;
  return l402RefundMint(env, sats, token);
}

function refundFrom(api) {
  const m = /^\s*Bearer\s+(\S+)\s*$/i.exec(api.request.headers.get("Authorization") || "");
  const token = m ? l402RefundToken(m[1]) : "";
  if (!token) throw unauth("invalid_refund_token", "Send the refund token as `Authorization: Bearer REFUND-…`.");
  return token;
}

async function refundGet(api) {
  const token = refundFrom(api);
  const pending = await refundHooks(api, l402RefundHash(token));
  const peek = await l402RefundPeek(api.env, token);
  if (!peek.ok && pending) return apiJson({ object: "refund_token", sats: 0, status: "pending", created_at: null, expires_at: null });
  if (!peek.ok) throw unauth("invalid_refund_token", "Unknown refund token.");
  return apiJson({ object: "refund_token", sats: peek.sats, status: peek.state, created_at: apiIso(peek.createdAt), expires_at: apiIso(peek.expiresAt) });
}

async function refundRedeem(api) {
  const b = api.body || {};
  const token = l402RefundToken(b.refund_token);
  if (!token) throw apiBad("`refund_token` is required: the REFUND-… token from a failed paid request.", "refund_token", "missing_required_parameter");
  const tier = b.balance == null ? "standard" : b.balance;
  if (tier !== "standard" && tier !== "pro") throw apiBad("`balance` must be standard or pro.", "balance", "invalid_value");
  const per = tier === "pro" ? BOT_PRO_SATS_PER_CREDIT : BOT_SATS_PER_CREDIT;
  await apiRateLimit(api, "refundToken", l402RefundHash(token), "requests with this refund token");
  await refundHooks(api, l402RefundHash(token));
  const r = await l402RefundRedeem(api.env, api.auth.pubkey, token, tier, per);
  if (r.ok) return apiJson({ data: { credited: r.credited, tier: r.tier, balance_credits: r.balance, remaining_sats: r.remainingSats } });
  if (r.unknown) throw new ApiError(404, "not_found_error", r.error, { code: "refund_not_found", param: "refund_token" });
  if (r.expired) throw new ApiError(410, "invalid_request_error", r.error, { code: "refund_token_expired", param: "refund_token" });
  if (r.tooSmall) throw new ApiError(400, "invalid_request_error", r.error, { code: "refund_too_small", param: "refund_token", extra: { refund_token_sats: r.sats } });
  if (r.conflict) throw new ApiError(409, "invalid_request_error", r.error, { code: "refund_conflict" });
  throw new ApiError(503, "api_error", r.error || "Refunds are not available right now.", { code: "service_unavailable", headers: { "Retry-After": "30" } });
}

export function registerL402(r) {
  r.add("GET", "/l402/refunds", refundGet, { auth: "none", spends: false });
  r.add("POST", "/l402/refunds/redeem", refundRedeem, { auth: "nostr", spends: false });
}
