// Error pages inline a subset of styles.css: Cloudflare serves stored copies when the origin is unreachable.
import { readFile } from "node:fs/promises";

import { transform } from "esbuild";

// Prefix match, so `.legal-page h1`, `.docs-card:hover` and every `.nf-*` come along.
const KEEP = [
  "*",
  ":root",
  "body",
  "footer",
  /^\.grid-bg\b/,
  /^\.legal-page\b/,
  /^\.docs-cards?\b/,
  /^\.docs-card-/,
  /^\.nf\b/,
  /^\.nf-/,
];

const KEEP_KEYFRAMES = new Set(["gridMove", "nf-blink"]);

// Renaming or deleting any of these in styles.css must fail the build.
const REQUIRED = [
  ":root",
  "body",
  "footer",
  ".grid-bg",
  ".legal-page",
  ".docs-card",
  ".nf-art",
  ".nf-box",
  ".nf-title",
  ".nf-quip",
  ".nf-term",
];

// Enough for a flat stylesheet; comments are stripped first so a brace in prose cannot break the counting.
function blocks(css) {
  const found = [];
  let i = 0;
  while (i < css.length) {
    const open = css.indexOf("{", i);
    if (open === -1) break;
    const prelude = css.slice(i, open).trim();
    let depth = 1;
    let j = open + 1;
    while (j < css.length && depth > 0) {
      if (css[j] === "{") depth++;
      else if (css[j] === "}") depth--;
      j++;
    }
    found.push({ prelude, body: css.slice(open + 1, j - 1) });
    i = j;
  }
  return found;
}

const selectors = (prelude) => prelude.split(",").map((s) => s.trim());

// A data URI in `url(...)` contains semicolons that are not separators.
function declarations(body) {
  const out = [];
  let depth = 0;
  let quote = null;
  let start = 0;
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (quote) {
      if (ch === quote && body[i - 1] !== "\\") quote = null;
    } else if (ch === '"' || ch === "'") quote = ch;
    else if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (ch === ";" && depth === 0) {
      out.push(body.slice(start, i));
      start = i + 1;
    }
  }
  out.push(body.slice(start));
  return out.map((d) => d.trim()).filter(Boolean);
}

// Declarations referencing files are dropped, which also cuts the inlined hero SVGs from the palette.
const withoutFiles = (body) =>
  declarations(body)
    .filter((decl) => !decl.includes("url("))
    .join(";");

// `[dir='rtl']` overrides are matched as part of the rule they correct.
const RTL_PREFIX = /^\[dir=['"]rtl['"]\]\s+/;

const wanted = (prelude) =>
  selectors(prelude).some((sel) => {
    const bare = sel.replace(RTL_PREFIX, "");
    return KEEP.some((rule) => (rule instanceof RegExp ? rule.test(bare) : rule === bare));
  });

export async function errorStyles() {
  const source = (await readFile("styles.css", "utf8")).replace(
    /\/\*[\s\S]*?\*\//g,
    ""
  );

  const kept = [];
  const seen = new Set();

  const take = (block) => {
    for (const sel of selectors(block.prelude)) seen.add(sel);
    kept.push(`${block.prelude} {${withoutFiles(block.body)}}`);
  };

  for (const block of blocks(source)) {
    if (!block.prelude.startsWith("@")) {
      if (wanted(block.prelude)) take(block);
      continue;
    }

    // `@keyframes` is all or nothing.
    const keyframes = block.prelude.match(/^@keyframes\s+(\S+)$/);
    if (keyframes) {
      if (KEEP_KEYFRAMES.has(keyframes[1])) kept.push(`${block.prelude} {${block.body}}`);
      continue;
    }

    if (/^@(media|supports)\b/.test(block.prelude)) {
      const inner = [];
      for (const child of blocks(block.body)) {
        if (child.prelude.startsWith("@") || !wanted(child.prelude)) continue;
        for (const sel of selectors(child.prelude)) seen.add(sel);
        inner.push(`${child.prelude} {${withoutFiles(child.body)}}`);
      }
      if (inner.length > 0) kept.push(`${block.prelude} {\n${inner.join("\n")}\n}`);
    }
  }

  // A whole-component match counts, so `.nf-title` is satisfied by `.nf .nf-title`.
  const present = (sel) => {
    const pattern = new RegExp(
      `(^|[\\s>+~])${sel.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}($|[\\s>+~:.,\\[])`
    );
    return [...seen].some((kept) => pattern.test(kept));
  };
  const missing = REQUIRED.filter((sel) => !present(sel));
  if (missing.length > 0) {
    throw new Error(
      `styles.css no longer has ${missing.join(", ")} — the error pages are styled from it`
    );
  }

  const { code } = await transform(kept.join("\n"), {
    loader: "css",
    minify: true,
  });
  return code;
}
