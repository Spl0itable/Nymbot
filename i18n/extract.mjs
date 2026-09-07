// Pulls the translatable strings out of index.html and rewrites the document so
// each one can be swapped per language, and reads the `t()`-marked copy that
// script.js writes into the page at runtime.
//
// Document copy is not hand-annotated: the page is the source of truth, so
// adding copy to index.html automatically makes it translatable. A regex walk
// is enough here because this is one hand-written document, not arbitrary HTML.
// Runtime copy has no markup to walk, so it carries the `t()` marker instead —
// see the script section at the bottom of this file.

/// Elements whose contents are never prose.
const SKIP_ELEMENTS = new Set(['script', 'style', 'svg', 'pre', 'code']);

/// Marks an element whose subtree must never be translated (the ASCII logo).
const SKIP_ATTRIBUTE = 'data-i18n-skip';

/// Brand names a translator would mangle or transliterate.
const PROTECTED = new Set([
  'Nymbot', 'Nymchat', 'Nostr', 'Zapstore',
  // Store names are brands, not prose — Apple and Google keep them in English.
  'App Store', 'Google Play', 'TestFlight',
  // The legal entity behind the site. A translated company name names nobody.
  '21 Million LLC',
]);

/// Attributes carrying user-visible text.
const TEXT_ATTRIBUTES = ['alt', 'title', 'placeholder', 'aria-label'];

/// <meta> names/properties whose content is prose.
const META_CONTENT = new Set([
  'description', 'og:title', 'og:description',
  'twitter:title', 'twitter:description', 'apple-mobile-web-app-title',
  // What a social card's image shows is prose, and a reader who cannot see the
  // card is the one being described to.
  'og:image:alt', 'twitter:image:alt',
]);

/// The named entities a hand-written page actually uses. Anything outside this
/// set is left encoded rather than guessed at.
const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0',
  copy: '\u00a9', reg: '\u00ae', larr: '\u2190', rarr: '\u2192',
  ndash: '\u2013', mdash: '\u2014', hellip: '\u2026',
};

/// Extracted text is what a reader sees, not what the author typed. A
/// translator has to be handed `DMCA & Content Policy`; hand it the raw
/// `DMCA &amp; Content Policy` and the entity comes back verbatim, gets
/// escaped a second time on the way out, and the page renders `&amp;`.
function decodeEntities(text) {
  return text.replace(/&(#[Xx][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/g, (whole, body) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' || body[1] === 'X'
        ? parseInt(body.slice(2), 16)
        : parseInt(body.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    }
    return Object.prototype.hasOwnProperty.call(ENTITIES, body) ? ENTITIES[body] : whole;
  });
}

