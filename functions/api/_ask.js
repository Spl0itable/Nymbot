export var ASK_TOOL_NAME = "ask_user";
export var ASK_QUESTIONS_MAX = 4;
export var ASK_OPTIONS_MIN = 2;
export var ASK_OPTIONS_MAX = 4;
export var ASK_QUESTION_CHARS = 300;
export var ASK_HEADER_CHARS = 30;
export var ASK_LABEL_CHARS = 60;
export var ASK_DESC_CHARS = 160;
export var ASK_OTHER_CHARS = 500;
export var ASK_WAIT_MS = 24 * 3600 * 1000;
export var ASK_ID_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
export var PENDING_KINDS = { question: true, plan: true };

var BLOCK_RE = /<ask_user>([\s\S]*?)<\/ask_user>/g;

export function askClean(v, max) {
  var s = typeof v === "string" ? v : "";
  s = s.replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, " ").replace(/\s+/g, " ").replace(/^ +| +$/g, "");
  if (max && s.length > max) s = s.slice(0, max - 1).replace(/ +$/, "") + "\u2026";
  return s;
}

export function askParse(raw) {
  var list = raw && typeof raw === "object" && Array.isArray(raw.questions) ? raw.questions : null;
  if (!list || list.length < 1 || list.length > ASK_QUESTIONS_MAX) return { error: "questions" };
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var q = list[i];
    if (!q || typeof q !== "object" || Array.isArray(q)) return { error: "question" };
    var text = askClean(q.question, ASK_QUESTION_CHARS);
    if (!text) return { error: "question" };
    var opts = Array.isArray(q.options) ? q.options : [];
    var seen = {};
    var kept = [];
    for (var j = 0; j < opts.length; j++) {
      var o = opts[j];
      var label = askClean(o && typeof o === "object" ? o.label : o, ASK_LABEL_CHARS);
      if (!label) return { error: "label" };
      var key = label.toLowerCase();
      if (key === "other") continue;
      if (seen["k:" + key]) return { error: "duplicate" };
      seen["k:" + key] = true;
      kept.push({ label: label, description: askClean(o && typeof o === "object" ? o.description : "", ASK_DESC_CHARS) });
    }
    if (kept.length < ASK_OPTIONS_MIN || kept.length > ASK_OPTIONS_MAX) return { error: "options" };
    out.push({
      question: text,
      header: askClean(q.header, ASK_HEADER_CHARS),
      multi: q.multiSelect === true || q.multi === true,
      options: kept
    });
  }
  return { questions: out };
}

export function askAnswers(questions, raw) {
  if (!Array.isArray(questions) || !questions.length) return { error: "questions" };
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "answers" };
  if (raw.skipped === true) return { skipped: true };
  var list = Array.isArray(raw.answers) ? raw.answers : null;
  if (!list || list.length !== questions.length) return { error: "answers" };
  var out = [];
  for (var i = 0; i < questions.length; i++) {
    var a = list[i];
    if (!a || typeof a !== "object" || Array.isArray(a)) return { error: "answers" };
    var sel = a.selected == null ? [] : a.selected;
    if (!Array.isArray(sel)) return { error: "selected" };
    var picked = [];
    for (var j = 0; j < sel.length; j++) {
      var n = sel[j];
      if (typeof n !== "number" || !Number.isInteger(n) || n < 0 || n >= questions[i].options.length || picked.indexOf(n) !== -1) {
        return { error: "selected" };
      }
      picked.push(n);
    }
    picked.sort(function (x, y) { return x - y; });
    var other = askClean(a.other, ASK_OTHER_CHARS);
    var count = picked.length + (other ? 1 : 0);
    if (questions[i].multi ? count < 1 : count !== 1) return { error: questions[i].multi ? "empty" : "single" };
    out.push({ selected: picked, other: other });
  }
  return { answers: out };
}

export function askAnswerText(questions, answered) {
  if (answered && answered.skipped) {
    return "The user chose not to answer these questions. Carry on with your best judgment and say which assumptions you made.";
  }
  var lines = ["The user answered:"];
  for (var i = 0; i < questions.length; i++) {
    var q = questions[i];
    var a = answered.answers[i];
    var parts = a.selected.map(function (n) { return q.options[n].label; });
    if (a.other) parts.push("Other: " + a.other);
    lines.push((i + 1) + ". " + q.question);
    lines.push("Answer: " + parts.join("; "));
  }
  return lines.join("\n");
}

export function askBlock(id, questions) {
  return "<ask_user>" + JSON.stringify({ id: id, questions: questions }).replace(/</g, "\\u003c").replace(/>/g, "\\u003e") + "</ask_user>";
}

