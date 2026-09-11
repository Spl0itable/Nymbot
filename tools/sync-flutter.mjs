import { cp, rm, readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const MIRROR = path.join(ROOT, 'flutter/lib');

const from = process.argv[2] || process.env.NYMBOT_FLUTTER
  || path.resolve(ROOT, '../nymbot-flutter');
const src = path.join(from, 'lib');

async function dartFiles(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await dartFiles(full));
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

async function strings(dir) {
  const out = new Set();
  for (const file of await dartFiles(dir)) {
    if (file.includes('/core/crypto/') || file.endsWith('/i18n/i18n.dart')) continue;
    const body = await readFile(file, 'utf8');
    for (const m of body.matchAll(/\bt\(\s*'((?:[^'\\]|\\.)*)'/g)) out.add(m[1]);
    for (const m of body.matchAll(/\bt\(\s*"((?:[^"\\]|\\.)*)"/g)) out.add(m[1]);
  }
  return out;
}

try {
  await stat(src);
} catch {
  console.error('no Flutter app at ' + src);
  console.error('pass its path, or set NYMBOT_FLUTTER');
  process.exit(1);
}

const before = await strings(MIRROR).catch(() => new Set());
await rm(MIRROR, { recursive: true, force: true });
await cp(src, MIRROR, { recursive: true });
const after = await strings(MIRROR);

const added = [...after].filter((s) => !before.has(s));
const gone = [...before].filter((s) => !after.has(s));
console.log('flutter/lib synced from ' + src);
console.log('  ' + after.size + ' translatable strings (' + added.length + ' new, '
  + gone.length + ' gone)');
added.slice(0, 12).forEach((s) => console.log('  + ' + s.slice(0, 88)));
if (added.length > 12) console.log('  + … ' + (added.length - 12) + ' more');
gone.slice(0, 12).forEach((s) => console.log('  - ' + s.slice(0, 88)));
if (added.length || gone.length) console.log("\nrun 'npm run i18n' to translate the difference");
