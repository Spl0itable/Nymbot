import { ledgerCall } from "./_ledger.js";
import { hasD1, invoiceGet } from "./_d1.js";
import {
  sha256, bytesToHex, utf8ToBytes, randomBytes, botBase64Encode, botBase64Decode, parseNwcUri,
  nwcGetInfo, nwcPayInvoice, bolt11ExpiresAt, invoicePaymentConfirmed
} from "./_shared.js";
import {
  botBtcPrice, botCreditInvoice, botCreditsForSatsTier, botCreditFigure, isPrivateHostUrl, BOT_BULK_BONUS, BOT_SATS_PER_CREDIT, BOT_PRO_SATS_PER_CREDIT
} from "./bot.js";
import { ApiError, apiBad, apiIso, apiJson, apiRateLimit, apiClientIp } from "./_apihttp.js";
import { apiBalances, apiSatsPer, apiAddSettleHook } from "./_apibill.js";
import { apiAddAccountField } from "./_apikeys.js";

export const API_TOPUP_METHOD = "btc-lightning";
export const API_TOPUP_MAX_SATS = 1000000;
export const API_TOPUP_CURRENCIES = ["SATS", "USD", "BTC"];
export const API_TOPUP_TIERS = ["standard", "pro"];
export const API_NWC_MIN_SATS = 1000;
export const API_NWC_MAX_TOPUP_SATS = 1000000;
export const API_NWC_TIMING = { infoMs: 8000, payMs: 20000, infoWaitMs: 1500, lockTtlS: 300 };

const OWN_HOST_RE = /(^|\.)(nymbot\.ai|nymbot\.pages\.dev)$/;
const TIER_MIN_SATS = { standard: BOT_SATS_PER_CREDIT, pro: BOT_PRO_SATS_PER_CREDIT };
const INVOICE_ID_RE = /^[0-9a-f]{64}$/;

const NWC_DDL = [
  "CREATE TABLE IF NOT EXISTS api_nwc (pubkey TEXT PRIMARY KEY, uri_enc TEXT NOT NULL, threshold_sats INTEGER NOT NULL, " +
  "topup_sats INTEGER NOT NULL, tier TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, " +
  "last_topup_at INTEGER, last_topup_sats INTEGER, last_error TEXT, last_attempt_at INTEGER)"
];
const nwcReady = new WeakSet();

async function nwcDb(env) {
  const db = env && env.DB_CREDITS;
  if (!hasD1(db)) return null;
  if (!nwcReady.has(db)) {
    for (const ddl of NWC_DDL) { try { await db.prepare(ddl).run(); } catch (e) { } }
    nwcReady.add(db);
  }
  return db;
}

async function nwcDbOrFail(env) {
  const db = await nwcDb(env);
  if (!db) throw new ApiError(503, "api_error", "Auto top-up is not available right now.", { code: "service_unavailable" });
  return db;
}

function nwcSecret(env) {
  const s = env && env.API_NWC_SECRET;
  return typeof s === "string" && s.length ? s : null;
}

function nwcGuard(api) {
  if (!nwcSecret(api.env)) {
    throw new ApiError(501, "api_error", "NWC auto top-up is not enabled on this server.", { code: "nwc_unavailable" });
  }
}

async function sealKey(secret) {
  const base = await crypto.subtle.importKey("raw", utf8ToBytes(secret), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: utf8ToBytes("nymbot-api-nwc"), info: utf8ToBytes("nwc-uri-v1") },
    base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]
  );
}

export async function apiNwcSeal(secret, pubkey, uri) {
  const iv = randomBytes(12);
  const key = await sealKey(secret);
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: utf8ToBytes(pubkey) }, key, utf8ToBytes(uri));
  return "v1." + botBase64Encode(iv) + "." + botBase64Encode(new Uint8Array(ct));
}

export async function apiNwcOpen(secret, pubkey, sealed) {
  const parts = String(sealed || "").split(".");
  if (parts.length !== 3 || parts[0] !== "v1") throw new Error("sealed");
  const key = await sealKey(secret);
  const pt = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: botBase64Decode(parts[1]), additionalData: utf8ToBytes(pubkey) }, key, botBase64Decode(parts[2])
  );
  return new TextDecoder().decode(pt);
}

