import { createServer } from 'node:http';
import { rm } from 'node:fs/promises';

let fail = 0;
const ok = (cond, msg, extra) => {
  if (!cond) { fail++; console.log('FAIL:', msg, extra === undefined ? '' : extra); }
  else console.log('  ok', msg);
};

const seen = [];
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    seen.push(req.headers['x-nym-build'] || '');
    const { text, texts, target } = JSON.parse(body);
    res.writeHead(200, { 'content-type': 'application/json' });
    if (Array.isArray(texts)) res.end(JSON.stringify({ translations: texts.map((t) => `${target}:${t}`) }));
    else res.end(JSON.stringify({ translatedText: `${target}:${text}` }));
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const cacheDir = new URL('./.build-token-cache/', import.meta.url).pathname;
process.env.NYM_TRANSLATE_PROXY = `http://127.0.0.1:${server.address().port}/api/proxy`;
process.env.NYM_I18N_CACHE_DIR = cacheDir;
process.env.NYM_BUILD_TOKEN = 'e'.repeat(40);

try {
  const mod = await import('../translate.mjs');
  const run = mod.translateMissing || mod.translateAll || mod.fillCache || mod.translateStrings;
  if (typeof run !== 'function') throw new Error('no translate entry point exported: ' + Object.keys(mod).join(','));
  await run('es', ['Hello there', 'Good night']);
  ok(seen.length > 0, 'the stub was asked to translate', seen.length);
  ok(seen.every((v) => v === 'e'.repeat(40)), 'every request carries X-Nym-Build from NYM_BUILD_TOKEN', seen);
} finally {
  server.close();
  await rm(cacheDir, { recursive: true, force: true });
}
process.exit(fail ? 1 : 0);
