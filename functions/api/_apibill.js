import { ledgerCall } from "./_ledger.js";
import { creditsGet, hasD1 } from "./_d1.js";
import { noteUsage } from "./_usage.js";
import { bytesToHex, randomBytes } from "./_shared.js";
import {
  botBtcPrice, botCreditFigure, botFailedSpendMilli, BOT_HOLD_TTL_S, BOT_SATS_PER_CREDIT, BOT_PRO_SATS_PER_CREDIT
} from "./bot.js";
import { ApiError, apiBad, apiIso, apiJson, apiRound, apiParseTime } from "./_apihttp.js";
import { apiKeyLimitError } from "./_apiauth.js";
import { apiL402Open, apiL402Settle, apiL402Cost, apiL402Usage } from "./_apil402.js";

export const API_HISTORY_DAYS = 90;
export const API_BILL_TIMING = { refreshMs: 300000, refreshMaxMs: 7200000 };
export const API_HISTORY_TYPES = ["chat", "responses", "messages", "image", "video", "speech", "transcription", "embedding"];

export function apiSatsPer(tier) {
  return tier === "pro" ? BOT_PRO_SATS_PER_CREDIT : BOT_SATS_PER_CREDIT;
}

export function apiMilliSats(milli, tier) {
  return apiRound((Number(milli) || 0) * apiSatsPer(tier) / 1000);
}

export function apiUsd(sats, btcUsd) {
  const b = Number(btcUsd);
  if (!(b > 0)) return null;
  return Math.round((Number(sats) || 0) / 1e8 * b * 1e10) / 1e10;
}

async function btcOrNull() {
  try { return await botBtcPrice(); } catch (e) { return null; }
}

function ledgerDown() {
  return new ApiError(503, "api_error", "Billing is temporarily unavailable. Try again shortly.", { code: "service_unavailable", headers: { "Retry-After": "30" } });
}

const DEBT_DDL = "CREATE TABLE IF NOT EXISTS api_debt (pubkey TEXT NOT NULL, tier TEXT NOT NULL, " +
  "milli INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (pubkey, tier))";
const debtReady = new WeakSet();

async function debtDb(env) {
  const db = env && env.DB_CREDITS;
  if (!hasD1(db)) return null;
  if (!debtReady.has(db)) {
    try { await db.prepare(DEBT_DDL).run(); } catch (e) { return null; }
    debtReady.add(db);
  }
  return db;
}

export async function apiDebtOf(env, pubkey, tier) {
  const db = await debtDb(env);
  if (!db) return 0;
  try {
    const row = await db.prepare("SELECT milli FROM api_debt WHERE pubkey = ? AND tier = ?").bind(pubkey, tier === "pro" ? "pro" : "standard").first();
    return row ? Math.max(0, Number(row.milli) || 0) : 0;
  } catch (e) { return 0; }
}

async function debtAdd(env, pubkey, tier, milli) {
  const m = Math.ceil(Number(milli) || 0);
  if (m <= 0) return true;
  const db = await debtDb(env);
  if (!db) return false;
  try {
    await db.prepare("INSERT INTO api_debt (pubkey, tier, milli, updated_at) VALUES (?, ?, ?, ?) " +
      "ON CONFLICT(pubkey, tier) DO UPDATE SET milli = milli + excluded.milli, updated_at = excluded.updated_at")
      .bind(pubkey, tier, m, Date.now()).run();
    return true;
  } catch (e) { return false; }
}

async function debtTake(env, pubkey, tier) {
  const db = await debtDb(env);
  if (!db) return 0;
  try {
    const row = await db.prepare("DELETE FROM api_debt WHERE pubkey = ? AND tier = ? RETURNING milli").bind(pubkey, tier).first();
    return row ? Math.max(0, Number(row.milli) || 0) : 0;
  } catch (e) { return 0; }
}

async function consumeOp(env, pubkey, tier, milli, hold) {
  const op = { op: "consume-credits", pubkey, cost: 0, tier, milli };
  if (hold) op.hold = hold;
  try { return await ledgerCall(env, op); } catch (e) { return { _noLedger: true }; }
}

