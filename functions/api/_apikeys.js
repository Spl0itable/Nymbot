import { ledgerCall } from "./_ledger.js";
import { bytesToHex, randomBytes } from "./_shared.js";
import { ApiError, apiBad, apiIso, apiJson, apiRateLimit, apiClientIp } from "./_apihttp.js";
import { apiKeysDb, apiKeyNew, apiKeyHash, apiKeyHint } from "./_apiauth.js";
import { apiBalances } from "./_apibill.js";

export const API_KEYS_MAX_ACTIVE = 25;
export const API_KEYS_MAX_REVOKED = 50;
export const API_KEY_NAME_MAX = 40;
const PERIODS = ["daily", "weekly", "monthly"];
const PATCHABLE = ["name", "limit_sats", "reset_period", "expire_at"];

export const apiAccountFields = [];

export function apiAddAccountField(fn) {
  apiAccountFields.push(fn);
}

async function usageFor(env, rows) {
  if (!rows.length) return {};
  const r = await ledgerCall(env, {
    op: "key-usage", now: Date.now(),
    keys: rows.map((k) => ({ id: k.id, period: k.reset_period || null }))
  });
  return r && r.usage ? r.usage : {};
}

export function apiKeyObject(row, u) {
  const usage = u || {};
  return {
    id: row.id,
    name: row.name,
    hint: row.hint,
    limit_sats: row.limit_sats == null ? null : row.limit_sats,
    reset_period: row.reset_period || null,
    reset_at: row.reset_period && usage.resetAt ? apiIso(usage.resetAt) : null,
    expire_at: apiIso(row.expire_at),
    period_used_sats: usage.periodUsedSats || 0,
    total_used_sats: usage.totalSats || 0,
    created_at: apiIso(row.created_at),
    updated_at: apiIso(row.updated_at),
    last_used_at: apiIso(row.last_used_at),
    revoked_at: apiIso(row.revoked_at)
  };
}

async function oneObject(env, row) {
  const u = await usageFor(env, [row]);
  return apiKeyObject(row, u[row.id]);
}

function validName(v) {
  if (typeof v !== "string") throw apiBad("`name` is required: 1 to " + API_KEY_NAME_MAX + " characters.", "name");
  const name = v.trim();
  if (!name || name.length > API_KEY_NAME_MAX) throw apiBad("`name` must be 1 to " + API_KEY_NAME_MAX + " characters.", "name");
  return name;
}

function validLimit(v) {
  if (v == null) return null;
  if (typeof v !== "number" || !Number.isInteger(v) || v < 1 || v > 1e12) throw apiBad("`limit_sats` must be a whole number of sats, at least 1, or null.", "limit_sats");
  return v;
}

function validPeriod(v) {
  if (v == null) return null;
  if (!PERIODS.includes(v)) throw apiBad("`reset_period` must be daily, weekly, monthly or null.", "reset_period");
  return v;
}

function validExpire(v) {
  if (v == null) return null;
  let t = NaN;
  if (typeof v === "number") t = v;
  else if (typeof v === "string") t = /^\d{10,16}$/.test(v) ? Number(v) : Date.parse(v);
  if (!Number.isFinite(t)) throw apiBad("`expire_at` must be an ISO 8601 date or a time in milliseconds.", "expire_at");
  if (t <= Date.now()) throw apiBad("`expire_at` must be in the future.", "expire_at");
  return Math.floor(t);
}

function checkPair(limit, period) {
  if (period && limit == null) throw apiBad("`reset_period` needs `limit_sats`.", "reset_period");
}

async function ownRow(api) {
  const db = await apiKeysDb(api.env);
  const id = String(api.params.id || "");
  const row = /^[0-9a-f]{16}$/.test(id)
    ? await db.prepare("SELECT * FROM api_keys WHERE id = ? AND pubkey = ? LIMIT 1").bind(id, api.auth.pubkey).first()
    : null;
  if (!row) throw new ApiError(404, "not_found_error", "No API key with that id.", { code: "key_not_found", param: "id" });
  return { db, row };
}

async function nameTaken(db, pubkey, name, except) {
  const hit = await db.prepare("SELECT id FROM api_keys WHERE pubkey = ? AND lower(name) = lower(?) AND revoked_at IS NULL AND id != ? LIMIT 1")
    .bind(pubkey, name, except || "").first();
  return !!hit;
}

const dupName = () => apiBad("You already have an active key with that name.", "name", "duplicate_name");

async function listKeys(api) {
  const db = await apiKeysDb(api.env);
  const all = /^(?:true|1)$/i.test(api.url.searchParams.get("include_revoked") || "");
  const rs = await db.prepare("SELECT * FROM api_keys WHERE pubkey = ?" + (all ? "" : " AND revoked_at IS NULL") + " ORDER BY created_at DESC, rowid DESC")
    .bind(api.auth.pubkey).all();
  const rows = (rs && rs.results) || [];
  const usage = await usageFor(api.env, rows);
  return apiJson({ data: rows.map((r) => apiKeyObject(r, usage[r.id])) });
}

async function pruneRevoked(db, pubkey) {
  try {
    await db.prepare("DELETE FROM api_keys WHERE pubkey = ? AND revoked_at IS NOT NULL AND id NOT IN " +
      "(SELECT id FROM api_keys WHERE pubkey = ? AND revoked_at IS NOT NULL ORDER BY revoked_at DESC, rowid DESC LIMIT ?)")
      .bind(pubkey, pubkey, API_KEYS_MAX_REVOKED).run();
  } catch (e) { }
}