/// Text that is a value, not prose: numbers, symbols, single glyphs, URLs.
function isTranslatable(text) {
  const t = text.trim();
  if (t.length < 2) return false;
  if (!/\p{L}/u.test(t)) return false;
  if (/^[\d\s.,:%+\-–—/]+$/.test(t)) return false;
  if (/^https?:\/\//i.test(t)) return false;
  if (/^[@#][\w-]+$/.test(t)) return false;
  // An address, not prose. A translator that "helpfully" transliterates
  // support@nymbot.ai hands 133 pages a contact address nobody can write to.
  if (/^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i.test(t)) return false;
  if (/^[\w-]+(\.[\w-]+)+$/.test(t)) return false;
  if (PROTECTED.has(t)) return false;
  return true;
}

/// Splits a chunk of markup into text runs and the tags between them, so text
/// can be replaced without disturbing the tags.
function* walkText(html) {
  // `<!...>` covers comments and the doctype; without it the regex falls
  // through to the text branch and treats `!DOCTYPE html>` as prose.
  const tagOrText = /<!--[\s\S]*?-->|<![^>]*>|<\/?([a-zA-Z][\w-]*)\b[^>]*>|[^<]+/g;
  const skipStack = [];
  let m;
  while ((m = tagOrText.exec(html)) !== null) {
    const chunk = m[0];
    const start = m.index;
    if (chunk.startsWith('<!')) continue; // comments and <!DOCTYPE>
    if (chunk.startsWith('<')) {
      const tag = (m[1] || '').toLowerCase();
      const closing = chunk.startsWith('</');
      const selfClosing = chunk.endsWith('/>') || /^(br|img|input|meta|link|hr|source|path|circle|line|rect|polygon|use)$/.test(tag);
      const opaque = SKIP_ELEMENTS.has(tag) || (!closing && chunk.includes(SKIP_ATTRIBUTE));
      if (opaque && !selfClosing) {
        if (closing) {
          if (skipStack[skipStack.length - 1] === tag) skipStack.pop();
        } else {
          skipStack.push(tag);
        }
      } else if (closing && skipStack[skipStack.length - 1] === tag) {
        skipStack.pop();
      }
      continue;
    }
    if (skipStack.length > 0) continue;
    yield { text: chunk, start, end: start + chunk.length };
  }
}

/// One replaceable slot in the document.
/// `{ start, end, value }` — `value` is the English source to translate.
export function extractHtml(html) {
  const slots = [];

  for (const run of walkText(html)) {
    // Preserve the surrounding whitespace; only the trimmed core is prose.
    const lead = run.text.length - run.text.trimStart().length;
    const trail = run.text.length - run.text.trimEnd().length;
    const core = decodeEntities(run.text.slice(lead, run.text.length - trail));
    if (!isTranslatable(core)) continue;
    slots.push({ start: run.start + lead, end: run.end - trail, value: core, kind: 'text' });
  }

  // Attributes carrying prose. Scanned tag by tag rather than across the whole
  // document, so an element marked untranslatable keeps its attributes too: a
  // `placeholder="owner/repo"` is a format hint, and a translator handed it
  // returns something the field will not accept.
  const attrRe = new RegExp(`\\s(${TEXT_ATTRIBUTES.join('|')})="([^"]*)"`, 'g');
  const tagRe = /<[a-zA-Z][^>]*>/g;
  let m;
  let tag;
  while ((tag = tagRe.exec(html)) !== null) {
    if (tag[0].includes(SKIP_ATTRIBUTE)) continue;
    attrRe.lastIndex = 0;
    while ((m = attrRe.exec(tag[0])) !== null) {
      const value = decodeEntities(m[2]);
      if (!isTranslatable(value)) continue;
      const valueStart = tag.index + m.index + m[0].indexOf('="') + 2;
      slots.push({ start: valueStart, end: valueStart + m[2].length, value, kind: 'attr' });
    }
  }

  // <title> is inside no skipped element but is matched as its own tag pair.
  const titleRe = /<title>([^<]+)<\/title>/i;
  const titleMatch = titleRe.exec(html);
  if (titleMatch && isTranslatable(decodeEntities(titleMatch[1]))) {
    const valueStart = titleMatch.index + '<title>'.length;
    slots.push({
      start: valueStart,
      end: valueStart + titleMatch[1].length,
      value: decodeEntities(titleMatch[1]),
      kind: 'text',
    });
  }

  // <meta ... content="prose">
  const metaRe = /<meta\b[^>]*>/gi;
  while ((m = metaRe.exec(html)) !== null) {
    const tag = m[0];
    const key = (/(?:name|property)="([^"]+)"/i.exec(tag) || [])[1];
    if (!key || !META_CONTENT.has(key.toLowerCase())) continue;
    const content = /content="([^"]*)"/i.exec(tag);
    if (!content || !isTranslatable(decodeEntities(content[1]))) continue;
    const valueStart = m.index + tag.indexOf(content[0]) + content[0].indexOf('="') + 2;
    slots.push({
      start: valueStart,
      end: valueStart + content[1].length,
      value: decodeEntities(content[1]),
      kind: 'attr',
    });
  }

  // Later passes can overlap earlier ones (a <title> run is also a text run).
  // Keep the first slot at each offset and drop anything nested inside it.
  slots.sort((a, b) => a.start - b.start || b.end - a.end);
  const merged = [];
  let lastEnd = -1;
  for (const slot of slots) {
    if (slot.start < lastEnd) continue;
    merged.push(slot);
    lastEnd = slot.end;
  }
  return merged;
}

