// Behavior for the knowledge base at /docs/.
//
// Three small things, none of which the page depends on to be readable: the
// off-canvas nav on narrow screens, the filter box in the top bar, and the
// "on this page" rail following the reader down the article. Everything here
// is progressive — with scripting off the stylesheet leaves the nav in flow
// and hides the filter box, so the page is still a complete document.
//
// No user-visible strings live in this file. Copy that a reader can see stays
// in the markup, where the build's extractor finds and translates it without
// anything having to be marked up by hand.

(function () {
    'use strict';

    var nav = document.getElementById('docs-nav');
    var main = document.getElementById('docs-main');
    if (!nav || !main) return;

    // --- off-canvas nav ----------------------------------------------------

    var toggle = document.querySelector('.docs-nav-toggle');
    var scrim = null;

    // The scrim has to go inside the shell, not on the body. `.docs-shell` is
    // `position: relative; z-index: 1` — it lifts the page off the fixed grid
    // background — and that makes it a stacking context, so the drawer's
    // `z-index: 40` is scoped to it. A scrim parented to the body is compared
    // against the whole shell at z-index 1 instead, wins, and swallows every
    // click meant for the nav underneath it. Same context, and the topbar (30),
    // scrim (35) and drawer (40) layer in the order the stylesheet says.
    var scrimHost = document.querySelector('.docs-shell') || document.body;

    var isOffCanvas = function () {
        return window.matchMedia('(max-width: 900px)').matches;
    };

    var closeNav = function () {
        nav.classList.remove('is-open');
        if (toggle) toggle.setAttribute('aria-expanded', 'false');
        if (scrim) {
            scrim.remove();
            scrim = null;
        }
    };

    var openNav = function () {
        nav.classList.add('is-open');
        if (toggle) toggle.setAttribute('aria-expanded', 'true');
        if (!scrim) {
            scrim = document.createElement('div');
            scrim.className = 'docs-nav-scrim';
            scrim.addEventListener('click', closeNav);
            scrimHost.appendChild(scrim);
        }
    };

    if (toggle) {
        toggle.addEventListener('click', function () {
            if (nav.classList.contains('is-open')) closeNav();
            else openNav();
        });
    }

    // Following a link inside the drawer should reveal the page behind it.
    nav.addEventListener('click', function (e) {
        if (e.target.closest('a') && isOffCanvas()) closeNav();
    });

    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && nav.classList.contains('is-open')) {
            closeNav();
            if (toggle) toggle.focus();
        }
    });

    // A drawer left open across a resize would sit over a desktop layout.
    window.addEventListener('resize', function () {
        if (!isOffCanvas() && nav.classList.contains('is-open')) closeNav();
    });

    // The nav is taller than the viewport once every section is listed, and it
    // is its own scroll container. Landing halfway down the knowledge base with
    // the sidebar showing its first entries hides where you actually are, so
    // bring the current page into view — without moving the page itself.
    var here = nav.querySelector('a[aria-current="page"]');
    if (here) {
        var navBox = nav.getBoundingClientRect();
        var hereBox = here.getBoundingClientRect();
        if (hereBox.bottom > navBox.bottom || hereBox.top < navBox.top) {
            nav.scrollTop += hereBox.top - navBox.top - navBox.height / 3;
        }
    }

    // --- filter ------------------------------------------------------------
    //
    // Every docs page ships the whole navigation tree, headings included, so
    // filtering it is a site-wide search that needs no index — and one that is
    // translated for free, because the tree is ordinary markup the build
    // already translates. The stylesheet hides other pages' headings until a
    // filter is running.

    var search = document.getElementById('docs-search');
    var empty = document.querySelector('.docs-nav-empty');

    // Match the way a reader types: case-folded, and with accents dropped so
    // "reves" finds "révès". A browser without Unicode normalisation just gets
    // the case-folded comparison.
    var fold = function (text) {
        var lower = String(text).toLowerCase();
        return lower.normalize ? lower.normalize('NFD').replace(/[\u0300-\u036f]/g, '') : lower;
    };

    if (search) {
        var items = [].slice.call(nav.querySelectorAll('li'));
        var groups = [].slice.call(nav.querySelectorAll('.docs-nav-group'));
        var haystacks = items.map(function (li) {
            var link = li.querySelector(':scope > a');
            return fold(link ? link.textContent : li.textContent);
        });

        var runFilter = function () {
            var query = fold(search.value.trim());
            if (!query) {
                nav.classList.remove('is-filtering');
                items.forEach(function (li) { li.hidden = false; });
                groups.forEach(function (g) { g.hidden = false; });
                if (empty) empty.hidden = true;
                return;
            }
            nav.classList.add('is-filtering');
            var hits = 0;
            // Deepest first, so a parent can see whether any child matched.
            for (var i = items.length - 1; i >= 0; i--) {
                var li = items[i];
                var self = haystacks[i].indexOf(query) !== -1;
                var child = !!li.querySelector('li:not([hidden])');
                li.hidden = !(self || child);
                if (!li.hidden) hits++;
            }
            groups.forEach(function (group) {
                group.hidden = !group.querySelector('li:not([hidden])');
            });
            if (empty) empty.hidden = hits > 0;
        };

        search.addEventListener('input', runFilter);
        search.addEventListener('keydown', function (e) {
            if (e.key !== 'Escape') return;
            search.value = '';
            runFilter();
        });

        // "/" is the search shortcut everyone already knows, but only when the
        // reader is not typing into something else.
        document.addEventListener('keydown', function (e) {
            if (e.key !== '/' || e.metaKey || e.ctrlKey || e.altKey) return;
            var el = document.activeElement;
            if (el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))) return;
            e.preventDefault();
            if (isOffCanvas() && !nav.classList.contains('is-open')) openNav();
            search.focus();
            search.select();
        });

        // A filter typed, then restored from the back-forward cache.
        if (search.value) runFilter();
    }

    // --- on this page ------------------------------------------------------

    var tocLinks = [].slice.call(document.querySelectorAll('.docs-toc a[href^="#"]'));
    if (tocLinks.length === 0) return;

    var targets = tocLinks
        .map(function (link) {
            return { link: link, el: document.getElementById(decodeURIComponent(link.hash.slice(1))) };
        })
        .filter(function (pair) { return pair.el; });
    if (targets.length === 0) return;

    var current = null;
    var setActive = function (pair) {
        if (pair === current) return;
        if (current) current.link.classList.remove('is-active');
        if (pair) pair.link.classList.add('is-active');
        current = pair;
    };

    // Plain measurement rather than IntersectionObserver: headings here are
    // zero-height anchors between blocks of prose, so "which heading did I last
    // scroll past" is the question, and an observer answers a different one.
    var update = function () {
        var line = window.scrollY + 120;
        var found = targets[0];
        for (var i = 0; i < targets.length; i++) {
            if (targets[i].el.getBoundingClientRect().top + window.scrollY <= line) found = targets[i];
            else break;
        }
        // At the very bottom the last section may be too short to ever cross
        // the line; the reader is plainly in it, so say so.
        if (window.innerHeight + window.scrollY >= document.body.scrollHeight - 4) {
            found = targets[targets.length - 1];
        }
        setActive(found);
    };

    var ticking = false;
    var onScroll = function () {
        if (ticking) return;
        ticking = true;
        window.requestAnimationFrame(function () {
            ticking = false;
            update();
        });
    };

    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll);
    update();
})();

