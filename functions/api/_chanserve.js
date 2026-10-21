import {
  TYPES,
  MAX_BODY,
  MAX_LIFETIME,
  verifyHello,
  serverAccept,
  serverFinish,
  sealCert,
  dropSeal,
  sealFrame,
  openFrame,
  encodeFrame,
  decodeFrame,
  openTurnSeal,
  runRumor,
  parseCert,
  newResumeKey,
  resumeSeal,
  resumeOpen,
  controlSeal,
  controlOpen,
  controlId
} from "./_channel.js";
import { bytesToHex, hexToBytes, randomBytes, sha256, utf8ToBytes, concatBytes, getEventHash, getPublicKey } from "./_shared.js";
import { b64uDecode, wrapDMTo } from "./_pq.js";
import { ASK_WAIT_MS } from "./_ask.js";

var CHAN_MAX_PER_SOCKET = 8;
var CHAN_OPEN_PER_MIN = 30;
var CHAN_MESSAGE_MAX = 16 * 1024 * 1024;
var TURN_PARTS_MAX = 8;
var CHAN_KEEP_MS = 24 * 3600 * 1000;
var CHAN_REPLY_AFTER = 3600;
var CHAN_RESEAL_MARGIN = 300;
var CHAN_DRAFT_EVERY_MS = 250;
var CHAN_JOIN_POLL_MS = 1000;
var CHAN_SNAPSHOT_TTL_S = 900;
var CHAN_STEPS_MAX = 40;
var HEX64 = /^[0-9a-f]{64}$/;
var RUN_ID = /^[\x21-\x7e]{1,128}$/;
var NAMES = {};
Object.keys(TYPES).forEach(function (k) { NAMES[TYPES[k]] = k; });
var ASK_KIND = { question: "question", plan: "plan", mcp: "connector", connector: "connector", tool: "tool", "server-run": "tool", run: "tool" };
var CONTENT_FREE = [
  "balance", "cost", "costCredits", "balanceCredits", "dustMilli", "taskType", "pro", "proModel", "git", "modelCalls",
  "free", "truncated", "capStopped", "stopped", "noCredits", "runCap", "running", "limit", "ceiling", "reserve",
  "nextReserve", "resumeExpiresIn", "retryAfterMs", "stalled", "research", "connectors", "serverRunCredits", "compacted",
  "cache", "required", "resumeExpired", "pendingInvalid", "unavailable", "busy", "rateLimited", "insufficient", "resumable"
];
var META_FIELDS = ["followUps", "sources", "checkpoint", "staged", "actions", "plan", "steerOffer", "steerMissed", "team", "serverRuns"];
var openRate = new Map();
var LIVE = new Map();
var tablesReady = new WeakSet();

function chanRequired(env) {
  return !!env && String(env.STANDALONE_CHANNEL_REQUIRED || "") === "1";
}

function nowSec() {
  return Math.floor(Date.now() / 1000);
}

function codeOf(e) {
  return e && e.chanCode ? e.chanCode : (e && typeof e.code === "string" ? e.code : "malformed");
}

function liveKey(u, run) {
  return u + ":" + run;
}

function resumeId(k) {
  return bytesToHex(sha256(concatBytes(utf8ToBytes("nymbot-chan/1/resume-id"), k))).slice(0, 32);
}

function chanCipher(c, run, u, sealDir) {
  var dir = sealDir || "s2c";
  return {
    seal: function (text) {
      var t = String(text || "");
      if (!t || !c) return "";
      try { return controlSeal({ c: c, dir: dir, run: run, userPk: u, body: t }); } catch (e) { return ""; }
    },
    open: function (blob) {
      if (!blob || !c) return "";
      try { return controlOpen({ c: c, dir: "c2s", run: run, userPk: u, blob: String(blob) }); } catch (e) { }
      try { return controlOpen({ c: c, dir: "s2c", run: run, userPk: u, blob: String(blob) }); } catch (e) { }
      return "";
    }
  };
}

function rateOk(u) {
  var now = Date.now();
  var list = (openRate.get(u) || []).filter(function (t) { return t > now - 60000; });
  if (list.length >= CHAN_OPEN_PER_MIN) {
    openRate.set(u, list);
    return false;
  }
  list.push(now);
  openRate.set(u, list);
  if (openRate.size > 5000) openRate.delete(openRate.keys().next().value);
  return true;
}

async function chanTables(db) {
  if (!db || tablesReady.has(db)) return !!db;
  await db.prepare("CREATE TABLE IF NOT EXISTS chan_runs (pubkey TEXT NOT NULL, run TEXT NOT NULL, ctl_id TEXT, phase TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (pubkey, run))").run();
  await db.prepare("CREATE TABLE IF NOT EXISTS chan_wraps (pubkey TEXT NOT NULL, run TEXT NOT NULL, seq INTEGER NOT NULL, phase TEXT NOT NULL, wrap TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (pubkey, run, seq))").run();
  tablesReady.add(db);
  return true;
}

async function chanRunPut(env, u, run, phase, ctlIdHex) {
  var db = env && env.DB_BOT;
  if (!(await chanTables(db))) return;
  var now = Date.now();
  await db.prepare("INSERT INTO chan_runs (pubkey, run, ctl_id, phase, at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (pubkey, run) DO UPDATE SET ctl_id = excluded.ctl_id, phase = excluded.phase, at = excluded.at")
    .bind(u, run, ctlIdHex || null, phase, now).run();
}

