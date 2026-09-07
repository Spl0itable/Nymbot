// Build-time translation through the app's backend
// (`/api/proxy?action=translate`, nym-staging functions/api/proxy.js), which
// runs the models on Workers AI.
//
// The app translates at runtime and caches on-device; the landing page cannot,
// because a search engine has to see finished text. So the text is translated
// at BUILD time and the results are committed under i18n/cache/, which makes
// builds reproducible, keeps CI offline-capable, and means a language is only
// ever paid for once per string.
//
// This briefly went straight to Google instead, because the backend's own
// upstream WAS Google and was being rate-limited by colo IP. The backend no
// longer calls out to anyone, so that reason is gone.
//
// Source is always English here, which is what lets the backend take its fast
// dedicated-translator paths rather than the instruct fallback.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

/// web.nymchat.app, not nymchat.app. Only that deployment carries the bot
/// worker, and therefore the AI binding the translate endpoint runs on — the
/// apex host answers the request and fails every translation in it.
const PROXY = process.env.NYM_TRANSLATE_PROXY || 'https://web.nymchat.app/api/proxy';
// Overridable so tests never touch the committed cache.
const CACHE_DIR = process.env.NYM_I18N_CACHE_DIR || new URL('./cache/', import.meta.url).pathname;

/// Concurrent requests. The proxy fans out to Google Translate, so this is
/// polite rather than fast.
const CONCURRENCY = 6;
const RETRIES = 3;

/// Base pause after a throttle, doubling per attempt. Overridable so the tests
/// can exercise the retry path without waiting out a real backoff.
const THROTTLE_MS = Number(process.env.NYM_I18N_THROTTLE_MS || 6000);

/// How many strings the batched upstream route puts in one request. Bounded by
/// count and by encoded query length, because the endpoint takes its input in
/// the URL — a knowledge base's worth of copy would otherwise build a query
/// string the server rejects.
const BATCH_STRINGS = 20;
const BATCH_CHARS = 16000;

export const cachePath = (lang) => path.join(CACHE_DIR, `${lang}.json`);

export async function loadCache(lang) {
  try {
    return JSON.parse(await readFile(cachePath(lang), 'utf8'));
  } catch {
    return {};
  }
}

export async function saveCache(lang, map) {
  await mkdir(CACHE_DIR, { recursive: true });
  // Sorted keys so a re-run produces no spurious diff.
  const sorted = {};
  for (const key of Object.keys(map).sort()) sorted[key] = map[key];
  await writeFile(cachePath(lang), JSON.stringify(sorted, null, 2) + '\n');
}

/// One string. Used when a batch comes back short, so a single bad string
/// costs itself rather than its nineteen neighbours.
async function viaProxy(text, target) {
  const res = await fetch(`${PROXY}?action=translate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, source: 'en', target }),
  });
  if (!res.ok) throw new Error(`proxy ${res.status}`);
  const data = await res.json();
  if (data && data.error) throw new Error(data.error);
  return (data && data.translatedText) || '';
}

/// Many strings, one request. The backend still runs one inference per string;
/// what this saves is the round trip, which is most of the wall clock when
/// there are a few hundred thousand of them to get through.
///
/// Returns translations positionally. A `null` is a string the backend could
/// not translate. A response of the wrong LENGTH is different and throws:
/// there is no way to tell which translation belongs to which source.
async function viaProxyBatch(texts, target) {
  const res = await fetch(`${PROXY}?action=translate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ texts, source: 'en', target }),
  });
  if (!res.ok) throw new Error(`proxy ${res.status}`);
  const data = await res.json();
  if (data && data.error) throw new Error(data.error);
  const out = data && Array.isArray(data.translations) ? data.translations : null;
  if (!out || out.length !== texts.length) {
    throw new Error('batch response did not line up with the request');
  }
  return out.map((v) => (typeof v === 'string' && v.trim() ? v : null));
}

/// The one route there is.
let route = null;

