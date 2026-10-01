import { mcpHostBlocked } from "./_mcp.js";

export var SITE_OWN_DOMAINS = ["nymbot.ai", "nymbot.pages.dev", "nymchat.app", "nymchat.pages.dev"];
export var SITE_URL_MAX = 2000;
export var SITE_SIGNATURE_SKEW_MS = 60000;
export var SITE_DOH_URL = "https://cloudflare-dns.com/dns-query";

var SITE_ERRORS = {
  invalid: "That is not a valid web address.",
  scheme: "Only http and https addresses can be checked.",
  credentials: "Leave usernames and passwords out of the address.",
  private: "That address is private or local, so it cannot be checked.",
  own: "Nymbot's own sites cannot be checked.",
  port: "Only the standard ports (80 and 443) can be checked.",
  dns: "The address could not be resolved safely."
};

export function siteRefusal(reason) {
  return { ok: false, reason: reason, error: SITE_ERRORS[reason] || SITE_ERRORS.invalid };
}

function under(host, list) {
  for (var i = 0; i < list.length; i++) {
    var d = list[i];
    if (host === d || host.slice(-(d.length + 1)) === "." + d) return true;
  }
  return false;
}

export function siteUrlCheck(raw, opts) {
  var s = typeof raw === "string" ? raw.trim() : "";
  if (!s || s.length > SITE_URL_MAX) return siteRefusal("invalid");
  var u;
  try { u = new URL(s); } catch (e) { return siteRefusal("invalid"); }
  if (u.protocol !== "http:" && u.protocol !== "https:") return siteRefusal("scheme");
  if (u.username || u.password) return siteRefusal("credentials");
  var host = u.hostname.toLowerCase().replace(/\.+$/, "");
  if (!host) return siteRefusal("invalid");
  var bare = host.charAt(0) === "[" ? host.slice(1, -1) : host;
  var kind = mcpHostBlocked(bare);
  if (kind === "address" || kind === "local") return siteRefusal("private");
  if (kind === "invalid") return siteRefusal("invalid");
  if (under(host, SITE_OWN_DOMAINS)) return siteRefusal("own");
  if (u.port) {
    var allowed = opts && Array.isArray(opts.allowPorts) ? opts.allowPorts.map(Number) : [];
    if (allowed.indexOf(Number(u.port)) === -1) return siteRefusal("port");
  }
  u.hash = "";
  return { ok: true, url: u.toString() };
}

export function siteAddressBlocked(ip) {
  var s = String(ip || "").trim().toLowerCase();
  if (!s) return true;
  if (s.charAt(0) === "[") s = s.slice(1, -1);
  return mcpHostBlocked(s) !== "";
}

function literal(host) {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.indexOf(":") !== -1 || host.charAt(0) === "[";
}

export async function siteResolveCheck(host, resolve) {
  var h = String(host || "").toLowerCase().replace(/\.+$/, "");
  if (literal(h)) return { ok: true };
  var ips;
  try {
    ips = await resolve(h);
  } catch (e) {
    return siteRefusal("dns");
  }
  for (var i = 0; i < (ips || []).length; i++) {
    if (siteAddressBlocked(ips[i])) return siteRefusal("private");
  }
  return { ok: true };
}

export async function siteDohResolve(host, fetchImpl) {
  var f = fetchImpl || fetch;
  var out = [];
  var types = [["A", 1], ["AAAA", 28]];
  for (var i = 0; i < types.length; i++) {
    var res = await f(SITE_DOH_URL + "?name=" + encodeURIComponent(host) + "&type=" + types[i][0], {
      headers: { Accept: "application/dns-json" }
    });
    if (!res.ok) throw new Error("DNS lookup failed (" + res.status + ")");
    var data = await res.json();
    var answers = data && Array.isArray(data.Answer) ? data.Answer : [];
    for (var j = 0; j < answers.length; j++) {
      if (answers[j] && answers[j].type === types[i][1] && typeof answers[j].data === "string") out.push(answers[j].data.trim());
    }
  }
  return out;
}

function hex(buf) {
  var b = new Uint8Array(buf);
  var s = "";
  for (var i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, "0");
  return s;
}

export async function siteSign(secret, ts, body) {
  var enc = new TextEncoder();
  var key = await crypto.subtle.importKey("raw", enc.encode(String(secret).trim()), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(String(ts) + "\n" + String(body))));
}

export async function siteVerify(secret, tsHeader, sig, body, now) {
  var key = String(secret || "").trim();
  if (!key || !/^\d{10,16}$/.test(String(tsHeader || ""))) return false;
  var ts = Number(tsHeader);
  var at = Number.isFinite(Number(now)) ? Number(now) : Date.now();
  if (Math.abs(at - ts) > SITE_SIGNATURE_SKEW_MS) return false;
  var given = String(sig || "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(given)) return false;
  var want = await siteSign(key, ts, body);
  var diff = 0;
  for (var i = 0; i < 64; i++) diff |= want.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}
