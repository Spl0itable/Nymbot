import { LANGUAGES, TRANSLATED_LANGUAGES, displayName, isRtl, pathFor } from './languages.mjs';
import { applyTranslations } from './extract.mjs';
import {
  isDocsPage, renderCrumbs, renderNav, renderPager, renderToc, renderTopbar,
} from './docs.mjs';

export const SITE = 'https://nymbot.ai';

const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/// hreflang is what search engines use to serve the right translation; the client-side redirect is a convenience.
function hreflangBlock(available, slug) {
  const rows = [`    <link rel="alternate" hreflang="x-default" href="${SITE}${pathFor('en', slug)}">`];
  for (const lang of LANGUAGES) {
    if (lang.code !== 'en' && !available.has(lang.code)) continue;
    rows.push(`    <link rel="alternate" hreflang="${lang.code}" href="${SITE}${pathFor(lang.code, slug)}">`);
  }
  return rows.join('\n');
}

/// English only: a translated page has no markdown twin, and the landing page points at the site index.
function markdownAlternate(lang, slug) {
  if (lang !== 'en') return '';
  const link = slug
    ? `<link rel="alternate" type="text/markdown" href="${SITE}/${slug}.md" title="This page as markdown">`
    : `<link rel="alternate" type="text/plain" href="${SITE}/llms.txt" title="Nymbot for AI agents (llms.txt)">`;
  return `\n    ${link}`;
}

function languageSelector(current, available, label, slug) {
  const options = LANGUAGES
    .filter((l) => l.code === 'en' || available.has(l.code))
    .map((l) => {
      const selected = l.code === current ? ' aria-current="true"' : '';
      // Canonical hrefs to match hreflang; the endonym is the label and the English name the tooltip.
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

/// A JSON block, not an inline script, so every page stays under `script-src 'self'` without per-page hashes.
function runtimeData(lang, available, strings, slug) {
  const codes = ['en', ...LANGUAGES.filter((l) => available.has(l.code)).map((l) => l.code)];
  return `    <script type="application/json" id="nym-i18n" data-lang="${lang}"`
    + ` data-page="${slug ?? ''}" data-langs="${codes.join(',')}">`
    + `${JSON.stringify(strings)}</script>`;
}

/// Read from the rendered HTML so FAQPage data matches the visible answers, which Google requires.
function faqPairs(html) {
  const items = [];
  // The answer holds only paragraphs, so it ends at the first `</div>` starting a line.
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
    graph.push({
      '@type': 'SoftwareApplication',
      name: 'Nymbot',
      alternateName: 'Nymbot private AI chat',
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
    // A page with a publication date (the press release) is emitted as a NewsArticle.
    const published = (/<meta property="article:published_time" content="([^"]*)">/i.exec(html) || [])[1];
    // The page's <h1>, since the <title> carries a site suffix.
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

/// Rewrites only the site's own page paths for the language, keeping any fragment or query; assets are left alone.
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

/// Governing-English note: extracted and translated like any sentence, dropped from the English render.
const TRANSLATED_ONLY = /[^\S\n]*<p\b[^>]*\bdata-i18n-translated-only\b[^>]*>[\s\S]*?<\/p>\n/g;

/// `runtime` lists the only strings injected into the runtime table; the rest is already baked into the markup.
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
  // Matched rather than compared, because the press release's og:type is `article`.
  out = out.replace(/<meta property="og:type" content="[^"]*">/,
    (tag) => `${tag}\n    <meta property="og:locale" content="${lang.replace('-', '_')}">`);

  // A missing marker fails the build rather than shipping a page without selector, hreflang or correct canonical.
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
  // Docs chrome is filled from the one outline in docs.mjs so pages cannot drift apart.
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

  return out;
}

/// Split per language: alternates make one file quadratic in size, past Cloudflare's 25 MiB limit.
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
    // Non-document paths (the app) have no alternates, so they appear once, in the English sitemap.
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
