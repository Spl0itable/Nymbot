export const RESEARCH_LIMITS = {
  maxRounds: 4,
  maxPages: 20,
  maxSources: 30,
  pagesPerRound: 6,
  queriesPerRound: 3,
  resultsPerQuery: 8,
  resultChars: 400,
  pageChars: 5000,
  notesChars: 20000,
  findingChars: 600,
  questionChars: 4000,
  historyChars: 4000,
  planTokens: 900,
  noteTokens: 1500,
  reportTokens: 8192,
  promptOverheadTokens: 1500,
  legBudgetMs: 140000,
  roundReserveMs: 35000,
  reportReserveMs: 80000,
  pageDeadlineMs: 9000
};

export const RESEARCH_MAX_CALLS = 1 + RESEARCH_LIMITS.maxRounds + 1;

const COMMAND_RE = /^\s*\?research\b[ \t]*/i;

export function researchCommand(text) {
  const s = String(text || "");
  if (!COMMAND_RE.test(s)) return null;
  return s.replace(COMMAND_RE, "").trim();
}

export function researchWanted(flag) {
  return flag === true || !!(flag && typeof flag === "object");
}

export function researchStatedMax(flag) {
  if (!flag || typeof flag !== "object") return 0;
  const n = Number(flag.max);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function tokensFor(chars) {
  return Math.ceil(Math.max(0, Number(chars) || 0) / 3);
}

function reportOut(model) {
  const cap = Number(model && model.maxTokens) || RESEARCH_LIMITS.reportTokens;
  return Math.min(cap, RESEARCH_LIMITS.reportTokens);
}

export function researchTokenBudget(model) {
  const L = RESEARCH_LIMITS;
  const over = L.promptOverheadTokens;
  const results = L.queriesPerRound * L.resultsPerQuery * L.resultChars;
  const planIn = over + tokensFor(L.questionChars + L.historyChars);
  const noteIn = over + tokensFor(L.questionChars + L.notesChars + results + L.pagesPerRound * L.pageChars);
  const reportIn = over + tokensFor(L.questionChars + L.notesChars + L.maxSources * 250);
  const out = reportOut(model);
  const maxIn = planIn + L.maxRounds * noteIn + reportIn;
  const maxOut = L.planTokens + L.maxRounds * L.noteTokens + out;
  const typicalOut = Math.min(out, 3000);
  const longOut = Math.min(out, 6000);
  return {
    calls: RESEARCH_MAX_CALLS,
    low: { calls: 4, in: 2500 + 2 * 12000 + 7000, out: 500 + 2 * 900 + typicalOut },
    high: { calls: RESEARCH_MAX_CALLS, in: 2500 + L.maxRounds * 16000 + 10000, out: 500 + L.maxRounds * 1200 + longOut },
    max: { calls: RESEARCH_MAX_CALLS, in: maxIn, out: maxOut }
  };
}

function flatCredits(model, calls, outTok) {
  const base = Number(model && model.baseCredits) || 1;
  const per = Number(model && model.outTokensPerCredit) || 0;
  let cost = base * calls;
  if (per > 0) {
    const included = per * calls;
    if (outTok > included) cost += Math.ceil((outTok - included) / per);
  }
  return cost;
}

export function researchEstimate(model, meterMilli) {
  const b = researchTokenBudget(model);
  const credits = (part) => {
    const milli = typeof meterMilli === "function" ? meterMilli(part.in, part.out) : null;
    if (milli != null && Number.isFinite(milli) && milli > 0) {
      return { credits: Math.max(1, Math.ceil(milli / 1000)), milli: Math.ceil(milli) };
    }
    const c = flatCredits(model, part.calls, part.out);
    return { credits: c, milli: c * 1000 };
  };
  const low = credits(b.low);
  const high = credits(b.high);
  const max = credits(b.max);
  const hi = Math.max(low.credits, high.credits);
  const top = Math.max(hi, max.credits);
  return {
    low: low.credits,
    high: hi,
    max: top,
    maxMilli: Math.max(max.milli, top * 1000),
    maxCalls: RESEARCH_MAX_CALLS,
    metered: typeof meterMilli === "function" && meterMilli(1000, 1000) != null
  };
}

const SUBS_CHARS = 5 * 200;

function messagesChars(messages) {
  let n = 0;
  for (const m of messages) n += String((m && m.content) || "").length;
  return n;
}

function stepCost(messages, maxTokens, extraChars) {
  return {
    in: RESEARCH_LIMITS.promptOverheadTokens + tokensFor(messagesChars(messages) + (Number(extraChars) || 0)),
    out: maxTokens
  };
}

export function researchFloor(model) {
  const L = RESEARCH_LIMITS;
  const state = freshState("x".repeat(L.questionChars), "x".repeat(L.historyChars));
  const plan = stepCost(planMessages(state), L.planTokens);
  const report = stepCost(reportMessages(state), reportOut(model), SUBS_CHARS);
  return { calls: 2, in: plan.in + report.in, out: plan.out + report.out };
}

export const RESEARCH_BUDGET_ERROR = "The research budget left is too small for the next step.";

export function researchPublicLimits() {
  const L = RESEARCH_LIMITS;
  return {
    maxCalls: RESEARCH_MAX_CALLS,
    maxRounds: L.maxRounds,
    maxPages: L.maxPages,
    maxSources: L.maxSources
  };
}

function clip(text, max) {
  const s = String(text == null ? "" : text).replace(/\s+/g, " ").trim();
  return s.length > max ? s.slice(0, Math.max(0, max - 1)).trimEnd() + "…" : s;
}

function hostOf(url) {
  try { return new URL(url).hostname.replace(/^www\./, ""); } catch (e) { return ""; }
}

export function parseResultLine(line) {
  const raw = String(line || "").trim();
  if (!raw) return null;
  let body = raw;
  let url = "";
  const m = /^([\s\S]*?)\s*\[(https?:\/\/[^\]\s]+)\]$/.exec(raw);
  if (m) { body = m[1].trim(); url = m[2]; }
  let title = body;
  let snippet = "";
  const cut = body.indexOf(": ");
  if (cut > 0) {
    title = body.slice(0, cut).trim();
    snippet = body.slice(cut + 2).trim();
  }
  return { title: clip(title, 160), snippet: clip(snippet, 300), url };
}

