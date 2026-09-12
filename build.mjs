import { build } from "esbuild";
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import { TRANSLATED_LANGUAGES } from "./i18n/languages.mjs";
import { buildPacks, writePacks } from "./i18n/packs.mjs";
import { appSources, flutterSources } from "./i18n/surfaces.mjs";
import { loadCache } from "./i18n/translate.mjs";
import { loadSite } from "./i18n/pages.mjs";
import { renderPage, renderSitemap, SITE } from "./i18n/render.mjs";
import { renderLlmsFull, renderLlmsTxt } from "./i18n/llms.mjs";
import { articleMarkdown } from "./i18n/markdown.mjs";

const outDir = "dist";

// Static assets copied through verbatim (referenced by absolute URLs in the HTML,
// or read by the host — `_redirects` keeps retired slugs resolving and
// `_headers` carries the security and caching policy). `app` is the standalone
// Nymbot web app, copied through as built rather than rebuilt here. `media` is
// the promo video the knowledge base opens with; it is served from this origin,
// which is what `default-src 'self'` in `_headers` requires of it.
const staticAssets = ["images", "app", "media", "robots.txt", "_redirects", "_headers"];

// Local assets that get minified and content-hashed for cache busting.
const hashedAssets = [
  { src: "styles.css", ref: "styles.css" },
  { src: "script.js", ref: "script.js" },
  // Every page carries this one: it installs the translation table, keeps a
  // first-time visitor on their language, and marks that scripting is on. It is
  // a file rather than an inline script so the site can be served under
  // `script-src 'self'` — see `_headers`.
  { src: "boot.js", ref: "boot.js" },
  // Only the knowledge base loads this one; the landing and legal pages never
  // reference it, so they never pay for it.
  { src: "docs.js", ref: "docs.js" },
  { src: "brand-marks.js", ref: "brand-marks.js" },
  // Same again for the not-found page: it is the only page that loads this.
  { src: "404.js", ref: "404.js" },
];

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

// Emitted into a directory of their own so `_headers` can pin them for a year
// by prefix. A bare `/*.js` rule would also match the app's un-hashed files
// under /app and freeze a stale deploy in every cache for a year.
const assetDir = "assets";

const result = await build({
  entryPoints: hashedAssets.map((a) => a.src),
  outdir: path.join(outDir, assetDir),
  bundle: false,
  minify: true,
  entryNames: "[name]-[hash]",
  metafile: true,
});

// Map each source file to its hashed output filename.
const rename = new Map();
for (const [outPath, meta] of Object.entries(result.metafile.outputs)) {
  if (meta.entryPoint) {
    rename.set(meta.entryPoint, path.basename(outPath));
  }
}

const site = await loadSite();
const { runtime: runtimeStrings, slugs, sources } = site;

// Point every document at the hashed asset filenames. Absolute, so a page
// served from /es/terms/ still resolves them.
const documents = site.documents.map((doc) => {
  let html = doc.html;
  for (const asset of hashedAssets) {
    const hashed = rename.get(asset.src);
    if (!hashed) throw new Error(`No hashed output for ${asset.src}`);
    html = html.replaceAll(`"${asset.ref}"`, `"/${assetDir}/${hashed}"`);
  }
  return { ...doc, html };
});

// A language ships only when its cache covers every string on the site. A
// partial cache would publish a half-English page under a localized URL, which
// is worse for a reader and for search than not publishing it at all. The gate
// is site-wide on purpose: a language whose terms of service is still English
// should not have a translated home page linking to it as if it were not.
const available = new Set();
const partial = [];
const caches = new Map();
for (const lang of TRANSLATED_LANGUAGES) {
  const cache = await loadCache(lang.code);
  const have = sources.filter((s) => typeof cache[s] === "string").length;
  if (have === 0) continue;
  if (have < sources.length) {
    partial.push(`${lang.code} (${have}/${sources.length})`);
    continue;
  }
  caches.set(lang.code, cache);
  available.add(lang.code);
}

