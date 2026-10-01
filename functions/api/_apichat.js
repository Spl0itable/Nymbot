import {
  proGatewayChat, proConfigured, botBtcPrice, botMeteredCharge, botMeteredReserveMilli, botProCost, botProMaxCost,
  botOutCeiling, botStandardRates, botStandardPartsMilli, botStandardRun, botClassify, botCreditsForTask,
  botFailedSpendMilli, botUsageZero, botUsageBilled, botWebReserveTokens, botSearchContext, searchCitations,
  searchQueryFor, needsWebSearch, webSearch, sanitizeBotResponse, isPrivateHostUrl, botMilliForUsd,
  BOT_PM_MODELS, BOT_PM_MAX_TOKENS, BOT_PM_VISION_ROUTES, BOT_PM_VISION_MODEL, BOT_IMAGE_RESERVE_TOKENS,
  BOT_RESERVE_CHARS_PER_TOKEN, BOT_SATS_PER_CREDIT, BOT_PRO_SATS_PER_CREDIT, BOT_MIN_CHARGE_MILLI, BOT_MODEL_UTILITY
} from "./bot.js";
import {
  ApiError, apiBad, apiJson, apiRandomId, apiSseStream, apiSseHeaders, apiClientGone, apiErrorBody,
  apiUrlHasUserinfo, API_TIMING, API_IMAGE_URL_MAX_CHARS
} from "./_apihttp.js";
import {
  apiBillOpen, apiBillSettle, apiBillFail, apiBillPrecheck, apiBillCheckpoint, apiCostObject, apiCostHeaders, apiRecordQuery,
  API_BILL_TIMING
} from "./_apibill.js";
import { apiResolveModel, apiModelTools, apiModelReasons, apiSamplingParams, apiModelShape } from "./_apimodels.js";

export const API_CHAT_MAX_IMAGES = 20;
export const API_WEB_DEFAULT_RESULTS = 5;
export const API_WEB_MAX_RESULTS = 10;
export const API_MAX_JSON_DEPTH = 64;
export const API_MAX_JSON_NODES = 100000;
export const API_MAX_TOOLS = 128;
export const API_MAX_TOOLS_BYTES = 512 * 1024;
export const API_RESERVE_NONASCII_BYTES_PER_TOKEN = 3;
export const API_WEB_SEARCH_USD = 0.008;
const CLASSIFIER_PROMPT_CHARS = 700;
const CLASSIFIER_INPUT_CHARS = 1000;
const ROLES = Object.assign(Object.create(null), { system: 1, developer: 1, user: 1, assistant: 1, tool: 1 });
const EFFORTS = ["minimal", "low", "medium", "high"];
const EFFORT_BUDGET = Object.assign(Object.create(null), { minimal: 1024, low: 2048, medium: 8192, high: 16384 });
const SAMPLING = ["temperature", "top_p", "stop", "seed", "presence_penalty", "frequency_penalty", "response_format"];
const STANDARD_SAMPLING = ["temperature", "top_p", "seed", "presence_penalty", "frequency_penalty"];
const IMAGE_DETAILS = ["auto", "low", "high"];
const WEB_TOOLS = Object.assign(Object.create(null), { web_search: 1, web_search_preview: 1, "openrouter:web_search": 1 });

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((p) => p && p.type === "text" && typeof p.text === "string").map((p) => p.text).join("\n");
}

function nestedTooDeep(value, limit) {
  const stack = [[value, 1]];
  let nodes = 0;
  while (stack.length) {
    const [x, depth] = stack.pop();
    if (depth > limit || ++nodes > API_MAX_JSON_NODES) return true;
    for (const k in x) {
      if (!Object.prototype.hasOwnProperty.call(x, k)) continue;
      const c = x[k];
      if (c && typeof c === "object") stack.push([c, depth + 1]);
    }
  }
  return false;
}

export function apiCheckNesting(obj) {
  if (!obj || typeof obj !== "object") return;
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    if (v && typeof v === "object" && nestedTooDeep(v, API_MAX_JSON_DEPTH)) {
      throw apiBad("`" + k + "` is nested too deeply or has too many parts (at most " + API_MAX_JSON_DEPTH + " levels and " +
        API_MAX_JSON_NODES + " objects and arrays).", k, "too_deeply_nested");
    }
  }
}

