// The tiny runtime every page on the site carries.
//
// Three jobs, none of them worth a second request: mark that scripting is
// available, hand `t()` the translation table for this language, and keep a
// visitor on the language they asked for.
//
// It exists as a file rather than as an inline <script> so the site can be
// served under `script-src 'self'` with no `unsafe-inline` — see `_headers`.
// The data it needs is inlined instead, as a `type="application/json"` block
// the browser parses but never executes.

(function () {
    'use strict';

    // Progressive enhancement marker. The stylesheet keys the knowledge base's
    // off-canvas nav and filter box off this, so with scripting off the nav
    // stays in flow rather than vanishing off-screen.
    document.documentElement.className += ' js';

    var el = document.getElementById('nym-i18n');
    if (!el) return;

    // Copy that is written into the page at runtime rather than being in the
    // markup — the animated chat in the phone mockup. English ships an empty
    // table and `t()` falls through to the literal.
    var table = {};
    try { table = JSON.parse(el.textContent) || {}; } catch (e) { }
    window.NYM_I18N = table;

    var lang = el.getAttribute('data-lang') || 'en';
    var page = el.getAttribute('data-page') || '';
    var codes = (el.getAttribute('data-langs') || 'en').split(',');

    // An explicit pick from the footer selector is remembered, and always wins
    // over the browser's setting. Recorded on every page, so choosing English
    // from a translated page is not undone by the root's redirect next visit.
    document.addEventListener('click', function (e) {
        var a = e.target.closest && e.target.closest('.lang-picker a[data-lang]');
        if (!a) return;
        try { localStorage.setItem('nym_lang', a.getAttribute('data-lang')); } catch (err) { }
    });

    // Only ever runs on an English URL. A translated URL — chosen by a visitor,
    // or fetched by a crawler — is never redirected away from, and the page is
    // kept: someone on /terms/ goes to /es/terms/, never to the Spanish home
    // page. `?lang=en` pins English for good.
    if (lang !== 'en') return;

    var pinned = null;
    try { pinned = localStorage.getItem('nym_lang'); } catch (e) { }
    var forced = new URLSearchParams(location.search).get('lang');
    if (forced) {
        try { localStorage.setItem('nym_lang', forced); } catch (e) { }
        pinned = forced;
    }
    if (pinned) return;

    var best = '';
    var wanted = (navigator.languages && navigator.languages.length)
        ? navigator.languages : [navigator.language || ''];
    for (var i = 0; i < wanted.length && !best; i++) {
        var tag = String(wanted[i] || '').toLowerCase();
        if (codes.indexOf(tag) !== -1) { best = tag; break; }
        var base = tag.split('-')[0];
        if (codes.indexOf(base) !== -1) best = base;
    }
    if (best && best !== 'en') {
        location.replace('/' + best + '/' + (page ? page + '/' : '') + location.search + location.hash);
    }
})();
