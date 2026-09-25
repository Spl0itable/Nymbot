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

export function apnsReplyPayload(chat, text) {
  const body = typeof text === "string" && text.trim() ? text.trim().slice(0, 80) : APNS_DEFAULT_TEXT;
  return {
    aps: { alert: { title: "Nymbot", body: body }, sound: "default", "thread-id": chat },
    chat: chat
  };
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
      body: JSON.stringify(apnsReplyPayload(reg.chat, reg.text))
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
