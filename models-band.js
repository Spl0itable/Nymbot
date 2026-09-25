(function () {
    'use strict';

    var band = document.getElementById('modelsBand');
    if (!band) return;
    var rows = band.querySelectorAll('.models-band-track');
    var names = document.getElementById('modelsBandNames');
    if (!rows.length) return;

    var pill = function (m) {
        var el = document.createElement('li');
        el.className = 'models-band-pill';
        var tile = document.createElement('span');
        tile.className = 'models-band-tile';
        if (window.NymbotBrands) tile.appendChild(window.NymbotBrands.mark(m.authorSlug, 24));
        var label = document.createElement('span');
        label.className = 'models-band-label';
        label.textContent = m.label;
        el.appendChild(tile);
        el.appendChild(label);
        return el;
    };

    var fill = function (track, list) {
        track.textContent = '';
        var set = function (hidden) {
            var ul = document.createElement('ul');
            ul.className = 'models-band-set';
            if (hidden) ul.setAttribute('aria-hidden', 'true');
            list.forEach(function (m) { ul.appendChild(pill(m)); });
            track.appendChild(ul);
        };
        set(false);
        set(true);
    };

    var render = function (data) {
        var models = (data && data.models) || [];
        var groups = (data && data.groups) || [];
        var byKey = {};
        models.forEach(function (m) { byKey[m.key] = m; });
        var ordered = [];
        var flagships = [];
        groups.forEach(function (g) {
            var keep = (g.keys || []).map(function (k) { return byKey[k]; })
                .filter(function (m) { return m && m.priced !== false && m.label; });
            if (!keep.length) return;
            flagships.push(keep[0]);
            keep.slice(0, 6).forEach(function (m) { ordered.push(m); });
        });
        if (ordered.length < 4) return;

        var first = [];
        var second = [];
        ordered.forEach(function (m, i) { (i % 2 ? second : first).push(m); });
        fill(rows[0], first);
        if (rows[1]) fill(rows[1], second);
        band.classList.add('is-live');

        if (names && flagships.length) {
            var lang = document.documentElement.lang || 'en';
            var picked = flagships.slice(0, 4).map(function (m) { return m.label; });
            var text = picked.join(', ');
            try {
                text = new Intl.ListFormat(lang, { style: 'short', type: 'unit' }).format(picked);
            } catch (e) {}
            names.textContent = text;
        }
    };

    fetch('/api/bot', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'models' })
    })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(render)
        .catch(function () {});
})();
