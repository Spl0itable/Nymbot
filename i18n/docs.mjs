// The knowledge base at /docs/: its outline, and the shared chrome every page
// in it carries.
//
// One outline drives four things that would otherwise drift apart — the
// section nav, each page's "on this page" rail, the previous/next pager, and
// the breadcrumb. It is also the reason a docs page's source file is mostly
// prose: the chrome is filled in at build time from here, the way the language
// selector and the hreflang block already are.
//
// The outline is checked against the documents themselves (see `checkOutline`),
// so a heading renamed in the markup and not here fails the build instead of
// publishing a nav that points at anchors which no longer exist.

const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/// The knowledge base, in reading order.
///
/// `slug` is the path the page publishes under, minus the language prefix, and
/// matches its source file: `docs/mesh` is `pages/docs/mesh.html` at
/// `/docs/mesh/` and `/es/docs/mesh/`.
///
/// `nav` is the label in the sidebar — usually shorter than the page's own
/// `<h1>`, which the outline does not repeat. `sections` lists the page's `<h2>`
/// anchors in document order.
export const OUTLINE = [
  {
    group: 'Start here',
    pages: [
      {
        slug: 'docs',
        nav: 'Overview',
        sections: [
          { id: 'what-nymbot-is', title: 'What Nymbot is' },
          { id: 'how-to-read-this', title: 'How to read this' },
          { id: 'the-short-version', title: 'The short version' },
        ],
      },
      {
        slug: 'docs/getting-started',
        nav: 'Getting started',
        sections: [
          { id: 'open-it', title: 'Open Nymbot' },
          { id: 'your-key', title: 'Your key is your account' },
          { id: 'first-conversation', title: 'Your first conversation' },
          { id: 'buying-credits', title: 'Buying credits' },
        ],
      },
      {
        slug: 'docs/apps',
        nav: 'Apps and platforms',
        sections: [
          { id: 'web', title: 'The web app' },
          { id: 'mobile', title: 'Android and iOS' },
          { id: 'one-account', title: 'One account everywhere' },
          { id: 'nymchat', title: 'Nymbot inside Nymchat' },
        ],
      },
    ],
  },
  {
    group: 'Chatting',
    pages: [
      {
        slug: 'docs/chats',
        nav: 'Conversations',
        sections: [
          { id: 'separate-chats', title: 'Each chat is its own thread' },
          { id: 'titles', title: 'Where the titles come from' },
          { id: 'context', title: 'What Nymbot remembers' },
          { id: 'branching', title: 'Asking a question differently' },
          { id: 'queue', title: 'Typing while it is still writing' },
          { id: 'memory', title: 'What carries between chats' },
          { id: 'recall', title: 'Reading back what fell out' },
          { id: 'writing', title: 'Writing your message' },
          { id: 'attachments', title: 'Sending pictures' },
          { id: 'watching', title: 'Watching a reply as it is written' },
          { id: 'clearing', title: 'Clearing and deleting' },
          { id: 'ghost-mode', title: 'Ghost chats and auto-delete' },
        ],
      },
      {
        slug: 'docs/artifacts',
        nav: 'Artifacts and compare',
        sections: [
          { id: 'what-they-are', title: 'What an artifact is' },
          { id: 'versions', title: 'Editing and versions' },
          { id: 'compare', title: 'Asking two models at once' },
          { id: 'citations-and-patches', title: 'Citations and patches' },
        ],
      },
      {
        slug: 'docs/workspaces',
        nav: 'Workspaces and bots',
        sections: [
          { id: 'workspaces', title: 'Workspaces' },
          { id: 'knowledge-files', title: 'Knowledge files' },
          { id: 'bots', title: 'Bots' },
          { id: 'sharing-a-bot', title: 'Sharing and publishing one' },
          { id: 'scheduled', title: 'Scheduled prompts' },
        ],
      },
      {
        slug: 'docs/commands',
        nav: 'Command reference',
        sections: [
          { id: 'how-commands-work', title: 'How commands work' },
          { id: 'account', title: 'Account and credits' },
          { id: 'routing', title: 'Routing and tools' },
          { id: 'making-things', title: 'Making things' },
          { id: 'knowledge', title: 'Knowledge and utility' },
          { id: 'games', title: 'Games' },
        ],
      },
      {
        slug: 'docs/media',
        nav: 'Images and speech',
        sections: [
          { id: 'images', title: 'Generating images' },
          { id: 'generators', title: 'Choosing a generator' },
          { id: 'speech', title: 'Speech' },
          { id: 'pricing', title: 'What they cost' },
        ],
      },
    ],
  },
  {
    group: 'Models and credits',
    pages: [
      {
        slug: 'docs/credits',
        nav: 'Credits and pricing',
        sections: [
          { id: 'two-balances', title: 'Two balances' },
          { id: 'buying', title: 'Buying over Lightning' },
          { id: 'what-a-reply-costs', title: 'What a reply costs' },
          { id: 'gifting', title: 'Gifting and transferring' },
          { id: 'refunds', title: 'When nothing is charged' },
        ],
      },
      {
        slug: 'docs/models',
        nav: 'Models and routing',
        sections: [
          { id: 'standard', title: 'Standard: auto-routed' },
          { id: 'pro', title: 'Pro: pin a model' },
          { id: 'catalog', title: 'The model catalog' },
          { id: 'effort', title: 'Asking it to think harder' },
          { id: 'reasoning', title: 'Reasoning and vision' },
        ],
      },
      {
        slug: 'docs/git',
        nav: 'Working in a git repository',
        sections: [
          { id: 'connecting', title: 'Connecting a repository' },
          { id: 'what-it-can-do', title: 'What it can do' },
          { id: 'writes', title: 'Turning writes on' },
          { id: 'undo', title: 'Undoing what a run changed' },
          { id: 'cost', title: 'What a repo task costs' },
          { id: 'carrying-on', title: 'When a task runs out of room' },
          { id: 'token-safety', title: 'About that token' },
        ],
      },
    ],
  },
  {
    group: 'Privacy',
    pages: [
      {
        slug: 'docs/encryption',
        nav: 'Encryption',
        sections: [
          { id: 'end-to-end', title: 'End-to-end by default' },
          { id: 'gift-wraps', title: 'Gift wraps' },
          { id: 'post-quantum', title: 'Post-quantum hybrid' },
          { id: 'what-the-server-sees', title: 'What the server sees' },
        ],
      },
      {
        slug: 'docs/anonymous',
        nav: 'Anonymous mode',
        sections: [
          { id: 'the-gap', title: 'The gap it closes' },
          { id: 'throwaway-key', title: 'The throwaway key' },
          { id: 'vouchers', title: 'Blind credit vouchers' },
          { id: 'limits', title: 'What it does not hide' },
        ],
      },
      {
        slug: 'docs/identity',
        nav: 'Identity and login',
        sections: [
          { id: 'nsec', title: 'Keys, not accounts' },
          { id: 'signing-in', title: 'Ways to sign in' },
          { id: 'encryption-at-rest', title: 'Identity encryption' },
          { id: 'panic', title: 'Panic wipe' },
        ],
      },
    ],
  },
  {
    group: 'Under the hood',
    pages: [
      {
        slug: 'docs/protocol',
        nav: 'Protocol and events',
        sections: [
          { id: 'nostr', title: 'Nostr underneath' },
          { id: 'the-turn', title: 'One turn, end to end' },
          { id: 'ledger', title: 'The credit ledger' },
        ],
      },
      {
        slug: 'docs/troubleshooting',
        nav: 'Troubleshooting',
        sections: [
          { id: 'no-reply', title: 'The reply never arrives' },
          { id: 'credits-wrong', title: 'The balance looks wrong' },
          { id: 'history-missing', title: 'A conversation is missing' },
          { id: 'git-errors', title: 'The repository will not connect' },
          { id: 'locked-out', title: 'Locked out of an encrypted identity' },
        ],
      },
    ],
  },
  {
    // Pages that belong beside the knowledge base without being part of it.
    // `page` is a slug elsewhere on the site, so the link follows the reader's
    // language; `url` would be somewhere else entirely.
    group: 'Elsewhere',
    pages: [
      { nav: 'Terms of Service', page: 'terms' },
      { nav: 'Privacy Policy', page: 'privacy' },
      { nav: 'Contact', page: 'contact' },
      { nav: 'Nymchat', url: 'https://nymchat.app' },
    ],
  },
];

