import { hasD1 } from "./_d1.js";

export const RUNNER_RATES = {
  memoryUsdPerGiBSecond: 0.0000025,
  cpuUsdPerVcpuSecond: 0.00002,
  diskUsdPerGBSecond: 0.00000007
};

export const RUNNER_INSTANCE_TYPES = {
  "standard-1": { vcpu: 0.5, memoryGiB: 4, diskGB: 8 },
  "standard-2": { vcpu: 1, memoryGiB: 6, diskGB: 12 },
  "standard-3": { vcpu: 2, memoryGiB: 8, diskGB: 16 }
};

export const RUNNER_IMAGES = {
  python: {
    label: "Python 3.12",
    className: "PythonRunner",
    binding: "PYTHON_RUNNER",
    instanceType: "standard-1",
    maxInstances: 20,
    maxTimeoutSec: 900
  },
  node: {
    label: "Node.js 22",
    className: "NodeRunner",
    binding: "NODE_RUNNER",
    instanceType: "standard-1",
    maxInstances: 20,
    maxTimeoutSec: 900
  },
  polyglot: {
    label: "Go, Rust, Java, C and more",
    className: "PolyglotRunner",
    binding: "POLYGLOT_RUNNER",
    instanceType: "standard-2",
    maxInstances: 10,
    maxTimeoutSec: 900
  },
  flutter: {
    label: "Flutter 3.32 and Dart",
    className: "FlutterRunner",
    binding: "FLUTTER_RUNNER",
    instanceType: "standard-3",
    maxInstances: 6,
    maxTimeoutSec: 1200
  }
};

export const RUNNER_MIN_TIMEOUT_SEC = 5;
export const RUNNER_MARGIN_DEFAULT = 1.4;
export const RUNNER_MARGIN_MIN = 1.0;
export const RUNNER_MARGIN_MAX = 3.0;
export const RUNNER_BILL_STEP_MS = 10000;
export const RUNNER_DEADLINE_SLACK_MS = 120000;
export const RUNNER_SETTINGS_TTL_MS = 60000;
export const RUNNER_OUTPUT_BYTES = 256 * 1024;
export const RUNNER_CODE_MAX_BYTES = 1024 * 1024;
export const RUNNER_FILES_MAX = 200;
export const RUNNER_FILES_MAX_BYTES = 20 * 1024 * 1024;
export const RUNNER_COMMAND_MAX = 8000;

export const RUNNER_LANGUAGES = {
  python: { image: "python", filename: "main.py", command: "python main.py" },
  javascript: { image: "node", filename: "main.js", command: "node main.js" },
  typescript: { image: "node", filename: "main.ts", command: "npx -y tsx main.ts" },
  bash: { image: "polyglot", filename: "main.sh", command: "bash main.sh" },
  sh: { image: "polyglot", filename: "main.sh", command: "bash main.sh" },
  go: { image: "polyglot", filename: "main.go", command: "go run main.go" },
  rust: { image: "polyglot", filename: "main.rs", command: "rustc -O main.rs -o /tmp/m && /tmp/m" },
  java: { image: "polyglot", filename: "Main.java", command: "java Main.java" },
  dart: { image: "flutter", filename: "main.dart", command: "dart run main.dart" }
};

const LANGUAGE_ALIASES = {
  py: "python", python3: "python", js: "javascript", node: "javascript", mjs: "javascript",
  ts: "typescript", shell: "bash", zsh: "bash", golang: "go", rs: "rust"
};

export function runnerLanguage(language) {
  const key = String(language || "").trim().toLowerCase();
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const name = own(RUNNER_LANGUAGES, key) ? key : own(LANGUAGE_ALIASES, key) ? LANGUAGE_ALIASES[key] : null;
  return name ? Object.assign({ language: name }, RUNNER_LANGUAGES[name]) : null;
}

function hasImage(image) {
  return typeof image === "string" && Object.prototype.hasOwnProperty.call(RUNNER_IMAGES, image);
}

export function runnerUsdPerSecond(image) {
  if (!hasImage(image)) return 0;
  const size = RUNNER_INSTANCE_TYPES[RUNNER_IMAGES[image].instanceType];
  return size.memoryGiB * RUNNER_RATES.memoryUsdPerGiBSecond
    + size.vcpu * RUNNER_RATES.cpuUsdPerVcpuSecond
    + size.diskGB * RUNNER_RATES.diskUsdPerGBSecond;
}

