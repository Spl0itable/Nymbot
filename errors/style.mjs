// The error pages carry their own stylesheet, inline, and link to nothing at
// all — no CSS file, no favicon, no script.
//
// That is not a preference, it is what the pages are for. Cloudflare fetches
// each one once and stores it, then serves it in the moments when this origin
// cannot be reached: a 5xx, a DNS failure, a challenge. Anything a stored page
// still has to fetch from nymchat.app is exactly what is unavailable when the
// page is shown, so an error page that links its stylesheet is an unstyled wall
// of text precisely when it is needed. Custom error rules solve the same
// problem by inlining every referenced asset into the stored copy, which would
// mean shipping all 180 KB of `styles.css` on every blocked request.
//
// So the look is taken from `styles.css` rather than rewritten here: this pulls
// out the blocks the error markup uses — the palette, the page frame, the link
// cards, the whole `.nf` hero — and nothing else, and minifies the result. One
// stylesheet stays the source of truth, and the pages come out around 6 KB.
import { readFile } from "node:fs/promises";

import { transform } from "esbuild";

// A block is kept when any of its selectors matches. Prefixes rather than exact
// names, so `.legal-page h1`, `.docs-card:hover` and every `.nf-*` come along
// with the rule they belong to.
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

// Renaming or deleting any of these in styles.css should fail the build, not
// quietly publish an error page with no styling on it.
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

// Enough of a CSS parser for a stylesheet that is a flat list of rules and
// at-rules, which is what styles.css is. Comments go first so that a brace
// inside prose cannot throw off the brace counting.
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

// Declarations, split on the semicolons that are actually separators — a data
// URI in a `url(...)` is full of ones that are not.
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

// An error page references no image, no font and no other file — that is the
// whole point of it. So any declaration pointing at one is dropped, which is
// also what keeps the palette small: two of the custom properties in `:root`
// hold the landing page's hero illustration as an inlined SVG, and those two
// are 140 KB of the 148 KB that a naive copy of the palette would cost.
const withoutFiles = (body) =>
  declarations(body)
    .filter((decl) => !decl.includes("url("))
    .join(";");

const wanted = (prelude) =>
  selectors(prelude).some((sel) =>
    KEEP.some((rule) => (rule instanceof RegExp ? rule.test(sel) : rule === sel))
  );

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

    // `@keyframes` is all or nothing: its children are percentages, not
    // selectors, and an animation without its frames is worse than neither.
    const keyframes = block.prelude.match(/^@keyframes\s+(\S+)$/);
    if (keyframes) {
      if (KEEP_KEYFRAMES.has(keyframes[1])) kept.push(`${block.prelude} {${block.body}}`);
      continue;
    }

    // `@media` and `@supports` carry the light palette and the responsive
    // overrides. Descend, and drop the wrapper when nothing inside it survives.
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

  // A required selector counts as present when it turns up as a whole
  // component of a kept selector, so `.nf-title` is satisfied by
  // `.nf .nf-title` and `.docs-card` by `.docs-card:hover`.
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
