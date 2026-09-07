// The site as one markdown file, for agents.
//
// `/llms.txt` is a small convention: a markdown index at a well-known path that
// tells a language model what a site contains and where each part lives, so it
// does not have to crawl and strip HTML to find out. Everything here is derived
// from the documents themselves — their own titles and descriptions, and the
// knowledge base's own outline — so it cannot drift from the site the way a
// hand-written summary would.
//
// English only, and deliberately: the convention describes one document at one
// path, and an agent that wants another language can follow the hreflang set on
// any page.

import { OUTLINE } from './docs.mjs';
import { pathFor } from './languages.mjs';
import { articleMarkdown } from './markdown.mjs';

const SITE = 'https://nymbot.ai';

const decode = (s) => String(s)
  .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&mdash;/g, '—')
  .replace(/&ndash;/g, '–').replace(/&bull;/g, '•').replace(/&times;/g, '×')
  .replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

const meta = (html, re) => {
  const m = re.exec(html);
  return m ? decode(m[1]).trim() : '';
};

/// Title without the site suffix — `Anonymous mode`, not
/// `Anonymous mode - Nymbot Knowledge Base`.
const shortTitle = (html) => meta(html, /<title>([^<]*)<\/title>/i)
  .replace(/\s*-\s*Nymbot Knowledge Base$/, '')
  .replace(/\s*-\s*Nymbot$/, '');

const describe = (html) => meta(html, /<meta name="description" content="([^"]*)">/i);

/// One markdown line per page.
const entry = (slug, html) =>
  `- [${shortTitle(html)}](${SITE}${pathFor('en', slug)}): ${describe(html)}`;

/// The finished `/llms.txt` for [documents].
///
/// The knowledge base is listed in its reading order rather than
/// alphabetically, because that order is the argument the pages make together.
export function renderLlmsTxt(documents) {
  const bySlug = new Map(documents.map((d) => [d.slug, d]));
  const landing = bySlug.get(null);

  const lines = [
    '# Nymbot',
    '',
    `> ${describe(landing.html)} It is a Progressive Web App and a pair of native Android and iOS apps, built on the Nostr protocol. There is no account and no registration: an identity is a keypair generated on the device. Messages are end-to-end encrypted with NIP-17 gift wraps, hybridized with ML-KEM so captured traffic stays unreadable. Replies are paid for with credits bought over the Bitcoin Lightning Network rather than by subscription; an anonymous mode moves the conversation onto a throwaway key and carries credits across as blind Chaumian vouchers, so the service can bill a message it cannot attribute. It shares one identity and one balance with the Nymchat messenger.`,
    '',
    'This file follows the llms.txt convention. Every page below is also served as',
    'ordinary HTML, and every page carries an hreflang set covering the languages the',
    'site is published in.',
    '',
    '## Knowledge base',
    '',
    'A page per topic, written against the app’s source rather than its feature list.',
    '',
  ];

  for (const group of OUTLINE) {
    const pages = group.pages.filter((p) => p.slug && bySlug.has(p.slug));
    if (pages.length === 0) continue;
    lines.push(`### ${group.group}`, '');
    for (const page of pages) lines.push(entry(page.slug, bySlug.get(page.slug).html));
    lines.push('');
  }

  lines.push('## The site', '');
  lines.push(entry(null, landing.html));
  for (const slug of ['terms', 'privacy', 'dmca', 'contact']) {
    if (bySlug.has(slug)) lines.push(entry(slug, bySlug.get(slug).html));
  }

  lines.push(
    '',
    '## Elsewhere',
    '',
    '- [Source code](https://github.com/Spl0itable/nymbot): the web app, and the Flutter app for Android and iOS, under AGPL-3.0.',
    `- [Open Nymbot](${SITE}/app): the running web app. It generates a key on the device and needs no sign-up.`,
    '- [Nymchat](https://nymchat.app): the messenger Nymbot is also built into, sharing one identity and one balance.',
    '',
    '## Getting this as markdown',
    '',
    `- [${SITE}/llms-full.txt](${SITE}/llms-full.txt): the entire knowledge base as one markdown file.`,
    '- Every page above also has a markdown twin at the same path with `.md`',
    `  instead of the trailing slash — ${SITE}/docs/anonymous/ is also`,
    `  ${SITE}/docs/anonymous.md.`,
    '',
  );
  return lines.join('\n');
}

/// The whole knowledge base as one markdown document.
///
/// Same content as the pages, in the same reading order, so an agent can take
/// the lot in a single fetch instead of fourteen. Generated from the
/// documents, so it says exactly what they say.
export function renderLlmsFull(documents) {
  const bySlug = new Map(documents.map((d) => [d.slug, d]));
  const landing = bySlug.get(null);
  const parts = [
    '# Nymbot — knowledge base',
    '',
    `> ${describe(landing.html)}`,
    '',
    'The complete knowledge base from ' + SITE + '/docs/, in reading order.',
    'Generated from the pages themselves. Each section below is one page, and the',
    'URL above it is where that page lives.',
    '',
  ];
  for (const group of OUTLINE) {
    for (const page of group.pages) {
      if (!page.slug || !bySlug.has(page.slug)) continue;
      parts.push('---', '', `Source: ${SITE}${pathFor('en', page.slug)}`, '');
      parts.push(articleMarkdown(bySlug.get(page.slug).html, { site: SITE }).trim(), '');
    }
  }
  return parts.join('\n');
}
