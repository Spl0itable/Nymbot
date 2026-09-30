import {
  handleBotPMAction, botProCatalog, botProPick, botChargeRate, botOutCeiling, botWatchesVideo, botStandardRates, botBtcPrice,
  botProGenerators, botGeneratorCatalog, BOT_PM_MODELS, BOT_PM_MAX_TOKENS, BOT_IMAGE_MODELS, BOT_TTS_MODELS,
  BOT_MEDIA_COSTS, BOT_SATS_PER_CREDIT, BOT_PRO_SATS_PER_CREDIT
} from "./bot.js";
import { catalogSortKeys } from "./_catalog.js";
import { transcribeUsd } from "./_mediaprice.js";
import { ApiError, apiBad, apiJson, apiRound } from "./_apihttp.js";

export const API_AUTO_ID = "nymbot/auto";
export const API_MODEL_NAME_MAX = 200;
export const API_MODEL_SUFFIX_MAX = 4;
export const API_MODEL_TYPES = ["chat", "image", "video", "audio", "embedding"];
const AUTO_NAMES = Object.assign(Object.create(null), { "nymbot/auto": 1, "auto": 1, "nymbot-auto": 1, "nymbot": 1 });
const NOOP_SUFFIXES = Object.assign(Object.create(null), { nitro: 1, floor: 1, exacto: 1, extended: 1 });
const FEE_MARGIN = 1.05 * 1.5;
const CHAT_SAMPLING = ["temperature", "top_p", "stop", "seed", "presence_penalty", "frequency_penalty", "response_format"];
const ANTHROPIC_SAMPLING = ["temperature", "top_p", "stop"];
const RESPONSES_SAMPLING = ["temperature", "top_p", "response_format"];

export const apiModelSources = { chat: [], image: [], video: [], audio: [], embedding: [] };

export function apiAddModelSource(type, fn) {
  if (!apiModelSources[type]) apiModelSources[type] = [];
  apiModelSources[type].push(fn);
}

