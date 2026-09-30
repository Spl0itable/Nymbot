const CLIENT_ORIGIN_HOSTS = new Set([
  "nymbot.ai",
  "www.nymbot.ai"
]);

// Extra comma-separated hostnames in `API_CLIENT_HOSTS` (staging, local builds).
function envClientHosts(env) {
  const raw = env && typeof env.API_CLIENT_HOSTS === "string" ? env.API_CLIENT_HOSTS : "";
  if (!raw) return null;
  return new Set(raw.split(",").map((h) => h.trim().toLowerCase()).filter(Boolean));
}

// Allowlisted hosts count only over https (loopback excepted) so a plaintext origin can't be minted.
function originIsTrustworthy(url) {
  if (url.protocol === "https:") return true;
  return url.protocol === "http:" &&
    (url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]");
}

function isNymchatClient(request, env) {
  const origin = request.headers.get("Origin") || "";
  if (origin) {
    try {
      const url = new URL(origin);
      const host = url.host.toLowerCase();
      if (host === new URL(request.url).host.toLowerCase()) return true;
      if (originIsTrustworthy(url)) {
        if (CLIENT_ORIGIN_HOSTS.has(host)) return true;
        const extra = envClientHosts(env);
        if (extra && extra.has(host)) return true;
      }
    } catch (_) {}
  }
  const ua = request.headers.get("User-Agent") || "";
  return /Nym(?:chat|bot)App\//i.test(ua) || /\bNYMApp\b/.test(ua);
}

const APP_ORIGIN_HOSTS = new Set([
  "nymbot.ai",
  "www.nymbot.ai"
]);

function clientOriginAllowed(request, env) {
  const origin = request.headers.get("Origin");
  if (!origin) return true;   // native clients and same-origin GETs send none
  try {
    const url = new URL(origin);
    if (url.origin === new URL(request.url).origin) return true;
    if (!originIsTrustworthy(url)) return false;
    const host = url.host.toLowerCase();
    if (APP_ORIGIN_HOSTS.has(host) || CLIENT_ORIGIN_HOSTS.has(host)) return true;
    const extra = envClientHosts(env);
    return !!(extra && extra.has(host));
  } catch (_) {
    return false;
  }
}

function isStandaloneNymbot(request, env) {
  const origin = request.headers.get("Origin") || "";
  if (origin) {
    try {
      const url = new URL(origin);
      const host = url.host.toLowerCase();
      if (originIsTrustworthy(url)) {
        if (CLIENT_ORIGIN_HOSTS.has(host)) return true;
        const extra = envClientHosts(env);
        if (extra && extra.has(host)) return true;
      }
    } catch (_) {}
  }
  return /NymbotApp\//i.test(request.headers.get("User-Agent") || "");
}

const RATE_WINDOW_MS = 60000;
const RATE_HOST = "https://nymbot-socket-rate.invalid";

function clientIp(request) {
  try { return request.headers.get("CF-Connecting-IP") || ""; } catch (_) { return ""; }
}

async function socketRateOk(request, env, bucket, limit, bindingName) {
  const ip = clientIp(request);
  if (!ip) return true;
  const binding = env && bindingName ? env[bindingName] : null;
  if (binding && typeof binding.limit === "function") {
    try {
      const out = await binding.limit({ key: bucket + ":" + ip });
      return !!(out && out.success);
    } catch (_) {}
  }
  try {
    if (typeof caches === "undefined" || !caches.default) return true;
    const windowId = Math.floor(Date.now() / RATE_WINDOW_MS);
    const key = new Request(RATE_HOST + "/" + bucket + "?ip=" + encodeURIComponent(ip) + "&w=" + windowId);
    let count = 0;
    const hit = await caches.default.match(key);
    if (hit) {
      const n = parseInt(await hit.text(), 10);
      if (Number.isFinite(n)) count = n;
    }
    if (count >= limit) return false;
    await caches.default.put(key, new Response(String(count + 1), {
      headers: { "Content-Type": "text/plain", "Cache-Control": "max-age=" + Math.ceil(RATE_WINDOW_MS / 1000) }
    }));
    return true;
  } catch (_) {
    return true;
  }
}

export { CLIENT_ORIGIN_HOSTS, APP_ORIGIN_HOSTS, clientOriginAllowed, isNymchatClient, isStandaloneNymbot, socketRateOk };
