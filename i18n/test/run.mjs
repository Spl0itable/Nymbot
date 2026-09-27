// Runs every *.test.mjs beside this file.
import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const here = fileURLToPath(new URL('.', import.meta.url));
const files = readdirSync(here).filter((f) => f.endsWith('.test.mjs')).sort();
let failed = 0;

for (const name of files) {
  const res = spawnSync(process.execPath, [join(here, name)], { encoding: 'utf8' });
  const passed = res.status === 0;
  if (!passed) failed++;
  console.log(`${passed ? 'PASS' : 'FAIL'}  ${name}`);
  if (!passed) console.log((res.stdout || '') + (res.stderr || ''));
}

console.log(`\n${files.length - failed}/${files.length} test files passed`);
process.exit(failed ? 1 : 0);
