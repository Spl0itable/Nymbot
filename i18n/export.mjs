// Writes one app's language packs to the other

import { readdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

import { LANGUAGES } from './languages.mjs';
import { buildPacks, writePacks } from './packs.mjs';
import { appSources, flutterSources } from './surfaces.mjs';

const SURFACES = {
  flutter: { sources: flutterSources, out: 'flutter/assets/i18n' },
  app: { sources: appSources, out: 'dist/app/i18n' },
};

function args(argv) {
  const out = { surface: 'flutter', out: null, prune: true };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const take = () => {
      const value = arg.includes('=') ? arg.slice(arg.indexOf('=') + 1) : argv[++i];
      if (!value) throw new Error(`${arg.split('=')[0]} needs a value`);
      return value;
    };
    if (arg === '--out' || arg.startsWith('--out=')) out.out = take();
    else if (arg === '--surface' || arg.startsWith('--surface=')) out.surface = take();
    else if (arg === '--no-prune') out.prune = false;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!SURFACES[out.surface]) {
    throw new Error(`unknown surface '${out.surface}' — one of: ${Object.keys(SURFACES).join(', ')}`);
  }
  return out;
}

/// Removes `<code>.json` for languages that no longer ship, so a directory
/// cannot keep serving a pack the index has stopped listing. Only ever touches
/// files named after a language this repo knows about.
async function prune(dir, keep) {
  const known = new Set(LANGUAGES.map((l) => l.code));
  let removed = 0;
  let entries;
  try {
    entries = await readdir(dir);
  } catch {
    return 0;
  }
  for (const name of entries) {
    if (!name.endsWith('.json') || name === 'index.json') continue;
    const code = name.slice(0, -'.json'.length);
    if (!known.has(code) || keep.has(code)) continue;
    await unlink(path.join(dir, name));
    removed++;
  }
  return removed;
}

const opts = args(process.argv.slice(2));
if (opts.help) {
  console.log('usage: npm run i18n:export -- [--surface flutter|app] [--out DIR] [--no-prune]');
  process.exit(0);
}

const surface = SURFACES[opts.surface];
const dir = path.resolve(opts.out || surface.out);
const { sources, label } = await surface.sources();
const built = await buildPacks(sources);

console.log(`${label}: ${sources.length} strings across ${LANGUAGES.length - 1} languages`);

if (built.packs.size === 0) {
  console.error(`\nNothing to export — no language covers all ${sources.length} strings.`);
  if (built.partial.length) {
    console.error(`Closest: ${built.partial.slice(0, 5).join(', ')}`
      + (built.partial.length > 5 ? `, and ${built.partial.length - 5} more` : ''));
  }
  console.error('\nRun `npm run i18n` to translate what is missing, then export again.');
  process.exit(1);
}

await writePacks(dir, built);
const removed = opts.prune ? await prune(dir, new Set(built.packs.keys())) : 0;

console.log(`wrote ${built.packs.size} packs + index.json to ${dir}`);
if (removed) console.log(`removed ${removed} pack${removed === 1 ? '' : 's'} no longer published`);
if (built.partial.length) {
  console.log(`skipped ${built.partial.length} incomplete: `
    + built.partial.slice(0, 5).join(', ')
    + (built.partial.length > 5 ? `, and ${built.partial.length - 5} more` : ''));
  console.log('Run `npm run i18n` to fill those in.');
}
