// End-to-end check of the localized build: the extractor, the per-language
// render, and the SEO surface. Uses a synthetic cache so it runs offline.

import { execFile } from 'node:child_process';
import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

import { sourceStrings, scriptStrings, applyTranslations } from '../extract.mjs';
import { loadSite } from '../pages.mjs';
import { renderPage, renderSitemap, SITE } from '../render.mjs';
import { LANGUAGES, displayName, isRtl, pathFor } from '../languages.mjs';
import { DOCS_PAGES, checkOutline } from '../docs.mjs';
import { loadCache } from '../translate.mjs';

const run = promisify(execFile);
const root = new URL('../../', import.meta.url).pathname;

let fail = 0;
const ok = (cond, msg, extra) => {
  if (!cond) { fail++; console.log('FAIL:', msg, extra === undefined ? '' : extra); }
  else console.log('  ok', msg);
};

const boot = await readFile(path.join(root, 'boot.js'), 'utf8');
const site = await loadSite();
const { slugs, runtime: runtimeStrings, sources } = site;
const html = site.documents.find((d) => d.slug === null).html;
const terms = site.documents.find((d) => d.slug === 'terms').html;
const pageSources = sourceStrings(html);

// Read out of the page rather than written down twice. The four assertions
// below are about what the pipeline does to body copy, not about what the copy
// currently says, and hardcoding the sentence made them fail the day it was
// reworded rather than the day the pipeline broke.
const TAGLINE = /<p class="tagline">([^<]+)<\/p>/.exec(html)[1];
const render = (doc, lang, strings, avail, opts = {}) =>
  renderPage(doc, lang, strings, avail, { slugs, runtime: runtimeStrings, ...opts });

// --- extraction ------------------------------------------------------------
ok(sources.length > 150, 'the page yields a real string set', sources.length);
ok(!sources.some((s) => s.includes('#######')), 'the ASCII logo is never extracted');
ok(!sources.some((s) => s.includes('DOCTYPE')), 'the doctype is not prose');
ok(!sources.includes('Nymbot'), 'a bare brand name is protected from translation');
ok(!sources.some((s) => s.startsWith('https://')), 'URLs are not extracted');
ok(applyTranslations(html, (v) => v) === html,
   'an identity substitution reproduces the document byte for byte');
ok(sources.includes(TAGLINE), 'the tagline is translatable', TAGLINE);

// --- the demo chat in the phone mockup -------------------------------------
// Its bubbles are written by script.js at runtime, so they are marked with
// `t()` there instead of appearing in the markup.
ok(runtimeStrings.length > 0, 'the mockup copy yields strings', runtimeStrings.length);
ok(runtimeStrings.includes('what does hybrid post-quantum actually buy me here?'),
   'the first chat bubble is translatable');
ok(runtimeStrings.includes('Nymbot is reading your repo'),
   'a thinking label is translatable too');
ok(runtimeStrings.every((s) => sources.includes(s)),
   'every mockup string is part of the set sent for translation');
ok(pageSources.every((v) => sources.includes(v)) && sources.length > pageSources.length,
   'the landing page is one document in a larger site-wide string set');
ok(!pageSources.includes('what does hybrid post-quantum actually buy me here?'),
   'the HTML walk alone never sees the mockup copy, which is why t() exists');
ok(scriptStrings('t(\'quoted\'); t("double"); setTimeout(f, 1); function t(x) { return x; }')
     .join('|') === 'quoted|double',
   'both quote styles are read, and neither a longer identifier nor the declaration is');
{
  let threw = false;
  try { scriptStrings('t(someVariable)'); } catch { threw = true; }
  ok(threw, 'a t() the extractor cannot read fails the build instead of shipping English');
}

// --- the standalone pages (/terms/, /privacy/, /dmca/, /contact/) ----------
ok(slugs.includes('terms') && slugs.includes('privacy') && slugs.includes('dmca')
   && slugs.includes('contact'), 'the site publishes the legal and contact pages', slugs);