async function chargeUpTo(env, pubkey, tier, milli, hold, floorMilli) {
  let took = await consumeOp(env, pubkey, tier, milli, hold);
  if (took && took.ok) return { charged: milli, took };
  if (!took || took._noLedger || took.error) return { charged: 0, took: null };
  const whole = Math.floor(Math.max(0, Number(took.balance) || 0)) * 1000;
  const tries = [...new Set([whole, whole - 1000, whole >= milli ? milli - 1000 : 0, Number(floorMilli) || 0])]
    .filter((m) => m > 0 && m < milli).sort((x, y) => y - x);
  for (const m of tries) {
    took = await consumeOp(env, pubkey, tier, m, null);
    if (took && took.ok) return { charged: m, took };
    if (!took || took._noLedger || took.error) break;
  }
  return { charged: 0, took: null };
}

function insufficient(tier, needCredits, freeCredits, heldByOthers, owedMilli) {
  const satsPer = apiSatsPer(tier);
  const label = tier === "pro" ? "Pro" : "standard";
  const needSats = apiRound(needCredits * satsPer);
  const haveSats = apiRound(Math.max(0, freeCredits) * satsPer);
  const owedSats = apiMilliSats(owedMilli || 0, tier);
  const extra = { balance: tier, required_sats: needSats, balance_sats: haveSats };
  if (owedSats > 0) extra.owed_sats = owedSats;
  return new ApiError(402, "insufficient_quota",
    (owedSats > 0 ? "Earlier requests left " + owedSats + " sats unpaid on your " + label + " balance, and they are collected before the next request. " : "") +
    "This request needs up to " + needSats + " sats (" + needCredits + " credits) on your " + label + " balance, and " + haveSats +
    " sats are free" + (heldByOthers ? " while other requests hold part of it" : "") + ". " +
    (tier === "pro" ? "Catalog models spend the Pro balance." : "nymbot/auto spends the standard balance.") +
    " Top up in the Nymbot app or with POST /api/v1/topup/create/btc-lightning.",
    { code: "insufficient_balance", extra });
}

export async function apiBillPrecheck(api, tierIn) {
  const auth = api.auth;
  if (!auth || !auth.pubkey || auth.via === "l402") return;
  const env = api.env;
  if (!hasD1(env && env.DB_CREDITS)) return;
  const tier = tierIn === "pro" ? "pro" : "standard";
  let balance = 0;
  try { balance = Number((await creditsGet(env.DB_CREDITS, tier === "pro" ? auth.pubkey + "#pro" : auth.pubkey)).balance) || 0; } catch (e) { return; }
  const owed = await apiDebtOf(env, auth.pubkey, tier);
  if (balance - owed / 1000 >= 1) return;
  throw insufficient(tier, 1, balance - owed / 1000, false, owed);
}

export async function apiBalances(env, pubkey) {
  const std = await creditsGet(env.DB_CREDITS, pubkey);
  const pro = await creditsGet(env.DB_CREDITS, pubkey + "#pro");
  const dust = await ledgerCall(env, { op: "dust-peek", pubkey });
  const owed = dust && dust.ok ? dust : { standard: 0, pro: 0 };
  const debt = { standard: await apiDebtOf(env, pubkey, "standard"), pro: await apiDebtOf(env, pubkey, "pro") };
  const credits = {
    standard: botCreditFigure(std.balance || 0, -((owed.standard || 0) + debt.standard)),
    pro: botCreditFigure(pro.balance || 0, -((owed.pro || 0) + debt.pro))
  };
  return {
    standard: { credits: credits.standard, sats: apiRound(credits.standard * BOT_SATS_PER_CREDIT) },
    pro: { credits: credits.pro, sats: apiRound(credits.pro * BOT_PRO_SATS_PER_CREDIT) }
  };
}