export function apiNwcLockId(pubkey, tier) {
  return bytesToHex(sha256(utf8ToBytes("api-nwc-topup/" + pubkey + "/" + tier)));
}

function nwcObject(row) {
  if (!row) {
    return { connected: false, threshold_sats: null, topup_sats: null, tier: null, last_topup_at: null, last_topup_sats: null, last_error: null };
  }
  return {
    connected: true,
    threshold_sats: Number(row.threshold_sats),
    topup_sats: Number(row.topup_sats),
    tier: row.tier === "standard" ? "standard" : "pro",
    last_topup_at: apiIso(row.last_topup_at),
    last_topup_sats: row.last_topup_sats == null ? null : Number(row.last_topup_sats),
    last_error: row.last_error || null
  };
}

export function apiNwcRelayProblem(uri) {
  const cfg = parseNwcUri(uri);
  if (!cfg) return "The wallet connection string is not valid.";
  let u;
  try { u = new URL(cfg.relay); } catch (e) { return "The wallet relay is not a valid URL."; }
  if (u.protocol !== "wss:") return "The wallet relay must use wss://.";
  if (u.username || u.password) return "The wallet relay URL must not carry credentials.";
  const host = u.hostname.toLowerCase().replace(/\.+$/, "");
  if (!host || isPrivateHostUrl(cfg.relay) || OWN_HOST_RE.test(host)) return "The wallet relay points at a private, local or reserved address.";
  return null;
}

async function nwcRow(db, pubkey) {
  return db.prepare("SELECT * FROM api_nwc WHERE pubkey = ? LIMIT 1").bind(pubkey).first();
}

function wholeSats(v, param, min, max) {
  if (typeof v !== "number" || !Number.isInteger(v) || v < min || v > max) {
    throw apiBad("`" + param + "` must be a whole number of sats from " + min + " to " + max + ".", param);
  }
  return v;
}

function tierOf(v, param) {
  if (v == null) return "pro";
  if (!API_TOPUP_TIERS.includes(v)) throw apiBad("`" + param + "` must be standard or pro.", param);
  return v;
}

async function nwcGet(api) {
  nwcGuard(api);
  const db = await nwcDbOrFail(api.env);
  return apiJson({ data: nwcObject(await nwcRow(db, api.auth.pubkey)) });
}

async function nwcConnect(api) {
  nwcGuard(api);
  const b = api.body || {};
  const uri = typeof b.nwc_url === "string" ? b.nwc_url.trim() : "";
  if (!uri) throw apiBad("`nwc_url` is required: a nostr+walletconnect:// connection string.", "nwc_url");
  if (!parseNwcUri(uri)) throw apiBad("`nwc_url` is not a valid nostr+walletconnect:// connection string (it needs the wallet pubkey, a relay and a secret).", "nwc_url", "invalid_nwc_url");
  const relayProblem = apiNwcRelayProblem(uri);
  if (relayProblem) throw apiBad("`nwc_url` cannot be used: " + relayProblem, "nwc_url", "invalid_nwc_relay");
  const threshold = wholeSats(b.threshold_sats, "threshold_sats", API_NWC_MIN_SATS, 1e12);
  const topup = wholeSats(b.topup_sats, "topup_sats", API_NWC_MIN_SATS, API_NWC_MAX_TOPUP_SATS);
  const tier = tierOf(b.tier, "tier");
  const db = await nwcDbOrFail(api.env);
  const info = await nwcGetInfo(uri, { timeoutMs: API_NWC_TIMING.infoMs, infoWaitMs: API_NWC_TIMING.infoWaitMs });
  if (!info.ok) {
    const answered = info.error !== "The wallet did not answer.";
    throw apiBad(answered
      ? "The wallet refused the connection check (" + info.error + ")."
      : "The wallet did not answer a get_info request over its relay. Check the connection string and that the wallet is online.",
      "nwc_url", answered ? "nwc_rejected" : "nwc_unreachable");
  }
  if (info.methods && !info.methods.includes("pay_invoice")) {
    throw apiBad("This wallet connection cannot pay invoices. Create one with the pay_invoice permission.", "nwc_url", "nwc_missing_permission");
  }
  const pubkey = api.auth.pubkey;
  const sealed = await apiNwcSeal(nwcSecret(api.env), pubkey, uri);
  const now = Date.now();
  await db.prepare("INSERT OR REPLACE INTO api_nwc (pubkey, uri_enc, threshold_sats, topup_sats, tier, created_at, updated_at, last_topup_at, last_topup_sats, last_error, last_attempt_at) " +
    "VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)").bind(pubkey, sealed, threshold, topup, tier, now, now).run();
  return apiJson({ data: nwcObject(await nwcRow(db, pubkey)) });
}

