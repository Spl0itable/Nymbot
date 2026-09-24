const SHARE_HOSTS = new Set([
  "blossom.band",
  "blossom.primal.net",
  "nostr.download"
]);

const MAX_SHARE_BYTES = 12 * 1024 * 1024;
const SHARE_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

export function shareBase(server) {
  if (!server) return null;
  try {
    const u = new URL(server);
    if (u.protocol !== "https:") return null;
    if (!SHARE_HOSTS.has(u.hostname)) return null;
    return "https://" + u.hostname;
  } catch (_) {
    return null;
  }
}

export function shareHash(value) {
  const x = String(value || "").toLowerCase();
  return /^[0-9a-f]{64}$/.test(x) ? x : null;
}

function reply(body, status, cors, type) {
  const headers = new Headers(cors || {});
  headers.set("Content-Type", type || "application/json");
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  return new Response(type ? body : JSON.stringify(body), { status, headers });
}

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readCapped(resp, max) {
  const body = resp.body;
  if (!body || typeof body.getReader !== "function") {
    const all = await resp.arrayBuffer();
    return all.byteLength > max ? null : all;
  }
  const reader = body.getReader();
  const parts = [];
  let total = 0;
  while (true) {
    const step = await reader.read();
    if (step.done) break;
    total += step.value ? step.value.byteLength : 0;
    if (total > max) {
      try { await reader.cancel(); } catch (_) { }
      return null;
    }
    parts.push(step.value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.byteLength; }
  return out.buffer;
}

export async function handleShareBlob(request, params, cors) {
  if (request.method !== "GET") return reply({ error: "GET required" }, 405, cors);
  const base = shareBase(params.get("server"));
  const hash = shareHash(params.get("x"));
  if (!base || !hash) return reply({ error: "Unknown blob" }, 400, cors);
  const resp = await fetch(base + "/" + hash, {
    headers: { "User-Agent": SHARE_UA, "Accept": "*/*" },
    cf: { cacheTtl: 0, cacheEverything: false }
  });
  if (resp.status === 404 || resp.status === 410) return reply({ error: "Gone" }, 404, cors);
  if (!resp.ok) return reply({ error: "Upstream returned " + resp.status }, 502, cors);
  const declared = parseInt(resp.headers.get("content-length") || "", 10);
  if (Number.isFinite(declared) && declared > MAX_SHARE_BYTES) return reply({ error: "Too large" }, 413, cors);
  const bytes = await readCapped(resp, MAX_SHARE_BYTES);
  if (!bytes) return reply({ error: "Too large" }, 413, cors);
  if (await sha256Hex(bytes) !== hash) return reply({ error: "Hash mismatch" }, 502, cors);
  return reply(bytes, 200, cors, "application/octet-stream");
}

export async function handleShareDelete(request, params, cors) {
  if (request.method !== "POST" && request.method !== "DELETE") {
    return reply({ error: "POST required" }, 405, cors);
  }
  const base = shareBase(params.get("server"));
  const hash = shareHash(params.get("x"));
  if (!base || !hash) return reply({ error: "Unknown blob" }, 400, cors);
  const auth = request.headers.get("Authorization");
  if (!auth || !auth.startsWith("Nostr ")) return reply({ error: "Missing Nostr auth" }, 401, cors);
  const resp = await fetch(base + "/" + hash, {
    method: "DELETE",
    headers: { "Authorization": auth, "User-Agent": SHARE_UA, "Accept": "application/json" }
  });
  if (resp.ok || resp.status === 404) return reply({ ok: true, status: resp.status }, 200, cors);
  return reply({ error: "Upstream returned " + resp.status, status: resp.status }, resp.status === 401 || resp.status === 403 ? 403 : 502, cors);
}
