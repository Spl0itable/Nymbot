const DRIVER_LEASE_MS = 10 * 60 * 1000;
const DRIVER_BACKOFF_MS = [30000, 120000, 600000];
const DRIVER_POLL_MS = 30000;
const DRIVER_MAX_MS = 6 * 3600 * 1000;
const DRIVER_CALL_MS = 11 * 60 * 1000;
const DRIVER_SCHED_MAX = 10;
const DRIVER_SCHED_RETRY_MS = 5 * 60 * 1000;
const DRIVER_SCHED_FAIL_MAX = 3;
const DRIVER_SWEEP_BATCH = 500;
const DRIVER_FATAL = { 400: true, 401: true, 403: true, 404: true, 409: true, 410: true, 413: true };
const DRIVER_QUEUE_RETRY_S = 30;
const DRIVER_END_TRIES = 3;
const DRIVER_KINDS = { leg: true, end: true, sched: true };

function driverHex(bytes) {
  const b = new Uint8Array(bytes);
  let out = "";
  for (let i = 0; i < b.length; i++) out += (b[i] < 16 ? "0" : "") + b[i].toString(16);
  return out;
}

async function driverSign(secret, pk, runId, leg, ts) {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(String(secret)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return driverHex(await crypto.subtle.sign("HMAC", k, enc.encode(String(pk).toLowerCase() + "|" + runId + "|" + leg + "|" + ts)));
}

function driverDay(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

function driverNum(v, d) {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
}

function driverTok() {
  return driverHex(crypto.getRandomValues(new Uint8Array(16)));
}

async function driverPost(env, pk, action, runId, leg, extra) {
  const origin = String(env.PAGES_ORIGIN || "").replace(/\/+$/, "");
  const secret = String(env.BG_HMAC_KEY || "");
  if (!pk || !origin || secret.length < 32) return { status: 0, data: null };
  const ts = Date.now();
  const sig = await driverSign(secret, pk, runId, leg, ts);
  const body = Object.assign({ action: action, pubkey: pk, runId: runId, leg: leg, ts: ts, sig: sig }, extra || {});
  const wait = driverNum(env.DRIVER_CALL_MS, DRIVER_CALL_MS);
  let timer = null;
  const ctl = new AbortController();
  try {
    timer = setTimeout(() => ctl.abort(), wait);
    const res = await fetch(origin + "/api/bot", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Origin": origin, "User-Agent": "NymbotDriver/1" },
      body: JSON.stringify(body),
      signal: ctl.signal
    });
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    return { status: res.status, data: data };
  } catch (e) {
    return { status: ctl.signal.aborted ? 202 : 0, data: null, timeout: ctl.signal.aborted };
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function driverOp(ns, pk, msg) {
  const stub = ns.get(ns.idFromName("u:" + pk));
  const res = await stub.fetch("https://driver/op", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(Object.assign({ pubkey: pk }, msg))
  });
  if (res.status >= 500) throw new Error("driver " + res.status);
  return await res.json();
}

async function driverConsumeOne(msg, env) {
  const b = msg && msg.body && typeof msg.body === "object" ? msg.body : {};
  const pk = typeof b.pubkey === "string" && /^[0-9a-f]{64}$/.test(b.pubkey) ? b.pubkey : "";
  if (!pk || !DRIVER_KINDS[b.kind] || typeof b.id !== "string" || !b.id || typeof b.tok !== "string" || !/^[0-9a-f]{32}$/.test(b.tok)) {
    msg.ack();
    return;
  }
  const ns = env.RUN_DRIVER;
  if (!ns || typeof ns.idFromName !== "function") {
    msg.retry({ delaySeconds: DRIVER_QUEUE_RETRY_S });
    return;
  }
  const ask = { kind: b.kind, id: b.id, leg: String(b.leg == null ? "" : b.leg), tok: b.tok };
  let claim = null;
  try {
    claim = await driverOp(ns, pk, Object.assign({ drive: "claim" }, ask));
  } catch (e) {
    msg.retry({ delaySeconds: DRIVER_QUEUE_RETRY_S });
    return;
  }
  if (!claim || !claim.go) {
    msg.ack();
    return;
  }
  const out = await driverPost(env, pk, claim.action, claim.runId, claim.leg, claim.extra);
  const report = Object.assign({ drive: "report", status: out.status, data: out.data, day: claim.day || "" }, ask);
  let rep = null;
  for (let i = 0; i < 2 && !rep; i++) {
    try { rep = await driverOp(ns, pk, report); } catch (e) { rep = null; }
  }
  if (rep && driverNum(rep.retry, 0) > 0) {
    msg.retry({ delaySeconds: Math.ceil(driverNum(rep.retry, DRIVER_QUEUE_RETRY_S)) });
    return;
  }
  msg.ack();
}

export async function driverConsume(batch, env) {
  const list = batch && Array.isArray(batch.messages) ? batch.messages : [];
  for (const msg of list) await driverConsumeOne(msg, env || {});
}

export class NymRunDriver {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env || {};
    this.sql = ctx.storage.sql;
    this.ready = false;
  }

  init() {
    if (this.ready) return;
    this.sql.exec("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)");
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS runs (run_id TEXT PRIMARY KEY, blob TEXT NOT NULL, leg INTEGER NOT NULL, " +
      "state TEXT NOT NULL, next_at INTEGER NOT NULL, lease_until INTEGER NOT NULL DEFAULT 0, " +
      "tries INTEGER NOT NULL DEFAULT 0, until_at INTEGER NOT NULL, created_at INTEGER NOT NULL)"
    );
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS scheds (id TEXT PRIMARY KEY, mode TEXT NOT NULL, sha TEXT NOT NULL, blob TEXT NOT NULL, " +
      "next_at INTEGER NOT NULL, step INTEGER NOT NULL DEFAULT 0, expires_at INTEGER NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, " +
      "fails INTEGER NOT NULL DEFAULT 0, retry INTEGER NOT NULL DEFAULT 0, day TEXT NOT NULL DEFAULT '', " +
      "runs_day INTEGER NOT NULL DEFAULT 0, last_at INTEGER NOT NULL DEFAULT 0, last_state TEXT NOT NULL DEFAULT '', " +
      "lease_until INTEGER NOT NULL DEFAULT 0)"
    );
    this.sql.exec("CREATE TABLE IF NOT EXISTS idx (pubkey TEXT PRIMARY KEY, at INTEGER NOT NULL)");
    this.sql.exec(
      "CREATE TABLE IF NOT EXISTS ends (run_id TEXT PRIMARY KEY, blob TEXT NOT NULL, tok TEXT NOT NULL DEFAULT '', " +
      "claim INTEGER NOT NULL DEFAULT 0, lease_until INTEGER NOT NULL DEFAULT 0, tries INTEGER NOT NULL DEFAULT 0)"
    );
    if (this.metaGet("schema") !== "2") {
      for (const t of ["runs", "scheds"]) {
        try { this.sql.exec("ALTER TABLE " + t + " ADD COLUMN tok TEXT NOT NULL DEFAULT ''"); } catch (e) { }
        try { this.sql.exec("ALTER TABLE " + t + " ADD COLUMN claim INTEGER NOT NULL DEFAULT 0"); } catch (e) { }
      }
      this.metaSet("schema", "2");
    }
    this.ready = true;
  }

  rows(q, ...binds) {
    return this.sql.exec(q, ...binds).toArray();
  }

  metaGet(k) {
    const r = this.rows("SELECT v FROM meta WHERE k = ?", k);
    return r.length ? r[0].v : null;
  }

  metaSet(k, v) {
    this.sql.exec("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, String(v));
  }

  now() {
    return Date.now();
  }

  reply(obj, status) {
    return new Response(JSON.stringify(obj), { status: status || 200, headers: { "Content-Type": "application/json" } });
  }

  async fetch(request) {
    this.init();
    let body;
    try { body = await request.json(); } catch (e) { return this.reply({ error: "bad json" }, 400); }
    const op = body && body.drive;
    if (op === "index-add" || op === "index-drop" || op === "index-sweep") return this.reply(await this.indexOp(op, body));
    const pk = typeof body.pubkey === "string" && /^[0-9a-f]{64}$/.test(body.pubkey) ? body.pubkey : "";
    if (!pk) return this.reply({ error: "bad pubkey" }, 400);
    const known = this.metaGet("pubkey");
    if (known && known !== pk) return this.reply({ error: "wrong object" }, 400);
    if (!known) this.metaSet("pubkey", pk);
    switch (op) {
      case "run-put": return this.reply(await this.runPut(body));
      case "run-cancel": return this.reply(await this.runCancel(body));
      case "run-list": return this.reply(this.runList());
      case "sched-put": return this.reply(await this.schedPut(body));
      case "sched-delete": return this.reply(await this.schedDelete(body));
      case "sched-clear": return this.reply(await this.schedClear());
      case "sched-list": return this.reply(this.schedList());
      case "clear": return this.reply(await this.clearAll());
      case "sweep": return this.reply(await this.sweep());
      case "claim": return this.reply(this.claim(body));
      case "report": return this.reply(await this.report(body));
      case "alarm": await this.alarm(); return this.reply({ ok: true });
      default: return this.reply({ error: "unknown op" }, 400);
    }
  }

  async indexOp(op, body) {
    if (op === "index-add") {
      if (typeof body.pubkey !== "string" || !/^[0-9a-f]{64}$/.test(body.pubkey)) return { ok: false };
      this.sql.exec("INSERT INTO idx (pubkey, at) VALUES (?, ?) ON CONFLICT(pubkey) DO UPDATE SET at = excluded.at", body.pubkey, this.now());
      return { ok: true };
    }
    if (op === "index-drop") {
      this.sql.exec("DELETE FROM idx WHERE pubkey = ?", String(body.pubkey || ""));
      return { ok: true };
    }
    const list = this.rows("SELECT pubkey FROM idx ORDER BY at LIMIT ?", DRIVER_SWEEP_BATCH);
    let swept = 0;
    for (const r of list) {
      const out = await this.peer(r.pubkey, { drive: "sweep" });
      swept++;
      if (out && out.empty) this.sql.exec("DELETE FROM idx WHERE pubkey = ?", r.pubkey);
      else this.sql.exec("UPDATE idx SET at = ? WHERE pubkey = ?", this.now(), r.pubkey);
    }
    return { ok: true, swept: swept };
  }

  async peer(pk, msg) {
    const ns = this.env.RUN_DRIVER;
    if (!ns || typeof ns.idFromName !== "function") return null;
    try {
      const stub = ns.get(ns.idFromName(pk === "index" ? "index" : "u:" + pk));
      const res = await stub.fetch("https://driver/op", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(Object.assign({}, msg, pk === "index" ? {} : { pubkey: pk }))
      });
      return await res.json();
    } catch (e) {
      return null;
    }
  }

  async indexed(on) {
    const pk = this.metaGet("pubkey");
    if (!pk) return;
    const was = this.metaGet("indexed") === "1";
    if (on === was) return;
    this.metaSet("indexed", on ? "1" : "0");
    await this.peer("index", { drive: on ? "index-add" : "index-drop", pubkey: pk });
  }

  empty() {
    const a = this.rows("SELECT COUNT(*) AS n FROM runs")[0].n;
    const b = this.rows("SELECT COUNT(*) AS n FROM scheds")[0].n;
    const c = this.rows("SELECT COUNT(*) AS n FROM ends")[0].n;
    return Number(a) + Number(b) + Number(c) === 0;
  }

  async arm() {
    const now = this.now();
    const cands = [];
    const r = this.rows("SELECT MIN(CASE WHEN state = 'leased' THEN lease_until ELSE next_at END) AS t FROM runs")[0];
    if (r && r.t != null) cands.push(Number(r.t));
    const u = this.rows("SELECT MIN(until_at) AS t FROM runs")[0];
    if (u && u.t != null) cands.push(Number(u.t) + 60000);
    const s = this.rows("SELECT MIN(CASE WHEN lease_until > next_at THEN lease_until ELSE next_at END) AS t FROM scheds WHERE enabled = 1")[0];
    if (s && s.t != null) cands.push(Number(s.t));
    const e = this.rows("SELECT MIN(expires_at) AS t FROM scheds")[0];
    if (e && e.t != null) cands.push(Number(e.t));
    const f = this.rows("SELECT MIN(lease_until) AS t FROM ends")[0];
    if (f && f.t != null) cands.push(Number(f.t));
    if (!cands.length) {
      await this.ctx.storage.deleteAlarm();
      return null;
    }
    const at = Math.max(now, Math.min.apply(null, cands));
    const cur = await this.ctx.storage.getAlarm();
    if (cur == null || cur > at || cur < now) await this.ctx.storage.setAlarm(at);
    return at;
  }

  async runPut(b) {
    if (typeof b.runId !== "string" || !/^[0-9a-f]{64}$/.test(b.runId)) return { ok: false, error: "bad run" };
    if (typeof b.blob !== "string" || !b.blob || b.blob.length > 1024 * 1024) return { ok: false, error: "bad blob" };
    const now = this.now();
    const until = Math.min(driverNum(b.until, now + DRIVER_MAX_MS), now + DRIVER_MAX_MS);
    const leg = Math.max(1, Math.floor(driverNum(b.leg, 1)));
    const at = Math.max(now, Math.min(driverNum(b.at, now), until));
    this.sql.exec(
      "INSERT INTO runs (run_id, blob, leg, state, next_at, lease_until, tries, until_at, created_at) VALUES (?, ?, ?, 'queued', ?, 0, 0, ?, ?) " +
      "ON CONFLICT(run_id) DO UPDATE SET blob = excluded.blob, leg = excluded.leg, state = 'queued', next_at = excluded.next_at, " +
      "lease_until = 0, tries = 0, tok = '', claim = 0",
      b.runId, b.blob, leg, at, until, now
    );
    await this.indexed(true);
    await this.arm();
    return { ok: true, until: until, at: at };
  }

  async runCancel(b) {
    const had = this.rows("SELECT run_id FROM runs WHERE run_id = ?", String(b.runId || "")).length;
    this.sql.exec("DELETE FROM runs WHERE run_id = ?", String(b.runId || ""));
    await this.arm();
    return { ok: true, had: had > 0 };
  }

  runList() {
    return { runs: this.rows("SELECT run_id, leg, state, next_at, tries, until_at, created_at FROM runs ORDER BY created_at") };
  }

  schedList() {
    const day = driverDay(this.now());
    return {
      schedules: this.rows("SELECT id, mode, sha, next_at, expires_at, enabled, fails, last_at, last_state FROM scheds ORDER BY id").map((r) => ({
        id: r.id, mode: r.mode, sha256: r.sha, nextAt: Number(r.next_at), expiresAt: Number(r.expires_at),
        enabled: !!Number(r.enabled), fails: Number(r.fails), lastAt: Number(r.last_at) || 0, lastState: r.last_state || ""
      })),
      day: {
        credits: this.metaGet("sched_day") === day ? driverNum(this.metaGet("sched_credits"), 0) : 0,
        cap: driverNum(this.metaGet("sched_cap"), 50)
      }
    };
  }

  async schedPut(b) {
    const id = typeof b.id === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(b.id) ? b.id : "";
    if (!id) return { ok: false, error: "bad id" };
    if (b.mode !== "run" && b.mode !== "notify") return { ok: false, error: "bad mode" };
    if (typeof b.blob !== "string" || !b.blob || b.blob.length > 64 * 1024) return { ok: false, error: "bad blob" };
    const exists = this.rows("SELECT id FROM scheds WHERE id = ?", id).length > 0;
    if (!exists && Number(this.rows("SELECT COUNT(*) AS n FROM scheds")[0].n) >= DRIVER_SCHED_MAX) {
      return { ok: false, limit: DRIVER_SCHED_MAX };
    }
    const now = this.now();
    const step = Math.max(0, Math.floor(driverNum(b.step, 0)));
    const nextAt = Math.max(now, Math.floor(driverNum(b.nextAt, now)));
    const expiresAt = Math.floor(driverNum(b.expiresAt, 0));
    if (expiresAt <= now) return { ok: false, error: "expired" };
    this.sql.exec(
      "INSERT INTO scheds (id, mode, sha, blob, next_at, step, expires_at, enabled, fails, retry, day, runs_day, last_at, last_state, lease_until) " +
      "VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, 0, '', 0, 0, '', 0) " +
      "ON CONFLICT(id) DO UPDATE SET mode = excluded.mode, sha = excluded.sha, blob = excluded.blob, next_at = excluded.next_at, " +
      "step = excluded.step, expires_at = excluded.expires_at, enabled = 1, fails = 0, retry = 0, lease_until = 0, tok = '', claim = 0",
      id, b.mode, String(b.sha || ""), b.blob, nextAt, step, expiresAt
    );
    if (b.dailyCap != null) this.metaSet("sched_cap", driverNum(b.dailyCap, 50));
    await this.indexed(true);
    await this.arm();
    return { ok: true, id: id, nextAt: nextAt, expiresAt: expiresAt };
  }

  async schedDelete(b) {
    const id = String(b.id || "");
    const n = this.rows("SELECT id FROM scheds WHERE id = ?", id).length;
    this.sql.exec("DELETE FROM scheds WHERE id = ?", id);
    this.sql.exec("DELETE FROM meta WHERE k = ?", "retry:" + id);
    await this.arm();
    return { ok: true, deleted: n };
  }

  async schedClear() {
    const n = Number(this.rows("SELECT COUNT(*) AS n FROM scheds")[0].n);
    this.sql.exec("DELETE FROM scheds");
    this.sql.exec("DELETE FROM meta WHERE k LIKE 'retry:%'");
    await this.arm();
    return { ok: true, deleted: n };
  }

  async clearAll() {
    const runs = Number(this.rows("SELECT COUNT(*) AS n FROM runs")[0].n);
    const scheds = Number(this.rows("SELECT COUNT(*) AS n FROM scheds")[0].n);
    this.sql.exec("DELETE FROM runs");
    this.sql.exec("DELETE FROM scheds");
    this.sql.exec("DELETE FROM ends");
    this.sql.exec("DELETE FROM meta WHERE k IN ('sched_day', 'sched_credits', 'sched_cap') OR k LIKE 'retry:%'");
    await this.arm();
    await this.indexed(false);
    return { ok: true, runs: runs, deleted: scheds };
  }

  async sweep() {
    const now = this.now();
    const old = this.rows("SELECT run_id, blob, leg FROM runs WHERE until_at + 60000 < ? OR created_at + ? < ?", now, DRIVER_MAX_MS + 60000, now);
    for (const r of old) await this.endRun(r.run_id, r.blob, now);
    const gone = this.rows("SELECT id FROM scheds WHERE expires_at <= ?", now).length;
    this.sql.exec("DELETE FROM scheds WHERE expires_at <= ?", now);
    this.sql.exec("UPDATE runs SET state = 'queued', next_at = ?, tok = '', claim = 0 WHERE state = 'leased' AND lease_until + ? < ?", now, DRIVER_LEASE_MS, now);
    const empty = this.empty();
    if (empty) {
      await this.ctx.storage.deleteAlarm();
      this.metaSet("indexed", "0");
    } else {
      await this.arm();
    }
    return { ok: true, killed: old.length, expired: gone, empty: empty };
  }

  async enqueue(kind, id, leg, tok) {
    const q = this.env.LEG_QUEUE;
    const pk = this.metaGet("pubkey");
    if (!pk || !q || typeof q.send !== "function") return false;
    try {
      await q.send({ kind: kind, pubkey: pk, id: id, leg: String(leg), tok: tok, ts: this.now() });
      return true;
    } catch (e) {
      return false;
    }
  }

  async settle() {
    if (this.empty()) {
      await this.ctx.storage.deleteAlarm();
      await this.indexed(false);
    } else {
      await this.arm();
    }
  }

  async alarm() {
    this.init();
    const now = this.now();
    const expired = this.rows("SELECT run_id FROM runs WHERE until_at + 60000 < ?", now);
    if (expired.length) await this.sweep();
    const due = this.rows(
      "SELECT run_id, blob, leg, state, lease_until, tries FROM runs WHERE (state IN ('queued', 'polling') AND next_at <= ?) " +
      "OR (state = 'leased' AND lease_until <= ?)", now, now
    );
    for (const r of due) await this.dispatchRun(r, now);
    const ends = this.rows("SELECT run_id, tries FROM ends WHERE lease_until <= ?", now);
    for (const e of ends) await this.dispatchEnd(e, now);
    const scheds = this.rows(
      "SELECT id, mode, next_at, expires_at FROM scheds WHERE enabled = 1 AND " +
      "(next_at <= ? OR expires_at <= ?) AND lease_until <= ?", now, now, now
    );
    for (const s of scheds) await this.dispatchSched(s, now);
    await this.settle();
  }

  failRun(r, now) {
    const tries = Number(r.tries) + 1;
    if (tries > DRIVER_BACKOFF_MS.length) return { dead: true };
    this.sql.exec("UPDATE runs SET state = 'queued', tries = ?, lease_until = 0, next_at = ?, tok = '', claim = 0 WHERE run_id = ?",
      tries, now + DRIVER_BACKOFF_MS[tries - 1], r.run_id);
    return { dead: false };
  }

  async failOrEnd(r, now) {
    if (this.failRun(r, now).dead) await this.endRun(r.run_id, r.blob, now);
  }

  async endRun(runId, blob, now) {
    this.sql.exec("DELETE FROM runs WHERE run_id = ?", runId);
    const tok = driverTok();
    this.sql.exec(
      "INSERT INTO ends (run_id, blob, tok, claim, lease_until, tries) VALUES (?, ?, ?, 0, ?, 0) " +
      "ON CONFLICT(run_id) DO UPDATE SET blob = excluded.blob, tok = excluded.tok, claim = 0, lease_until = excluded.lease_until, tries = 0",
      runId, blob, tok, now + DRIVER_LEASE_MS
    );
    if (!(await this.enqueue("end", runId, "end", tok))) {
      this.sql.exec("UPDATE ends SET lease_until = ? WHERE run_id = ?", now + DRIVER_BACKOFF_MS[0], runId);
    }
  }

  async dispatchEnd(e, now) {
    const tries = Number(e.tries) + 1;
    if (tries > DRIVER_END_TRIES) {
      this.sql.exec("DELETE FROM ends WHERE run_id = ?", e.run_id);
      return;
    }
    const tok = driverTok();
    this.sql.exec("UPDATE ends SET tok = ?, claim = 0, tries = ?, lease_until = ? WHERE run_id = ?", tok, tries, now + DRIVER_LEASE_MS, e.run_id);
    if (!(await this.enqueue("end", e.run_id, "end", tok))) {
      this.sql.exec("UPDATE ends SET lease_until = ? WHERE run_id = ?", now + DRIVER_BACKOFF_MS[0], e.run_id);
    }
  }

  async dispatchRun(r, now) {
    if (r.state === "leased" && Number(r.lease_until) <= now) {
      await this.failOrEnd(r, now);
      return;
    }
    const lease = r.state === "polling" && Number(r.lease_until) > now ? Number(r.lease_until) : now + DRIVER_LEASE_MS;
    const tok = driverTok();
    this.sql.exec("UPDATE runs SET state = 'leased', lease_until = ?, tok = ?, claim = 0 WHERE run_id = ?", lease, tok, r.run_id);
    if (!(await this.enqueue("leg", r.run_id, String(r.leg), tok))) await this.failOrEnd(r, now);
  }

  async dispatchSched(s, now) {
    if (Number(s.expires_at) <= now) {
      this.sql.exec("DELETE FROM scheds WHERE id = ?", s.id);
      return;
    }
    const tok = driverTok();
    this.sql.exec("UPDATE scheds SET lease_until = ?, tok = ?, claim = 0 WHERE id = ?", now + DRIVER_LEASE_MS, tok, s.id);
    const leg = (s.mode === "notify" ? "n:" : "f:") + String(Number(s.next_at));
    if (!(await this.enqueue("sched", s.id, leg, tok))) {
      this.sql.exec("UPDATE scheds SET lease_until = ?, tok = '' WHERE id = ?", now + DRIVER_BACKOFF_MS[0], s.id);
    }
  }

  claim(b) {
    const now = this.now();
    const tok = typeof b.tok === "string" ? b.tok : "";
    const id = String(b.id || "");
    if (!tok) return { go: false };
    if (b.kind === "leg") {
      const r = this.rows("SELECT run_id, blob, leg, state, lease_until, tok, claim FROM runs WHERE run_id = ?", id)[0];
      if (!r || r.tok !== tok || Number(r.claim) || r.state !== "leased" || String(r.leg) !== String(b.leg) || Number(r.lease_until) <= now) {
        return { go: false };
      }
      this.sql.exec("UPDATE runs SET claim = 1 WHERE run_id = ?", id);
      return { go: true, action: "pm-bgleg", runId: r.run_id, leg: String(r.leg), extra: { blob: r.blob } };
    }
    if (b.kind === "end") {
      const e = this.rows("SELECT run_id, blob, tok, claim FROM ends WHERE run_id = ?", id)[0];
      if (!e || e.tok !== tok || Number(e.claim)) return { go: false };
      this.sql.exec("UPDATE ends SET claim = 1 WHERE run_id = ?", id);
      return { go: true, action: "pm-bgend", runId: e.run_id, leg: "end", extra: { blob: e.blob, state: "failed" } };
    }
    if (b.kind !== "sched") return { go: false };
    const s = this.rows("SELECT id, mode, blob, next_at, expires_at, enabled, fails, day, runs_day, lease_until, tok, claim FROM scheds WHERE id = ?", id)[0];
    if (!s || s.tok !== tok || Number(s.claim) || !Number(s.enabled) || Number(s.lease_until) <= now || Number(s.expires_at) <= now) return { go: false };
    const firedAt = String(Number(s.next_at));
    const leg = (s.mode === "notify" ? "n:" : "f:") + firedAt;
    if (String(b.leg) !== leg) return { go: false };
    this.sql.exec("UPDATE scheds SET claim = 1 WHERE id = ?", id);
    const day = driverDay(now);
    if (s.mode === "notify") return { go: true, action: "pm-schednotify", runId: "s:" + id, leg: leg, extra: { blob: s.blob }, day: day };
    const runsDay = s.day === day ? Number(s.runs_day) : 0;
    if (this.metaGet("sched_day") !== day) {
      this.metaSet("sched_day", day);
      this.metaSet("sched_credits", 0);
    }
    const credits = driverNum(this.metaGet("sched_credits"), 0);
    return {
      go: true, action: "pm-schedfire", runId: "s:" + id, leg: leg, day: day,
      extra: { blob: s.blob, day: { runs: runsDay, credits: credits }, fails: Number(s.fails) }
    };
  }

  async report(b) {
    const now = this.now();
    const tok = typeof b.tok === "string" ? b.tok : "";
    const id = String(b.id || "");
    const out = { status: Math.floor(driverNum(b.status, 0)), data: b.data && typeof b.data === "object" ? b.data : null };
    let res = { ok: false };
    if (tok && b.kind === "leg") {
      const r = this.rows("SELECT run_id, blob, leg, state, lease_until, tries, tok, claim FROM runs WHERE run_id = ?", id)[0];
      if (r && r.tok === tok && Number(r.claim)) res = await this.reportLeg(r, out, now);
    } else if (tok && b.kind === "end") {
      const n = this.rows("SELECT run_id FROM ends WHERE run_id = ? AND tok = ? AND claim = 1", id, tok).length;
      if (n) {
        this.sql.exec("DELETE FROM ends WHERE run_id = ?", id);
        res = { ok: true };
      }
    } else if (tok && b.kind === "sched") {
      const s = this.rows("SELECT id, mode, next_at, step, expires_at, fails, retry, day, runs_day, tok, claim FROM scheds WHERE id = ?", id)[0];
      if (s && s.tok === tok && Number(s.claim)) {
        const day = typeof b.day === "string" && /^\d{4}-\d{2}-\d{2}$/.test(b.day) ? b.day : driverDay(now);
        this.reportSched(s, out, now, day);
        res = { ok: true };
      }
    }
    await this.settle();
    return res;
  }

  async reportLeg(r, out, now) {
    const d = out.data || {};
    if (out.status === 200 && d.next && typeof d.next.blob === "string") {
      this.sql.exec(
        "UPDATE runs SET blob = ?, leg = leg + 1, state = 'queued', next_at = ?, lease_until = 0, tries = 0, tok = '', claim = 0 WHERE run_id = ?",
        d.next.blob, Math.max(now, driverNum(d.next.at, now)), r.run_id
      );
      return { ok: true };
    }
    if (out.status === 200 && d.end) {
      this.sql.exec("DELETE FROM runs WHERE run_id = ?", r.run_id);
      return { ok: true };
    }
    if (out.status === 202) {
      if (now >= Number(r.lease_until)) {
        await this.failOrEnd(r, now);
        return { ok: true };
      }
      this.sql.exec("UPDATE runs SET state = 'polling', next_at = ?, tok = '', claim = 0 WHERE run_id = ?",
        now + driverNum(this.env.DRIVER_POLL_MS, DRIVER_POLL_MS), r.run_id);
      return { ok: true };
    }
    if (DRIVER_FATAL[out.status] && d.fatal) {
      this.sql.exec("DELETE FROM runs WHERE run_id = ?", r.run_id);
      return { ok: true };
    }
    const tries = Number(r.tries) + 1;
    if (tries > DRIVER_BACKOFF_MS.length) {
      await this.endRun(r.run_id, r.blob, now);
      return { ok: true };
    }
    const wait = DRIVER_BACKOFF_MS[tries - 1];
    this.sql.exec("UPDATE runs SET state = 'leased', tries = ?, next_at = ?, lease_until = ?, claim = 0 WHERE run_id = ?",
      tries, now + wait, now + wait + DRIVER_LEASE_MS, r.run_id);
    return { ok: true, retry: Math.ceil(wait / 1000) };
  }

  schedAdvance(s, now, patch) {
    this.sql.exec("DELETE FROM meta WHERE k = ?", "retry:" + s.id);
    const step = Number(s.step) || 0;
    if (!step) {
      this.sql.exec("DELETE FROM scheds WHERE id = ?", s.id);
      return;
    }
    let next = Number(s.next_at) + step;
    if (next <= now) next += Math.ceil((now - next + 1) / step) * step;
    const p = patch || {};
    this.sql.exec(
      "UPDATE scheds SET next_at = ?, retry = 0, lease_until = 0, tok = '', claim = 0, fails = ?, enabled = ?, last_at = ?, last_state = ?, day = ?, runs_day = ? WHERE id = ?",
      next, p.fails != null ? p.fails : Number(s.fails), p.enabled === false ? 0 : 1, now, p.state || "",
      p.day != null ? p.day : s.day, p.runsDay != null ? p.runsDay : Number(s.runs_day), s.id
    );
  }

  reportSched(s, out, now, day) {
    const runsDay = s.day === day ? Number(s.runs_day) : 0;
    const d = out.data || {};
    if (s.mode === "notify") {
      if (out.status === 200 && d.expired) {
        this.sql.exec("DELETE FROM scheds WHERE id = ?", s.id);
        return;
      }
      this.schedAdvance(s, now, { state: out.status === 200 ? "notified" : "failed", day: day, runsDay: runsDay });
      return;
    }
    const base = Number(s.retry) ? Object.assign({}, s, { next_at: driverNum(this.metaGet("retry:" + s.id), Number(s.next_at)) }) : s;
    if (out.status === 200 && d.expired) {
      this.sql.exec("DELETE FROM scheds WHERE id = ?", s.id);
      return;
    }
    if (out.status === 200 && d.ok && d.state === "done") {
      if (this.metaGet("sched_day") === day) this.metaSet("sched_credits", driverNum(this.metaGet("sched_credits"), 0) + Math.max(0, driverNum(d.credits, 0)));
      this.schedAdvance(base, now, { fails: 0, state: "done", day: day, runsDay: runsDay + 1 });
      return;
    }
    if (out.status === 200 && d.skipped) {
      this.schedAdvance(base, now, { state: "skipped", day: day, runsDay: runsDay });
      return;
    }
    if (out.status === 200 && d.retry && !Number(s.retry)) {
      this.metaSet("retry:" + s.id, base.next_at);
      this.sql.exec("UPDATE scheds SET retry = 1, lease_until = 0, tok = '', claim = 0, next_at = ? WHERE id = ?", now + DRIVER_SCHED_RETRY_MS, s.id);
      return;
    }
    if (out.status === 200 && d.retry) {
      this.schedAdvance(base, now, { state: "skipped", day: day, runsDay: runsDay });
      return;
    }
    const fails = Number(s.fails) + 1;
    const off = !!d.disable || fails >= DRIVER_SCHED_FAIL_MAX;
    this.schedAdvance(base, now, { fails: fails, enabled: !off, state: off ? "disabled" : "failed", day: day, runsDay: runsDay });
  }
}
