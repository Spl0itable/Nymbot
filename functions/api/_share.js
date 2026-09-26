import { getEventHash, schnorr, botBase64Encode, botBase64Decode } from "./_shared.js";

const SHARE_HOSTS = new Set([
  "blossom.band",
  "blossom.primal.net",
  "blossom.yakihonne.com",
  "files.sovbit.host",
  "nostr.download"
]);

const MAX_SHARE_BYTES = 12 * 1024 * 1024;
const SHARE_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

export function shareBase(server) {
  if (!server) return null;
  try {
    const u = new URL(server);
    if (u.protocol !== "https:") return null;
    if (!SHARE_HOSTS.has(u.hostname)) return null;
    return "https://" + u.hostname;
  } catch (_) {
    return null;
  }
}

export function shareHash(value) {
  const x = String(value || "").toLowerCase();
  return /^[0-9a-f]{64}$/.test(x) ? x : null;
}

function reply(body, status, cors, type) {
  const headers = new Headers(cors || {});
  headers.set("Content-Type", type || "application/json");
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  return new Response(type ? body : JSON.stringify(body), { status, headers });
}

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readCapped(resp, max) {
  const body = resp.body;
  if (!body || typeof body.getReader !== "function") {
    const all = await resp.arrayBuffer();
    return all.byteLength > max ? null : all;
  }
  const reader = body.getReader();
  const parts = [];
  let total = 0;
  while (true) {
    const step = await reader.read();
    if (step.done) break;
    total += step.value ? step.value.byteLength : 0;
    if (total > max) {
      try { await reader.cancel(); } catch (_) { }
      return null;
    }
    parts.push(step.value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.byteLength; }
  return out.buffer;
}

const STORE_CHUNK_BYTES = 1024 * 1024;
const AUTH_WINDOW_S = 600;

export function shareIsOurs(server, request) {
  if (!server) return false;
  try {
    const u = new URL(server);
    return u.protocol === "https:" && u.hostname === new URL(request.url).hostname;
  } catch (_) {
    return false;
  }
}

function shareDb(env) {
  const db = env && env.DB_PM;
  return db && typeof db.prepare === "function" ? db : null;
}

const SHARE_TTL_S = 24 * 60 * 60;
const SHARE_OWNER_MAX_BYTES = 50 * 1024 * 1024;
const SHARE_OWNER_MAX_COUNT = 20;
const SHARE_OWNER_HOURLY_UPLOADS = 10;
const SHARE_GLOBAL_MAX_BYTES = 1024 * 1024 * 1024;
const SHARE_IP_HOURLY_PUTS = 30;
const SHARE_SWEEP_ROWS = 200;
const SHARE_RATE_HOST = "https://nymbot-share-rate.invalid";
const SHARE_LIVE = "COALESCE(expires_at, created_at + " + SHARE_TTL_S + ") > ?";
const SHARE_SIZE = "COALESCE(size, LENGTH(data) * 3 / 4)";

const readyDbs = new WeakSet();

async function ensureShares(db) {
  if (readyDbs.has(db)) return;
  const ddl = [
    "CREATE TABLE IF NOT EXISTS shares (hash TEXT NOT NULL, part INTEGER NOT NULL, parts INTEGER NOT NULL, " +
    "owner TEXT NOT NULL, data TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER, size INTEGER, " +
    "PRIMARY KEY (hash, part))",
    "ALTER TABLE shares ADD COLUMN expires_at INTEGER",
    "ALTER TABLE shares ADD COLUMN size INTEGER",
    "CREATE INDEX IF NOT EXISTS shares_owner ON shares (owner)",
    "CREATE INDEX IF NOT EXISTS shares_expires ON shares (expires_at)"
  ];
  let created = false;
  for (let i = 0; i < ddl.length; i++) {
    try { await db.prepare(ddl[i]).run(); if (i === 0) created = true; } catch (_) { }
  }
  if (created) readyDbs.add(db);
}

const SHARE_READ_SWEEP_MS = 60 * 1000;
let shareReadSweptAt = 0;

async function sweepOnRead(db) {
  const at = Date.now();
  if (at - shareReadSweptAt < SHARE_READ_SWEEP_MS) return;
  shareReadSweptAt = at;
  await sweepExpired(db, Math.floor(at / 1000));
}

async function sweepExpired(db, now) {
  try {
    await db.prepare("DELETE FROM shares WHERE rowid IN (SELECT rowid FROM shares WHERE NOT (" + SHARE_LIVE + ") LIMIT ?)")
      .bind(now, SHARE_SWEEP_ROWS).run();
  } catch (err) {
    console.error("[share] sweep failed", err);
  }
}

function clientIp(request) {
  try { return request.headers.get("CF-Connecting-IP") || ""; } catch (_) { return ""; }
}

async function ipRateOk(request) {
  const ip = clientIp(request);
  if (!ip) return true;
  try {
    if (typeof caches === "undefined" || !caches.default) return true;
    const windowId = Math.floor(Date.now() / 3600000);
    const key = new Request(SHARE_RATE_HOST + "/put?ip=" + encodeURIComponent(ip) + "&w=" + windowId);
    let count = 0;
    const hit = await caches.default.match(key);
    if (hit) {
      const n = parseInt(await hit.text(), 10);
      if (Number.isFinite(n)) count = n;
    }
    if (count >= SHARE_IP_HOURLY_PUTS) return false;
    await caches.default.put(key, new Response(String(count + 1), {
      headers: { "Content-Type": "text/plain", "Cache-Control": "max-age=3600" }
    }));
  } catch (_) { }
  return true;
}

async function quotaRefusal(db, owner, incoming, now) {
  const mine = await db.prepare("SELECT COUNT(DISTINCT hash) AS n, COALESCE(SUM(" + SHARE_SIZE + "), 0) AS bytes, " +
    "COUNT(DISTINCT CASE WHEN created_at > ? THEN hash END) AS recent FROM shares WHERE owner = ? AND " + SHARE_LIVE)
    .bind(now - 3600, owner, now).first();
  const n = Number(mine && mine.n) || 0;
  const bytes = Number(mine && mine.bytes) || 0;
  const recent = Number(mine && mine.recent) || 0;
  if (recent >= SHARE_OWNER_HOURLY_UPLOADS) return [429, "Too many shares this hour"];
  if (n >= SHARE_OWNER_MAX_COUNT) return [429, "Share limit reached"];
  if (bytes + incoming > SHARE_OWNER_MAX_BYTES) return [429, "Share storage limit reached"];
  const all = await db.prepare("SELECT COALESCE(SUM(" + SHARE_SIZE + "), 0) AS bytes FROM shares WHERE " + SHARE_LIVE)
    .bind(now).first();
  if ((Number(all && all.bytes) || 0) + incoming > SHARE_GLOBAL_MAX_BYTES) return [503, "Share storage is full"];
  return null;
}

function shareAuth(request, verb, hash) {
  const header = request.headers.get("Authorization") || "";
  if (!header.startsWith("Nostr ")) return null;
  let evt;
  try { evt = JSON.parse(atob(header.slice(6).trim())); } catch (_) { return null; }
  if (!evt || evt.kind !== 24242 || typeof evt.pubkey !== "string" || !/^[0-9a-f]{64}$/.test(evt.pubkey)) return null;
  const tags = Array.isArray(evt.tags) ? evt.tags : [];
  const tag = (name) => { const t = tags.find((x) => Array.isArray(x) && x[0] === name); return t ? String(t[1] || "") : ""; };
  if (tag("t") !== verb || tag("x").toLowerCase() !== hash) return null;
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(evt.created_at) || Math.abs(now - evt.created_at) > AUTH_WINDOW_S) return null;
  const exp = parseInt(tag("expiration"), 10);
  if (Number.isFinite(exp) && exp < now) return null;
  try {
    if (getEventHash(evt) !== evt.id) return null;
    if (!schnorr.verify(evt.sig, evt.id, evt.pubkey)) return null;
  } catch (_) {
    return null;
  }
  return evt.pubkey;
}

