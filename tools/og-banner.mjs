// Renders images/og-banner.png (1200x630) from the site's own palette and
// wordmark, so the social card is generated rather than hand-maintained.
//
//   node tools/og-banner.mjs [path-to-chrome]
//
// Uses headless Chrome rather than a rendering dependency: this runs when the
// artwork changes, not on every build.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const chrome = process.argv[2] || process.env.CHROME || 'chromium';
const root = new URL('../', import.meta.url).pathname;
const art = (await readFile(path.join(root, 'images/wordmark.txt'), 'utf8')).trimEnd();
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const html = `<!doctype html><meta charset="utf-8"><style>
  html,body{margin:0;width:1200px;height:630px;background:#050810;overflow:hidden}
  body{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:34px;
       font-family:'DejaVu Sans Mono','Liberation Mono','Courier New',monospace}
  .glow{position:absolute;inset:0;background:
    radial-gradient(900px 420px at 50% 40%, rgba(0,255,0,.13), transparent 70%),
    radial-gradient(700px 380px at 80% 90%, rgba(0,212,255,.10), transparent 70%)}
  pre{position:relative;margin:0;font-size:19px;line-height:1.02;color:#00ff00;
      text-shadow:0 0 18px rgba(0,255,0,.55);white-space:pre}
  .tag{position:relative;color:#00d4ff;font-size:31px;letter-spacing:.16em;text-transform:uppercase}
  .sub{position:relative;color:rgba(255,255,255,.5);font-size:19px;letter-spacing:.05em}
</style><div class="glow"></div><pre>${esc(art)}</pre>
<div class="tag">Private. Paid in sats. Yours alone.</div>
<div class="sub">nymbot.ai</div>`;

const scratch = mkdtempSync(path.join(tmpdir(), 'og-'));
const page = path.join(scratch, 'og.html');
writeFileSync(page, html);

execFileSync(chrome, [
  '--headless', '--disable-gpu', '--no-sandbox', '--hide-scrollbars',
  '--force-device-scale-factor=1', '--window-size=1200,630',
  `--screenshot=${path.join(root, 'images/og-banner.png')}`,
  `file://${page}`,
], { stdio: 'inherit' });

console.log('images/og-banner.png written');
