import { hasD1 } from "./_d1.js";
import { ledgerCall } from "./_ledger.js";
import { sha256, bytesToHex, utf8ToBytes, randomBytes } from "./_shared.js";

export const L402_REFUND_TTL_MS = 30 * 24 * 60 * 60 * 1000;
export const L402_REFUND_RE = /^REFUND-[0-9A-F]{64}$/;

const DDL = [
  "CREATE TABLE IF NOT EXISTS api_l402_refunds (hash TEXT PRIMARY KEY, sats INTEGER NOT NULL, created_at INTEGER NOT NULL, " +
  "expires_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, redeem_seq INTEGER NOT NULL DEFAULT 0, redeem_pending TEXT)",
  "CREATE INDEX IF NOT EXISTS api_l402_refunds_exp ON api_l402_refunds (expires_at)",
  "ALTER TABLE api_l402_refunds ADD COLUMN redeem_seq INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE api_l402_refunds ADD COLUMN redeem_pending TEXT"
];
const CLAIM_TRIES = 2;
const ready = new WeakSet();

export function l402RefundToken(raw) {
  const s = String(raw == null ? "" : raw).trim().toUpperCase();
  return L402_REFUND_RE.test(s) ? s : "";
}

export function l402RefundHash(token) {
  return bytesToHex(sha256(utf8ToBytes(l402RefundToken(token))));
}

export function l402RefundNew() {
  return "REFUND-" + bytesToHex(randomBytes(32)).toUpperCase();
}

export async function l402RefundDb(env) {
  const db = env && env.DB_CREDITS;
  if (!hasD1(db)) return null;
  if (!ready.has(db)) {
    for (const ddl of DDL) { try { await db.prepare(ddl).run(); } catch (e) { } }
    ready.add(db);
  }
  return db;
}

export async function l402RefundMint(env, sats, fixedToken) {
  const amount = Math.floor(Number(sats) || 0);
  if (amount <= 0) return null;
  const db = await l402RefundDb(env);
  if (!db) return null;
  const token = fixedToken ? l402RefundToken(fixedToken) : l402RefundNew();
  const now = Date.now();
  await db.prepare("INSERT OR IGNORE INTO api_l402_refunds (hash, sats, created_at, expires_at, updated_at) VALUES (?, ?, ?, ?, ?)")
    .bind(l402RefundHash(token), amount, now, now + L402_REFUND_TTL_MS, now).run();
  const row = await db.prepare("SELECT * FROM api_l402_refunds WHERE hash = ?").bind(l402RefundHash(token)).first();
  if (Math.random() < 0.02) {
    try { await db.prepare("DELETE FROM api_l402_refunds WHERE expires_at < ?").bind(now - 86400000).run(); } catch (e) { }
  }
  return { token, sats: row ? Number(row.sats) : amount, expiresAt: row ? Number(row.expires_at) : now + L402_REFUND_TTL_MS };
}

export async function l402RefundGet(env, token) {
  const t = l402RefundToken(token);
  if (!t) return null;
  const db = await l402RefundDb(env);
  if (!db) return null;
  return db.prepare("SELECT * FROM api_l402_refunds WHERE hash = ?").bind(l402RefundHash(t)).first();
}

export async function l402RefundSpend(env, token, sats) {
  const t = l402RefundToken(token);
  const amount = Math.floor(Number(sats) || 0);
  if (!t) return { unknown: true };
  const db = await l402RefundDb(env);
  if (!db) return { unavailable: true };
  const now = Date.now();
  const hash = l402RefundHash(t);
  const r = await db.prepare("UPDATE api_l402_refunds SET sats = sats - ?, updated_at = ? WHERE hash = ? AND sats >= ? AND expires_at > ?")
    .bind(amount, now, hash, amount, now).run();
  const row = await db.prepare("SELECT * FROM api_l402_refunds WHERE hash = ?").bind(hash).first();
  if (r && r.meta && r.meta.changes === 1) return { ok: true, left: row ? Number(row.sats) : 0, expiresAt: row ? Number(row.expires_at) : null };
  if (!row) return { unknown: true };
  if (Number(row.expires_at) <= now) return { expired: true };
  return { insufficient: true, have: Number(row.sats) || 0 };
}

export async function l402RefundCredit(env, token, sats) {
  const t = l402RefundToken(token);
  const amount = Math.floor(Number(sats) || 0);
  if (!t || amount <= 0) return null;
  const db = await l402RefundDb(env);
  if (!db) return null;
  const hash = l402RefundHash(t);
  await db.prepare("UPDATE api_l402_refunds SET sats = sats + ?, updated_at = ? WHERE hash = ?").bind(amount, Date.now(), hash).run();
  const row = await db.prepare("SELECT * FROM api_l402_refunds WHERE hash = ?").bind(hash).first();
  return row ? { token: t, sats: Number(row.sats), expiresAt: Number(row.expires_at) } : null;
}

export async function l402RefundPeek(env, token) {
  const row = await l402RefundGet(env, token);
  if (!row) return { error: "No refund has that token.", unknown: true };
  const now = Date.now();
  const sats = Number(row.sats) || 0;
  const state = Number(row.expires_at) <= now ? "expired" : (sats > 0 ? "open" : "redeemed");
  return { ok: true, sats, state, createdAt: Number(row.created_at), expiresAt: Number(row.expires_at), id: row.hash };
}

