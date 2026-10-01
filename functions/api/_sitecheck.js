import { siteUrlCheck, siteSign } from "./_siteurl.js";
import { runnerCredits } from "./_runner.js";
import { serverRunOpen, serverRunSettle, serverRunHostArtifacts } from "./_serverrun.js";

export var SITE_CHECK_TOOL = "check_site";
export var SITE_CHECK_IMAGE = "sitecheck";
export var SITE_CHECK_BROWSER_USD_PER_HOUR = 0.09;
export var SITE_CHECK_MIN_USD = 0.005;
export var SITE_CHECK_TIMEOUT_SEC = 60;
export var SITE_CHECK_SLACK_SEC = 30;
export var SITE_CHECK_STEPS_MAX = 20;
export var SITE_CHECK_RATE_LIMIT = 20;
export var SITE_CHECK_RATE_WINDOW_MS = 3600000;
export var SITE_CHECK_CALL_SLACK_MS = 30000;

var STEP_ACTIONS = ["click", "type", "press", "wait", "waitFor", "assertText", "goto"];

function positive(v, max) {
  var n = Number(v);
  if (v === null || v === undefined || v === "" || typeof v === "boolean" || !Number.isFinite(n) || n <= 0) return null;
  return Math.min(max, n);
}

export function siteCheckAvailable(env, settings) {
  if (!(env && env.SITE_CHECK && String(env.SITE_CHECK_SECRET || "").trim())) return false;
  return !(settings && settings.siteCheck && settings.siteCheck.enabled === false);
}

export function siteCheckUsdPerMinute(env, settings, margin, surcharge) {
  var fromSettings = settings && settings.siteCheck ? positive(settings.siteCheck.usdPerMinute, 1) : null;
  if (fromSettings !== null) return fromSettings;
  var fromEnv = positive(env && env.SITE_CHECK_PRICE, 1);
  if (fromEnv !== null) return fromEnv;
  var m = Number(margin) > 0 ? Number(margin) : 1;
  var x = Number(surcharge) > 0 ? Number(surcharge) : 1;
  return SITE_CHECK_BROWSER_USD_PER_HOUR / 60 * m * x;
}

export function siteCheckMinutes(ms) {
  return Math.max(1, Math.ceil((Number(ms) || 0) / 60000));
}

function toMilli(o, usd) {
  return Math.max(1, Math.ceil(Number(o.milliForUsd(usd, o.btcUsd)) || 0));
}

export function siteCheckMaxMilli(timeoutSec, o) {
  var minutes = Math.ceil(((Number(timeoutSec) || SITE_CHECK_TIMEOUT_SEC) + SITE_CHECK_SLACK_SEC) / 60);
  return toMilli(o, Math.max(SITE_CHECK_MIN_USD, minutes * o.usdPerMinute));
}

export function siteCheckChargeMilli(browserMs, o) {
  if (!(Number(browserMs) > 0)) return 0;
  var usd = Math.max(SITE_CHECK_MIN_USD, siteCheckMinutes(browserMs) * o.usdPerMinute);
  return Math.min(Math.floor(Number(o.maxMilli)), toMilli(o, usd));
}

export function siteCheckInfo(env, settings, btcUsd, o) {
  var price = siteCheckUsdPerMinute(env, settings, o.margin, o.surcharge);
  var p = { usdPerMinute: price, btcUsd: btcUsd, milliForUsd: o.milliForUsd };
  return {
    available: siteCheckAvailable(env, settings),
    creditsPerMinute: Math.round(Number(o.milliForUsd(price, btcUsd)) || 0) / 1000,
    minCredits: toMilli(p, SITE_CHECK_MIN_USD) / 1000,
    maxCredits: siteCheckMaxMilli(SITE_CHECK_TIMEOUT_SEC, p) / 1000,
    timeoutSec: SITE_CHECK_TIMEOUT_SEC,
    surcharge: Number(o.surcharge) > 1 ? Number(o.surcharge) : 1
  };
}