/// Every page in the knowledge base, in reading order. Plain links in the
/// outline are navigation, not pages: they have no headings, no place in the
/// pager, and nothing to check against a document.
export const DOCS_PAGES = OUTLINE
  .flatMap((g) => g.pages.map((p) => ({ ...p, group: g.group })))
  .filter((p) => p.slug);

const BY_SLUG = new Map(DOCS_PAGES.map((p) => [p.slug, p]));

/// Whether [slug] is a page in the knowledge base.
export const isDocsPage = (slug) => BY_SLUG.has(slug);

/// The chrome's own copy — the words that appear in the shell rather than in
/// any one document. Kept here so `loadSite` can send them for translation
/// along with the copy the extractor finds in the markup.
export const CHROME = {
  home: 'Back to Nymbot',
  title: 'Knowledge base',
  navLabel: 'Documentation',
  menu: 'Menu',
  search: 'Search the docs',
  noResults: 'Nothing matches that.',
  onThisPage: 'On this page',
  previous: 'Previous',
  next: 'Next',
  skip: 'Skip to the content',
};

/// Every English string the knowledge base's chrome needs translated: the
/// group headings, the sidebar labels, each page's section titles, and the
/// fixed copy above. The section titles are also the pages' own `<h2>` text,
/// so in practice they cost nothing extra — the cache is keyed by the English
/// string, not by where it was found.
export function docsStrings() {
  const out = Object.values(CHROME);
  for (const group of OUTLINE) {
    out.push(group.group);
    for (const page of group.pages) {
      out.push(page.nav);
      for (const section of page.sections ?? []) out.push(section.title);
    }
  }
  return [...new Set(out)];
}