ok(sources.some((v) => v.includes('These Terms of Service')),
   'terms-of-service copy is part of the translated string set');
ok(sources.includes('DMCA & Content Policy'),
   'an entity reaches the translator decoded, not as the literal &amp;');
ok(!sources.includes('support@nymchat.app') && !sources.includes('nostrservices.com'),
   'an address is a value, not prose, and is never sent for translation');
ok(!sources.includes('21 Million LLC'), 'the legal entity name is protected');
ok(pathFor('en', 'terms') === '/terms/' && pathFor('es', 'terms') === '/es/terms/'
   && pathFor('en') === '/' && pathFor('es') === '/es/', 'page paths nest under the language');

// --- escaping: a translation is third-party text going into HTML -----------
{
  const hostile = '" onload="alert(1)" x="';
  const withQuote = applyTranslations(html, (v) =>
    v.startsWith('Anonymous AI chat with no account') ? hostile : v);
  ok(!withQuote.includes('onload="alert(1)"'),
     'a quote in a translated meta description cannot break out of the attribute');
  ok(withQuote.includes('&quot; onload=&quot;alert(1)&quot;'), 'it is escaped instead');

  const withTags = applyTranslations(html, (v) =>
    v === TAGLINE ? '<script>alert(1)</script>' : v);
  ok(!withTags.includes('<script>alert(1)</script>'), 'a tag in translated body text is escaped');
  ok(withTags.includes('&lt;script&gt;alert(1)&lt;/script&gt;'), 'it renders as literal text');

  // An author-written entity must survive untouched when nothing replaces it.
  ok(applyTranslations(html, () => undefined).includes('&copy;'),
     'an untranslated slot keeps its original bytes, entities and all');
}

// --- render ----------------------------------------------------------------
const fake = (lang) => Object.fromEntries(sources.map((s) => [s, `[${lang}]${s}`]));
const available = new Set(['es', 'ar']);

const es = render(html, 'es', fake('es'), available);
ok(es.includes('<html lang="es">'), 'the language attribute is set');
ok(!es.includes('dir="rtl"'), 'a LTR language gets no dir attribute');
ok(es.includes(`<link rel="canonical" href="${SITE}/es/">`), 'canonical points at the language path');
ok(es.includes(`<meta property="og:url" content="${SITE}/es/">`), 'og:url points at the language path');
ok(es.includes('<meta property="og:locale" content="es">'), 'og:locale is set');
ok(es.includes(`[es]${TAGLINE}`), 'body copy is translated');
ok(es.includes('#######'), 'the ASCII logo survives untouched');
ok(!es.includes('[es]Nymbot</p>'), 'the brand name is not mangled');

const ar = render(html, 'ar', fake('ar'), available);
ok(ar.includes('<html lang="ar" dir="rtl">'), 'an RTL language gets dir="rtl"');
ok(isRtl('ar') && !isRtl('es'), 'the RTL set is correct');

const en = render(html, 'en', {}, available);
ok(en.includes('<html lang="en">'), 'English keeps its language attribute');
ok(en.includes(`<link rel="canonical" href="${SITE}/">`), 'English canonical stays at the root');
ok(en.includes(TAGLINE) && !en.includes('[es]'),
   'English is passed through untranslated');