export function siteCheckRequest(args, opts) {
  var a = args && typeof args === "object" ? args : {};
  var checked = siteUrlCheck(a.url);
  if (!checked.ok) return { error: checked.error };
  var userText = String((opts && opts.userText) || "");
  var steps = [];
  if (a.steps != null) {
    if (!Array.isArray(a.steps)) return { error: "Steps must be a list." };
    if (a.steps.length > SITE_CHECK_STEPS_MAX) return { error: "A check takes at most " + SITE_CHECK_STEPS_MAX + " steps." };
    for (var i = 0; i < a.steps.length; i++) {
      var s = a.steps[i];
      if (!s || typeof s !== "object" || STEP_ACTIONS.indexOf(s.action) === -1) {
        return { error: "Each step needs an action: " + STEP_ACTIONS.join(", ") + "." };
      }
      var step = {};
      for (var k in s) {
        if (Object.prototype.hasOwnProperty.call(s, k) && ["action", "selector", "text", "key", "ms", "url"].indexOf(k) !== -1) step[k] = s[k];
      }
      if (s.action === "type" && s.credential === true && typeof s.text === "string" && s.text.trim() && userText.indexOf(s.text) !== -1) {
        step.credential = true;
      }
      steps.push(step);
    }
  }
  return {
    request: {
      url: checked.url,
      steps: steps,
      viewports: a.mobile === false ? ["desktop"] : ["desktop", "mobile"],
      pwa: a.pwa !== false,
      a11y: true,
      timeoutMs: SITE_CHECK_TIMEOUT_SEC * 1000
    }
  };
}

function failure(message) {
  return { ok: false, report: { error: message }, screenshots: [], browserMs: 0 };
}

export async function callSiteCheck(env, request) {
  var body = JSON.stringify(request);
  var ts = Date.now();
  var abort = new AbortController();
  var timer = setTimeout(function () { abort.abort(); }, (Number(request.timeoutMs) || SITE_CHECK_TIMEOUT_SEC * 1000) + SITE_CHECK_CALL_SLACK_MS);
  try {
    var res;
    try {
      res = await env.SITE_CHECK.fetch("https://sitecheck/check", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Site-Check-Ts": String(ts),
          "X-Site-Check-Sig": await siteSign(String(env.SITE_CHECK_SECRET || ""), ts, body)
        },
        body: body,
        signal: abort.signal
      });
    } catch (e) {
      return failure("The browser service could not be reached.");
    }
    var data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (!res.ok || !data || typeof data !== "object") {
      return failure("The browser service refused the check (" + res.status + (data && data.error ? ": " + String(data.error).slice(0, 200) : "") + ").");
    }
    return {
      ok: data.ok === true,
      report: data.report && typeof data.report === "object" ? data.report : {},
      screenshots: Array.isArray(data.screenshots) ? data.screenshots.slice(0, 4) : [],
      browserMs: Math.max(0, Number(data.browserMs) || 0)
    };
  } finally {
    clearTimeout(timer);
  }
}

function inert(text) {
  return String(text == null ? "" : text).replace(/<<<|>>>/g, "‹‹‹");
}

export function siteCheckModelText(o) {
  var out = o.out || {};
  var r = out.report || {};
  var lines = [];
  lines.push(out.ok ? "Site check of " + o.url + " finished." : "Site check of " + o.url + " did not finish" + (r.timedOut ? " (it hit its time limit)" : "") + ".");
  lines.push("Charged " + runnerCredits(o.milli) + " Pro credits for the browser time.");
  var shots = Array.isArray(o.screenshots) ? o.screenshots : [];
  var body = {
    status: r.status, finalUrl: r.finalUrl, title: r.title, error: r.error || undefined, timings: r.timings,
    console: r.console, pageErrors: r.pageErrors, failedRequests: r.failedRequests, blocked: r.blocked,
    pwa: r.pwa, a11y: r.a11y, steps: r.steps, pages: r.pages, bytes: r.bytes, timedOut: r.timedOut || undefined,
    screenshotsShownToUser: shots.map(function (s) { return { name: s.name, url: s.url }; })
  };
  lines.push("<<<UNTRUSTED TOOL OUTPUT from site check>>>");
  lines.push(inert(JSON.stringify(body)).slice(0, 12000));
  lines.push("<<<END UNTRUSTED TOOL OUTPUT>>>");
  lines.push("The screenshots are already shown to the user; describe what the check found.");
  return lines.join("\n");
}

function usageDetail(o, out, billedMs, milli) {
  return {
    image: SITE_CHECK_IMAGE, billedMs: billedMs, usd: o.costUsd, milli: milli, surcharge: o.surcharge > 1 ? o.surcharge : undefined,
    exitCode: out.ok ? 0 : null, stage: out.ok ? undefined : (out.browserMs > 0 ? "run" : "start")
  };
}

