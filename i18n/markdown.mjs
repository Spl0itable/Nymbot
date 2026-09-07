// The site's own documents, as markdown.
//
// Agents asking for a page would rather have prose than a stylesheet and a
// navigation tree, so every page is also served as a `.md` twin and the whole
// knowledge base as one `llms-full.txt`. Both are generated from the documents
// themselves at build time, so they cannot drift from what the HTML says.
//
// This is not a general HTML-to-markdown converter and does not try to be. It
// handles the vocabulary these hand-written pages actually use, and throws on
// anything it does not recognise rather than quietly dropping content — a
// silently missing paragraph is exactly the failure nobody notices.

const VOID = new Set(['br', 'img', 'input', 'meta', 'link', 'hr', 'source']);

/// Entities the pages use. Anything else is left as written rather than guessed.
const ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  copy: '©', reg: '®', larr: '←', rarr: '→',
  ndash: '–', mdash: '—', hellip: '…', middot: '·',
  bull: '•', times: '×', check: '✓', vellip: '⋮',
  lsaquo: '‹', rsaquo: '›', ldquo: '“', rdquo: '”',
};

const decode = (text) => text.replace(
  /&(#[Xx][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/g,
  (whole, body) => {
    if (body[0] === '#') {
      const code = body[1] === 'x' || body[1] === 'X'
        ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    }
    return Object.prototype.hasOwnProperty.call(ENTITIES, body) ? ENTITIES[body] : whole;
  });

/// A very small tree builder for well-formed, hand-written markup.
function parse(html) {
  const root = { tag: null, attrs: {}, children: [] };
  const stack = [root];
  const re = /<!--[\s\S]*?-->|<\/([a-zA-Z][\w-]*)\s*>|<([a-zA-Z][\w-]*)((?:\s+[\w:-]+(?:="[^"]*")?)*)\s*(\/?)>|([^<]+)/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    const [chunk, closeTag, openTag, attrText, selfClose, text] = m;
    if (chunk.startsWith('<!--')) continue;
    const top = stack[stack.length - 1];
    if (text !== undefined) {
      top.children.push({ text });
      continue;
    }
    if (closeTag) {
      // Unwind to the matching open tag; stray closers are ignored rather than
      // corrupting the tree.
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i].tag === closeTag.toLowerCase()) { stack.length = i; break; }
      }
      continue;
    }
    const tag = openTag.toLowerCase();
    const attrs = {};
    for (const a of attrText.matchAll(/([\w:-]+)(?:="([^"]*)")?/g)) {
      if (a[1]) attrs[a[1].toLowerCase()] = a[2] ?? '';
    }
    const node = { tag, attrs, children: [] };
    top.children.push(node);
    if (!selfClose && !VOID.has(tag)) stack.push(node);
  }
  return root;
}

const cls = (node) => (node.attrs?.class || '').split(/\s+/);
const has = (node, name) => cls(node).includes(name);

/// Links are authored relative to the site root; an agent reading the markdown
/// somewhere else needs them absolute.
const absolute = (href, site) => (href.startsWith('/') ? site + href : href);

/// Inline markdown for a node's children.
function inline(node, ctx) {
  let out = '';
  for (const child of node.children) {
    if (child.text !== undefined) {
      // Collapse authored line wrapping; markdown re-wraps anyway.
      out += decode(child.text).replace(/\s+/g, ' ');
      continue;
    }
    switch (child.tag) {
      case 'strong': case 'b': out += `**${inline(child, ctx).trim()}**`; break;
      case 'em': case 'i': out += `*${inline(child, ctx).trim()}*`; break;
      case 'del': case 's': out += `~~${inline(child, ctx).trim()}~~`; break;
      case 'code': out += `\`${inline(child, ctx).trim()}\``; break;
      case 'br': out += '\n'; break;
      case 'a': {
        const text = inline(child, ctx).trim();
        const href = child.attrs.href || '';
        out += href ? `[${text}](${absolute(href, ctx.site)})` : text;
        break;
      }
      case 'span': case 'abbr': case 'small': case 'sup': case 'sub':
        out += inline(child, ctx);
        break;
      case 'img': {
        const alt = decode(child.attrs.alt || '');
        out += `![${alt}](${absolute(child.attrs.src || '', ctx.site)})`;
        break;
      }
      // Decorative inline SVG (the badge glyphs in the post-quantum table).
      // It carries no text and is aria-hidden, so the adjacent label is
      // already the whole meaning — emitting anything here would put raw path
      // data into the plain-text rendering.
      case 'svg':
        break;
      default:
        throw new Error(`markdown: unhandled inline <${child.tag}>`);
    }
  }
  return out;
}

const tidy = (s) => s.replace(/[ \t]+/g, ' ').replace(/ ?\n ?/g, '\n').trim();

