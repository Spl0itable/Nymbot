// The three translatable surfaces, and where each one's English strings live.
//
// ONE cache serves all three (i18n/cache/<lang>.json is keyed by the English
// string, not by where it was found), so a string the site and the app share is
// paid for once. What is kept apart is the SOURCE SETS: each surface publishes a
// language only when that surface's own strings are covered, so a complete site
// is not held back by an app string, and a half-translated app is never shipped.
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';

import { scriptStrings, sourceStrings } from './extract.mjs';
import { loadSite } from './pages.mjs';

const ROOT = new URL('../', import.meta.url).pathname;

/// Every .dart under [dir], recursively.
async function dartFiles(dir) {
  const out = [];
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch (_) {
    return out;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await dartFiles(full));
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

/// Replaces every comment with spaces, keeping the file's length and so every
/// offset. Without it a doc comment that merely mentions `t()` reads as a call
/// site the scanner cannot resolve, and fails the build.
function blankComments(source) {
  let out = '';
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (c === '/' && source[i + 1] === '/') {
      const end = source.indexOf('\n', i);
      const stop = end === -1 ? source.length : end;
      out += ' '.repeat(stop - i);
      i = stop;
      continue;
    }
    if (c === '/' && source[i + 1] === '*') {
      const end = source.indexOf('*/', i + 2);
      const stop = end === -1 ? source.length : end + 2;
      out += source.slice(i, stop).replace(/[^\n]/g, ' ');
      i = stop;
      continue;
    }
    if (c === "'" || c === '"') {
      // Copied verbatim so a `//` inside a literal is not read as a comment.
      const raw = source[i - 1] === 'r';
      let j = i + 1;
      while (j < source.length) {
        if (!raw && source[j] === '\\') { j += 2; continue; }
        if (source[j] === c || source[j] === '\n') break;
        j++;
      }
      const stop = Math.min(j + 1, source.length);
      out += source.slice(i, stop);
      i = stop;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/// `t('…')` in Dart, including the adjacent-literal concatenation the formatter
/// produces when a string is too long for one line:
///
///     t('a long sentence '
///       'continued here')
///
/// Raw strings (r'…') are skipped: they are patterns, not prose.
export function dartStrings(source) {
  const out = new Set();
  const code = blankComments(source);
  const call = /(?<![\w$.])t\(\s*/g;
  let m;
  while ((m = call.exec(code))) {
    let at = m.index + m[0].length;
    const parts = [];
    for (;;) {
      const quote = code[at];
      if (quote !== "'" && quote !== '"') break;
      let i = at + 1;
      let text = '';
      let closed = false;
      while (i < code.length) {
        const c = code[i];
        if (c === '\\') {
          const next = code[i + 1];
          text += next === 'n' ? '\n' : next === 't' ? '\t' : next;
          i += 2;
          continue;
        }
        if (c === quote) { closed = true; i++; break; }
        // An interpolation makes the string not a fixed source string.
        if (c === '$') { closed = false; break; }
        text += c;
        i++;
      }
      if (!closed) { parts.length = 0; break; }
      parts.push(text);
      at = i;
      // Skip whitespace to see whether another literal follows.
      while (at < code.length && /\s/.test(code[at])) at++;
    }
    // A call the reader cannot resolve throws rather than being skipped: a
    // silently dropped string ships English inside an otherwise translated
    // screen, which is exactly the failure nobody notices.
    if (!parts.length) {
      throw new Error('t() must wrap plain string literals so it can be '
        + `extracted; found: ${code.slice(m.index, m.index + 60).split('\n')[0]}`);
    }
    out.add(parts.join(''));
  }
  return [...out];
}

/// The marketing site: the pages, plus the demo-chat copy script.js writes at
/// runtime. Already what build.mjs gates a language on.
export async function siteSources() {
  const site = await loadSite();
  return { sources: site.sources, label: 'site' };
}

/// The web app: its shell markup, plus every `t('…')` in its modules.
export async function appSources() {
  const html = await readFile(path.join(ROOT, 'app/index.html'), 'utf8');
  const out = new Set(sourceStrings(html));
  const dir = path.join(ROOT, 'app/js');
  for (const name of await readdir(dir)) {
    // i18n.js DEFINES t(); its own signature is not a call site.
    if (!name.endsWith('.js') || name === 'i18n.js') continue;
    const js = await readFile(path.join(dir, name), 'utf8');
    for (const s of scriptStrings(js)) out.add(s);
  }
  return { sources: [...out], label: 'app' };
}

/// The Flutter app: every `t('…')` under lib/, minus the vendored crypto, which
/// has no user-facing prose in it.
export async function flutterSources() {
  const out = new Set();
  const dir = path.join(ROOT, 'flutter/lib');
  for (const file of await dartFiles(dir)) {
    // No prose in the vendored crypto, and i18n.dart DEFINES t().
    if (file.includes('/core/crypto/') || file.endsWith('/i18n/i18n.dart')) continue;
    for (const s of dartStrings(await readFile(file, 'utf8'))) out.add(s);
  }
  return { sources: [...out], label: 'flutter' };
}

/// All three, and the union the translator is asked to fill.
export async function allSurfaces() {
  const surfaces = await Promise.all([siteSources(), appSources(), flutterSources()]);
  const union = new Set();
  for (const surface of surfaces) {
    for (const s of surface.sources) union.add(s);
  }
  return { surfaces, union: [...union] };
}