export async function apiBillOpen(api, o) {
  if (api.auth && api.auth.via === "l402") return apiL402Open(api, o);
  const tier = o.tier === "pro" ? "pro" : "standard";
  const satsPer = apiSatsPer(tier);
  const holdCredits = Math.max(1, Math.ceil((Number(o.reserveMilli) || 0) / 1000));
  const auth = api.auth;
  const bill = {
    id: bytesToHex(randomBytes(16)), tier, satsPer, holdCredits, pubkey: auth.pubkey,
    keyId: auth.keyId || null, keyLimited: !!(auth.key && auth.key.limit_sats != null), keyOpen: false, done: false,
    keyPeriod: (auth.key && auth.key.reset_period) || null, timer: null, refreshing: null
  };
  if (bill.keyId) {
    const need = holdCredits * satsPer;
    const kr = await ledgerCall(api.env, {
      op: "key-reserve", keyId: bill.keyId, id: bill.id, sats: need, limit: auth.key.limit_sats,
      period: auth.key.reset_period || null, now: Date.now(), ttl: BOT_HOLD_TTL_S
    });
    if (kr && kr._noLedger) throw ledgerDown();
    if (kr && kr.capped) {
      const left = apiRound(Math.max(0, kr.limit - kr.used - (kr.reserved || 0)));
      throw apiKeyLimitError(kr, auth.key, kr.reached ? null
        : "This request could cost up to " + need + " sats, but this API key has " + left + " of its " + kr.limit +
          " sat limit left" + (kr.reserved ? " (requests in flight hold " + apiRound(kr.reserved) + ")" : "") +
          ". Lower max_tokens, or raise the key's limit in the app.");
    }
    if (!kr || !kr.ok) throw ledgerDown();
    bill.keyOpen = true;
  }
  const unpaid = await apiDebtCollect(api.env, bill.pubkey, tier);
  if (unpaid > 0) {
    await apiKeyClose(api, bill, 0);
    throw insufficient(tier, holdCredits, 0, false, unpaid);
  }
  const held = await holdOp(api.env, bill);
  if (held && held.ok) {
    if (o.refresh) startRefresh(api, bill);
    return bill;
  }
  await apiKeyClose(api, bill, 0);
  if (held && held._noLedger) throw ledgerDown();
  if (held && held.rateLimited) throw new ApiError(429, "rate_limit_error", "Too many requests.", { code: "rate_limit_exceeded", headers: { "Retry-After": "10" } });
  const free = held ? Math.max(0, (Number(held.balance) || 0) - (Number(held.held) || 0)) : 0;
  throw insufficient(tier, holdCredits, free, !!(held && held.held), 0);
}

function holdOp(env, bill) {
  return ledgerCall(env, {
    op: "credit-hold", id: bill.id, pubkey: bill.pubkey, tier: bill.tier, amount: bill.holdCredits, ttl: BOT_HOLD_TTL_S, stamp: false
  });
}

export async function apiDebtCollect(env, pubkey, tier) {
  const owed = await debtTake(env, pubkey, tier);
  if (owed <= 0) return 0;
  const got = await chargeUpTo(env, pubkey, tier, owed, null, 0);
  const left = owed - got.charged;
  if (left > 0) await debtAdd(env, pubkey, tier, left);
  return left;
}

function startRefresh(api, bill) {
  const every = Number(API_BILL_TIMING.refreshMs);
  if (!(every > 0) || typeof setInterval !== "function") return;
  const until = Date.now() + (Number(API_BILL_TIMING.refreshMaxMs) || 0);
  bill.timer = setInterval(() => {
    if (bill.done || Date.now() > until) {
      clearInterval(bill.timer);
      bill.timer = null;
      return;
    }
    if (bill.refreshing) return;
    bill.refreshing = refreshHold(api, bill).catch(() => { }).then(() => { bill.refreshing = null; });
  }, every);
  if (bill.timer && typeof bill.timer.unref === "function") bill.timer.unref();
}

async function refreshHold(api, bill) {
  const env = api.env;
  if (bill.keyOpen && !bill.done) {
    await ledgerCall(env, {
      op: "key-reserve", keyId: bill.keyId, id: bill.id, sats: bill.holdCredits * bill.satsPer, limit: null,
      period: bill.keyPeriod, now: Date.now(), ttl: BOT_HOLD_TTL_S
    });
  }
  if (bill.done) return;
  await ledgerCall(env, { op: "credit-release", id: bill.id });
  if (bill.done) return;
  const held = await holdOp(env, bill);
  bill.holdLost = !(held && held.ok);
}