function checkImageUrl(url, where) {
  const bad = (why) => apiBad("Image " + where + ": " + why, where, "invalid_image_url");
  if (typeof url !== "string" || !url) throw bad("`image_url.url` is required.");
  if (/^data:image\/svg/i.test(url)) throw bad("SVG pictures are not accepted; send PNG, JPEG, WebP or GIF.");
  if (/^data:image\/[a-z0-9.+-]+;base64,/i.test(url)) return url;
  if (!/^https?:\/\//i.test(url)) throw bad("only http(s) and data:image URLs are accepted.");
  if (url.length > API_IMAGE_URL_MAX_CHARS) throw bad("the URL is longer than " + API_IMAGE_URL_MAX_CHARS + " characters.");
  if (apiUrlHasUserinfo(url)) throw bad("the URL must not carry a user name or password.");
  if (isPrivateHostUrl(url)) throw bad("the URL must point to a public host.");
  return url;
}

function normalizePart(p, where, counter) {
  if (!p || typeof p !== "object") throw apiBad("Each content part must be an object.", where);
  if (p.type === "text") {
    if (typeof p.text !== "string") throw apiBad("A text part needs `text`.", where);
    return { type: "text", text: p.text };
  }
  if (p.type === "image_url") {
    const url = typeof p.image_url === "string" ? p.image_url : p.image_url && p.image_url.url;
    counter.images++;
    if (counter.images > API_CHAT_MAX_IMAGES) {
      throw apiBad("At most " + API_CHAT_MAX_IMAGES + " images per request.", where, "too_many_images");
    }
    const out = { type: "image_url", image_url: { url: checkImageUrl(url, where) } };
    if (p.image_url && typeof p.image_url === "object" && p.image_url.detail != null) {
      if (!IMAGE_DETAILS.includes(p.image_url.detail)) throw apiBad("`image_url.detail` must be auto, low or high.", where + ".image_url.detail", "invalid_value");
      out.image_url.detail = p.image_url.detail;
    }
    return out;
  }
  if (p.type === "input_audio" || p.type === "file" || p.type === "input_file") {
    throw apiBad("Content parts of type `" + p.type + "` are not supported; send text and images.", where, "unsupported_content");
  }
  throw apiBad("Unknown content part type `" + String(p.type) + "`.", where, "unsupported_content");
}

function normalizeToolCalls(list, where) {
  if (list == null) return null;
  if (!Array.isArray(list)) throw apiBad("`tool_calls` must be an array.", where);
  return list.map((tc, i) => {
    const f = tc && tc.function;
    if (!f || typeof f.name !== "string") throw apiBad("Each tool call needs `function.name`.", where + "[" + i + "]");
    const args = typeof f.arguments === "string" ? f.arguments : JSON.stringify(f.arguments || {});
    return { id: String((tc && tc.id) || ("call_" + i)), type: "function", function: { name: f.name, arguments: args } };
  });
}

function normalizeMessages(list, counter) {
  if (!Array.isArray(list) || !list.length) throw apiBad("`messages` must be a non-empty array.", "messages", "missing_required_parameter");
  return list.map((m, i) => {
    const at = "messages[" + i + "]";
    if (!m || typeof m !== "object") throw apiBad("Each message must be an object.", at);
    if (!ROLES[m.role]) throw apiBad("`role` must be system, developer, user, assistant or tool.", at + ".role", "invalid_role");
    const role = m.role === "developer" ? "system" : m.role;
    let content = m.content;
    if (content != null && typeof content !== "string") {
      if (!Array.isArray(content)) throw apiBad("`content` must be a string or an array of parts.", at + ".content");
      content = content.map((p, j) => normalizePart(p, at + ".content[" + j + "]", counter));
      if (role === "system" || role === "tool" || role === "assistant") {
        if (content.some((p) => p.type !== "text")) {
          if (role !== "assistant") throw apiBad("Only user messages may carry images.", at + ".content", "unsupported_content");
        } else content = textOf(content);
      }
    }
    const out = { role, content: content == null ? (role === "assistant" ? null : "") : content };
    if (role === "tool") {
      if (typeof m.tool_call_id !== "string" || !m.tool_call_id) throw apiBad("A tool message needs `tool_call_id`.", at + ".tool_call_id");
      out.tool_call_id = m.tool_call_id;
      if (typeof out.content !== "string") out.content = textOf(out.content);
    }
    if (role === "assistant" && m.tool_calls != null) {
      const calls = normalizeToolCalls(m.tool_calls, at + ".tool_calls");
      if (calls && calls.length) out.tool_calls = calls;
    }
    if (role === "user" && out.content == null) out.content = "";
    return out;
  });
}

function normalizeTools(body, resolved) {
  let web = null;
  const functions = [];
  if (body.tools != null) {
    if (!Array.isArray(body.tools)) throw apiBad("`tools` must be an array.", "tools");
    if (body.tools.length > API_MAX_TOOLS) throw apiBad("At most " + API_MAX_TOOLS + " tools per request.", "tools", "too_many_tools");
    for (const t of body.tools) {
      if (t && WEB_TOOLS[t.type]) {
        const n = Number((t.parameters && t.parameters.max_results) || t.max_results);
        web = { mode: "auto", maxResults: n > 0 ? Math.min(API_WEB_MAX_RESULTS, Math.floor(n)) : API_WEB_DEFAULT_RESULTS };
        continue;
      }
      if (!t || t.type !== "function" || !t.function || typeof t.function.name !== "string" || !t.function.name) {
        throw apiBad("Only `function` tools (and `web_search`) are supported.", "tools", "unsupported_tool");
      }
      const f = { name: t.function.name };
      if (typeof t.function.description === "string") f.description = t.function.description;
      f.parameters = t.function.parameters && typeof t.function.parameters === "object" ? t.function.parameters : { type: "object", properties: {} };
      if (typeof t.function.strict === "boolean") f.strict = t.function.strict;
      functions.push({ type: "function", function: f });
    }
  }
  if (functions.length && JSON.stringify(functions).length > API_MAX_TOOLS_BYTES) {
    throw apiBad("The tool definitions are too large (at most " + API_MAX_TOOLS_BYTES / 1024 + " KB).", "tools", "tools_too_large");
  }
  if (functions.length && resolved.tier === "standard") {
    throw apiBad("nymbot/auto does not call tools. Pick a catalog model that supports tools (see GET /api/v1/models).", "tools", "unsupported_tool");
  }
  if (functions.length && !apiModelTools(resolved.model)) {
    throw apiBad(resolved.id + " does not support tool calling through Nymbot.", "tools", "unsupported_tool");
  }
  return { tools: functions.length ? functions : null, web };
}

function checkToolChoice(tc) {
  if (tc == null) return undefined;
  if (tc === "none" || tc === "auto" || tc === "required") return tc;
  if (tc && typeof tc === "object" && tc.type === "function" && tc.function && typeof tc.function.name === "string") {
    return { type: "function", function: { name: tc.function.name } };
  }
  throw apiBad("`tool_choice` must be none, auto, required or {type:\"function\", function:{name}}.", "tool_choice");
}

function checkMaxTokens(body) {
  const field = body.max_completion_tokens != null ? "max_completion_tokens" : (body.max_tokens != null ? "max_tokens" : null);
  if (!field) return null;
  const n = body[field];
  if (typeof n !== "number" || !Number.isInteger(n) || n < 1) throw apiBad("`" + field + "` must be a positive integer.", field);
  return n;
}

function checkEffort(body, resolved) {
  let e = resolved.effort || body.reasoning_effort || (body.reasoning && typeof body.reasoning === "object" ? body.reasoning.effort : null);
  if (body.reasoning && typeof body.reasoning === "object" && body.reasoning.enabled === false && !resolved.effort) return null;
  if (e == null || e === "none") return null;
  if (!EFFORTS.includes(e)) throw apiBad("`reasoning_effort` must be minimal, low, medium or high.", "reasoning_effort");
  return e;
}

export const API_STOP_MAX = 4;
export const API_STOP_MAX_CHARS = 256;
export const API_LOGIT_BIAS_MAX = 300;
export const API_USER_MAX_CHARS = 256;
export const API_METADATA_MAX_KEYS = 16;
export const API_METADATA_KEY_CHARS = 64;
export const API_METADATA_VALUE_CHARS = 512;
const SAMPLING_RANGES = { temperature: [0, 2], top_p: [0, 1], presence_penalty: [-2, 2], frequency_penalty: [-2, 2] };

const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const isPlain = (v) => !!v && typeof v === "object" && !Array.isArray(v);

export function apiCheckMetadata(v, param) {
  if (v == null) return;
  const keys = isPlain(v) ? Object.keys(v) : null;
  if (!keys || keys.length > API_METADATA_MAX_KEYS || keys.some((k) => k.length > API_METADATA_KEY_CHARS || typeof v[k] !== "string" || v[k].length > API_METADATA_VALUE_CHARS)) {
    throw apiBad("`" + param + "` must be an object of at most " + API_METADATA_MAX_KEYS + " string values, keys up to " + API_METADATA_KEY_CHARS +
      " characters and values up to " + API_METADATA_VALUE_CHARS + ".", param, "invalid_value");
  }
}

export function apiCheckSampling(body) {
  for (const k of Object.keys(SAMPLING_RANGES)) {
    const v = body[k];
    if (v == null) continue;
    const [lo, hi] = SAMPLING_RANGES[k];
    if (!isNum(v) || v < lo || v > hi) throw apiBad("`" + k + "` must be a number from " + lo + " to " + hi + ".", k, "invalid_value");
  }
  if (body.seed != null && !Number.isSafeInteger(body.seed)) throw apiBad("`seed` must be an integer.", "seed", "invalid_value");
  if (body.stop != null) {
    const list = Array.isArray(body.stop) ? body.stop : [body.stop];
    if (list.length > API_STOP_MAX || list.some((x) => typeof x !== "string" || x.length > API_STOP_MAX_CHARS)) {
      throw apiBad("`stop` must be a string or an array of at most " + API_STOP_MAX + " strings of at most " + API_STOP_MAX_CHARS + " characters.", "stop", "invalid_value");
    }
  }
  if (body.response_format != null && !(isPlain(body.response_format) && typeof body.response_format.type === "string")) {
    throw apiBad("`response_format` must be an object with a `type`.", "response_format", "invalid_value");
  }
  if (body.logit_bias != null) {
    const keys = isPlain(body.logit_bias) ? Object.keys(body.logit_bias) : null;
    if (!keys || keys.length > API_LOGIT_BIAS_MAX || keys.some((k) => !isNum(body.logit_bias[k]) || body.logit_bias[k] < -100 || body.logit_bias[k] > 100)) {
      throw apiBad("`logit_bias` must map at most " + API_LOGIT_BIAS_MAX + " token ids to numbers from -100 to 100.", "logit_bias", "invalid_value");
    }
  }
  if (body.user != null && (typeof body.user !== "string" || body.user.length > API_USER_MAX_CHARS)) {
    throw apiBad("`user` must be a string of at most " + API_USER_MAX_CHARS + " characters.", "user", "invalid_value");
  }
  apiCheckMetadata(body.metadata, "metadata");
}

export async function apiChatPrepare(api, body) {
  if (typeof body.model !== "string" || !body.model.trim()) throw apiBad("`model` is required.", "model", "missing_required_parameter");
  if (body.n != null && body.n !== 1) throw apiBad("Only n = 1 is supported.", "n");
  apiCheckNesting(body);
  apiCheckSampling(body);
  const resolved = await apiResolveModel(api.env, body.model);
  const counter = { images: 0 };
  const messages = normalizeMessages(body.messages, counter);
  if (counter.images && resolved.tier === "pro" && !resolved.model.vision) {
    throw apiBad(resolved.id + " does not accept images.", "messages", "unsupported_content");
  }
  const t = normalizeTools(body, resolved);
  let web = t.web;
  if (Array.isArray(body.plugins)) {
    const p = body.plugins.find((x) => x && x.id === "web");
    if (p) {
      const n = Number(p.max_results);
      web = { mode: "always", maxResults: n > 0 ? Math.min(API_WEB_MAX_RESULTS, Math.floor(n)) : API_WEB_DEFAULT_RESULTS };
    }
  }
  if (resolved.web) web = { mode: "always", maxResults: web ? web.maxResults : API_WEB_DEFAULT_RESULTS };
  const sampling = {};
  for (const k of SAMPLING) if (body[k] !== undefined && body[k] !== null) sampling[k] = body[k];
  return apiAnthropicToolLoopGuard({
    type: "chat",
    resolved,
    messages,
    images: counter.images,
    tools: t.tools,
    toolChoice: t.tools ? checkToolChoice(body.tool_choice) : undefined,
    parallelToolCalls: t.tools && typeof body.parallel_tool_calls === "boolean" ? body.parallel_tool_calls : undefined,
    maxTokens: checkMaxTokens(body),
    sampling,
    effort: checkEffort(body, resolved),
    web,
    stream: body.stream === true,
    includeUsage: !!(body.stream_options && body.stream_options.include_usage === true),
    completionId: apiRandomId("chatcmpl-", 29),
    created: Math.floor(Date.now() / 1000)
  });
}

export function apiResumesToolLoop(req) {
  const last = req.messages[req.messages.length - 1];
  return !!last && last.role === "tool";
}

export function apiAnthropicToolLoopGuard(req) {
  if (req.effort && req.resolved.tier === "pro" && apiModelShape(req.resolved.model) === "anthropic" && apiResumesToolLoop(req)) req.effort = null;
  return req;
}

export function apiReserveTokens(text) {
  const s = typeof text === "string" ? text : "";
  let ascii = 0;
  let dense = 0;
  let wide = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) {
      if ((c >= 0x30 && c <= 0x39) || (c > 0x20 && c < 0x7f && !((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)))) dense++;
      else ascii++;
    }
    else if (c < 0x800) wide += 2;
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      wide += 4;
      i++;
    } else wide += 3;
  }
  return ascii / BOT_RESERVE_CHARS_PER_TOKEN + dense + wide / API_RESERVE_NONASCII_BYTES_PER_TOKEN;
}

