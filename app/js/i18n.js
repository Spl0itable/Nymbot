// Translation at runtime.
//
// The app is one page, not one page per language, so the pack is fetched and
// applied to the DOM rather than baked in at build time the way the marketing
// site's pages are. Both surfaces translate BY THE ENGLISH STRING — the pack is
// `{ english: translated }` — so one cache serves them and the same extractor
// finds the same strings in both.
(function () {
    'use strict';

    const C = window.NymbotConfig;

    // The same rules the extractor applies, or the two would disagree about
    // what a string is: i18n/extract.mjs.
    const SKIP_ELEMENTS = new Set(['SCRIPT', 'STYLE', 'SVG', 'PRE', 'CODE', 'TEXTAREA']);
    const TEXT_ATTRIBUTES = ['alt', 'title', 'placeholder', 'aria-label'];

    const I18n = {
        lang: 'en',
        pack: null,
        ready: null,

        /// The stored choice, else the closest published match for the
        /// browser's languages, else English.
        pick(published) {
            const stored = (() => {
                try { return localStorage.getItem(C.storagePrefix + 'lang'); } catch (_) { return null; }
            })();
            if (stored && (stored === 'en' || published.includes(stored))) return stored;
            for (const tag of navigator.languages || [navigator.language || 'en']) {
                const code = String(tag);
                if (published.includes(code)) return code;
                const base = code.split('-')[0];
                if (base === 'en') return 'en';
                if (published.includes(base)) return base;
            }
            return 'en';
        },

        async setLang(code) {
            try { localStorage.setItem(C.storagePrefix + 'lang', code); } catch (_) { }
            location.reload();
        },

        /// Which languages have a pack, as `[{ code, name, native }]`. Absent
        /// or unreadable means English only, which is what a local checkout
        /// with no build looks like.
        async published() {
            try {
                const resp = await fetch('/app/i18n/index.json', { cache: 'no-cache' });
                if (!resp.ok) return [];
                const list = await resp.json();
                return Array.isArray(list) ? list : [];
            } catch (_) { return []; }
        },

        async init() {
            this.available = await this.published();
            this.lang = this.pick(this.available.map((l) => l.code));
            if (this.lang === 'en') return;
            try {
                const resp = await fetch(`/app/i18n/${this.lang}.json`, { cache: 'no-cache' });
                if (resp.ok) this.pack = await resp.json();
            } catch (_) { this.pack = null; }
            if (!this.pack) { this.lang = 'en'; return; }
            document.documentElement.lang = this.lang;
            if (RTL.has(this.lang)) document.documentElement.dir = 'rtl';
            this.translateDom(document.body);
        },

        /// A figure with its thousands separated, and nothing else done to it.
        ///
        /// Never abbreviated, however long it gets: these are balances and
        /// prices, and rounding 12,500 credits to "12.5k" throws away digits
        /// the reader is entitled to. Separators are all the legibility a
        /// figure needs when every one of them has to stay.
        ///
        /// The grouping is done here rather than by `toLocaleString` so it is
        /// deterministic: the same figure however the app has been translated,
        /// and whatever the browser's own locale happens to be.
        count(value) {
            return String(Math.round(Number(value) || 0))
                .replace(/\B(?=(\d{3})+(?!\d))/g, ',');
        },

        amount(value, places) {
            const digits = places == null ? 2 : places;
            const scale = Math.pow(10, digits);
            const n = Math.round((Number(value) || 0) * scale) / scale;
            const whole = Math.trunc(n);
            const grouped = String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
            let frac = Math.abs(n - whole).toFixed(digits).slice(1).replace(/0+$/, '');
            if (frac === '.') frac = '';
            return grouped + frac;
        },

        /// One string, with `{name}` placeholders filled from [vars].
        ///
        /// Untranslated text is returned as it came in, so a pack missing an
        /// entry degrades to English rather than to a key. The whole sentence
        /// is the unit on purpose: a translator handed fragments to join cannot
        /// reorder them, and word order is most of what changes.
        t(text, vars) {
            const hit = this.pack && typeof this.pack[text] === 'string' ? this.pack[text] : text;
            if (!vars) return hit;
            return hit.replace(/\{(\w+)\}/g, (m, key) =>
                (Object.prototype.hasOwnProperty.call(vars, key) ? String(vars[key]) : m));
        },

        /// Replaces the prose already in the markup. Called once at boot and
        /// again for anything rendered from the HTML afterwards.
        translateDom(root) {
            if (!this.pack || !root) return;
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
                acceptNode: (node) => {
                    if (node.nodeType === Node.ELEMENT_NODE) {
                        if (SKIP_ELEMENTS.has(node.tagName) || node.hasAttribute('data-i18n-skip')) {
                            return NodeFilter.FILTER_REJECT;
                        }
                        return NodeFilter.FILTER_ACCEPT;
                    }
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            const texts = [];
            let node;
            while ((node = walker.nextNode())) {
                if (node.nodeType === Node.TEXT_NODE) texts.push(node);
            }
            for (const text of texts) {
                // Whitespace around the run is layout, not prose: translate the
                // trimmed value and put the padding back.
                const raw = text.nodeValue;
                const trimmed = raw.trim();
                if (!trimmed) continue;
                const hit = this.pack[trimmed];
                if (typeof hit !== 'string') continue;
                text.nodeValue = raw.replace(trimmed, hit);
            }
            // Walked separately from the text, because the two ask different
            // questions of the same element: a <textarea> holds no prose to
            // translate but its placeholder is prose, and the tree walk that
            // skips the one would skip the other with it. Only
            // `data-i18n-skip` covers both.
            const selector = TEXT_ATTRIBUTES.map((a) => `[${a}]`).join(',');
            const scope = root.nodeType === Node.ELEMENT_NODE ? [root] : [];
            for (const el of [...scope, ...root.querySelectorAll(selector)]) {
                if (el.closest('[data-i18n-skip]')) continue;
                for (const attr of TEXT_ATTRIBUTES) {
                    const value = el.getAttribute(attr);
                    if (!value) continue;
                    const hit = this.pack[value.trim()];
                    if (typeof hit === 'string') el.setAttribute(attr, hit);
                }
            }
        }
    };

    const RTL = new Set(['ar', 'he', 'fa', 'ur', 'ps', 'sd', 'ckb', 'yi', 'dv']);

    I18n.ready = I18n.init();
    window.NymbotI18n = I18n;
    /// Shorthand the extractor looks for: `t('…')` in app/js/*.js.
    window.t = (text, vars) => I18n.t(text, vars);
    window.amount = (value, places) => I18n.amount(value, places);
})();