async function stopRefresh(bill) {
  if (bill.timer) {
    clearInterval(bill.timer);
    bill.timer = null;
  }
  if (bill.refreshing) await bill.refreshing;
}

async function apiKeyClose(api, bill, sats) {
  if (!bill.keyOpen) return;
  bill.keyOpen = false;
  try {
    await ledgerCall(api.env, { op: "key-settle", keyId: bill.keyId, id: bill.id, sats: Math.max(0, Number(sats) || 0), now: Date.now() });
  } catch (e) { }
}

export async function apiBillRelease(api, bill) {
  if (bill.l402) return apiL402Settle(api, bill, 0);
  if (bill.done) return { chargedMilli: 0, balance: null, dust: null };
  bill.done = true;
  await stopRefresh(bill);
  try { await ledgerCall(api.env, { op: "credit-release", id: bill.id }); } catch (e) { }
  await apiKeyClose(api, bill, 0);
  return { chargedMilli: 0, balance: null, dust: null };
}

export async function apiBillSettle(api, bill, milliIn, opts) {
  if (bill.l402) return apiL402Settle(api, bill, milliIn, opts);
  if (bill.done) return { chargedMilli: 0, balance: null, dust: null };
  const milli = Math.max(0, Math.ceil(Number(milliIn) || 0));
  if (milli <= 0) return apiBillRelease(api, bill);
  bill.done = true;
  await stopRefresh(bill);
  const env = api.env;
  const got = await chargeUpTo(env, bill.pubkey, bill.tier, milli, bill.id, bill.holdCredits * 1000);
  let owed = milli - got.charged;
  if (owed > 0 && !(await debtAdd(env, bill.pubkey, bill.tier, owed))) owed = 0;
  const billed = got.charged + owed;
  await apiKeyClose(api, bill, billed * bill.satsPer / 1000);
  const took = got.took;
  const settled = {
    chargedMilli: billed, owedMilli: owed,
    balance: took && owed <= 0 ? took.balance : null, dust: took && owed <= 0 ? (took.dust || 0) : null
  };
  if (billed > 0) apiRunSettleHooks(api, bill, settled);
  return settled;
}

export const apiSettleHooks = [];

export function apiAddSettleHook(fn) {
  apiSettleHooks.push(fn);
}

function apiRunSettleHooks(api, bill, settled) {
  for (const fn of apiSettleHooks) {
    try { api.waitUntil(Promise.resolve().then(() => fn(api, bill, settled))); } catch (e) { }
  }
}

export async function apiBillFail(api, bill, err, o) {
  let milli = 0;
  try { milli = await botFailedSpendMilli(api.env, err, (o && o.proModel) || null, (o && o.stdRates) || null); } catch (e) { milli = 0; }
  milli += Math.max(0, Math.ceil(Number(o && o.extraMilli) || 0));
  if (milli > 0) return apiBillSettle(api, bill, milli);
  return apiBillRelease(api, bill);
}

export async function apiCostObject(api, bill, settled, btcUsd) {
  if (bill.l402) return apiL402Cost(api, bill, settled, (sats) => apiUsd(sats, btcUsd));
  const milli = settled.chargedMilli || 0;
  let balanceCredits;
  if (settled.balance != null) balanceCredits = botCreditFigure(settled.balance, -(settled.dust || 0));
  else balanceCredits = (await apiBalances(api.env, bill.pubkey))[bill.tier].credits;
  const chargedSats = apiMilliSats(milli, bill.tier);
  const out = {
    balance: bill.tier,
    charged_credits: apiRound(milli / 1000),
    charged_sats: chargedSats,
    charged_usd: apiUsd(chargedSats, btcUsd),
    balance_credits: balanceCredits,
    balance_sats: apiRound(balanceCredits * bill.satsPer)
  };
  if (settled.owedMilli > 0) out.owed_sats = apiMilliSats(settled.owedMilli, bill.tier);
  return out;
}

