// Emits a site page with the shared head/footer chrome, so every document in
// pages/ carries identical metadata and only its own prose differs.
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const SITE = 'https://nymbot.ai';
const OG = `${SITE}/images/og-banner.png`;
const OG_ALT = 'The nymbot wordmark in ASCII block letters, above the words Private. Paid in sats. Yours alone.';

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function head({ title, description, slug }) {
  const url = `${SITE}/${slug ? slug + '/' : ''}`;
  return `<!DOCTYPE html>
<html lang="en">

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${esc(title)}</title>
    <meta name="description" content="${esc(description)}">
    <link rel="icon" type="image/x-icon" href="${SITE}/images/favicon.ico">
    <link rel="icon" type="image/png" sizes="192x192" href="${SITE}/images/android-chrome-192x192.png">
    <link rel="icon" type="image/png" sizes="512x512" href="${SITE}/images/android-chrome-512x512.png">
    <link rel="apple-touch-icon" sizes="192x192" href="${SITE}/images/android-chrome-192x192.png">

    <!-- Open Graph Meta Tags -->
    <meta property="og:title" content="${esc(title)}">
    <meta property="og:description" content="${esc(description)}">
    <meta property="og:image" content="${OG}">
    <meta property="og:url" content="${url}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Nymbot">
    <meta property="og:image:width" content="1200">
    <meta property="og:image:height" content="630">
    <meta property="og:image:alt" content="${esc(OG_ALT)}">
    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:image" content="${OG}">
    <meta name="twitter:image:alt" content="${esc(OG_ALT)}">
    <meta name="twitter:title" content="${esc(title)}">
    <meta name="twitter:description" content="${esc(description)}">
    <link rel="canonical" href="${url}">
    <!--HREFLANG-->
    <meta name="theme-color" content="#050810" media="(prefers-color-scheme: dark)">
    <meta name="theme-color" content="#f2f4f7" media="(prefers-color-scheme: light)">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-title" content="Nymbot">
    <link rel="stylesheet" href="styles.css">
    <!--I18N-RUNTIME-->
    <script src="boot.js"></script>
</head>
`;
}

export const FOOTER = `    <footer>
        <div style="margin-top: 1rem;">
            <p>Nymbot - your AI, on your key</p>
            <p style="font-size: 0.8rem; margin-top: 0.5rem;">&copy; <a href="https://nostrservices.com" target="_blank"
                    rel="noopener" style="color: var(--secondary)">21 Million LLC</a> &bull; <a href="/terms/"
                    style="color: var(--secondary)">Terms of Service</a> &bull; <a href="/privacy/"
                    style="color: var(--secondary)">Privacy Policy</a> &bull; <a href="/dmca/"
                    style="color: var(--secondary)">DMCA</a> &bull; <a href="/contact/"
                    style="color: var(--secondary)">Contact</a> &bull; <a href="/docs/"
                    style="color: var(--secondary)">Knowledge Base</a> &bull; <a href="https://nymchat.app"
                    style="color: var(--secondary)">Nymchat</a></p>
        </div>
        <p class="lang-picker-label">Language</p>
        <!--LANG-SELECTOR-->
    </footer>`;

/// A knowledge-base page: shared chrome around [body], which is the prose from
/// the <h1> down.
export async function docsPage({ file, slug, title, description, body }) {
  const html = `${head({ title, description, slug })}
<body>
    <div class="grid-bg"></div>
    <div class="docs-shell">
        <!--DOCS-TOPBAR-->
        <div class="docs-body">
        <!--DOCS-NAV-->
        <main id="docs-main" class="docs-main">
        <!--DOCS-CRUMBS-->
${body}
        <!--DOCS-PAGER-->
        </main>
        <!--DOCS-TOC-->
        </div>
    </div>

${FOOTER}
    <script src="docs.js"></script>
</body>

</html>
`;
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, html);
}

/// A standalone page (legal, contact) with the landing page's plain chrome.
export async function plainPage({ file, slug, title, description, body }) {
  const html = `${head({ title, description, slug })}
<body>
    <div class="grid-bg"></div>
    <main class="legal-page">
        <a href="/" class="legal-back"><span aria-hidden="true">&larr;</span> Back to Nymbot</a>
${body}
    </main>

${FOOTER}
</body>

</html>
`;
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, html);
}
