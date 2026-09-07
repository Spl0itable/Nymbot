// The two apps' half of the translation pipeline: what the extractor finds in
// their sources, and what the build turns that into.
//
// The marketing site bakes a translation into a page per language; an app is
// one page, so it ships a pack and applies it at runtime. That difference is
// what this file covers — the site's own path is pipeline.test.mjs.

import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import vm from 'node:vm';

import { appSources, dartStrings, flutterSources } from '../surfaces.mjs';

const run = promisify(execFile);

const root = new URL('../../', import.meta.url).pathname;

let fail = 0;
const ok = (cond, msg, extra) => {
  if (!cond) { fail++; console.log('FAIL:', msg, extra === undefined ? '' : extra); }
  else console.log('  ok', msg);
};

// --- reading t() out of Dart ------------------------------------------------

ok(dartStrings("Text(t('Sign in'))").join('|') === 'Sign in',
   'a plain call is read');
ok(dartStrings("t('one long sentence '\n  'continued here')").join('|')
   === 'one long sentence continued here',
   'the formatter splitting a long string across lines is one string again');
ok(dartStrings(`t("it's here " 'and here')`).join('|') === "it's here and here",
   'and it may switch quote style across the join, which is how the formatter escapes an apostrophe');
ok(dartStrings("t('a\\nb')").join('|') === 'a\nb', 'escapes are decoded');
ok(dartStrings("widget.t('x')").length === 0 && dartStrings("format(x)").length === 0,
   'a method call on something else is not a call site');
ok(dartStrings("/// Every screen reads `t()` on build.\nt('Real')").join('|') === 'Real',
   'a comment that merely mentions t() is not a call site');
ok(dartStrings("// t('commented out')\nt('Real')").join('|') === 'Real',
   'and a commented-out call does not ship a string nothing renders');
ok(dartStrings("final url = 'https://example.test'; // not a comment\nt('Real')")
     .join('|') === 'Real',
   'a `//` inside a string literal does not blank the rest of the line');

let threw = false;
try { dartStrings("t('total: \$n')"); } catch (_) { threw = true; }
ok(threw, 'an interpolated string fails the build rather than being dropped silently');
threw = false;
try { dartStrings('t(someVariable)'); } catch (_) { threw = true; }
ok(threw, 'and so does a call the extractor cannot resolve');

// --- what each surface actually reports ------------------------------------

const app = await appSources();
const flutter = await flutterSources();

ok(app.sources.length > 100, 'the web app has a source set', app.sources.length);
ok(flutter.sources.length > 100, 'so does the Flutter app', flutter.sources.length);

for (const surface of [app, flutter]) {
  ok(surface.sources.every((s) => typeof s === 'string' && s.trim() === s && s.length > 1),
     `${surface.label}: every source string is trimmed prose`);
  ok(new Set(surface.sources).size === surface.sources.length,
     `${surface.label}: with no duplicates, since the pack is keyed by the string`);
  ok(!surface.sources.some((s) => s.includes('${')),
     `${surface.label}: and none of them carries an interpolation the pack could not match`);
}

// Placeholders are the one thing a translator must carry through verbatim, so
// the same name has to exist on both sides of the call.
for (const surface of [app, flutter]) {
  const withVars = surface.sources.filter((s) => /\{\w+\}/.test(s));
  ok(withVars.length > 0, `${surface.label}: some strings take placeholders`, withVars.length);
}

// The whole point of one shared cache: an overlap is paid for once.
const shared = app.sources.filter((s) => flutter.sources.includes(s));
ok(shared.length > 20,
   'the two apps say many of the same things, and share the cache entry for them',
   shared.length);

// --- packs ------------------------------------------------------------------
// Driven through a child process: translate.mjs reads the cache directory once
// at import time, so the override has to be in place before the module loads.

