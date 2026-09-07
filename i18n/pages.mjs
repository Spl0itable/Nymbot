// The documents the site is built from, and the complete English string set
// they need translated.
//
// One place decides what "the site" is, so the build, the translation sync and
// the tests can never disagree about which pages exist or which strings are
// due — a disagreement there would quietly publish a page in the wrong state.

import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';

import { checkOutline, docsStrings } from './docs.mjs';
import { scriptStrings, sourceStrings } from './extract.mjs';

const ROOT = new URL('../', import.meta.url).pathname;

/// The landing page is the site root; every document under pages/ gets a slug
/// directory of its own — pages/terms.html is served at /terms/ and /es/terms/.
///
/// Subdirectories nest: pages/docs.html is /docs/ and pages/docs/mesh.html is
/// /docs/mesh/, so a section can be a real directory of pages rather than a
/// flat list of hyphenated names.
const LANDING = 'index.html';
const PAGES_DIR = 'pages';

/// Every .html under pages/, depth-first, as a path relative to pages/.
///
/// Sorted by the slug each file will publish under rather than by file name, so
/// a section's own page comes immediately before the pages inside it —
/// docs.html, then docs/*. That ordering is what the sitemap and the build log
/// report, and it is the order a reader would expect to see them listed in.
async function pageFiles(dir = '') {
  const entries = await readdir(path.join(ROOT, PAGES_DIR, dir), { withFileTypes: true });
  const sorted = entries
    .filter((e) => e.isDirectory() || e.name.endsWith('.html'))
    .map((e) => ({ entry: e, key: e.name.replace(/\.html$/, '') }))
    // A directory and its index page share a key; the page comes first.
    .sort((a, b) => (a.key === b.key
      ? Number(a.entry.isDirectory()) - Number(b.entry.isDirectory())
      : (a.key < b.key ? -1 : 1)));
  const files = [];
  for (const { entry } of sorted) {
    const rel = dir ? `${dir}/${entry.name}` : entry.name;
    if (entry.isDirectory()) files.push(...await pageFiles(rel));
    else files.push(rel);
  }
  return files;
}

/// Every source document, landing page first, each as `{ file, slug, html }`.
/// `slug` is null for the landing page, and carries the directory for a nested
/// one (`docs/mesh`), which is exactly the path it publishes under.
export async function loadDocuments() {
  const names = await pageFiles();
  const files = [
    { file: LANDING, slug: null },
    ...names.map((name) => ({
      file: path.join(PAGES_DIR, name),
      slug: name.replace(/\.html$/, ''),
    })),
  ];
  return Promise.all(files.map(async (doc) => ({
    ...doc,
    html: await readFile(path.join(ROOT, doc.file), 'utf8'),
  })));
}

/// The whole site: its documents, the slugs they publish under, the copy
/// script.js writes into the page at runtime, and the union of every English
/// string all of that needs translated.
export async function loadSite() {
  const documents = await loadDocuments();
  const script = await readFile(path.join(ROOT, 'script.js'), 'utf8');
  const runtime = scriptStrings(script);
  // The knowledge base's nav, rail and pager are generated rather than written
  // into each document, so the extractor never sees their copy. Checking the
  // outline against the documents here means both facts — that the pages exist
  // and that their headings still match — are established before anything is
  // translated or rendered.
  checkOutline(documents);
  return {
    documents,
    slugs: documents.map((d) => d.slug).filter(Boolean),
    runtime,
    sources: [...new Set([
      ...documents.flatMap((d) => sourceStrings(d.html)),
      ...runtime,
      ...docsStrings(),
    ])],
  };
}