async function chanRunEnd(env, u, run) {
  var db = env && env.DB_BOT;
  if (!(await chanTables(db))) return;
  await db.prepare("UPDATE chan_runs SET phase = 'done', ctl_id = NULL, at = ? WHERE pubkey = ? AND run = ? AND phase = 'bg'").bind(Date.now(), u, run).run();
}

function chanReplyTags(o) {
  var tags = [];
  if (!o) return tags;
  if (o.threadRoot) tags.push(["nymthread", String(o.threadRoot)]);
  if (o.model) tags.push(["model", String(o.model).slice(0, 60)]);
  var link = Array.isArray(o.replyTo) ? o.replyTo.filter(function (v) { return typeof v === "string" && HEX64.test(v.toLowerCase()); }) : [];
  if (link.length) tags.push(["nymreply"].concat(link.slice(0, 2).map(function (v) { return v.toLowerCase(); })));
  var sched = Array.isArray(o.sched) ? o.sched : null;
  if (sched && typeof sched[0] === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(sched[0]) && /^[0-9]{1,16}$/.test(String(sched[1]))) {
    tags.push(["nymsched", sched[0], String(sched[1])]);
  }
  var prw = Array.isArray(o.prw) ? o.prw : null;
  if (prw && typeof prw[0] === "string" && /^[0-9a-f]{32}$/.test(prw[0]) && /^[a-z-]{1,16}$/.test(String(prw[1])) && /^[0-9]{1,9}$/.test(String(prw[2]))) {
    tags.push(["nymprw", prw[0], String(prw[1]), String(prw[2])]);
  }
  return tags;
}

function finishTags(obj, meta, more) {
  var tags = [];
  var ev = obj && obj.event;
  if (ev && Array.isArray(ev.chanTags)) for (var i = 0; i < ev.chanTags.length; i++) tags.push(ev.chanTags[i]);
  if (Object.keys(meta).length) tags.push(["nymbot-meta", JSON.stringify(meta)]);
  return more ? tags.concat(more) : tags;
}

function bgInfo(bg) {
  return { runId: bg.runId, until: bg.until, waiting: bg.waiting, state: bg.state, reason: bg.reason };
}

function pqKemOf(pq) {
  if (typeof pq !== "string" || !pq) return null;
  var kem = null;
  try { kem = { pk: b64uDecode(pq), fmt: "pq2" }; } catch (e) { kem = null; }
  return kem && kem.pk.length === 1184 ? kem : null;
}

async function chanRunGet(env, u, run) {
  var db = env && env.DB_BOT;
  if (!(await chanTables(db))) return null;
  return await db.prepare("SELECT run, ctl_id, phase, at FROM chan_runs WHERE pubkey = ? AND run = ?").bind(u, run).first();
}

