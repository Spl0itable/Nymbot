import { bytesToHex, randomBytes, hmac, sha256, utf8ToBytes } from "./_shared.js";
import { ledgerCall } from "./_ledger.js";
import { BtcPriceUnavailable } from "./_btcprice.js";

export const API_TIMING = { keepAliveMs: 15000, firstByteWaitMs: 8000 };
export const API_JSON_MAX_BYTES = 4 * 1024 * 1024;
export const API_MULTIPART_MAX_BYTES = 32 * 1024 * 1024;
export const API_MULTIPART_MAX_PARTS = 64;
export const API_MULTIPART_MAX_HEADER_BYTES = 8192;
export const API_EMPTY_BODY_SHA256 = bytesToHex(sha256(new Uint8Array(0)));
export const API_RATE_LIMITS = {
  unauthIp: { limit: 120, windowMs: 60000 },
  keysPubkey: { limit: 60, windowMs: 3600000 },
  keysIp: { limit: 120, windowMs: 3600000 },
  topupPubkey: { limit: 60, windowMs: 3600000 },
  topupIp: { limit: 120, windowMs: 3600000 },
  authFailIp: { limit: 30, windowMs: 60000 },
  refundToken: { limit: 60, windowMs: 60000 },
  nwcPubkey: { limit: 10, windowMs: 3600000 },
  nwcIp: { limit: 30, windowMs: 3600000 }
};
export const API_NOSTR_MAX_BYTES = 64 * 1024;
export const API_ACCOUNT_ORIGINS = ["https://nymbot.ai", "https://nymchat.app", "https://nymbot.pages.dev"];
const ACCOUNT_ORIGIN_SUFFIXES = [".nymbot.ai", ".nymchat.app", ".nymbot.pages.dev"];
const SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'"
};

const ALLOW_HEADERS = [
  "Authorization", "Content-Type", "x-api-key", "api-key", "anthropic-version", "anthropic-beta",
  "anthropic-dangerous-direct-browser-access", "OpenAI-Beta", "OpenAI-Organization", "OpenAI-Project",
  "x-stainless-arch", "x-stainless-async", "x-stainless-custom-poll-interval", "x-stainless-helper-method",
  "x-stainless-lang", "x-stainless-os", "x-stainless-package-version", "x-stainless-poll-helper",
  "x-stainless-retry-count", "x-stainless-runtime", "x-stainless-runtime-version", "x-stainless-timeout"
];

export const API_CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": ALLOW_HEADERS.join(", "),
  "Access-Control-Expose-Headers": "X-Request-Id, X-Nymbot-Cost-Sats, X-Nymbot-Balance-Sats, Retry-After, WWW-Authenticate, Payment-Receipt",
  "Access-Control-Max-Age": "86400"
};

export function apiRequestId() {
  return "req_" + bytesToHex(randomBytes(12));
}

export function apiRandomId(prefix, n) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = randomBytes(n || 24);
  let out = "";
  for (let i = 0; i < bytes.length; i++) out += alphabet[bytes[i] % alphabet.length];
  return (prefix || "") + out;
}

export function apiAccountOrigin(origin) {
  let u;
  try { u = new URL(String(origin || "")); } catch (e) { return false; }
  if (u.protocol !== "https:" || u.origin !== String(origin)) return false;
  if (API_ACCOUNT_ORIGINS.includes(u.origin)) return true;
  return ACCOUNT_ORIGIN_SUFFIXES.some((s) => u.hostname.endsWith(s));
}

export function apiCorsHeaders(request, account) {
  const h = Object.assign({}, API_CORS_HEADERS);
  if (!account) return h;
  const origin = request && request.headers ? request.headers.get("Origin") : "";
  h["Access-Control-Allow-Origin"] = origin && apiAccountOrigin(origin) ? origin : null;
  h.Vary = "Origin";
  return h;
}