export function apiModelShape(m) {
  const id = String((m && m.model) || "");
  const transport = String((m && m.transport) || "");
  if (transport === "responses" || (m && m.apiPath === "responses")) return "responses";
  if (transport === "anthropic" || transport === "anthropic-compat" || /^anthropic\//.test(id)) return "anthropic";
  return "chat";
}

export function apiModelTools(m) {
  return !!m && m.tools !== false && apiModelShape(m) !== "responses";
}

export function apiModelReasons(m) {
  return !!(m && m.reasoning);
}

export function apiSamplingParams(m) {
  const shape = apiModelShape(m);
  const base = shape === "anthropic" ? ANTHROPIC_SAMPLING : (shape === "responses" ? RESPONSES_SAMPLING : CHAT_SAMPLING);
  const declared = m && m.params && typeof m.params === "object" ? Object.keys(m.params) : null;
  if (!declared || !declared.length) return base.slice();
  return base.filter((p) => declared.includes(p) || (p === "stop" && declared.includes("stop_sequences")));
}

export function apiSupportedParams(m) {
  const out = ["max_tokens", "max_completion_tokens"].concat(apiSamplingParams(m));
  if (apiModelTools(m)) {
    out.push("tools", "tool_choice");
    if (apiModelShape(m) === "chat") out.push("parallel_tool_calls");
  }
  if (apiModelReasons(m)) out.push("reasoning", "reasoning_effort", "include_reasoning");
  return out;
}

const idMaps = new WeakMap();

function findByModelId(cat, name) {
  let map = idMaps.get(cat.models);
  if (!map) {
    map = new Map();
    for (const k of Object.keys(cat.models)) {
      const id = String(cat.models[k].model || "").toLowerCase();
      if (!map.has(id)) map.set(id, k);
    }
    idMaps.set(cat.models, map);
  }
  const k = map.get(String(name || "").toLowerCase());
  return k === undefined ? null : { key: k, model: cat.models[k] };
}

async function pickOne(cat, name) {
  if (!name) return null;
  if (AUTO_NAMES[name.toLowerCase()]) return { auto: true };
  return botProPick(cat, name) || findByModelId(cat, name);
}

export async function apiResolveModel(env, raw, opts) {
  const name = typeof raw === "string" ? raw.trim() : "";
  const param = (opts && opts.param) || "model";
  if (!name) throw apiBad("`" + param + "` is required.", param, "missing_required_parameter");
  if (name.length > API_MODEL_NAME_MAX) throw apiBad("`" + param + "` is longer than " + API_MODEL_NAME_MAX + " characters.", param, "invalid_value");
  const parts = name.split(":");
  if (parts.length > API_MODEL_SUFFIX_MAX + 1) throw apiBad("`" + param + "` has more than " + API_MODEL_SUFFIX_MAX + " suffixes.", param, "invalid_value");
  const cat = await botProCatalog(env);
  let hit = null;
  let suffixes = [];
  for (let n = parts.length; n >= 1 && !hit; n--) {
    hit = await pickOne(cat, parts.slice(0, n).join(":"));
    if (hit) suffixes = parts.slice(n).map((s) => s.toLowerCase());
  }
  if (!hit) {
    throw new ApiError(404, "not_found_error", "The model `" + name + "` does not exist or is not available on Nymbot. List models with GET /api/v1/models.",
      { code: "model_not_found", param });
  }
  const out = hit.auto
    ? { id: API_AUTO_ID, tier: "standard", key: "auto", model: null, web: false, effort: null, task: null, suffixes, requested: name }
    : { id: hit.model.model, tier: "pro", key: hit.key, model: hit.model, web: false, effort: null, task: null, suffixes, requested: name };
  for (const s of suffixes) {
    if (s === "online") out.web = true;
    else if (s === "thinking") {
      if (out.tier === "standard") out.task = "reasoning";
      else if (!apiModelReasons(out.model)) {
        throw new ApiError(400, "invalid_request_error", "No endpoints found for `" + name + "`: " + out.id + " has no reasoning variant.",
          { code: "model_not_found", param });
      } else out.effort = "high";
    } else if (NOOP_SUFFIXES[s]) continue;
  }
  return out;
}

function sats(usd, btc) {
  return btc > 0 && usd != null ? apiRound(usd / btc * 1e8) : null;
}

function modalities(m) {
  const input = ["text"];
  if (m.vision) input.push("image");
  if (botWatchesVideo(m)) input.push("video");
  return { input_modalities: input, output_modalities: ["text"] };
}

export function apiChatModelEntry(m, btc) {
  const inUsd = botChargeRate(m, "in");
  const outUsd = botChargeRate(m, "out");
  const readUsd = botChargeRate(m, "cacheRead");
  const pricing = inUsd != null && outUsd != null
    ? {
      type: "per_token", currency: "USD",
      input_per_1M_tokens: inUsd, output_per_1M_tokens: outUsd, cache_read_per_1M_tokens: readUsd,
      sats_input_per_1M_tokens: sats(inUsd, btc), sats_output_per_1M_tokens: sats(outUsd, btc)
    }
    : { type: "per_request", currency: "USD", credits_per_request: m.baseCredits || 1,
      usd_per_request: btc > 0 ? apiRound((m.baseCredits || 1) * BOT_PRO_SATS_PER_CREDIT / 1e8 * btc, 6) : null };
  return {
    id: m.model,
    object: "model",
    type: "chat",
    owned_by: m.author || String(m.model || "").split("/")[0] || "",
    name: m.label || m.model,
    created: 0,
    context_length: m.context || null,
    max_output_tokens: botOutCeiling(m),
    architecture: modalities(m),
    supported_parameters: apiSupportedParams(m),
    capabilities: { vision: !!m.vision, video: botWatchesVideo(m), tools: apiModelTools(m), reasoning: apiModelReasons(m), web_search: true },
    balance: "pro",
    pricing,
    description: m.description || ""
  };
}

async function autoEntry(env, btc) {
  const routes = [];
  for (const task of Object.keys(BOT_PM_MODELS)) {
    const rates = await botStandardRates(env, BOT_PM_MODELS[task]);
    if (!rates) continue;
    const i = botChargeRate(rates, "in");
    const o = botChargeRate(rates, "out");
    routes.push({
      task, input_per_1M_tokens: i, output_per_1M_tokens: o, cache_read_per_1M_tokens: botChargeRate(rates, "cacheRead"),
      sats_input_per_1M_tokens: sats(i, btc), sats_output_per_1M_tokens: sats(o, btc),
      max_output_tokens: BOT_PM_MAX_TOKENS[task] || BOT_PM_MAX_TOKENS.general
    });
  }
  return {
    id: API_AUTO_ID,
    object: "model",
    type: "chat",
    owned_by: "Nymbot",
    name: "Nymbot Auto",
    created: 0,
    context_length: null,
    max_output_tokens: Math.max(...Object.values(BOT_PM_MAX_TOKENS)),
    architecture: { input_modalities: ["text", "image"], output_modalities: ["text"] },
    supported_parameters: ["max_tokens", "max_completion_tokens", "temperature", "top_p", "seed", "presence_penalty", "frequency_penalty"],
    capabilities: { vision: true, video: false, tools: false, reasoning: true, web_search: true },
    balance: "standard",
    pricing: { type: "variable", currency: "USD", routes },
    description: "Nymbot's standard routing: each request goes to the open model that fits the task, on the standard balance."
  };
}

async function appOrder(env) {
  try {
    const res = await handleBotPMAction({ env, request: new Request("https://nymbot.ai/api/models"), waitUntil() { } }, { action: "models" }, null, null);
    const data = await res.json();
    return (data.models || []).filter((m) => m.kind === "chat").map((m) => m.key);
  } catch (e) {
    return [];
  }
}

async function chatEntries(env, btc) {
  const cat = await botProCatalog(env);
  const ordered = await appOrder(env);
  const keys = ordered.concat(catalogSortKeys(cat.models).filter((k) => !ordered.includes(k)));
  const out = [await autoEntry(env, btc)];
  const seen = new Set();
  for (const k of keys) {
    const m = cat.models[k];
    if (!m || !m.model || seen.has(m.model)) continue;
    seen.add(m.model);
    const e = apiChatModelEntry(m, btc);
    e.nymbot_key = k;
    out.push(e);
  }
  return out;
}

function generatorId(g) {
  return String(g.key || "").replace(/^(?:image|video|speech):/, "");
}

async function generatorEntries(env, btc, kind) {
  const list = botGeneratorCatalog(await botProGenerators(env), btc).filter((g) => g.kind === kind);
  return list.map((g) => {
    const base = {
      id: generatorId(g), object: "model", type: kind === "speech" ? "audio" : kind, owned_by: g.author || "", name: g.label,
      balance: "pro", description: g.description || ""
    };
    if (kind === "image") {
      base.capabilities = { accepts_image_url: !!(g.needsImage || g.edit), requires_image_url: !!g.needsImage, edit: !!g.edit };
      base.pricing = { type: "per_generation", currency: "USD", per_generation: g.usd, sats_per_generation: sats(g.usd, btc), estimated: !g.priced };
    } else if (kind === "video") {
      const secs = g.seconds || 1;
      base.capabilities = { accepts_image_url: !!(g.needsImage || g.edit), requires_image_url: !!g.needsImage, max_duration_seconds: secs,
        resolutions: (g.resolutions || []).map((r) => r.res) };
      base.pricing = {
        type: "per_second", currency: "USD", per_second: apiRound(g.usd / secs, 6), sats_per_second: sats(g.usd / secs, btc),
        resolutions: (g.resolutions || []).map((r) => ({ resolution: r.res, per_second: apiRound(r.usd / (r.seconds || secs), 6), sats_per_second: sats(r.usd / (r.seconds || secs), btc) })),
        estimated: !g.priced
      };
    } else {
      base.audio_type = "speech";
      const per1k = g.usd * 1000 / 800;
      base.pricing = { type: "per_1k_chars", currency: "USD", per_1k_chars: apiRound(per1k, 6), sats_per_1k_chars: sats(per1k, btc), estimated: !g.priced };
    }
    return base;
  });
}

function standardFlat(credits, btc) {
  const s = credits * BOT_SATS_PER_CREDIT;
  return { usd: btc > 0 ? apiRound(s / 1e8 * btc, 6) : null, sats: s };
}

async function imageEntries(env, btc) {
  const flat = standardFlat(BOT_MEDIA_COSTS.image.standard, btc);
  return [{
    id: BOT_IMAGE_MODELS.standard, object: "model", type: "image", owned_by: "Black Forest Labs", name: "FLUX.1 [schnell]",
    balance: "standard", capabilities: { accepts_image_url: false, requires_image_url: false, edit: false },
    pricing: { type: "per_generation", currency: "USD", per_generation: flat.usd, sats_per_generation: flat.sats }
  }].concat(await generatorEntries(env, btc, "image"));
}

async function audioEntries(env, btc) {
  const flat = standardFlat(BOT_MEDIA_COSTS.speak.standard, btc);
  const whisper = transcribeUsd(60) * FEE_MARGIN;
  return [{
    id: BOT_TTS_MODELS.standard, object: "model", type: "audio", audio_type: "speech", owned_by: "MyShell", name: "MeloTTS",
    balance: "standard", pricing: { type: "per_1k_chars", currency: "USD", per_1k_chars: flat.usd, sats_per_1k_chars: flat.sats }
  }, {
    id: "whisper", object: "model", type: "audio", audio_type: "transcription", owned_by: "OpenAI", name: "Whisper large v3 turbo",
    balance: "standard",
    pricing: { type: "per_minute", currency: "USD", per_minute: apiRound(whisper, 6), sats_per_minute: sats(whisper, btc) }
  }].concat(await generatorEntries(env, btc, "speech"));
}

const BUILTIN_SOURCES = {
  chat: chatEntries,
  image: imageEntries,
  video: (env, btc) => generatorEntries(env, btc, "video"),
  audio: audioEntries,
  embedding: async () => []
};

export async function apiListModels(env, types) {
  let btc = null;
  try { btc = await botBtcPrice(); } catch (e) { btc = null; }
  const out = [];
  for (const t of types) {
    out.push(...(await BUILTIN_SOURCES[t](env, btc)));
    for (const fn of apiModelSources[t] || []) {
      try { out.push(...((await fn(env, btc)) || [])); } catch (e) { }
    }
  }
  return out;
}

function parseTypes(raw) {
  if (!raw) return ["chat"];
  const list = String(raw).split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  if (list.includes("all")) return API_MODEL_TYPES.slice();
  const bad = list.find((t) => !API_MODEL_TYPES.includes(t));
  if (bad) throw apiBad("`type` must be chat, image, video, audio, embedding or all (comma lists allowed).", "type", "invalid_type");
  return API_MODEL_TYPES.filter((t) => list.includes(t));
}

async function cached(api, path, build) {
  const key = new Request("https://nymbot-api-cache.invalid/api/v1" + path);
  try {
    if (typeof caches !== "undefined" && caches.default) {
      const hit = await caches.default.match(key);
      if (hit) return new Response(hit.body, { status: 200, headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" } });
    }
  } catch (e) { }
  const res = await build();
  if (res.status !== 200) return res;
  const text = await res.text();
  try {
    if (typeof caches !== "undefined" && caches.default) {
      api.waitUntil(caches.default.put(key, new Response(text, { headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" } })));
    }
  } catch (e) { }
  return new Response(text, { status: 200, headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" } });
}

async function listHandler(api) {
  const types = parseTypes(api.url.searchParams.get("type"));
  return cached(api, "/models?type=" + types.join(","), async () => apiJson({ object: "list", data: await apiListModels(api.env, types) }));
}

async function oneHandler(api) {
  const want = api.params.id;
  return cached(api, "/models/" + encodeURIComponent(String(want || "")), async () => {
    let r = null;
    try { r = await apiResolveModel(api.env, want); } catch (e) { r = null; }
    if (r) {
      const all = await apiListModels(api.env, ["chat"]);
      const hit = all.find((m) => m.id === r.id);
      if (hit) return apiJson(hit);
    }
    const media = await apiListModels(api.env, ["image", "video", "audio", "embedding"]);
    const found = media.find((m) => m.id === want);
    if (found) return apiJson(found);
    throw new ApiError(404, "not_found_error", "The model `" + want + "` does not exist or is not available on Nymbot.", { code: "model_not_found", param: "id" });
  });
}

export function registerModels(r) {
  r.add("GET", "/models", listHandler, { auth: "none", spends: false });
  r.add("GET", "/models/{id*}", oneHandler, { auth: "none", spends: false });
}