export async function handleSharePut(request, params, cors, env) {
  if (request.method !== "PUT" && request.method !== "POST") return reply({ error: "PUT required" }, 405, cors);
  const db = shareDb(env);
  if (!db) return reply({ error: "Share storage unavailable" }, 503, cors);
  if (!(await ipRateOk(request))) return reply({ error: "Too many uploads" }, 429, cors);
  const declared = parseInt(request.headers.get("Content-Length") || "", 10);
  if (Number.isFinite(declared) && declared > MAX_SHARE_BYTES) return reply({ error: "Too large" }, 413, cors);
  const buf = await readCapped(request, MAX_SHARE_BYTES);
  if (!buf) return reply({ error: "Too large" }, 413, cors);
  const bytes = new Uint8Array(buf);
  if (!bytes.length) return reply({ error: "Empty" }, 400, cors);
  const hash = await sha256Hex(bytes);
  const owner = shareAuth(request, "upload", hash);
  if (!owner) return reply({ error: "Missing or invalid Nostr auth" }, 401, cors);
  await ensureShares(db);
  const now = Math.floor(Date.now() / 1000);
  await sweepExpired(db, now);
  try {
    await db.prepare("DELETE FROM shares WHERE hash = ? AND NOT (" + SHARE_LIVE + ")").bind(hash, now).run();
  } catch (err) {
    console.error("[share] expired cleanup failed", err);
  }
  const existing = await db.prepare("SELECT owner, COALESCE(expires_at, created_at + " + SHARE_TTL_S + ") AS expires FROM shares WHERE hash = ? AND part = 0")
    .bind(hash).first();
  if (existing) {
    return existing.owner === owner
      ? reply({ sha256: hash, size: bytes.length, expires: existing.expires }, 200, cors)
      : reply({ error: "Already stored" }, 409, cors);
  }
  const refused = await quotaRefusal(db, owner, bytes.length, now);
  if (refused) return reply({ error: refused[1] }, refused[0], cors);
  const parts = Math.ceil(bytes.length / STORE_CHUNK_BYTES);
  const expires = now + SHARE_TTL_S;
  const stmts = [];
  for (let i = 0; i < parts; i++) {
    const chunk = bytes.subarray(i * STORE_CHUNK_BYTES, Math.min(bytes.length, (i + 1) * STORE_CHUNK_BYTES));
    stmts.push(db.prepare("INSERT OR IGNORE INTO shares (hash, part, parts, owner, data, created_at, expires_at, size) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
      .bind(hash, i, parts, owner, botBase64Encode(chunk), now, expires, chunk.length));
  }
  try {
    await db.batch(stmts);
  } catch (err) {
    console.error("[share] store failed", err);
    return reply({ error: "Could not store the share" }, 500, cors);
  }
  return reply({ sha256: hash, size: bytes.length, expires }, 201, cors);
}

async function readStored(db, hash) {
  await ensureShares(db);
  const now = Math.floor(Date.now() / 1000);
  const rs = await db.prepare("SELECT part, parts, data FROM shares WHERE hash = ? AND " + SHARE_LIVE + " ORDER BY part")
    .bind(hash, now).all();
  const rows = (rs && rs.results) || [];
  if (!rows.length || rows.length !== rows[0].parts) return null;
  const chunks = rows.map((r) => botBase64Decode(r.data));
  const total = chunks.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) { out.set(c, at); at += c.length; }
  return out;
}

