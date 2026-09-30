import { BOT_IMAGE_RESERVE_TOKENS } from "./bot.js";
import { apiChatPrepare, apiChatRun, apiStreamDraft, apiStreamRun, apiThinkSplitter, apiNymbotObject, apiUpstreamError } from "./_apichat.js";
import { ApiError, apiBad, apiJson, apiRandomId, apiSseStream, apiErrorBody, API_TIMING } from "./_apihttp.js";
import { apiCostHeaders } from "./_apibill.js";
import { apiResolveModel } from "./_apimodels.js";

const CHARS_PER_TOKEN = 4;
const CLAUDE_FAMILY = /claude-(?:[0-9]+(?:[-.][0-9]+)*-)?(opus|sonnet|haiku)\b/;
const STOP_REASONS = { tool_calls: "tool_use", length: "max_tokens", content_filter: "refusal", stop: "end_turn" };

function versionOf(s) {
  return (String(s).match(/[0-9]+/g) || []).filter((n) => n.length < 8).map(Number);
}

function versionCmp(a, b) {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] || 0;
    const y = b[i] || 0;
    if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

async function tryResolve(env, name) {
  try {
    return await apiResolveModel(env, name);
  } catch (e) {
    if (e instanceof ApiError && e.status === 404) return null;
    throw e;
  }
}

export async function apiClaudeModelName(env, raw) {
  const name = typeof raw === "string" ? raw.trim() : "";
  if (!name) throw apiBad("`model` is required.", "model", "missing_required_parameter");
  if (await tryResolve(env, name)) return name;
  const base = name.toLowerCase()
    .replace(/\[[a-z0-9]+\]$/, "")
    .replace(/^anthropic[/.]/, "")
    .replace(/-latest$/, "")
    .replace(/-v[0-9]+(?::[0-9]+)?$/, "")
    .replace(/-[0-9]{8}$/, "");
  const dotted = base.replace(/([0-9])-([0-9])/g, "$1.$2");
  const dashed = base.replace(/([0-9])\.([0-9])/g, "$1-$2");
  const tries = [base, dashed, dotted, "anthropic/" + base, "anthropic/" + dotted];
  for (const t of [...new Set(tries)]) {
    if (t && t !== name && await tryResolve(env, t)) return t;
  }
  const fam = CLAUDE_FAMILY.exec(base);
  if (fam) {
    const family = "claude-" + fam[1];
    const hit = await tryResolve(env, family);
    if (hit && hit.model && versionCmp(versionOf(base), versionOf(hit.key || hit.id)) <= 0) return family;
  }
  throw new ApiError(404, "not_found_error", "The model `" + name + "` does not exist or is not available on Nymbot. List models with GET /api/v1/models.",
    { code: "model_not_found", param: "model" });
}

function blockText(content, where) {
  if (typeof content === "string") return content;
  if (content == null) return "";
  if (!Array.isArray(content)) throw apiBad("`" + where + "` must be a string or an array of blocks.", where);
  return content.map((b, i) => {
    if (!b || b.type !== "text" || typeof b.text !== "string") throw apiBad("`" + where + "[" + i + "]` must be a text block.", where);
    return b.text;
  }).join("\n\n");
}

function imagePart(b, where) {
  const s = b.source || {};
  if (s.type === "base64" && typeof s.data === "string" && typeof s.media_type === "string") {
    return { type: "image_url", image_url: { url: "data:" + s.media_type + ";base64," + s.data } };
  }
  if (s.type === "url" && typeof s.url === "string") return { type: "image_url", image_url: { url: s.url } };
  throw apiBad("Image blocks need a base64 or url source.", where, "unsupported_content");
}

function toolResult(b, where, pendingImages) {
  let text = "";
  if (typeof b.content === "string") text = b.content;
  else if (Array.isArray(b.content)) {
    const texts = [];
    b.content.forEach((c, i) => {
      if (c && c.type === "text" && typeof c.text === "string") texts.push(c.text);
      else if (c && c.type === "image") pendingImages.push(imagePart(c, where + ".content[" + i + "]"));
      else throw apiBad("Tool results may hold text and image blocks only.", where, "unsupported_content");
    });
    text = texts.join("\n\n");
  }
  if (b.is_error === true) text = "Error: " + text;
  if (typeof b.tool_use_id !== "string" || !b.tool_use_id) throw apiBad("A tool_result block needs `tool_use_id`.", where);
  return { role: "tool", tool_call_id: b.tool_use_id, content: text };
}