export function parseModelJson(text) {
  const s = String(text || "");
  const fenced = /```(?:json)?\s*([\s\S]*?)```/i.exec(s);
  const candidates = [];
  if (fenced) candidates.push(fenced[1]);
  const a = s.indexOf("{");
  const z = s.lastIndexOf("}");
  if (a !== -1 && z > a) candidates.push(s.slice(a, z + 1));
  for (const c of candidates) {
    try {
      const v = JSON.parse(c);
      if (v && typeof v === "object") return v;
    } catch (e) { }
  }
  return null;
}

export function queryList(raw, limit) {
  const out = [];
  const seen = {};
  const list = Array.isArray(raw) ? raw : [];
  for (const item of list) {
    const q = clip(typeof item === "string" ? item : (item && (item.q || item.query)) || "", 160);
    if (q.length < 3) continue;
    const key = q.toLowerCase();
    if (seen[key]) continue;
    seen[key] = true;
    const kind = item && typeof item === "object" && /news/i.test(String(item.kind || "")) ? "news" : "reference";
    out.push({ q, kind });
    if (out.length >= limit) break;
  }
  return out;
}

export function freshState(question, history) {
  return {
    v: 1,
    question: clip(question, RESEARCH_LIMITS.questionChars),
    history: String(history || "").slice(0, RESEARCH_LIMITS.historyChars),
    phase: "plan",
    subs: [],
    pending: [],
    asked: [],
    round: 0,
    pages: 0,
    seen: [],
    sources: [],
    notes: [],
    calls: 0,
    chargedMilli: 0
  };
}

function notesChars(notes) {
  let n = 0;
  for (const x of notes) n += String(x.text || "").length + 12;
  return n;
}

function notesBlock(state) {
  if (!state.notes.length) return "(nothing noted yet)";
  return state.notes.map((x) => "- " + x.text + (x.src && x.src.length ? " " + x.src.map((n) => "[" + n + "]").join("") : "")).join("\n");
}

function sourcesBlock(state) {
  return state.sources.map((s, i) => "[" + (i + 1) + "] " + (s.title || s.host || s.url) + (s.url ? " — " + s.url : "")).join("\n");
}

const PLAN_PROMPT = "You are planning a piece of deep web research. Break the question into the sub-questions a careful researcher would need answered, and write the first web searches to run: different phrasings, some aimed at recent news and some at reference material (encyclopedias, official documentation, primary sources). Reply with JSON only, no prose, in exactly this shape: {\"subquestions\": [\"...\"], \"queries\": [{\"q\": \"search terms\", \"kind\": \"news\" or \"reference\"}]}. At most 5 sub-questions and at most 4 queries. Queries are short keyword phrases, not sentences.";