// --- a standalone page renders at its own path -----------------------------
{
  const opts = { slug: 'terms', slugs, runtime: [] };
  const esTerms = renderPage(terms, 'es', fake('es'), available, opts);
  const enTerms = renderPage(terms, 'en', {}, available, opts);

  ok(esTerms.includes(`<link rel="canonical" href="${SITE}/es/terms/">`),
     'the canonical points at this page in this language, not at the home page');
  ok(esTerms.includes(`<meta property="og:url" content="${SITE}/es/terms/">`), 'og:url matches it');
  ok(esTerms.includes(`<link rel="alternate" hreflang="ar" href="${SITE}/ar/terms/">`),
     'alternates point at the same page in the other languages');
  ok(esTerms.includes(`<link rel="alternate" hreflang="x-default" href="${SITE}/terms/">`),
     'x-default is the English copy of this page');
  ok(esTerms.includes('href="/ar/terms/" data-lang="ar"'),
     'switching language keeps the reader on the page they are reading');
  ok(esTerms.includes('[es]Terms of Service'), 'the copy is translated');

  // A link written for English has to land in the reader's language.
  ok(esTerms.includes('href="/es/privacy/"') && !esTerms.includes('href="/privacy/"'),
     'a link between pages stays inside the language');
  ok(esTerms.includes('href="/es/"'), 'so does the link back to the home page');
  ok(enTerms.includes('href="/privacy/"') && enTerms.includes('href="/"'),
     'the English page keeps the paths as authored');
  ok(esTerms.includes('href="styles.css"'),
     'an asset href is left exactly as authored, not treated as a page path');

  ok(esTerms.includes('data-i18n-translated-only'),
     'a translated page says the English original is the one that applies');
  ok(!enTerms.includes('data-i18n-translated-only') && !enTerms.includes('machine-translated'),
     'the English original does not carry that note');

  // The landing page owns the demo chat; a legal page has no copy to feed it.
  ok(enTerms.includes('id="nym-i18n"') && enTerms.includes('>{}</script>')
     && esTerms.includes('>{}</script>'),
     'a page without the animated chat ships an empty runtime table');

  let threw = false;
  try { renderPage(terms, 'es', fake('es'), available, { slug: 'wrong', slugs }); }
  catch { threw = true; }
  ok(threw, 'a slug that does not match the document fails instead of shipping a bad canonical');
}

// --- hreflang + selector ---------------------------------------------------
for (const page of [en, es, ar]) {
  ok(page.includes(`<link rel="alternate" hreflang="x-default" href="${SITE}/">`), 'x-default alternate present');
  ok(page.includes(`<link rel="alternate" hreflang="es" href="${SITE}/es/">`), 'es alternate present');
  ok(page.includes(`<link rel="alternate" hreflang="ar" href="${SITE}/ar/">`), 'ar alternate present');
  ok(!page.includes('hreflang="ja"'), 'a language with no page is not advertised');
}

// --- the markdown an agent would otherwise have to guess at ----------------
ok(en.includes(`<link rel="alternate" type="text/plain" href="${SITE}/llms.txt"`),
   'the landing page points at the site index in markdown');
for (const page of [es, ar]) {
  ok(!page.includes('/llms.txt'), 'a translated page does not advertise the English-only index');
}
// CLDR gives endonyms in their own orthography, so Spanish is lowercase.
ok(es.includes('data-lang="es" hreflang="es" lang="es" title="Spanish" aria-current="true">espa\u00f1ol'),
   'the selector marks the current language and shows its endonym');
ok(es.includes('>English</a>'), 'a language without a distinct endonym keeps its English name');
ok(displayName({ code: 'ja', name: 'Japanese', native: '\u65e5\u672c\u8a9e' }) === '\u65e5\u672c\u8a9e',
   'displayName prefers the endonym');
ok(displayName({ code: 'af', name: 'Afrikaans' }) === 'Afrikaans',
   'displayName falls back to the English name');
ok(boot.includes("localStorage.setItem('nym_lang', a.getAttribute('data-lang'))"),
   'picking a language records the choice');
ok(!/^\s*<script>/m.test(es) && !/^\s*<script>/m.test(en),
   'no page carries an inline script, so the site can be served under a strict CSP');
ok(es.includes('href="/"') && es.includes('href="/ar/"'), 'the selector links every published language');
ok((es.match(/class="lang-picker"/g) || []).length === 1, 'exactly one selector is rendered');

