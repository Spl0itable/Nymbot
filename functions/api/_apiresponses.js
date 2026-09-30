import { apiChatPrepare, apiCheckSampling, apiChatRun, apiStreamDraft, apiStreamRun, apiThinkSplitter, apiNymbotObject, apiUpstreamError, apiOpenAiUsage } from "./_apichat.js";
import { apiBad, apiJson, apiRandomId, apiSseStream, apiErrorBody } from "./_apihttp.js";
import { apiCostHeaders } from "./_apibill.js";

const REFUSED = {
  previous_response_id: "`previous_response_id` is not supported: Nymbot does not store responses. Send the full input (earlier messages and tool outputs) with every request.",
  conversation: "`conversation` is not supported: Nymbot does not store conversations. Send the full input with every request.",
  background: "`background` is not supported: Nymbot answers synchronously or by streaming."
};
const WEB_TOOL = /^web_search(?:_preview)?(?:_[0-9_]+)?$/;
const SKIPPED_ITEMS = Object.assign(Object.create(null), { reasoning: 1, web_search_call: 1 });
const EFFORT_ALIASES = Object.assign(Object.create(null), { xhigh: "high", max: "high" });

function contentPart(p, where, role) {
  if (!p || typeof p !== "object") throw apiBad("Each content part must be an object.", where);
  if (p.type === "input_text" || p.type === "output_text" || p.type === "text") {
    if (typeof p.text !== "string") throw apiBad("A text part needs `text`.", where);
    return { type: "text", text: p.text };
  }
  if (p.type === "refusal") return { type: "text", text: String(p.refusal || "") };
  if (p.type === "input_image") {
    if (role !== "user") throw apiBad("Only user messages may carry images.", where, "unsupported_content");
    const url = typeof p.image_url === "string" ? p.image_url : (p.image_url && p.image_url.url);
    if (!url) throw apiBad("`input_image` needs an `image_url` (http(s) or data URL); file ids are not supported.", where, "unsupported_content");
    const out = { type: "image_url", image_url: { url } };
    if (p.detail) out.image_url.detail = p.detail;
    return out;
  }
  throw apiBad("Content parts of type `" + String(p.type) + "` are not supported; send text and images.", where, "unsupported_content");
}

function itemMessage(item, where) {
  const role = item.role === "developer" ? "system" : item.role;
  if (!["user", "assistant", "system"].includes(role)) throw apiBad("`role` must be user, assistant, system or developer.", where + ".role", "invalid_role");
  if (typeof item.content === "string") return { role, content: item.content };
  if (!Array.isArray(item.content)) throw apiBad("`content` must be a string or an array of parts.", where + ".content");
  const parts = item.content.map((p, j) => contentPart(p, where + ".content[" + j + "]", role));
  if (parts.every((p) => p.type === "text")) {
    if (role !== "user" || parts.length === 1) return { role, content: parts.map((p) => p.text).join(role === "user" ? "\n" : "") };
  }
  return { role, content: parts };
}

function outputText(output, where, images) {
  if (typeof output === "string") return output;
  if (output == null) return "";
  if (!Array.isArray(output)) return JSON.stringify(output);
  const texts = [];
  output.forEach((p, j) => {
    const part = contentPart(p, where + ".output[" + j + "]", "user");
    if (part.type === "text") texts.push(part.text);
    else images.push(part);
  });
  return texts.join("\n");
}

function inputMessages(input) {
  if (typeof input === "string") return [{ role: "user", content: input }];
  if (!Array.isArray(input) || !input.length) throw apiBad("`input` must be a string or a non-empty array of items.", "input", "missing_required_parameter");
  const out = [];
  let images = [];
  const flush = () => {
    if (images.length) out.push({ role: "user", content: images });
    images = [];
  };
  input.forEach((item, i) => {
    const at = "input[" + i + "]";
    if (!item || typeof item !== "object") throw apiBad("Each input item must be an object.", at);
    const type = item.type || (item.role ? "message" : "");
    if (SKIPPED_ITEMS[type]) return;
    if (type === "function_call_output") {
      if (typeof item.call_id !== "string" || !item.call_id) throw apiBad("A function_call_output item needs `call_id`.", at + ".call_id");
      out.push({ role: "tool", tool_call_id: item.call_id, content: outputText(item.output, at, images) });
      return;
    }
    flush();
    if (type === "message") {
      out.push(itemMessage(item, at));
    } else if (type === "function_call") {
      if (typeof item.name !== "string" || !item.name) throw apiBad("A function_call item needs `name`.", at + ".name");
      const call = {
        id: String(item.call_id || item.id || ("call_" + i)), type: "function",
        function: { name: item.name, arguments: typeof item.arguments === "string" ? item.arguments : JSON.stringify(item.arguments || {}) }
      };
      const last = out[out.length - 1];
      if (last && last.role === "assistant") last.tool_calls = (last.tool_calls || []).concat([call]);
      else out.push({ role: "assistant", content: null, tool_calls: [call] });
    } else if (type === "item_reference") {
      throw apiBad("`item_reference` needs stored items, which Nymbot does not keep. Send the item itself.", at, "unsupported_parameter");
    } else {
      throw apiBad("Input items of type `" + String(type) + "` are not supported.", at, "unsupported_content");
    }
  });
  flush();
  if (!out.length) throw apiBad("`input` holds no messages.", "input", "missing_required_parameter");
  return out;
}