{
  const scratch = await mkdtemp(path.join(tmpdir(), 'nym-i18n-apps-'));
  const cacheDir = path.join(scratch, 'cache');
  const outDir = path.join(scratch, 'out');
  const emptyDir = path.join(scratch, 'empty');
  await mkdir(cacheDir, { recursive: true });

  const sources = ['Sign in', 'New chat', '{n} relays'];
  await writeFile(path.join(cacheDir, 'es.json'),
    JSON.stringify(Object.fromEntries(sources.map((s) => [s, `[es]${s}`]))));
  // One string short. A pack that covers most of a screen is worse than none:
  // it puts two languages in one sentence.
  await writeFile(path.join(cacheDir, 'fr.json'),
    JSON.stringify({ 'Sign in': '[fr]Sign in', 'New chat': '[fr]New chat' }));

  const driver = path.join(scratch, 'driver.mjs');
  await writeFile(driver, `
    import { buildPacks, writePacks } from ${JSON.stringify(path.join(root, 'i18n/packs.mjs'))};
    const sources = ${JSON.stringify(sources)};
    const built = await buildPacks(sources);
    await writePacks(${JSON.stringify(outDir)}, built);
    process.stdout.write(JSON.stringify({
      codes: [...built.packs.keys()], partial: built.partial, published: built.published,
    }));
  `);
  const { stdout } = await run(process.execPath, [driver],
    { env: { ...process.env, NYM_I18N_CACHE_DIR: cacheDir + '/' } });
  const built = JSON.parse(stdout);

  ok(built.codes.includes('es'), 'a language covering every string is published');
  ok(!built.codes.includes('fr'), 'a language missing one is not');
  ok(built.partial.some((p) => p.startsWith('fr (2/3)')),
     'and is reported so the gap is visible rather than silent', built.partial);
  ok(built.published.find((l) => l.code === 'es')?.name === 'Spanish',
     'the index names the language');
  ok(built.published.find((l) => l.code === 'es')?.native,
     'in its own script, so a reader who cannot read the current one still finds it');

  const written = (await readdir(outDir)).sort();
  ok(written.join(',') === 'es.json,index.json',
     'the pack and the index are written, and nothing else', written);
  const index = JSON.parse(await readFile(path.join(outDir, 'index.json'), 'utf8'));
  ok(Array.isArray(index) && index.length === 1, 'the index is the list the app fetches');
  const pack = JSON.parse(await readFile(path.join(outDir, 'es.json'), 'utf8'));
  ok(pack['{n} relays'] === '[es]{n} relays',
     'a pack is keyed by the English string, which is what both runtimes look up');

  // An empty cache publishes nothing, which is what a fresh checkout looks
  // like — and it must still write an index, or the app fetches a 404 on boot.
  await rm(path.join(cacheDir, 'es.json'));
  await rm(path.join(cacheDir, 'fr.json'));
  const emptyDriver = path.join(scratch, 'empty.mjs');
  await writeFile(emptyDriver, `
    import { buildPacks, writePacks } from ${JSON.stringify(path.join(root, 'i18n/packs.mjs'))};
    const built = await buildPacks(${JSON.stringify(sources)});
    await writePacks(${JSON.stringify(emptyDir)}, built);
    process.stdout.write(String(built.packs.size));
  `);
  const empty = await run(process.execPath, [emptyDriver],
    { env: { ...process.env, NYM_I18N_CACHE_DIR: cacheDir + '/' } });
  ok(empty.stdout === '0', 'an empty cache publishes nothing');
  ok(JSON.parse(await readFile(path.join(emptyDir, 'index.json'), 'utf8')).length === 0,
     'and still writes an index, so the app boots into English instead of erroring');
  ok((await readdir(emptyDir)).join(',') === 'index.json', 'and no pack beside it');

  await rm(scratch, { recursive: true, force: true });
}

// --- the two runtimes agree with each other and with the extractor ----------

const appJs = await readFile(path.join(root, 'app/js/i18n.js'), 'utf8');
const dartI18n = await readFile(path.join(root, 'flutter/lib/features/i18n/i18n.dart'), 'utf8');