function clampMargin(v) {
  const n = Number(v);
  if (v === null || v === undefined || v === "" || !Number.isFinite(n)) return null;
  return Math.min(RUNNER_MARGIN_MAX, Math.max(RUNNER_MARGIN_MIN, n));
}

export function runnerMargin(env, settings) {
  const fromSettings = settings ? clampMargin(settings.margin) : null;
  if (fromSettings !== null) return fromSettings;
  const fromEnv = clampMargin(env && env.RUNNER_MARGIN);
  return fromEnv !== null ? fromEnv : RUNNER_MARGIN_DEFAULT;
}

export function runnerBilledMs(ms) {
  const n = Math.max(0, Number(ms) || 0);
  return Math.max(RUNNER_BILL_STEP_MS, Math.ceil(n / RUNNER_BILL_STEP_MS) * RUNNER_BILL_STEP_MS);
}

function converter(opts) {
  const f = opts && opts.milliForUsd;
  if (typeof f !== "function") throw new Error("milliForUsd is required");
  return f;
}

function marginOf(opts) {
  const m = clampMargin(opts && opts.margin);
  return m !== null ? m : RUNNER_MARGIN_DEFAULT;
}

export function runnerMaxMilli(image, timeoutSec, btcUsd, opts) {
  if (!hasImage(image)) return 0;
  const toMilli = converter(opts);
  const usd = runnerBilledMs(Number(timeoutSec) * 1000) / 1000 * runnerUsdPerSecond(image);
  return Math.max(1, Math.ceil(Number(toMilli(usd * marginOf(opts), btcUsd)) || 0));
}

export function runnerChargeMilli(image, billedMs, usd, btcUsd, opts) {
  if (!hasImage(image)) return 0;
  const toMilli = converter(opts);
  const max = Math.floor(Number(opts && opts.maxMilli));
  if (!Number.isFinite(max) || max < 0) throw new Error("maxMilli is required");
  const ms = Math.max(0, Number(billedMs) || 0);
  let cost = Number(usd);
  if (!Number.isFinite(cost) || cost < 0) cost = 0;
  if (cost === 0 && ms > 0) cost = ms / 1000 * runnerUsdPerSecond(image);
  if (cost === 0) return 0;
  const milli = Math.max(1, Math.ceil(Number(toMilli(cost * marginOf(opts), btcUsd)) || 0));
  return Math.min(max, milli);
}

export function runnerCredits(milli) {
  return Math.round(Math.max(0, Number(milli) || 0)) / 1000;
}

export function runnerPriceCheck(maxCost, maxMilli) {
  const approved = Number(maxCost);
  const need = runnerCredits(maxMilli);
  if (!Number.isFinite(approved) || Math.round(approved * 1000) < maxMilli) {
    return { status: 402, body: { error: "price-changed", maxCredits: need } };
  }
  return null;
}

export function runnerDefaultSettings() {
  const images = {};
  for (const name of Object.keys(RUNNER_IMAGES)) {
    images[name] = { enabled: true, maxTimeoutSec: RUNNER_IMAGES[name].maxTimeoutSec };
  }
  return { enabled: true, margin: null, images };
}

export function runnerParseSettings(rows) {
  const s = runnerDefaultSettings();
  for (const row of rows || []) {
    if (!row || typeof row.key !== "string") continue;
    const value = row.value == null ? "" : String(row.value).trim();
    if (row.key === "runner.enabled") {
      s.enabled = value !== "0";
      continue;
    }
    if (row.key === "runner.margin") {
      s.margin = clampMargin(value);
      continue;
    }
    const m = /^runner\.image\.([a-z]+)\.(enabled|maxTimeoutSec)$/.exec(row.key);
    if (!m || !hasImage(m[1])) continue;
    if (m[2] === "enabled") {
      s.images[m[1]].enabled = value !== "0";
    } else {
      const n = Math.floor(Number(value));
      if (value !== "" && Number.isFinite(n)) {
        s.images[m[1]].maxTimeoutSec = Math.min(RUNNER_IMAGES[m[1]].maxTimeoutSec, Math.max(RUNNER_MIN_TIMEOUT_SEC, n));
      }
    }
  }
  return s;
}

const SETTINGS_DDL = "CREATE TABLE IF NOT EXISTS bot_runner_settings (key TEXT PRIMARY KEY, value TEXT)";