function translateTools(tools) {
  if (tools == null) return undefined;
  if (!Array.isArray(tools)) throw apiBad("`tools` must be an array.", "tools");
  return tools.map((t) => {
    if (t && typeof t.type === "string" && WEB_TOOL.test(t.type)) return { type: "web_search" };
    if (!t || t.type !== "function") throw apiBad("Only `function` and `web_search` tools are supported.", "tools", "unsupported_tool");
    const src = t.function && typeof t.function === "object" ? t.function : t;
    const f = { name: src.name, description: src.description, parameters: src.parameters };
    if (typeof src.strict === "boolean") f.strict = src.strict;
    if (typeof f.description !== "string") delete f.description;
    return { type: "function", function: f };
  });
}

function echoTools(tools) {
  if (!Array.isArray(tools)) return [];
  return tools.map((t) => {
    if (t.type !== "function") return { type: t.type };
    const src = t.function && typeof t.function === "object" ? t.function : t;
    const out = { type: "function", name: src.name };
    if (typeof src.description === "string") out.description = src.description;
    if (src.parameters !== undefined) out.parameters = src.parameters;
    if (typeof src.strict === "boolean") out.strict = src.strict;
    return out;
  });
}

function translateToolChoice(tc) {
  if (tc == null || typeof tc === "string") return tc;
  if (tc.type === "function" && typeof tc.name === "string") return { type: "function", function: { name: tc.name } };
  if (tc.type === "allowed_tools" && typeof tc.mode === "string") return tc.mode;
  if (typeof tc.type === "string" && WEB_TOOL.test(tc.type)) return "auto";
  return tc;
}

function translateFormat(body) {
  const f = body.text && typeof body.text === "object" ? body.text.format : null;
  if (!f || typeof f !== "object") return body.response_format;
  if (f.type === "json_schema") {
    const js = { name: f.name };
    if (typeof f.description === "string") js.description = f.description;
    js.schema = f.schema;
    if (typeof f.strict === "boolean") js.strict = f.strict;
    return { type: "json_schema", json_schema: js };
  }
  if (f.type === "json_object") return { type: "json_object" };
  return undefined;
}

function translate(body) {
  for (const k of Object.keys(REFUSED)) {
    if (body[k] != null && body[k] !== false) throw apiBad(REFUSED[k], k, "unsupported_parameter");
  }
  if (body.input == null) throw apiBad("`input` is required.", "input", "missing_required_parameter");
  const messages = inputMessages(body.input);
  if (typeof body.instructions === "string" && body.instructions) messages.unshift({ role: "system", content: body.instructions });
  const out = { model: body.model, messages };
  const tools = translateTools(body.tools);
  if (tools && tools.length) {
    out.tools = tools;
    const tc = translateToolChoice(body.tool_choice);
    if (tc !== undefined) out.tool_choice = tc;
    if (typeof body.parallel_tool_calls === "boolean") out.parallel_tool_calls = body.parallel_tool_calls;
  }
  if (body.max_output_tokens != null) {
    const n = body.max_output_tokens;
    if (typeof n !== "number" || !Number.isInteger(n) || n < 1) throw apiBad("`max_output_tokens` must be a positive integer.", "max_output_tokens");
    out.max_tokens = n;
  }
  if (typeof body.temperature === "number") out.temperature = body.temperature;
  if (typeof body.top_p === "number") out.top_p = body.top_p;
  const fmt = translateFormat(body);
  if (fmt) out.response_format = fmt;
  const r = body.reasoning;
  if (r && typeof r === "object" && typeof r.effort === "string" && r.effort !== "none") out.reasoning_effort = EFFORT_ALIASES[r.effort] || r.effort;
  return out;
}

