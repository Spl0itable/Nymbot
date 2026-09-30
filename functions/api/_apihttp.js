import { bytesToHex, randomBytes, hmac, sha256, utf8ToBytes } from "./_shared.js";
import { ledgerCall } from "./_ledger.js";
import { BtcPriceUnavailable } from "./_btcprice.js";

export const API_TIMING = { keepAliveMs: 15000, firstByteWaitMs: 8000 };
export const API_JSON_MAX_BYTES = 4 * 1024 * 1024;
export const API_MULTIPART_MAX_BYTES = 32 * 1024 * 1024;
export const API_RATE_LIMITS = {
  unauthIp: { limit: 120, windowMs: 60000 },
  keysPubkey: { limit: 60, windowMs: 3600000 },
  keysIp: { limit: 120, windowMs: 3600000 },
  topupPubkey: { limit: 60, windowMs: 3600000 },
  topupIp: { limit: 120, windowMs: 3600000 }
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

export function apiPreflightHeaders(request) {
  const h = Object.assign({}, API_CORS_HEADERS);
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
  404: "not_found_error", 405: "invalid_request_error", 413: "request_too_large", 422: "invalid_request_error",
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

export function apiFinish(res, requestId, extraHeaders) {
  if (res.headers.has("WWW-Authenticate")) {
    try {
      for (const [k, v] of Object.entries(API_CORS_HEADERS)) res.headers.set(k, v);
      if (extraHeaders) for (const [k, v] of Object.entries(extraHeaders)) res.headers.set(k, v);
      if (!res.headers.has("Cache-Control")) res.headers.set("Cache-Control", "no-store");
      res.headers.set("X-Request-Id", requestId);
      return res;
    } catch (e) { }
  }
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries(API_CORS_HEADERS)) headers.set(k, v);
  if (extraHeaders) for (const [k, v] of Object.entries(extraHeaders)) headers.set(k, v);
  if (!headers.has("Cache-Control")) headers.set("Cache-Control", "no-store");
  headers.set("X-Request-Id", requestId);
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
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

function rateSecret(env) {
  for (const name of ["API_RATE_SECRET", "API_L402_SECRET", "API_NWC_SECRET"]) {
    const s = env && env[name];
    if (typeof s === "string" && s.trim()) return s.trim();
  }
  return "nymbot-api-rate";
}

function rateError(rule, waitMs, what) {
  const secs = Math.max(1, Math.ceil((Number(waitMs) || 1000) / 1000));
  const span = rule.windowMs >= 3600000 ? "an hour" : (rule.windowMs >= 60000 ? "a minute" : Math.round(rule.windowMs / 1000) + " s");
  return new ApiError(429, "rate_limit_error", "Too many " + what + ": at most " + rule.limit + " " + span + ". Retry in " + secs + " s.",
    { code: "rate_limit_exceeded", headers: { "Retry-After": String(secs) } });
}

export async function apiRateLimit(api, name, who, what) {
  const rule = API_RATE_LIMITS[name];
  const id = String(who || "");
  if (!rule || !id) return;
  const keyId = bytesToHex(hmac(sha256, utf8ToBytes(rateSecret(api.env)), utf8ToBytes("nymbot-api-rate/" + name + "/" + id))).slice(0, 16);
  let r = null;
  try {
    r = await ledgerCall(api.env, { op: "key-reserve", keyId, sats: 0, now: Date.now(), rateLimit: rule.limit, rateWindowMs: rule.windowMs });
  } catch (e) { return; }
  if (r && r.rateLimited) throw rateError(rule, r.retryAfterMs, what);
}

export async function apiIpRateLimit(api, name, what) {
  const rule = API_RATE_LIMITS[name];
  const ip = apiClientIp(api);
  if (!rule || !ip) return;
  const now = Date.now();
  const win = Math.floor(now / rule.windowMs);
  let key = null;
  let count = 0;
  try {
    if (typeof caches === "undefined" || !caches.default) return;
    key = new Request("https://nymbot-api-rate.invalid/" + name + "?ip=" + encodeURIComponent(ip) + "&w=" + win);
    const hit = await caches.default.match(key);
    if (hit) {
      const n = parseInt(await hit.text(), 10);
      if (Number.isFinite(n)) count = n;
    }
  } catch (e) { return; }
  if (count >= rule.limit) throw rateError(rule, (win + 1) * rule.windowMs - now, what);
  try {
    await caches.default.put(key, new Response(String(count + 1), {
      headers: { "Content-Type": "text/plain", "Cache-Control": "max-age=" + Math.ceil(rule.windowMs / 1000) }
    }));
  } catch (e) { }
}