let settingsCache = { at: 0, value: null, db: null };

export function runnerSettingsReset() {
  settingsCache = { at: 0, value: null, db: null };
}

export async function runnerSettings(env, now = Date.now()) {
  const db = env && env.DB_BOT;
  if (!hasD1(db)) return runnerDefaultSettings();
  if (settingsCache.value && settingsCache.db === db && now - settingsCache.at < RUNNER_SETTINGS_TTL_MS) {
    return settingsCache.value;
  }
  let value;
  try {
    await db.prepare(SETTINGS_DDL).run();
    const res = await db.prepare("SELECT key, value FROM bot_runner_settings").all();
    value = runnerParseSettings(res && res.results);
  } catch (e) {
    value = settingsCache.db === db && settingsCache.value ? settingsCache.value : runnerDefaultSettings();
  }
  settingsCache = { at: now, value, db };
  return value;
}

export function runnerAvailable(env, settings) {
  if (!(env && env.RUNNER && String(env.RUNNER_SECRET || "").trim())) return false;
  return !(settings && settings.enabled === false);
}

export function runnerImageOpen(settings, image) {
  if (!hasImage(image)) return false;
  const s = settings && settings.images && settings.images[image];
  return !(s && s.enabled === false);
}

export function runnerMaxTimeout(settings, image) {
  if (!hasImage(image)) return 0;
  const s = settings && settings.images && settings.images[image];
  const cap = RUNNER_IMAGES[image].maxTimeoutSec;
  const n = s ? Math.floor(Number(s.maxTimeoutSec)) : cap;
  return Number.isFinite(n) ? Math.min(cap, Math.max(RUNNER_MIN_TIMEOUT_SEC, n)) : cap;
}

export function runnerSafePath(p) {
  if (typeof p !== "string" || !p.length || p.length > 512) return null;
  if (/[\u0000-\u001f\u007f]/.test(p) || p.includes("\\")) return null;
  if (p.startsWith("/") || p.startsWith("~")) return null;
  const parts = p.split("/").filter((s) => s !== "" && s !== ".");
  if (!parts.length || parts.some((s) => s === "..")) return null;
  return parts.join("/");
}