/// Block markdown for a node's children.
function blocks(node, ctx, depth = 0) {
  const out = [];
  for (const child of node.children) {
    if (child.text !== undefined) {
      if (child.text.trim()) out.push(tidy(decode(child.text)));
      continue;
    }
    switch (child.tag) {
      case 'h1': out.push(`# ${tidy(inline(child, ctx))}`); break;
      case 'h2': out.push(`## ${tidy(inline(child, ctx))}`); break;
      case 'h3': out.push(`### ${tidy(inline(child, ctx))}`); break;
      case 'h4': out.push(`#### ${tidy(inline(child, ctx))}`); break;

      case 'p': {
        // The note that a page is machine-translated belongs only to a
        // translated render; the markdown is the English original.
        if ('data-i18n-translated-only' in child.attrs) break;
        const text = tidy(inline(child, ctx));
        if (text) out.push(text);
        break;
      }

      case 'ul': case 'ol': {
        // The card grids are navigation: a list of links reads better than a
        // list of two-line blurbs.
        const ordered = child.tag === 'ol';
        const items = child.children.filter((c) => c.tag === 'li').map((li, i) => {
          const marker = ordered ? `${i + 1}. ` : '- ';
          const body = listItem(li, ctx, depth);
          const pad = ' '.repeat(marker.length);
          return marker + body.split('\n').map((l, n) => (n === 0 ? l : pad + l)).join('\n');
        });
        if (items.length) out.push(items.join('\n'));
        break;
      }

      case 'pre': {
        const code = child.children.find((c) => c.tag === 'code') || child;
        out.push('```\n' + decode(textOf(code)).replace(/\n+$/, '') + '\n```');
        break;
      }

      case 'blockquote':
        out.push(blocks(child, ctx, depth).join('\n\n').split('\n').map((l) => `> ${l}`.trimEnd()).join('\n'));
        break;

      case 'figure': {
        const img = find(child, 'img');
        const video = find(child, 'video');
        const caption = find(child, 'figcaption');
        const parts = [];
        if (img) parts.push(`![${decode(img.attrs.alt || '')}](${absolute(img.attrs.src || '', ctx.site)})`);
        // Markdown has no video element. Link it, so a reader of the .md twin
        // gets the film rather than a caption with nothing above it.
        if (video) {
          const src = find(video, 'source');
          const url = absolute((src && src.attrs.src) || video.attrs.src || '', ctx.site);
          const label = caption ? tidy(inline(caption, ctx)) : 'Video';
          parts.push(`[▶ ${label}](${url})`);
        }
        if (caption && !video) parts.push(`*${tidy(inline(caption, ctx))}*`);
        if (parts.length) out.push(parts.join('\n\n'));
        break;
      }

      case 'table': out.push(table(child, ctx)); break;

      case 'div': case 'section': case 'main': case 'article': case 'aside': {
        // A callout: its label is a heading-ish line, the rest is the body.
        if (has(child, 'docs-note')) {
          const label = child.children.find((c) => has(c, 'docs-note-label'));
          const rest = { ...child, children: child.children.filter((c) => c !== label) };
          const body = blocks(rest, ctx, depth).join('\n\n');
          const name = label ? tidy(inline(label, ctx)) : 'Note';
          out.push(`> **${name}**\n>\n` + body.split('\n').map((l) => `> ${l}`.trimEnd()).join('\n'));
          break;
        }
        out.push(...blocks(child, ctx, depth));
        break;
      }

      case 'nav': case 'header': case 'footer': case 'script': case 'style':
        break;

      case 'a': case 'span': case 'strong': case 'em': case 'code': case 'img': case 'br': {
        const text = tidy(inline({ children: [child] }, ctx));
        if (text) out.push(text);
        break;
      }

      case 'hr': out.push('---'); break;

      default:
        throw new Error(`markdown: unhandled block <${child.tag}>`);
    }
  }
  return out.filter(Boolean);
}

/// A list item is inline unless it carries real blocks (a nested list, a card).
function listItem(li, ctx, depth) {
  const hasBlocks = li.children.some((c) =>
    ['ul', 'ol', 'p', 'pre', 'table', 'figure', 'blockquote'].includes(c.tag));
  if (!hasBlocks) {
    const card = li.children.find((c) => c.tag === 'a' && has(c, 'docs-card'));
    if (card) {
      const title = card.children.find((c) => has(c, 'docs-card-title'));
      const desc = card.children.find((c) => has(c, 'docs-card-desc'));
      const label = title ? tidy(inline(title, ctx)) : tidy(inline(card, ctx));
      const href = absolute(card.attrs.href || '', ctx.site);
      return `[${label}](${href})` + (desc ? `: ${tidy(inline(desc, ctx))}` : '');
    }
    return tidy(inline(li, ctx));
  }
  return blocks(li, ctx, depth + 1).join('\n\n');
}

function table(node, ctx) {
  const rows = [];
  const walk = (n) => {
    for (const c of n.children) {
      if (!c.tag) continue;
      if (c.tag === 'tr') {
        rows.push(c.children.filter((x) => x.tag === 'th' || x.tag === 'td')
          .map((cell) => tidy(inline(cell, ctx)).replace(/\|/g, '\\|').replace(/\n/g, ' ')));
      } else walk(c);
    }
  };
  walk(node);
  if (rows.length === 0) return '';
  const width = Math.max(...rows.map((r) => r.length));
  const pad = (r) => [...r, ...Array(width - r.length).fill('')];
  const [head, ...body] = rows;
  return [
    `| ${pad(head).join(' | ')} |`,
    `| ${Array(width).fill('---').join(' | ')} |`,
    ...body.map((r) => `| ${pad(r).join(' | ')} |`),
  ].join('\n');
}

const textOf = (node) => node.children
  .map((c) => (c.text !== undefined ? c.text : textOf(c))).join('');

function find(node, tag) {
  for (const c of node.children) {
    if (c.tag === tag) return c;
    if (c.children) {
      const hit = find(c, tag);
      if (hit) return hit;
    }
  }
  return null;
}

/// The article out of a source document — everything inside `<main>`, which is
/// the page minus the chrome the build fills in around it.
export function articleMarkdown(html, { site }) {
  const start = html.indexOf('<main');
  const end = html.lastIndexOf('</main>');
  if (start === -1 || end === -1) throw new Error('markdown: document has no <main>');
  const tree = parse(html.slice(html.indexOf('>', start) + 1, end));
  return blocks(tree, { site }).join('\n\n').replace(/\n{3,}/g, '\n\n').trim() + '\n';
}
