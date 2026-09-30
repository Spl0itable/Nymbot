import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';

import { checkOutline, docsStrings } from './docs.mjs';
import { scriptStrings, sourceStrings } from './extract.mjs';

const ROOT = new URL('../', import.meta.url).pathname;

/// pages/terms.html publishes at /terms/ and /es/terms/; pages/docs/mesh.html nests at /docs/mesh/.
const LANDING = 'index.html';
const PAGES_DIR = 'pages';

/// Sorted by slug so a section's own page precedes the pages inside it.
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

/// `slug` is null for the landing page and carries the directory for a nested one (`docs/mesh`).
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

export async function loadSite() {
  const documents = await loadDocuments();
  const script = await readFile(path.join(ROOT, 'script.js'), 'utf8');
  const runtime = scriptStrings(script);
  // The generated docs chrome is invisible to the extractor, so the outline is checked against the documents here.
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