function inputTokens(req, pro) {
  let tokens = 0;
  let images = 0;
  for (const m of req.messages) {
    tokens += 16 / BOT_RESERVE_CHARS_PER_TOKEN;
    if (typeof m.content === "string") tokens += apiReserveTokens(m.content);
    else if (Array.isArray(m.content)) {
      for (const p of m.content) {
        if (p.type === "text") tokens += apiReserveTokens(p.text);
        else if (p.type === "image_url") images++;
      }
    }
    if (m.tool_calls) tokens += apiReserveTokens(JSON.stringify(m.tool_calls));
  }
  if (req.tools) tokens += apiReserveTokens(JSON.stringify(req.tools));
  return Math.ceil(tokens) + images * BOT_IMAGE_RESERVE_TOKENS + (req.web ? botWebReserveTokens(pro) : 0);
}

function searchFeeMilli(tier, btc) {
  return botMilliForUsd(API_WEB_SEARCH_USD, btc, tier === "pro" ? BOT_PRO_SATS_PER_CREDIT : BOT_SATS_PER_CREDIT);
}

function estimatedUsage(req, plan, messages, u, outChars) {
  const base = u || botUsageZero();
  const fed = (Number(base.fresh) || 0) + (Number(base.read) || 0) + (Number(base.wrote) || 0);
  const inTok = inputTokens({ messages, tools: req.tools, web: null }, plan.tier === "pro");
  const hidden = plan.tier === "pro" && apiModelReasons(plan.model) ? plan.maxOut : 0;
  const out = Math.max(Number(base.out) || 0, Math.ceil((Number(outChars) || 0) / 4), hidden);
  if (fed >= inTok) return { fresh: Number(base.fresh) || 0, read: Number(base.read) || 0, wrote: Number(base.wrote) || 0, out };
  return { fresh: inTok, read: 0, wrote: 0, out };
}