async function nwcDisconnect(api) {
  nwcGuard(api);
  const db = await nwcDbOrFail(api.env);
  await db.prepare("DELETE FROM api_nwc WHERE pubkey = ?").bind(api.auth.pubkey).run();
  return apiJson({ data: nwcObject(null) });
}

async function nwcNote(db, pubkey, fields) {
  const keys = Object.keys(fields);
  try {
    await db.prepare("UPDATE api_nwc SET " + keys.map((k) => k + " = ?").join(", ") + " WHERE pubkey = ?")
      .bind(...keys.map((k) => fields[k]), pubkey).run();
  } catch (e) { }
}

async function topupClaim(env, invoiceId, pubkey, rec) {
  const tier = rec.tier === "pro" ? "pro" : "standard";
  const credits = botCreditsForSatsTier(rec.amountSats, tier);
  if (credits <= 0) return { ok: false };
  const r = await ledgerCall(env, {
    op: "claim-credits", invoiceId, creditTo: pubkey, credits, tier,
    claimData: { pubkey, paidBy: pubkey, amountSats: rec.amountSats, credits, tier, gift: false }
  });
  if (r && r.alreadyClaimed) return { ok: true, already: true, credits, tier };
  if (!r || r._noLedger || r.error) return { ok: false };
  return { ok: true, credits, tier };
}

export async function apiNwcTopup(env, row) {
  const lock = await ledgerCall(env, { op: "replay", id: apiNwcLockId(row.pubkey, row.tier), ttl: API_NWC_TIMING.lockTtlS });
  if (!lock || !lock.fresh) return { skipped: true };
  const db = await nwcDb(env);
  const started = Date.now();
  let invoiceId = null;
  try {
    let uri;
    try { uri = await apiNwcOpen(nwcSecret(env), row.pubkey, row.uri_enc); } catch (e) {
      throw new Error("The saved wallet connection can no longer be read. Reconnect the wallet.");
    }
    const relayProblem = apiNwcRelayProblem(uri);
    if (relayProblem) throw new Error(relayProblem + " Reconnect the wallet with a public wss:// relay.");
    const made = await botCreditInvoice(env, row.pubkey, Number(row.topup_sats), row.tier, {});
    if (made.error) throw new Error("Could not create a top-up invoice: " + made.error);
    invoiceId = made.invoiceId;
    const paid = await nwcPayInvoice(uri, made.pr, { timeoutMs: API_NWC_TIMING.payMs, infoWaitMs: API_NWC_TIMING.infoWaitMs });
    const later = " If it goes through later, GET /api/v1/topup/status/" + invoiceId + " credits it.";
    if (!paid.ok) throw new Error("The wallet did not pay: " + paid.error + later);
    const rec = (await invoiceGet(env.DB_INVOICES, "credits", "pending", invoiceId)) ||
      { pubkey: row.pubkey, amountSats: Number(row.topup_sats), tier: row.tier, pr: made.pr };
    const confirmed = paid.verified || await invoicePaymentConfirmed(env, rec);
    if (!confirmed) throw new Error("The wallet reported the payment, but it could not be confirmed yet." + later);
    const claim = await topupClaim(env, invoiceId, row.pubkey, rec);
    if (!claim.ok) throw new Error("The payment went through, but crediting failed." + later);
    if (db) await nwcNote(db, row.pubkey, { last_topup_at: Date.now(), last_topup_sats: Number(row.topup_sats), last_error: null, last_attempt_at: started });
    return { ok: true, invoiceId, credits: claim.credits };
  } catch (e) {
    const message = String((e && e.message) || "The top-up failed.").slice(0, 500);
    if (db) await nwcNote(db, row.pubkey, { last_error: message, last_attempt_at: started });
    return { ok: false, invoiceId, error: message };
  }
}

