// The web app's translation, in a real browser, against a synthetic pack.
//
// Not part of `npm test`: it needs Chromium, which a checkout does not have.
//
//   npm i --no-save playwright-core && npx playwright install chromium
//   node i18n/test/browser.mjs
//
// What it covers is the half no unit test can: the DOM walk. `t()` is a pure
// function and is tested in apps.test.mjs; whether the strings ALREADY IN THE
// MARKUP get replaced — and whether the ones that must not be, are not — is a
// question about a live document.
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, writeFile, mkdir } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
let chromium;
try {
  ({ chromium } = await import('playwright-core'));
} catch (_) {
  console.log('skipped: playwright-core is not installed (see the header of this file)');
  process.exit(0);
}

const run = promisify(execFile);
const root = new URL('../../', import.meta.url).pathname;

// 1. A cache that covers every app string, so the build publishes an es pack.
const { appSources } = await import(path.join(root, 'i18n/surfaces.mjs'));
const sources = (await appSources()).sources;
const scratch = await mkdtemp(path.join(tmpdir(), 'nym-pwa-'));
await mkdir(scratch, { recursive: true });
await writeFile(path.join(scratch, 'es.json'),
  JSON.stringify(Object.fromEntries(sources.map((s) => [s, `[es]${s}`]))));

await run('node', ['build.mjs'], {
  cwd: root,
  env: { ...process.env, NYM_I18N_CACHE_DIR: scratch + '/' },
});

const dist = path.join(root, 'dist');
const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml',
  '.webmanifest': 'application/manifest+json', '.txt': 'text/plain',
  '.xml': 'application/xml', '.ico': 'image/x-icon',
};
const server = createServer(async (req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/app') p = '/app/index.html';
  if (p.endsWith('/')) p += 'index.html';
  const file = path.join(dist, p);
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
    res.end(body);
  } catch (_) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
  }
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

let fail = 0;
const ok = (cond, msg, extra) => {
  if (!cond) { fail++; console.log('FAIL:', msg, extra ?? ''); }
  else console.log('  ok', msg);
};

// PLAYWRIGHT_CHROMIUM_PATH lets a sandbox point at a browser it already has.
const browser = await chromium.launch(process.env.PLAYWRIGHT_CHROMIUM_PATH
  ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH }
  : {});
const errors = [];
try {
  const index = JSON.parse(await readFile(path.join(dist, 'app/i18n/index.json'), 'utf8'));
  ok(index.some((l) => l.code === 'es'), 'the build published an es pack for the app',
     index.map((l) => l.code));

  // --- English by default ---------------------------------------------------
  {
    const ctx = await browser.newContext({ locale: 'en-US' });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(`${base}/app`, { waitUntil: 'networkidle' });
    const html = await page.locator('html').getAttribute('lang');
    ok(html === 'en', 'an English browser gets the English app', html);
    ok(!(await page.content()).includes('[es]'), 'with no translated string in it');
    await ctx.close();
  }

  // --- the browser's language ------------------------------------------------
  {
    const ctx = await browser.newContext({ locale: 'es-ES' });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(`${base}/app`, { waitUntil: 'networkidle' });
    ok(await page.locator('html').getAttribute('lang') === 'es',
       'a Spanish browser gets the Spanish app without being asked');
    const body = await page.locator('body').innerText();
    ok(body.includes('[es]'), 'and the markup already in the page is translated');
    const composer = await page.locator('#input').getAttribute('placeholder');
    ok(composer?.startsWith('[es]'), 'including the attributes that carry prose', composer);
    const nsecHint = await page.locator('#gateNsec').getAttribute('placeholder');
    ok(nsecHint === 'nsec1…', 'while a value that is not prose is left alone', nsecHint);
    const skipped = await page.locator('[data-i18n-skip]').count();
    if (skipped) {
      const text = await page.locator('[data-i18n-skip]').first().innerText();
      ok(!text.includes('[es]'), 'and so is a subtree marked untranslatable');
    }
    const stored = await page.evaluate(() => window.NymbotI18n.lang);
    ok(stored === 'es', 'the runtime knows which language it is in');
    ok(await page.evaluate(() => window.t('New chat')) === '[es]New chat',
       'and t() resolves against the pack for anything rendered later');
    await ctx.close();
  }

  // --- an explicit choice beats the browser ---------------------------------
  {
    const ctx = await browser.newContext({ locale: 'es-ES' });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(`${base}/app`, { waitUntil: 'networkidle' });
    await page.evaluate(() => window.NymbotI18n.setLang('en'));
    await page.waitForLoadState('networkidle');
    ok(await page.locator('html').getAttribute('lang') === 'en',
       'choosing English sticks, even in a Spanish browser');
    // The picker is filled when the settings modal opens, which is behind a
    // key; the population itself is what matters here.
    const opts = await page.evaluate(() => {
      window.NymbotUI.renderLanguages();
      return [...document.querySelectorAll('#langSelect option')].map((o) => o.value);
    });
    ok(opts.includes('en') && opts.includes('es'),
       'and the picker lists English plus what is published', opts);
    await ctx.close();
  }

  // --- a missing pack --------------------------------------------------------
  {
    const ctx = await browser.newContext({ locale: 'es-ES' });
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.route('**/app/i18n/*.json', (r) => r.fulfill({ status: 404, body: '' }));
    await page.goto(`${base}/app`, { waitUntil: 'networkidle' });
    ok(await page.locator('html').getAttribute('lang') === 'en',
       'a pack the server does not have leaves the app in English rather than blank');
    await ctx.close();
  }

  ok(errors.length === 0, 'no page threw', errors);
} finally {
  await browser.close();
  server.close();
}
console.log(fail === 0 ? '\nPWA translation: all assertions passed' : `\n${fail} FAILURES`);
process.exit(fail ? 1 : 0);
