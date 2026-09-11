// The Flutter app's glyph table, cut out of the web app's icons.js.
//
//   npm run icons:export -- --out ../nymbot-flutter/lib/features/nym_glyphs.dart
//
// The two apps drew different pictures for the same thing: the web app has a
// hand-drawn stroke set, the Flutter app was picking the nearest Material icon,
// so settings, memory, git and the rest were recognisably not the same product.
// Rather than redraw them by hand in Dart — which drifts the first time one of
// them is touched — the SVG bodies are copied verbatim and the Flutter side
// renders them, so there is one drawing of each icon and it lives in icons.js.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const DEFAULT_OUT = '../nymbot-flutter/lib/features/nym_glyphs.dart';

function args(argv) {
  const out = { out: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--out' || arg.startsWith('--out=')) {
      out.out = arg.includes('=') ? arg.slice(arg.indexOf('=') + 1) : argv[++i];
      if (!out.out) throw new Error('--out needs a value');
    } else if (arg === '--help' || arg === '-h') {
      out.help = true;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return out;
}

/// One `const NAME = { key: '<svg body>', ... };` table out of icons.js.
///
/// Cut with a brace scan rather than a regex over the whole file: the bodies
/// contain braces and quotes of their own, and a regex that got it wrong would
/// emit a Dart file that compiles and draws the wrong shape.
function table(source, name) {
  const start = source.indexOf(`const ${name} = {`);
  if (start < 0) throw new Error(`gen-flutter-icons: no ${name} table in icons.js`);
  let depth = 0;
  let end = -1;
  for (let i = source.indexOf('{', start); i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}') {
      depth--;
      if (depth === 0) { end = i; break; }
    }
  }
  if (end < 0) throw new Error(`gen-flutter-icons: ${name} table is unterminated`);
  const body = source.slice(source.indexOf('{', start) + 1, end);
  const out = new Map();
  const seen = [];
  const entry = /(\w+)\s*:\s*'((?:[^'\\]|\\.)*)'/g;
  let m;
  while ((m = entry.exec(body)) !== null) {
    if (out.has(m[1])) seen.push(m[1]);
    out.set(m[1], m[2].replace(/\\'/g, "'").replace(/\\\\/g, '\\'));
  }
  if (out.size === 0) throw new Error(`gen-flutter-icons: ${name} table is empty`);
  if (seen.length) {
    throw new Error(`gen-flutter-icons: ${name} defines ${[...new Set(seen)].join(', ')} `
      + 'more than once. The last one silently wins, so editing an earlier copy '
      + 'changes nothing — delete the dead ones.');
  }
  return out;
}

function list(source, name) {
  const m = new RegExp(`const ${name} = \\[([^\\]]*)\\]`).exec(source);
  if (!m) throw new Error(`gen-flutter-icons: no ${name} list in icons.js`);
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
}

const dartString = (s) => `'${s.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\$/g, '\\$')}'`;

const opts = args(process.argv.slice(2));
if (opts.help) {
  console.log('usage: npm run icons:export -- [--out FILE]');
  process.exit(0);
}

const root = new URL('../', import.meta.url).pathname;
const source = await readFile(path.join(root, 'app/js/icons.js'), 'utf8');
const stroke = table(source, 'STROKE');
const filled = table(source, 'FILLED');
const personas = list(source, 'PERSONA_ICONS');

const missing = personas.filter((n) => !stroke.has(n));
if (missing.length) {
  console.error(`Personas with no glyph in STROKE: ${missing.join(', ')}`);
  process.exit(1);
}

/// The shell's one-off drawings: the sidebar rows and toolbar chips whose icon
/// is inline in index.html rather than in icons.js. They are real parts of the
/// icon set — "Saved messages" and "Compare" have a picture like everything
/// else — so they come across too, keyed by the label they sit next to and
/// deduplicated against icons.js so a shared drawing keeps its own name.
function shellGlyphs(html, known) {
  const byBody = new Map([...known.entries()].map(([k, v]) => [v, k]));
  const out = new Map();
  const slug = (label) => label.trim().toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const buttons =
    /<button[^>]*class="(?:side-link|chip)"[^>]*>([\s\S]*?)<\/button>/g;
  let m;
  while ((m = buttons.exec(html)) !== null) {
    const inner = m[1];
    const svg = /<svg[^>]*>([\s\S]*?)<\/svg>/.exec(inner);
    if (!svg) continue;
    const label = /<span(?:\s+class="chip-label")?>([^<]*)<\/span>/.exec(inner);
    if (!label || !label[1].trim()) continue;
    const body = svg[1].trim();
    if (byBody.has(body)) continue;
    const name = slug(label[1]);
    if (!name || out.has(name)) continue;
    out.set(name, body);
  }
  return out;
}

/// What the shell calls each thing, so the Flutter side asks for a concept
/// rather than repeating the lookup. A label already drawn by icons.js maps to
/// that name; anything else maps to the harvested one.
function shellNames(html, known, harvested) {
  const byBody = new Map([...known.entries()].map(([k, v]) => [v, k]));
  const out = new Map();
  const slug = (label) => label.trim().toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const buttons =
    /<button[^>]*class="(?:side-link|chip)"[^>]*>([\s\S]*?)<\/button>/g;
  let m;
  while ((m = buttons.exec(html)) !== null) {
    const inner = m[1];
    const svg = /<svg[^>]*>([\s\S]*?)<\/svg>/.exec(inner);
    const label = /<span(?:\s+class="chip-label")?>([^<]*)<\/span>/.exec(inner);
    if (!svg || !label || !label[1].trim()) continue;
    const body = svg[1].trim();
    const name = byBody.get(body) || (harvested.has(slug(label[1])) ? slug(label[1]) : null);
    if (name) out.set(slug(label[1]), name);
  }
  return out;
}

const entries = (map) => [...map.entries()]
  .map(([k, v]) => `  ${dartString(k)}: ${dartString(v)},`)
  .join('\n');

const html = await readFile(path.join(root, 'app/index.html'), 'utf8');
const shell = shellGlyphs(html, stroke);
const names = shellNames(html, stroke, shell);

const dart = `// GENERATED by tools/gen-flutter-icons.mjs in the Nymbot-staging repo, from
// app/js/icons.js. Do not edit: edit the web app's icon set and re-run
//
//   npm run icons:export -- --out <this file>
//
// These are the SVG bodies the web app draws, verbatim, on a 0 0 24 24 box.
// NymGlyph parses and paints them, so both apps draw one picture of each icon
// rather than two that drift apart.

/// Outline glyphs: painted with a round-capped stroke and no fill.
const Map<String, String> kNymGlyphStroke = <String, String>{
${entries(stroke)}
};

/// The few that also have a solid form, for a selected or active state.
const Map<String, String> kNymGlyphFilled = <String, String>{
${entries(filled)}
};

/// The shell's own drawings — the sidebar rows and toolbar chips whose icon is
/// inline in index.html rather than in icons.js.
const Map<String, String> kNymGlyphShell = <String, String>{
${entries(shell)}
};

/// What the web app draws next to each label, so a screen here asks for the
/// thing rather than repeating the lookup: kNymGlyphFor['settings'].
const Map<String, String> kNymGlyphFor = <String, String>{
${[...names.entries()].map(([k, v]) => `  ${dartString(k)}: ${dartString(v)},`).join('\n')}
};

/// The persona icons, in the order the web app offers them.
const List<String> kNymPersonaGlyphs = <String>[
${personas.map((p) => `  ${dartString(p)},`).join('\n')}
];
`;

const out = path.resolve(opts.out || DEFAULT_OUT);
await mkdir(path.dirname(out), { recursive: true });
await writeFile(out, dart);
console.log(`wrote ${stroke.size} outline + ${filled.size} solid + ${shell.size} shell `
  + `glyphs, ${names.size} named, ${personas.length} personas, to ${out}`);
