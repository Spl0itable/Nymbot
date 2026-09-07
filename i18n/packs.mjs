// Per-language packs for the two apps.
//
// The marketing site substitutes translations into its pages at build time —
// one page per language. An app is one page, so it fetches a pack instead and
// applies it at runtime. Both read from the SAME cache, keyed by the English
// string, so a sentence the site and the app share is translated once.
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { LANGUAGES } from './languages.mjs';
import { loadCache } from './translate.mjs';

const byCode = new Map(LANGUAGES.map((l) => [l.code, l]));

/// Builds `{ packs, published, partial }` for one surface's [sources].
///
/// A language ships only when the whole surface is covered. Half a pack is
/// worse than none: it puts two languages in one sentence, and the reader
/// cannot tell which half is the app's opinion and which is a gap.
export async function buildPacks(sources) {
  const wanted = new Set(sources);
  const packs = new Map();
  const partial = [];
  for (const lang of LANGUAGES) {
    if (lang.code === 'en') continue;
    const cache = await loadCache(lang.code);
    const pack = {};
    let have = 0;
    for (const source of wanted) {
      const value = cache[source];
      if (typeof value !== 'string') continue;
      pack[source] = value;
      have++;
    }
    if (have === 0) continue;
    if (have < wanted.size) {
      partial.push(`${lang.code} (${have}/${wanted.size})`);
      continue;
    }
    packs.set(lang.code, pack);
  }
  const published = [...packs.keys()].map((code) => ({
    code,
    name: byCode.get(code).name,
    ...(byCode.get(code).native ? { native: byCode.get(code).native } : {}),
  }));
  return { packs, published, partial };
}

/// Writes `<dir>/<lang>.json` plus the `index.json` the app reads to find out
/// which languages exist.
export async function writePacks(dir, { packs, published }) {
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, 'index.json'), JSON.stringify(published));
  for (const [code, pack] of packs) {
    await writeFile(path.join(dir, `${code}.json`), JSON.stringify(pack));
  }
}
