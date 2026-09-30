import { sha256, bytesToHex, utf8ToBytes, randomBytes, getEventHash, schnorr, AUTH_REPLAY_TTL_S } from "./_shared.js";
import { ledgerCall } from "./_ledger.js";
import { hasD1 } from "./_d1.js";
import { deniedStrict } from "./_usage.js";
import { ApiError, apiIso, API_EMPTY_BODY_SHA256 } from "./_apihttp.js";

export const API_KEY_PREFIX = "sk-nymbot-";
export const API_KEY_RE = /^sk-nymbot-[A-Za-z0-9_-]{43}$/;
export const API_KEY_RATE_LIMIT = 120;
export const API_KEY_RATE_WINDOW_MS = 60000;
export const API_KEY_TOUCH_MS = 60000;
export const API_NIP98_MAX_AGE_S = 60;

const KEYS_DDL = [
  "CREATE TABLE IF NOT EXISTS api_keys (id TEXT PRIMARY KEY, pubkey TEXT NOT NULL, name TEXT NOT NULL, hash TEXT UNIQUE NOT NULL, " +
  "hint TEXT, limit_sats INTEGER, reset_period TEXT, expire_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, " +
  "last_used_at INTEGER, revoked_at INTEGER)",
  "CREATE INDEX IF NOT EXISTS api_keys_pubkey ON api_keys (pubkey, created_at)",
  "CREATE UNIQUE INDEX IF NOT EXISTS api_keys_name ON api_keys (pubkey, lower(name)) WHERE revoked_at IS NULL"
];

const keysReady = new WeakSet();

export async function apiKeysDb(env) {
  const db = env && env.DB_CREDITS;
  if (!hasD1(db)) throw new ApiError(503, "api_error", "API keys are not available right now.", { code: "service_unavailable" });
  if (!keysReady.has(db)) {
    for (const ddl of KEYS_DDL) { try { await db.prepare(ddl).run(); } catch (e) { } }
    keysReady.add(db);
  }
  return db;
}

