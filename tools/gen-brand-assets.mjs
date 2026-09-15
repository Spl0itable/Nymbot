// Renders images/brand/ — the downloadable assets the press kit at /brand/
// hands out, and the three guideline panels that page illustrates.
//
//   node tools/gen-brand-assets.mjs [path-to-chrome]
//
// Everything here is drawn from what the site already owns: the ASCII wordmark
// in images/wordmark.txt, the app icon in images/nymbot-icon.png, the social
// card in images/og-banner.png, and the palette out of styles.css. A press kit
// whose assets are hand-cut drifts from the product the first time the artwork
// changes; this is one command instead.
//
// Like test/mobile.mjs, it drives a real browser through playwright-core, which
// a checkout does not have:
//
//   npm i --no-save playwright-core && npx playwright install chromium
//
// Chrome's own --screenshot is not enough here: it captures the window rather
// than the page, so every panel would come back short by the height of the
// browser's own furniture. These are fixed-size assets, so the capture has to
// be exact.
import { mkdtempSync } from 'node:fs';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { chromium } from 'playwright-core';

const executablePath = process.argv[2] || process.env.PLAYWRIGHT_CHROMIUM_PATH || undefined;
const root = new URL('../', import.meta.url).pathname;
const out = path.join(root, 'images/brand');

const art = (await readFile(path.join(root, 'images/wordmark.txt'), 'utf8')).trimEnd();
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const iconUrl = `file://${path.join(root, 'images/nymbot-icon.png')}`;

// The palette, from :root in styles.css and its light-scheme override.
const DARK = { bg: '#050810', ink: '#00ff00', cyan: '#00d4ff', magenta: '#ff00ff' };
const LIGHT = { bg: '#f2f4f7', ink: '#007a00', cyan: '#0077a8', magenta: '#b300b3' };

// DejaVu Sans Mono advances 0.602 em per cell, which is what turns a column
// count into a pixel width. The wordmark is sized to a target art width rather
// than a font size so that changing the art does not silently change how big
// the mark renders.
const COLS = Math.max(...art.split('\n').map((l) => l.length));
const ROWS = art.split('\n').length;
const ADVANCE = 0.602;
const fontFor = (width) => width / (COLS * ADVANCE);

const MONO = "'DejaVu Sans Mono','Liberation Mono','Courier New',monospace";

const scratch = mkdtempSync(path.join(tmpdir(), 'brand-'));
const browser = await chromium.launch(executablePath ? { executablePath } : {});

/// One `<div id="panel">` written out at exactly `w`x`h`.
async function shot(name, w, h, body, css = '') {
  const html = `<!doctype html><meta charset="utf-8"><style>
  html,body{margin:0;padding:0;width:${w}px;height:${h}px;overflow:hidden;font-family:${MONO}}
  #panel{position:relative;width:${w}px;height:${h}px;overflow:hidden}
  pre{margin:0;white-space:pre;line-height:1.05}
  ${css}</style><div id="panel">${body}</div>`;
  const file = path.join(scratch, `${name}.html`);
  await writeFile(file, html);
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
  await page.goto(`file://${file}`, { waitUntil: 'load' });
  await page.locator('#panel').screenshot({ path: path.join(out, `${name}.png`) });
  await page.close();
  console.log(`images/brand/${name}.png (${w}x${h})`);
}

/// The wordmark as the site draws it: monospace, the primary color, and the
/// glow only on dark — on a light background a glow reads as a smudge.
const wordmark = (t, size, glow = true) => `<pre style="font-size:${size}px;color:${t.ink};`
  + `${glow ? `text-shadow:0 0 ${Math.round(size / 2)}px ${t.ink}8c;` : ''}">${esc(art)}</pre>`;

await mkdir(out, { recursive: true });

// ------------------------------------------------------------- the wordmark --

for (const [name, t, glow] of [['nymbot-wordmark-dark', DARK, true],
                               ['nymbot-wordmark-light', LIGHT, false]]) {
  const size = fontFor(1200);
  await shot(name, 1520, 460,
    `<div class="center">${wordmark(t, size, glow)}</div>`,
    `#panel{background:${t.bg}}
     .center{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}`);
}

// The plain text it actually is — the same file the site renders, under the
// name the press kit offers it as.
await copyFile(path.join(root, 'images/wordmark.txt'), path.join(out, 'nymbot-wordmark.txt'));
console.log('images/brand/nymbot-wordmark.txt');

// ----------------------------------------------------------------- the icon --

// Every size is drawn at its own size rather than downscaled from one master,
// and on the same near-black tile the launcher icons use (tools/app-icons.py).
for (const px of [1024, 512, 192]) {
  await shot(`nymbot-icon-${px}`, px, px,
    `<img src="${iconUrl}" width="${px}" height="${px}" alt="">`,
    `#panel{background:#0a0a0f}img{display:block}`);
}