const NOTE_PROMPT = "You are in the middle of deep web research. Read the new material below and note what it establishes that bears on the question. Every finding must come from the material and name the numbered source it came from. Do not note anything the material does not say. Then decide whether more searching would materially improve the answer. Reply with JSON only, in exactly this shape: {\"findings\": [{\"text\": \"one factual finding\", \"sources\": [1]}], \"next\": [{\"q\": \"search terms\", \"kind\": \"news\" or \"reference\"}], \"done\": false}. At most 8 findings, at most 3 next queries, and set done to true when the question is well covered or further searching is unlikely to help.";

export const RESEARCH_REPORT_PROMPT = "Write the final research report for the user from the notes and numbered sources below. Structure it in Markdown: a title as a level-one heading, a short summary paragraph under a bold 'Summary' label, then sections with level-two headings covering the sub-questions, and finish with a level-two section titled 'Limits of this research' of two to four sentences saying what could not be established, where sources disagreed or were thin, and how recent the material is. Be thorough and specific. Cite claims with the source numbers in square brackets, like [3] or [2][5], using only the numbers listed below, and never invent a source, a URL or a quotation. Do not add a list of sources or references at the end: the app shows them. If no sources were found, say plainly that the web searches turned up nothing usable, answer only as far as general knowledge allows, and cite nothing. Write in the same language as the question.";

function planMessages(state) {
  const ctx = state.history ? "Earlier in this conversation:\n" + state.history + "\n\n" : "";
  return [
    { role: "system", content: PLAN_PROMPT },
    { role: "user", content: ctx + "Current date: " + new Date().toUTCString() + "\n\nQuestion: " + state.question }
  ];
}

function noteMessages(state, material) {
  return [
    { role: "system", content: NOTE_PROMPT },
    { role: "user", content: "Question: " + state.question +
      (state.subs.length ? "\n\nSub-questions:\n" + state.subs.map((s) => "- " + s).join("\n") : "") +
      "\n\nNoted so far:\n" + notesBlock(state) +
      "\n\nAlready searched: " + state.asked.join("; ") +
      "\n\nNew material (cite by the number in brackets):\n" + material }
  ];
}

function reportMessages(state) {
  return [
    { role: "system", content: RESEARCH_REPORT_PROMPT },
    { role: "user", content: "Question: " + state.question +
      (state.subs.length ? "\n\nSub-questions:\n" + state.subs.map((s) => "- " + s).join("\n") : "") +
      "\n\nResearch notes:\n" + notesBlock(state) +
      "\n\nNumbered sources:\n" + (state.sources.length ? sourcesBlock(state) : "(none)") +
      "\n\nCurrent date: " + new Date().toUTCString() }
  ];
}

export function renumberCitations(text, sources, maxSources) {
  const limit = maxSources || RESEARCH_LIMITS.maxSources;
  const map = {};
  const out = [];
  const body = String(text || "").replace(/([ \t]*)\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]/g, (whole, lead, inner) => {
    const nums = inner.split(",").map((x) => parseInt(x.trim(), 10));
    const mapped = [];
    for (const n of nums) {
      if (!(n >= 1 && n <= sources.length)) continue;
      if (!map[n]) {
        if (out.length >= limit) continue;
        out.push(sources[n - 1]);
        map[n] = out.length;
      }
      if (mapped.indexOf(map[n]) === -1) mapped.push(map[n]);
    }
    return mapped.length ? lead + mapped.map((m) => "[" + m + "]").join("") : "";
  });
  return { text: body, sources: out };
}