export function l402RefundClaimId(hash, seq) {
  return bytesToHex(sha256(utf8ToBytes("nymbot-l402-redeem:" + hash + ":" + seq)));
}

async function claimOnce(env, p) {
  const payload = {
    op: "claim-credits", invoiceId: l402RefundClaimId(p.hash, p.seq), creditTo: p.pubkey, credits: p.credits, tier: p.tier,
    claimData: { pubkey: p.pubkey, paidBy: p.pubkey, amountSats: p.sats, credits: p.credits, tier: p.tier, gift: false, refund: true }
  };
  for (let i = 0; i < CLAIM_TRIES; i++) {
    let r = null;
    try { r = await ledgerCall(env, payload); } catch (e) { r = null; }
    if (r && r._noLedger) return { failed: true };
    if (r && r.alreadyClaimed) return { ok: true, balance: null };
    if (r && !r.error && Number(r.credited) > 0) return { ok: true, balance: r.balance };
  }
  return { unsure: true };
}

function pendingOf(row) {
  if (!row || !row.redeem_pending) return null;
  try {
    const p = JSON.parse(row.redeem_pending);
    return p && Number.isSafeInteger(p.seq) && Number(p.credits) > 0 ? p : null;
  } catch (e) { return null; }
}

const busy = () => ({ error: "The refund could not be added to the balance right now. Try again: it will not be credited twice.", _noLedger: true });

export async function l402RefundRedeem(env, pubkey, token, tier, satsPer) {
  const t = l402RefundToken(token);
  if (!t) return { error: "That is not a refund token.", invalid: true };
  if (!/^[0-9a-f]{64}$/.test(String(pubkey || ""))) return { error: "Invalid pubkey." };
  const per = Math.max(1, Math.floor(Number(satsPer) || 0));
  const db = await l402RefundDb(env);
  if (!db) return { error: "Refunds are not available right now.", _noLedger: true };
  const hash = l402RefundHash(t);
  const load = () => db.prepare("SELECT * FROM api_l402_refunds WHERE hash = ?").bind(hash).first();
  let row = await load();
  if (!row) return { error: "No refund has that token.", unknown: true };
  let earlier = null;
  const open = pendingOf(row);
  if (open) {
    const r = await claimOnce(env, open);
    if (r.unsure) return busy();
    if (r.failed) {
      await db.prepare("UPDATE api_l402_refunds SET sats = sats + ?, redeem_pending = NULL, updated_at = ? WHERE hash = ? AND redeem_seq = ? AND redeem_pending IS NOT NULL")
        .bind(Number(open.sats) || 0, Date.now(), hash, open.seq).run();
      return { error: "Refunds are not available right now.", _noLedger: true };
    }
    await db.prepare("UPDATE api_l402_refunds SET redeem_pending = NULL, updated_at = ? WHERE hash = ? AND redeem_seq = ?").bind(Date.now(), hash, open.seq).run();
    if (open.pubkey === pubkey && open.tier === tier) earlier = { credits: open.credits, tier: open.tier, balance: r.balance };
    row = await load();
    if (!row) return { error: "No refund has that token.", unknown: true };
  }
  const done = (credited, balance) => ({ ok: true, credited, tier: earlier ? earlier.tier : tier, balance, remainingSats: Number(row.sats) || 0 });
  const now = Date.now();
  if (Number(row.expires_at) <= now) return earlier ? done(earlier.credits, earlier.balance) : { error: "This refund token expired.", expired: true };
  const credits = Math.floor((Number(row.sats) || 0) / per);
  if (credits <= 0) {
    if (earlier) return done(earlier.credits, earlier.balance);
    return { error: "This refund token holds " + (Number(row.sats) || 0) + " sats, less than one " + (tier === "pro" ? "Pro " : "") + "credit (" + per + " sats). Spend it on an API request instead.", tooSmall: true, sats: Number(row.sats) || 0 };
  }
  const seq = (Number(row.redeem_seq) || 0) + 1;
  const p = { seq, hash, pubkey, credits, tier, sats: credits * per };
  const took = await db.prepare("UPDATE api_l402_refunds SET sats = sats - ?, redeem_seq = ?, redeem_pending = ?, updated_at = ? " +
    "WHERE hash = ? AND sats >= ? AND expires_at > ? AND redeem_seq = ? AND redeem_pending IS NULL")
    .bind(p.sats, seq, JSON.stringify(p), now, hash, p.sats, now, seq - 1).run();
  if (!took || !took.meta || took.meta.changes !== 1) {
    if (earlier) return done(earlier.credits, earlier.balance);
    return { error: "This refund token changed while redeeming. Try again.", conflict: true };
  }
  const r = await claimOnce(env, p);
  if (r.unsure) return busy();
  if (r.failed) {
    await db.prepare("UPDATE api_l402_refunds SET sats = sats + ?, redeem_pending = NULL, updated_at = ? WHERE hash = ? AND redeem_seq = ? AND redeem_pending IS NOT NULL")
      .bind(p.sats, Date.now(), hash, seq).run();
    return { error: "Refunds are not available right now.", _noLedger: true };
  }
  await db.prepare("UPDATE api_l402_refunds SET redeem_pending = NULL, updated_at = ? WHERE hash = ? AND redeem_seq = ?").bind(Date.now(), hash, seq).run();
  row = (await load()) || row;
  return { ok: true, credited: credits + (earlier ? earlier.credits : 0), tier, balance: r.balance, remainingSats: Number(row.sats) || 0 };
}
