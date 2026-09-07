// Drops cache entries for strings this site no longer contains. The cache was
// inherited from the Nymchat site, where most of these came from; keeping them
// would carry ~80 MB of translations for copy that is not here.
import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

import { loadSite } from '../i18n/pages.mjs';

const dir = new URL('../i18n/cache/', import.meta.url).pathname;
const { sources } = await loadSite();
const keep = new Set(sources);

let before = 0;
let after = 0;
for (const name of (await readdir(dir)).filter((f) => f.endsWith('.json'))) {
  const file = path.join(dir, name);
  const cache = JSON.parse(await readFile(file, 'utf8'));
  const kept = {};
  for (const [source, translated] of Object.entries(cache)) {
    before++;
    if (keep.has(source)) { kept[source] = translated; after++; }
  }
  await writeFile(file, JSON.stringify(kept, null, 2) + '\n');
}
console.log(`kept ${after} of ${before} cached translations across ${keep.size} source strings`);