function providerToolCalls(list) {
  if (!Array.isArray(list)) return null;
  const out = [];
  list.forEach((tc, i) => {
    const f = tc && typeof tc === "object" ? tc.function : null;
    if (!f || typeof f !== "object" || typeof f.name !== "string" || !f.name) return;
    let args = "{}";
    if (typeof f.arguments === "string") args = f.arguments;
    else if (f.arguments != null) {
      try { args = JSON.stringify(f.arguments); } catch (e) { args = "{}"; }
    }
    out.push({ id: String((tc && tc.id) || ("call_" + i)), type: "function", function: { name: f.name, arguments: args } });
  });
  return out.length ? out : null;
}

function lastUserIndex(messages) {
  for (let i = messages.length - 1; i >= 0; i--) if (messages[i].role === "user") return i;
  return -1;
}

async function planRun(api, req, btc) {
  const env = api.env;
  const r = req.resolved;
  const inTok = inputTokens(req, r.tier === "pro");
  if (r.tier === "pro") {
    if (!proConfigured(env)) throw new ApiError(503, "api_error", "Catalog models are not available right now.", { code: "service_unavailable" });
    const m = r.model;
    const ceiling = botOutCeiling(m);
    const maxOut = Math.min(req.maxTokens || ceiling, ceiling);
    let reserve = botMeteredReserveMilli(Object.assign({}, m, { maxTokens: maxOut }), 1, false, btc, BOT_PRO_SATS_PER_CREDIT, null, inTok);
    if (reserve == null) reserve = botProMaxCost(m, false) * 1000;
    if (req.web) reserve += searchFeeMilli("pro", btc);
    return { tier: "pro", model: m, maxOut, reserveMilli: reserve, btc, stdRates: null };
  }
  if (!env.AI || typeof env.AI.run !== "function") {
    throw new ApiError(503, "api_error", "Standard routing is not available right now.", { code: "service_unavailable" });
  }
  const at = lastUserIndex(req.messages);
  const question = at >= 0 ? textOf(req.messages[at].content) : "";
  let classifyUsage = null;
  if (!r.task) {
    await apiBillPrecheck(api, "standard");
    classifyUsage = { fresh: Math.ceil(CLASSIFIER_PROMPT_CHARS / BOT_RESERVE_CHARS_PER_TOKEN + apiReserveTokens(question.slice(0, CLASSIFIER_INPUT_CHARS))), read: 0, wrote: 0, out: 6 };
  }
  const task = r.task || await botClassify(env.AI, question, null);
  const route = BOT_PM_MODELS[task] || BOT_PM_MODELS.general;
  const pmModel = req.images && !BOT_PM_VISION_ROUTES[task] ? BOT_PM_VISION_MODEL : route;
  const ceiling = BOT_PM_MAX_TOKENS[task] || BOT_PM_MAX_TOKENS.general;
  const maxOut = Math.min(req.maxTokens || ceiling, ceiling);
  const stdRates = await botStandardRates(env, route);
  const priced = [stdRates];
  if (pmModel !== route) priced.push(await botStandardRates(env, pmModel));
  let reserve = null;
  for (const rates of priced) {
    if (!rates) continue;
    const milli = botMeteredReserveMilli(Object.assign({}, rates, { maxTokens: maxOut }), 1, false, btc, BOT_SATS_PER_CREDIT, null, inTok);
    if (milli != null && (reserve == null || milli > reserve)) reserve = milli;
  }
  if (reserve == null) reserve = botCreditsForTask(task) * 1000;
  if (req.web) reserve += searchFeeMilli("standard", btc);
  return { tier: "standard", model: null, task, route, pmModel, maxOut, reserveMilli: reserve, btc, stdRates, classifyUsage };
}

function anthropicToolChoice(tc, parallel) {
  let out = null;
  if (tc === "auto") out = { type: "auto" };
  else if (tc === "required") out = { type: "any" };
  else if (tc === "none") out = { type: "none" };
  else if (tc && typeof tc === "object") out = { type: "tool", name: tc.function.name };
  if (parallel === false) {
    if (!out) out = { type: "auto" };
    if (out.type !== "none") out.disable_parallel_tool_use = true;
  }
  return out;
}