function userMessages(m, at) {
  if (typeof m.content === "string") return [{ role: "user", content: m.content }];
  if (!Array.isArray(m.content)) throw apiBad("`content` must be a string or an array of blocks.", at + ".content");
  const tools = [];
  const parts = [];
  const pendingImages = [];
  m.content.forEach((b, i) => {
    const where = at + ".content[" + i + "]";
    if (!b || typeof b !== "object") throw apiBad("Each content block must be an object.", where);
    if (b.type === "text") {
      if (typeof b.text !== "string") throw apiBad("A text block needs `text`.", where);
      parts.push({ type: "text", text: b.text });
    } else if (b.type === "image") parts.push(imagePart(b, where));
    else if (b.type === "tool_result") tools.push(toolResult(b, where, pendingImages));
    else if (b.type === "thinking" || b.type === "redacted_thinking") return;
    else throw apiBad("Content blocks of type `" + String(b.type) + "` are not supported; send text, images, tool_use and tool_result.", where, "unsupported_content");
  });
  const all = pendingImages.concat(parts);
  const out = tools.slice();
  if (all.length) {
    const onlyOne = all.length === 1 && all[0].type === "text";
    out.push({ role: "user", content: onlyOne ? all[0].text : all });
  } else if (!tools.length) out.push({ role: "user", content: "" });
  return out;
}

function assistantMessage(m, at) {
  if (typeof m.content === "string") return { role: "assistant", content: m.content };
  if (!Array.isArray(m.content)) throw apiBad("`content` must be a string or an array of blocks.", at + ".content");
  const texts = [];
  const calls = [];
  m.content.forEach((b, i) => {
    const where = at + ".content[" + i + "]";
    if (!b || typeof b !== "object") throw apiBad("Each content block must be an object.", where);
    if (b.type === "text") texts.push(String(b.text || ""));
    else if (b.type === "tool_use") {
      if (typeof b.name !== "string" || !b.name) throw apiBad("A tool_use block needs `name`.", where);
      calls.push({ id: String(b.id || ("toolu_" + i)), type: "function", function: { name: b.name, arguments: JSON.stringify(b.input == null ? {} : b.input) } });
    } else if (b.type === "thinking" || b.type === "redacted_thinking" || b.type === "server_tool_use" || /_tool_result$/.test(String(b.type))) return;
    else throw apiBad("Assistant blocks of type `" + String(b.type) + "` are not supported.", where, "unsupported_content");
  });
  const out = { role: "assistant", content: texts.length ? texts.join("\n\n") : (calls.length ? null : "") };
  if (calls.length) out.tool_calls = calls;
  return out;
}

function translateTools(tools) {
  if (tools == null) return undefined;
  if (!Array.isArray(tools)) throw apiBad("`tools` must be an array.", "tools");
  return tools.map((t, i) => {
    if (!t || typeof t !== "object") throw apiBad("Each tool must be an object.", "tools");
    if (t.type && t.type !== "custom") {
      if (/^web_search/.test(t.type)) return { type: "web_search" };
      throw apiBad("Anthropic-defined tools (`" + t.type + "`) are not supported; define the tool with a name and an input_schema instead.", "tools", "unsupported_tool");
    }
    if (typeof t.name !== "string" || !t.name) throw apiBad("Each tool needs a `name`.", "tools[" + i + "].name");
    const f = { name: t.name, parameters: t.input_schema && typeof t.input_schema === "object" ? t.input_schema : { type: "object", properties: {} } };
    if (typeof t.description === "string") f.description = t.description;
    return { type: "function", function: f };
  });
}

function translateToolChoice(tc) {
  if (tc == null) return { choice: undefined, parallel: undefined };
  if (typeof tc !== "object") throw apiBad("`tool_choice` must be an object such as {\"type\":\"auto\"}.", "tool_choice");
  const parallel = tc.disable_parallel_tool_use === true ? false : undefined;
  if (tc.type === "auto") return { choice: "auto", parallel };
  if (tc.type === "any") return { choice: "required", parallel };
  if (tc.type === "none") return { choice: "none", parallel };
  if (tc.type === "tool" && typeof tc.name === "string") return { choice: { type: "function", function: { name: tc.name } }, parallel };
  throw apiBad("`tool_choice.type` must be auto, any, tool or none.", "tool_choice");
}

