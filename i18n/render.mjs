// Turns an English source document into the finished page for one language.
//
// The landing page lives at the site root; every document in pages/ gets a slug
// directory of its own, in English (/tos/) and per language (/es/tos/).

import { LANGUAGES, TRANSLATED_LANGUAGES, displayName, isRtl, pathFor } from './languages.mjs';
import { applyTranslations } from './extract.mjs';
import {
  isDocsPage, renderCrumbs, renderNav, renderPager, renderToc, renderTopbar,
} from './docs.mjs';

export const SITE = 'https://nymbot.ai';

const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/// hreflang alternates for every language that has a page, plus x-default.
/// This is the signal search engines actually use to serve the right
/// translation; the client-side redirect below is only a convenience.
function hreflangBlock(available, slug) {
  const rows = [`    <link rel="alternate" hreflang="x-default" href="${SITE}${pathFor('en', slug)}">`];
  for (const lang of LANGUAGES) {
    if (lang.code !== 'en' && !available.has(lang.code)) continue;
    rows.push(`    <link rel="alternate" hreflang="${lang.code}" href="${SITE}${pathFor(lang.code, slug)}">`);
  }
  return rows.join('\n');
}

/// The markdown representation of this page, so an agent that lands on the
/// HTML does not have to guess that one exists. robots.txt names /llms.txt,
/// but nothing reads robots.txt on the way to a page it already has.
///
/// English only, because the markdown is: an English page's twin is the same
/// document (/docs/mesh/ is also /docs/mesh.md), while a translated page has
/// no twin at all, and pointing one at the English markdown would advertise a
/// translation that is not there. Those pages carry their hreflang set
/// instead, which is the honest route to the English original. The landing
/// page has no twin either — it is chrome rather than prose — so it points at
/// the site index, which is the markdown that describes it.
function markdownAlternate(lang, slug) {
  if (lang !== 'en') return '';
  const link = slug
    ? `<link rel="alternate" type="text/markdown" href="${SITE}/${slug}.md" title="This page as markdown">`
    : `<link rel="alternate" type="text/plain" href="${SITE}/llms.txt" title="Nymbot for AI agents (llms.txt)">`;
  return `\n    ${link}`;
}

/// Switching language keeps the reader on the page they are reading, so the
/// selector links this page's slug rather than the site root.
function languageSelector(current, available, label, slug) {
  const options = LANGUAGES
    .filter((l) => l.code === 'en' || available.has(l.code))
    .map((l) => {
      const selected = l.code === current ? ' aria-current="true"' : '';
      // Canonical hrefs so crawlers see the same URLs as hreflang; data-lang
      // lets the runtime record the pick before navigating.
      // The endonym is what a speaker looks for; the English name rides along
      // as the tooltip so it stays findable from any locale.
      return `                <li><a href="${pathFor(l.code, slug)}" data-lang="${l.code}" hreflang="${l.code}" lang="${l.code}" title="${escapeHtml(l.name)}"${selected}>${escapeHtml(displayName(l))}</a></li>`;
    })
    .join('\n');
  const currentName = displayName(LANGUAGES.find((l) => l.code === current) || { name: 'English' });
  return `        <nav class="lang-picker" aria-label="${escapeHtml(label)}">
            <details>
                <summary><span class="lang-picker-globe" aria-hidden="true">&#127760;</span>${escapeHtml(currentName)}</summary>
                <ul class="lang-picker-list">
${options}
                </ul>
            </details>
        </nav>`;
}

/// The data `boot.js` needs, inlined as JSON.
///
/// It is a `type="application/json"` block rather than a `<script>` that runs,
/// so the whole site can be served under `script-src 'self'` with no
/// `unsafe-inline` — a page cannot carry a per-language inline script and a
/// strict policy at the same time, and there are far too many combinations of
/// page and language to enumerate as hashes in `_headers`.
///
/// [strings] is the copy script.js writes into the page at runtime; [slug] and
/// the published language list are what boot.js needs to keep a first-time
/// visitor on the right language without losing the page they asked for.
function runtimeData(lang, available, strings, slug) {
  const codes = ['en', ...LANGUAGES.filter((l) => available.has(l.code)).map((l) => l.code)];
  return `    <script type="application/json" id="nym-i18n" data-lang="${lang}"`
    + ` data-page="${slug ?? ''}" data-langs="${codes.join(',')}">`
    + `${JSON.stringify(strings)}</script>`;
}

