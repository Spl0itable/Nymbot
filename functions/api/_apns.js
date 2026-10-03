export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com"
};
export const APNS_JWT_MAX_AGE_S = 50 * 60;
export const APNS_DEFAULT_TOPIC = "ai.nymbot";
export const APNS_DEFAULT_TEXT = "Your reply is ready";

const enc = new TextEncoder();
const memo = { jwt: "", iat: 0, id: "" };
const keys = { p8: "", key: null };

export function apnsForget() {
  memo.jwt = "";
  memo.iat = 0;
  memo.id = "";
  keys.p8 = "";
  keys.key = null;
}

function b64url(input) {
  const bytes = typeof input === "string" ? enc.encode(input) : new Uint8Array(input);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemBody(p8) {
  return String(p8 || "")
    .replace(/\\n/g, "\n")
    .replace(/-----(BEGIN|END) [A-Z ]*-----/g, "")
    .replace(/\s+/g, "");
}

async function signingKey(p8) {
  if (keys.key && keys.p8 === p8) return keys.key;
  const body = pemBody(p8);
  if (!body || !/^[A-Za-z0-9+/]+=*$/.test(body)) throw new Error("APNS_KEY_P8 is not a PKCS#8 PEM key");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  keys.p8 = p8;
  keys.key = key;
  return key;
}

export async function apnsProviderToken(env, nowS) {
  const id = env.APNS_KEY_ID + "." + env.APNS_TEAM_ID;
  if (memo.jwt && memo.id === id && memo.iat <= nowS + 60 && nowS - memo.iat < APNS_JWT_MAX_AGE_S) return memo.jwt;
  const input = b64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })) + "." +
    b64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: nowS }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await signingKey(env.APNS_KEY_P8), enc.encode(input));
  const jwt = input + "." + b64url(sig);
  memo.jwt = jwt;
  memo.iat = nowS;
  memo.id = id;
  return jwt;
}

export function apnsConfigured(env) {
  return !!(env && env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID);
}

const RUN_STATES = { done: true, paused: true, approval: true, stopped: true, failed: true, due: true, disabled: true, question: true, pr: true, expired: true, "ci-failed": true, review: true };

export const PUSH_TEXT_MAX = 80;
export const PUSH_MIN_SECONDS = [0, 30, 120];
const PUSH_KEY_RE = /^[a-z][a-z-]{0,15}$/;
const PUSH_KEYS_MAX = 16;

export const PUSH_TEXTS = {
  turn: {
    done: "Your reply is ready",
    failed: "Nymbot could not finish that reply",
    approval: "Nymbot is waiting for your approval",
    question: "Nymbot has a question for you",
    expired: "Nymbot stopped: no answer came within 24 hours",
    paused: "Nymbot paused. Open the chat to carry on.",
    pr: "Nymbot opened a pull request"
  },
  background: {
    done: "Your background task is done",
    failed: "Your background task could not finish",
    approval: "Your background task needs your approval",
    question: "Your background task has a question for you",
    expired: "Your background task stopped: no answer came within 24 hours",
    paused: "Your background task paused",
    pr: "Your background task opened a pull request"
  },
  schedule: {
    done: "Your scheduled prompt ran",
    failed: "A scheduled prompt could not run",
    approval: "A scheduled prompt needs your approval",
    question: "A scheduled prompt has a question for you",
    expired: "A scheduled prompt stopped: no answer came within 24 hours",
    paused: "A scheduled prompt paused",
    due: "A scheduled prompt is due",
    disabled: "A scheduled prompt failed 3 times and was turned off",
    pr: "A scheduled prompt opened a pull request"
  },
  prwatch: {
    "ci-failed": "CI failed on a pull request you watch",
    review: "New review comments on a pull request you watch",
    pr: "A pull request you watch changed",
    done: "A fix run on a pull request you watch finished",
    failed: "A fix run on a pull request you watch could not finish",
    approval: "A fix run on a pull request you watch needs your approval",
    question: "A fix run on a pull request you watch has a question for you",
    paused: "A fix run on a pull request you watch paused"
  }
};

