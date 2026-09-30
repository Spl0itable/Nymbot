// Inline because Cloudflare serves stored copies while the origin is unreachable; `_headers` carries its hash.
(function () {
    'use strict';

    var el = document.getElementById('nym-i18n-errors');
    if (!el) return;

    var data;
    try { data = JSON.parse(el.textContent); } catch (e) { return; }

    // One array per language, ordered by the markup's `data-i18n` indexes; English is absent.
    var table = data.t || {};

    // A site-wide selector pick wins; `?lang=` is ignored because the query belongs to the failed request.
    var pinned = null;
    try { pinned = localStorage.getItem('nym_lang'); } catch (e) { }

    var wanted = pinned ? [pinned] : (
        (navigator.languages && navigator.languages.length)
            ? navigator.languages
            : [navigator.language || '']
    );

    // Exact tag first, then the base language, matching boot.js.
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

    // Each slot is the whole text of one element or attribute, numbered by the renderer.
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