{
  // The module is an IIFE that fetches on load; it is run here against stubs so
  // the substitution rule itself can be checked rather than reimplemented.
  const calls = [];
  const sandbox = {
    window: {}, navigator: { languages: ['es-ES', 'es'] },
    localStorage: { getItem: () => null, setItem: () => {} },
    location: { reload: () => {} },
    document: { documentElement: {}, body: null, createTreeWalker: () => ({ nextNode: () => null }) },
    NodeFilter: { SHOW_TEXT: 4, SHOW_ELEMENT: 1, FILTER_ACCEPT: 1, FILTER_REJECT: 2 },
    Node: { ELEMENT_NODE: 1, TEXT_NODE: 3 },
    fetch: async (url) => { calls.push(url); return { ok: false }; },
  };
  sandbox.window = sandbox;
  sandbox.window.NymbotConfig = { storagePrefix: 'nymbot_' };
  vm.createContext(sandbox);
  vm.runInContext(appJs, sandbox);
  const I18n = sandbox.window.NymbotI18n;
  await I18n.ready;

  ok(calls[0] === '/app/i18n/index.json',
     'the web app looks for its index where the build writes it', calls);
  ok(I18n.lang === 'en' && I18n.pack === null,
     'and stays in English when there is none, rather than failing to boot');

  I18n.pack = { 'Sign in': '[es]Sign in', '{n} relays': '[es]{n} conexiones' };
  ok(I18n.t('Sign in') === '[es]Sign in', 'a hit is translated');
  ok(I18n.t('Not in the pack') === 'Not in the pack',
     'a miss degrades to English rather than to a key');
  ok(I18n.t('{n} relays', { n: 4 }) === '[es]4 conexiones', 'placeholders are filled');
  ok(I18n.t('{n} relays', {}) === '[es]{n} conexiones',
     'and a name the caller did not pass is left alone rather than printed as undefined');
  ok(typeof sandbox.window.t === 'function' && sandbox.window.t('Sign in') === '[es]Sign in',
     'the shorthand the extractor looks for is installed, and goes through the same table');
}

{
  // The Dart side cannot be executed here, so what is pinned is the agreement
  // the two runtimes have to keep: the same placeholder syntax and the same
  // right-to-left set. A pack is shared between them; a rule that is not would
  // render one of the two wrong.
  const rtlJs = /const RTL = new Set\(\[([^\]]*)\]\)/.exec(appJs)[1];
  const rtlDart = /static bool get isRtl => const \{([^}]*)\}/.exec(dartI18n)[1];
  const codes = (s) => [...s.matchAll(/'([a-z-]+)'/g)].map((m) => m[1]).sort().join(',');
  ok(codes(rtlJs) === codes(rtlDart) && codes(rtlJs).includes('ar'),
     'both runtimes lay out the same languages right to left', codes(rtlJs));
  ok(dartI18n.includes(String.raw`RegExp(r'\{(\w+)\}')`)
     && appJs.includes(String.raw`/\{(\w+)\}/g`),
     'and read the same placeholder syntax, since one pack feeds both');
  ok(dartI18n.includes("'assets/i18n'"), 'the Flutter app reads the packs from its bundle');
}

// --- the app shell -----------------------------------------------------------

{
  const html = await readFile(path.join(root, 'app/index.html'), 'utf8');
  ok(html.indexOf('js/config.js') < html.indexOf('js/i18n.js'),
     'i18n.js loads after the config it reads the storage prefix from');
  const sw = await readFile(path.join(root, 'app/sw.js'), 'utf8');
  ok(sw.includes('/app/js/i18n.js'),
     'and is in the service worker shell, so a translated app still opens offline');
  ok(!sw.includes('/app/i18n/'),
     'while the packs are not precached: they are fetched per language, and one is 132 files');
}

// --- the Flutter bundle ------------------------------------------------------

{
  const pubspec = await readFile(path.join(root, 'flutter/pubspec.yaml'), 'utf8');
  ok(/assets:\s*\n\s*- assets\/i18n\//.test(pubspec),
     'the Flutter bundle declares the pack directory');
  const index = await readFile(path.join(root, 'flutter/assets/i18n/index.json'), 'utf8');
  ok(Array.isArray(JSON.parse(index)),
     'and an index is committed, so a checkout that has never been built still bundles');
}

console.log(fail === 0 ? '\napp translation: all assertions passed' : `\n${fail} FAILURES`);
process.exit(fail ? 1 : 0);
