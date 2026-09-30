import { build, transform } from "esbuild";
import { createHash } from "node:crypto";
import { cp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import { isRtl, TRANSLATED_LANGUAGES } from "./i18n/languages.mjs";
import { buildPacks, writePacks } from "./i18n/packs.mjs";
import { appSources, flutterSources } from "./i18n/surfaces.mjs";
import { loadCache } from "./i18n/translate.mjs";
import { loadSite } from "./i18n/pages.mjs";
import { renderPage, renderSitemap, SITE } from "./i18n/render.mjs";
import { renderLlmsFull, renderLlmsTxt } from "./i18n/llms.mjs";
import { articleMarkdown } from "./i18n/markdown.mjs";
import { ERROR_PAGES, renderErrorPage } from "./errors/pages.mjs";
import { errorStyles } from "./errors/style.mjs";

const outDir = "dist";

// `media` is served from this origin because `_headers` sets `default-src 'self'`.
const staticAssets = ["images", "app", "media", "robots.txt", "_redirects", "_headers", "_routes.json", ".well-known"];

const hashedAssets = [
  { src: "styles.css", ref: "styles.css" },
  { src: "script.js", ref: "script.js" },
  { src: "boot.js", ref: "boot.js" },
  { src: "docs.js", ref: "docs.js" },
  { src: "brand-marks.js", ref: "brand-marks.js" },
  { src: "models-band.js", ref: "models-band.js" },
  { src: "models-band.css", ref: "models-band.css" },
  { src: "404.js", ref: "404.js" },
];

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

// A directory of their own so `_headers` can pin them for a year without freezing /app's unhashed files.
const assetDir = "assets";

const result = await build({
  entryPoints: hashedAssets.map((a) => a.src),
  outdir: path.join(outDir, assetDir),
  bundle: false,
  minify: true,
  entryNames: "[name]-[hash]",
  metafile: true,
});

const rename = new Map();
for (const [outPath, meta] of Object.entries(result.metafile.outputs)) {
  if (meta.entryPoint) {
    rename.set(meta.entryPoint, path.basename(outPath));
  }
}

const site = await loadSite();
const { runtime: runtimeStrings, slugs, sources } = site;

const { BOT_PRO_MODELS } = await import("./functions/api/bot.js");
const modelsFallback = (() => {
  const models = [];
  const groups = [];
  const bySlug = new Map();
  for (const [key, m] of Object.entries(BOT_PRO_MODELS)) {
    if (m.priced === false || !m.label) continue;
    const authorSlug = String(m.model || "").replace(/^@cf\//, "").split("/")[0].toLowerCase();
    models.push({ key, label: m.label, authorSlug, priced: true });
    if (!bySlug.has(authorSlug)) {
      const group = { author: m.author || authorSlug, authorSlug, keys: [] };
      bySlug.set(authorSlug, group);
      groups.push(group);
    }
    bySlug.get(authorSlug).keys.push(key);
  }
  return JSON.stringify({ models, groups }).replaceAll("&", "&amp;").replaceAll('"', "&quot;");
})();

// Absolute, so a page served from /es/terms/ still resolves them.
const documents = site.documents.map((doc) => {
  let html = doc.html.replace('data-models-fallback=""', `data-models-fallback="${modelsFallback}"`);
  for (const asset of hashedAssets) {
    const hashed = rename.get(asset.src);
    if (!hashed) throw new Error(`No hashed output for ${asset.src}`);
    html = html.replaceAll(`"${asset.ref}"`, `"/${assetDir}/${hashed}"`);
  }
  return { ...doc, html };
});

// A language ships only when its cache covers every site string; a half-English page is worse than none.
const available = new Set();
const partial = [];
const caches = new Map();
// Error pages are gated on their own strings, so they need every cache.
const everyCache = new Map();
for (const lang of TRANSLATED_LANGUAGES) {
  const cache = await loadCache(lang.code);
  everyCache.set(lang.code, cache);
  const have = sources.filter((s) => typeof cache[s] === "string").length;
  if (have === 0) continue;
  if (have < sources.length) {
    partial.push(`${lang.code} (${have}/${sources.length})`);
    continue;
  }
  caches.set(lang.code, cache);
  available.add(lang.code);
}

// Only the landing page carries the runtime string table, for the demo chat.
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

const sitemaps = renderSitemap(available, slugs, ["/app"]);
for (const file of sitemaps) {
  const out = path.join(outDir, file.path);
  await mkdir(path.dirname(out), { recursive: true });
  await writeFile(out, file.xml);
}

await writeFile(path.join(outDir, "llms.txt"), renderLlmsTxt(site.documents));

// English only: agents wanting another language can follow each page's hreflang set.
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

// Not a localized page (noindex, no sitemap), but it needs the hashed stylesheet name.
{
  let notFound = await readFile("404.html", "utf8");
  for (const asset of hashedAssets) {
    notFound = notFound.replaceAll(`"${asset.ref}"`, `"/${assetDir}/${rename.get(asset.src)}"`);
  }
  await writeFile(path.join(outDir, "404.html"), notFound);
}

// Self-contained, with no hashed assets or localized render, since this host is unreachable when they show.
const errorCss = await errorStyles();

// Minified here because these exact bytes are what `_headers` hashes.
const errorRuntime = (await transform(await readFile("errors/runtime.js", "utf8"), {
  loader: "js",
  minify: true,
})).code.trim();
const errorHash = `sha256-${createHash("sha256").update(errorRuntime).digest("base64")}`;

// An error page takes a language when its own strings are covered, unlike the site-wide gate.
const errorTranslations = (strings) => {
  const t = {};
  const rtl = [];
  for (const [code, cache] of everyCache) {
    const row = strings.map((s) => cache[s]);
    if (row.some((value) => typeof value !== "string")) continue;
    t[code] = row;
    if (isRtl(code)) rtl.push(code);
  }
  return { t, rtl };
};

await mkdir(path.join(outDir, "errors"), { recursive: true });
const errorLanguages = new Map();
for (const page of ERROR_PAGES) {
  let carried = 0;
  const { html } = renderErrorPage(
    page,
    { css: errorCss, runtime: errorRuntime },
    (strings) => {
      const table = errorTranslations(strings);
      carried = Object.keys(table.t).length;
      return table;
    }
  );
  await writeFile(path.join(outDir, "errors", page.file), html);
  errorLanguages.set(page.file, carried);
}

// Written into the shipped `_headers` because it changes whenever the script does.
{
  const headersFile = path.join(outDir, "_headers");
  const headers = await readFile(headersFile, "utf8");
  const placeholder = "'sha256-ERROR-PAGE-RUNTIME'";
  if (!headers.includes(placeholder)) {
    throw new Error(`_headers has no ${placeholder} for the error pages' script hash`);
  }
  await writeFile(headersFile, headers.replaceAll(placeholder, `'${errorHash}'`));
}


console.log("Build complete:");
for (const asset of hashedAssets) {
  console.log(`  ${asset.src} -> ${rename.get(asset.src)}`);
}
console.log(`  ${documents.length} pages: ${documents.map((d) => d.slug ?? "/").join(", ")}`);
// Derived from the cache, not checked in; the Flutter pack goes to its asset directory, where Flutter builds read.
{
  const app = await buildPacks((await appSources()).sources);
  await writePacks(path.join(outDir, "app", "i18n"), app);
  const flutter = await buildPacks((await flutterSources()).sources);
  await writePacks("flutter/assets/i18n", flutter);
  const say = (label, built) => `${label}: ${built.packs.size} languages`
    + (built.partial.length ? `, ${built.partial.length} incomplete` : "");
  console.log(`  ${say("app packs", app)}; ${say("flutter packs", flutter)}`);
}

{
  const appDir = path.join(outDir, "app");
  const swFile = path.join(appDir, "sw.js");
  const files = (await readdir(appDir, { recursive: true, withFileTypes: true }))
    .filter((d) => d.isFile())
    .map((d) => path.relative(appDir, path.join(d.parentPath ?? d.path, d.name)).split(path.sep).join("/"))
    .filter((rel) => rel !== "sw.js")
    .sort();
  const digest = createHash("sha256");
  for (const rel of files) {
    digest.update(rel + "\0");
    digest.update(createHash("sha256").update(await readFile(path.join(appDir, rel))).digest());
  }
  const version = digest.digest("hex").slice(0, 12);
  const sw = await readFile(swFile, "utf8");
  const cacheLine = /const CACHE = '[^']*';/;
  if (!cacheLine.test(sw)) throw new Error("app/sw.js has no `const CACHE = '...';` line to stamp");
  await writeFile(swFile, sw.replace(cacheLine, `const CACHE = 'nymbot-shell-${version}';`));
  console.log(`  app cache: nymbot-shell-${version} (${files.length} files)`);
}

console.log(`  sitemap.xml (index over ${sitemaps.length - 1} language sitemaps), llms.txt, llms-full.txt, 404.html`);
console.log(`  ${markdownPages} markdown twins (<page>.md)`);
console.log(
  `  ${ERROR_PAGES.length} error pages: ${ERROR_PAGES.map((p) => `errors/${p.file}`).join(", ")}`
);
{
  const carried = [...errorLanguages.values()];
  const low = Math.min(...carried);
  const high = Math.max(...carried);
  console.log(`    each carries its own translations: `
    + `${low === high ? high : `${low}-${high}`} languages, + English`);
}
console.log(`  ${sources.length} translatable strings (${runtimeStrings.length} from script.js)`);
console.log(`  languages published: ${available.size} (+ English at /)`);
if (partial.length > 0) {
  console.log(`  skipped, cache incomplete: ${partial.join(", ")}`);
  console.log(`  run 'npm run i18n' to fill them in`);
}