async function createKey(api) {
  await apiRateLimit(api, "keysIp", apiClientIp(api), "API keys created from this address");
  await apiRateLimit(api, "keysPubkey", api.auth.pubkey, "API keys created by this account");
  const b = api.body || {};
  const unknown = Object.keys(b).find((k) => !PATCHABLE.includes(k));
  if (unknown) throw apiBad("Unknown field `" + unknown + "`.", unknown, "unknown_parameter");
  const name = validName(b.name);
  const limit = validLimit(b.limit_sats);
  const period = validPeriod(b.reset_period);
  checkPair(limit, period);
  const expire = validExpire(b.expire_at);
  const db = await apiKeysDb(api.env);
  const pubkey = api.auth.pubkey;
  const count = await db.prepare("SELECT COUNT(*) AS n FROM api_keys WHERE pubkey = ? AND revoked_at IS NULL").bind(pubkey).first();
  if (count && Number(count.n) >= API_KEYS_MAX_ACTIVE) {
    throw apiBad("You can have up to " + API_KEYS_MAX_ACTIVE + " active keys. Revoke one first.", null, "too_many_keys");
  }
  if (await nameTaken(db, pubkey, name)) throw dupName();
  const key = apiKeyNew();
  const now = Date.now();
  const row = {
    id: bytesToHex(randomBytes(8)), pubkey, name, hash: apiKeyHash(key), hint: apiKeyHint(key), limit_sats: limit,
    reset_period: period, expire_at: expire, created_at: now, updated_at: now, last_used_at: null, revoked_at: null
  };
  try {
    await db.prepare("INSERT INTO api_keys (id, pubkey, name, hash, hint, limit_sats, reset_period, expire_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
      .bind(row.id, pubkey, name, row.hash, row.hint, limit, period, expire, now, now).run();
  } catch (e) {
    if (/unique|constraint/i.test(String((e && e.message) || e))) throw dupName();
    throw e;
  }
  const obj = await oneObject(api.env, row);
  obj.key = key;
  return apiJson({ data: obj }, 201);
}

async function getKey(api) {
  const { row } = await ownRow(api);
  return apiJson({ data: await oneObject(api.env, row) });
}

async function patchKey(api) {
  const b = api.body || {};
  const unknown = Object.keys(b).find((k) => !PATCHABLE.includes(k));
  if (unknown) throw apiBad("Unknown field `" + unknown + "`. Editable: " + PATCHABLE.join(", ") + ".", unknown, "unknown_parameter");
  const { db, row } = await ownRow(api);
  if (row.revoked_at) throw apiBad("This key is revoked and can no longer be changed.", null, "key_revoked");
  const next = Object.assign({}, row);
  if ("name" in b) next.name = validName(b.name);
  if ("limit_sats" in b) next.limit_sats = validLimit(b.limit_sats);
  if ("reset_period" in b) next.reset_period = validPeriod(b.reset_period);
  if ("expire_at" in b) next.expire_at = validExpire(b.expire_at);
  checkPair(next.limit_sats, next.reset_period);
  if (next.name !== row.name && await nameTaken(db, api.auth.pubkey, next.name, row.id)) throw dupName();
  next.updated_at = Date.now();
  try {
    await db.prepare("UPDATE api_keys SET name = ?, limit_sats = ?, reset_period = ?, expire_at = ?, updated_at = ? WHERE id = ? AND pubkey = ?")
      .bind(next.name, next.limit_sats, next.reset_period || null, next.expire_at, next.updated_at, row.id, api.auth.pubkey).run();
  } catch (e) {
    if (/unique|constraint/i.test(String((e && e.message) || e))) throw dupName();
    throw e;
  }
  if ((next.reset_period || null) !== (row.reset_period || null)) {
    await ledgerCall(api.env, { op: "key-reset", keyId: row.id, period: next.reset_period || null, now: Date.now() });
  }
  return apiJson({ data: await oneObject(api.env, next) });
}

async function revokeKey(api) {
  const { db, row } = await ownRow(api);
  if (!row.revoked_at) {
    const now = Date.now();
    await db.prepare("UPDATE api_keys SET revoked_at = ?, updated_at = ? WHERE id = ? AND pubkey = ? AND revoked_at IS NULL")
      .bind(now, now, row.id, api.auth.pubkey).run();
    await pruneRevoked(db, api.auth.pubkey);
  }
  return apiJson({ data: { id: row.id, revoked: true } });
}

async function account(api) {
  const db = await apiKeysDb(api.env);
  const pubkey = api.auth.pubkey;
  const c = await db.prepare("SELECT COUNT(*) AS n FROM api_keys WHERE pubkey = ? AND revoked_at IS NULL AND (expire_at IS NULL OR expire_at > ?)")
    .bind(pubkey, Date.now()).first();
  const out = { pubkey, balances: await apiBalances(api.env, pubkey), keys_active: c ? Number(c.n) || 0 : 0, nwc_auto_topup: null };
  for (const fn of apiAccountFields) {
    try { Object.assign(out, (await fn(api, pubkey)) || {}); } catch (e) { }
  }
  return apiJson({ data: out });
}

export function registerKeys(r) {
  r.add("GET", "/keys", listKeys, { auth: "nostr" });
  r.add("POST", "/keys", createKey, { auth: "nostr" });
  r.add("GET", "/keys/{id}", getKey, { auth: "nostr" });
  r.add("PATCH", "/keys/{id}", patchKey, { auth: "nostr" });
  r.add("DELETE", "/keys/{id}", revokeKey, { auth: "nostr" });
  r.add("GET", "/account", account, { auth: "nostr" });
}