export function apiCostHeaders(cost) {
  if (cost.payment) return { "X-Nymbot-Cost-Sats": String(cost.charged_sats) };
  return { "X-Nymbot-Cost-Sats": String(cost.charged_sats), "X-Nymbot-Balance-Sats": String(cost.balance_sats) };
}

const HISTORY_DDL = [
  "CREATE TABLE IF NOT EXISTS api_queries (id TEXT PRIMARY KEY, at INTEGER NOT NULL, pubkey TEXT NOT NULL, key_id TEXT, " +
  "model TEXT, type TEXT NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0, " +
  "cached_tokens INTEGER NOT NULL DEFAULT 0, cost_msat INTEGER NOT NULL DEFAULT 0, cost_usd REAL, balance TEXT, " +
  "web_search INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL)",
  "CREATE INDEX IF NOT EXISTS api_queries_pubkey ON api_queries (pubkey, at)",
  "CREATE INDEX IF NOT EXISTS api_queries_key ON api_queries (key_id, at)",
  "CREATE INDEX IF NOT EXISTS api_queries_at ON api_queries (at)"
];
const historyReady = new WeakSet();

async function historyDb(env) {
  const db = env && env.DB_BOT;
  if (!hasD1(db)) return null;
  if (!historyReady.has(db)) {
    for (const ddl of HISTORY_DDL) { try { await db.prepare(ddl).run(); } catch (e) { } }
    historyReady.add(db);
  }
  return db;
}

const num = (v) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? Math.round(n) : 0; };

const USAGE_KIND = { chat: "chat", responses: "chat", messages: "chat", transcription: "transcribe", embedding: "embedding" };

export async function apiRecordQuery(api, row) {
  const env = api.env;
  const auth = api.auth || {};
  const tier = row.tier === "pro" ? "pro" : "standard";
  const u = row.usage || {};
  const at = Number(row.at) > 0 ? Math.floor(row.at) : Date.now();
  const milli = num(row.milli);
  const sats = milli * apiSatsPer(tier) / 1000;
  if (auth.via === "l402") {
    apiL402Usage(api, {
      kind: USAGE_KIND[row.type] || "media", tier, task: row.task || row.type, model: row.model, calls: row.calls == null ? 1 : row.calls,
      usage: u, costMilli: milli, ms: row.ms || 0, web: !!row.web, ok: row.status !== "error", err: row.err || null
    });
    return;
  }
  const btc = row.btcUsd > 0 ? row.btcUsd : await btcOrNull();
  try {
    noteUsage(api.context || { env }, {
      pubkey: auth.pubkey, kind: USAGE_KIND[row.type] || "media", tier, task: row.task || row.type, model: row.model,
      calls: row.calls == null ? 1 : row.calls, usage: u, costMilli: milli, ms: row.ms || 0, client: "api",
      web: !!row.web, ok: row.status !== "error", err: row.err || null
    });
  } catch (e) { }
  const db = await historyDb(env);
  if (!db || !auth.pubkey) return;
  try {
    await db.prepare("INSERT INTO api_queries (id, at, pubkey, key_id, model, type, input_tokens, output_tokens, cached_tokens, cost_msat, cost_usd, balance, web_search, status) " +
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").bind(
      "q_" + bytesToHex(randomBytes(12)), at, auth.pubkey, auth.keyId || null, row.model ? String(row.model).slice(0, 160) : null,
      API_HISTORY_TYPES.includes(row.type) ? row.type : "chat",
      num(u.fresh) + num(u.read) + num(u.wrote), num(u.out), num(u.read), Math.round(milli * apiSatsPer(tier)),
      btc ? apiUsd(sats, btc) : null, tier, row.web ? 1 : 0, row.status === "error" ? "error" : "ok"
    ).run();
    if (Math.random() < 0.02) {
      await db.prepare("DELETE FROM api_queries WHERE at < ?").bind(Date.now() - API_HISTORY_DAYS * 86400000).run();
    }
  } catch (e) { }
}