function effortFor(body) {
  const t = body.thinking;
  if (!t || typeof t !== "object" || t.type === "disabled") return undefined;
  if (t.type === "adaptive") {
    const e = body.output_config && body.output_config.effort;
    if (e === "low" || e === "medium" || e === "high") return e;
    return "high";
  }
  if (t.type !== "enabled") throw apiBad("`thinking.type` must be enabled, adaptive or disabled.", "thinking");
  const b = Number(t.budget_tokens);
  if (!Number.isFinite(b) || b < 1) throw apiBad("`thinking.budget_tokens` must be a positive integer.", "thinking.budget_tokens");
  if (b >= 16384) return "high";
  if (b >= 8192) return "medium";
  if (b >= 2048) return "low";
  return "minimal";
}

function translate(body, modelName, counting) {
  if (!counting) {
    const n = body.max_tokens;
    if (n == null) throw apiBad("`max_tokens` is required.", "max_tokens", "missing_required_parameter");
    if (typeof n !== "number" || !Number.isInteger(n) || n < 1) throw apiBad("`max_tokens` must be a positive integer.", "max_tokens");
  }
  if (!Array.isArray(body.messages) || !body.messages.length) {
    throw apiBad("`messages` must be a non-empty array.", "messages", "missing_required_parameter");
  }
  const messages = [];
  const system = blockText(body.system, "system");
  if (system) messages.push({ role: "system", content: system });
  body.messages.forEach((m, i) => {
    const at = "messages[" + i + "]";
    if (!m || typeof m !== "object") throw apiBad("Each message must be an object.", at);
    if (m.role === "user") messages.push(...userMessages(m, at));
    else if (m.role === "assistant") messages.push(assistantMessage(m, at));
    else throw apiBad("`role` must be user or assistant; put system text in the top-level `system`.", at + ".role", "invalid_role");
  });
  const tc = translateToolChoice(body.tool_choice);
  const tools = translateTools(body.tools);
  const out = { model: modelName, messages };
  if (tools && tools.length) {
    out.tools = tools;
    if (tc.choice !== undefined) out.tool_choice = tc.choice;
    if (tc.parallel !== undefined) out.parallel_tool_calls = tc.parallel;
  }
  if (!counting) out.max_tokens = body.max_tokens;
  if (typeof body.temperature === "number") out.temperature = body.temperature;
  if (typeof body.top_p === "number") out.top_p = body.top_p;
  if (body.stop_sequences != null) {
    if (!Array.isArray(body.stop_sequences) || body.stop_sequences.some((s) => typeof s !== "string")) {
      throw apiBad("`stop_sequences` must be an array of strings.", "stop_sequences");
    }
    if (body.stop_sequences.length) out.stop = body.stop_sequences;
  }
  const effort = effortFor(body);
  if (effort) out.reasoning_effort = effort;
  return out;
}

export function apiEstimateTokens(messages, tools) {
  let chars = 0;
  let images = 0;
  for (const m of messages) {
    if (typeof m.content === "string") chars += m.content.length;
    else if (Array.isArray(m.content)) {
      for (const p of m.content) {
        if (p.type === "text") chars += p.text.length;
        else if (p.type === "image_url") images++;
      }
    }
    for (const c of m.tool_calls || []) chars += c.function.name.length + c.function.arguments.length;
  }
  if (tools && tools.length) chars += JSON.stringify(tools).length;
  return Math.ceil(chars / CHARS_PER_TOKEN) + images * BOT_IMAGE_RESERVE_TOKENS;
}

function anthropicUsage(usage) {
  const u = usage || {};
  const n = (v) => Math.max(0, Math.round(Number(v) || 0));
  return { input_tokens: n(u.fresh), cache_creation_input_tokens: n(u.wrote), cache_read_input_tokens: n(u.read), output_tokens: n(u.out) };
}

function toolInput(args) {
  try {
    const v = JSON.parse(args || "{}");
    return v && typeof v === "object" && !Array.isArray(v) ? v : {};
  } catch (e) {
    return {};
  }
}

function messageObject(out) {
  const content = [];
  if (out.reasoning) content.push({ type: "thinking", thinking: out.reasoning, signature: "" });
  if (out.content) content.push({ type: "text", text: out.content });
  for (const c of out.toolCalls || []) content.push({ type: "tool_use", id: c.id, name: c.function.name, input: toolInput(c.function.arguments) });
  return {
    id: out.id,
    type: "message",
    role: "assistant",
    model: out.model,
    content,
    stop_reason: STOP_REASONS[out.finish] || "end_turn",
    stop_sequence: null,
    usage: anthropicUsage(out.usage),
    nymbot: apiNymbotObject(out)
  };
}