// The demo chat is only on the landing page, so only that page carries the
// runtime string table.
const emit = async (doc, lang, cache) => {
  const dir = path.join(outDir, lang === "en" ? "" : lang, doc.slug ?? "");
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, "index.html"), renderPage(doc.html, lang, cache, available, {
    slug: doc.slug,
    slugs,
    runtime: doc.slug === null ? runtimeStrings : [],
  }));
};

for (const doc of documents) {
  await emit(doc, "en", {});
  for (const [code, cache] of caches) await emit(doc, code, cache);
}

// A sitemap index plus one file per language — see renderSitemap for why the
// single file could not stay.
const sitemaps = renderSitemap(available, slugs, ["/app"]);
for (const file of sitemaps) {
  const out = path.join(outDir, file.path);
  await mkdir(path.dirname(out), { recursive: true });
  await writeFile(out, file.xml);
}

// A markdown index of the site at a well-known path, for agents that would
// otherwise have to crawl and strip HTML to find out what is here.
await writeFile(path.join(outDir, "llms.txt"), renderLlmsTxt(site.documents));

// The whole knowledge base as one markdown file, and a markdown twin beside
// every page — /docs/mesh/ is also /docs/mesh.md. An agent asking for a page
// would rather have the prose than the stylesheet and the navigation tree.
// English only: the convention is one document at one path, and a reader who
// wants another language has the hreflang set on every page.
await writeFile(path.join(outDir, "llms-full.txt"), renderLlmsFull(site.documents));
let markdownPages = 0;
for (const doc of site.documents) {
  if (!doc.slug) continue;
  const md = articleMarkdown(doc.html, { site: SITE });
  const out = path.join(outDir, `${doc.slug}.md`);
  await mkdir(path.dirname(out), { recursive: true });
  await writeFile(out, md);
  markdownPages++;
}

for (const asset of staticAssets) {
  await cp(asset, path.join(outDir, asset), { recursive: true });
}

// The host serves this for anything that does not resolve. It is not a page in
// the site's sense — no canonical, no hreflang, not in the sitemap, and marked
// noindex — so it does not go through the localized render. It does still need
// the hashed stylesheet name, which is the whole reason it is not just copied.
{
  let notFound = await readFile("404.html", "utf8");
  for (const asset of hashedAssets) {
    notFound = notFound.replaceAll(`"${asset.ref}"`, `"/${assetDir}/${rename.get(asset.src)}"`);
  }
  await writeFile(path.join(outDir, "404.html"), notFound);
}

console.log("Build complete:");
for (const asset of hashedAssets) {
  console.log(`  ${asset.src} -> ${rename.get(asset.src)}`);
}
console.log(`  ${documents.length} pages: ${documents.map((d) => d.slug ?? "/").join(", ")}`);
// The apps' packs. Emitted here rather than checked in: they are derived from
// the cache, and a stale copy in the tree is a translation nobody can explain.
// The Flutter pack goes to its asset directory in the working tree, because a
// Flutter build reads assets from there, not from dist/.
{
  const app = await buildPacks((await appSources()).sources);
  await writePacks(path.join(outDir, "app", "i18n"), app);
  const flutter = await buildPacks((await flutterSources()).sources);
  await writePacks("flutter/assets/i18n", flutter);
  const say = (label, built) => `${label}: ${built.packs.size} languages`
    + (built.partial.length ? `, ${built.partial.length} incomplete` : "");
  console.log(`  ${say("app packs", app)}; ${say("flutter packs", flutter)}`);
}

console.log(`  sitemap.xml (index over ${sitemaps.length - 1} language sitemaps), llms.txt, llms-full.txt, 404.html`);
console.log(`  ${markdownPages} markdown twins (<page>.md)`);
console.log(`  ${sources.length} translatable strings (${runtimeStrings.length} from script.js)`);
console.log(`  languages published: ${available.size} (+ English at /)`);
if (partial.length > 0) {
  console.log(`  skipped, cache incomplete: ${partial.join(", ")}`);
  console.log(`  run 'npm run i18n' to fill them in`);
}