function responsesFormat(rf) {
  if (!rf || typeof rf !== "object") return null;
  if (rf.type === "json_schema" && rf.json_schema) {
    return Object.assign({ type: "json_schema" }, rf.json_schema);
  }
  if (rf.type === "json_object" || rf.type === "text") return { type: rf.type };
  return null;
}

export function apiUpstreamParams(req, m, maxOut) {
  const allowed = new Set(apiSamplingParams(m));
  const s = req.sampling || {};
  const reasons = apiModelReasons(m);
  return function (shape) {
    const out = {};
    if (shape === "anthropic") {
      if (s.temperature !== undefined && allowed.has("temperature")) out.temperature = s.temperature;
      if (s.top_p !== undefined && allowed.has("top_p")) out.top_p = s.top_p;
      if (s.stop !== undefined && allowed.has("stop")) out.stop_sequences = Array.isArray(s.stop) ? s.stop : [s.stop];
      let forced = false;
      if (req.tools) {
        const tc = anthropicToolChoice(req.toolChoice, req.parallelToolCalls);
        if (tc) {
          out.tool_choice = tc;
          forced = tc.type === "any" || tc.type === "tool";
        }
      }
      if (req.effort && reasons && !forced) {
        const budget = Math.min(EFFORT_BUDGET[req.effort] || 2048, maxOut - 1);
        if (budget >= 1024) {
          out.thinking = { type: "enabled", budget_tokens: budget };
          delete out.temperature;
          delete out.top_p;
        }
      }
      return out;
    }
    if (shape === "responses") {
      if (s.temperature !== undefined && allowed.has("temperature")) out.temperature = s.temperature;
      if (s.top_p !== undefined && allowed.has("top_p")) out.top_p = s.top_p;
      const fmt = allowed.has("response_format") ? responsesFormat(s.response_format) : null;
      if (fmt) out.text = { format: fmt };
      if (req.effort && reasons) out.reasoning = { effort: req.effort };
      return out;
    }
    for (const k of SAMPLING) if (s[k] !== undefined && allowed.has(k)) out[k] = s[k];
    if (req.tools) {
      if (req.toolChoice !== undefined) out.tool_choice = req.toolChoice;
      if (req.parallelToolCalls !== undefined) out.parallel_tool_calls = req.parallelToolCalls;
    }
    if (req.effort && reasons) out.reasoning_effort = req.effort;
    return out;
  };
}

function standardParams(req) {
  const out = {};
  for (const k of STANDARD_SAMPLING) if (req.sampling[k] !== undefined) out[k] = req.sampling[k];
  return Object.keys(out).length ? out : null;
}

export function apiSplitThink(content, reasoning) {
  let text = typeof content === "string" ? content : textOf(content);
  let r = typeof reasoning === "string" ? reasoning.trim() : "";
  const m = /^\s*<think>([\s\S]*?)<\/think>\s*/i.exec(text);
  if (m) {
    if (!r) r = m[1].trim();
    text = text.slice(m[0].length);
  }
  return { text, reasoning: r };
}

async function webContext(api, req, tier) {
  if (!req.web) return null;
  const at = lastUserIndex(req.messages);
  const question = at >= 0 ? textOf(req.messages[at].content).trim() : "";
  if (!question) return null;
  const query = searchQueryFor(question, []);
  if (req.web.mode === "auto" && !needsWebSearch(question, query)) return null;
  let results = [];
  req.webSearched = true;
  try { results = await webSearch(query, null, api.env, { pro: tier === "pro" }); } catch (e) { results = []; }
  const kept = results.slice(0, req.web.maxResults);
  kept.sources = results.sources;
  kept.reachable = results.reachable;
  kept.pages = (results.pages || []).filter((p) => kept.some((line) => String(line).includes(p.url)));
  const attempted = kept.length > 0 || results.reachable === true;
  const context = kept.length || attempted ? botSearchContext(question, kept, attempted, query) : "";
  return { at, context, query, sources: kept.length ? searchCitations(kept) : [] };
}

function withWeb(messages, web) {
  if (!web || !web.context || web.at < 0) return messages;
  return messages.slice(0, web.at)
    .concat([{ role: "user", content: web.context }, { role: "assistant", content: "Understood." }])
    .concat(messages.slice(web.at));
}

async function runPro(api, req, plan, messages, draft, gone) {
  const m = plan.model;
  const res = await proGatewayChat(api.env, m, messages, plan.maxOut, req.tools, {
    draft: draft || null,
    gone,
    params: apiUpstreamParams(req, m, plan.maxOut)
  });
  const usage = (res && res.usage) || botUsageZero();
  try {
    const msg = (res && res.msg) || {};
    const split = apiSplitThink(msg.content, msg.reasoning_content || msg.reasoning);
    const billed = botUsageBilled(usage);
    const guess = billed ? null : estimatedUsage(req, Object.assign({}, plan, { maxOut: 0 }), messages, null,
      split.text.length + split.reasoning.length);
    if (guess && res && res.outputTokens > guess.out) guess.out = res.outputTokens;
    let milli = botMeteredCharge(m, billed ? usage : guess, plan.btc, BOT_PRO_SATS_PER_CREDIT);
    if (milli == null) milli = botProCost(m, 1, (res && res.outputTokens) || Math.ceil(split.text.length / 4), false) * 1000;
    const calls = providerToolCalls(msg.tool_calls);
    return { content: split.text, reasoning: split.reasoning, toolCalls: calls, usage, milli };
  } catch (e) {
    if (e && typeof e === "object" && !botUsageBilled(e.usage)) {
      e.usage = botUsageBilled(usage) ? usage : estimatedUsage(req, plan, messages, null, 0);
    }
    throw e;
  }
}