/// The path a docs page publishes under, for the language being rendered.
/// `pathFor` is passed in rather than imported so this module stays about the
/// outline and nothing else.
const href = (pathFor, lang, slug) => pathFor(lang, slug);

/// The skip link and the sticky top bar.
export function renderTopbar(t) {
  return `        <a class="docs-skip" href="#docs-main">${escapeHtml(t(CHROME.skip))}</a>
        <header class="docs-topbar">
            <a href="/" class="docs-home"><span class="docs-home-mark" aria-hidden="true">&larr;</span> <span class="docs-home-full">${escapeHtml(t(CHROME.home))}</span></a>
            <button type="button" class="docs-nav-toggle" aria-expanded="false" aria-controls="docs-nav">
                <span aria-hidden="true">&#9776;</span> ${escapeHtml(t(CHROME.menu))}
            </button>
            <div class="docs-search-wrap">
                <input type="search" id="docs-search" class="docs-search" autocomplete="off" placeholder="${escapeHtml(t(CHROME.search))}" aria-label="${escapeHtml(t(CHROME.search))}">
            </div>
        </header>`;
}

/// The section nav.
///
/// Every page carries the WHOLE tree, each page's own headings included. That
/// is what lets the filter box in the top bar act as a search across the entire
/// knowledge base without an index to build, ship or keep translated — and the
/// stylesheet hides the headings that belong to other pages until a filter is
/// actually running.
export function renderNav(t, pathFor, lang, currentSlug) {
  const groups = OUTLINE.map((group) => {
    const items = group.pages.map((page) => {
      if (!page.slug) {
        const target = page.url || href(pathFor, lang, page.page);
        const outbound = page.url ? ' target="_blank" rel="noopener"' : '';
        return `                <li><a href="${target}"${outbound}>${escapeHtml(t(page.nav))}</a></li>`;
      }
      const current = page.slug === currentSlug;
      const sub = page.sections.map((section) =>
        `                        <li><a href="${href(pathFor, lang, page.slug)}#${section.id}">${escapeHtml(t(section.title))}</a></li>`).join('\n');
      return `                <li${current ? ' class="is-current"' : ''}>
                    <a href="${href(pathFor, lang, page.slug)}"${current ? ' aria-current="page"' : ''}>${escapeHtml(t(page.nav))}</a>
                    <ul class="docs-nav-sub">
${sub}
                    </ul>
                </li>`;
    }).join('\n');
    return `            <div class="docs-nav-group">
                <p class="docs-nav-title">${escapeHtml(t(group.group))}</p>
                <ul>
${items}
                </ul>
            </div>`;
  }).join('\n');

  return `        <nav id="docs-nav" class="docs-nav" aria-label="${escapeHtml(t(CHROME.navLabel))}">
${groups}
            <p class="docs-nav-empty" hidden>${escapeHtml(t(CHROME.noResults))}</p>
        </nav>`;
}

/// The breadcrumb above the article's title.
export function renderCrumbs(t, pathFor, lang, slug) {
  const page = BY_SLUG.get(slug);
  const trail = [`<a href="${href(pathFor, lang, 'docs')}">${escapeHtml(t(CHROME.title))}</a>`];
  if (slug !== 'docs') trail.push(escapeHtml(t(page.group)));
  return `        <p class="docs-crumbs">${trail.join(' <span aria-hidden="true">/</span> ')}</p>`;
}

