import { handleBotPMAction } from "./bot.js";

const MODELS_EDGE_TTL = 300;

export async function onRequestGet(context) {
  const cache = typeof caches !== "undefined" ? caches.default : null;
  const key = new Request(new URL("/api/models", context.request.url).toString(), { method: "GET" });
  if (cache) {
    try {
      const hit = await cache.match(key);
      if (hit) return hit;
    } catch (e) { }
  }
  const upstream = await handleBotPMAction(context, { action: "models" }, null, null);
  const body = await upstream.text();
  const res = new Response(body, {
    status: upstream.status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": `public, max-age=${MODELS_EDGE_TTL}`,
      "X-Content-Type-Options": "nosniff"
    }
  });
  if (cache && upstream.ok) {
    try {
      const put = cache.put(key, res.clone());
      if (typeof context.waitUntil === "function") context.waitUntil(put);
      else await put;
    } catch (e) { }
  }
  return res;
}
