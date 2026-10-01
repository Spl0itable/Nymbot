// The outline drives the nav, rail, pager and breadcrumb; `checkOutline` fails the build on drift.

const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/// `slug` matches the source file (`docs/mesh` is pages/docs/mesh.html); `sections` lists `<h2>` anchors in order.
export const OUTLINE = [
  {
    group: 'Start here',
    pages: [
      {
        slug: 'docs',
        nav: 'Overview',
        sections: [
          { id: 'what-nymbot-is', title: 'What is Nymbot' },
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
          { id: 'reply-notifications', title: 'Reply notifications' },
          { id: 'one-account', title: 'One account everywhere' },
          { id: 'notices', title: 'Announcements' },
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
          { id: 'parallel', title: 'Several requests at once' },
          { id: 'background', title: 'Letting a task carry on without the app' },
          { id: 'schedules', title: 'Scheduled prompts' },
          { id: 'memory', title: 'What carries between chats' },
          { id: 'recall', title: 'Reading back what fell out' },
          { id: 'writing', title: 'Writing your message' },
          { id: 'attachments', title: 'Sending pictures' },
          { id: 'watching', title: 'Watching a reply as it is written' },
          { id: 'follow-ups', title: 'Next steps and sources' },
          { id: 'sharing', title: 'Sharing a chat by link' },
          { id: 'clearing', title: 'Clearing and deleting' },
          { id: 'ghost-mode', title: 'Ghost chats and auto-delete' },
        ],
      },
      {
        slug: 'docs/documents',
        nav: 'PDFs and long documents',
        sections: [
          { id: 'attaching', title: 'What you can attach' },
          { id: 'searched', title: 'Long documents are searched, not sent whole' },
          { id: 'pages-used', title: 'Seeing which pages were used' },
          { id: 'limits', title: 'Limits' },
        ],
      },
      {
        slug: 'docs/artifacts',
        nav: 'Artifacts and compare',
        sections: [
          { id: 'what-they-are', title: 'What is an artifact' },
          { id: 'versions', title: 'Editing and versions' },
          { id: 'files', title: 'Files a reply makes' },
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
        nav: 'Images, video and speech',
        sections: [
          { id: 'images', title: 'Generating images' },
          { id: 'generators', title: 'Choosing a generator' },
          { id: 'pinning', title: 'Pinning a generator' },
          { id: 'editing', title: 'Editing a picture' },
          { id: 'video', title: 'Video' },
          { id: 'speech', title: 'Speech' },
          { id: 'pricing', title: 'What they cost' },
        ],
      },
    ],
  },
  {
    group: 'Research and tools',
    pages: [
      {
        slug: 'docs/research',
        nav: 'Deep research',
        sections: [
          { id: 'starting', title: 'Starting a research task' },
          { id: 'what-it-does', title: 'What it does' },
          { id: 'the-report', title: 'The report' },
          { id: 'cost', title: 'What it costs' },
          { id: 'tasks-pane', title: 'The Tasks pane' },
        ],
      },
      {
        slug: 'docs/connectors',
        nav: 'Connectors (MCP)',
        sections: [
          { id: 'what-they-are', title: 'What is a connector' },
          { id: 'adding', title: 'Adding one' },
          { id: 'approving', title: 'Approving a tool call' },
          { id: 'always-allow', title: 'Letting a tool run without asking' },
          { id: 'secrets', title: 'Where the secrets live' },
        ],
      },
      {
        slug: 'docs/team-mode',
        nav: 'Team mode',
        sections: [
          { id: 'what-it-is', title: 'What is Team mode' },
          { id: 'research', title: 'A team on deep research' },
          { id: 'repositories', title: 'A team in a repository' },
          { id: 'approvals', title: 'Connectors and server runs' },
          { id: 'cost', title: 'What it costs' },
          { id: 'progress', title: 'Watching the team work' },
          { id: 'tasks-pane', title: 'The Tasks pane' },
        ],
      },
    ],
  },
  {
    group: 'Code',
    pages: [
      {
        slug: 'docs/git',
        nav: 'Working in a git repository',
        sections: [
          { id: 'connecting', title: 'Connecting a repository' },
          { id: 'ngit', title: 'Repositories announced on Nostr' },
          { id: 'what-it-can-do', title: 'What it can do' },
          { id: 'writes', title: 'Turning writes on' },
          { id: 'task-branches', title: 'A branch for each task' },
          { id: 'undo', title: 'Undoing what a run changed' },
          { id: 'cost', title: 'What a repo task costs' },
          { id: 'carrying-on', title: 'When a task runs out of room' },
          { id: 'token-safety', title: 'About that token' },
        ],
      },
      {
        slug: 'docs/sandbox',
        nav: 'Running code on your device',
        sections: [
          { id: 'run-button', title: 'The Run button' },
          { id: 'what-comes-back', title: 'What comes back' },
          { id: 'files', title: 'Using attached files' },
          { id: 'limits', title: 'What it cannot do' },
        ],
      },
      {
        slug: 'docs/server-runs',
        nav: 'Running code on a server',
        sections: [
          { id: 'what-it-is', title: 'What is a server run' },
          { id: 'code-blocks', title: 'Running a code block' },
          { id: 'images', title: 'Languages and images' },
          { id: 'price', title: 'What it costs' },
          { id: 'in-a-repository', title: 'Server runs in a repository' },
          { id: 'isolation', title: 'What is isolated' },
          { id: 'limits', title: 'Limits' },
          { id: 'tasks-pane', title: 'The Tasks pane' },
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
          { id: 'free', title: 'The free daily allowance' },
          { id: 'two-balances', title: 'Two balances' },
          { id: 'buying', title: 'Buying over Lightning' },
          { id: 'what-a-reply-costs', title: 'What a reply costs' },
          { id: 'server-time', title: 'Server runs, research and Team mode' },
          { id: 'caps', title: 'Spending caps' },
          { id: 'every-model', title: 'Every model and what it costs' },
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
          { id: 'mentions', title: 'Asking one model with @' },
          { id: 'catalog', title: 'The model catalog' },
          { id: 'effort', title: 'Asking it to think harder' },
          { id: 'reasoning', title: 'Reasoning and vision' },
        ],
      },
    ],
  },
  {
    group: 'Developers',
    pages: [
      {
        slug: 'docs/api',
        nav: 'API overview',
        sections: [
          { id: 'what-it-is', title: 'What the API is' },
          { id: 'base-urls', title: 'Base URLs' },
          { id: 'keys', title: 'API keys' },
          { id: 'authentication', title: 'Authenticating a request' },
          { id: 'first-request', title: 'Your first request' },
          { id: 'billing', title: 'What a request costs' },
          { id: 'errors', title: 'Errors' },
          { id: 'limits', title: 'Limits' },
          { id: 'privacy', title: 'What the API can see' },
          { id: 'endpoints', title: 'Every endpoint' },
        ],
      },
      {
        slug: 'docs/api-chat',
        nav: 'Chat, Responses and Messages',
        sections: [
          { id: 'chat-completions', title: 'Chat Completions' },
          { id: 'streaming', title: 'Streaming' },
          { id: 'tools', title: 'Tool calls' },
          { id: 'vision', title: 'Pictures in a request' },
          { id: 'reasoning', title: 'Reasoning' },
          { id: 'suffixes', title: 'Model suffixes' },
          { id: 'web-search', title: 'Web search' },
          { id: 'responses', title: 'Responses API' },
          { id: 'messages', title: 'Anthropic Messages' },
          { id: 'count-tokens', title: 'Counting tokens' },
          { id: 'models', title: 'Listing models' },
        ],
      },
      {
        slug: 'docs/api-media',
        nav: 'Images, audio and embeddings',
        sections: [
          { id: 'images', title: 'Generating images' },
          { id: 'image-edits', title: 'Editing images' },
          { id: 'video', title: 'Video' },
          { id: 'speech', title: 'Text to speech' },
          { id: 'voices', title: 'Audio models and voices' },
          { id: 'transcription', title: 'Speech to text' },
          { id: 'embeddings', title: 'Embeddings' },
        ],
      },
      {
        slug: 'docs/api-account',
        nav: 'Balance, top-ups and keys',
        sections: [
          { id: 'balance', title: 'Checking the balance' },
          { id: 'payment-methods', title: 'Payment methods' },
          { id: 'topup', title: 'Topping up over Lightning' },
          { id: 'topup-status', title: 'Checking a top-up' },
          { id: 'history', title: 'Query history' },
          { id: 'nip98', title: 'Signing account requests' },
          { id: 'account', title: 'The account summary' },
          { id: 'key-endpoints', title: 'Managing keys' },
          { id: 'nwc', title: 'NWC auto-top-up' },
          { id: 'l402', title: 'Paying per request without a key' },
        ],
      },
      {
        slug: 'docs/api-integrations',
        nav: 'Tools and SDKs',
        sections: [
          { id: 'openai-sdk', title: 'OpenAI SDK' },
          { id: 'anthropic-sdk', title: 'Anthropic SDK' },
          { id: 'aider', title: 'Aider' },
          { id: 'openwebui', title: 'Open WebUI' },
          { id: 'goose', title: 'Goose' },
          { id: 'curl', title: 'Plain HTTP' },
        ],
      },
      {
        slug: 'docs/api-tools',
        nav: 'Coding tools',
        sections: [
          { id: 'before-you-start', title: 'Before you start' },
          { id: 'claude-code', title: 'Claude Code' },
          { id: 'claude-code-vscode', title: 'Claude Code in VS Code' },
          { id: 'codex', title: 'Codex CLI' },
          { id: 'cline', title: 'Cline' },
          { id: 'kilo-code', title: 'Kilo Code' },
          { id: 'roo-code', title: 'Roo Code' },
          { id: 'continue', title: 'Continue' },
          { id: 'privacy', title: 'What the tools send' },
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
          { id: 'unlock-methods', title: 'Passphrase, passkey or biometrics' },
          { id: 'synced-settings', title: 'What syncs between your devices' },
          { id: 'panic', title: 'Wiping this device' },
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
          { id: 'server-run-errors', title: 'A server run did not start' },
          { id: 'connector-errors', title: 'A connector will not connect' },
          { id: 'locked-out', title: 'Locked out of an encrypted identity' },
        ],
      },
    ],
  },
  {
    // `page` is a site slug, so the link follows the reader's language; `url` is external.
    group: 'Elsewhere',
    pages: [
      { nav: 'Press kit and brand', page: 'brand' },
      { nav: 'Press release', page: 'press-release' },
      { nav: 'Terms of Service', page: 'terms' },
      { nav: 'Privacy Policy', page: 'privacy' },
      { nav: 'Contact', page: 'contact' },
      { nav: 'Nymchat', url: 'https://nymchat.app' },
    ],
  },
];

/// Plain links in the outline are navigation, not pages.
export const DOCS_PAGES = OUTLINE
  .flatMap((g) => g.pages.map((p) => ({ ...p, group: g.group })))
  .filter((p) => p.slug);

const BY_SLUG = new Map(DOCS_PAGES.map((p) => [p.slug, p]));

export const isDocsPage = (slug) => BY_SLUG.has(slug);

/// Shell copy, sent for translation alongside the extracted markup.
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

const href = (pathFor, lang, slug) => pathFor(lang, slug);

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

/// Every page carries the whole tree so the filter box searches the knowledge base without an index.
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

export function renderCrumbs(t, pathFor, lang, slug) {
  const page = BY_SLUG.get(slug);
  const trail = [`<a href="${href(pathFor, lang, 'docs')}">${escapeHtml(t(CHROME.title))}</a>`];
  if (slug !== 'docs') trail.push(escapeHtml(t(page.group)));
  return `        <p class="docs-crumbs">${trail.join(' <span aria-hidden="true">/</span> ')}</p>`;
}

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

function documentSections(html) {
  const out = [];
  const re = /<h2\b[^>]*\bid="([^"]+)"[^>]*>([\s\S]*?)<\/h2>/g;
  let m;
  while ((m = re.exec(html)) !== null) {
    out.push({ id: m[1], title: m[2].replace(/<[^>]*>/g, '').trim() });
  }
  return out;
}

/// A mismatch between the outline and the documents fails the build; throws with the first disagreement.
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

  // Cross-page heading links are checked here, since a renamed heading silently breaks them.
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
