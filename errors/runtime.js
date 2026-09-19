// The one script on an error page, and the only inline script on the site.
//
// Everywhere else the site solves language at build time: a page per language
// at its own URL, and boot.js only redirects a first-time visitor to the right
// one. An error page cannot work that way. Cloudflare stores one copy per slot
// and serves it under whatever URL was asked for, so there is no second URL to
// send anyone to — and the moments these pages are shown are exactly the ones
// where this origin cannot be reached, so the copy cannot fetch a translation
// either. Every language it supports has to already be in the file, and
// something in the file has to choose.
//
// That is why this is inline, and why `_headers` carries its hash: it is one
// script, byte-identical across all eight pages, so it is one `sha256-` in the
// policy rather than the per-page-per-language explosion that made inline
// scripts a non-starter for the rest of the site (see i18n/render.mjs).
//
// The translations themselves are NOT here. They sit in a
// `type="application/json"` block the browser parses and never executes, the
// same arrangement every other page uses, which is what keeps this to one hash
// no matter how the copy changes.
//
// With scripting off the page stays in English: still styled, still readable,
// still linking onward. That is the same trade as the rest of the site, made in
// the other direction.
(function () {
    'use strict';

    var el = document.getElementById('nym-i18n-errors');
    if (!el) return;

    var data;
    try { data = JSON.parse(el.textContent); } catch (e) { return; }

    // { "es": ["…", "…"], … } — one array per language, in the same order as
    // the `data-i18n` indexes in the markup. English is absent: it is what the
    // page already says.
    var table = data.t || {};

    // A pick made from the language selector anywhere on the site wins, and
    // wins alone — someone who chose English is not then sent to their browser
    // language. Same origin as the rest of the site, so the same key is here.
    //
    // `?lang=` is deliberately not read: on an error page the query string
    // belongs to whatever the visitor was actually asking for, not to a
    // language choice.
    var pinned = null;
    try { pinned = localStorage.getItem('nym_lang'); } catch (e) { }

    var wanted = pinned ? [pinned] : (
        (navigator.languages && navigator.languages.length)
            ? navigator.languages
            : [navigator.language || '']
    );

    // An exact tag first (pt-br), then the base language (pt) — the same
    // matching boot.js does, so the two agree about what a browser asked for.
    var code = '';
    for (var i = 0; i < wanted.length && !code; i++) {
        var tag = String(wanted[i] || '').toLowerCase();
        if (table[tag]) { code = tag; break; }
        var base = tag.split('-')[0];
        if (table[base]) code = base;
    }
    if (!code) return;

    var row = table[code];
    document.documentElement.lang = code;
    if ((data.rtl || []).indexOf(code) !== -1) document.documentElement.dir = 'rtl';

    // Every translatable string on the page is the whole text of one element or
    // the whole value of one of its attributes — the renderer guarantees it, and
    // numbers the slots as it writes them. So there is nothing to decide here:
    // no walking for prose, no re-deriving which text is copy and which is a
    // Cloudflare token or a shell prompt. That question was answered at build
    // time and cannot drift from the answer the translations were made against.
    var nodes = document.querySelectorAll('[data-i18n]');
    for (var n = 0; n < nodes.length; n++) {
        var node = nodes[n];
        var text = row[+node.getAttribute('data-i18n')];
        if (typeof text !== 'string') continue;
        var attribute = node.getAttribute('data-i18n-attr');
        if (attribute) node.setAttribute(attribute, text);
        else node.textContent = text;
    }
})();