// --- auto-switch -----------------------------------------------------------
//
// The behavior lives in boot.js, one file the whole site shares; each page
// carries only the data it needs, as JSON that is parsed and never executed.
ok(boot.includes('navigator.languages'), 'boot.js reads the browser language');
ok(boot.includes("localStorage.getItem('nym_lang')"), 'an explicit choice is remembered');
ok(/if \(lang !== 'en'\) return;/.test(boot),
   'a translated page never auto-redirects, so a chosen or crawled URL is stable');
ok(en.includes('data-lang="en"') && es.includes('data-lang="es"'),
   'each page tells boot.js which language it is');
// English first, then the rest in the order LANGUAGES lists them.
ok(es.includes('data-langs="en,ar,es"') && es.includes('data-page=""'),
   'and which languages are published, and which page this is');
ok(es.includes('id="nym-i18n"') && es.includes('type="application/json"'),
   'the runtime string table is injected as data, not as a script that runs');
ok(en.includes('>{}</script>'), 'English injects an empty table');
ok(es.includes(JSON.stringify('[es]what does hybrid post-quantum actually buy me here?')),
   'the mockup copy reaches the runtime table, so the animated chat is localized');
ok(!es.includes(JSON.stringify('[es]Private. Paid in sats. Yours alone.')),
   'copy already baked into the markup is not shipped a second time in the table');

// --- a broken template fails the build rather than shipping quietly --------
{
  let threw = false;
  try { render(html.replace('<!--HREFLANG-->', ''), 'es', fake('es'), available); }
  catch { threw = true; }
  ok(threw, 'a missing marker raises instead of publishing a page without hreflang');
}

// --- the knowledge base ----------------------------------------------------
//
// /docs/ is a section rather than a page: its documents live in a subdirectory
// of pages/, and their shared chrome — nav, breadcrumb, rail, pager — is filled
// in from the outline in docs.mjs rather than written into each document.
{
  ok(slugs.includes('docs') && slugs.includes('docs/anonymous'),
     'a document in a pages/ subdirectory publishes under a nested slug', slugs.filter((s) => s.startsWith('docs')).length);
  ok(pathFor('en', 'docs/anonymous') === '/docs/anonymous/' && pathFor('es', 'docs/anonymous') === '/es/docs/anonymous/',
     'a nested page path nests under the language too');
  ok(DOCS_PAGES.every((p) => slugs.includes(p.slug)),
     'every page in the outline has a source document');
  ok(DOCS_PAGES[0].slug === 'docs', 'the outline starts at the section index');

  const anon = site.documents.find((d) => d.slug === 'docs/anonymous').html;
  const opts = { slug: 'docs/anonymous', slugs, runtime: [] };
  const esAnon = renderPage(anon, 'es', fake('es'), available, opts);
  const enAnon = renderPage(anon, 'en', {}, available, opts);

  ok(enAnon.includes('id="docs-nav"'), 'the section nav is filled in');
  ok(enAnon.includes('aria-current="page"'), 'the nav marks the page being read');
  ok(enAnon.includes('class="docs-toc"'), 'the on-this-page rail is filled in');
  ok(enAnon.includes('class="docs-pager"'), 'the pager is filled in');
  ok(enAnon.includes('class="docs-crumbs"'), 'the breadcrumb is filled in');
  ok(!enAnon.includes('<!--DOCS-'), 'no docs marker is left unfilled');

  // The whole tree ships on every page: that is what makes the filter box a
  // search across the knowledge base with no index to build or translate.
  for (const page of DOCS_PAGES) {
    if (!enAnon.includes(`href="${pathFor('en', page.slug)}"`)) {
      ok(false, `the nav links every page (${page.slug})`);
      break;
    }
  }
  ok(enAnon.includes('#panic'), "another page's headings ride along for the filter to find");

  ok(esAnon.includes(`<link rel="canonical" href="${SITE}/es/docs/anonymous/">`),
     'a nested page is canonical to itself');
  ok(esAnon.includes(`<link rel="alternate" hreflang="ar" href="${SITE}/ar/docs/anonymous/">`),
     'its alternates are the same page in the other languages');
  ok(esAnon.includes('href="/es/docs/"'), 'the nav stays inside the language');
  ok(!esAnon.includes('href="/docs/"'), 'and never links back out to English');
  ok(esAnon.includes('[es]Anonymous mode'), 'the nav label is translated');

  ok(enAnon.includes(`<link rel="alternate" type="text/markdown" href="${SITE}/docs/anonymous.md"`),
     'an English page points at its own markdown twin');
  ok(!esAnon.includes('.md"'), 'a translated page has no twin to point at, and claims none');

  // A link to a heading on another page is the knowledge base's most common
  // internal link; dropping the fragment, or the language, breaks it quietly.
  {
    const withFragment = anon.replace('<h1>', '<p><a href="/docs/credits/#buying">buying</a></p><h1>');
    const rendered = renderPage(withFragment, 'es', fake('es'), available, opts);
    ok(rendered.includes('href="/es/docs/credits/#buying"'),
       'a link to a heading on another page keeps both its language and its fragment');
  }

  // The outline is duplicated information, so it is checked rather than trusted.
  const renamed = anon.replace('id="vouchers"', 'id="voucher"');
  let threw = false;
  try { checkOutline([...site.documents.filter((d) => d.slug !== 'docs/anonymous'), { slug: 'docs/anonymous', html: renamed }]); }
  catch { threw = true; }
  ok(threw, 'a heading renamed in the markup but not in the outline fails the build');

  threw = false;
  try { checkOutline([...site.documents, { slug: 'docs/orphan', html: '' }]); }
  catch { threw = true; }
  ok(threw, 'a docs page missing from the outline fails the build, since nothing would link to it');

  // A cross-page link to a heading is the knowledge base's most common internal
  // link, and the easiest thing to break by renaming a heading somewhere else.
  const linkTo = (href) => [
    ...site.documents.filter((d) => d.slug !== 'docs/anonymous'),
    { slug: 'docs/anonymous', html: anon.replace('<h1>', `<p><a href="${href}">x</a></p><h1>`) },
  ];
  threw = false;
  try { checkOutline(linkTo('/docs/credits/#not-a-heading')); } catch { threw = true; }
  ok(threw, 'a link to a heading that does not exist on another page fails the build');
  threw = false;
  try { checkOutline(linkTo('/docs/nowhere/')); } catch { threw = true; }
  ok(threw, 'a link to a docs page that does not exist fails too');
  threw = false;
  try { checkOutline(linkTo('/docs/credits/#buying')); } catch { threw = true; }
  ok(!threw, 'a link to a heading that does exist is fine');
}

