// Fills i18n/cache/<lang>.json with uncached strings (npm run i18n); args: --only=es,ja,fr, --list.

import { TRANSLATED_LANGUAGES } from './languages.mjs';
import { allSurfaces } from './surfaces.mjs';
import { loadCache, translateMissing } from './translate.mjs';

const args = process.argv.slice(2);
const only = (args.find((a) => a.startsWith('--only=')) || '').slice('--only='.length);
const listOnly = args.includes('--list');
const wanted = only ? new Set(only.split(',').map((s) => s.trim())) : null;

const { surfaces, union: sources } = await allSurfaces();
const targets = TRANSLATED_LANGUAGES.filter((l) => !wanted || wanted.has(l.code));

console.log(`${sources.length} source strings (`
  + surfaces.map((s) => `${s.sources.length} ${s.label}`).join(', ')
  + `), ${targets.length} languages`);

if (listOnly) {
  for (const surface of surfaces) {
    let complete = 0;
    const gaps = [];
    for (const lang of targets) {
      const cache = await loadCache(lang.code);
      const have = surface.sources.filter((s) => typeof cache[s] === 'string').length;
      if (have === surface.sources.length) complete++;
      else gaps.push(`  ${lang.code.padEnd(7)} ${have}/${surface.sources.length}  ${lang.name}`);
    }
    console.log(`\n${surface.label}: ${complete}/${targets.length} languages fully cached`);
    for (const line of gaps.slice(0, 10)) console.log(line);
    if (gaps.length > 10) console.log(`  … and ${gaps.length - 10} more`);
  }
  process.exit(0);
}

const LANG_CONCURRENCY = Number(process.env.NYM_I18N_LANG_CONCURRENCY || 8);

let failed = 0;
let done = 0;

async function runLang(lang) {
  try {
    const { translated } = await translateMissing(lang.code, sources);
    done++;
    process.stdout.write(`  ${lang.code.padEnd(7)} ${translated === 0 ? 'cached' : `+${translated}`}`.padEnd(28)
      + `${lang.name}  (${done}/${targets.length})\n`);
  } catch (err) {
    failed++;
    done++;
    process.stdout.write(`  ${lang.code.padEnd(7)} FAILED`.padEnd(28) + `${err.message}\n`);
  }
}

{
  const queue = targets.slice();
  const worker = async () => {
    for (;;) {
      const lang = queue.shift();
      if (!lang) return;
      await runLang(lang);
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(LANG_CONCURRENCY, queue.length) }, worker));
}

if (failed > 0) {
  console.error(`\n${failed} language(s) failed. Re-run to retry — cached strings are not re-sent.`);
  process.exit(1);
}
console.log('\nAll languages cached. Commit i18n/cache/ so the next build reuses it.');
