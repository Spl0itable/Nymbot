// Translated at build time via `/api/proxy?action=translate`; results are committed under i18n/cache/.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const PROXY = process.env.NYM_TRANSLATE_PROXY || 'https://nymbot.ai/api/proxy';
const BUILD_TOKEN = (process.env.NYM_BUILD_TOKEN || '').trim();
const proxyHeaders = () => ({
  'Content-Type': 'application/json',
  ...(BUILD_TOKEN ? { 'X-Nym-Build': BUILD_TOKEN } : {}),
});
// Overridable so tests never touch the committed cache.
const CACHE_DIR = process.env.NYM_I18N_CACHE_DIR || new URL('./cache/', import.meta.url).pathname;

/// Kept low to be polite to the upstream.
const CONCURRENCY = 6;
const RETRIES = 3;

/// Base pause after a throttle, doubling per attempt; overridable for tests.
const THROTTLE_MS = Number(process.env.NYM_I18N_THROTTLE_MS || 6000);

/// Bounded by count and by query length, because the endpoint takes its input in the URL.
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

/// Used when a batch comes back short, so one bad string costs only itself.
async function viaProxy(text, target) {
  const res = await fetch(`${PROXY}?action=translate`, {
    method: 'POST',
    headers: proxyHeaders(),
    body: JSON.stringify({ text, source: 'en', target }),
  });
  if (!res.ok) throw new Error(`proxy ${res.status}`);
  const data = await res.json();
  if (data && data.error) throw new Error(data.error);
  return (data && data.translatedText) || '';
}

/// Returns translations positionally, `null` for a failure; a wrong-length response throws.
async function viaProxyBatch(texts, target) {
  const res = await fetch(`${PROXY}?action=translate`, {
    method: 'POST',
    headers: proxyHeaders(),
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

let route = null;

function pickRoute() {
  if (!route) route = viaProxyBatch;
  return Promise.resolve(route);
}

/// Includes a 200 with an empty translation: the endpoint soft-throttles that way.
const isThrottled = (err) => /\b(429|403)\b|empty translation/.test(String(err && err.message));

/// The pause is shared so every worker backs off together.
let cooldownUntil = 0;
const cooldown = () => {
  const left = cooldownUntil - Date.now();
  return left > 0 ? new Promise((r) => setTimeout(r, left)) : Promise.resolve();
};

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

/// Set once the backend answers 400 to a batch; older deployments reject every batch.
let batchUnsupported = false;

/// A malformed batch is retried string by string, sequentially after any cooldown, so throttling does not multiply.
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
    // Retry only the holes, sequentially.
    for (let i = 0; i < out.length; i++) {
      if (out[i] === null) out[i] = await one(texts[i]);
    }
    return out;
  } catch (err) {
    if (isThrottled(err)) cooldownUntil = Math.max(cooldownUntil, Date.now() + THROTTLE_MS);
    // A 400 means an older deployment without `texts[]`; say so once, loudly.
    if (/\b400\b/.test(err.message || '') && !batchUnsupported) {
      batchUnsupported = true;
      notice(`the backend rejected a batch (${err.message}) — it is probably an `
        + 'older deployment without the batch endpoint. Falling back to one '
        + 'request per string for the rest of this run.');
    }
    // Returning `null` for one string keeps the rest and names the one that failed.
    const out = [];
    for (const text of texts) out.push(await one(text));
    return out;
  }
}

export const activeRoute = () => (route ? PROXY : 'unknown');

/// Drops entries whose English source is gone so the committed cache tracks the copy.
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

  // Decide the route first; the queue's shape depends on which one answers.
  await pickRoute();
  const queue = batches(missing);

  let index = 0;
  let done = 0;
  const failures = [];
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

  // Progress is saved even on failure; build.mjs withholds any language whose cache is incomplete.
  await saveCache(lang, prune(cache, sources));

  if (failures.length > 0) {
    const sample = failures.slice(0, 3).map((f) => `${JSON.stringify(f.source.slice(0, 40))}: ${f.error}`);
    throw new Error(
      `${lang}: ${failures.length}/${missing.length} strings failed to translate`
      + ` (${missing.length - failures.length} kept; re-run to finish)\n  ${sample.join('\n  ')}`);
  }

  return { cache, translated: missing.length };
}
