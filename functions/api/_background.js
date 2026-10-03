import { apnsSendReply, pushParseOpts, pushResolve } from "./_apns.js";
import { webPushSendReply, webPushToken, unifiedPushSend, unifiedPushParse } from "./_webpush.js";

export var BG_MAX_LEGS = 40;
export var BG_MIN_LEGS = 2;
export var BG_MAX_MS = 6 * 3600 * 1000;
export var BG_KEEP_AFTER_MS = 24 * 3600 * 1000;
export var BG_HMAC_SKEW_MS = 5 * 60 * 1000;
export var BG_MAX_CREDITS = 100000;
export var BG_LEG_GAP_MS = 2000;
export var BG_SEALED_PREFIX = "bg1.";

export var SCHED_MAX = 10;
export var SCHED_MAX_MS = 90 * 86400 * 1000;
export var SCHED_PROMPT_MAX = 4000;
export var SCHED_TITLE_MAX = 120;
export var SCHED_DAILY_DEFAULT = 50;
export var SCHED_DAILY_MAX = 10000;
export var SCHED_PER_RUN_MAX = 1000;
export var SCHED_RUNS_DAY_MAX = 24;
export var SCHED_FAIL_MAX = 3;
export var SCHED_PAYLOAD_MAX = 12000;
export var SCHED_STEPS = { once: 0, hourly: 3600000, daily: 86400000, weekly: 604800000 };

var BG_REQ_KEYS = ["proModel", "git", "repos", "mcp", "effort", "web", "followUps", "research", "team", "policy",
  "maxCost", "maxRuns", "serverRuns", "runKind", "leadTools", "pqClassical", "ask"];

var enc = new TextEncoder();
var dec = new TextDecoder();
var keyMemo = { raw: "", key: null };