export async function siteCheckRun(o) {
  var opened = await serverRunOpen(o.env, {
    pubkey: o.pubkey, maxMilli: o.maxMilli, timeoutSec: SITE_CHECK_TIMEOUT_SEC + SITE_CHECK_SLACK_SEC,
    rateLimit: o.rateLimit, rateWindowMs: o.rateWindowMs
  });
  if (!opened.ok) return { opened: opened };
  var out;
  try {
    out = await callSiteCheck(o.env, o.request);
  } catch (e) {
    out = failure("The check failed.");
  }
  var shots = await serverRunHostArtifacts(out.screenshots, o.hostArtifact, false);
  var browserMs = out.browserMs;
  var milli = siteCheckChargeMilli(browserMs, { usdPerMinute: o.usdPerMinute, btcUsd: o.btcUsd, milliForUsd: o.milliForUsd, maxMilli: o.maxMilli });
  var billedMs = browserMs > 0 ? siteCheckMinutes(browserMs) * 60000 : 0;
  var costUsd = browserMs > 0 ? Math.round(browserMs / 3600000 * SITE_CHECK_BROWSER_USD_PER_HOUR * 1e9) / 1e9 : 0;
  var charged = await serverRunSettle(o.env, opened.run, {
    pubkey: o.pubkey, image: SITE_CHECK_IMAGE, maxMilli: o.maxMilli, context: o.context, balanceOf: o.balanceOf, git: !!o.git,
    priced: {
      milli: milli, billedMs: billedMs, usd: costUsd, ok: out.ok,
      detail: usageDetail({ costUsd: costUsd, surcharge: o.surcharge }, out, billedMs, milli)
    }
  });
  return { out: out, screenshots: shots, charged: charged };
}

function publicReport(r) {
  var report = Object.assign({}, r || {});
  delete report.screenshots;
  return report;
}

export async function siteCheckAction(o) {
  var body = o.body || {};
  var built = siteCheckRequest({ url: body.url, mobile: body.mobile, pwa: body.pwa });
  if (built.error) return { status: 400, body: { error: built.error } };
  var price = { usdPerMinute: o.usdPerMinute, btcUsd: o.btcUsd, milliForUsd: o.milliForUsd };
  var maxMilli = siteCheckMaxMilli(SITE_CHECK_TIMEOUT_SEC, price);
  var approved = Number(body.maxCost);
  if (!Number.isFinite(approved) || Math.round(approved * 1000) < maxMilli) {
    return { status: 402, body: { error: "price-changed", maxCredits: runnerCredits(maxMilli) } };
  }
  if (typeof o.rateOk === "function" && !(await o.rateOk())) {
    return { status: 429, body: { error: "Too many site checks just now. Try again later." } };
  }
  var ran = await siteCheckRun(Object.assign({}, o, { request: built.request, maxMilli: maxMilli }));
  if (ran.opened) return { status: ran.opened.status, body: ran.opened.body };
  return {
    status: 200,
    body: {
      ok: ran.out.ok,
      url: built.request.url,
      report: publicReport(ran.out.report),
      screenshots: ran.screenshots,
      browserMs: ran.out.browserMs,
      milli: ran.charged.milli,
      credits: ran.charged.credits,
      balance: ran.charged.balance,
      balanceCredits: ran.charged.balanceCredits
    }
  };
}

export function siteCheckToolDef() {
  return {
    type: "function",
    function: {
      name: SITE_CHECK_TOOL,
      description: "Open a deployed, public website in a fresh headless Chromium (Cloudflare Browser Rendering) and report its status, console errors, failed and blocked requests, load timings, web app manifest, service worker, offline reload, a quick accessibility scan, and desktop and phone screenshots that are shown to the user. Optional short scripted steps run first. Every call waits for the user to approve its maximum price and costs Pro credits.",
      parameters: {
        type: "object",
        properties: {
          url: { type: "string", description: "The public http or https address to open." },
          steps: {
            type: "array",
            description: "Up to " + SITE_CHECK_STEPS_MAX + " steps run in order after the page loads: {action:'click'|'type'|'press'|'wait'|'waitFor'|'assertText'|'goto', selector, text, key, ms, url}. Set credential:true on a type step only when the user gave that exact value in their message; password and payment fields are never filled otherwise.",
            items: { type: "object" }
          },
          mobile: { type: "boolean", description: "Also take a phone-sized screenshot. Default true." },
          pwa: { type: "boolean", description: "Check the manifest, service worker and offline reload. Default true." }
        },
        required: ["url"]
      }
    }
  };
}

export function siteCheckPrompt() {
  return [
    "You can check a deployed public website with the check_site tool: it opens the page in a fresh headless browser and returns console errors, failed requests, timings, PWA signals (manifest, service worker, offline reload, installability), a quick accessibility scan and screenshots, which the user sees directly.",
    "Use it to test a live site or PWA; use run_command on the browser image to test the code in the repository. Private, local and Nymbot addresses are refused. Every check_site call pauses for the user to approve it and costs Pro credits (browser time carries a surcharge)."
  ].join("\n");
}