function base64url(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function apiKeyNew() {
  return API_KEY_PREFIX + base64url(randomBytes(32));
}

export function apiKeyHash(key) {
  return bytesToHex(sha256(utf8ToBytes(String(key))));
}

export function apiKeyHint(key) {
  const k = String(key);
  return API_KEY_PREFIX + k.slice(API_KEY_PREFIX.length, API_KEY_PREFIX.length + 4) + "…" + k.slice(-4);
}

export function apiKeyFromRequest(request) {
  const h = request.headers;
  const auth = h.get("Authorization") || "";
  const bearer = /^\s*Bearer\s+(\S+)\s*$/i.exec(auth);
  if (bearer) return { key: bearer[1] };
  if (/^\s*Nostr\s/i.test(auth)) return { nostr: true };
  const x = (h.get("x-api-key") || h.get("api-key") || "").trim();
  return x ? { key: x } : {};
}

const unauth = (message, code) => new ApiError(401, "authentication_error", message, { code });

export async function apiDeniedCheck(env, pubkey) {
  let no = false;
  try { no = await deniedStrict(env, pubkey); } catch (e) {
    throw new ApiError(503, "api_error", "Service temporarily unavailable. Try again shortly.", { code: "service_unavailable", headers: { "Retry-After": "30" } });
  }
  if (no) throw new ApiError(403, "permission_error", "This account cannot use the Nymbot API.", { code: "account_denied" });
}

export function apiKeyLimitError(r, row, extraMessage) {
  const limit = row.limit_sats;
  const reset = r && r.resetAt ? apiIso(r.resetAt) : null;
  const when = reset ? "It resets at " + reset + "." : "The limit never resets; raise it or remove it in the app.";
  const message = extraMessage || ("This API key reached its spend limit of " + limit + " sats. " + when);
  return new ApiError(403, "permission_error", message, {
    code: "key_limit_reached",
    extra: { limit_sats: limit, used_sats: r ? r.used : null, reset_at: reset }
  });
}

export async function apiAuthKey(api) {
  const got = apiKeyFromRequest(api.request);
  if (got.nostr) throw unauth("This endpoint takes an API key, not a Nostr signature. Send `Authorization: Bearer <key>`.", "invalid_api_key");
  if (!got.key) throw unauth("Missing API key. Send it as `Authorization: Bearer <key>`, `x-api-key: <key>` or `api-key: <key>`. Create keys in the Nymbot app under API.", "missing_api_key");
  if (!API_KEY_RE.test(got.key)) throw unauth("Invalid API key.", "invalid_api_key");
  const db = await apiKeysDb(api.env);
  const row = await db.prepare("SELECT * FROM api_keys WHERE hash = ? LIMIT 1").bind(apiKeyHash(got.key)).first();
  if (!row) throw unauth("Invalid API key.", "invalid_api_key");
  const now = Date.now();
  if (row.revoked_at) throw unauth("This API key was revoked on " + apiIso(row.revoked_at) + ".", "revoked_api_key");
  if (row.expire_at && row.expire_at <= now) throw unauth("This API key expired on " + apiIso(row.expire_at) + ".", "expired_api_key");
  await apiDeniedCheck(api.env, row.pubkey);
  const check = await ledgerCall(api.env, {
    op: "key-reserve", keyId: row.id, sats: 0, limit: row.limit_sats, period: row.reset_period || null, now,
    rateLimit: API_KEY_RATE_LIMIT, rateWindowMs: API_KEY_RATE_WINDOW_MS
  });
  if (check && check.rateLimited) {
    const secs = Math.max(1, Math.ceil((Number(check.retryAfterMs) || 1000) / 1000));
    throw new ApiError(429, "rate_limit_error", "This API key is limited to " + API_KEY_RATE_LIMIT + " requests a minute. Retry in " + secs + " s.",
      { code: "rate_limit_exceeded", headers: { "Retry-After": String(secs) } });
  }
  if (check && check.capped && !(api.route && api.route.opts && api.route.opts.spends === false)) throw apiKeyLimitError(check, row);
  if (!row.last_used_at || now - row.last_used_at > API_KEY_TOUCH_MS) {
    const touch = db.prepare("UPDATE api_keys SET last_used_at = ? WHERE id = ?").bind(now, row.id).run().catch(() => { });
    api.waitUntil(touch);
  }
  api.auth = { via: "key", pubkey: row.pubkey, keyId: row.id, key: row };
  return api.auth;
}

function decodeEvent(token) {
  let text = "";
  try {
    const b64 = token.replace(/-/g, "+").replace(/_/g, "/");
    const bin = atob(b64 + "===".slice((b64.length + 3) % 4));
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    text = new TextDecoder().decode(bytes);
    return JSON.parse(text);
  } catch (e) {
    return null;
  }
}

function tagOf(evt, name) {
  const tags = Array.isArray(evt.tags) ? evt.tags : [];
  for (const t of tags) if (Array.isArray(t) && t[0] === name) return t[1];
  return null;
}

function sameUrl(a, b) {
  try { return new URL(a).href === new URL(b).href; } catch (e) { return false; }
}

const badNostr = (why) => unauth("Invalid Nostr authorization: " + why + ". Sign a NIP-98 event (kind 27235) with `u`, `method` and, for a body, `payload` tags.", "invalid_nostr_auth");

function nostrBodyMethod(method) {
  return method === "POST" || method === "PATCH" || method === "PUT";
}

export function apiNostrReplayId(id) {
  return bytesToHex(sha256(utf8ToBytes("nymbot-api-nip98/" + String(id))));
}

export function apiNostrEvent(api) {
  const header = api.request.headers.get("Authorization") || "";
  const m = /^\s*Nostr\s+(\S+)\s*$/i.exec(header);
  const bad = badNostr;
  if (!m) throw unauth("This endpoint needs a NIP-98 Nostr signature from your nym: `Authorization: Nostr <base64 event>`. API keys are not accepted here.", "missing_nostr_auth");
  if (m[1].length > 16384) throw bad("the event is too large");
  const evt = decodeEvent(m[1]);
  if (!evt || typeof evt !== "object") throw bad("not a base64 JSON event");
  if (evt.kind !== 27235) throw bad("the event kind must be 27235");
  if (typeof evt.pubkey !== "string" || !/^[0-9a-f]{64}$/.test(evt.pubkey)) throw bad("bad pubkey");
  const nowSec = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(evt.created_at) || Math.abs(nowSec - evt.created_at) > API_NIP98_MAX_AGE_S) throw bad("created_at must be within 60 seconds of now");
  let valid = false;
  try { valid = getEventHash(evt) === evt.id && schnorr.verify(evt.sig, evt.id, evt.pubkey); } catch (e) { valid = false; }
  if (!valid) throw bad("the signature does not verify");
  if (!sameUrl(tagOf(evt, "u"), api.request.url)) throw bad("the `u` tag must be the exact request URL");
  if (String(tagOf(evt, "method") || "").toUpperCase() !== api.request.method.toUpperCase()) throw bad("the `method` tag must be " + api.request.method.toUpperCase());
  if (nostrBodyMethod(api.request.method.toUpperCase()) && tagOf(evt, "payload") == null) throw bad("a `payload` tag with the SHA-256 of the body is required");
  return evt;
}

export async function apiNostrFinish(api, evt) {
  const payload = tagOf(evt, "payload");
  if (nostrBodyMethod(api.request.method.toUpperCase()) || payload != null) {
    const want = api.bodyHex || API_EMPTY_BODY_SHA256;
    if (payload == null) throw badNostr("a `payload` tag with the SHA-256 of the body is required");
    if (String(payload).toLowerCase() !== want) throw badNostr("the `payload` tag does not match the body");
  }
  const rp = await ledgerCall(api.env, { op: "replay", id: apiNostrReplayId(evt.id), ttl: Math.max(AUTH_REPLAY_TTL_S, API_NIP98_MAX_AGE_S * 2 + 30) });
  if (rp && rp._noLedger) throw new ApiError(503, "api_error", "Service temporarily unavailable.", { code: "service_unavailable" });
  if (!rp || !rp.fresh) throw unauth("This signature was already used. Sign a new event for every request.", "nostr_auth_replayed");
  await apiDeniedCheck(api.env, evt.pubkey);
  api.auth = { via: "nostr", pubkey: evt.pubkey, keyId: null, key: null };
  return api.auth;
}

export async function apiAuthNostr(api) {
  return apiNostrFinish(api, apiNostrEvent(api));
}

export async function apiAuthKeyOrNostr(api) {
  const auth = api.request.headers.get("Authorization") || "";
  if (/^\s*Nostr\s/i.test(auth)) return apiAuthNostr(api);
  return apiAuthKey(api);
}