function b64u(bytes) {
  var bin = "";
  var b = new Uint8Array(bytes);
  for (var i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function unb64u(s) {
  if (typeof s !== "string" || !/^[A-Za-z0-9_+/-]*={0,2}$/.test(s)) return null;
  var t = s.replace(/=+$/, "").replace(/-/g, "+").replace(/_/g, "/");
  try {
    return Uint8Array.from(atob(t + "===".slice((t.length + 3) % 4)), function (c) { return c.charCodeAt(0); });
  } catch (e) {
    return null;
  }
}

function hex(bytes) {
  var b = new Uint8Array(bytes);
  var out = "";
  for (var i = 0; i < b.length; i++) out += (b[i] < 16 ? "0" : "") + b[i].toString(16);
  return out;
}

export function bgSealKeyBytes(env) {
  var raw = String((env && env.BG_SEAL_KEY) || "").trim();
  if (!raw) return null;
  if (/^[0-9a-f]{64}$/i.test(raw)) {
    var out = new Uint8Array(32);
    for (var i = 0; i < 32; i++) out[i] = parseInt(raw.slice(i * 2, i * 2 + 2), 16);
    return out;
  }
  var b = unb64u(raw);
  return b && b.length === 32 ? b : null;
}

function hmacKeyOf(env) {
  var k = String((env && env.BG_HMAC_KEY) || "");
  return k.length >= 32 ? k : "";
}

export function bgSealReady(env) {
  return !!bgSealKeyBytes(env);
}

export function bgConfigured(env) {
  return !!(bgSealKeyBytes(env) && hmacKeyOf(env));
}

export function bgDriverReady(env) {
  return !!(env && env.RUN_DRIVER && typeof env.RUN_DRIVER.idFromName === "function" && bgConfigured(env));
}

async function aesKey(env) {
  var raw = bgSealKeyBytes(env);
  if (!raw) return null;
  var id = hex(raw);
  if (keyMemo.key && keyMemo.raw === id) return keyMemo.key;
  var key = await crypto.subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
  keyMemo.raw = id;
  keyMemo.key = key;
  return key;
}

async function squeeze(bytes, mode) {
  var stream = new Blob([bytes]).stream().pipeThrough(mode === "in" ? new CompressionStream("gzip") : new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

function aadOf(pk, runId) {
  return enc.encode(String(pk || "").toLowerCase() + "|" + String(runId || ""));
}

export async function bgSeal(env, pk, runId, obj) {
  var key = await aesKey(env);
  if (!key) return null;
  var plain;
  try { plain = enc.encode(JSON.stringify(obj)); } catch (e) { return null; }
  var packed = await squeeze(plain, "in");
  var iv = crypto.getRandomValues(new Uint8Array(12));
  var ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv: iv, additionalData: aadOf(pk, runId) }, key, packed);
  return BG_SEALED_PREFIX + b64u(iv) + "." + b64u(ct);
}

export async function bgOpen(env, pk, runId, sealed) {
  if (typeof sealed !== "string" || sealed.indexOf(BG_SEALED_PREFIX) !== 0) return null;
  var key = await aesKey(env);
  if (!key) return null;
  var parts = sealed.slice(BG_SEALED_PREFIX.length).split(".");
  if (parts.length !== 2) return null;
  var iv = unb64u(parts[0]);
  var ct = unb64u(parts[1]);
  if (!iv || iv.length !== 12 || !ct) return null;
  try {
    var packed = await crypto.subtle.decrypt({ name: "AES-GCM", iv: iv, additionalData: aadOf(pk, runId) }, key, ct);
    return JSON.parse(dec.decode(await squeeze(new Uint8Array(packed), "out")));
  } catch (e) {
    return null;
  }
}

export async function bgResumeSeal(env, pk, runId, state) {
  if (!bgSealReady(env) || !/^[0-9a-f]{64}$/i.test(String(runId || ""))) return state;
  var sealed = await bgSeal(env, pk, "r:" + String(runId).toLowerCase(), state);
  return sealed ? { v: "bg1", run: String(runId).toLowerCase(), s: sealed } : state;
}

export async function bgResumeOpen(env, pk, state) {
  if (!state || typeof state !== "object" || state.v !== "bg1") return { state: state };
  var run = String(state.run || "");
  if (!/^[0-9a-f]{64}$/.test(run)) return { state: null };
  var opened = await bgOpen(env, pk, "r:" + run, state.s);
  return { state: opened, run: run };
}

export async function bgSign(secret, pk, runId, leg, ts) {
  var k = await crypto.subtle.importKey("raw", enc.encode(String(secret)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  var msg = String(pk).toLowerCase() + "|" + String(runId) + "|" + String(leg) + "|" + String(ts);
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
}

function sameText(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export async function bgVerify(env, body, now) {
  var secret = hmacKeyOf(env);
  if (!secret || !body || typeof body !== "object") return false;
  if (typeof body.pubkey !== "string" || !/^[0-9a-f]{64}$/i.test(body.pubkey)) return false;
  if (typeof body.runId !== "string" || !/^([sw]:)?[0-9A-Za-z_-]{1,64}$/.test(body.runId)) return false;
  if (typeof body.leg !== "string" && typeof body.leg !== "number") return false;
  var ts = Number(body.ts);
  var at = now || Date.now();
  if (!Number.isFinite(ts) || Math.abs(at - ts) > BG_HMAC_SKEW_MS) return false;
  if (typeof body.sig !== "string" || !/^[0-9a-f]{64}$/.test(body.sig)) return false;
  var want = await bgSign(secret, body.pubkey, body.runId, body.leg, ts);
  return sameText(want, body.sig);
}

export async function sha256Hex(text) {
  return hex(await crypto.subtle.digest("SHA-256", typeof text === "string" ? enc.encode(text) : text));
}

export async function bgLegIds(runId, n) {
  var r = String(runId).toLowerCase();
  return {
    eventId: await sha256Hex("nymbg-event|" + r + "|" + n),
    msgId: await sha256Hex("nymbg-asked|" + r + "|" + n)
  };
}

export async function bgSchedIds(id, firedAt) {
  return {
    eventId: await sha256Hex("nymsched-event|" + id + "|" + firedAt),
    msgId: await sha256Hex("nymsched-asked|" + id + "|" + firedAt)
  };
}

export function bgRequestOf(body) {
  var out = {};
  for (var i = 0; i < BG_REQ_KEYS.length; i++) {
    var k = BG_REQ_KEYS[i];
    if (body && Object.prototype.hasOwnProperty.call(body, k) && body[k] !== undefined) out[k] = body[k];
  }
  return out;
}

function chatOk(chat) {
  return typeof chat === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(chat);
}

export function bgParsePush(raw, isPrivate) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  if (!chatOk(raw.chat)) return null;
  if (raw.text != null && (typeof raw.text !== "string" || raw.text.length > 80)) return null;
  var base = { env: raw.env, chat: raw.chat };
  if (typeof raw.text === "string" && raw.text) base.text = raw.text;
  var opts = pushParseOpts(raw);
  if (opts.error) return null;
  Object.assign(base, opts.opts);
  if (raw.env === "production" || raw.env === "sandbox") {
    var tok = typeof raw.token === "string" ? raw.token.toLowerCase() : "";
    if (!/^[0-9a-f]{64,200}$/.test(tok)) return null;
    base.token = tok;
    return base;
  }
  if (raw.env === "web") {
    var sub = webPushToken(raw.subscription);
    if (!sub) return null;
    base.token = sub;
    return base;
  }
  if (raw.env === "unifiedpush") {
    var up = unifiedPushParse(raw, isPrivate);
    if (!up) return null;
    base.token = JSON.stringify(up);
    return base;
  }
  return null;
}

export async function bgPushSend(env, reg, fields, fetchFn) {
  if (!reg || typeof reg !== "object") return { skipped: true };
  var f = Object.assign({}, fields || {});
  var kind = typeof f.kind === "string" ? f.kind : "background";
  var started = Number(f.startedAt) || 0;
  delete f.kind;
  delete f.startedAt;
  var picked = pushResolve(kind, reg, f, started);
  if (!picked) return { skipped: true, filtered: true };
  var msg = Object.assign({}, reg, picked);
  if (picked.chat == null) msg.chat = reg.chat;
  try {
    if (reg.env === "web") return await webPushSendReply(env, msg, fetchFn);
    if (reg.env === "unifiedpush") return await unifiedPushSend(env, msg, fetchFn);
    if (reg.env === "production" || reg.env === "sandbox") return await apnsSendReply(env, msg, fetchFn);
  } catch (e) {
    return { status: 0, reason: "error" };
  }
  return { skipped: true };
}

export function bgParseGrant(raw, isPrivate) {
  if (raw == null || raw === false) return { grant: null };
  if (typeof raw !== "object" || Array.isArray(raw)) return { error: "The background setting could not be read." };
  var legs = raw.maxLegs == null ? BG_MAX_LEGS : Number(raw.maxLegs);
  if (!Number.isInteger(legs) || legs < BG_MIN_LEGS) return { error: "A background run needs at least " + BG_MIN_LEGS + " steps." };
  legs = Math.min(legs, BG_MAX_LEGS);
  var credits = null;
  if (raw.maxCredits != null) {
    credits = Number(raw.maxCredits);
    if (!Number.isFinite(credits) || credits <= 0) return { error: "The background credit limit must be a positive number." };
    credits = Math.min(credits, BG_MAX_CREDITS);
  }
  var notify = null;
  if (raw.notify != null) {
    notify = bgParsePush(raw.notify, isPrivate);
    if (!notify) return { error: "Invalid push registration", push: true };
  }
  return { grant: { maxLegs: legs, maxCredits: credits, notify: notify } };
}

export async function bgDriver(env, pk, msg) {
  if (!env || !env.RUN_DRIVER || typeof env.RUN_DRIVER.idFromName !== "function") return null;
  var who = String(pk || "").toLowerCase();
  try {
    var stub = env.RUN_DRIVER.get(env.RUN_DRIVER.idFromName("u:" + who));
    var res = await stub.fetch("https://driver/op", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(Object.assign({}, msg, { pubkey: who }))
    });
    var data = await res.json();
    return data && typeof data === "object" ? data : null;
  } catch (e) {
    return null;
  }
}

export function schedParse(raw, now, isPrivate) {
  var at = now || Date.now();
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "The schedule could not be read." };
  if (typeof raw.id !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(raw.id)) return { error: "Invalid schedule id." };
  var mode = raw.mode === "notify" ? "notify" : (raw.mode === "run" ? "run" : null);
  if (!mode) return { error: "A schedule runs the prompt or only notifies." };
  if (typeof raw.sha256 !== "string" || !/^[0-9a-f]{64}$/i.test(raw.sha256)) return { error: "The schedule's hash is missing." };
  var expiresAt = Number(raw.expiresAt);
  if (!Number.isFinite(expiresAt) || expiresAt <= at) return { error: "This schedule's permission has expired. Save it again to renew it.", expired: true };
  if (expiresAt > at + SCHED_MAX_MS) return { error: "A server schedule can be allowed for at most 90 days at a time." };
  if (typeof raw.payload !== "string" || !raw.payload || raw.payload.length > SCHED_PAYLOAD_MAX) return { error: "The schedule is empty or too long." };
  var p;
  try { p = JSON.parse(raw.payload); } catch (e) { return { error: "The schedule could not be read." }; }
  if (!p || typeof p !== "object" || Array.isArray(p)) return { error: "The schedule could not be read." };
  if (!Object.prototype.hasOwnProperty.call(SCHED_STEPS, p.repeat)) return { error: "A server schedule repeats at most hourly: once, hourly, daily or weekly." };
  var nextAt = Number(p.nextAt);
  if (!Number.isFinite(nextAt) || nextAt <= 0) return { error: "The schedule has no time set." };
  var step = SCHED_STEPS[p.repeat];
  if (step && nextAt < at) nextAt += Math.ceil((at - nextAt) / step) * step;
  if (!step && nextAt < at - 60000) return { error: "That time has already passed." };
  var push = null;
  if (raw.push != null) {
    push = bgParsePush(raw.push, isPrivate);
    if (!push) return { error: "Invalid push registration", push: true };
  }
  var dailyCap = raw.dailyCap == null ? SCHED_DAILY_DEFAULT : Number(raw.dailyCap);
  if (!Number.isFinite(dailyCap) || dailyCap < 1 || dailyCap > SCHED_DAILY_MAX) return { error: "The daily credit limit for schedules must be between 1 and " + SCHED_DAILY_MAX + "." };
  var out = { id: raw.id, mode: mode, sha256: raw.sha256.toLowerCase(), expiresAt: Math.floor(expiresAt), nextAt: Math.floor(nextAt), step: step, push: push, dailyCap: dailyCap };
  if (mode === "notify") {
    if (!push) return { error: "Notify-only schedules need a push registration.", push: true };
    return { sched: out };
  }
  var prompt = typeof p.prompt === "string" ? p.prompt.trim() : "";
  if (!prompt) return { error: "The scheduled prompt is empty." };
  if (prompt.length > SCHED_PROMPT_MAX) return { error: "A server schedule's prompt can be at most " + SCHED_PROMPT_MAX + " characters." };
  var title = typeof p.title === "string" ? p.title.slice(0, SCHED_TITLE_MAX) : "";
  var thread = typeof p.thread === "string" ? p.thread.toLowerCase() : "";
  if (thread && !/^[0-9a-f]{64}$/.test(thread)) return { error: "Invalid target chat." };
  var tier = p.tier === "pro" ? "pro" : "standard";
  var model = typeof p.model === "string" ? p.model.slice(0, 120) : "";
  if (tier === "pro" && !model) return { error: "A Pro schedule needs its model." };
  var perRun = Number(raw.maxCreditsPerRun);
  if (!Number.isFinite(perRun) || perRun <= 0 || perRun > SCHED_PER_RUN_MAX) return { error: "Set how many credits one run may spend (up to " + SCHED_PER_RUN_MAX + ")." };
  if (perRun > dailyCap) return { error: "One run may not spend more than the daily limit for schedules." };
  var perDay = raw.maxRunsPerDay == null ? SCHED_RUNS_DAY_MAX : Number(raw.maxRunsPerDay);
  if (!Number.isInteger(perDay) || perDay < 1 || perDay > SCHED_RUNS_DAY_MAX) return { error: "A schedule runs between 1 and " + SCHED_RUNS_DAY_MAX + " times a day." };
  out.prompt = prompt;
  out.title = title;
  out.thread = thread;
  out.tier = tier;
  out.model = tier === "pro" ? model : "";
  out.maxCreditsPerRun = perRun;
  out.maxRunsPerDay = perDay;
  out.repeat = p.repeat;
  out.ask = p.ask === true;
  out.runChanges = p.runChanges === true;
  return { sched: out };
}