// --- sitemap ---------------------------------------------------------------
//
// One file per language behind an index. Every URL carries the full alternate
// set, so a single sitemap grows with pages TIMES languages: at 130 languages
// it passed 40 MB, over the 25 MiB a file may be on the host and closing on the
// 50 MB the protocol allows.
{
  const files = renderSitemap(available, slugs);
  const index = files[0];
  const byPath = new Map(files.map((f) => [f.path, f.xml]));

  ok(index.path === 'sitemap.xml', 'the index keeps the well-known path');
  ok(index.xml.includes('<sitemapindex'), 'and is a sitemap index');
  ok(!index.xml.includes('<url>'), 'carrying no URLs of its own');
  ok(files.length === 4, 'one file per published language, plus the index', files.length);
  for (const lang of ['en', 'es', 'ar']) {
    ok(index.xml.includes(`<loc>${SITE}/sitemaps/${lang}.xml</loc>`),
       `the index points at the ${lang} sitemap`);
    ok(byPath.has(`sitemaps/${lang}.xml`), `and that file is emitted (${lang})`);
  }

  const en = byPath.get('sitemaps/en.xml');
  const es = byPath.get('sitemaps/es.xml');
  ok(en.includes(`<loc>${SITE}/</loc>`), 'the English sitemap lists the root');
  ok(en.includes(`<loc>${SITE}/terms/</loc>`), 'and each standalone page');
  ok(es.includes(`<loc>${SITE}/es/terms/</loc>`), 'each language lists its own copies');
  ok(!es.includes(`<loc>${SITE}/terms/</loc>`), 'and only its own');
  ok((en.match(/<url>/g) || []).length === 1 + slugs.length,
     'one entry per page in that language');
  ok(files.slice(1).reduce((n, f) => n + (f.xml.match(/<url>/g) || []).length, 0)
     === 3 * (1 + slugs.length),
     'and the set still covers every page in every published language');

  // Splitting must not weaken the annotations: each URL still names every
  // alternate, which is what the protocol asks for — not that reciprocal
  // annotations share a file.
  ok(es.includes(`hreflang="ar" href="${SITE}/ar/terms/"`),
     'a URL still names its alternates in the other languages');
  ok(es.includes('hreflang="x-default"'), 'and x-default');
}