export function askTake(text) {
  var src = typeof text === "string" ? text : "";
  var last = null;
  var m;
  BLOCK_RE.lastIndex = 0;
  while ((m = BLOCK_RE.exec(src))) last = m[1];
  var rest = src.replace(BLOCK_RE, "");
  var open = rest.search(/<ask_user\b/);
  if (open !== -1) rest = rest.slice(0, open);
  rest = rest.replace(/\n{3,}/g, "\n\n").replace(/^\s+|\s+$/g, "");
  var ask = null;
  if (last != null) {
    var obj = null;
    try { obj = JSON.parse(last); } catch (e) { obj = null; }
    var parsed = obj && typeof obj === "object" ? askParse(obj) : { error: "json" };
    if (!parsed.error) {
      ask = { id: typeof obj.id === "string" && ASK_ID_RE.test(obj.id) ? obj.id : "", questions: parsed.questions };
    }
  }
  return { text: rest, ask: ask };
}

export function askErrorText(code) {
  var why = {
    questions: "Ask between 1 and " + ASK_QUESTIONS_MAX + " questions.",
    question: "Every question needs its text.",
    label: "Every option needs a label.",
    duplicate: "Two options of one question have the same label.",
    options: "Every question needs " + ASK_OPTIONS_MIN + " to " + ASK_OPTIONS_MAX + " options; the user can always write their own answer, so do not add an Other option."
  }[code] || "The question could not be read.";
  return "Error: nothing was asked. " + why + " Call " + ASK_TOOL_NAME + " again with a corrected question, or decide yourself.";
}

export function askPauseReply(text) {
  var said = typeof text === "string" ? text.replace(/^\s+|\s+$/g, "") : "";
  return said || "I need your input before I go on.";
}

export var ASK_TOOL = {
  type: "function",
  function: {
    name: ASK_TOOL_NAME,
    description: "Pause the task and ask the user a structured question. Use it only when you are genuinely blocked on a choice only the user can make: a preference or requirement they have not stated, or a costly or irreversible choice between real alternatives. Never use it for things you can decide, look up or work out yourself, to confirm an obvious next step, or to ask the same thing twice. Ask 1 to " +
      ASK_QUESTIONS_MAX + " questions, each with " + ASK_OPTIONS_MIN + " to " + ASK_OPTIONS_MAX +
      " distinct options and a one-line description of each; the user can always write their own answer, so do not add an Other option. The task waits until the user answers, and their answers come back as this tool's result.",
    parameters: {
      type: "object",
      properties: {
        questions: {
          type: "array", minItems: 1, maxItems: ASK_QUESTIONS_MAX,
          items: {
            type: "object",
            properties: {
              question: { type: "string", description: "The question, in one sentence (at most " + ASK_QUESTION_CHARS + " characters)." },
              header: { type: "string", description: "A short label for the question, a few words (at most " + ASK_HEADER_CHARS + " characters)." },
              multiSelect: { type: "boolean", description: "True when the user may pick more than one option." },
              options: {
                type: "array", minItems: ASK_OPTIONS_MIN, maxItems: ASK_OPTIONS_MAX,
                items: {
                  type: "object",
                  properties: {
                    label: { type: "string", description: "The option, in a few words (at most " + ASK_LABEL_CHARS + " characters)." },
                    description: { type: "string", description: "What choosing it means, in one short line (at most " + ASK_DESC_CHARS + " characters)." }
                  },
                  required: ["label", "description"]
                }
              }
            },
            required: ["question", "options"]
          }
        }
      },
      required: ["questions"]
    }
  }
};

export var ASK_GUIDELINE = "ASKING THE USER: Only when you are genuinely blocked on a choice only the user can make (a preference or requirement they have not stated, or a costly or irreversible choice between real alternatives), you may end your reply with one block in exactly this form, after a short sentence saying why you are asking: " +
  "<ask_user>{\"questions\":[{\"question\":\"...\",\"header\":\"a few words\",\"multiSelect\":false,\"options\":[{\"label\":\"...\",\"description\":\"one short line\"}]}]}</ask_user> " +
  "with 1 to " + ASK_QUESTIONS_MAX + " questions and " + ASK_OPTIONS_MIN + " to " + ASK_OPTIONS_MAX + " options each, no Other option (the user can always write their own answer). The user sees it as a form and their answers arrive as their next message. Never use it for things you can decide or work out yourself, to confirm an obvious next step, or instead of answering; most replies need no block.";

export function pendingQuestion(id, questions, now) {
  return { kind: "question", id: id, questions: questions, expiresAt: (now || Date.now()) + ASK_WAIT_MS };
}

export function pendingAnswerOf(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  if (typeof raw.id !== "string" || !ASK_ID_RE.test(raw.id)) return null;
  return raw;
}