export function siteCheckPauseReply(pending) {
  return "Before I go on I need your OK to check " + inert(pending.url).replace(/`/g, "'").slice(0, 300) +
    " in a headless browser. It costs up to " + pending.maxCredits + " Pro credits, charged for the browser time it actually uses, and includes a browser surcharge. Allow it below and I will carry on from exactly here; decline it and nothing runs.";
}

export function siteCheckTool(o) {
  var usdPerMinute = o.usdPerMinute;
  var price = { usdPerMinute: usdPerMinute, btcUsd: o.btcUsd, milliForUsd: o.milliForUsd };
  var maxMilli = siteCheckMaxMilli(SITE_CHECK_TIMEOUT_SEC, price);
  var perMinute = Math.round(Number(o.milliForUsd(usdPerMinute, o.btcUsd)) || 0) / 1000;
  var gate = function (item, usage) {
    if (!item || item.name !== SITE_CHECK_TOOL) return null;
    if (!item.run || !item.run.check) {
      var built = siteCheckRequest(item.args, { userText: o.userText });
      if (built.error) return { refuse: "Error: check_site was not run: " + built.error };
      item.run = { check: true, request: built.request, maxMilli: maxMilli };
    }
    var run = item.run;
    var roomLeft = null;
    if (o.capGuard && typeof o.capGuard.left === "function") {
      roomLeft = o.capGuard.left(usage || {});
      if (run.maxMilli > roomLeft) {
        return {
          refuse: "Error: check_site was not run. It could cost up to " + runnerCredits(run.maxMilli) +
            " Pro credits, more than the " + runnerCredits(roomLeft) + " left under this chat's spending cap for this reply. Nothing ran and nothing was charged. Tell the user; they can raise the cap."
        };
      }
    }
    if (o.autoRun === true && roomLeft != null && run.maxMilli <= roomLeft) return { allowed: true };
    var steps = run.request.steps.map(function (s) {
      return { action: s.action, selector: s.selector ? String(s.selector).slice(0, 120) : undefined, text: s.action === "type" ? (s.credential ? "••••" : String(s.text || "").slice(0, 80)) : (s.text ? String(s.text).slice(0, 80) : undefined), url: s.url, key: s.key };
    });
    return {
      pending: {
        kind: "server-run", check: true, id: item.id, image: SITE_CHECK_IMAGE, url: run.request.url, command: run.request.url,
        steps: steps, timeoutSec: SITE_CHECK_TIMEOUT_SEC, maxCredits: runnerCredits(run.maxMilli),
        surcharge: Number(o.surcharge) > 1 ? Number(o.surcharge) : 1, creditsPerMinute: perMinute
      },
      declined: "The user declined this site check. Nothing ran and nothing was charged. Carry on without it, and do not ask to run it again unless the user says so."
    };
  };
  var exec = async function (item) {
    var run = item && item.run;
    if (!run || !run.check) return { text: "Error: check_site needs the user's approval first.", milli: 0, entry: null };
    if (typeof o.progress === "function") o.progress({ kind: "server-run", image: SITE_CHECK_IMAGE, stage: "start", command: run.request.url.slice(0, 160) });
    var ran = await siteCheckRun(Object.assign({}, o, { request: run.request, maxMilli: run.maxMilli, git: true }));
    if (ran.opened) {
      return { text: "Error: the site check did not start: " + String((ran.opened.body && ran.opened.body.error) || "unavailable") + " Nothing was charged.", milli: 0, entry: null };
    }
    var entry = {
      image: SITE_CHECK_IMAGE, check: true, command: run.request.url, milli: ran.charged.milli, billedMs: ran.charged.billedMs,
      code: ran.out.ok ? 0 : null, ok: ran.out.ok
    };
    if (ran.screenshots.length) entry.artifacts = ran.screenshots;
    if (typeof o.progress === "function") o.progress({ kind: "server-run", image: SITE_CHECK_IMAGE, stage: "done", credits: ran.charged.credits, code: entry.code, ms: Number(ran.charged.billedMs) || 0 });
    return {
      text: siteCheckModelText({ url: run.request.url, out: ran.out, screenshots: ran.screenshots, milli: ran.charged.milli }),
      milli: ran.charged.milli,
      entry: entry
    };
  };
  return { tool: siteCheckToolDef(), prompt: siteCheckPrompt(), gate: gate, exec: exec, pauseReply: siteCheckPauseReply };
}