/// Structured data for the page, as JSON-LD.
///
/// Built from the ALREADY-TRANSLATED document rather than from a separate table
/// of strings: the title and description a crawler is shown are then, by
/// construction, the ones on the page, in the language of the page. A
/// `type="application/json"` block executes nothing, so it costs the strict
/// script policy nothing either.
/// The landing page's FAQ, as {question, answer} pairs lifted from the markup.
///
/// Read from the SAME rendered HTML the reader gets, so the structured data is
/// the visible answer in the visible language. Google refuses FAQPage markup
/// that says anything the page does not, and a separate copy of these strings
/// is exactly how that happens.
function faqPairs(html) {
  const items = [];
  // Each item is one question line followed by one answer block. The answer
  // holds only paragraphs, so it ends at the first `</div>` that starts a line
  // — which is what keeps this out of the business of matching nested tags.
  const block = /<div class="faq-question-text">([\s\S]*?)<\/div>[\s\S]*?<div class="faq-answer">([\s\S]*?)\n\s*<\/div>/g;
  let m;
  while ((m = block.exec(html))) items.push({ question: m[1], answer: m[2] });
  return items;
}

/// Markup out, entities in: JSON-LD carries text, not HTML.
function plainText(html) {
  return html
    .replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function structuredData(html, lang, slug) {
  const title = (/<title>([^<]*)<\/title>/i.exec(html) || [])[1] || '';
  const description = (/<meta name="description" content="([^"]*)">/i.exec(html) || [])[1] || '';
  const decode = (v) => v
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>').replace(/&amp;/g, '&');
  const url = `${SITE}${pathFor(lang, slug)}`;

  const publisher = {
    '@type': 'Organization',
    name: '21 Million LLC',
    url: 'https://nostrservices.com',
  };

  const graph = [];
  if (slug === null) {
    // The landing page describes the product; every other page describes itself.
    graph.push({
      '@type': 'SoftwareApplication',
      name: 'Nymbot',
      alternateName: 'Nymbot anonymous AI chat',
      applicationCategory: 'CommunicationApplication',
      applicationSubCategory: 'AI assistant',
      operatingSystem: 'Web, Android, iOS',
      url,
      installUrl: `${SITE}/app`,
      description: decode(description),
      inLanguage: lang,
      license: 'https://www.gnu.org/licenses/agpl-3.0.html',
      isAccessibleForFree: false,
      offers: {
        '@type': 'Offer',
        price: '0.0000001',
        priceCurrency: 'BTC',
        description: 'Replies are paid for in credits bought over the Bitcoin Lightning Network. No subscription.',
      },
      featureList: [
        'Anonymous AI chat from a throwaway key the service cannot link to you',
        'End-to-end encrypted messages, hybridized post-quantum with ML-KEM',
        'No account, no email, no password — a keypair on your device',
        'Pay per reply in Bitcoin over the Lightning Network',
        'Claude, GPT, Gemini, Grok, Kimi, Qwen and MiniMax models',
        'Reads and edits a connected GitHub, GitLab or Gitea repository',
        'Generates images and speech',
        'Many separate conversations, titled on the device',
      ],
      publisher,
    });
    graph.push({
      '@type': 'WebSite',
      name: 'Nymbot',
      url: `${SITE}${pathFor(lang)}`,
      inLanguage: lang,
      publisher,
    });
    // Only the landing page carries the FAQ, and only when it actually has one.
    const faq = faqPairs(html);
    if (faq.length) {
      graph.push({
        '@type': 'FAQPage',
        inLanguage: lang,
        mainEntity: faq.map((item) => ({
          '@type': 'Question',
          name: plainText(item.question),
          acceptedAnswer: { '@type': 'Answer', text: plainText(item.answer) },
        })),
      });
    }
  } else {
    const isDocs = isDocsPage(slug);
    // A page carrying a publication date is a dated announcement — the press
    // release — and an aggregator that files one as an undated WebPage files it
    // as nothing. The date is read from the document rather than listed here,
    // so a second announcement needs no change to this file.
    const published = (/<meta property="article:published_time" content="([^"]*)">/i.exec(html) || [])[1];
    // The page's own <h1>, which both the headline and the breadcrumb leaf
    // want: a release's headline IS the news, and the <title> carries a site
    // suffix that is part of neither.
    const h1 = (/<h1[^>]*>([\s\S]*?)<\/h1>/i.exec(html) || [])[1];
    const headline = h1 ? decode(h1.replace(/<[^>]*>/g, '').trim()) : decode(title);
    graph.push({
      '@type': published ? 'NewsArticle' : (isDocs ? 'TechArticle' : 'WebPage'),
      headline: published ? headline : decode(title),
      name: decode(title),
      description: decode(description),
      url,
      inLanguage: lang,
      ...(published ? {
        datePublished: published,
        dateModified: published,
        author: publisher,
        image: (/<meta property="og:image" content="([^"]*)">/i.exec(html) || [])[1],
      } : {}),
      isPartOf: { '@type': 'WebSite', name: 'Nymbot', url: `${SITE}${pathFor(lang)}` },
      publisher,
    });
    // A crawler cannot see the breadcrumb the reader sees, so it is stated.
    const leaf = headline;
    const trail = [{ name: 'Nymbot', item: `${SITE}${pathFor(lang)}` }];
    if (isDocs && slug !== 'docs') trail.push({ name: 'Knowledge base', item: `${SITE}${pathFor(lang, 'docs')}` });
    trail.push({ name: leaf, item: url });
    graph.push({
      '@type': 'BreadcrumbList',
      itemListElement: trail.map((entry, i) => ({
        '@type': 'ListItem', position: i + 1, name: entry.name, item: entry.item,
      })),
    });
  }

  const json = JSON.stringify({ '@context': 'https://schema.org', '@graph': graph })
    // A closing tag inside JSON would end the script element early.
    .replace(/</g, '\\u003c');
  return `    <script type="application/ld+json">${json}</script>\n`;
}