export function pushParseOpts(raw) {
  const out = {};
  if (!raw || typeof raw !== "object") return { opts: out };
  if (raw.want != null) {
    if (!Array.isArray(raw.want) || raw.want.length > PUSH_KEYS_MAX) return { error: "Invalid notification list" };
    const want = [];
    for (const w of raw.want) {
      if (typeof w !== "string" || !PUSH_KEY_RE.test(w)) return { error: "Invalid notification list" };
      if (want.indexOf(w) < 0) want.push(w);
    }
    out.want = want;
  }
  if (raw.texts != null) {
    if (typeof raw.texts !== "object" || Array.isArray(raw.texts)) return { error: "Invalid notification texts" };
    const keys = Object.keys(raw.texts);
    if (keys.length > PUSH_KEYS_MAX) return { error: "Invalid notification texts" };
    const texts = {};
    for (const k of keys) {
      const v = raw.texts[k];
      if (!PUSH_KEY_RE.test(k) || typeof v !== "string" || v.length > PUSH_TEXT_MAX) return { error: "Invalid notification texts" };
      if (v.trim()) texts[k] = v.trim();
    }
    out.texts = texts;
  }
  if (raw.min != null) {
    const min = Number(raw.min);
    if (!Number.isInteger(min) || min < 0 || min > 3600) return { error: "Invalid notification delay" };
    if (min) out.min = min;
  }
  return { opts: out };
}

export function pushWanted(reg, state) {
  if (!reg || !Array.isArray(reg.want)) return true;
  return reg.want.indexOf(String(state || "done")) >= 0;
}

export function pushText(kind, state, reg, fallback) {
  const st = typeof state === "string" && state ? state : "done";
  const texts = reg && reg.texts && typeof reg.texts === "object" ? reg.texts : null;
  if (typeof fallback === "string" && fallback.trim()) return fallback.trim().slice(0, PUSH_TEXT_MAX);
  const own = texts && typeof texts[st] === "string" ? texts[st].trim() : "";
  if (own) return own.slice(0, PUSH_TEXT_MAX);
  if (st === "done" && reg && typeof reg.text === "string" && reg.text.trim()) return reg.text.trim().slice(0, PUSH_TEXT_MAX);
  const table = PUSH_TEXTS[kind] || PUSH_TEXTS.turn;
  return table[st] || PUSH_TEXTS.turn[st] || APNS_DEFAULT_TEXT;
}

export function pushResolve(kind, reg, fields, startedAt, now) {
  const f = fields || {};
  const state = typeof f.state === "string" && f.state ? f.state : "done";
  if (!pushWanted(reg, state)) return null;
  const min = reg ? Number(reg.min) || 0 : 0;
  if (min > 0 && Number(startedAt) > 0 && (now || Date.now()) - Number(startedAt) < min * 1000) return null;
  const out = Object.assign({}, f, { state: state, text: pushText(kind, state, reg, f.fallback) });
  delete out.fallback;
  return out;
}

export function runNoticeFields(extra) {
  const out = {};
  if (!extra || typeof extra !== "object") return out;
  if (typeof extra.asked === "string" && /^[0-9a-f]{64}$/.test(extra.asked)) out.asked = extra.asked;
  if (typeof extra.state === "string" && Object.prototype.hasOwnProperty.call(RUN_STATES, extra.state)) out.state = extra.state;
  if (typeof extra.schedule === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(extra.schedule)) out.schedule = extra.schedule;
  return out;
}

export function apnsReplyPayload(chat, text, extra) {
  const body = typeof text === "string" && text.trim() ? text.trim().slice(0, 80) : APNS_DEFAULT_TEXT;
  return Object.assign({
    aps: { alert: { title: "Nymbot", body: body }, sound: "default", "thread-id": chat },
    chat: chat
  }, runNoticeFields(extra));
}

export async function apnsSendReply(env, reg, fetchFn) {
  if (!reg || !apnsConfigured(env)) return { skipped: true };
  if (typeof reg.token !== "string" || !/^[0-9a-f]{64,200}$/i.test(reg.token)) return { skipped: true };
  const send = fetchFn || fetch;
  let jwt;
  try {
    jwt = await apnsProviderToken(env, Math.floor(Date.now() / 1000));
  } catch (e) {
    return { status: 0, reason: "key" };
  }
  const host = reg.env === "sandbox" ? APNS_HOSTS.sandbox : APNS_HOSTS.production;
  let res;
  try {
    res = await send(host + "/3/device/" + reg.token, {
      method: "POST",
      headers: {
        "authorization": "bearer " + jwt,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-topic": env.APNS_TOPIC || APNS_DEFAULT_TOPIC,
        "content-type": "application/json"
      },
      body: JSON.stringify(apnsReplyPayload(reg.chat, reg.text, reg))
    });
  } catch (e) {
    return { status: 0, reason: "network" };
  }
  let reason = "";
  try {
    const text = await res.text();
    if (res.status !== 200 && text) reason = String(JSON.parse(text).reason || "");
  } catch (e) { }
  if (res.status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) apnsForget();
  return { status: res.status, reason: reason };
}