function annotations(out) {
  if (!out.web || !out.web.sources.length) return [];
  return out.web.sources.filter((s) => s && s.url).map((s) => ({ type: "url_citation", url: s.url, title: s.title || "", start_index: 0, end_index: 0 }));
}

function responsesUsage(usage) {
  const u = apiOpenAiUsage(usage, null);
  return {
    input_tokens: u.prompt_tokens,
    input_tokens_details: { cached_tokens: u.prompt_tokens_details.cached_tokens },
    output_tokens: u.completion_tokens,
    output_tokens_details: { reasoning_tokens: 0 },
    total_tokens: u.total_tokens
  };
}

function statusOf(finish) {
  if (finish === "length") return { status: "incomplete", incomplete_details: { reason: "max_output_tokens" } };
  if (finish === "content_filter") return { status: "incomplete", incomplete_details: { reason: "content_filter" } };
  return { status: "completed", incomplete_details: null };
}

function responseObject(ctx, fields) {
  const body = ctx.body;
  const output = fields.output || [];
  const text = output.filter((i) => i.type === "message").map((i) => i.content.filter((c) => c.type === "output_text").map((c) => c.text).join("")).join("");
  const o = {
    id: ctx.id,
    object: "response",
    created_at: ctx.created,
    status: fields.status,
    background: false,
    error: fields.error || null,
    incomplete_details: fields.incomplete_details || null,
    instructions: typeof body.instructions === "string" ? body.instructions : null,
    max_output_tokens: body.max_output_tokens == null ? null : body.max_output_tokens,
    model: ctx.model,
    output,
    output_text: text,
    parallel_tool_calls: typeof body.parallel_tool_calls === "boolean" ? body.parallel_tool_calls : true,
    previous_response_id: null,
    reasoning: { effort: ctx.effort || null, summary: body.reasoning && typeof body.reasoning.summary === "string" ? body.reasoning.summary : null },
    store: false,
    temperature: typeof body.temperature === "number" ? body.temperature : null,
    text: { format: body.text && body.text.format && typeof body.text.format === "object" && typeof body.text.format.type === "string" ? body.text.format : { type: "text" } },
    tool_choice: body.tool_choice == null ? "auto" : body.tool_choice,
    tools: ctx.tools,
    top_p: typeof body.top_p === "number" ? body.top_p : null,
    truncation: "disabled",
    usage: fields.usage || null,
    user: null,
    metadata: body.metadata && typeof body.metadata === "object" ? body.metadata : {}
  };
  if (fields.nymbot) o.nymbot = fields.nymbot;
  return o;
}

const reasoningItem = (id, text) => ({ id, type: "reasoning", summary: [], content: [{ type: "reasoning_text", text }] });
const messageItem = (id, text, status, ann) => ({
  id, type: "message", status, role: "assistant", content: [{ type: "output_text", text, annotations: ann, logprobs: [] }]
});
const callItem = (id, c, status, args) => ({ id, type: "function_call", status, arguments: args, call_id: c.id, name: c.function.name });

function outputItems(out, finalStatus) {
  const items = [];
  if (out.reasoning) items.push(reasoningItem(apiRandomId("rs_", 24), out.reasoning));
  if (out.content || !(out.toolCalls && out.toolCalls.length)) {
    items.push(messageItem(apiRandomId("msg_", 24), out.content || "", finalStatus === "completed" ? "completed" : "incomplete", annotations(out)));
  }
  for (const c of out.toolCalls || []) items.push(callItem(apiRandomId("fc_", 24), c, "completed", c.function.arguments));
  return items;
}

function finalFields(out, output) {
  const st = statusOf(out.finish);
  return { status: st.status, incomplete_details: st.incomplete_details, output, usage: responsesUsage(out.usage), nymbot: apiNymbotObject(out) };
}