// --- cache round trip ------------------------------------------------------
{
  const before = await loadCache('__nonexistent__');
  ok(Object.keys(before).length === 0, 'a missing cache loads as empty, not an error');
}

// --- the real build, driven by a synthetic cache ---------------------------
// The cache directory is redirected to a scratch dir: a test must never write
// to the committed translation memory.
{
  const scratch = await mkdtemp(path.join(tmpdir(), 'nym-i18n-cache-'));
  const env = { ...process.env, NYM_I18N_CACHE_DIR: scratch + '/' };
  const write = async (lang, map) =>
    writeFile(path.join(scratch, `${lang}.json`), JSON.stringify(map, null, 2));

  for (const lang of ['es', 'ar']) await write(lang, fake(lang));
  // A deliberately incomplete cache must NOT publish a page.
  const partialLang = 'fr';
  await write(partialLang, Object.fromEntries(sources.slice(0, 5).map((s) => [s, 'x'])));

  try {
    await run('node', ['build.mjs'], { cwd: root, env });
    const built = (p) => readFile(path.join(root, 'dist', p), 'utf8');
    const esOut = await built('es/index.html');
    ok(esOut.includes('<html lang="es">'), 'build emitted /es/index.html');
    ok(esOut.includes('[es]'), 'the built page carries translations');
    ok(/href="\/assets\/styles-[A-Z0-9]+\.css"/.test(esOut),
       'assets are absolute so a subdirectory page still loads them');
    ok(/src="\/assets\/script-[A-Z0-9]+\.js"/.test(esOut), 'the script src is absolute too');
    ok(/src="\/assets\/boot-[A-Z0-9]+\.js"/.test(esOut), 'the built page loads the hashed boot script');
    ok(esOut.indexOf('id="nym-i18n"') < esOut.indexOf('src="/assets/boot-')
       && esOut.indexOf('src="/assets/boot-') < esOut.indexOf('<script src="/assets/script-'),
       'the table is in the DOM before boot.js reads it, and both run before script.js');
    ok(esOut.includes(JSON.stringify('[es]what does hybrid post-quantum actually buy me here?')),
       'the built page carries the mockup translations');
    ok((await built('ar/index.html')).includes('dir="rtl"'), 'build emitted the RTL page');
    ok((await built('index.html')).includes('<html lang="en">'), 'build emitted the English root');
    ok((await built('sitemap.xml')).includes('/sitemaps/es.xml'),
       'build emitted the sitemap index');
    ok((await built('sitemaps/es.xml')).includes(`<loc>${SITE}/es/</loc>`),
       'and the per-language sitemaps it points at');
    {
      const sizes = await Promise.all(['sitemap.xml', 'sitemaps/en.xml', 'sitemaps/es.xml']
        .map(async (f) => (await built(f)).length));
      ok(sizes.every((n) => n < 25 * 1024 * 1024),
         'no sitemap file is near the 25 MiB the host allows', Math.max(...sizes));
    }
    let frExists = true;
    try { await built(`${partialLang}/index.html`); } catch { frExists = false; }
    ok(!frExists, 'a language with an incomplete cache is not published');

    for (const slug of slugs) {
      // Two page shapes: the legal and contact documents, and the knowledge
      // base. Both are documents in pages/ and go through the same pipeline;
      // only their shell differs.
      const shell = slug.startsWith('docs') ? 'docs-shell' : 'legal-page';
      ok((await built(`${slug}/index.html`)).includes(shell), `build emitted /${slug}/`);
      ok((await built(`es/${slug}/index.html`)).includes('[es]'),
         `build emitted a translated /es/${slug}/`);
    }
    // --- the outputs that are not pages ----------------------------------
    {
      const llms = await built('../dist/llms.txt').catch(() => readFile(path.join(root, 'dist/llms.txt'), 'utf8'));
      ok(llms.startsWith('# Nymbot'), 'llms.txt is markdown headed by the site name');
      ok(DOCS_PAGES.every((p) => llms.includes(`${SITE}${pathFor('en', p.slug)}`)),
         'llms.txt lists every knowledge base page');
      ok(llms.includes(`${SITE}/contact/`) && llms.includes(`${SITE}/terms/`),
         'and the standalone pages');
      ok(llms.includes(`${SITE}/llms-full.txt`) && llms.includes('.md'),
         'and points at the markdown, so an agent does not have to guess it exists');

      // --- markdown twins ---------------------------------------------
      const full = await readFile(path.join(root, 'dist/llms-full.txt'), 'utf8');
      ok(full.length > 20000, 'llms-full.txt carries the whole knowledge base', full.length);
      ok(DOCS_PAGES.every((p) => full.includes(`Source: ${SITE}${pathFor('en', p.slug)}`)),
         'with every page attributed to the URL it came from');
      ok(full.includes('## Blind credit vouchers') && full.includes('Last Updated:') === false,
         'it is the knowledge base, in markdown, and not the pages outside it');

      const anonMd = await readFile(path.join(root, 'dist/docs/anonymous.md'), 'utf8');
      ok(anonMd.startsWith('# Anonymous mode'), 'a page twin opens with that page\'s heading');
      ok(anonMd.includes('## Blind credit vouchers'), 'and carries its sections');
      ok(!/<[a-z]/i.test(anonMd), 'with no markup left in it');
      ok(!/\]\(\//.test(anonMd), 'and no relative link left in it, since it may be read anywhere');
      ok(anonMd.includes(`](${SITE}/docs/identity/#panic)`),
         'the site-root paths having been made absolute');
      ok(!anonMd.includes('machine-translated'),
         'the note that belongs only to a translated render is not in the English markdown');

      const creditsMd = await readFile(path.join(root, 'dist/docs/credits.md'), 'utf8');
      ok(creditsMd.includes('| Balance | Price | Spent on |'), 'a table survives as a markdown table');
      ok(creditsMd.includes('**Standard replies**'), 'and emphasis survives with it');

      const gitMd = await readFile(path.join(root, 'dist/docs/git.md'), 'utf8');
      ok(/> \*\*About that token\*\*/.test(gitMd), 'a callout becomes a labelled blockquote');

      const docsMd = await readFile(path.join(root, 'dist/docs.md'), 'utf8');
      ok(docsMd.includes(`](${SITE}/docs/getting-started/)`),
         'and a relative link becomes an absolute one');

      const notFound = await readFile(path.join(root, 'dist/404.html'), 'utf8');
      ok(notFound.includes('name="robots" content="noindex"'),
         'the 404 page asks not to be indexed');
      ok(/href="\/assets\/styles-[A-Z0-9]+\.css"/.test(notFound),
         'and still resolves the hashed stylesheet, which is why it is not merely copied');
      ok(!notFound.includes('rel="canonical"'),
         'a page that is not at one address does not claim to be canonical anywhere');
      ok(!(await built('sitemaps/en.xml')).includes('404'), 'and is not in the sitemap');

      const enMap = await built('sitemaps/en.xml');
      ok(enMap.includes(`<loc>${SITE}/app</loc>`), 'the app is a URL worth crawling');
      // Counted across every sitemap that was published rather than checked
      // against one language's file: which languages ship depends on how
      // complete their cache is, and this assertion is about the app.
      const maps = await readdir(path.join(root, 'dist/sitemaps'));
      let appEntries = 0;
      for (const name of maps) {
        const xml = await readFile(path.join(root, 'dist/sitemaps', name), 'utf8');
        appEntries += (xml.match(/<loc>[^<]*\/app<\/loc>/g) ?? []).length;
      }
      ok(appEntries === 1,
         'and appears once, not once per language, since it has no translations',
         `${appEntries} across ${maps.length} sitemaps`);

      const ld = (html) => JSON.parse(
        /<script type="application\/ld\+json">([\s\S]*?)<\/script>/.exec(html)[1].replace(/\\u003c/g, '<'));
      const home = ld(await built('index.html'))['@graph'];
      ok(home[0]['@type'] === 'SoftwareApplication' && home[0].name === 'Nymbot',
         'the landing page describes the app in structured data');
      ok(home[0].publisher.name === '21 Million LLC', 'attributed to the company that publishes it');
      ok(Array.isArray(home[0].featureList) && home[0].featureList.length >= 6
         && home[0].installUrl === `${SITE}/app`,
         'with what it does and where to open it');

      // FAQ rich results. Google refuses markup that says anything the page
      // does not, so what matters is that these come OUT of the page.
      const faq = home.find((n) => n['@type'] === 'FAQPage');
      const faqOnPage = [...(await built('index.html'))
        .matchAll(/<div class="faq-question-text">([\s\S]*?)<\/div>/g)].map((m) => m[1]);
      ok(faq && faq.mainEntity.length === faqOnPage.length && faqOnPage.length >= 8,
         'every FAQ on the page is in the structured data', `${faq?.mainEntity.length} vs ${faqOnPage.length}`);
      ok(faq.mainEntity.every((q, i) => q.name === faqOnPage[i]),
         'in the same order, and worded the same way');
      ok(faq.mainEntity.every((q) => q.acceptedAnswer.text.length > 40
         && !/[<>]/.test(q.acceptedAnswer.text)),
         'answers carry the prose without the markup around it');
      const esHome = ld(await built('es/index.html'))['@graph'];
      const esFaq = esHome.find((n) => n['@type'] === 'FAQPage');
      ok(esFaq && esFaq.inLanguage === 'es' && esFaq.mainEntity[0].name.includes('[es]'),
         'and a translated page carries the translated FAQ, not the English one');
      const anonLd = ld(await built('docs/anonymous/index.html'))['@graph'];
      ok(anonLd[0]['@type'] === 'TechArticle', 'a docs page is an article');
      ok(!anonLd.some((n) => n['@type'] === 'FAQPage'),
         'and carries no FAQ, since only the landing page has one');
      ok(anonLd[1]['@type'] === 'BreadcrumbList'
         && anonLd[1].itemListElement.map((i) => i.name).join('>') === 'Nymbot>Knowledge base>Anonymous mode',
         'with the breadcrumb a crawler cannot otherwise see');
      const esLd = ld(await built('es/docs/anonymous/index.html'))['@graph'];
      ok(esLd[0].inLanguage === 'es' && esLd[0].headline.includes('[es]'),
         'structured data is in the language of the page it describes');
    }

    const esTermsOut = await built('es/terms/index.html');
    ok(esTermsOut.includes(`<link rel="canonical" href="${SITE}/es/terms/">`),
       'the built page is canonical to itself');
    ok(esTermsOut.includes('href="/es/privacy/"'),
       'the built page links to the same language it is written in');
    ok(/href="\/assets\/styles-[A-Z0-9]+\.css"/.test(esTermsOut),
       'a page in a nested directory still resolves the hashed stylesheet');
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}

console.log(fail === 0 ? '\nlocalized build: all assertions passed' : `\n${fail} FAILURES`);
process.exit(fail ? 1 : 0);