async function nwcAfterSettle(api, bill, settled) {
  const env = api.env;
  if (!nwcSecret(env) || !settled || settled.balance == null) return;
  const db = await nwcDb(env);
  if (!db) return;
  const row = await nwcRow(db, bill.pubkey);
  if (!row || row.tier !== bill.tier) return;
  const sats = botCreditFigure(settled.balance, -(settled.dust || 0)) * apiSatsPer(bill.tier);
  if (sats >= Number(row.threshold_sats)) return;
  await apiNwcTopup(env, row);
}

async function nwcAccountField(api, pubkey) {
  if (!nwcSecret(api.env)) return {};
  const db = await nwcDb(api.env);
  if (!db) return {};
  return { nwc_auto_topup: nwcObject(await nwcRow(db, pubkey)) };
}

async function usdLimits() {
  let btc = null;
  try { btc = await botBtcPrice(); } catch (e) { btc = null; }
  if (!(btc > 0)) return null;
  const usd = (sats) => sats / 1e8 * btc;
  return { min: Math.ceil(usd(TIER_MIN_SATS.standard) * 100) / 100, max: Math.floor(usd(API_TOPUP_MAX_SATS) * 100) / 100 };
}

async function paymentMethods(api) {
  const scale = BOT_PRO_SATS_PER_CREDIT / BOT_SATS_PER_CREDIT;
  return apiJson({
    supported_methods: [{
      method: API_TOPUP_METHOD,
      display_name: "Bitcoin Lightning",
      supported_currencies: API_TOPUP_CURRENCIES.slice(),
      limits: {
        SATS: { min: TIER_MIN_SATS.standard, max: API_TOPUP_MAX_SATS },
        USD: await usdLimits(),
        BTC: { min: TIER_MIN_SATS.standard / 1e8, max: API_TOPUP_MAX_SATS / 1e8 }
      },
      tiers: API_TOPUP_TIERS.slice(),
      default_tier: "pro",
      tier_min_sats: Object.assign({}, TIER_MIN_SATS),
      sats_per_credit: { standard: BOT_SATS_PER_CREDIT, pro: BOT_PRO_SATS_PER_CREDIT },
      bulk_bonus: BOT_BULK_BONUS.slice().reverse().map((b) => ({ bonus: b.bonus, standard_sats: b.sats, pro_sats: b.sats * scale }))
    }]
  });
}

async function topupSats(body) {
  const currency = body.currency == null ? "SATS" : String(body.currency).toUpperCase();
  if (!API_TOPUP_CURRENCIES.includes(currency)) {
    throw apiBad("`currency` must be one of " + API_TOPUP_CURRENCIES.join(", ") + ".", "currency", "unsupported_currency");
  }
  const raw = body.amount;
  const amount = typeof raw === "number" ? raw : (typeof raw === "string" && /^\s*\d+(\.\d+)?\s*$/.test(raw) ? Number(raw) : NaN);
  if (!Number.isFinite(amount) || amount <= 0) throw apiBad("`amount` is required: a positive number in `currency`.", "amount");
  if (currency === "SATS") {
    if (!Number.isInteger(amount)) throw apiBad("`amount` in SATS must be a whole number.", "amount");
    return amount;
  }
  if (currency === "BTC") return Math.round(amount * 1e8);
  const btc = await botBtcPrice();
  return Math.round(amount / btc * 1e8);
}