async function keyUsage(env, key) {
  const r = await ledgerCall(env, { op: "key-usage", keys: [{ id: key.id, period: key.reset_period || null }], now: Date.now() });
  return r && r.usage && r.usage[key.id] ? r.usage[key.id] : null;
}

async function balanceHandler(api) {
  const b = await apiBalances(api.env, api.auth.pubkey);
  const btc = await btcOrNull();
  const totalSats = apiRound(b.standard.sats + b.pro.sats);
  const out = { balance: apiUsd(totalSats, btc), balance_sats: totalSats, standard: b.standard, pro: b.pro };
  const key = api.auth.key;
  if (key) {
    const u = await keyUsage(api.env, key);
    out.key = {
      id: key.id, name: key.name, limit_sats: key.limit_sats == null ? null : key.limit_sats,
      period_used_sats: u ? u.periodUsedSats : 0, total_used_sats: u ? u.totalSats : 0,
      reset_period: key.reset_period || null, reset_at: u && key.reset_period ? apiIso(u.resetAt) : null
    };
  }
  return apiJson(out);
}

function flag(v) {
  return v === true || v === "true" || v === "1";
}

async function historyHandler(api) {
  const q = api.url.searchParams;
  const page = Math.max(1, Math.floor(Number(q.get("page")) || 1));
  const pageCount = Math.min(100, Math.max(1, Math.floor(Number(q.get("page_count")) || 20)));
  const start = apiParseTime(q.get("start_date"), "start_date");
  const end = apiParseTime(q.get("end_date"), "end_date");
  const type = q.get("type");
  if (type && !API_HISTORY_TYPES.includes(type)) throw apiBad("`type` must be one of " + API_HISTORY_TYPES.join(", ") + ".", "type");
  const where = ["pubkey = ?", "at >= ?"];
  const bind = [api.auth.pubkey, Date.now() - API_HISTORY_DAYS * 86400000];
  if (api.auth.via === "key" && !flag(q.get("all_keys"))) { where.push("key_id = ?"); bind.push(api.auth.keyId); }
  else if (q.get("key_id")) { where.push("key_id = ?"); bind.push(String(q.get("key_id"))); }
  if (q.get("model")) { where.push("model = ?"); bind.push(String(q.get("model"))); }
  if (type) { where.push("type = ?"); bind.push(type); }
  if (start != null) { where.push("at >= ?"); bind.push(start); }
  if (end != null) { where.push("at <= ?"); bind.push(end); }
  const db = await historyDb(api.env);
  let total = 0;
  let rows = [];
  if (db) {
    const cond = where.join(" AND ");
    const c = await db.prepare("SELECT COUNT(*) AS n FROM api_queries WHERE " + cond).bind(...bind).first();
    total = c ? Number(c.n) || 0 : 0;
    const rs = await db.prepare("SELECT * FROM api_queries WHERE " + cond + " ORDER BY at DESC, rowid DESC LIMIT ? OFFSET ?")
      .bind(...bind, pageCount, (page - 1) * pageCount).all();
    rows = (rs && rs.results) || [];
  }
  return apiJson({
    data: rows.map((r) => ({
      id: r.id, timestamp: apiIso(r.at), model: r.model, type: r.type,
      input_tokens: r.input_tokens, output_tokens: r.output_tokens, cached_tokens: r.cached_tokens,
      cost_sats: apiRound((Number(r.cost_msat) || 0) / 1000), cost_usd: r.cost_usd == null ? null : r.cost_usd,
      balance: r.balance, key_id: r.key_id, web_search: !!r.web_search, status: r.status
    })),
    pagination: { page, page_count: pageCount, total, total_pages: Math.ceil(total / pageCount) }
  });
}

export function registerAccount(r) {
  r.add("GET", "/credits/balance", balanceHandler, { auth: "key", spends: false });
  r.add("POST", "/credits/balance", balanceHandler, { auth: "key", spends: false });
  r.add("GET", "/queries/history", historyHandler, { auth: "key-or-nostr", spends: false });
}