export async function handleShareBlob(request, params, cors, env) {
  if (request.method !== "GET") return reply({ error: "GET required" }, 405, cors);
  if (shareIsOurs(params.get("server"), request)) {
    const hash = shareHash(params.get("x"));
    const db = shareDb(env);
    if (!hash) return reply({ error: "Unknown blob" }, 400, cors);
    if (!db) return reply({ error: "Share storage unavailable" }, 503, cors);
    await sweepOnRead(db);
    const bytes = await readStored(db, hash);
    if (!bytes) return reply({ error: "Gone" }, 404, cors);
    if (await sha256Hex(bytes) !== hash) return reply({ error: "Hash mismatch" }, 502, cors);
    return reply(bytes, 200, cors, "application/octet-stream");
  }
  const base = shareBase(params.get("server"));
  const hash = shareHash(params.get("x"));
  if (!base || !hash) return reply({ error: "Unknown blob" }, 400, cors);
  const resp = await fetch(base + "/" + hash, {
    headers: { "User-Agent": SHARE_UA, "Accept": "*/*" },
    cf: { cacheTtl: 0, cacheEverything: false }
  });
  if (resp.status === 404 || resp.status === 410) return reply({ error: "Gone" }, 404, cors);
  if (!resp.ok) return reply({ error: "Upstream returned " + resp.status }, 502, cors);
  const declared = parseInt(resp.headers.get("content-length") || "", 10);
  if (Number.isFinite(declared) && declared > MAX_SHARE_BYTES) return reply({ error: "Too large" }, 413, cors);
  const bytes = await readCapped(resp, MAX_SHARE_BYTES);
  if (!bytes) return reply({ error: "Too large" }, 413, cors);
  if (await sha256Hex(bytes) !== hash) return reply({ error: "Hash mismatch" }, 502, cors);
  return reply(bytes, 200, cors, "application/octet-stream");
}

export async function handleShareDelete(request, params, cors, env) {
  if (request.method !== "POST" && request.method !== "DELETE") {
    return reply({ error: "POST required" }, 405, cors);
  }
  if (shareIsOurs(params.get("server"), request)) {
    const hash = shareHash(params.get("x"));
    const db = shareDb(env);
    if (!hash) return reply({ error: "Unknown blob" }, 400, cors);
    if (!db) return reply({ error: "Share storage unavailable" }, 503, cors);
    const owner = shareAuth(request, "delete", hash);
    if (!owner) return reply({ error: "Missing or invalid Nostr auth" }, 401, cors);
    await ensureShares(db);
    const row = await db.prepare("SELECT owner FROM shares WHERE hash = ? AND part = 0").bind(hash).first();
    if (!row) return reply({ ok: true, status: 404 }, 200, cors);
    if (row.owner !== owner) return reply({ error: "Not the owner" }, 403, cors);
    await db.prepare("DELETE FROM shares WHERE hash = ?").bind(hash).run();
    return reply({ ok: true, status: 200 }, 200, cors);
  }
  const base = shareBase(params.get("server"));
  const hash = shareHash(params.get("x"));
  if (!base || !hash) return reply({ error: "Unknown blob" }, 400, cors);
  const auth = request.headers.get("Authorization");
  if (!auth || !auth.startsWith("Nostr ")) return reply({ error: "Missing Nostr auth" }, 401, cors);
  const resp = await fetch(base + "/" + hash, {
    method: "DELETE",
    headers: { "Authorization": auth, "User-Agent": SHARE_UA, "Accept": "application/json" }
  });
  if (resp.ok || resp.status === 404) return reply({ ok: true, status: resp.status }, 200, cors);
  return reply({ error: "Upstream returned " + resp.status, status: resp.status }, resp.status === 401 || resp.status === 403 ? 403 : 502, cors);
}