async function chanWrapPut(env, u, run, phase, wrap) {
  var db = env && env.DB_BOT;
  if (!(await chanTables(db))) return;
  var now = Date.now();
  var top = await db.prepare("SELECT MAX(seq) AS s FROM chan_wraps WHERE pubkey = ? AND run = ?").bind(u, run).first();
  var seq = (top && Number(top.s) >= 0 ? Number(top.s) : -1) + 1;
  await db.prepare("INSERT INTO chan_wraps (pubkey, run, seq, phase, wrap, at) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(u, run, seq, phase, JSON.stringify(wrap), now).run();
  await db.prepare("DELETE FROM chan_wraps WHERE rowid IN (SELECT rowid FROM chan_wraps WHERE at < ? LIMIT 200)").bind(now - CHAN_KEEP_MS).run();
  await db.prepare("DELETE FROM chan_runs WHERE rowid IN (SELECT rowid FROM chan_runs WHERE at < ? LIMIT 200)").bind(now - CHAN_KEEP_MS).run();
}

async function chanWrapsGet(env, u, run) {
  var db = env && env.DB_BOT;
  if (!(await chanTables(db))) return [];
  var rows = await db.prepare("SELECT seq, phase, wrap FROM chan_wraps WHERE pubkey = ? AND run = ? AND at >= ? ORDER BY seq").bind(u, run, Date.now() - CHAN_KEEP_MS).all();
  return ((rows && rows.results) || []).map(function (r) {
    var w = null;
    try { w = JSON.parse(r.wrap); } catch (e) { w = null; }
    return { seq: Number(r.seq), phase: r.phase, wrap: w };
  }).filter(function (r) { return r.wrap; });
}

function makeSealer(o) {
  var cur = { cert: o.cert, sSk: o.sSk };
  var pqKem = pqKemOf(o.pq);
  return {
    get alive() { return !!cur.sSk; },
    async wrap(run, phase, x) {
      if (!cur.sSk) {
        if (!o.botSk) throw Object.assign(new Error("dead"), { chanCode: "dead" });
        cur = await sealCert({ botSk: o.botSk, userPk: o.userPk });
      }
      var now = nowSec();
      var c = parseCert(cur.cert);
      if (now > c.exp + CHAN_REPLY_AFTER - CHAN_RESEAL_MARGIN && o.botSk) {
        cur = await sealCert({ botSk: o.botSk, userPk: o.userPk });
        c = parseCert(cur.cert);
      }
      var rumor = runRumor({
        cert: cur.cert, run: run, phase: phase, ctl: x.ctl, resume: x.resume, ask: x.ask,
        content: x.content === undefined ? "" : x.content, createdAt: Math.max(now, c.iat)
      });
      if (x.extra) for (var i = 0; i < x.extra.length; i++) rumor.tags.push(x.extra[i]);
      rumor.id = getEventHash(rumor);
      return wrapDMTo(rumor, cur.sSk, c.s, o.userPk, x.pq !== undefined ? pqKemOf(x.pq) : pqKem);
    },
    drop() {
      cur.sSk = null;
    }
  };
}

async function legSealer(botSk, userPk, pq) {
  var minted = await sealCert({ botSk: botSk, userPk: userPk });
  return makeSealer({ cert: minted.cert, sSk: minted.sSk, userPk: userPk, pq: pq, botSk: botSk });
}

function chanLegHooks(env, botSk, u, run, pq, ctl) {
  var st = { k: null, sent: null, c: typeof ctl === "string" && HEX64.test(ctl) ? hexToBytes(ctl) : randomBytes(32) };
  return {
    run: run,
    user: u,
    leg: true,
    pq: pq || null,
    cipher: chanCipher(st.c, run, u, "s2c"),
    ctl: function () { return bytesToHex(st.c); },
    resumeKey: function () {
      if (!st.k) st.k = newResumeKey();
      return { id: resumeId(st.k) };
    },
    resumeSeal: function (r, state) {
      if (!st.k) st.k = newResumeKey();
      return resumeSeal({ k: st.k, run: run, userPk: u, state: JSON.stringify(state) });
    },
    resumeDrop: function () {
      if (st.k) { st.k.fill(0); st.k = null; }
    },
    parkedId: function () { return st.sent; },
    finish: async function (obj) {
      var text = obj && obj.event && typeof obj.event.chanText === "string" ? obj.event.chanText : "";
      var pending = obj ? obj.pendingTool : null;
      var parks = !!(pending && st.k);
      var meta = pick(obj, META_FIELDS);
      if (pending && !parks) meta.pendingTool = pending;
      var wrap = null;
      var carried = false;
      if (obj && obj.event && botSk) {
        var sealer = await legSealer(botSk, u, pq);
        var phase = parks ? "park" : "done";
        wrap = await sealer.wrap(run, phase, {
          resume: st.k ? bytesToHex(st.k) : undefined,
          ask: parks ? askOf(pending) : undefined,
          content: parks ? JSON.stringify({ text: text, pending: pending }) : text,
          extra: finishTags(obj, meta)
        });
        sealer.drop();
        if (st.k) { st.sent = resumeId(st.k); carried = true; st.k.fill(0); st.k = null; }
        await chanWrapPut(env, u, run, phase, wrap);
      }
      var body = pick(obj, CONTENT_FREE);
      body.run = run;
      body.phase = parks ? "park" : "done";
      if (wrap) body.event = wrap;
      if (carried) body.resumable = true;
      if (obj && obj.background) body.background = bgInfo(obj.background);
      return body;
    }
  };
}

function askOf(pending) {
  if (!pending || typeof pending !== "object") return null;
  var kind = ASK_KIND[String(pending.kind || "")] || "tool";
  var q = String(pending.id || pending.q || pending.name || kind).slice(0, 256) || kind;
  return [kind, q];
}

function pick(obj, fields) {
  var out = {};
  if (!obj || typeof obj !== "object") return out;
  for (var i = 0; i < fields.length; i++) {
    if (obj[fields[i]] !== undefined) out[fields[i]] = obj[fields[i]];
  }
  return out;
}

function draftPump(push) {
  var pending = null;
  var timer = null;
  var last = 0;
  var closed = false;
  var seq = 0;
  function flush() {
    timer = null;
    if (closed || pending == null) return;
    var t = pending;
    pending = null;
    last = Date.now();
    seq++;
    push(t, seq);
  }
  return {
    push: function (text) {
      if (closed) return;
      pending = String(text || "");
      if (timer) return;
      var wait = Math.max(0, CHAN_DRAFT_EVERY_MS - (Date.now() - last));
      if (!wait) flush();
      else timer = setTimeout(flush, wait);
    },
    reset: function () {
      if (closed) return;
      pending = "";
      flush();
    },
    close: function () {
      if (timer) { clearTimeout(timer); timer = null; }
      if (!closed && pending != null) flush();
      closed = true;
      return Promise.resolve();
    }
  };
}

function chanHistory(list) {
  var out = [];
  if (!Array.isArray(list)) return out;
  for (var i = 0; i < list.length && out.length < 400; i++) {
    var m = list[i];
    if (!m || typeof m.content !== "string" || !m.content) continue;
    var role = m.role === "assistant" || m.role === "bot" ? "assistant" : (m.role === "user" ? "user" : "");
    if (!role) continue;
    out.push({ role: role, content: m.content, at: Number(m.at) || 0 });
  }
  return out;
}

function chanSocket(o) {
  var env = o.env;
  var chans = new Map();
  var sockKey = null;
  var closed = false;
  var me = {};

  function raw(arr) {
    if (!closed) o.send(arr);
  }

  function out(ch, type, obj) {
    if (!ch.state || ch.state.dead) return false;
    var bytes = obj instanceof Uint8Array ? obj : utf8ToBytes(JSON.stringify(obj));
    try {
      if (bytes.length <= MAX_BODY) {
        raw(["CHAN", ch.n, encodeFrame(sealFrame(ch.state, type, bytes))]);
        return true;
      }
      for (var at = 0; at < bytes.length; at += MAX_BODY) {
        var part = bytes.subarray(at, Math.min(bytes.length, at + MAX_BODY));
        raw(["CHAN", ch.n, encodeFrame(sealFrame(ch.state, type, part, { more: at + MAX_BODY < bytes.length }))]);
      }
      return true;
    } catch (e) {
      drop(ch);
      return false;
    }
  }

  function drop(ch) {
    ch.closed = true;
    if (ch.joinedC) {
      Object.keys(ch.joinedC).forEach(function (r) { ch.joinedC[r].fill(0); });
      ch.joinedC = null;
    }
    if (ch.secret) dropSeal(ch.secret);
    if (ch.sealer) ch.sealer.drop();
    chans.delete(ch.n);
  }

  function abort(ch, code) {
    out(ch, TYPES.ABORT, { code: code });
    drop(ch);
  }

  function runsOf(ch) {
    return ch.runs;
  }

  function fanout(ref, type, obj) {
    ref.watchers.forEach(function (w) {
      if (w.closed || !w.emit || !w.emit(type, obj)) ref.watchers.delete(w);
    });
  }

  function snapshot(ref) {
    var body = JSON.stringify({ draft: ref.draft, seq: ref.seq, plan: ref.plan, steps: ref.steps.slice(-CHAN_STEPS_MAX) });
    var blob = chanCipher(ref.c, ref.run, ref.u, "s2c").seal(body);
    if (!blob || !o.ledger) return;
    try {
      var p = o.ledger({ op: "side-put", keys: ["cs:" + ref.u + ":" + ref.run], side: { b: blob }, ttl: CHAN_SNAPSHOT_TTL_S });
      if (p && p.then) p.then(function () { }, function () { });
    } catch (e) { }
  }

  function hooksFor(ch, ref, sealer, extra) {
    var pump = draftPump(function (text, seq) {
      ref.draft = text;
      ref.seq = seq;
      fanout(ref, TYPES.DRAFT, { run: ref.run, seq: seq, text: text });
      snapshot(ref);
    });
    return Object.assign({
      run: ref.run,
      user: ref.u,
      pq: ref.pq,
      resumeTaken: ref.resumeTaken || null,
      cipher: chanCipher(ref.c, ref.run, ref.u, "s2c"),
      ctl: function () { return ref.c ? bytesToHex(ref.c) : null; },
      draft: function () { return pump; },
      step: function (step) {
        if (!step || typeof step !== "object") return;
        if (step.kind === "plan" && Array.isArray(step.items)) {
          ref.plan = step.items;
          fanout(ref, TYPES.PLAN, { run: ref.run, plan: step.items });
        } else {
          ref.steps.push(step);
          if (ref.steps.length > CHAN_STEPS_MAX) ref.steps.shift();
          fanout(ref, TYPES.STEP, { run: ref.run, step: step });
        }
        snapshot(ref);
      },
      resumeKey: function () {
        if (!ref.k) ref.k = newResumeKey();
        return { id: resumeId(ref.k) };
      },
      resumeSeal: function (run, state) {
        if (!ref.k && !ref.resumeK) ref.k = newResumeKey();
        return resumeSeal({ k: ref.k || ref.resumeK, run: run, userPk: ref.u, state: JSON.stringify(state) });
      },
      resumeDrop: function () {
        if (ref.k) { ref.k.fill(0); ref.k = null; }
      },
      resumeOpen: function (blob) {
        if (!ref.resumeK) return null;
        try { return { state: JSON.parse(resumeOpen({ k: ref.resumeK, run: ref.run, userPk: ref.u, blob: blob })) }; } catch (e) { return null; }
      },
      finish: async function (obj, status) {
        var text = obj && obj.event && typeof obj.event.chanText === "string" ? obj.event.chanText : "";
        var pending = obj ? obj.pendingTool : null;
        var parks = !!(pending && ref.k);
        var meta = pick(obj, META_FIELDS);
        var tags = finishTags(obj, meta, typeof ref.summaryOut === "string" && ref.summaryOut ? [["nymbot-summary", ref.summaryOut, String(ref.summaryUpto || 0)]] : null);
        var phase = parks ? "park" : "done";
        var wrap = null;
        var carried = false;
        if (obj && obj.event) {
          wrap = await sealer.wrap(ref.run, phase, {
            resume: ref.k ? bytesToHex(ref.k) : undefined,
            ask: parks ? askOf(pending) : undefined,
            content: parks ? JSON.stringify({ text: text, pending: pending }) : text,
            extra: tags,
            pq: ref.pq
          });
          sealer.drop();
          if (ref.k) { carried = true; ref.k.fill(0); ref.k = null; }
          await chanWrapPut(env, ref.u, ref.run, phase, wrap);
        }
        ref.phase = phase;
        var toBg = !!(obj && obj.background && obj.background.runId && ref.c && !parks);
        if (toBg) {
          ref.watchers.forEach(function (w) {
            if (w.closed) return;
            w.joinedC = w.joinedC || {};
            if (w.joinedC[ref.run]) w.joinedC[ref.run].fill(0);
            w.joinedC[ref.run] = ref.c.slice();
          });
        }
        await chanRunPut(env, ref.u, ref.run, toBg ? "bg" : phase, toBg ? controlId(ref.c) : null);
        if (ref.c) { ref.c.fill(0); ref.c = null; }
        LIVE.delete(liveKey(ref.u, ref.run));
        var body = pick(obj, CONTENT_FREE);
        body.run = ref.run;
        body.phase = phase;
        if (wrap) body.event = wrap;
        if (obj && obj.error) body.failed = true;
        if (carried) body.resumable = true;
        if (obj && obj.background) body.background = bgInfo(obj.background);
        return body;
      }
    }, extra || {});
  }

  async function startRun(ch, run, mode, turn) {
    var c = randomBytes(32);
    var ref = LIVE.get(liveKey(ch.u, run));
    if (ref && ref.c && mode === "turn") {
      out(ch, TYPES.ERROR, { run: run, code: "busy" });
      return null;
    }
    ref = { run: run, u: ch.u, c: c, k: null, resumeK: null, pq: turn && typeof turn.pq === "string" ? turn.pq : null, watchers: new Set([ch]), draft: "", seq: 0, plan: null, steps: [], phase: "live", home: me };
    LIVE.set(liveKey(ch.u, run), ref);
    ch.runs.add(run);
    try {
      ch.sealer = ch.sealer || makeSealer({ cert: ch.cert, sSk: ch.secret.sSk, userPk: ch.u, pq: ref.pq, botSk: o.botSk });
      var live = await ch.sealer.wrap(run, "live", { ctl: bytesToHex(c), pq: ref.pq });
      await chanRunPut(env, ch.u, run, "live", controlId(c));
      await chanWrapPut(env, ch.u, run, "live", live);
    } catch (e) {
      if (LIVE.get(liveKey(ch.u, run)) === ref) LIVE.delete(liveKey(ch.u, run));
      ch.runs.delete(run);
      c.fill(0);
      throw e;
    }
    out(ch, TYPES.ACCEPT, { run: run, wrap: live });
    return ref;
  }

  async function runLeg(ch, ref, body, extra) {
    var hooks = hooksFor(ch, ref, ch.sealer, extra);
    var started = Date.now();
    var res;
    try {
      res = await o.call(hooks, body);
    } catch (e) {
      res = null;
    }
    var data = null;
    try { data = res ? await res.json() : null; } catch (e) { data = null; }
    var status = res ? res.status : 500;
    if (data && data.event && data.phase) {
      var done = pick(data, CONTENT_FREE);
      if (data.background) done.background = data.background;
      fanout(ref, data.phase === "park" ? TYPES.PARK : TYPES.REPLY, { run: ref.run, wrap: data.event, info: done });
    } else {
      var info = pick(data, CONTENT_FREE);
      if (data && typeof data.error === "string") info.message = data.error;
      fanout(ref, TYPES.ERROR, { run: ref.run, code: status === 402 || (data && data.noCredits) ? "credits" : (status === 429 ? "rate" : "failed"), info: info });
      if (ref.c) { ref.c.fill(0); ref.c = null; }
      LIVE.delete(liveKey(ref.u, ref.run));
      await chanRunPut(env, ref.u, ref.run, "failed", null);
    }
    ref.ms = Date.now() - started;
    return data;
  }

  function joinTurnSeals(ch, seals) {
    var bad = function () { return Object.assign(new Error("malformed"), { chanCode: "malformed" }); };
    if (seals.length < 2 || seals.length > TURN_PARTS_MAX) throw bad();
    var got = seals.map(function (s) { return openTurnSeal({ secret: ch.secret, seal: s }); });
    var x = null;
    var at = [];
    for (var i = 0; i < got.length; i++) {
      var tags = got[i].tags;
      var xt = tags.filter(function (tg) { return Array.isArray(tg) && tg[0] === "x"; })[0];
      var pt = tags.filter(function (tg) { return Array.isArray(tg) && tg[0] === "part"; })[0];
      var n = pt ? parseInt(pt[1], 10) : 0;
      if (!xt || !HEX64.test(String(xt[1])) || (x !== null && xt[1] !== x)) throw bad();
      if (!pt || String(pt[2]) !== String(got.length) || !(n >= 1 && n <= got.length) || at[n]) throw bad();
      x = xt[1];
      at[n] = got[i];
    }
    return Object.assign({}, at[1], {
      content: at.slice(1).map(function (r) { return r.content; }).join(""),
      tags: at[1].tags.filter(function (tg) { return !(Array.isArray(tg) && tg[0] === "part"); })
    });
  }

  async function onTurn(ch, t) {
    if (!t || typeof t !== "object") throw Object.assign(new Error("malformed"), { chanCode: "malformed" });
    var rumor = Array.isArray(t.seal) ? joinTurnSeals(ch, t.seal) : openTurnSeal({ secret: ch.secret, seal: t.seal });
    if (!rumor.id) rumor.id = getEventHash(Object.assign({ created_at: 0 }, rumor));
    var x = (rumor.tags || []).filter(function (tg) { return Array.isArray(tg) && tg[0] === "x"; })[0];
    var run = x && HEX64.test(String(x[1])) ? String(x[1]) : String(rumor.id);
    if (!RUN_ID.test(run)) throw Object.assign(new Error("malformed"), { chanCode: "malformed" });
    var ref = await startRun(ch, run, "turn", t);
    if (!ref) return;
    var opts = t.opts && typeof t.opts === "object" && !Array.isArray(t.opts) ? t.opts : {};
    var body = Object.assign({}, opts, { action: "pm", pubkey: ch.u, eventId: String(rumor.id), draft: true });
    delete body.wrap;
    delete body.wraps;
    delete body.history;
    delete body.resume;
    var chanTurn = {
      rumor: rumor,
      history: chanHistory(t.history),
      summary: typeof t.summary === "string" ? t.summary.slice(0, 8000) : "",
      fold: chanHistory(t.fold),
      attachments: Array.isArray(t.attachments) ? t.attachments.slice(0, 32) : [],
      pq: typeof t.pq === "string" ? t.pq : null,
      setSummary: function (text, upto) { ref.summaryOut = text; ref.summaryUpto = upto; }
    };
    return await runLeg(ch, ref, body, { turn: chanTurn });
  }

  async function onResume(ch, b) {
    if (!b || typeof b.run !== "string" || !RUN_ID.test(b.run) || typeof b.k !== "string" || !HEX64.test(b.k)) {
      throw Object.assign(new Error("malformed"), { chanCode: "malformed" });
    }
    ch.pendingResume = { run: b.run, k: hexToBytes(b.k), pq: typeof b.pq === "string" ? b.pq : null, opts: b.opts && typeof b.opts === "object" && !Array.isArray(b.opts) ? b.opts : {} };
    if (b.go === true) return o.waitUntil(onAnswer(ch, TYPES.RESUME, { run: b.run }).catch(function (e) { abort(ch, codeOf(e)); }));
    return null;
  }

  async function takeResume(ch, run, k) {
    if (!o.ledger) return { _noLedger: true };
    var took = null;
    try { took = await o.ledger({ op: "resume-take", id: resumeId(k), owner: ch.u }); } catch (e) { took = null; }
    if (took && took._noLedger) return took;
    if (!took || !took.ok || !took.state) return null;
    var opened = null;
    try { opened = JSON.parse(resumeOpen({ k: k, run: run, userPk: ch.u, blob: took.state })); } catch (e) { return null; }
    if (opened && opened.pending) took.ttl = Math.floor(ASK_WAIT_MS / 1000);
    return took;
  }

  async function onAnswer(ch, type, b) {
    var pr = ch.pendingResume;
    if (!b || typeof b.run !== "string") throw Object.assign(new Error("malformed"), { chanCode: "malformed" });
    if (!pr || pr.run !== b.run) {
      var live = LIVE.get(liveKey(ch.u, b.run));
      if (live && live.watchers.has(ch) && type === TYPES.APPROVE && b.kind !== "plan") {
        return await control(ch, { action: b.ok ? "pm-steer" : "pm-cancel", replyTo: b.run, text: b.ok ? "Approved." : undefined });
      }
      out(ch, TYPES.ERROR, { run: b.run, code: "no-run" });
      return null;
    }
    ch.pendingResume = null;
    var took = await takeResume(ch, b.run, pr.k);
    if (!took) {
      pr.k.fill(0);
      out(ch, TYPES.ERROR, { run: b.run, code: "no-run" });
      return null;
    }
    var ref = null;
    try {
      ref = await startRun(ch, b.run, "resume", { pq: pr.pq });
    } catch (e) {
      if (!took._noLedger) {
        try { await o.ledger({ op: "resume-put", id: resumeId(pr.k), owner: ch.u, state: took.state, ttl: took.ttl }); } catch (e2) { }
      }
      pr.k.fill(0);
      out(ch, TYPES.ERROR, { run: b.run, code: "failed" });
      return null;
    }
    if (!ref) return null;
    ref.resumeK = pr.k;
    ref.resumeTaken = took;
    var body = Object.assign({}, pr.opts, { action: "pm", pubkey: ch.u, resume: resumeId(pr.k), draft: true });
    delete body.wrap;
    delete body.wraps;
    delete body.history;
    delete body.eventId;
    var text = "";
    if (type === TYPES.RESUME) {
      text = "Carry on.";
    } else if (type === TYPES.ANSWER) {
      body.pendingAnswer = { id: String(b.q || ""), answers: b.answer };
      text = typeof b.text === "string" && b.text ? b.text : (typeof b.answer === "string" ? b.answer : JSON.stringify(b.answer || ""));
    } else if (b.kind === "plan") {
      body.pendingAnswer = { id: String(b.id || ""), decision: b.ok ? "approve" : "decline", edits: b.edits };
      text = b.ok ? "Approved." : "Declined.";
    } else if (b.kind === "tool") {
      if (b.ok) body.runApprove = String(b.id || "");
      else body.runDecline = String(b.id || "");
      text = b.ok ? "Approved." : "Declined.";
    } else {
      if (b.ok) body.mcpApprove = String(b.id || "");
      else body.mcpDecline = String(b.id || "");
      text = b.ok ? "Approved." : "Declined.";
    }
    var msgId = bytesToHex(randomBytes(32));
    var rumor = { kind: 14, pubkey: ch.u, created_at: nowSec(), tags: [["x", msgId]], content: text.slice(0, 20000) };
    rumor.id = getEventHash(rumor);
    body.eventId = rumor.id;
    var data = await runLeg(ch, ref, body, { turn: { rumor: rumor, history: [], summary: "", fold: [], attachments: [], pq: pr.pq, resumed: true, setSummary: function () { } } });
    if (ref.resumeK) { ref.resumeK.fill(0); ref.resumeK = null; }
    pr.k.fill(0);
    return data;
  }

  async function control(ch, body) {
    var ref = LIVE.get(liveKey(ch.u, body.replyTo));
    var c = ref && ref.c ? ref.c : (ch.joinedC && ch.joinedC[body.replyTo]) || null;
    if (!c && body.action !== "pm-cancel") {
      out(ch, TYPES.ERROR, { run: body.replyTo, code: "no-run" });
      return null;
    }
    var hooks = { run: body.replyTo, user: ch.u, cipher: chanCipher(c, body.replyTo, ch.u, "c2s"), control: true };
    var res = await o.call(hooks, Object.assign({ pubkey: ch.u }, body));
    var data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (!res || res.status >= 400) out(ch, TYPES.ERROR, { run: body.replyTo, code: res && res.status === 404 ? "no-run" : "failed" });
    return data;
  }

  async function onJoin(ch, b) {
    if (!b || typeof b.run !== "string" || !RUN_ID.test(b.run) || typeof b.c !== "string" || !HEX64.test(b.c)) {
      throw Object.assign(new Error("malformed"), { chanCode: "malformed" });
    }
    var c = hexToBytes(b.c);
    var want = controlId(c);
    var ref = LIVE.get(liveKey(ch.u, b.run));
    if (ref && ref.c && ref.home === me && controlId(ref.c) === want) {
      ref.watchers.add(ch);
      ch.runs.add(b.run);
      out(ch, TYPES.ACCEPT, { run: b.run, wrap: null });
      if (ref.plan) out(ch, TYPES.PLAN, { run: b.run, plan: ref.plan });
      if (ref.draft) out(ch, TYPES.DRAFT, { run: b.run, seq: ref.seq, text: ref.draft });
      return;
    }
    var row = await chanRunGet(env, ch.u, b.run);
    if (!row || !row.ctl_id || row.ctl_id !== want || (row.phase !== "live" && row.phase !== "bg")) {
      c.fill(0);
      out(ch, TYPES.ERROR, { run: b.run, code: "no-run" });
      return;
    }
    ch.joinedC = ch.joinedC || {};
    if (ch.joinedC[b.run]) ch.joinedC[b.run].fill(0);
    ch.joinedC[b.run] = c;
    ch.runs.add(b.run);
    out(ch, TYPES.ACCEPT, { run: b.run, wrap: null });
    if (row.phase === "live") pollJoined(ch, b.run, c);
  }

  function pollJoined(ch, run, c) {
    var seenSeq = -1;
    var seenPlan = "";
    var seenSteps = 0;
    var tick = async function () {
      var snap = null;
      if (o.ledger) {
        try {
          var got = await o.ledger({ op: "side-get", key: "cs:" + ch.u + ":" + run });
          var blob = got && got.side && got.side.b;
          snap = blob ? JSON.parse(controlOpen({ c: c, dir: "s2c", run: run, userPk: ch.u, blob: blob })) : null;
        } catch (e) { snap = null; }
      }
      if (snap) {
        var planText = JSON.stringify(snap.plan || null);
        if (snap.plan && planText !== seenPlan) { seenPlan = planText; out(ch, TYPES.PLAN, { run: run, plan: snap.plan }); }
        var steps = Array.isArray(snap.steps) ? snap.steps : [];
        for (var i = Math.min(seenSteps, steps.length); i < steps.length; i++) out(ch, TYPES.STEP, { run: run, step: steps[i] });
        seenSteps = steps.length;
        if (Number(snap.seq) > seenSeq) { seenSeq = Number(snap.seq); out(ch, TYPES.DRAFT, { run: run, seq: snap.seq, text: snap.draft }); }
      }
      var row = await chanRunGet(env, ch.u, run);
      if (row && row.phase !== "live") {
        var wraps = await chanWrapsGet(env, ch.u, run);
        var last = wraps.length ? wraps[wraps.length - 1] : null;
        if (last && (last.phase === "done" || last.phase === "park")) out(ch, last.phase === "park" ? TYPES.PARK : TYPES.REPLY, { run: run, wrap: last.wrap });
        else out(ch, TYPES.ERROR, { run: run, code: "failed" });
        return true;
      }
      return false;
    };
    var loop = async function () {
      try {
        while (!closed && chans.has(ch.n) && ch.state && !ch.state.dead && nowSec() < ch.state.exp) {
          if (await tick()) break;
          await new Promise(function (r) { setTimeout(r, CHAN_JOIN_POLL_MS); });
        }
      } finally {
        c.fill(0);
        if (ch.joinedC && ch.joinedC[run] === c) delete ch.joinedC[run];
      }
    };
    o.waitUntil(loop());
  }

  async function dispatch(ch, type, body) {
    var b = null;
    if (type !== TYPES.ATTACH) {
      try { b = JSON.parse(new TextDecoder().decode(body)); } catch (e) { throw Object.assign(new Error("malformed"), { chanCode: "malformed" }); }
    }
    switch (type) {
      case TYPES.TURN: return o.waitUntil(onTurn(ch, b).catch(function (e) { abort(ch, codeOf(e)); }));
      case TYPES.RESUME: return await onResume(ch, b);
      case TYPES.ANSWER:
      case TYPES.APPROVE: return o.waitUntil(onAnswer(ch, type, b).catch(function (e) { abort(ch, codeOf(e)); }));
      case TYPES.JOIN: return await onJoin(ch, b);
      case TYPES.STEER:
        if (!b || typeof b.run !== "string" || typeof b.text !== "string") throw Object.assign(new Error("malformed"), { chanCode: "malformed" });
        return await control(ch, { action: "pm-steer", replyTo: b.run, text: b.text });
      case TYPES.CANCEL:
        if (!b || typeof b.run !== "string") throw Object.assign(new Error("malformed"), { chanCode: "malformed" });
        return await control(ch, { action: "pm-cancel", replyTo: b.run });
      case TYPES.ATTACH: return null;
      case TYPES.CLOSE:
        out(ch, TYPES.CLOSE, {});
        drop(ch);
        return null;
      case TYPES.ABORT:
        drop(ch);
        return null;
      default: throw Object.assign(new Error("type"), { chanCode: "type" });
    }
  }

  async function onOpen(hello, auth) {
    var n = hello && typeof hello.n === "string" ? hello.n : "";
    if (!HEX64.test(n)) { raw(["CHAN_ERR", n, "malformed"]); return; }
    if (chans.has(n)) { raw(["CHAN_ERR", n, "malformed"]); return; }
    if (chans.size >= CHAN_MAX_PER_SOCKET) { raw(["CHAN_ERR", n, "busy"]); return; }
    if (!o.botSk) { raw(["CHAN_ERR", n, "unavailable"]); return; }
    try {
      verifyHello(hello, auth, o.url);
    } catch (e) {
      raw(["CHAN_ERR", n, codeOf(e)]);
      return;
    }
    if (sockKey && sockKey !== hello.u) { raw(["CHAN_ERR", n, "busy"]); return; }
    if (!rateOk(hello.u)) { raw(["CHAN_ERR", n, "rate"]); return; }
    if (o.authFresh && !(await o.authFresh(auth))) { raw(["CHAN_ERR", n, "auth"]); return; }
    var acc;
    try {
      acc = await serverAccept({ hello: hello, authId: auth.id, botSk: o.botSk });
    } catch (e) {
      raw(["CHAN_ERR", n, codeOf(e)]);
      return;
    }
    var made = { n: n, u: hello.u, cert: acc.cert, secret: acc.secret, state: null, rx: null, runs: new Set(), sealer: null, closed: false };
    made.emit = function (type, obj) { return !closed && out(made, type, obj); };
    if (sockKey && sockKey !== hello.u) { raw(["CHAN_ERR", n, "busy"]); return; }
    sockKey = hello.u;
    chans.set(n, made);
    raw(["CHAN_CERT", n, acc.cert]);
  }

  async function onKey(n, ct) {
    var ch = chans.get(n);
    if (!ch) { raw(["CHAN_ERR", n, "malformed"]); return; }
    var kemCt;
    try {
      kemCt = b64uDecode(String(ct || ""));
    } catch (e) {
      kemCt = null;
    }
    try {
      ch.state = (await serverFinish({ secret: ch.secret, kemCt: kemCt })).state;
    } catch (e) {
      raw(["CHAN_ERR", n, codeOf(e)]);
      drop(ch);
    }
  }

  async function onFrame(n, text) {
    var ch = chans.get(n);
    if (!ch || !ch.state) { raw(["CHAN_ERR", n, "malformed"]); return; }
    var f;
    try {
      f = openFrame(ch.state, decodeFrame(text));
    } catch (e) {
      raw(["CHAN_ERR", n, codeOf(e)]);
      drop(ch);
      return;
    }
    if (ch.rx && ch.rx.type !== f.type) { abort(ch, "malformed"); return; }
    if (!ch.rx) ch.rx = { type: f.type, parts: [], size: 0 };
    ch.rx.parts.push(f.body);
    ch.rx.size += f.body.length;
    if (ch.rx.size > CHAN_MESSAGE_MAX) { abort(ch, "oversize"); return; }
    if (f.more) return;
    var whole = ch.rx.parts.length === 1 ? ch.rx.parts[0] : concatBytes.apply(null, ch.rx.parts);
    ch.rx = null;
    try {
      await dispatch(ch, f.type, whole);
    } catch (e) {
      abort(ch, codeOf(e));
    }
  }

  return {
    handles: function (type) {
      return type === "CHAN_OPEN" || type === "CHAN_KEY" || type === "CHAN";
    },
    handle: async function (msg) {
      var type = msg[0];
      if (type === "CHAN_OPEN") return await onOpen(msg[1], msg[2]);
      if (type === "CHAN_KEY") return await onKey(String(msg[1] || ""), msg[2]);
      if (type === "CHAN") return await onFrame(String(msg[1] || ""), msg[2]);
    },
    close: function () {
      closed = true;
      chans.forEach(function (ch) { drop(ch); });
    },
    get size() { return chans.size; }
  };
}

export {
  CHAN_MAX_PER_SOCKET,
  CHAN_KEEP_MS,
  chanRequired,
  chanSocket,
  chanCipher,
  chanHistory,
  chanWrapsGet,
  chanRunGet,
  chanRunEnd,
  chanReplyTags,
  chanLegHooks,
  legSealer,
  makeSealer,
  resumeId,
  LIVE as CHAN_LIVE
};