export function pendingSettle(pending, raw) {
  if (!pending || typeof pending !== "object" || !PENDING_KINDS[pending.kind]) return { error: "kind" };
  var ans = pendingAnswerOf(raw);
  if (!ans || ans.id !== pending.id) return { error: "id" };
  if (pending.kind === "question") {
    var got = askAnswers(pending.questions, ans);
    if (got.error) return got;
    return { id: pending.id, text: askAnswerText(pending.questions, got), answered: got };
  }
  if (pending.kind === "plan") {
    var decided = planDecision(pending, ans);
    if (decided.error) return decided;
    return Object.assign({ id: pending.id }, decided, planDecisionText(decided));
  }
  return { error: "kind" };
}

export var PLAN_TOOL_NAME = "propose_plan";
export var PLAN_SUMMARY_CHARS = 600;
export var PLAN_ITEMS_MAX = 20;
export var PLAN_ITEM_CHARS = 120;
export var PLAN_CHANGES_MAX = 12;
export var PLAN_TARGET_CHARS = 120;
export var PLAN_WHAT_CHARS = 300;
export var PLAN_NOTE_CHARS = 2000;
export var PLAN_MODES = { always: true, changing: true, never: true };
export var PLAN_DECISIONS = { approve: true, reject: true, revise: true };
export var PLAN_GATE_TEXT = "Error: propose a plan first (call " + PLAN_TOOL_NAME + ")";
export var PLAN_REJECTED_TEXT = "Error: the user rejected the plan, so nothing may change now. Ask the user what they want changed.";
export var PLAN_HELD_TEXT = "Error: this call did not run because the plan is waiting for the user's approval. Call it again after approval if it is still needed.";

var PLAN_BLOCK_RE = /<propose_plan>([\s\S]*?)<\/propose_plan>/g;

export function planMode(raw) {
  return typeof raw === "string" && PLAN_MODES[raw] ? raw : "changing";
}

export function planNote(v) {
  var s = typeof v === "string" ? v : "";
  s = s.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0009\u000b-\u001f\u007f\u2028\u2029]/g, " ").replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").replace(/^\s+|\s+$/g, "");
  if (s.length > PLAN_NOTE_CHARS) s = s.slice(0, PLAN_NOTE_CHARS - 1).replace(/\s+$/, "") + "\u2026";
  return s;
}

export function planItems(raw) {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > PLAN_ITEMS_MAX) return null;
  var out = [];
  for (var i = 0; i < raw.length; i++) {
    var it = raw[i];
    var text = askClean(it && typeof it === "object" && !Array.isArray(it) ? it.text : it, PLAN_ITEM_CHARS);
    if (!text) return null;
    out.push(text);
  }
  return out;
}

export function planParse(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "plan" };
  var summary = askClean(raw.summary, PLAN_SUMMARY_CHARS);
  if (!summary) return { error: "summary" };
  var items = planItems(raw.items);
  if (!items) return { error: "items" };
  var list = raw.changes == null ? [] : raw.changes;
  if (!Array.isArray(list) || list.length > PLAN_CHANGES_MAX) return { error: "changes" };
  var changes = [];
  for (var i = 0; i < list.length; i++) {
    var c = list[i];
    if (!c || typeof c !== "object" || Array.isArray(c)) return { error: "changes" };
    var target = askClean(c.target, PLAN_TARGET_CHARS);
    var what = askClean(c.what, PLAN_WHAT_CHARS);
    if (!target || !what) return { error: "changes" };
    changes.push({ target: target, what: what });
  }
  return { summary: summary, items: items, changes: changes };
}

export function planDecision(pending, ans) {
  var decision = typeof ans.decision === "string" && PLAN_DECISIONS[ans.decision] ? ans.decision : "";
  if (!decision) return { error: "decision" };
  var edits = ans.edits == null ? {} : ans.edits;
  if (!edits || typeof edits !== "object" || Array.isArray(edits)) return { error: "edits" };
  if (edits.note != null && typeof edits.note !== "string") return { error: "edits" };
  var note = planNote(edits.note);
  if (decision === "approve") {
    var items = pending.items;
    var edited = false;
    if (edits.items != null) {
      items = planItems(edits.items);
      if (!items) return { error: "edits" };
      edited = JSON.stringify(items) !== JSON.stringify(pending.items);
    }
    return { decision: "approve", items: items, note: note, edited: edited };
  }
  if (edits.items != null) return { error: "edits" };
  return { decision: decision, note: note };
}