/// The distinct English strings a document needs translated.
export function sourceStrings(html) {
  return [...new Set(extractHtml(html).map((s) => s.value))];
}

/// Translated text is third-party data going into HTML, so it is escaped for
/// the slot it lands in. An attribute value additionally cannot carry a quote —
/// without this a translation containing `"` would break out of the attribute.
function escapeFor(kind, text) {
  const base = String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return kind === 'attr' ? base.replace(/"/g, '&quot;') : base;
}

/// Rebuilds `html` with each slot replaced by `lookup(value)`. A slot the
/// lookup does not change keeps its ORIGINAL bytes, so entities the author
/// wrote (`&copy;`) survive and an identity pass is a no-op.
export function applyTranslations(html, lookup) {
  const slots = extractHtml(html);
  let out = '';
  let cursor = 0;
  for (const slot of slots) {
    out += html.slice(cursor, slot.start);
    const replacement = lookup(slot.value);
    out += (replacement === undefined || replacement === null || replacement === slot.value)
      ? html.slice(slot.start, slot.end)
      : escapeFor(slot.kind, replacement);
    cursor = slot.end;
  }
  return out + html.slice(cursor);
}

// --- script copy -----------------------------------------------------------
//
// The animated phone mockup writes its chat bubbles at runtime, so that copy
// never appears in index.html for the walk above to find. Those strings are
// marked at the call site with `t('…')` in script.js — the extractor reads the
// same marker the runtime does, so the two can never drift apart.

/// A `t(` that starts a call, not a declaration and not the tail of a longer
/// identifier (`setTimeout(`, `split(`).
const T_PREFIX = String.raw`(?<!function\s)(?<![\w$.])t\(`;

/// `t('…')`, `t("…")` or `t(\`…\`)` — a plain literal, optionally followed by
/// more arguments.
const T_CALL = new RegExp(
  T_PREFIX +
  String.raw`\s*(?:'((?:[^'\\]|\\[\s\S])*)'|"((?:[^"\\]|\\[\s\S])*)"|` +
  '`((?:[^`\\\\$]|\\\\[\\s\\S])*)`' +
  String.raw`)\s*[,)]`,
  'g');

/// Every call site, matched or not, so an unsupported form fails the build.
const T_ANY = new RegExp(T_PREFIX, 'g');

const SHORT_ESCAPES = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', v: '\v', '0': '\0' };

/// Turns the bytes between the quotes back into the string the runtime sees.
function decodeJsString(body) {
  return body.replace(
    /\\(?:u\{([0-9a-fA-F]+)\}|u([0-9a-fA-F]{4})|x([0-9a-fA-F]{2})|([\s\S]))/g,
    (_m, codePoint, u4, x2, ch) => {
      if (codePoint !== undefined) return String.fromCodePoint(parseInt(codePoint, 16));
      if (u4 !== undefined) return String.fromCharCode(parseInt(u4, 16));
      if (x2 !== undefined) return String.fromCharCode(parseInt(x2, 16));
      if (ch === '\n') return ''; // line continuation
      return Object.prototype.hasOwnProperty.call(SHORT_ESCAPES, ch) ? SHORT_ESCAPES[ch] : ch;
    });
}

/// The distinct English strings marked with `t()` in [js].
///
/// A call the pattern cannot read throws rather than being skipped: a silently
/// dropped string ships English text inside an otherwise translated page,
/// which is exactly the failure nobody notices.
export function scriptStrings(js) {
  const byOffset = new Map();
  let m;
  T_CALL.lastIndex = 0;
  while ((m = T_CALL.exec(js)) !== null) {
    byOffset.set(m.index, decodeJsString(m[1] ?? m[2] ?? m[3]));
  }
  T_ANY.lastIndex = 0;
  while ((m = T_ANY.exec(js)) !== null) {
    if (byOffset.has(m.index)) continue;
    const context = js.slice(m.index, m.index + 60).split('\n')[0];
    throw new Error(
      `t() must wrap a plain string literal so it can be extracted; found: ${context}`);
  }
  return [...new Set(byOffset.values())];
}