export function apiPreflightHeaders(request, account) {
  const h = apiCorsHeaders(request, account);
  const asked = request && request.headers ? request.headers.get("Access-Control-Request-Headers") : "";
  if (asked && /^[A-Za-z0-9\-_, ]{1,2000}$/.test(asked)) {
    const known = new Set(ALLOW_HEADERS.map((x) => x.toLowerCase()));
    const extra = asked.split(",").map((x) => x.trim()).filter((x) => x && !known.has(x.toLowerCase()));
    if (extra.length) h["Access-Control-Allow-Headers"] = ALLOW_HEADERS.concat(extra).join(", ");
  }
  return h;
}

export class ApiError extends Error {
  constructor(status, type, message, opts) {
    super(message);
    const o = opts || {};
    this.status = status;
    this.type = type;
    this.code = o.code == null ? null : o.code;
    this.param = o.param == null ? null : o.param;
    this.extra = o.extra || null;
    this.headers = o.headers || null;
  }
}

export function apiError(status, type, message, opts) {
  return new ApiError(status, type, message, opts);
}

export const apiBad = (message, param, code) => new ApiError(400, "invalid_request_error", message, { param: param || null, code: code || null });

const ANTHROPIC_TYPES = {
  400: "invalid_request_error", 401: "authentication_error", 402: "billing_error", 403: "permission_error",
  404: "not_found_error", 405: "invalid_request_error", 413: "request_too_large", 415: "invalid_request_error", 422: "invalid_request_error",
  429: "rate_limit_error", 500: "api_error", 501: "api_error", 502: "api_error", 503: "overloaded_error", 529: "overloaded_error"
};

export function apiErrorBody(err, format) {
  if (format === "anthropic") {
    return { type: "error", error: { type: ANTHROPIC_TYPES[err.status] || "api_error", message: err.message } };
  }
  const e = { message: err.message, type: err.type, code: err.code, param: err.param };
  if (err.extra) Object.assign(e, err.extra);
  return { error: e };
}

export function apiJson(obj, status, headers) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: Object.assign({ "Content-Type": "application/json" }, headers || {})
  });
}

export function apiErrorResponse(err, format) {
  if (err.response instanceof Response) return err.response;
  const headers = Object.assign({}, err.headers || {});
  return apiJson(apiErrorBody(err, format), err.status, headers);
}

function finishHeaders(headers, requestId, cors) {
  for (const [k, v] of Object.entries(Object.assign({}, cors || API_CORS_HEADERS, SECURITY_HEADERS))) {
    if (v == null) headers.delete(k);
    else headers.set(k, v);
  }
  if (!headers.has("Cache-Control")) headers.set("Cache-Control", "no-store");
  headers.set("X-Request-Id", requestId);
}

export function apiFinish(res, requestId, cors) {
  if (res.headers.has("WWW-Authenticate")) {
    try {
      finishHeaders(res.headers, requestId, cors);
      return res;
    } catch (e) { }
  }
  const headers = new Headers(res.headers);
  finishHeaders(headers, requestId, cors);
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}

export function apiRequireContentType(request, kind) {
  const type = String(request.headers.get("Content-Type") || "").split(";")[0].trim().toLowerCase();
  const ok = kind === "multipart" ? type === "multipart/form-data" : (type === "application/json" || /^application\/[a-z0-9.+-]+\+json$/.test(type));
  if (ok) return;
  if (!type && kind !== "multipart") {
    const declared = request.headers.get("Content-Length");
    if (!request.body || declared === "0") return;
  }
  const want = kind === "multipart" ? "multipart/form-data" : "application/json";
  throw new ApiError(415, "invalid_request_error", "This endpoint takes " + (kind === "multipart" ? "a multipart form" : "a JSON body") +
    ". Send `Content-Type: " + want + "`.",
    { code: "unsupported_media_type" });
}