async function runStandard(api, req, plan, messages, draft, gone) {
  const env = api.env;
  const std = await botStandardRun(env.AI, plan.pmModel, messages, plan.maxOut, {
    draft: draft || null,
    gone,
    fallbackMax: plan.maxOut,
    vision: req.images > 0,
    params: standardParams(req),
    clean: (t) => sanitizeBotResponse(t, true, true)
  });
  if (!String(std.reply || "").trim()) {
    const e = new Error("The model returned an empty reply.");
    e.usage = std.usage;
    e.usageParts = std.usageParts;
    throw e;
  }
  let metered = null;
  const split = apiSplitThink(std.reply, "");
  if (plan.stdRates) {
    const billed = std.billedModel && std.billedModel !== plan.route
      ? (await botStandardRates(env, std.billedModel)) || plan.stdRates
      : plan.stdRates;
    const parts = botUsageBilled(std.usage) ? std.usageParts
      : [{ model: std.billedModel || plan.pmModel, usage: estimatedUsage(req, plan, messages, null, split.text.length + split.reasoning.length) }];
    metered = await botStandardPartsMilli(env, parts, billed);
  }
  return {
    content: split.text, reasoning: split.reasoning, toolCalls: null, usage: std.usage,
    milli: metered != null ? metered : botCreditsForTask(plan.task) * 1000
  };
}

export function apiOpenAiUsage(usage, cost) {
  const u = usage || {};
  const n = (v) => Math.max(0, Math.round(Number(v) || 0));
  const prompt = n(u.fresh) + n(u.read) + n(u.wrote);
  const completion = n(u.out);
  return {
    prompt_tokens: prompt,
    completion_tokens: completion,
    total_tokens: prompt + completion,
    prompt_tokens_details: { cached_tokens: n(u.read) },
    completion_tokens_details: { reasoning_tokens: 0 },
    cost: cost && cost.charged_usd != null ? cost.charged_usd : 0
  };
}

export function apiUpstreamError(e) {
  if (e instanceof ApiError) return e;
  const msg = String((e && e.message) || "");
  if (e && e.holdLost) {
    return new ApiError(402, "insufficient_quota", "The balance held for this request was spent elsewhere while it ran, so it was stopped. What it generated is charged.",
      { code: "insufficient_balance" });
  }
  if (e && e.clientGone) return new ApiError(400, "invalid_request_error", "The client closed the stream.", { code: "client_closed" });
  const codes = [...msg.matchAll(/HTTP (\d{3})/g)].map((x) => Number(x[1]));
  const status = (e && e.httpStatus) || codes[0] || 0;
  const secs = Math.max(1, Math.ceil((Number(e && e.retryAfterMs) || 10000) / 1000));
  if (status === 503 || status === 529 || (!status && /overloaded|over capacity|no capacity|temporarily unavailable/i.test(msg))) {
    return new ApiError(503, "api_error", "The model provider is overloaded. Retry in " + secs + " s.",
      { code: "upstream_overloaded", headers: { "Retry-After": String(secs) } });
  }
  if (status === 429 || /rate[- ]?limit|too many requests/i.test(msg)) {
    return new ApiError(429, "rate_limit_error", "The model provider rate-limited this request. Retry in " + secs + " s.",
      { code: "upstream_rate_limited", headers: { "Retry-After": String(secs) } });
  }
  if (status >= 400 && status < 500) {
    return new ApiError(400, "invalid_request_error", "The model provider rejected the request (HTTP " + status + "). Check the model's supported parameters and your messages.",
      { code: "upstream_rejected" });
  }
  if (/empty reply/i.test(msg)) return new ApiError(502, "api_error", "The model returned an empty reply.", { code: "upstream_error" });
  return new ApiError(502, "api_error", "The model provider did not return an answer" + (status ? " (HTTP " + status + ")" : "") + ".", { code: "upstream_error" });
}

async function prepFailMilli(api, req, plan, btc) {
  let milli = 0;
  try {
    if (req.webSearched) milli += botMilliForUsd(API_WEB_SEARCH_USD, btc, plan.tier === "pro" ? BOT_PRO_SATS_PER_CREDIT : BOT_SATS_PER_CREDIT);
    if (plan.classifyUsage) {
      const rates = await botStandardRates(api.env, BOT_MODEL_UTILITY);
      if (rates) milli += (await botStandardPartsMilli(api.env, [{ model: BOT_MODEL_UTILITY, usage: plan.classifyUsage }], rates)) || 0;
    }
  } catch (e) { }
  return milli > 0 ? Math.max(BOT_MIN_CHARGE_MILLI, milli) : 0;
}

function goneCheck(api, draft, bill) {
  const signal = api.request && api.request.signal;
  return () => !!(signal && signal.aborted) || !!(draft && draft.gone) || !!(bill && bill.holdLost);
}

function holdLostError() {
  const e = new Error("The balance held for this request is no longer available.");
  e.holdLost = true;
  e.abortUpstream = true;
  return e;
}

function watchedDraft(draft, gone, bill, seen) {
  if (!draft) return null;
  return {
    push(t) { return draft.push(t); },
    reset() { return draft.reset(); },
    delta(kind, piece) {
      if (bill && bill.holdLost) throw holdLostError();
      if (typeof piece === "string") seen.chars += piece.length;
      if (seen.tick) seen.tick();
      return draft.delta(kind, piece);
    },
    accepted() {
      if (seen.accept) seen.accept();
    },
    get committed() { return !!draft.committed || gone(); }
  };
}

function settleWhenGone(api, sink, settle) {
  const signal = api.request && api.request.signal;
  const st = { timer: null, over: false };
  const fire = () => {
    st.timer = null;
    if (st.over) return;
    st.over = true;
    api.waitUntil(Promise.resolve().then(settle).catch(() => { }));
  };
  const arm = () => {
    if (st.over || st.timer) return;
    st.timer = setTimeout(fire, Math.max(0, Number(API_TIMING.goneSettleMs) || 0));
  };
  if (sink && sink.draft && typeof sink.draft.onGone === "function") sink.draft.onGone(arm);
  if (signal && typeof signal.addEventListener === "function") {
    if (signal.aborted) arm();
    else signal.addEventListener("abort", arm);
  }
  return () => {
    st.over = true;
    if (st.timer) clearTimeout(st.timer);
    st.timer = null;
    if (signal && typeof signal.removeEventListener === "function") signal.removeEventListener("abort", arm);
  };
}

export function apiChatRun(api, req, sink) {
  const job = chatRun(api, req, sink);
  api.waitUntil(job.then(() => { }, () => { }));
  return job;
}

