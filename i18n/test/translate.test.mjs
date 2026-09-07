// Exercises the build-time translate client against a local stub: caching,
// retry, concurrency, and the refusal to write a partial cache.

import { createServer } from 'node:http';
import { rm } from 'node:fs/promises';

let fail = 0;
const ok = (cond, msg, extra) => {
  if (!cond) { fail++; console.log('FAIL:', msg, extra === undefined ? '' : extra); }
  else console.log('  ok', msg);
};

// The stub stands in for /api/proxy?action=translate, which speaks two shapes:
// one string (`text`), or a batch (`texts[]` answered with `translations[]`).
// The client batches, and falls back to single requests for the strings a
// batch could not translate — so the stub has to implement both or the tests
// would only ever exercise the fallback.
let calls = 0;          // requests, batched or not
let translated = 0;     // strings actually translated
let failuresLeft = 0;
let emptyFor = null;
const render = (text, target, source) => `${target}:${source}:${text}`;
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    calls++;
    const { text, texts, target, source } = JSON.parse(body);
    if (failuresLeft > 0) { failuresLeft--; res.writeHead(502).end('{"error":"upstream"}'); return; }
    res.writeHead(200, { 'content-type': 'application/json' });
    if (Array.isArray(texts)) {
      // A string the backend could not do comes back as null, which is what
      // makes the client retry that one on its own.
      const out = texts.map((t) => (emptyFor && t === emptyFor ? null : render(t, target, source)));
      translated += out.filter((v) => v !== null).length;
      res.end(JSON.stringify({ translations: out, failed: out.filter((v) => v === null).length }));
      return;
    }
    if (emptyFor && text === emptyFor) { res.end('{"translatedText":""}'); return; }
    translated++;
    res.end(JSON.stringify({ translatedText: render(text, target, source), detectedLanguage: 'en' }));
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
process.env.NYM_TRANSLATE_PROXY = `http://127.0.0.1:${server.address().port}/api/proxy`;
// An empty translation is now read as throttling and backs off for seconds.
// The behavior under test is the retry and the refusal to cache, not the
// length of the pause.
process.env.NYM_I18N_THROTTLE_MS = '5';

const { translateMissing, loadCache, cachePath, activeRoute } = await import('../translate.mjs');
const LANG = '__test__';
const cleanup = () => rm(cachePath(LANG), { force: true });
await cleanup();

try {
  // --- a first run translates everything and persists it -------------------
  const sources = Array.from({ length: 40 }, (_, i) => `string ${i}`);
  const first = await translateMissing(LANG, sources);
  ok(first.translated === 40, 'every uncached string is translated', first.translated);
  // 40 strings plus ONE route probe, shared by all workers rather than one each.
  // Batched: 40 strings in groups of 20 is 2 requests, not 40. The count is
  // what the change bought, so assert it rather than the string total alone.
  ok(calls === 2, '40 strings cost 2 requests, not 40', calls);
  ok(translated === 40, 'and every one of them was translated', translated);
  ok(first.cache['string 7'] === `${LANG}:en:string 7`, 'the translation is stored under its source');

  const persisted = await loadCache(LANG);
  ok(Object.keys(persisted).length === 40, 'the cache is written to disk');

  // --- a second run is free ------------------------------------------------
  calls = 0;
  const second = await translateMissing(LANG, sources);
  ok(second.translated === 0, 'nothing is re-translated');
  ok(calls === 0, 'a warm cache makes no requests at all', calls);

  // --- only new copy costs anything ---------------------------------------
  calls = 0;
  const grown = [...sources, 'a brand new sentence'];
  const third = await translateMissing(LANG, grown);
  ok(third.translated === 1, 'only the new string is sent');
  ok(calls === 1, 'adding copy costs one request, not a full re-run', calls);

  // --- transient upstream failures are retried -----------------------------
  await cleanup();
  calls = 0;
  failuresLeft = 2;
  const retried = await translateMissing(LANG, ['needs a retry']);
  ok(retried.translated === 1, 'a string survives two 502s');
  ok(calls === 3, 'it took three attempts', calls);
  ok(/^http:\/\/127\.0\.0\.1:/.test(activeRoute()), 'the backend answered', activeRoute());

  // --- an empty translation is treated as a failure, not a result ----------
  await cleanup();
  calls = 0;
  emptyFor = 'blank please';
  let threw = false;
  try { await translateMissing(LANG, ['blank please']); } catch { threw = true; }
  ok(threw, 'an empty translation raises rather than caching a blank string');
  ok(calls > 1, 'and is retried, because an empty 200 is how this upstream throttles', calls);
  const afterFailure = await loadCache(LANG);
  ok(Object.keys(afterFailure).length === 0,
     'nothing succeeded here, so nothing is written');
  emptyFor = null;

  // --- a run that partly fails keeps what it earned ------------------------
  //
  // The language still fails, and build.mjs still holds it back until the cache
  // covers every string. But the translations that DID succeed are kept, so the
  // next run finishes the remainder instead of redoing everything and hitting
  // the same wall — which is how three languages once sat at 440/1960 across
  // several runs, each doing fifteen hundred translations and discarding them.
  await cleanup();
  emptyFor = 'string 3';
  threw = false;
  try { await translateMissing(LANG, sources); } catch { threw = true; }
  ok(threw, 'one bad string still fails the language');
  {
    const partial = await loadCache(LANG);
    ok(Object.keys(partial).length === sources.length - 1,
       'but every other string is kept, so a re-run converges', Object.keys(partial).length);
    ok(partial['string 3'] === undefined, 'and the bad one is not cached');
  }

  // The re-run sends only what is still missing, and finishes.
  emptyFor = null;
  calls = 0;
  const finished = await translateMissing(LANG, sources);
  ok(calls === 1, 'the retry costs one request, not a full re-run', calls);
  ok(Object.keys(finished.cache).length === sources.length, 'and completes the language');
} finally {
  await cleanup();
  server.close();
}

console.log(fail === 0 ? '\ntranslate client: all assertions passed' : `\n${fail} FAILURES`);
process.exit(fail ? 1 : 0);
