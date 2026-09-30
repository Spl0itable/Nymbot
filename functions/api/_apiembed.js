import {
  aiRun, botBtcPrice, botMilliForUsd, BOT_MIN_CHARGE_MILLI, BOT_UNIFIED_BILLING_FEE, BOT_PRICE_MARGIN, BOT_SATS_PER_CREDIT
} from "./bot.js";
import { catalogEmbeddingModels } from "./_catalog.js";
import { ApiError, apiBad, apiJson, apiRound } from "./_apihttp.js";
import {
  apiBillOpen, apiBillSettle, apiBillRelease, apiCostObject, apiCostHeaders, apiRecordQuery
} from "./_apibill.js";
import { apiAddModelSource } from "./_apimodels.js";
import { apiNymbotCost } from "./_apimedia.js";

export const API_EMBED_MAX_INPUTS = 100;
export const API_EMBED_CHARS_PER_TOKEN = 4;
export const API_EMBED_RESERVE_SAFETY = 1.5;

export const API_EMBED_MODELS = {
  "@cf/baai/bge-m3": { name: "BGE M3", owned_by: "BAAI", dimensions: 1024, context: 8192, maxBatch: 100, usdPerM: 0.012,
    description: "Multilingual embeddings (100+ languages), long inputs." },
  "@cf/baai/bge-large-en-v1.5": { name: "BGE large en v1.5", owned_by: "BAAI", dimensions: 1024, context: 512, maxBatch: 100, usdPerM: 0.204,
    description: "English embeddings, the largest BGE v1.5." },
  "@cf/baai/bge-base-en-v1.5": { name: "BGE base en v1.5", owned_by: "BAAI", dimensions: 768, context: 512, maxBatch: 100, usdPerM: 0.067,
    description: "English embeddings, balanced size and quality." },
  "@cf/baai/bge-small-en-v1.5": { name: "BGE small en v1.5", owned_by: "BAAI", dimensions: 384, context: 512, maxBatch: 100, usdPerM: 0.020,
    description: "English embeddings, smallest and fastest." },
  "@cf/qwen/qwen3-embedding-0.6b": { name: "Qwen3 Embedding 0.6B", owned_by: "Qwen", dimensions: 1024, context: 8192, maxBatch: 32, usdPerM: 0.012,
    description: "Multilingual embeddings from the Qwen3 family, long inputs." }
};

export const API_EMBED_CATALOG_ONLY = {
  "@cf/google/embeddinggemma-300m": { name: "EmbeddingGemma 300M", owned_by: "Google", dimensions: 768, context: 2048, maxBatch: 100,
    mrl: [768, 512, 256, 128], description: "Multilingual embeddings with Matryoshka dimensions (768, 512, 256, 128)." }
};

const FEE_MARGIN = (usd) => usd * BOT_UNIFIED_BILLING_FEE * BOT_PRICE_MARGIN;

export async function apiEmbeddingModels(env) {
  let live = null;
  try { live = await catalogEmbeddingModels(env); } catch (e) { live = null; }
  const rows = (live && live.byModelId) || {};
  const priced = (id) => rows[id] && rows[id].inUsdPerMTok > 0 ? rows[id] : null;
  const ids = Object.keys(API_EMBED_MODELS).concat(Object.keys(API_EMBED_CATALOG_ONLY).filter(priced));
  return ids.map((id) => {
    const base = API_EMBED_MODELS[id] || API_EMBED_CATALOG_ONLY[id];
    const row = rows[id] || null;
    const live = priced(id);
    return Object.assign({ id }, base, {
      context: (row && row.context) || base.context,
      usdPerM: live ? live.inUsdPerMTok : base.usdPerM,
      priceSource: live ? "catalog" : "fallback"
    });
  });
}

function entry(m, btc) {
  const usd = apiRound(FEE_MARGIN(m.usdPerM), 6);
  const out = {
    id: m.id, object: "model", type: "embedding", owned_by: m.owned_by, name: m.name, created: 0,
    dimensions: m.dimensions, context_length: m.context, max_inputs: API_EMBED_MAX_INPUTS, balance: "standard",
    pricing: {
      type: "per_token", currency: "USD", input_per_1M_tokens: usd,
      sats_input_per_1M_tokens: btc > 0 ? apiRound(usd / btc * 1e8) : null, source: m.priceSource
    },
    description: m.description
  };
  if (m.mrl) out.supported_dimensions = m.mrl.slice();
  return out;
}

async function resolve(env, name) {
  const want = typeof name === "string" ? name.trim().toLowerCase() : "";
  if (!want) throw apiBad("`model` is required.", "model", "missing_required_parameter");
  const list = await apiEmbeddingModels(env);
  const hit = list.find((m) => m.id === want) || list.find((m) => m.id.split("/").pop() === want);
  if (!hit) {
    throw new ApiError(404, "not_found_error", "The embedding model `" + name + "` does not exist on Nymbot. List them with GET /api/v1/models?type=embedding.",
      { code: "model_not_found", param: "model" });
  }
  return hit;
}

function tokensOf(text) {
  return Math.max(1, Math.ceil(new TextEncoder().encode(text).length / API_EMBED_CHARS_PER_TOKEN));
}

function inputsOf(input) {
  const tokenErr = () => apiBad("Token arrays are not supported; send `input` as a string or a list of strings.", "input", "token_input_unsupported");
  if (typeof input === "string") {
    if (!input.length) throw apiBad("`input` must not be empty.", "input", "invalid_value");
    return [input];
  }
  if (!Array.isArray(input)) throw apiBad("`input` is required: a string or a list of strings.", "input", "missing_required_parameter");
  if (!input.length) throw apiBad("`input` must not be empty.", "input", "invalid_value");
  if (input.some((x) => typeof x === "number" || Array.isArray(x))) throw tokenErr();
  if (input.length > API_EMBED_MAX_INPUTS) {
    throw apiBad("`input` has " + input.length + " items; send up to " + API_EMBED_MAX_INPUTS + " per request.", "input", "too_many_inputs");
  }
  input.forEach((x, i) => {
    if (typeof x !== "string" || !x.length) throw apiBad("`input[" + i + "]` must be a non-empty string.", "input", "invalid_value");
  });
  return input;
}