async function chatRun(api, req, sink) {
  const started = Date.now();
  apiCheckNesting({ tools: req.tools, messages: req.messages, sampling: req.sampling });
  const btc = await botBtcPrice();
  const plan = await planRun(api, req, btc);
  let messages = req.messages;
  const cutMilli = async (chars) => {
    const est = estimatedUsage(req, plan, messages, null, chars);
    const cut = plan.tier === "pro" ? { usage: est } : { usageParts: [{ model: plan.pmModel, usage: est }] };
    const extraMilli = await prepFailMilli(api, req, plan, btc);
    let milli = 0;
    try { milli = await botFailedSpendMilli(api.env, cut, plan.model, plan.stdRates); } catch (e) { milli = 0; }
    return { est, milli: milli + extraMilli };
  };
  const bill = await apiBillOpen(api, {
    tier: plan.tier, reserveMilli: plan.reserveMilli, refresh: true, history: { type: req.type || "chat", model: req.resolved.id }
  });
  const gone = goneCheck(api, sink && sink.draft, bill);
  const seen = { chars: 0, billed: false, tick: null, accept: null, accepted: false };
  const expiryMilli = async (chars) => {
    if (seen.accepted) return (await cutMilli(chars)).milli;
    return prepFailMilli(api, req, plan, btc);
  };
  const mark = { at: Date.now(), busy: false, again: false };
  const checkpoint = () => {
    if (bill.done) return;
    if (mark.busy) {
      mark.again = true;
      return;
    }
    mark.at = Date.now();
    mark.busy = true;
    mark.again = false;
    api.waitUntil(expiryMilli(seen.chars).then((milli) => apiBillCheckpoint(api, bill, milli)).catch(() => { }).then(() => {
      mark.busy = false;
      if (mark.again) checkpoint();
    }));
  };
  seen.tick = () => {
    if (!seen.accepted) {
      seen.accept();
      return;
    }
    if (Date.now() - mark.at >= Math.max(0, Number(API_BILL_TIMING.checkpointMs) || 0)) checkpoint();
  };
  seen.accept = () => {
    if (seen.accepted) return;
    seen.accepted = true;
    checkpoint();
  };
  const draft = watchedDraft(sink && sink.draft ? sink.draft : null, gone, bill, seen);
  let web = null;
  let got = null;
  let failure = null;
  const record = (settled, status, usage) => {
    if (seen.billed && !usage) return;
    api.waitUntil(apiRecordQuery(api, {
      bill, type: req.type || "chat", model: req.resolved.id, usage: usage || (got ? got.usage : (failure && failure.usage) || null),
      milli: settled.chargedMilli, tier: plan.tier, status, web: !!(web && web.context), task: plan.task || null,
      ms: Date.now() - started, btcUsd: btc, err: status === "error" ? "upstream" : null
    }));
  };
  const stopGone = settleWhenGone(api, sink, async () => {
    if (bill.done) return;
    const cut = await cutMilli(seen.chars);
    if (bill.done) return;
    const pending = apiBillSettle(api, bill, cut.milli);
    seen.billed = true;
    record(await pending, "error", cut.est);
  });
  try {
    web = await webContext(api, req, plan.tier);
    messages = withWeb(req.messages, web);
    if (req.webSearched) checkpoint();
    try {
      got = plan.tier === "pro" ? await runPro(api, req, plan, messages, draft, gone) : await runStandard(api, req, plan, messages, draft, gone);
    } catch (e) {
      failure = e;
    }
    if (failure && (failure.refusal || failure.reasoning) && !failure.clientGone) {
      let milli = 0;
      try { milli = await botFailedSpendMilli(api.env, failure, plan.model, plan.stdRates); } catch (e) { milli = 0; }
      got = { content: "", reasoning: failure.reasoning || "", toolCalls: null, usage: failure.usage || botUsageZero(), milli,
        finish: failure.refusal ? "content_filter" : "length" };
      failure = null;
    }
  } catch (e) {
    failure = e;
  }
  stopGone();
  if (failure && typeof failure === "object" && failure.usageEstimated) {
    const est = estimatedUsage(req, plan, messages, failure.usage, failure.streamed ? failure.streamed.chars : 0);
    if (plan.tier === "pro") failure.usage = est;
    else failure.usageParts = [{ model: plan.pmModel, usage: est }];
  }
  if (failure) {
    const extraMilli = bill.done ? 0 : await prepFailMilli(api, req, plan, btc);
    const settled = bill.done ? { chargedMilli: 0 } : await apiBillFail(api, bill, failure, { proModel: plan.model, stdRates: plan.stdRates, extraMilli });
    record(settled, "error");
    throw apiUpstreamError(failure);
  }
  const settled = await apiBillSettle(api, bill, got.milli + (req.webSearched ? searchFeeMilli(plan.tier, btc) : 0));
  const cost = await apiCostObject(api, bill, settled, btc);
  record(settled, "ok");
  const finish = got.finish || (got.toolCalls && got.toolCalls.length ? "tool_calls"
    : (Number(got.usage && got.usage.out) >= plan.maxOut ? "length" : "stop"));
  return {
    id: req.completionId,
    created: req.created,
    model: req.resolved.id,
    tier: plan.tier,
    content: got.content,
    reasoning: got.reasoning,
    toolCalls: got.toolCalls,
    finish,
    usage: got.usage,
    cost,
    btcUsd: btc,
    web: web && web.context ? { query: web.query, sources: web.sources } : null
  };
}

export function apiNymbotObject(out) {
  const o = Object.assign({}, out.cost);
  delete o.charged_usd;
  if (out.web) o.web_search = { sources: out.web.sources };
  return o;
}

function annotations(out) {
  if (!out.web || !out.web.sources.length) return null;
  const list = out.web.sources.filter((s) => s && s.url).map((s) => ({
    type: "url_citation", url_citation: { url: s.url, title: s.title || "", start_index: 0, end_index: 0 }
  }));
  return list.length ? list : null;
}

