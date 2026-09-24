import { hasD1, replica } from "./_d1.js";

const CACHE_MS = 60 * 1000;
const LIMIT = 10;
const LEVELS = ["info", "success", "warning"];
const KINDS = ["announcement", "model"];

let cache = { at: 0, rows: null };

function text(v, max) {
  return typeof v === "string" ? v.trim().slice(0, max) : "";
}

function safeUrl(v) {
  const s = text(v, 2000);
  return /^https?:\/\/[^\s]+$/i.test(s) ? s : null;
}

export function noticePlatform(v) {
  return v === "app" ? "app" : "web";
}

export function shapeNotice(r) {
  const title = text(r.title, 120);
  const body = text(r.body, 500);
  if (!title && !body) return null;
  return {
    id: Number(r.id),
    kind: KINDS.includes(r.kind) ? r.kind : "announcement",
    level: LEVELS.includes(r.level) ? r.level : "info",
    title,
    body,
    url: safeUrl(r.link_url),
    linkLabel: text(r.link_label, 40) || null,
    model: text(r.model, 120) || null,
    audience: r.audience === "web" || r.audience === "app" ? r.audience : "all",
    at: Number(r.created_at) || 0,
    startsAt: Number(r.starts_at) || 0,
    endsAt: Number(r.ends_at) || 0
  };
}

async function loadNotices(env, now) {
  if (cache.rows && now - cache.at < CACHE_MS) return cache.rows;
  const db = env && env.DB_BOT;
  if (!hasD1(db)) return [];
  const rs = await replica(db).prepare(
    "SELECT id, kind, level, title, body, link_url, link_label, model, audience, starts_at, ends_at, created_at " +
    "FROM bot_notices WHERE active = 1 AND (ends_at = 0 OR ends_at > ?) ORDER BY created_at DESC, id DESC LIMIT 50"
  ).bind(now).all();
  const rows = ((rs && rs.results) || []).map(shapeNotice).filter(Boolean);
  cache = { at: now, rows };
  return rows;
}

export async function liveNotices(env, platform, now) {
  const at = Number(now) || Date.now();
  const where = noticePlatform(platform);
  let rows;
  try { rows = await loadNotices(env, at); } catch (e) { return []; }
  return rows
    .filter((n) => n.startsAt <= at && (!n.endsAt || n.endsAt > at))
    .filter((n) => n.audience === "all" || n.audience === where)
    .slice(0, LIMIT)
    .map(({ audience, startsAt, ...rest }) => rest);
}

export function _resetNoticeCache() {
  cache = { at: 0, rows: null };
}