/// The "on this page" rail, built from the same section list as the nav.
export function renderToc(t, slug) {
  const page = BY_SLUG.get(slug);
  const items = page.sections.map((section) =>
    `                <li><a href="#${section.id}">${escapeHtml(t(section.title))}</a></li>`).join('\n');
  return `        <aside class="docs-toc" aria-label="${escapeHtml(t(CHROME.onThisPage))}">
            <p class="docs-toc-title">${escapeHtml(t(CHROME.onThisPage))}</p>
            <ul>
${items}
            </ul>
        </aside>`;
}

/// Previous and next in reading order. The first page has no previous and the
/// last has no next, so the pager renders one side rather than a dead link.
export function renderPager(t, pathFor, lang, slug) {
  const index = DOCS_PAGES.findIndex((p) => p.slug === slug);
  const prev = DOCS_PAGES[index - 1];
  const next = DOCS_PAGES[index + 1];
  if (!prev && !next) return '';
  const side = (page, kind, label) => (page
    ? `            <a class="docs-pager-${kind}" href="${href(pathFor, lang, page.slug)}" rel="${kind}">
                <span class="docs-pager-label">${escapeHtml(t(label))}</span>
                <span class="docs-pager-title">${escapeHtml(t(page.nav))}</span>
            </a>`
    : '');
  return `        <nav class="docs-pager" aria-label="${escapeHtml(t(CHROME.title))}">
${[side(prev, 'prev', CHROME.previous), side(next, 'next', CHROME.next)].filter(Boolean).join('\n')}
        </nav>`;
}

/// Every `<h2 id="...">Title</h2>` in a document, in order.
function documentSections(html) {
  const out = [];
  const re = /<h2\b[^>]*\bid="([^"]+)"[^>]*>([\s\S]*?)<\/h2>/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    out.push({ id: m[1], title: m[2].replace(/<[^>]*>/g, '').trim() });
  }
  return out;
}

/// The outline is duplicated information: the nav, the rail and the pager are
/// generated from it, while the anchors and headings they point at live in the
/// documents. A mismatch would ship a table of contents linking to anchors that
/// are not there, which is exactly the sort of breakage nobody notices, so it
/// fails the build instead. Throws with the first disagreement it finds.
export function checkOutline(documents) {
  const bySlug = new Map(documents.map((d) => [d.slug, d]));
  for (const page of DOCS_PAGES) {
    const doc = bySlug.get(page.slug);
    if (!doc) throw new Error(`docs outline: no page source for ${page.slug} (expected pages/${page.slug}.html)`);
    const found = documentSections(doc.html);
    const expected = page.sections;
    const show = (list) => list.map((s) => `${s.id}:${s.title}`).join(', ') || '(none)';
    if (found.length !== expected.length
      || found.some((s, i) => s.id !== expected[i].id || s.title !== expected[i].title)) {
      throw new Error(
        `docs outline: ${page.slug} headings do not match the outline\n`
        + `  outline:  ${show(expected)}\n`
        + `  document: ${show(found)}`);
    }
  }
  for (const doc of documents) {
    if (doc.slug && doc.slug.startsWith('docs') && !BY_SLUG.has(doc.slug)) {
      throw new Error(`docs outline: pages/${doc.slug}.html is not listed in the outline, so nothing links to it`);
    }
  }

  // Pages in the knowledge base link to each other's headings constantly, and a
  // heading renamed on one page silently breaks every link into it from the
  // others — a dead link that still looks like a link. The outline knows every
  // page and every anchor there is, so check them here rather than finding out
  // from a reader.
  const anchors = new Set(DOCS_PAGES.flatMap((p) => p.sections.map((s) => `${p.slug}#${s.id}`)));
  for (const doc of documents) {
    for (const match of doc.html.matchAll(/href="\/(docs(?:\/[\w-]+)?)\/(#([\w-]+))?"/g)) {
      const [, slug, , id] = match;
      const where = `pages/${doc.slug ?? 'index'}.html`;
      if (!BY_SLUG.has(slug)) {
        throw new Error(`docs outline: ${where} links to /${slug}/, which is not a page in the knowledge base`);
      }
      if (id && !anchors.has(`${slug}#${id}`)) {
        throw new Error(`docs outline: ${where} links to /${slug}/#${id}, which is not a heading on that page`);
      }
    }
  }
}