(function () {
    'use strict';

    var mount = document.getElementById('priceSheet');
    if (!mount) return;

    var num = function (n) {
        return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    };

    var price = function (m) {
        var span = m.max && m.max !== m.credits;
        var n = span ? num(m.credits) + '–' + num(m.max) : num(m.credits);
        return (!span && m.credits === 1) ? n + ' credit' : n + ' credits';
    };

    var repoPrice = function (m) {
        if (!m.repoCredits) return '';
        var span = m.repoMax && m.repoMax !== m.repoCredits;
        return span ? num(m.repoCredits) + '–' + num(m.repoMax) : num(m.repoCredits);
    };

    var rate = function (usd) {
        if (!(usd > 0)) return '—';
        return '$' + (usd < 1 ? usd.toFixed(3).replace(/0+$/, '').replace(/\.$/, '')
            : usd.toFixed(2)) + ' / 1M';
    };

    var say = function (text, cls) {
        mount.innerHTML = '';
        var p = document.createElement('p');
        if (cls) p.className = cls;
        p.textContent = text;
        mount.appendChild(p);
    };

    var render = function (data) {
        var models = (data && data.models) || [];
        var groups = (data && data.groups) || [];
        if (!models.length) return say('The model list could not be loaded just now.', 'hint');
        var byKey = {};
        models.forEach(function (m) { byKey[m.key] = m; });

        var wrap = document.createElement('div');
        wrap.className = 'docs-table-wrap';
        var table = document.createElement('table');
        var anyRepo = models.some(function (m) { return !!m.repoCredits; });
        var anyRate = models.some(function (m) { return m.inUsdPerMTok > 0; });
        var head = '<thead><tr><th>Model</th><th>A reply</th>'
            + (anyRepo ? '<th>A repo call</th>' : '')
            + (anyRate ? '<th>Input</th><th>Output</th><th>Cached input</th>' : '')
            + '<th>Context</th></tr></thead>';
        table.innerHTML = head;
        var body = document.createElement('tbody');

        groups.forEach(function (group) {
            var rows = (group.keys || []).map(function (k) { return byKey[k]; })
                .filter(function (m) { return m && m.priced !== false; });
            if (!rows.length) return;
            var head = document.createElement('tr');
            head.className = 'price-maker';
            var cell = document.createElement('th');
            cell.setAttribute('colspan', String(3 + (anyRepo ? 1 : 0) + (anyRate ? 3 : 0)));
            var marks = window.NymbotBrands;
            if (marks && group.authorSlug) {
                cell.appendChild(marks.mark(group.authorSlug, 18));
            }
            cell.appendChild(document.createTextNode(group.author));
            head.appendChild(cell);
            body.appendChild(head);
            rows.forEach(function (m) {
                var tr = document.createElement('tr');
                var cells = [m.label, price(m)];
                if (anyRepo) cells.push(repoPrice(m) || '—');
                if (anyRate) {
                    cells.push(rate(m.inUsdPerMTok), rate(m.outUsdPerMTok),
                        rate(m.cacheReadUsdPerMTok));
                }
                cells.push(m.context ? num(m.context) + ' tokens' : '—');
                cells.forEach(function (text, i) {
                    var td = document.createElement(i === 0 ? 'th' : 'td');
                    td.textContent = text;
                    tr.appendChild(td);
                });
                body.appendChild(tr);
            });
        });

        if (!body.children.length) return say('The model list could not be loaded just now.', 'hint');
        table.appendChild(body);
        wrap.appendChild(table);
        mount.innerHTML = '';
        mount.appendChild(wrap);

        var note = document.createElement('p');
        note.className = 'hint';
        note.textContent = 'Live from the same catalog the app reads, so this page and the '
            + 'model picker can never disagree. Where a model has per-million-token rates, '
            + 'that is what you are charged on: the tokens a reply actually used, billed in '
            + 'thousandths of a credit, so a short question costs a fraction of one. Repeated '
            + 'context is billed at the cached rate rather than the full one, which is why a '
            + 'long chat does not re-pay for its own history. A dash means that model is '
            + 'billed per reply instead, and the reply column is what it comes to.';
        mount.appendChild(note);
    };

    fetch('https://web.nymchat.app/api/bot', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'models' })
    }).then(function (r) {
        if (!r.ok) throw new Error('http ' + r.status);
        return r.json();
    }).then(render).catch(function () {
        say('The model list could not be loaded just now — it is in the app under ?model.', 'hint');
    });
})();