/// Internal links are authored for English — `/` for the landing page, `/tos/`
/// for a named one. On a translated page they have to point at that language's
/// copy, or one click drops the reader back into English mid-site. Only the
/// site's own page paths are rewritten; assets and outbound links are left
/// exactly as written.
/// A fragment or query is part of the destination, not part of the path: the
/// knowledge base links to a specific heading on another page all the time, and
/// `/docs/mesh/#ghost-mode` has to become `/es/docs/mesh/#ghost-mode` rather
/// than falling through and dropping the reader back into English.
function localizeLinks(html, lang, slugs) {
  if (lang === 'en') return html;
  const paths = new Map([['/', pathFor(lang)]]);
  for (const slug of slugs) paths.set(`/${slug}/`, pathFor(lang, slug));
  return html.replace(/href="([^"]*)"/g, (whole, href) => {
    const cut = href.search(/[#?]/);
    const base = cut === -1 ? href : href.slice(0, cut);
    const rest = cut === -1 ? '' : href.slice(cut);
    return paths.has(base) ? `href="${paths.get(base)}${rest}"` : whole;
  });
}

/// Copy that belongs only on a translated page — the note saying the English
/// original is the one that governs. It lives in the source document so it is
/// extracted and translated like any other sentence, and is dropped from the
/// English render.
const TRANSLATED_ONLY = /[^\S\n]*<p\b[^>]*\bdata-i18n-translated-only\b[^>]*>[\s\S]*?<\/p>\n/g;

