// Packs are `{ english: translated }`, sharing the site's cache and extractor.
(function () {
    'use strict';

    const C = window.NymbotConfig;

    // Must match the rules in i18n/extract.mjs.
    const SKIP_ELEMENTS = new Set(['SCRIPT', 'STYLE', 'SVG', 'PRE', 'CODE', 'TEXTAREA']);
    const TEXT_ATTRIBUTES = ['alt', 'title', 'placeholder', 'aria-label', 'data-tip'];
    const MT_URL = '/api/proxy?action=translate';
    const MT_BATCH = 25;
    const MT_CHARS = 18000;
    const MT_MAX = 5000;
    const MT_CONTEXT = 'Nymbot app interface';
    const RENDERED_MAX = 3000;
    const PROTECTED = new Set(['Nymbot', 'Nymchat', 'Nostr', 'Zapstore', 'App Store', 'Google Play', 'TestFlight', '21 Million LLC']);
    const TOKEN = /\{\w+\}|<[^<>]+>|&[#\w]+;/g;

    function fill(text, vars) {
        if (!vars) return text;
        return text.replace(/\{(\w+)\}/g, (m, key) =>
            (Object.prototype.hasOwnProperty.call(vars, key) ? String(vars[key]) : m));
    }

    function shield(source) {
        const tokens = [];
        const text = source.replace(TOKEN, (m) => {
            tokens.push(m);
            return '\u27e6' + (tokens.length - 1) + '\u27e7';
        });
        return { text, tokens };
    }

    function unshield(out, tokens) {
        if (typeof out !== 'string' || !out.trim()) return null;
        const marks = out.match(/\u27e6(\d+)\u27e7/g) || [];
        if (marks.length !== tokens.length) return null;
        const seen = new Set();
        for (const m of marks) {
            const i = Number(m.slice(1, -1));
            if (!(i < tokens.length) || seen.has(i)) return null;
            seen.add(i);
        }
        const back = out.replace(/\u27e6(\d+)\u27e7/g, (m, i) => tokens[Number(i)]);
        return /[\u27e6\u27e7]/.test(back) ? null : back;
    }

    function wordy(text) {
        return text.length <= MT_MAX && /\p{L}{2}/u.test(text) && !PROTECTED.has(text);
    }

    function skipped(el) {
        return !!el && !!el.closest && !!el.closest('[data-i18n-skip], .msg-text');
    }

    function walkText(root, visit) {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
            acceptNode: (node) => {
                if (node.nodeType === Node.ELEMENT_NODE) {
                    if (SKIP_ELEMENTS.has(node.tagName) || node.tagName === 'NOSCRIPT' || node.hasAttribute('data-i18n-skip')
                        || node.classList.contains('msg-text') || node.isContentEditable) {
                        return NodeFilter.FILTER_REJECT;
                    }
                }
                return NodeFilter.FILTER_ACCEPT;
            }
        });
        const texts = [];
        let node;
        while ((node = walker.nextNode())) {
            if (node.nodeType === Node.TEXT_NODE) texts.push(node);
        }
        for (const text of texts) visit(text);
    }

    function walkAttributes(root, visit) {
        const selector = TEXT_ATTRIBUTES.map((a) => `[${a}]`).join(',');
        const scope = root.nodeType === Node.ELEMENT_NODE && root.matches(selector) ? [root] : [];
        for (const el of [...scope, ...root.querySelectorAll(selector)]) {
            if (el.closest('[data-i18n-skip]')) continue;
            for (const attr of TEXT_ATTRIBUTES) {
                const value = el.getAttribute(attr);
                if (value) visit(el, attr, value);
            }
        }
    }

    function staticSources() {
        const found = new Set();
        if (!document.body) return found;
        walkText(document.body, (node) => {
            const v = node.nodeValue.trim();
            if (v && wordy(v)) found.add(v);
        });
        walkAttributes(document.body, (el, attr, value) => {
            const v = value.trim();
            if (v && wordy(v)) found.add(v);
        });
        return found;
    }

    const I18n = {
        lang: 'en',
        pack: null,
        ready: null,
        settled: false,
        mt: {},
        mtTried: new Set(),
        mtQueue: [],
        mtTimer: null,
        sources: new Set(),
        statics: staticSources(),
        rendered: new Map(),

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

        /// Absent or unreadable means English only, as in a local checkout with no build.
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
            if (this.lang === 'en') return this.settle();
            try {
                const resp = await fetch(`/app/i18n/${this.lang}.json`, { cache: 'no-cache' });
                if (resp.ok) this.pack = await resp.json();
            } catch (_) { this.pack = null; }
            if (!this.pack || typeof this.pack !== 'object') { this.pack = null; this.lang = 'en'; return this.settle(); }
            document.documentElement.lang = this.lang;
            if (RTL.has(this.lang)) document.documentElement.dir = 'rtl';
            this.mt = this.loadMt(this.lang);
            this.settle();
            for (const source of [...this.statics, ...this.sources]) {
                if (this.lookup(source) == null) this.want(source);
            }
            this.translateDom(document.body);
        },

        settle() {
            this.settled = true;
            if (this.lang === 'en') this.rendered.clear();
        },

        mtKey(lang) {
            return C.storagePrefix + 'i18n-mt-' + lang;
        },

        loadMt(lang) {
            try {
                const raw = JSON.parse(localStorage.getItem(this.mtKey(lang)) || 'null');
                if (raw && raw.v === C.version && raw.m && typeof raw.m === 'object') return raw.m;
                if (raw) localStorage.removeItem(this.mtKey(lang));
            } catch (_) { }
            return {};
        },

        saveMt() {
            try { localStorage.setItem(this.mtKey(this.lang), JSON.stringify({ v: C.version, m: this.mt })); } catch (_) { }
        },

        lookup(source) {
            if (this.pack && typeof this.pack[source] === 'string') return this.pack[source];
            if (!this.settled) return null;
            if (this.lang === 'en') return source;
            const mt = this.mt[source];
            return typeof mt === 'string' ? mt : null;
        },

        want(source) {
            if (!this.settled || this.lang === 'en' || !this.pack) return;
            if (this.mtTried.has(source) || !wordy(source)) return;
            this.mtTried.add(source);
            this.mtQueue.push(source);
            if (!this.mtTimer) this.mtTimer = setTimeout(() => this.flushMt(), 30);
        },

        async flushMt() {
            this.mtTimer = null;
            const lang = this.lang;
            const batch = [];
            let chars = 0;
            while (this.mtQueue.length && batch.length < MT_BATCH) {
                const next = this.mtQueue[0];
                if (batch.length && chars + next.length > MT_CHARS) break;
                batch.push(this.mtQueue.shift());
                chars += next.length;
            }
            if (this.mtQueue.length) this.mtTimer = setTimeout(() => this.flushMt(), 0);
            if (!batch.length) return;
            const shielded = batch.map(shield);
            let out = null;
            try {
                const resp = await fetch(MT_URL, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        texts: shielded.map((s) => s.text),
                        source: 'en',
                        target: lang,
                        contexts: batch.map(() => MT_CONTEXT)
                    })
                });
                if (resp.ok) {
                    const data = await resp.json();
                    if (data && Array.isArray(data.translations)) out = data.translations;
                }
            } catch (_) { out = null; }
            if (!out || lang !== this.lang) return;
            let got = 0;
            batch.forEach((source, i) => {
                const back = unshield(out[i], shielded[i].tokens);
                if (back) { this.mt[source] = back; got++; }
            });
            if (!got) return;
            this.saveMt();
            this.translateDom(document.body);
            try { window.dispatchEvent(new CustomEvent('nymbot:i18n', { detail: { lang } })); } catch (_) { }
        },

        remember(output, source, vars) {
            if (this.rendered.has(output)) this.rendered.delete(output);
            this.rendered.set(output, { source, vars: vars || null });
            if (this.rendered.size > RENDERED_MAX) this.rendered.delete(this.rendered.keys().next().value);
        },

        swap(value) {
            const v = value.trim();
            if (!v) return null;
            const was = this.rendered.get(v);
            if (was) {
                const hit = this.lookup(was.source);
                if (hit == null || hit === was.source && !was.vars) return null;
                const now = fill(hit, was.vars);
                if (now === v) return null;
                this.rendered.delete(v);
                return value.replace(v, now);
            }
            const known = this.statics.has(v) || this.sources.has(v) || (this.pack && typeof this.pack[v] === 'string');
            if (!known) return null;
            const hit = this.lookup(v);
            return hit == null || hit === v ? null : value.replace(v, hit);
        },

        /// Never abbreviated, and grouped by hand rather than toLocaleString so it is locale-independent.
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

        /// Whole sentences so translators can reorder; a missing entry falls back to English.
        t(text, vars) {
            const source = String(text);
            const hit = this.lookup(source);
            if (hit != null) return fill(hit, vars);
            this.sources.add(source);
            const out = fill(source, vars);
            this.want(source);
            this.remember(out, source, vars);
            return out;
        },

        translateDom(root) {
            if (!root || !this.settled || this.lang === 'en') return;
            walkText(root, (node) => {
                const next = this.swap(node.nodeValue);
                if (next != null) node.nodeValue = next;
            });
            walkAttributes(root, (el, attr, value) => {
                const next = this.swap(value);
                if (next != null) el.setAttribute(attr, next);
            });
        }
    };

    const RTL = new Set(['ar', 'he', 'fa', 'ur', 'ps', 'sd', 'ckb', 'yi', 'dv']);

    I18n.ready = I18n.init();
    window.NymbotI18n = I18n;
    /// The extractor looks for `t('…')` in app/js/*.js.
    window.t = (text, vars) => I18n.t(text, vars);
    window.amount = (value, places) => I18n.amount(value, places);
})();