export function runnerBase64(text) {
  const bytes = typeof text === "string" ? new TextEncoder().encode(text) : text;
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

function base64Size(s) {
  if (typeof s !== "string" || s.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) return -1;
  return s.length / 4 * 3 - (s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0);
}

function refuse(error) {
  return { status: 400, error };
}

export function runnerBuildRequest(body, opts) {
  const settings = (opts && opts.settings) || runnerDefaultSettings();
  const runId = opts && opts.runId;
  if (!body || typeof body !== "object") return refuse("Nothing to run.");
  let image = body.image;
  let command = body.command;
  const files = [];
  if (body.code != null || body.language != null) {
    const lang = runnerLanguage(body.language);
    if (!lang) return refuse("That language can't run on a server.");
    if (typeof body.code !== "string" || !body.code.trim()) return refuse("There is no code to run.");
    if (new TextEncoder().encode(body.code).length > RUNNER_CODE_MAX_BYTES) return refuse("The code is larger than 1 MiB.");
    image = lang.image;
    command = lang.command;
    files.push({ path: lang.filename, data: runnerBase64(body.code) });
  }
  if (!hasImage(image)) return refuse("Unknown server image.");
  if (!runnerImageOpen(settings, image)) return refuse("That server image is turned off right now.");
  if (typeof command !== "string" || !command.trim() || command.length > RUNNER_COMMAND_MAX || command.includes("\u0000")) {
    return refuse("The command must be 1 to " + RUNNER_COMMAND_MAX + " characters.");
  }
  const maxTimeout = runnerMaxTimeout(settings, image);
  const timeoutSec = Number(body.timeoutSec);
  if (!Number.isInteger(timeoutSec) || timeoutSec < RUNNER_MIN_TIMEOUT_SEC || timeoutSec > maxTimeout) {
    return refuse("The time limit must be " + RUNNER_MIN_TIMEOUT_SEC + " to " + maxTimeout + " seconds.");
  }
  if (body.files != null) {
    if (!Array.isArray(body.files)) return refuse("Files must be a list.");
    if (body.files.length + files.length > RUNNER_FILES_MAX) return refuse("At most " + RUNNER_FILES_MAX + " files.");
    const seen = new Set(files.map((f) => f.path));
    let total = files.reduce((n, f) => n + base64Size(f.data), 0);
    for (const f of body.files) {
      const path = f && runnerSafePath(f.path);
      if (!path) return refuse("File paths must be relative, without '..'.");
      if (seen.has(path)) return refuse("Two files have the same path: " + path);
      const size = base64Size(f.data);
      if (size < 0) return refuse("File data must be base64.");
      total += size;
      if (total > RUNNER_FILES_MAX_BYTES) return refuse("The files are larger than 20 MiB in total.");
      seen.add(path);
      files.push({ path, data: f.data });
    }
  }
  if (typeof runId !== "string" || !/^[A-Za-z0-9_-]{8,64}$/.test(runId)) return refuse("Missing run id.");
  return {
    request: {
      image,
      command,
      timeoutSec,
      files,
      collectChanged: true,
      runId,
      maxOutputBytes: RUNNER_OUTPUT_BYTES
    }
  };
}

function synthetic(stage, message, startedAt, now, image) {
  if (startedAt == null) return { type: "error", stage: "start", message, billedMs: 0, usd: 0, synthetic: true };
  const billedMs = runnerBilledMs(now - startedAt);
  const usd = Math.round(billedMs / 1000 * runnerUsdPerSecond(image) * 1e9) / 1e9;
  return { type: "error", stage, message, billedMs, usd, synthetic: true };
}

export async function* callRunner(env, req, opts) {
  const clock = (opts && opts.now) || Date.now;
  const deadlineMs = opts && Number(opts.deadlineMs) > 0
    ? Number(opts.deadlineMs)
    : (Number(req.timeoutSec) || 0) * 1000 + RUNNER_DEADLINE_SLACK_MS;
  const t0 = clock();
  const abort = new AbortController();
  let expired = false;
  const timer = setTimeout(() => { expired = true; abort.abort(); }, deadlineMs);
  let startedAt = null;
  let finished = false;
  try {
    let res;
    try {
      res = await env.RUNNER.fetch("https://runner/run", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Runner-Secret": String(env.RUNNER_SECRET || "").trim() },
        body: JSON.stringify(req),
        signal: abort.signal
      });
    } catch (e) {
      finished = true;
      yield synthetic("start", expired ? "The server run did not start in time." : "The runner could not be reached.", null, clock(), req.image);
      return;
    }
    if (!res.ok || !res.body) {
      let detail = "";
      try { detail = ((await res.json()) || {}).error || ""; } catch (e) { }
      finished = true;
      yield synthetic("start", "The runner refused the run (" + res.status + (detail ? ": " + detail : "") + ").", null, clock(), req.image);
      return;
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    const parse = function* (line) {
      const text = line.trim();
      if (!text) return;
      let ev;
      try { ev = JSON.parse(text); } catch (e) { return; }
      if (!ev || typeof ev.type !== "string") return;
      if (ev.type === "start" && startedAt == null) startedAt = t0;
      if (ev.type === "exit" || ev.type === "error") finished = true;
      yield ev;
    };
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let nl;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          yield* parse(line);
          if (finished) return;
        }
      }
      buf += decoder.decode();
      yield* parse(buf);
    } catch (e) {
      if (!finished) {
        finished = true;
        yield synthetic("run", expired ? "The server run went past its deadline." : "The connection to the runner broke.", startedAt, clock(), req.image);
      }
      return;
    }
    if (!finished) {
      finished = true;
      yield synthetic("run", "The runner stopped without a result.", startedAt, clock(), req.image);
    }
  } finally {
    clearTimeout(timer);
    abort.abort();
  }
}

export function runnerInfo(env, btcUsd, opts) {
  const settings = (opts && opts.settings) || runnerDefaultSettings();
  const margin = runnerMargin(env, settings);
  const toMilli = converter(opts);
  const images = [];
  for (const name of Object.keys(RUNNER_IMAGES)) {
    if (!runnerImageOpen(settings, name)) continue;
    const spec = RUNNER_IMAGES[name];
    const milli = Number(toMilli(runnerUsdPerSecond(name) * 60 * margin, btcUsd)) || 0;
    images.push({
      name,
      label: spec.label,
      instanceType: spec.instanceType,
      maxTimeoutSec: runnerMaxTimeout(settings, name),
      creditsPerMinute: Math.round(milli) / 1000
    });
  }
  return { available: runnerAvailable(env, settings), margin, images };
}