/// The finished HTML for [lang]. [strings] is that language's cache
/// (English → translation); English passes through untouched.
///
/// Options:
///   `slug`    the page's directory, or null for the landing page at the root.
///   `slugs`   every named page on the site, for rewriting internal links.
///   `runtime` the English strings script.js looks up at runtime (the animated
///             phone mockup's chat copy). Only those reach the injected table:
///             the rest of the cache is already baked into the markup, and
///             shipping it twice would double the page for nothing.
export function renderPage(html, lang, strings, available, options = {}) {
  const { slug = null, slugs = [], runtime: runtimeKeys } = options;
  const lookup = lang === 'en' ? (v) => v : (v) => strings[v];
  let out = lang === 'en' ? html : applyTranslations(html, lookup);
  out = localizeLinks(out, lang, slugs);
  out = lang === 'en' ? out.replace(TRANSLATED_ONLY, '') : out;

  const path = pathFor(lang, slug);
  const enPath = pathFor('en', slug);
  out = out.replace('<html lang="en">',
    `<html lang="${lang}"${isRtl(lang) ? ' dir="rtl"' : ''}>`);
  // Matched rather than compared: the press release is an `article`, and an
  // exact-string replace would have skipped it silently, publishing 132
  // translations with no og:locale on them.
  out = out.replace(/<meta property="og:type" content="[^"]*">/,
    (tag) => `${tag}\n    <meta property="og:locale" content="${lang.replace('-', '_')}">`);

  // A silently-missing marker would ship a page with no selector, no hreflang
  // or a canonical pointing at the English original — exactly the kind of SEO
  // regression nobody notices.
  const fill = (marker, value) => {
    if (!out.includes(marker)) throw new Error(`${slug ?? 'index'}: missing ${marker.trim()}`);
    out = out.replace(marker, value);
  };
  const runtime = {};
  for (const key of runtimeKeys ?? Object.keys(strings)) {
    if (typeof strings[key] === 'string') runtime[key] = strings[key];
  }

  fill(`<link rel="canonical" href="${SITE}${enPath}">`,
    `<link rel="canonical" href="${SITE}${path}">`);
  fill(`<meta property="og:url" content="${SITE}${enPath}">`,
    `<meta property="og:url" content="${SITE}${path}">`);
  // The knowledge base's pages are mostly prose: their shared chrome — the top
  // bar, the section nav, the breadcrumb, the "on this page" rail and the
  // pager — is filled in from the one outline in docs.mjs, so twenty documents
  // cannot drift out of step with each other.
  if (isDocsPage(slug)) {
    const t = (v) => lookup(v) || v;
    fill('        <!--DOCS-TOPBAR-->', renderTopbar(t));
    fill('        <!--DOCS-NAV-->', renderNav(t, pathFor, lang, slug));
    fill('        <!--DOCS-CRUMBS-->', renderCrumbs(t, pathFor, lang, slug));
    fill('        <!--DOCS-TOC-->', renderToc(t, slug));
    fill('        <!--DOCS-PAGER-->', renderPager(t, pathFor, lang, slug));
  }

  fill('    <!--HREFLANG-->', hreflangBlock(available, slug) + markdownAlternate(lang, slug));
  fill('    <!--I18N-RUNTIME-->', runtimeData(lang, available, runtime, slug));
  // Emitted last, so it reflects the finished, translated document.
  out = out.replace('</head>', structuredData(out, lang, slug) + '</head>');

  fill('        <!--LANG-SELECTOR-->',
    languageSelector(lang, available, lookup('Language') || 'Language', slug));

  // Assets are absolute from the site root, so a page served from /es/tos/
  // still resolves them.
  return out;
}

/// The sitemap, split into one file per language behind an index.
///
/// One file would be simplest, and was — but every URL carries the full
/// alternate set, so the whole site's sitemap is quadratic in the number of
/// languages: at 130 languages and 27 pages it reached 41 MB, over Cloudflare
/// Pages' 25 MiB per-file limit and closing on the 50 MB the sitemap protocol
/// allows. Splitting by language keeps each file around a fifth of a megabyte
/// and leaves room to add both pages and languages.
///
/// The annotations themselves are unchanged: each URL still lists every
/// alternate plus x-default. The protocol does not require reciprocal
/// annotations to share a file, only that each URL carry the whole set.
///
/// Returns `[{ path, xml }]` — the index first, then a file per language.
export function renderSitemap(available, slugs = [], extra = []) {
  const langs = ['en', ...TRANSLATED_LANGUAGES.filter((l) => available.has(l.code)).map((l) => l.code)];
  const pages = [null, ...slugs];

  const files = langs.map((lang) => {
    const urls = pages.map((slug) => {
      const alternates = langs
        .map((c) => `    <xhtml:link rel="alternate" hreflang="${c}" href="${SITE}${pathFor(c, slug)}"/>`)
        .join('\n');
      return `  <url>
    <loc>${SITE}${pathFor(lang, slug)}</loc>
${alternates}
    <xhtml:link rel="alternate" hreflang="x-default" href="${SITE}${pathFor('en', slug)}"/>
  </url>`;
    }).join('\n');
    // Paths that are not documents in the site's sense — the app — and so have
    // no translations and no alternates. English sitemap only, once.
    const extras = lang !== 'en' ? '' : extra
      .map((p) => `\n  <url>\n    <loc>${SITE}${p}</loc>\n  </url>`).join('');
    return {
      path: `sitemaps/${lang}.xml`,
      xml: `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        xmlns:xhtml="http://www.w3.org/1999/xhtml">
${urls}${extras}
</urlset>
`,
    };
  });

  const index = `<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${files.map((f) => `  <sitemap>
    <loc>${SITE}/${f.path}</loc>
  </sitemap>`).join('\n')}
</sitemapindex>
`;

  return [{ path: 'sitemap.xml', xml: index }, ...files];
}