export function planDecisionText(d) {
  if (d.decision === "approve") {
    var user = "";
    if (d.edited) {
      user = "I edited your plan before approving it. Follow this version instead of the one you proposed:\n" +
        d.items.map(function (t, i) { return (i + 1) + ". " + t; }).join("\n");
    }
    if (d.note) user += (user ? "\n\n" : "") + "My note on the plan: " + d.note;
    return {
      text: "The user approved the plan" + (d.edited ? " with edits, which follow in their message" : (d.note ? " with a note, which follows in their message" : "")) +
        ". Carry it out now and keep the checklist current with plan_update.",
      user: user
    };
  }
  if (d.decision === "reject") {
    return {
      text: "The user rejected this plan. Do not change anything. Tell the user briefly that nothing was changed and ask what they want changed.",
      user: d.note ? "Why I rejected the plan: " + d.note : ""
    };
  }
  return {
    text: "The user sent new instructions while this plan waited for approval. Read them, then call " + PLAN_TOOL_NAME + " again with a revised plan before you change anything.",
    user: d.note ? "Please revise the plan: " + d.note : ""
  };
}

export function pendingPlan(id, plan, now) {
  return { kind: "plan", id: id, summary: plan.summary, items: plan.items, changes: plan.changes, expiresAt: (now || Date.now()) + ASK_WAIT_MS };
}

export function planBlock(id, plan) {
  return "<propose_plan>" + JSON.stringify({ id: id, summary: plan.summary, items: plan.items, changes: plan.changes })
    .replace(/</g, "\\u003c").replace(/>/g, "\\u003e") + "</propose_plan>";
}

export function planTake(text) {
  var src = typeof text === "string" ? text : "";
  var last = null;
  var m;
  PLAN_BLOCK_RE.lastIndex = 0;
  while ((m = PLAN_BLOCK_RE.exec(src))) last = m[1];
  var rest = src.replace(PLAN_BLOCK_RE, "");
  var open = rest.search(/<propose_plan\b/);
  if (open !== -1) rest = rest.slice(0, open);
  rest = rest.replace(/\n{3,}/g, "\n\n").replace(/^\s+|\s+$/g, "");
  var plan = null;
  if (last != null) {
    var obj = null;
    try { obj = JSON.parse(last); } catch (e) { obj = null; }
    var parsed = obj && typeof obj === "object" ? planParse(obj) : { error: "json" };
    if (!parsed.error && typeof obj.id === "string" && ASK_ID_RE.test(obj.id)) {
      plan = { id: obj.id, summary: parsed.summary, items: parsed.items, changes: parsed.changes };
    }
  }
  return { text: rest, plan: plan };
}

export function planErrorText(code) {
  var why = {
    plan: "Send the plan as an object.",
    summary: "The plan needs a short summary.",
    items: "The plan needs 1 to " + PLAN_ITEMS_MAX + " steps, each with text.",
    changes: "List at most " + PLAN_CHANGES_MAX + " changes, each with a target and what changes there."
  }[code] || "The plan could not be read.";
  return "Error: no plan was proposed. " + why + " Call " + PLAN_TOOL_NAME + " again with a corrected plan.";
}

export function planPauseReply(text) {
  var said = typeof text === "string" ? text.replace(/^\s+|\s+$/g, "") : "";
  return said || "Here is my plan. Nothing changes until you approve it.";
}

export function planGate(mode, changing, tools) {
  var m = planMode(mode);
  if (m === "never" || !tools) return false;
  return m === "always" ? true : !!changing;
}

export var PLAN_TOOL = {
  type: "function",
  function: {
    name: PLAN_TOOL_NAME,
    description: "Propose your plan to the user and wait for approval. In this chat nothing may change until the user approves a plan: tools that change things fail until then. Read and look around first if you need to, then call this once with a short summary, the steps, and what you will change where. The task waits until the user approves, edits or rejects the plan, and their decision comes back as this tool's result.",
    parameters: {
      type: "object",
      properties: {
        summary: { type: "string", description: "What you will do and why, in one or two sentences (at most " + PLAN_SUMMARY_CHARS + " characters)." },
        items: {
          type: "array", minItems: 1, maxItems: PLAN_ITEMS_MAX,
          description: "The steps, in order, each in a few words (at most " + PLAN_ITEM_CHARS + " characters).",
          items: { type: "string" }
        },
        changes: {
          type: "array", maxItems: PLAN_CHANGES_MAX,
          description: "What will change where: a file, branch, connector or other target, and the change there.",
          items: {
            type: "object",
            properties: {
              target: { type: "string", description: "Where the change happens (at most " + PLAN_TARGET_CHARS + " characters)." },
              what: { type: "string", description: "What changes there (at most " + PLAN_WHAT_CHARS + " characters)." }
            },
            required: ["target", "what"]
          }
        }
      },
      required: ["summary", "items"]
    }
  }
};

export var PLAN_GUIDELINE = "PLAN FIRST: In this chat nothing may change until the user approves a plan. Before any tool that changes something, call " + PLAN_TOOL_NAME +
  " once with a short summary, the steps and the changes per target, then wait. Tools that change things fail until the plan is approved. If the user rejects the plan, change nothing and ask what to change.";
