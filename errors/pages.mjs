// Error Pages substitute `::CLOUDFLARE_…_BOX::` tokens; Custom Error Rules do not (see server-error.html).
import { codeFontSize, HERO_ART, squareOff, windowArt } from "./art.mjs";

const SITE = "https://nymbot.ai";

// Absolute and off-host first: a stored page is served under any requested hostname, often during an outage.
const CARDS = {
  home: {
    href: `${SITE}/`,
    title: "Home",
    desc: "What Nymbot is, and where to get it.",
  },
  docs: {
    href: `${SITE}/docs/`,
    title: "Knowledge base",
    desc: "Credits, models, the repo mode and anonymous mode.",
  },
  app: {
    href: `${SITE}/app`,
    title: "Open Nymbot",
    desc: "Open the app in your browser.",
  },
  nymchat: {
    href: "https://nymchat.app",
    title: "Nymchat",
    // Marked fixed here because these pages collect strings from the renderer, not the extractor.
    fixed: true,
    desc: "The messenger on the same key, on a domain of its own.",
  },
  source: {
    href: "https://github.com/Spl0itable/nymbot",
    title: "Source and releases",
    desc: "The apps on GitHub, hosted somewhere else entirely.",
  },
  contact: {
    href: `${SITE}/contact/`,
    title: "Contact",
    desc: "Reach a person who can look up what happened.",
  },
};

const OUTAGE_CARDS = ["nymchat", "source", "home"];
const DEFAULT_CARDS = ["home", "docs", "app"];

export const ERROR_PAGES = [
  {
    file: "500s.html",
    slot: "Error Pages → 500 class errors",
    token: "::CLOUDFLARE_ERROR_500S_BOX::",
    title: "The site is down. Your key is not.",
    hero: "5XX",
    window: {
      channel: "#status",
      status: "relays: fine",
      lines: [
        null,
        { nym: "you", text: "nymbot?" },
        { nym: "you", text: "are you there?" },
        null,
        { sys: "* nymbot.ai did not answer *" },
        { sys: "* your key never lived here anyway *" },
        null,
      ],
    },
    label:
      "A chat channel called #status. Someone asks whether Nymbot is there, twice, and gets no reply — only a note that nymbot.ai did not answer and that their key was never kept here.",
    quip:
      "Your key, your credits and your history are not held on this server. This page is the part that can go missing.",
    term: { command: "ping", host: "nymbot.ai" },
    lead: "None of these are served by whatever just fell over:",
    cards: OUTAGE_CARDS,
  },
  {
    file: "1000s.html",
    slot: "Error Pages → 1000 class errors",
    token: "::CLOUDFLARE_ERROR_1000S_BOX::",
    title: "This address is not resolving",
    hero: "1XXX",
    window: {
      channel: "#dns",
      status: "0 answers",
      lines: [
        null,
        { nym: "you", text: "where does nymbot.ai point?" },
        null,
        { sys: "* no answer *" },
        { sys: "* still no answer *" },
        null,
      ],
    },
    label:
      "A chat channel called #dns. Someone asks where nymbot.ai points and gets no answer, twice.",
    quip:
      "Somewhere between the name and the number, the lookup lost the thread. Nothing you sent got this far.",
    term: { command: "dig", host: "nymbot.ai" },
    lead: "These do not depend on the record that is missing:",
    cards: OUTAGE_CARDS,
  },
  {
    file: "waf-block.html",
    slot: "Error Pages → WAF block",
    token: "::CLOUDFLARE_ERROR_1000S_BOX::",
    title: "That request was blocked",
    hero: "403",
    window: {
      channel: "#firewall",
      status: "1 rule matched",
      lines: [
        null,
        { nym: "you", text: "what did I do?" },
        null,
        { sys: "* a firewall rule matched the request *" },
        { sys: "* the ray id below says which one *" },
        null,
      ],
    },
    label:
      "A chat channel called #firewall. Someone asks what they did; the reply is that a firewall rule matched the request and the ray ID below says which one.",
    quip:
      "There is no account here to hold this against you. A rule matched one request, and that is the whole of it.",
    term: { command: "explain", argument: "this block" },
    lead: "If this was not what it looked like, say so:",
    cards: ["contact", "home", "docs"],
  },
  {
    file: "rate-limit.html",
    slot: "Error Pages → 429 errors (rate limiting)",
    token: "::CLOUDFLARE_ERROR_1000S_BOX::",
    title: "Too many requests, too quickly",
    hero: "429",
    window: {
      channel: "#ratelimit",
      status: "slow down",
      lines: [
        null,
        { nym: "you", text: "hello" },
        { nym: "you", text: "hello" },
        { nym: "you", text: "hello" },
        { sys: "* rate limit reached *" },
        null,
        { nym: "nymbot", text: "requests get counted. you don't." },
        null,
      ],
    },
    label:
      "A chat channel called #ratelimit. Someone says hello three times in a row, hits the rate limit, and Nymbot notes that requests are counted but people are not.",
    quip:
      "Rate limits count requests, never people, and nothing here spends a credit. Wait a moment and the counter forgets this one.",
    term: { command: "retry --after", argument: "a minute" },
    lead: "Somewhere to be in the meantime:",
    cards: DEFAULT_CARDS,
  },
  {
    file: "ip-block.html",
    slot: "Error Pages → IP/Country block",
    token: "::CLOUDFLARE_ERROR_1000S_BOX::",
    title: "This address is not allowed through",
    hero: "403",
    window: {
      channel: "#access",
      status: "0 nyms here",
      lines: [
        null,
        { nym: "you", text: "can I come in?" },
        null,
        { sys: "* this address is blocked here *" },
        { sys: "* only here *" },
        null,
      ],
    },
    label:
      "A chat channel called #access. Someone asks to come in and is told the address is blocked here, and only here.",
    quip:
      "The block is on this website, not on your key. Anywhere else you sign in with it, you are the same person with the same balance.",
    term: { command: "traceroute", host: "nymbot.ai" },
    lead: "Nothing below is behind this door:",
    cards: ["nymchat", "source", "contact"],
  },
  {
    file: "challenge.html",
    slot:
      "Error Pages → Managed Challenge, Interactive Challenge, Basic security challenge, Country challenge",
    token: "::CAPTCHA_BOX::",
    title: "One moment, checking your browser",
    // A challenge has no status code, so show whose site is holding the visitor up.
    hero: "logo",
    window: {
      channel: "#gate",
      status: "checking",
      lines: [
        null,
        { nym: "you", text: "I am a person" },
        null,
        { sys: "* proving that takes a second *" },
        null,
      ],
    },
    label:
      "A chat channel called #gate. Someone says they are a person, and the channel notes that proving it takes a second.",
    quip:
      "This check sits in front of the website, not in front of the app. Your conversations do not come through here.",
    term: null,
    lead: "Once it clears, you were probably after one of these:",
    cards: DEFAULT_CARDS,
  },
  {
    file: "under-attack.html",
    slot: "Error Pages → I'm Under Attack Mode",
    token: "::IM_UNDER_ATTACK_BOX::",
    title: "Checking your connection",
    hero: "logo",
    window: {
      channel: "#gate",
      status: "under attack",
      lines: [
        null,
        { nym: "you", text: "is this going to take long?" },
        null,
        { sys: "* five seconds, give or take *" },
        null,
      ],
    },
    label:
      "A chat channel called #gate. Someone asks whether this will take long, and the answer is five seconds, give or take.",
    quip:
      "The website is under load and is screening connections. Nothing about your key, your credits or your chats is involved in that.",
    term: null,
    lead: "Where you were going:",
    cards: DEFAULT_CARDS,
  },
  {
    file: "server-error.html",
    // Token-free: Error Pages skip 500/501/503/505 and custom rules do not substitute tokens.
    slot: "Custom Error Rules (any status code, no token substituted)",
    token: null,
    title: "That request did not go through",
    hero: "5XX",
    window: {
      channel: "#status",
      status: "relays: fine",
      lines: [
        null,
        { nym: "you", text: "did that work?" },
        null,
        { sys: "* the server returned an error *" },
        { sys: "* it was not written down *" },
        null,
      ],
    },
    label:
      "A chat channel called #status. Someone asks whether their request worked; the channel reports an error from the server and notes that nothing was written down.",
    quip:
      "The request failed on our side. There is no account here for it to have been filed against, so it was not.",
    term: { command: "curl -sI", host: "nymbot.ai" },
    lead: "These may be having a better day:",
    cards: OUTAGE_CARDS,
  },
];

