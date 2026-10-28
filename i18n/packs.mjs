// Apps fetch these packs at runtime; they share the site's cache, keyed by the English string.
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { LANGUAGES } from './languages.mjs';
import { catalogHash } from './catalog-key.mjs';
import { loadCache } from './translate.mjs';

const byCode = new Map(LANGUAGES.map((l) => [l.code, l]));

export const MIN_COVERAGE = 0.75;

/// A language ships only when the whole surface is covered; half a pack mixes two languages.
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
    if (have < wanted.size * MIN_COVERAGE) {
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
  return { packs, published, partial, catalog: catalogHash(sources) };
}

export async function writePacks(dir, { packs, published, catalog }) {
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, 'index.json'), JSON.stringify(published));
  if (catalog) await writeFile(path.join(dir, 'catalog.json'), JSON.stringify({ hash: catalog }));
  for (const [code, pack] of packs) {
    await writeFile(path.join(dir, `${code}.json`), JSON.stringify(pack));
  }
}