export function apiCompletionObject(out) {
  const message = { role: "assistant", content: out.toolCalls && out.toolCalls.length && !out.content ? null : out.content };
  if (out.reasoning) message.reasoning_content = out.reasoning;
  if (out.toolCalls && out.toolCalls.length) message.tool_calls = out.toolCalls;
  const ann = annotations(out);
  if (ann) message.annotations = ann;
  return {
    id: out.id,
    object: "chat.completion",
    created: out.created,
    model: out.model,
    choices: [{ index: 0, message, logprobs: null, finish_reason: out.finish }],
    usage: apiOpenAiUsage(out.usage, out.cost),
    nymbot: apiNymbotObject(out)
  };
}

export function apiThinkSplitter(emit) {
  const OPEN = "<think>";
  const CLOSE = "</think>";
  let mode = "start";
  let buf = "";
  const push = (piece) => {
    buf += piece;
    while (buf) {
      if (mode === "start" || mode === "lead") {
        const lead = buf.replace(/^\s+/, "");
        if (!lead) return;
        if (mode === "start" && lead.startsWith(OPEN)) {
          mode = "think";
          buf = lead.slice(OPEN.length).replace(/^\s+/, "");
          continue;
        }
        if (mode === "start" && OPEN.startsWith(lead)) return;
        if (mode === "lead") buf = lead;
        mode = "text";
        continue;
      }
      if (mode === "think") {
        const at = buf.indexOf(CLOSE);
        if (at >= 0) {
          const inner = buf.slice(0, at).replace(/\s+$/, "");
          if (inner) emit("reasoning", inner);
          buf = buf.slice(at + CLOSE.length);
          mode = "lead";
          continue;
        }
        let keep = 0;
        for (let k = Math.min(CLOSE.length - 1, buf.length); k > 0; k--) {
          if (CLOSE.startsWith(buf.slice(-k))) { keep = k; break; }
        }
        const outText = buf.slice(0, buf.length - keep);
        if (outText) emit("reasoning", outText);
        buf = buf.slice(buf.length - keep);
        return;
      }
      emit("text", buf);
      buf = "";
      return;
    }
  };
  const end = () => {
    if (buf && mode === "think") emit("reasoning", buf);
    else if (buf && buf.trim()) emit("text", buf);
    buf = "";
  };
  return { push, end };
}

export function apiChatChunker(sse, base) {
  let started = false;
  const state = { text: false, reasoning: false };
  const chunk = (delta, finish) => Object.assign({}, base, { choices: [{ index: 0, delta, finish_reason: finish == null ? null : finish }] });
  const start = () => {
    if (started) return;
    started = true;
    sse.data(chunk({ role: "assistant", content: "" }));
  };
  const emit = (kind, piece) => {
    if (!piece) return;
    start();
    if (kind === "reasoning") {
      state.reasoning = true;
      sse.data(chunk({ reasoning_content: piece }));
    } else {
      state.text = true;
      sse.data(chunk({ content: piece }));
    }
  };
  const splitter = apiThinkSplitter(emit);
  return {
    state,
    delta(kind, piece) {
      if (kind === "text") splitter.push(piece);
      else emit("reasoning", piece);
    },
    finish(out, includeUsage) {
      splitter.end();
      if (!state.reasoning && out.reasoning) emit("reasoning", out.reasoning);
      if (!state.text && out.content) emit("text", out.content);
      start();
      if (out.toolCalls && out.toolCalls.length) {
        sse.data(chunk({ tool_calls: out.toolCalls.map((c, i) => ({ index: i, id: c.id, type: "function", function: { name: c.function.name, arguments: c.function.arguments } })) }));
      }
      sse.data(chunk({}, out.finish));
      if (includeUsage) {
        sse.data(Object.assign({}, base, { choices: [], usage: apiOpenAiUsage(out.usage, out.cost), nymbot: apiNymbotObject(out) }));
      }
      sse.data("[DONE]");
    }
  };
}

export function apiStreamDraft(sse, onDelta) {
  let committed = false;
  let firstSeen = null;
  const first = new Promise((resolve) => { firstSeen = resolve; });
  return {
    first,
    committed: () => committed,
    draft: {
      push() { },
      reset() { },
      delta(kind, piece) {
        if (sse.cancelled || sse.closed) throw apiClientGone();
        if (!piece) return;
        committed = true;
        onDelta(kind, piece);
        firstSeen();
      },
      get committed() { return committed; },
      get gone() { return !!(sse.cancelled || sse.closed); },
      onGone(fn) {
        if (sse.cancelled) fn();
        else sse.onCancel(fn);
      }
    }
  };
}

export async function apiStreamRun(api, sse, gate, run, onDone) {
  let result = null;
  const job = Promise.resolve().then(() => run(gate.draft)).then((out) => { result = { out }; }, (error) => { result = { error }; });
  api.waitUntil(job);
  let timer = null;
  const wait = new Promise((resolve) => { timer = setTimeout(resolve, API_TIMING.firstByteWaitMs); });
  await Promise.race([gate.first, job, wait]);
  clearTimeout(timer);
  if (result && result.error && !gate.committed()) {
    sse.close();
    throw result.error;
  }
  sse.keepAlive();
  api.waitUntil(job.then(() => {
    try { onDone(result); } catch (e) { }
    sse.close();
  }));
  return new Response(sse.stream, { status: 200, headers: apiSseHeaders() });
}

async function streamCompletion(api, req) {
  const sse = apiSseStream();
  const base = { id: req.completionId, object: "chat.completion.chunk", created: req.created, model: req.resolved.id };
  const chunker = apiChatChunker(sse, base);
  const gate = apiStreamDraft(sse, (kind, piece) => chunker.delta(kind, piece));
  return apiStreamRun(api, sse, gate, (draft) => apiChatRun(api, req, { draft }), (result) => {
    if (result.error) {
      if (!sse.cancelled) sse.data(apiErrorBody(apiUpstreamError(result.error), "openai"));
      return;
    }
    chunker.finish(result.out, req.includeUsage);
  });
}

async function chatCompletions(api) {
  const req = await apiChatPrepare(api, api.body);
  if (req.stream) return streamCompletion(api, req);
  const out = await apiChatRun(api, req, null);
  return apiJson(apiCompletionObject(out), 200, apiCostHeaders(out.cost));
}

export function registerChat(r) {
  r.add("POST", "/chat/completions", chatCompletions, { auth: "key" });
}
