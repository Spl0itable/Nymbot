// A small relay pool: publish, one-shot fetch, and a live subscription.
// Through the worker's proxy when it answers, direct sockets when it does not.
// The relay set is the one the worker itself reads from.
(function () {
    'use strict';

    const C = window.NymbotConfig;

    function subId() {
        return 'nb' + Math.random().toString(36).slice(2, 10);
    }

    const Relays = {
        sockets: new Map(),      // url -> WebSocket
        _subs: new Map(),        // subId -> { filter, onEvent }
        _listeners: new Set(),   // status change callbacks
        _upstream: [],           // relays the proxy says it has
        _direct: false,          // proxy unreachable, on our own sockets
        _tries: 0,
        _timer: null,

        get connected() {
            if (this.pooled) return this._upstream.length || 1;
            let n = 0;
            for (const ws of this.sockets.values()) if (ws.readyState === 1) n++;
            return n;
        },

        get poolUrl() {
            return C.apiHost ? 'wss://' + C.apiHost + '/api/relay-pool' : null;
        },

        get pooled() {
            const ws = this.poolUrl && this.sockets.get(this.poolUrl);
            return !!(ws && ws.readyState === 1);
        },

        onStatus(fn) { this._listeners.add(fn); },

        _emit() {
            for (const fn of this._listeners) { try { fn(this.connected, C.relays.length); } catch (_) { } }
        },

        connect() {
            if (!this._direct && this._openPool()) return;
            this._connectDirect();
        },

        _connectDirect() {
            for (const url of C.relays) this._open(url);
        },

        /// The proxy speaks relay frames, so it is one more entry in `sockets`.
        _openPool() {
            const url = this.poolUrl;
            if (!url) return false;
            const live = this.sockets.get(url);
            if (live && (live.readyState === 0 || live.readyState === 1)) return true;
            let ws;
            try { ws = new WebSocket(url); } catch (_) { return false; }
            this.sockets.set(url, ws);
            this._upstream = [];
            let up = false;
            const bail = setTimeout(() => { if (!up) { try { ws.close(); } catch (_) { } } }, 8000);
            ws.addEventListener('open', () => {
                up = true;
                clearTimeout(bail);
                this._tries = 0;
                try { ws.send(JSON.stringify(['RELAYS', { critical: C.relays }])); } catch (_) { }
                for (const [id, sub] of this._subs) {
                    try { ws.send(JSON.stringify(['REQ', id, sub.filter])); } catch (_) { }
                }
                this._retireDirect();
                this._emit();
            });
            ws.addEventListener('message', (m) => {
                let data;
                try { data = JSON.parse(m.data); } catch (_) { return; }
                if (!Array.isArray(data)) return;
                if (data[0] === 'POOL:STATUS') {
                    this._upstream = (data[1] && data[1].connected) || [];
                    this._emit();
                    return;
                }
                if (data[0] === 'EVENT') {
                    const sub = this._subs.get(data[1]);
                    if (sub && data[2]) { try { sub.onEvent(data[2], url); } catch (_) { } }
                }
            });
            ws.addEventListener('close', () => {
                clearTimeout(bail);
                if (this.sockets.get(url) === ws) this.sockets.delete(url);
                this._upstream = [];
                this._emit();
                this._fallBack();
            });
            ws.addEventListener('error', () => { try { ws.close(); } catch (_) { } });
            return true;
        },

        _fallBack() {
            this._direct = true;
            this._connectDirect();
            this._retryPool();
        },

        _retryPool() {
            if (this._timer || this.pooled) return;
            const wait = Math.min(15000 * Math.pow(2, this._tries++), 120000);
            this._timer = setTimeout(() => {
                this._timer = null;
                if (this.pooled) return;
                this._direct = false;
                if (!this._openPool()) this._fallBack();
            }, wait + Math.random() * 4000);
        },

        /// Drops the direct sockets the proxy replaced, reconnects included.
        _retireDirect() {
            this._direct = false;
            const keep = this.poolUrl;
            for (const [u, ws] of [...this.sockets]) {
                if (u === keep) continue;
                this.sockets.delete(u);
                ws._retired = true;
                try { ws.close(); } catch (_) { }
            }
        },

        _open(url) {
            if (this.sockets.has(url)) {
                const existing = this.sockets.get(url);
                if (existing.readyState === 0 || existing.readyState === 1) return;
            }
            let ws;
            try { ws = new WebSocket(url); } catch (_) { return; }
            this.sockets.set(url, ws);
            ws.addEventListener('open', () => {
                this._emit();
                for (const [id, sub] of this._subs) {
                    try { ws.send(JSON.stringify(['REQ', id, sub.filter])); } catch (_) { }
                }
            });
            ws.addEventListener('message', (m) => {
                let data;
                try { data = JSON.parse(m.data); } catch (_) { return; }
                if (!Array.isArray(data)) return;
                if (data[0] === 'EVENT') {
                    const sub = this._subs.get(data[1]);
                    if (sub && data[2]) { try { sub.onEvent(data[2], url); } catch (_) { } }
                }
            });
            ws.addEventListener('close', () => {
                if (this.sockets.get(url) === ws) this.sockets.delete(url);
                this._emit();
                if (ws._retired || this.pooled) return;
                // Staggered so a relay that drops everyone at once is not met
                // with a synchronised stampede.
                setTimeout(() => this._open(url), 4000 + Math.random() * 6000);
            });
            ws.addEventListener('error', () => { try { ws.close(); } catch (_) { } });
        },

        /// Publishes to every open relay and resolves with how many said OK.
        /// One acceptance is enough for the worker to find the wrap, so the
        /// caller waits for the first rather than for all of them.
        publish(event, timeoutMs) {
            const open = [...this.sockets.entries()].filter(([, ws]) => ws.readyState === 1);
            if (open.length === 0) return Promise.resolve(0);
            const need = this.pooled ? 1 : 2;
            return new Promise((resolve) => {
                let accepted = 0;
                let settled = false;
                const finish = () => {
                    if (settled) return;
                    settled = true;
                    for (const [, ws] of open) ws.removeEventListener('message', onMessage);
                    resolve(accepted);
                };
                const onMessage = (m) => {
                    let data;
                    try { data = JSON.parse(m.data); } catch (_) { return; }
                    if (Array.isArray(data) && data[0] === 'OK' && data[1] === event.id && data[2] !== false) {
                        accepted++;
                        // Two is enough redundancy; the proxy sends one OK per
                        // event however many relays took it, so there one is.
                        if (accepted >= need) finish();
                    }
                };
                for (const [, ws] of open) {
                    ws.addEventListener('message', onMessage);
                    try { ws.send(JSON.stringify(['EVENT', event])); } catch (_) { }
                }
                setTimeout(finish, timeoutMs || 4000);
            });
        },

        /// One-shot query against relays this app does not keep open.
        fetchFrom(urls, filter, timeoutMs) {
            const list = (urls || []).filter(u => /^wss?:\/\//i.test(u)).slice(0, 8);
            if (!list.length) return Promise.resolve([]);
            return new Promise((resolve) => {
                const found = new Map();
                const opened = [];
                let done = 0;
                let settled = false;
                const finish = () => {
                    if (settled) return;
                    settled = true;
                    clearTimeout(timer);
                    for (const ws of opened) { try { ws.close(); } catch (_) { } }
                    resolve([...found.values()]);
                };
                const timer = setTimeout(finish, timeoutMs || 6000);
                const id = subId();
                // Proxied while the pool is up; one direct retry if that fails.
                const dial = (url, viaProxy) => {
                    const target = viaProxy
                        ? 'wss://' + C.apiHost + '/api/relay?relay=' + encodeURIComponent(url)
                        : url;
                    let ws;
                    try { ws = new WebSocket(target); } catch (_) { return retry(url, viaProxy); }
                    opened.push(ws);
                    let spoke = false;
                    ws.addEventListener('open', () => {
                        try { ws.send(JSON.stringify(['REQ', id, filter])); } catch (_) { }
                    });
                    ws.addEventListener('message', (m) => {
                        let data;
                        try { data = JSON.parse(m.data); } catch (_) { return; }
                        if (!Array.isArray(data) || data[1] !== id) return;
                        spoke = true;
                        if (data[0] === 'EVENT' && data[2] && data[2].id) found.set(data[2].id, data[2]);
                        else if (data[0] === 'EOSE' && ++done >= list.length) finish();
                    });
                    const gone = () => {
                        if (spoke || settled) return;
                        spoke = true;
                        retry(url, viaProxy);
                    };
                    ws.addEventListener('error', gone);
                    ws.addEventListener('close', gone);
                };
                const retry = (url, viaProxy) => {
                    if (viaProxy) return dial(url, false);
                    if (++done >= list.length) finish();
                };
                const proxy = this.pooled && !!C.apiHost;
                for (const url of list) dial(url, proxy);
            });
        },

        /// One-shot query across the pool, de-duplicated by event id.
        fetch(filter, timeoutMs) {
            const open = [...this.sockets.entries()].filter(([, ws]) => ws.readyState === 1);
            if (open.length === 0) return Promise.resolve([]);
            return new Promise((resolve) => {
                const id = subId();
                const found = new Map();
                let settled = false;
                let eose = 0;
                const finish = () => {
                    if (settled) return;
                    settled = true;
                    for (const [, ws] of open) {
                        ws.removeEventListener('message', onMessage);
                        try { ws.send(JSON.stringify(['CLOSE', id])); } catch (_) { }
                    }
                    resolve([...found.values()]);
                };
                const onMessage = (m) => {
                    let data;
                    try { data = JSON.parse(m.data); } catch (_) { return; }
                    if (!Array.isArray(data) || data[1] !== id) return;
                    if (data[0] === 'EVENT' && data[2] && data[2].id) found.set(data[2].id, data[2]);
                    else if (data[0] === 'EOSE' && ++eose >= open.length) finish();
                };
                for (const [, ws] of open) {
                    ws.addEventListener('message', onMessage);
                    try { ws.send(JSON.stringify(['REQ', id, filter])); } catch (_) { }
                }
                setTimeout(finish, timeoutMs || 4000);
            });
        },

        /// A standing subscription, replayed onto relays as they reconnect.
        subscribe(filter, onEvent) {
            const id = subId();
            this._subs.set(id, { filter, onEvent });
            for (const [, ws] of this.sockets) {
                if (ws.readyState === 1) {
                    try { ws.send(JSON.stringify(['REQ', id, filter])); } catch (_) { }
                }
            }
            return () => {
                this._subs.delete(id);
                for (const [, ws] of this.sockets) {
                    if (ws.readyState === 1) {
                        try { ws.send(JSON.stringify(['CLOSE', id])); } catch (_) { }
                    }
                }
            };
        }
    };

    window.NymbotRelays = Relays;
})();
