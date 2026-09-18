// Per-turn usage records for the Nymbot

import { hasD1, replica } from "./_d1.js";

const USAGE_DDL = [
  "CREATE TABLE IF NOT EXISTS bot_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, pubkey TEXT NOT NULL, " +
  "kind TEXT NOT NULL, tier TEXT NOT NULL, task TEXT, model TEXT, calls INTEGER NOT NULL DEFAULT 0, " +
  "tok_in INTEGER NOT NULL DEFAULT 0, tok_out INTEGER NOT NULL DEFAULT 0, tok_cached INTEGER NOT NULL DEFAULT 0, " +
  "cost_milli INTEGER NOT NULL DEFAULT 0, ms INTEGER NOT NULL DEFAULT 0, client TEXT, git INTEGER NOT NULL DEFAULT 0, " +
  "web INTEGER NOT NULL DEFAULT 0, ok INTEGER NOT NULL DEFAULT 1, err TEXT)",
  "CREATE INDEX IF NOT EXISTS bot_usage_at ON bot_usage (at)",
  "CREATE INDEX IF NOT EXISTS bot_usage_pubkey ON bot_usage (pubkey, at)"
];

let usageReady = false;

async function ensureUsage(db) {
  if (usageReady) return;
  for (const ddl of USAGE_DDL) { try { await db.prepare(ddl).run(); } catch (e) { /* tolerated */ } }
  usageReady = true;
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n) : 0;
}

// Which product and surface the request came from, from the same headers the
// origin gate reads. Never the address.
export function usageClient(request) {
  const ua = (request && request.headers && request.headers.get("User-Agent")) || "";
  if (/NymbotApp\//i.test(ua)) return "nymbot-app";
  if (/NymchatApp\//i.test(ua) || /\bNYMApp\b/.test(ua)) return "nymchat-app";
  const origin = (request && request.headers && request.headers.get("Origin")) || "";
  if (/nymbot\.ai/i.test(origin)) return "nymbot-web";
  if (/nymchat\.app/i.test(origin)) return "nymchat-web";
  return "other";
}

// Fire-and-forget. `row` fields mirror the table; tokens come in the worker's
// own usage shape ({fresh, read, wrote, out}).
export function noteUsage(context, row) {
  const env = context && context.env;
  const db = env && env.DB_BOT;
  if (!hasD1(db) || !row || typeof row.pubkey !== "string") return;
  const u = row.usage || {};
  const work = (async () => {
    try {
      await ensureUsage(db);
      await db.prepare(
        "INSERT INTO bot_usage (at, pubkey, kind, tier, task, model, calls, tok_in, tok_out, tok_cached, cost_milli, ms, client, git, web, ok, err) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
      ).bind(
        Date.now(), row.pubkey.toLowerCase(), String(row.kind || "chat").slice(0, 16), String(row.tier || "standard").slice(0, 16),
        row.task ? String(row.task).slice(0, 32) : null, row.model ? String(row.model).slice(0, 120) : null,
        num(row.calls), num(u.fresh) + num(u.wrote), num(u.out), num(u.read),
        num(row.costMilli), num(row.ms), usageClient(context.request), row.git ? 1 : 0, row.web ? 1 : 0,
        row.ok === false ? 0 : 1, row.err ? String(row.err).slice(0, 200) : null
      ).run();
    } catch (e) { /* a lost usage row is not a lost reply */ }
  })();
  try {
    if (typeof context.waitUntil === "function") context.waitUntil(work);
  } catch (e) { /* noop */ }
}

let denyCache = { at: 0, set: new Set() };

export async function denied(env, pubkey) {
  const db = env && env.DB_NOPE;
  if (!hasD1(db) || typeof pubkey !== "string") return false;
  const now = Date.now();
  if (now - denyCache.at > 60000) {
    try {
      const rs = await replica(db).prepare("SELECT value FROM nope WHERE kind = 'pubkey' AND (expires_at = 0 OR expires_at > ?)").bind(now).all();
      denyCache = { at: now, set: new Set(((rs && rs.results) || []).map((r) => String(r.value).toLowerCase())) };
    } catch (e) {
      denyCache = { at: now, set: denyCache.set };
    }
  }
  return denyCache.set.has(pubkey.toLowerCase());
}