// The social card is already generated by tools/og-banner.mjs; the press kit
// hands it out under a name that says what it is.
await copyFile(path.join(root, 'images/og-banner.png'), path.join(out, 'nymbot-card-1200x630.png'));
console.log('images/brand/nymbot-card-1200x630.png');

// ----------------------------------------------------------- the guidelines --

// Clear space: half the wordmark's height on every side, drawn as the dashed
// boundary the rule describes.
{
  const size = fontFor(880);
  const markH = ROWS * size * 1.05;
  const pad = Math.round(markH / 2);
  await shot('guideline-clear-space', 1520, 680,
    `<div class="frame">
       <div class="inner">${wordmark(DARK, size)}</div>
       <div class="arrow is-v" style="top:0;height:${pad}px"></div>
       <div class="arrow is-v is-bottom" style="bottom:0;height:${pad}px"></div>
       <div class="arrow is-h" style="left:0;width:${pad}px"></div>
       <div class="arrow is-h is-right" style="right:0;width:${pad}px"></div>
       <span class="cap" style="left:50%;top:${pad / 2}px">½ height</span>
       <span class="cap" style="left:50%;bottom:${pad / 2}px">½ height</span>
     </div>`,
    `#panel{background:${DARK.bg};display:flex;align-items:center;justify-content:center}
     .frame{position:relative;padding:${pad}px;border:2px dashed ${DARK.cyan}66;border-radius:10px}
     .inner{border:2px solid ${DARK.cyan}33;border-radius:6px}
     .arrow{position:absolute;background:${DARK.cyan}2e}
     .arrow.is-v{left:${pad}px;right:${pad}px}
     .arrow.is-h{top:${pad}px;bottom:${pad}px}
     .cap{position:absolute;transform:translate(-50%,-50%);font-size:22px;letter-spacing:.08em;
          color:${DARK.cyan};background:${DARK.bg};padding:0 10px}
     .cap[style*="bottom"]{transform:translate(-50%,50%)}`);
}

// Minimum size: the icon at 96, 48 and 24 px, bottom-aligned so the three read
// as one row shrinking, with the one that is too small called out.
{
  const SIZES = [[360, 192, '96 px — fine', DARK.cyan],
                 [724, 96, '48 px — the floor', DARK.cyan],
                 [1132, 48, '24 px — too small', DARK.magenta]];
  const tiles = SIZES.map(([x, px]) =>
    `<img class="tile" src="${iconUrl}" width="${px}" height="${px}" alt=""
          style="left:${x}px;top:${288 - px}px">`).join('');
  const caps = SIZES.map(([x, , text, colour]) =>
    `<span class="cap" style="left:${x}px;color:${colour}">${text}</span>`).join('');
  await shot('guideline-minimum-size', 1520, 440,
    tiles + caps,
    `#panel{background:${DARK.bg}}
     .tile{position:absolute;border-radius:22%;background:#0a0a0f}
     .cap{position:absolute;top:322px;font-size:24px;letter-spacing:.08em;white-space:nowrap}`);
}

// What not to do: the real wordmark, abused three ways and crossed out.
{
  // 250 rather than the box's 410: the stretched one is 1.42x as wide, and a
  // mark clipped by its own frame does not read as a mark being abused.
  const size = fontFor(250);
  const box = (x, label, transform, colour) => `
    <div class="box" style="left:${x}px">
      <pre class="wm" style="font-size:${size}px;color:${colour || DARK.ink};
           text-shadow:0 0 9px ${(colour || DARK.ink)}88;transform:translate(-50%,-50%) ${transform}">${esc(art)}</pre>
      <svg viewBox="0 0 410 258" preserveAspectRatio="none">
        <line x1="0" y1="0" x2="410" y2="258"/><line x1="410" y1="0" x2="0" y2="258"/>
      </svg>
    </div>
    <span class="cap" style="left:${x + 205}px">${label}</span>`;
  await shot('guideline-dont', 1520, 520,
    box(64, 'Stretched', 'scale(1.42,0.78)', null)
    + box(552, 'Rotated', 'rotate(-13deg)', null)
    + box(1040, 'Recolored', '', '#f7931a'),
    `#panel{background:${DARK.bg}}
     .box{position:absolute;top:102px;width:410px;height:258px;overflow:hidden;
          border:3px solid ${DARK.magenta};border-radius:14px}
     .wm{position:absolute;left:50%;top:50%}
     .box svg{position:absolute;inset:0;width:100%;height:100%}
     .box line{stroke:${DARK.magenta};stroke-width:3;vector-effect:non-scaling-stroke}
     .cap{position:absolute;top:396px;transform:translateX(-50%);color:${DARK.magenta};
          font-size:24px;letter-spacing:.09em;white-space:nowrap}`);
}

await browser.close();