export async function apiReadBody(request, max) {
  const declared = Number(request.headers.get("Content-Length"));
  const tooLarge = () => new ApiError(413, "invalid_request_error",
    "The request body is larger than the " + Math.round(max / 1024 / 1024) + " MB this endpoint accepts.", { code: "payload_too_large" });
  if (Number.isFinite(declared) && declared > max) throw tooLarge();
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const r = await reader.read();
    if (r.done) break;
    const piece = typeof r.value === "string" ? new TextEncoder().encode(r.value) : r.value;
    total += piece.length;
    if (total > max) {
      try { await reader.cancel(); } catch (e) { }
      throw tooLarge();
    }
    chunks.push(piece);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) { out.set(c, at); at += c.length; }
  return out;
}

function multipartBad(message) {
  return new ApiError(400, "invalid_request_error", message, { code: "invalid_multipart" });
}

function delimiterAt(bytes, at, delim) {
  if (at + delim.length > bytes.length) return false;
  for (let j = 0; j < delim.length; j++) if (bytes[at + j] !== delim[j]) return false;
  return true;
}

function headerEnd(bytes, from, limit) {
  const stop = Math.min(bytes.length - 3, from + limit);
  for (let i = from; i < stop; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) return i + 4;
  }
  return -1;
}

export function apiCheckMultipart(bytes, contentType) {
  const m = /;\s*boundary=(?:"([^"]*)"|([^\s;]*))/i.exec(String(contentType || ""));
  const boundary = m ? (m[1] != null ? m[1] : m[2]) : "";
  if (!/^[0-9A-Za-z'()+_,\-./:=? ]{0,69}[0-9A-Za-z'()+_,\-./:=?]$/.test(boundary)) {
    throw multipartBad("The multipart Content-Type needs a boundary of 1 to 70 letters, digits or '()+_,-./:=? characters.");
  }
  const delim = utf8ToBytes("--" + boundary);
  let parts = 0;
  let at = delimiterAt(bytes, 0, delim) ? 0 : -1;
  let i = 0;
  while (true) {
    if (at < 0) {
      for (; i < bytes.length - 1; i++) {
        if (bytes[i] === 13 && bytes[i + 1] === 10 && delimiterAt(bytes, i + 2, delim)) { at = i + 2; break; }
      }
      if (at < 0) break;
    }
    const after = at + delim.length;
    if (bytes[after] === 45 && bytes[after + 1] === 45) break;
    if (++parts > API_MULTIPART_MAX_PARTS) throw multipartBad("A multipart body may hold at most " + API_MULTIPART_MAX_PARTS + " parts.");
    const end = headerEnd(bytes, after, API_MULTIPART_MAX_HEADER_BYTES);
    if (end < 0) throw multipartBad("Each multipart part needs its headers, at most " + API_MULTIPART_MAX_HEADER_BYTES + " bytes, ended by a blank line.");
    i = end - 2;
    at = -1;
  }
}

export async function apiBufferMultipart(api, max, hash) {
  const bytes = await apiReadBody(api.request, max);
  apiCheckMultipart(bytes, api.request.headers.get("Content-Type"));
  if (hash) api.bodyHex = bytesToHex(sha256(bytes));
  api.request = new Request(api.request.url, { method: api.request.method, headers: api.request.headers, body: bytes });
}

export const API_IMAGE_URL_MAX_CHARS = 4096;