function responsesWriter(sse, ctx) {
  let seq = 0;
  let opened = false;
  let cur = null;
  const items = [];
  const streamed = { text: false, reasoning: false };
  const send = (type, obj) => sse.event(type, Object.assign({ type }, obj, { sequence_number: seq++ }));
  const open = () => {
    if (opened) return;
    opened = true;
    const snap = responseObject(ctx, { status: "in_progress", output: [] });
    send("response.created", { response: snap });
    send("response.in_progress", { response: snap });
  };
  const startItem = (kind) => {
    const text = kind === "text";
    const id = apiRandomId(text ? "msg_" : "rs_", 24);
    const index = items.length;
    const added = text
      ? { id, type: "message", status: "in_progress", role: "assistant", content: [] }
      : { id, type: "reasoning", summary: [], content: [] };
    items.push(added);
    cur = { kind, id, index, text: "" };
    send("response.output_item.added", { output_index: index, item: added });
    send("response.content_part.added", {
      item_id: id, output_index: index, content_index: 0,
      part: text ? { type: "output_text", text: "", annotations: [], logprobs: [] } : { type: "reasoning_text", text: "" }
    });
  };
  const closeItem = (status, ann) => {
    if (!cur) return;
    const c = cur;
    cur = null;
    const where = { item_id: c.id, output_index: c.index, content_index: 0 };
    if (c.kind === "text") {
      const item = messageItem(c.id, c.text, status, ann || []);
      send("response.output_text.done", Object.assign({}, where, { text: c.text, logprobs: [] }));
      send("response.content_part.done", Object.assign({}, where, { part: item.content[0] }));
      items[c.index] = item;
      send("response.output_item.done", { output_index: c.index, item });
    } else {
      const item = reasoningItem(c.id, c.text);
      send("response.reasoning_text.done", Object.assign({}, where, { text: c.text }));
      send("response.content_part.done", Object.assign({}, where, { part: item.content[0] }));
      items[c.index] = item;
      send("response.output_item.done", { output_index: c.index, item });
    }
  };
  const emit = (kind, piece, force) => {
    if (!piece && !force) return;
    open();
    if (cur && cur.kind !== kind) closeItem("completed");
    if (!cur) startItem(kind);
    streamed[kind] = true;
    if (!piece) return;
    cur.text += piece;
    const where = { item_id: cur.id, output_index: cur.index, content_index: 0 };
    if (kind === "text") send("response.output_text.delta", Object.assign(where, { delta: piece, logprobs: [] }));
    else send("response.reasoning_text.delta", Object.assign(where, { delta: piece }));
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
      const st = statusOf(out.finish);
      const calls = out.toolCalls || [];
      if (!streamed.reasoning && out.reasoning) emit("reasoning", out.reasoning);
      if (!streamed.text && (out.content || !calls.length)) emit("text", out.content || "", true);
      const itemStatus = st.status === "completed" ? "completed" : "incomplete";
      if (cur) closeItem(cur.kind === "text" ? itemStatus : "completed", annotations(out));
      for (const c of calls) {
        const id = apiRandomId("fc_", 24);
        const index = items.length;
        const added = callItem(id, c, "in_progress", "");
        items.push(added);
        send("response.output_item.added", { output_index: index, item: added });
        send("response.function_call_arguments.delta", { item_id: id, output_index: index, delta: c.function.arguments });
        send("response.function_call_arguments.done", { item_id: id, output_index: index, arguments: c.function.arguments, name: c.function.name });
        const done = callItem(id, c, "completed", c.function.arguments);
        items[index] = done;
        send("response.output_item.done", { output_index: index, item: done });
      }
      const final = responseObject(ctx, finalFields(out, items));
      send(st.status === "completed" ? "response.completed" : "response.incomplete", { response: final });
    },
    fail(error) {
      open();
      if (sse.cancelled) return;
      const e = apiErrorBody(apiUpstreamError(error), "openai").error;
      send("response.failed", { response: responseObject(ctx, { status: "failed", output: items, error: { code: e.code || "server_error", message: e.message } }) });
    }
  };
}

async function responses(api) {
  const body = api.body;
  if (typeof body.model !== "string" || !body.model.trim()) throw apiBad("`model` is required.", "model", "missing_required_parameter");
  apiCheckSampling(body);
  const req = await apiChatPrepare(api, translate(body));
  req.type = "responses";
  req.stream = body.stream === true;
  req.completionId = apiRandomId("resp_", 24);
  const ctx = { id: req.completionId, created: req.created, model: req.resolved.id, effort: req.effort, body, tools: echoTools(body.tools) };
  if (!req.stream) {
    const out = await apiChatRun(api, req, null);
    const st = statusOf(out.finish).status;
    const obj = responseObject(ctx, finalFields(out, outputItems(out, st)));
    return apiJson(obj, 200, apiCostHeaders(out.cost));
  }
  const sse = apiSseStream();
  const writer = responsesWriter(sse, ctx);
  const gate = apiStreamDraft(sse, (kind, piece) => writer.delta(kind, piece));
  const res = await apiStreamRun(api, sse, gate, (draft) => apiChatRun(api, req, { draft }), (result) => {
    if (result.error) writer.fail(result.error);
    else writer.finish(result.out);
  });
  writer.open();
  return res;
}

export function registerResponses(r) {
  r.add("POST", "/responses", responses, { auth: "key" });
}
