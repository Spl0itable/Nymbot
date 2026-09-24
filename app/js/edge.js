(function () {
    'use strict';

    const C = window.NymbotConfig;

    const RELOAD_MIN_MS = 60000;
    const RELOAD_WINDOW_MS = 15 * 60 * 1000;
    const RELOAD_MAX = 3;
    const CONFIRM_MS = 1500;
    const NOTE_MIN_MS = 30000;
    const SETTLE_MS = 2500;
    const KEY = 'nymbot_edge_challenge_reloads';
    const PROBE_PARAM = 'edge-probe';
    const RELOAD_PARAM = 'edge-reload';
    const PROBES = ['/app/?' + PROBE_PARAM + '=', '/robots.txt?t='];

    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    async function probe(path) {
        const resp = await fetch(path + Date.now(), { cache: 'no-store', credentials: 'same-origin' });
        try { if (resp.body) resp.body.cancel().catch(() => { }); } catch (_) { }
        return resp.headers.get('cf-mitigated') === 'challenge';
    }

    const Edge = {
        _checkedAt: 0,
        _running: false,
        _settle: null,

        async pending() {
            if (!C.apiHost) return false;
            const answers = await Promise.allSettled(PROBES.map(probe));
            if (answers.some((a) => a.status === 'fulfilled' && a.value === true)) return true;
            if (answers.every((a) => a.status === 'rejected')) return null;
            return false;
        },

        reload() {
            const now = Date.now();
            let times = [];
            try { times = JSON.parse(sessionStorage.getItem(KEY) || '[]'); } catch (_) { times = []; }
            if (!Array.isArray(times)) times = [];
            times = times.filter((t) => typeof t === 'number' && now - t < RELOAD_WINDOW_MS);
            if (times.length && now - times[times.length - 1] < RELOAD_MIN_MS) return false;
            if (times.length >= RELOAD_MAX) return false;
            times.push(now);
            try { sessionStorage.setItem(KEY, JSON.stringify(times)); } catch (_) { }
            let target = null;
            try {
                const u = new URL(location.href);
                u.searchParams.set(RELOAD_PARAM, String(now));
                target = u.href;
            } catch (_) { target = null; }
            if (target) location.replace(target);
            else location.reload();
            return true;
        },

        async recover() {
            const first = await this.pending();
            if (first !== null) this._checkedAt = Date.now();
            if (first !== true) return false;
            await sleep(CONFIRM_MS);
            if ((await this.pending()) !== true) return false;
            return this.reload();
        },

        nudge() {
            if (this._running) return;
            const now = Date.now();
            if (this._checkedAt && now - this._checkedAt < NOTE_MIN_MS) return;
            this._running = true;
            this.recover().catch(() => false).finally(() => { this._running = false; });
        },

        networkChanged() {
            this._checkedAt = 0;
            clearTimeout(this._settle);
            this._settle = setTimeout(() => {
                this._settle = null;
                if (document.visibilityState === 'hidden') return;
                this.nudge();
            }, SETTLE_MS);
        },

        note(resp) {
            if (!resp || resp.status !== 403 || !resp.headers || typeof resp.headers.get !== 'function') return resp;
            if (resp.headers.get('cf-mitigated') !== 'challenge') return resp;
            this._checkedAt = 0;
            this.nudge();
            return resp;
        },

        async fetch(url, opts) {
            const resp = await fetch(url, opts);
            return this.note(resp);
        },

        _cleanUrl() {
            try {
                const u = new URL(location.href);
                if (!u.searchParams.has(RELOAD_PARAM)) return;
                u.searchParams.delete(RELOAD_PARAM);
                history.replaceState(history.state, '', u.pathname + u.search + u.hash);
            } catch (_) { }
        },

        watch() {
            this._cleanUrl();
            window.addEventListener('online', () => this.networkChanged());
            const conn = navigator.connection;
            if (conn && typeof conn.addEventListener === 'function') conn.addEventListener('change', () => this.networkChanged());
            document.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'visible') this.nudge();
            });
            window.addEventListener('pageshow', (e) => { if (e.persisted) this.networkChanged(); });
        }
    };

    window.NymbotEdge = Edge;
    Edge.watch();
})();