export function apiUrlHasUserinfo(url) {
  try {
    const u = new URL(url);
    return !!(u.username || u.password);
  } catch (e) {
    return /^[a-z][a-z0-9+.-]*:\/\/[^/?#]*@/i.test(String(url));
  }
}

export function apiDropBody(api) {
  api.request = new Request(api.request.url, { method: api.request.method, headers: api.request.headers });
}

export function apiSseHeaders() {
  return {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-store, no-transform",
    "X-Accel-Buffering": "no"
  };
}

export function apiSseStream() {
  const enc = new TextEncoder();
  let ctrl = null;
  let closed = false;
  let cancelled = false;
  let last = Date.now();
  let timer = null;
  const onCancel = [];
  const stop = () => { if (timer) { clearInterval(timer); timer = null; } };
  const stream = new ReadableStream({
    start(c) { ctrl = c; },
    cancel() {
      cancelled = true;
      closed = true;
      stop();
      for (const f of onCancel) { try { f(); } catch (e) { } }
    }
  });
  const write = (text) => {
    if (closed) return false;
    try {
      ctrl.enqueue(enc.encode(text));
      last = Date.now();
      return true;
    } catch (e) {
      closed = true;
      stop();
      return false;
    }
  };
  return {
    stream,
    data(obj) { return write("data: " + (typeof obj === "string" ? obj : JSON.stringify(obj)) + "\n\n"); },
    event(name, obj) { return write("event: " + name + "\ndata: " + JSON.stringify(obj) + "\n\n"); },
    comment(text) { return write(": " + text + "\n\n"); },
    keepAlive() {
      if (timer || closed) return;
      const every = Math.max(5, API_TIMING.keepAliveMs);
      timer = setInterval(() => {
        if (closed) { stop(); return; }
        if (Date.now() - last >= every * 0.9) write(": keep-alive\n\n");
      }, every);
    },
    close() {
      stop();
      if (closed) return;
      closed = true;
      try { ctrl.close(); } catch (e) { }
    },
    onCancel(fn) { onCancel.push(fn); },
    get cancelled() { return cancelled; },
    get closed() { return closed; }
  };
}

export function apiClientGone() {
  const e = new Error("The client closed the stream.");
  e.clientGone = true;
  return e;
}

export function apiRound(n, dp) {
  const f = Math.pow(10, dp == null ? 3 : dp);
  return Math.round((Number(n) || 0) * f) / f;
}

export function apiIso(ms) {
  const n = Number(ms);
  return Number.isFinite(n) && n > 0 ? new Date(n).toISOString() : null;
}

export function apiParseTime(v, param) {
  if (v == null || v === "") return null;
  if (typeof v === "number" || /^\d{10,16}$/.test(String(v))) {
    const n = Number(v);
    if (Number.isFinite(n) && n > 0) return Math.floor(n);
  } else if (typeof v === "string") {
    const t = Date.parse(v);
    if (Number.isFinite(t)) return t;
  }
  throw apiBad("`" + param + "` must be an ISO 8601 date or a time in milliseconds.", param, "invalid_date");
}

export function apiErrorFrom(e) {
  if (e instanceof ApiError) return e;
  if (e instanceof BtcPriceUnavailable) {
    return new ApiError(503, "api_error", "The Bitcoin price is unavailable, so the request cannot be priced. Retry in a minute.",
      { code: "price_unavailable", headers: { "Retry-After": "60" } });
  }
  return new ApiError(500, "api_error", "Internal error. Please retry.", { code: "internal_error" });
}

export function apiClientIp(api) {
  try { return String(api.request.headers.get("CF-Connecting-IP") || "").trim().slice(0, 64); } catch (e) { return ""; }
}

function ipv6Groups(s) {
  let text = s;
  const tail = /(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(text);
  if (tail) {
    const o = tail.slice(1).map(Number);
    if (o.some((x) => x > 255)) return null;
    text = text.slice(0, tail.index) + (o[0] * 256 + o[1]).toString(16) + ":" + (o[2] * 256 + o[3]).toString(16);
  }
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] ? halves[0].split(":") : [];
  const rest = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const fill = halves.length === 2 ? 8 - head.length - rest.length : 0;
  if (halves.length === 2 && fill < 1) return null;
  const groups = head.concat(new Array(Math.max(0, fill)).fill("0"), rest);
  if (groups.length !== 8 || groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return null;
  return groups.map((g) => parseInt(g, 16));
}

export function apiIpBucket(api) {
  const raw = apiClientIp(api).toLowerCase();
  if (!raw) return null;
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(raw);
  if (v4) return v4.slice(1).every((x) => Number(x) <= 255) ? "4:" + v4.slice(1).map(Number).join(".") : null;
  if (!/^[0-9a-f:.]+$/.test(raw)) return null;
  const g = ipv6Groups(raw);
  if (!g) return null;
  if (g.slice(0, 5).every((x) => x === 0) && g[5] === 0xffff) return "4:" + [g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255].join(".");
  return "6:" + g.slice(0, 4).map((x) => x.toString(16)).join(":") + "::/64";
}

let isolateRateKey = null;

function rateKey(env) {
  for (const name of ["API_RATE_SECRET", "API_L402_SECRET", "API_NWC_SECRET"]) {
    const s = env && env[name];
    if (typeof s === "string" && s.trim()) return hmac(sha256, utf8ToBytes(s.trim()), utf8ToBytes("nymbot-api-rate-key/v1"));
  }
  if (!isolateRateKey) isolateRateKey = randomBytes(32);
  return isolateRateKey;
}

function rateError(rule, waitMs, what) {
  const secs = Math.max(1, Math.ceil((Number(waitMs) || 1000) / 1000));
  const span = rule.windowMs >= 3600000 ? "an hour" : (rule.windowMs >= 60000 ? "a minute" : Math.round(rule.windowMs / 1000) + " s");
  return new ApiError(429, "rate_limit_error", "Too many " + what + ": at most " + rule.limit + " " + span + ". Retry in " + secs + " s.",
    { code: "rate_limit_exceeded", headers: { "Retry-After": String(secs) } });
}

export async function apiRateHit(env, name, who, rule) {
  const r0 = rule || API_RATE_LIMITS[name];
  const id = String(who || "");
  if (!r0 || !id) return 0;
  const keyId = bytesToHex(hmac(sha256, rateKey(env), utf8ToBytes("nymbot-api-rate/" + name + "/" + id))).slice(0, 16);
  let r = null;
  try {
    r = await ledgerCall(env, { op: "key-reserve", keyId, sats: 0, now: Date.now(), rateLimit: r0.limit, rateWindowMs: r0.windowMs });
  } catch (e) { r = null; }
  if (!r || r._noLedger) return -1;
  return r.rateLimited ? Math.max(1, Number(r.retryAfterMs) || 1000) : 0;
}

export async function apiRateLimit(api, name, who, what) {
  const rule = API_RATE_LIMITS[name];
  const wait = await apiRateHit(api.env, name, who, rule);
  if (wait > 0) throw rateError(rule, wait, what);
}

export async function apiIpRateLimit(api, name, what) {
  const bucket = apiIpBucket(api);
  if (!bucket) return;
  await apiRateLimit(api, name, "ip/" + bucket, what);
}

function authFailKey(bucket) {
  return new Request("https://nymbot-api-rate.invalid/auth-fail?b=" + encodeURIComponent(bucket));
}

function authFailError(secs) {
  return new ApiError(429, "rate_limit_error", "Too many failed authentication attempts from this address: at most " +
    API_RATE_LIMITS.authFailIp.limit + " a minute. Retry in " + secs + " s.", { code: "rate_limit_exceeded", headers: { "Retry-After": String(secs) } });
}

export async function apiAuthFailGate(api) {
  const bucket = apiIpBucket(api);
  if (!bucket) return;
  let until = NaN;
  try {
    if (typeof caches === "undefined" || !caches.default) return;
    const hit = await caches.default.match(authFailKey(bucket));
    if (!hit) return;
    until = parseInt(await hit.text(), 10);
  } catch (e) { return; }
  const now = Date.now();
  if (Number.isFinite(until) && until > now) throw authFailError(Math.max(1, Math.ceil((until - now) / 1000)));
}

export async function apiAuthFailed(api) {
  const bucket = apiIpBucket(api);
  if (!bucket) return null;
  const wait = await apiRateHit(api.env, "authFailIp", "ip/" + bucket);
  if (wait <= 0) return null;
  const until = Date.now() + wait;
  try {
    if (typeof caches !== "undefined" && caches.default) {
      await caches.default.put(authFailKey(bucket), new Response(String(until), {
        headers: { "Content-Type": "text/plain", "Cache-Control": "max-age=" + Math.max(1, Math.ceil(wait / 1000)) }
      }));
    }
  } catch (e) { }
  return authFailError(Math.max(1, Math.ceil(wait / 1000)));
}