export function stripReferenceList(text) {
  return String(text || "").replace(/\n#{1,3}\s*(?:sources|references|bibliography)\s*\n[\s\S]*$/i, "").trimEnd();
}

export function publicSource(s) {
  return { title: s.title || s.host || s.url, snippet: s.snippet || "", url: s.url || undefined };
}

function emptyUsage() {
  return { fresh: 0, read: 0, wrote: 0, out: 0 };
}

function addUsage(into, u) {
  if (!u) return;
  into.fresh += Number(u.fresh) || 0;
  into.read += Number(u.read) || 0;
  into.wrote += Number(u.wrote) || 0;
  into.out += Number(u.out) || 0;
}

async function withDeadline(promises, ms) {
  let timer;
  await Promise.race([
    Promise.all(promises),
    new Promise((resolve) => { timer = setTimeout(resolve, ms); })
  ]);
  clearTimeout(timer);
}

export async function runResearch(deps, input) {
  const L = Object.assign({}, RESEARCH_LIMITS, (input && input.limits) || {});
  const maxCalls = input && Number(input.maxCalls) > 0 ? Math.floor(Number(input.maxCalls)) : RESEARCH_MAX_CALLS;
  const notesOnly = !!(input && input.notesOnly);
  const progress = typeof deps.progress === "function" ? deps.progress : () => { };
  const now = typeof deps.now === "function" ? deps.now : Date.now;
  const started = now();
  const resumed = !!(input && input.state);
  const state = resumed ? input.state : freshState(input.question, input.history);
  if (!resumed && input && Array.isArray(input.queries)) {
    const seeded = queryList(input.queries, 4);
    if (seeded.length) {
      state.pending = seeded;
      state.phase = "search";
    }
  }
  const usage = emptyUsage();
  let legCalls = 0;
  let outputTokens = 0;
  const limit = input && input.limitMilli != null && Number.isFinite(Number(input.limitMilli))
    ? Math.max(0, Number(input.limitMilli)) : null;
  const priced = limit != null && typeof deps.spent === "function";
  const fits = (steps) => {
    if (!priced) return true;
    const u = { fresh: usage.fresh, read: usage.read, wrote: usage.wrote, out: usage.out };
    let calls = legCalls;
    let outTok = outputTokens;
    for (const st of steps) {
      if (!st) continue;
      u.fresh += st.in;
      u.out += st.out;
      outTok += st.out;
      calls++;
    }
    const cost = Number(deps.spent(u, calls, outTok));
    return Number.isFinite(cost) && cost <= limit;
  };
  const reportStep = (extraChars) => notesOnly ? null : stepCost(reportMessages(state), reportOut(input && input.model), extraChars);

  const call = async (messages, maxTokens) => {
    if (state.calls >= maxCalls) throw new Error("Research call budget spent.");
    state.calls++;
    legCalls++;
    const r = await deps.chat(messages, maxTokens);
    addUsage(usage, r && r.usage);
    outputTokens += (r && r.outputTokens) || 0;
    return String((r && r.text) || "");
  };
  const elapsed = () => now() - started;
  const notesResult = () => ({
    reply: "",
    notes: state.notes,
    sources: state.sources,
    modelCalls: legCalls,
    outputTokens,
    usage,
    truncated: false,
    state
  });
  const park = (why) => {
    if (notesOnly) return notesResult();
    progress({ kind: "research", stage: "pause", round: state.round, of: L.maxRounds });
    const cited = state.notes.slice(-12);
    const lines = cited.map((x) => "- " + x.text + (x.src && x.src.length ? " " + x.src.map((n) => "[" + n + "]").join("") : ""));
    const draft = renumberCitations(lines.join("\n"), state.sources, L.maxSources);
    const head = "**Research paused** after " + state.round + " of up to " + L.maxRounds + " rounds (" + state.pages + " pages read). " +
      (why === "report" ? "The report is written next." : "It carries on from here.");
    return {
      reply: head + (draft.text ? "\n\nFound so far:\n" + draft.text : ""),
      sources: draft.sources.map(publicSource),
      modelCalls: legCalls,
      outputTokens,
      usage,
      truncated: true,
      state
    };
  };

  if (resumed) progress({ kind: "research", stage: "resume", round: state.round, of: L.maxRounds });

  if (state.phase === "plan") {
    if (!fits([stepCost(planMessages(state), L.planTokens), reportStep(SUBS_CHARS)])) throw new Error(RESEARCH_BUDGET_ERROR);
    progress({ kind: "research", stage: "plan" });
    const planned = parseModelJson(await call(planMessages(state), L.planTokens)) || {};
    state.subs = (Array.isArray(planned.subquestions) ? planned.subquestions : [])
      .map((s) => clip(s, 200)).filter(Boolean).slice(0, 5);
    state.pending = queryList(planned.queries, 4);
    if (!state.pending.length) state.pending = [{ q: clip(state.question, 160), kind: "reference" }];
    state.phase = "search";
    progress({ kind: "research", stage: "planned", subs: state.subs.length, queries: state.pending.length });
  }

  while (state.phase === "search") {
    if (state.round >= L.maxRounds || state.pages >= L.maxPages || !state.pending.length
      || state.calls >= maxCalls - (notesOnly ? 0 : 1)) {
      state.phase = "report";
      break;
    }
    if (legCalls > 0 && elapsed() > L.legBudgetMs - L.roundReserveMs) return park("search");
    state.round++;
    const queries = state.pending.slice(0, L.queriesPerRound);
    state.pending = state.pending.slice(L.queriesPerRound);
    const found = [];
    const seenUrls = {};
    state.seen.forEach((u) => { seenUrls[u] = true; });
    const runs = queries.map((qq) => {
      state.asked.push(qq.q);
      progress({ kind: "research", stage: "search", query: qq.q, news: qq.kind === "news", round: state.round, of: L.maxRounds });
      return Promise.resolve().then(() => deps.search(qq.q, qq.kind)).then((lines) => lines || [], () => []);
    });
    const results = await Promise.all(runs);
    for (const lines of results) {
      for (const line of lines.slice(0, L.resultsPerQuery)) {
        const r = parseResultLine(line);
        if (!r || !r.url || seenUrls[r.url]) continue;
        seenUrls[r.url] = true;
        found.push(r);
      }
    }
    const room = Math.min(L.pagesPerRound, L.maxPages - state.pages, L.maxSources - state.sources.length);
    const picks = found.slice(0, Math.max(0, room));
    const read = [];
    const reads = picks.map((r) => {
      state.seen.push(r.url);
      progress({ kind: "research", stage: "read", host: hostOf(r.url) });
      return Promise.resolve().then(() => deps.fetchPage(r.url, L.pageChars)).then((page) => {
        const text = page && page.text ? String(page.text).slice(0, L.pageChars) : "";
        if (text.length >= 200) read.push({ r, title: (page && page.title) || r.title, text });
      }, () => { });
    });
    await withDeadline(reads, L.pageDeadlineMs);
    const material = [];
    const sourcesBefore = state.sources.length;
    const pagesBefore = state.pages;
    for (const p of read) {
      if (state.sources.length >= L.maxSources) break;
      state.sources.push({ title: clip(p.title, 160), snippet: p.r.snippet, url: p.r.url, host: hostOf(p.r.url) });
      state.pages++;
      material.push("[" + state.sources.length + "] " + (p.title || hostOf(p.r.url)) + " (" + p.r.url + ")\n" + p.text);
    }
    if (read.length < 2) {
      for (const r of found) {
        if (material.length >= 6 || state.sources.length >= L.maxSources) break;
        if (read.some((p) => p.r.url === r.url) || !r.snippet) continue;
        state.sources.push({ title: r.title, snippet: r.snippet, url: r.url, host: hostOf(r.url) });
        material.push("[" + state.sources.length + "] " + r.title + " (" + r.url + ") — search snippet only: " + r.snippet);
      }
    }
    if (!material.length) {
      progress({ kind: "research", stage: "note", round: state.round, found: 0 });
      if (!state.pending.length && state.round < L.maxRounds && state.round === 1) {
        state.pending = [{ q: clip(state.question, 160), kind: "news" }].filter((x) => state.asked.indexOf(x.q) === -1);
      }
      continue;
    }
    const notesRoom = Math.max(0, L.notesChars - notesChars(state.notes));
    if (!fits([stepCost(noteMessages(state, material.join("\n\n")), L.noteTokens), reportStep(notesRoom)])) {
      state.sources.length = sourcesBefore;
      state.pages = pagesBefore;
      state.phase = "report";
      break;
    }
    let noted = null;
    try {
      noted = parseModelJson(await call(noteMessages(state, material.join("\n\n")), L.noteTokens));
    } catch (e) {
      if (!state.notes.length && state.round <= 1) throw e;
      state.phase = "report";
      break;
    }
    noted = noted || {};
    let added = 0;
    for (const f of Array.isArray(noted.findings) ? noted.findings : []) {
      const text = clip(f && (f.text || f.finding) || "", L.findingChars);
      if (!text) continue;
      const src = (Array.isArray(f.sources) ? f.sources : [])
        .map((n) => parseInt(n, 10)).filter((n) => n >= 1 && n <= state.sources.length).slice(0, 4);
      if (notesChars(state.notes) + text.length > L.notesChars) break;
      state.notes.push({ text, src });
      added++;
    }
    progress({ kind: "research", stage: "note", round: state.round, found: added });
    const next = queryList(noted.next, L.queriesPerRound)
      .filter((x) => state.asked.map((a) => a.toLowerCase()).indexOf(x.q.toLowerCase()) === -1);
    state.pending = next.concat(state.pending).slice(0, 6);
    if (noted.done === true) state.pending = [];
  }

  if (notesOnly) return notesResult();
  if (legCalls > 0 && elapsed() > L.legBudgetMs - L.reportReserveMs) return park("report");
  if (!fits([reportStep(0)])) throw new Error(RESEARCH_BUDGET_ERROR);
  progress({ kind: "research", stage: "write", sources: state.sources.length });
  const written = await call(reportMessages(state), reportOut(input && input.model));
  if (!written.trim()) throw new Error("The research report came back empty.");
  const cleaned = stripReferenceList(written);
  const cited = renumberCitations(cleaned, state.sources, L.maxSources);
  state.phase = "done";
  return {
    reply: cited.text,
    sources: cited.sources.map(publicSource),
    modelCalls: legCalls,
    outputTokens,
    usage,
    truncated: false,
    state
  };
}