function milliFor(tokens, usdPerM, btc) {
  return Math.max(BOT_MIN_CHARGE_MILLI, botMilliForUsd(tokens * usdPerM / 1e6 * BOT_UNIFIED_BILLING_FEE * BOT_PRICE_MARGIN, btc, BOT_SATS_PER_CREDIT));
}

function shrink(vec, dims) {
  const cut = vec.slice(0, dims);
  const norm = Math.sqrt(cut.reduce((n, x) => n + x * x, 0));
  return norm > 0 ? cut.map((x) => x / norm) : cut;
}

function b64Floats(vec) {
  const f = new Float32Array(vec);
  const bytes = new Uint8Array(f.buffer);
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

async function embeddings(api) {
  const env = api.env;
  const b = api.body;
  const t0 = Date.now();
  const m = await resolve(env, b.model);
  const inputs = inputsOf(b.input);
  const fmt = b.encoding_format == null || b.encoding_format === "" ? "float" : b.encoding_format;
  if (fmt !== "float" && fmt !== "base64") throw apiBad("`encoding_format` must be \"float\" or \"base64\".", "encoding_format", "invalid_value");
  let dims = m.dimensions;
  if (b.dimensions != null) {
    const d = Number(b.dimensions);
    const ok = Number.isInteger(d) && (d === m.dimensions || (m.mrl && m.mrl.includes(d)));
    if (!ok) {
      throw apiBad(m.id + " returns " + (m.mrl ? m.mrl.join(", ") : m.dimensions) + " dimensions; `dimensions` " + b.dimensions + " is not available.", "dimensions", "unsupported_dimensions");
    }
    dims = d;
  }
  const counts = inputs.map(tokensOf);
  counts.forEach((n, i) => {
    if (n > m.context) {
      throw apiBad("`input" + (inputs.length > 1 ? "[" + i + "]" : "") + "` is about " + n + " tokens; " + m.id + " takes up to " + m.context + ".", "input", "input_too_long");
    }
  });
  const estimate = counts.reduce((a, n) => a + n, 0);
  const btc = await botBtcPrice();
  const bill = await apiBillOpen(api, {
    tier: "standard", reserveMilli: milliFor(Math.ceil(estimate * API_EMBED_RESERVE_SAFETY), m.usdPerM, btc), l402Partial: true, refresh: true
  });
  const size = Math.max(1, Math.min(API_EMBED_MAX_INPUTS, Math.floor(Number(m.maxBatch) || API_EMBED_MAX_INPUTS)));
  const vectors = [];
  let tokens = 0;
  try {
    for (let at = 0; at < inputs.length; at += size) {
      const part = inputs.slice(at, at + size);
      const out = await aiRun(env.AI, m.id, { text: part });
      const got = out && Array.isArray(out.data) ? out.data : null;
      if (!got || got.length !== part.length || !got.every((v) => Array.isArray(v) && v.length >= dims)) throw new Error("bad shape");
      const u = out.usage && Number(out.usage.prompt_tokens);
      tokens += u > 0 ? Math.floor(u) : counts.slice(at, at + size).reduce((a, n) => a + n, 0);
      for (const v of got) vectors.push(v);
    }
  } catch (e) {
    const settled = tokens > 0 ? await apiBillSettle(api, bill, milliFor(tokens, m.usdPerM, btc), { l402Partial: true }) : await apiBillRelease(api, bill);
    api.waitUntil(apiRecordQuery(api, {
      type: "embedding", model: m.id, usage: tokens > 0 ? { fresh: tokens, read: 0, wrote: 0, out: 0 } : null, milli: settled.chargedMilli,
      tier: "standard", status: "error", btcUsd: btc, ms: Date.now() - t0
    }));
    throw new ApiError(502, "api_error", settled.chargedMilli > 0
      ? "The embedding model failed partway through the request. The batches it finished were charged. Please try again."
      : "The embedding model failed. Nothing was charged. Please try again.", { code: "upstream_error" });
  }
  const settled = await apiBillSettle(api, bill, milliFor(tokens, m.usdPerM, btc));
  const cost = await apiCostObject(api, bill, settled, btc);
  api.waitUntil(apiRecordQuery(api, {
    type: "embedding", model: m.id, usage: { fresh: tokens, read: 0, wrote: 0, out: 0 }, milli: settled.chargedMilli,
    tier: "standard", status: "ok", btcUsd: btc, ms: Date.now() - t0
  }));
  const data = vectors.map((v, i) => {
    const vec = dims < v.length || (m.mrl && b.dimensions != null && dims !== m.dimensions) ? shrink(v, dims) : v.slice(0, dims);
    return { object: "embedding", index: i, embedding: fmt === "base64" ? b64Floats(vec) : vec };
  });
  return apiJson({
    object: "list", data, model: m.id, usage: { prompt_tokens: tokens, total_tokens: tokens }, nymbot: apiNymbotCost(cost)
  }, 200, apiCostHeaders(cost));
}

let sourceAdded = false;

export function registerEmbeddings(r) {
  if (!sourceAdded) {
    sourceAdded = true;
    apiAddModelSource("embedding", async (env, btc) => (await apiEmbeddingModels(env)).map((m) => entry(m, btc)));
  }
  r.add("POST", "/embeddings", embeddings, { auth: "paid" });
}