const esc = (text) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const attr = (text) => esc(text).replace(/"/g, "&quot;");

// Inline favicon, since /images/ is unreachable when these pages show.
const FAVICON =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E" +
  "%3Crect width='32' height='32' rx='6' fill='%23050810'/%3E" +
  "%3Ctext x='16' y='23' font-family='monospace' font-size='20' fill='%2300ff00' text-anchor='middle'%3EN%3C/text%3E" +
  "%3C/svg%3E";

const card = (key, mark) => {
  const { href, title, desc, fixed } = CARDS[key];
  return `            <li><a class="docs-card" href="${attr(href)}">
                <span class="docs-card-title"${fixed ? "" : mark(title)}>${esc(title)}</span>
                <span class="docs-card-desc"${mark(desc)}>${esc(desc)}</span>
            </a></li>`;
};

// Kept in step with the 404.html footer by hand.
const footer = (mark) => `    <footer>
        <div style="margin-top: 1rem;">
            <p${mark("Nymbot - your AI, on your key")}>Nymbot - your AI, on your key</p>
            <p style="font-size: 0.8rem; margin-top: 0.5rem;">&copy; <a href="https://nostrservices.com" target="_blank"
                    rel="noopener" style="color: var(--secondary)">21 Million LLC</a> &bull; <a href="${SITE}/terms/"
                    style="color: var(--secondary)"${mark("Terms of Service")}>Terms of Service</a> &bull; <a href="${SITE}/privacy/"
                    style="color: var(--secondary)"${mark("Privacy Policy")}>Privacy Policy</a> &bull; <a href="${SITE}/dmca/"
                    style="color: var(--secondary)"${mark("DMCA")}>DMCA</a> &bull; <a href="${SITE}/contact/"
                    style="color: var(--secondary)"${mark("Contact")}>Contact</a> &bull; <a href="${SITE}/brand/"
                    style="color: var(--secondary)"${mark("Brand")}>Brand</a> &bull; <a href="${SITE}/docs/"
                    style="color: var(--secondary)"${mark("Knowledge Base")}>Knowledge Base</a></p>
        </div>
    </footer>`;

// `data-i18n="N"` numbering is the whole contract with errors/runtime.js.
function slots() {
  const strings = [];
  let sealed = false;
  const mark = (text) => {
    // Sealed so a slot added after the table is built fails the build instead of staying English.
    if (sealed) throw new Error(`slot "${text}" was added after the table was built`);
    return ` data-i18n="${strings.push(text) - 1}"`;
  };
  const markAttr = (text, name) => `${mark(text)} data-i18n-attr="${name}"`;
  const seal = () => { sealed = true; };
  return { strings, mark, markAttr, seal };
}

/// [assets] arrive prebuilt since `_headers` hashes the runtime's bytes; [translate] runs once all strings are known.
export function renderErrorPage(page, assets = {}, translate = () => ({})) {
  const { css = "", runtime = "" } = assets;
  const hero = HERO_ART[page.hero];
  if (!hero) {
    throw new Error(`no hero art named ${page.hero} — see errors/art.mjs`);
  }
  const art = squareOff(hero.art);
  const { strings, mark, markAttr, seal } = slots();

  // Each drawing has its own column count, so each gets its own cap.
  const sizing = `\n.nf-art-code{font-size:${codeFontSize(art)}}`;

  const title = `${page.title} - Nymbot`;
  const parts = [];

  // `<pre>` drawings stay untranslated; a translation would break the padded frame.
  parts.push(
    `        <pre class="nf-art nf-art-code" role="img" aria-label="${attr(hero.label)}"`
    + `${hero.fixed ? "" : markAttr(hero.label, "aria-label")}>${art}</pre>`
  );

  parts.push(`        <h1 class="nf-title"${mark(page.title)}>${esc(page.title)}</h1>`);

  parts.push(
    `        <pre class="nf-art nf-art-window" role="img" aria-label="${attr(page.label)}"`
    + `${markAttr(page.label, "aria-label")}>${windowArt(page.window)}</pre>`
  );

  // The token sits alone in a box that hides when empty; `data-i18n-skip` keeps translators from mangling it.
  if (page.token) {
    parts.push(`        <div class="nf-box" data-i18n-skip>${page.token}</div>`);
  }

  parts.push(`        <p class="nf-quip"${mark(page.quip)}>${esc(page.quip)}</p>`);

  if (page.term) {
    // Shell text carries the skip marker; a host argument is never translated, a phrase is.
    const argument = page.term.host ?? page.term.argument;
    const argumentMark = page.term.host
      ? ' data-i18n-skip'
      : mark(page.term.argument);
    parts.push(`        <p class="nf-term">
            <span class="nf-prompt" data-i18n-skip>nym@mesh:~$</span> <span
                data-i18n-skip>${esc(page.term.command)}</span> <span
                class="nf-path"${argumentMark}>${esc(argument)}</span><span class="nf-cursor"
                aria-hidden="true">&#9608;</span>
        </p>`);
  }

  parts.push(`        <p class="nf-lead"${mark(page.lead)}>${esc(page.lead)}</p>`);
  parts.push(`        <ul class="docs-cards">
${page.cards.map((key) => card(key, mark)).join("\n")}
        </ul>`);

  // Written before the table is requested so every slot is numbered first.
  const titleTag = `<title${mark(title)}>${esc(title)}</title>`;
  const footerHtml = footer(mark);

  // Parsed, never executed, so it costs the script policy nothing.
  seal();
  const table = translate(strings);
  for (const [code, row] of Object.entries(table.t ?? {})) {
    if (row.length !== strings.length) {
      throw new Error(
        `${page.file}: ${code} has ${row.length} translations for ${strings.length} slots`
      );
    }
  }
  const data = `    <script type="application/json" id="nym-i18n-errors">`
    + `${JSON.stringify(table)}</script>`;

  const html = `<!DOCTYPE html>
<html lang="en">

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    ${titleTag}
    <meta name="robots" content="noindex">
    <link rel="icon" type="image/svg+xml" href="${FAVICON}">
    <meta name="theme-color" content="#050810" media="(prefers-color-scheme: dark)">
    <meta name="theme-color" content="#f2f4f7" media="(prefers-color-scheme: light)">
    <style>${css}${sizing}</style>
</head>

<body>
    <div class="grid-bg"></div>
    <main class="legal-page nf">
${parts.join("\n\n")}
    </main>

${footerHtml}

${data}
    <script>${runtime}</script>
</body>

</html>
`;

  return { html, strings };
}

/// Collected by rendering, so a string added to a page cannot be forgotten here.
export function errorStrings() {
  const all = new Set();
  for (const page of ERROR_PAGES) {
    for (const string of renderErrorPage(page).strings) all.add(string);
  }
  return [...all];
}
