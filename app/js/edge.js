(function () {
    'use strict';

    const C = window.NymbotConfig;

    const RELOAD_MIN_MS = 60000;
    const RELOAD_WINDOW_MS = 15 * 60 * 1000;
    const RELOAD_MAX = 3;
    const CONFIRM_MS = 1500;
    const NOTE_MIN_MS = 30000;
    const KEY = 'nymbot_edge_challenge_reloads';

    const Edge = {
        _notedAt: 0,

        async pending() {
            if (!C.apiHost) return false;
            try {
                const resp = await fetch('/robots.txt?t=' + Date.now(), { cache: 'no-store', credentials: 'same-origin' });
                return resp.headers.get('cf-mitigated') === 'challenge';
            } catch (_) {
                return false;
            }
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
            location.reload();
            return true;
        },

        async recover() {
            if (!(await this.pending())) return false;
            await new Promise((r) => setTimeout(r, CONFIRM_MS));
            if (!(await this.pending())) return false;
            return this.reload();
        },

        nudge() {
            const now = Date.now();
            if (this._notedAt && now - this._notedAt < NOTE_MIN_MS) return;
            this._notedAt = now;
            this.recover().catch(() => { });
        },

        note(resp) {
            if (!resp || resp.status !== 403 || !resp.headers || typeof resp.headers.get !== 'function') return resp;
            if (resp.headers.get('cf-mitigated') !== 'challenge') return resp;
            this.nudge();
            return resp;
        },

        async fetch(url, opts) {
            const resp = await fetch(url, opts);
            return this.note(resp);
        }
    };

    window.NymbotEdge = Edge;
})();