function anthropicWriter(sse, req, estimate) {
  const send = (type, obj) => sse.event(type, Object.assign({ type }, obj || {}));
  let opened = false;
  let pinged = false;
  let timer = null;
  let index = 0;
  let cur = null;
  const streamed = { text: false, reasoning: false };
  const stopTimer = () => { if (timer) { clearInterval(timer); timer = null; } };
  sse.onCancel(stopTimer);
  const open = () => {
    if (opened) return;
    opened = true;
    send("message_start", {
      message: {
        id: req.completionId, type: "message", role: "assistant", model: req.resolved.id, content: [], stop_reason: null, stop_sequence: null,
        usage: { input_tokens: estimate, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0 }
      }
    });
    timer = setInterval(() => {
      if (sse.closed) { stopTimer(); return; }
      send("ping");
    }, Math.max(5, API_TIMING.keepAliveMs));
  };
  const ping = () => {
    if (pinged) return;
    pinged = true;
    send("ping");
  };
  const startBlock = (block) => {
    cur = { index: index++, kind: block.type };
    send("content_block_start", { index: cur.index, content_block: block });
    ping();
  };
  const stopBlock = () => {
    if (!cur) return;
    send("content_block_stop", { index: cur.index });
    cur = null;
  };
  const emit = (kind, piece) => {
    if (!piece) return;
    open();
    const type = kind === "reasoning" ? "thinking" : "text";
    if (cur && cur.kind !== type) stopBlock();
    if (!cur) startBlock(type === "thinking" ? { type: "thinking", thinking: "", signature: "" } : { type: "text", text: "" });
    streamed[kind === "reasoning" ? "reasoning" : "text"] = true;
    send("content_block_delta", { index: cur.index, delta: type === "thinking" ? { type: "thinking_delta", thinking: piece } : { type: "text_delta", text: piece } });
  };
  const splitter = apiThinkSplitter(emit);
  return {
    open,
    delta(kind, piece) {
      if (kind === "text") splitter.push(piece);
      else emit("reasoning", piece);
    },
    finish(out) {
      splitter.end();
      open();
      if (!streamed.reasoning && out.reasoning) emit("reasoning", out.reasoning);
      if (!streamed.text && out.content) emit("text", out.content);
      stopBlock();
      for (const c of out.toolCalls || []) {
        startBlock({ type: "tool_use", id: c.id, name: c.function.name, input: {} });
        send("content_block_delta", { index: cur.index, delta: { type: "input_json_delta", partial_json: JSON.stringify(toolInput(c.function.arguments)) } });
        stopBlock();
      }
      ping();
      send("message_delta", {
        delta: { stop_reason: STOP_REASONS[out.finish] || "end_turn", stop_sequence: null },
        usage: anthropicUsage(out.usage),
        nymbot: apiNymbotObject(out)
      });
      send("message_stop");
      stopTimer();
    },
    fail(error) {
      open();
      stopTimer();
      if (!sse.cancelled) send("error", { error: apiErrorBody(apiUpstreamError(error), "anthropic").error });
    }
  };
}

async function prepare(api) {
  const body = api.body;
  const name = await apiClaudeModelName(api.env, body.model);
  const req = await apiChatPrepare(api, translate(body, name, false));
  req.type = "messages";
  req.stream = body.stream === true;
  req.completionId = apiRandomId("msg_", 24);
  return req;
}

async function messages(api) {
  const req = await prepare(api);
  if (!req.stream) {
    const out = await apiChatRun(api, req, null);
    return apiJson(messageObject(out), 200, apiCostHeaders(out.cost));
  }
  const sse = apiSseStream();
  const writer = anthropicWriter(sse, req, apiEstimateTokens(req.messages, req.tools));
  const gate = apiStreamDraft(sse, (kind, piece) => writer.delta(kind, piece));
  const res = await apiStreamRun(api, sse, gate, (draft) => apiChatRun(api, req, { draft }), (result) => {
    if (result.error) writer.fail(result.error);
    else writer.finish(result.out);
  });
  writer.open();
  return res;
}

async function countTokens(api) {
  const body = api.body;
  const name = await apiClaudeModelName(api.env, body.model);
  const t = translate(body, name, true);
  return apiJson({ input_tokens: apiEstimateTokens(t.messages, t.tools) });
}

export function registerMessages(r) {
  r.add("POST", "/messages", messages, { auth: "key", format: "anthropic" });
  r.add("POST", "/messages/count_tokens", countTokens, { auth: "key", format: "anthropic", spends: false });
}