async function topupCreate(api) {
  if (api.params.method !== API_TOPUP_METHOD) {
    throw apiBad("Unsupported top-up method `" + api.params.method + "`. Nymbot accepts " + API_TOPUP_METHOD + " only.", "method", "unsupported_method");
  }
  await apiRateLimit(api, "topupIp", apiClientIp(api), "top-up invoices from this address");
  await apiRateLimit(api, "topupPubkey", api.auth.pubkey, "top-up invoices for this account");
  const b = api.body || {};
  const tier = tierOf(b.tier, "tier");
  const sats = await topupSats(b);
  const credits = botCreditsForSatsTier(sats, tier);
  if (sats < TIER_MIN_SATS[tier] || credits <= 0) {
    throw apiBad("That is " + sats + " sats; the smallest " + (tier === "pro" ? "Pro" : "standard") + " top-up is " + TIER_MIN_SATS[tier] + " sats (one credit).", "amount", "amount_too_small");
  }
  if (sats > API_TOPUP_MAX_SATS) {
    throw apiBad("That is " + sats + " sats; the largest top-up is " + API_TOPUP_MAX_SATS + " sats.", "amount", "amount_too_large");
  }
  if (!hasD1(api.env.DB_INVOICES)) throw new ApiError(503, "api_error", "Top-ups are not available right now.", { code: "service_unavailable" });
  const made = await botCreditInvoice(api.env, api.auth.pubkey, sats, tier, {});
  if (made.error) {
    if (made.status === 400) throw apiBad(made.error, "amount", "amount_out_of_range");
    throw new ApiError(502, "api_error", "Could not create a Lightning invoice right now. Try again shortly.", { code: "invoice_unavailable", headers: { "Retry-After": "30" } });
  }
  return apiJson({
    invoice_id: made.invoiceId,
    payment_request: made.pr,
    amount_sats: sats,
    credits,
    tier,
    expires_at: apiIso(bolt11ExpiresAt(made.pr) || Date.now() + 3600000),
    status: "pending"
  });
}

const notFound = () => new ApiError(404, "not_found_error", "No top-up invoice with that id.", { code: "invoice_not_found", param: "invoice_id" });

async function statusBody(api, id, status, amountSats, credits, tier, expiresAt) {
  const b = (await apiBalances(api.env, api.auth.pubkey))[tier];
  return apiJson({
    invoice_id: id, status, amount_sats: amountSats, credits, tier, expires_at: apiIso(expiresAt),
    balance_credits: b.credits, balance_sats: b.sats
  });
}

async function topupStatus(api) {
  const id = String(api.params.invoice_id || "").toLowerCase();
  if (!INVOICE_ID_RE.test(id)) throw apiBad("`invoice_id` must be the 64-character id from the create call.", "invoice_id");
  const env = api.env;
  const pubkey = api.auth.pubkey;
  if (!hasD1(env.DB_INVOICES)) throw new ApiError(503, "api_error", "Top-ups are not available right now.", { code: "service_unavailable" });
  const rec = await invoiceGet(env.DB_INVOICES, "credits", "pending", id);
  if (!rec) {
    const done = await invoiceGet(env.DB_INVOICES, "credits", "claimed", id);
    if (!done || (done.paidBy !== pubkey && done.pubkey !== pubkey)) throw notFound();
    const t = done.tier === "pro" ? "pro" : "standard";
    return statusBody(api, id, "credited", done.amountSats == null ? null : done.amountSats, done.credits, t, null);
  }
  if (rec.pubkey !== pubkey) throw notFound();
  const tier = rec.tier === "pro" ? "pro" : "standard";
  const credits = botCreditsForSatsTier(rec.amountSats, tier);
  const expiresAt = bolt11ExpiresAt(rec.pr) || (Number(rec.createdAt) || Date.now()) + 3600000;
  const paid = await invoicePaymentConfirmed(env, rec);
  if (!paid) return statusBody(api, id, Date.now() > expiresAt ? "expired" : "pending", rec.amountSats, credits, tier, expiresAt);
  if (rec.recipientPubkey && rec.recipientPubkey !== pubkey) return statusBody(api, id, "paid", rec.amountSats, credits, tier, expiresAt);
  const claim = await topupClaim(env, id, pubkey, rec);
  return statusBody(api, id, claim.ok ? "credited" : "paid", rec.amountSats, credits, tier, expiresAt);
}

apiAddSettleHook(nwcAfterSettle);
apiAddAccountField(nwcAccountField);

export function registerTopup(r) {
  r.add("GET", "/topup/payment-methods", paymentMethods, { auth: "none", spends: false });
  r.add("POST", "/topup/create/{method}", topupCreate, { auth: "key", spends: false });
  r.add("GET", "/topup/status/{invoice_id}", topupStatus, { auth: "key", spends: false });
  r.add("GET", "/nwc-auto-topup", nwcGet, { auth: "nostr" });
  r.add("POST", "/nwc-auto-topup/connect", nwcConnect, { auth: "nostr" });
  r.add("DELETE", "/nwc-auto-topup/connection", nwcDisconnect, { auth: "nostr" });
}
