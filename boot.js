// A file rather than an inline script so the site can be served under `script-src 'self'`.

(function () {
    'use strict';

    // The stylesheet keys the off-canvas docs nav off this, so with scripting off the nav stays in flow.
    document.documentElement.className += ' js';

    var el = document.getElementById('nym-i18n');
    if (!el) return;

    var table = {};
    try { table = JSON.parse(el.textContent) || {}; } catch (e) { }
    window.NYM_I18N = table;

    var lang = el.getAttribute('data-lang') || 'en';
    var page = el.getAttribute('data-page') || '';
    var codes = (el.getAttribute('data-langs') || 'en').split(',');

    // An explicit footer pick is recorded on every page and always beats the browser's setting.
    document.addEventListener('click', function (e) {
        var a = e.target.closest && e.target.closest('.lang-picker a[data-lang]');
        if (!a) return;
        try { localStorage.setItem('nym_lang', a.getAttribute('data-lang')); } catch (err) { }
    });

    // Only runs on English URLs; a translated URL is never redirected away from, and `?lang=en` pins English.
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