function pickRoute() {
  if (!route) route = viaProxyBatch;
  return Promise.resolve(route);
}

/// What throttling looks like on this upstream.
///
/// A 429 or a 403 is the obvious form. The one that is not obvious, and cost
/// three languages a full run, is a 200 carrying an EMPTY translation: the
/// endpoint soft-throttles by answering successfully with nothing in it. Read
/// as "transient error" that gets a few hundred milliseconds of backoff, which
/// under throttling is no wait at all, and the retries are spent for nothing.
const isThrottled = (err) => /\b(429|403)\b|empty translation/.test(String(err && err.message));

/// When one request is throttled, every worker waits. Six workers each backing
/// off privately still means six requests a second at a server that has just
/// asked for fewer, so the pause is shared.
let cooldownUntil = 0;
const cooldown = () => {
  const left = cooldownUntil - Date.now();
  return left > 0 ? new Promise((r) => setTimeout(r, left)) : Promise.resolve();
};

/// Retries [attempt] a few times, pausing much longer when throttled than after
/// a transient 5xx.
async function withRetries(attempt) {
  for (let i = 0; i < RETRIES; i++) {
    await cooldown();
    try {
      return await attempt();
    } catch (err) {
      if (i === RETRIES - 1) throw err;
      const wait = isThrottled(err) ? THROTTLE_MS * Math.pow(2, i) : 400 * Math.pow(2, i);
      if (isThrottled(err)) cooldownUntil = Math.max(cooldownUntil, Date.now() + wait);
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw new Error('unreachable');
}

async function translateOne(text, target) {
  return withRetries(async () => {
    const out = await viaProxy(text, target);
    if (!out.trim()) throw new Error('empty translation');
    return out;
  });
}

/// Splits [texts] into requests the batched route will accept.
function batches(texts) {
  const out = [];
  let current = [];
  let bytes = 0;
  for (const text of texts) {
    const cost = text.slice(0, 5000).length;
    if (current.length > 0 && (current.length >= BATCH_STRINGS || bytes + cost > BATCH_CHARS)) {
      out.push(current);
      current = [];
      bytes = 0;
    }
    current.push(text);
    bytes += cost;
  }
  if (current.length > 0) out.push(current);
  return out;
}

/// Translates a group of strings, as one request where the route allows it.
/// A batch that comes back malformed is retried string by string rather than
/// failing the language: one unlucky response should not cost a whole run.
///
/// The fallback is SEQUENTIAL, and waits out any cooldown first. Fanning a
/// failed batch of twenty into twenty concurrent requests is the worst possible
/// response to being throttled, and it is why failures arrived in exact
/// multiples of the batch size: one throttled batch became twenty throttled
/// strings, all of them spending their retries inside the same bad window.
/// Whether the backend has already told us it does not speak the batch shape.
/// Worth remembering for the run: an older deployment answers 400 to every
/// batch, and finding that out once per group is 130 wasted round trips.
let batchUnsupported = false;

/// Records why a string could not be translated, keyed by the string.
///
/// Every one of these used to be a bare `catch { null }`, so the reason was
/// discarded and the report said "no translation returned" for a 400, a 502, a
/// timeout and an empty answer alike. That is the difference between "the
/// backend is not deployed yet" and "this one string is untranslatable", and
/// the run said neither.
async function translateGroup(texts, target, reasons) {
  await pickRoute();
  const one = async (text) => {
    try { return await translateOne(text, target); }
    catch (err) { reasons.set(text, err.message || String(err)); return null; }
  };
  if (texts.length === 1 || batchUnsupported) {
    const out = [];
    for (const text of texts) out.push(await one(text));
    return out;
  }
  try {
    const out = await withRetries(() => viaProxyBatch(texts, target));
    // A batch that came back with holes in it: retry just those, sequentially.
    for (let i = 0; i < out.length; i++) {
      if (out[i] === null) out[i] = await one(texts[i]);
    }
    return out;
  } catch (err) {
    if (isThrottled(err)) cooldownUntil = Math.max(cooldownUntil, Date.now() + THROTTLE_MS);
    // A 400 means the endpoint does not know `texts[]` — an older deployment.
    // Say so once, loudly: it is the difference between a slow run and a
    // backend that has not shipped yet, and the per-string path below will
    // otherwise hide it behind whatever it fails with next.
    if (/\b400\b/.test(err.message || '') && !batchUnsupported) {
      batchUnsupported = true;
      notice(`the backend rejected a batch (${err.message}) — it is probably an `
        + 'older deployment without the batch endpoint. Falling back to one '
        + 'request per string for the rest of this run.');
    }
    // One string's failure is one string's failure. Returning `null` for it
    // keeps the other nineteen, and lets the caller name the string that
    // actually failed instead of blaming the batch it happened to be in.
    const out = [];
    for (const text of texts) out.push(await one(text));
    return out;
  }
}

/// The route actually in use, for the CLI to report.
export const activeRoute = () => (route ? PROXY : 'unknown');

/// Translates every source string missing from [lang]'s cache and returns the
/// merged map. Strings already cached cost nothing.
/// Drops entries whose English source is no longer on the page, so the
/// committed cache tracks the copy instead of growing forever.
function prune(cache, sources) {
  const live = new Set(sources);
  const out = {};
  for (const [key, value] of Object.entries(cache)) {
    if (live.has(key)) out[key] = value;
  }
  return out;
}

export async function translateMissing(lang, sources, { onProgress } = {}) {
  const cache = await loadCache(lang);
  const missing = sources.filter((s) => typeof cache[s] !== 'string');
  if (missing.length === 0) {
    // Still prune: copy may have been removed since the last run.
    const kept = prune(cache, sources);
    if (Object.keys(kept).length !== Object.keys(cache).length) await saveCache(lang, kept);
    return { cache: kept, translated: 0 };
  }

  // Decide the route before splitting the work: the proxy takes one string per
  // request, the fallback takes many, and the shape of the queue follows from
  // which one is answering.
  await pickRoute();
  const queue = batches(missing);

  let index = 0;
  let done = 0;
  const failures = [];
  /// Why each failed string failed, filled in by translateGroup.
  const reasons = new Map();

  const worker = async () => {
    while (index < queue.length) {
      const group = queue[index++];
      try {
        const translated = await translateGroup(group, lang, reasons);
        group.forEach((source, i) => {
          if (typeof translated[i] === 'string') cache[source] = translated[i];
          else failures.push({ source, error: reasons.get(source) || 'no translation returned' });
        });
      } catch (err) {
        for (const source of group) failures.push({ source, error: String(err.message || err) });
      }
      done += group.length;
      onProgress?.(done, missing.length);
    }
  };

  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, queue.length) }, worker));

  // What succeeded is written even when something failed. It used to be
  // discarded: a language that lost one string to a transient upstream error
  // threw away the other fifteen hundred translations of that run, so the next
  // attempt started from the same place, did the same work, hit the same wall
  // and discarded it again. Three languages sat at 440/1960 through several
  // runs for exactly that reason — "re-run to retry, cached strings are not
  // re-sent" was a promise the code could not keep.
  //
  // A partial cache cannot publish a partial page: build.mjs holds a language
  // back until its cache covers every string on the site. That gate is what
  // makes saving progress safe, and it is a better place for the invariant than
  // refusing to remember work that was already paid for.
  await saveCache(lang, prune(cache, sources));

  if (failures.length > 0) {
    const sample = failures.slice(0, 3).map((f) => `${JSON.stringify(f.source.slice(0, 40))}: ${f.error}`);
    throw new Error(
      `${lang}: ${failures.length}/${missing.length} strings failed to translate`
      + ` (${missing.length - failures.length} kept; re-run to finish)\n  ${sample.join('\n  ')}`);
  }

  return { cache, translated: missing.length };
}
