// A small relay pool: publish, one-shot fetch, and a live subscription.
//
// Direct WebSockets rather than a proxy. The relay set is the one the Nymbot
// worker itself reads from, because a wrap published anywhere else is one it
// can never fetch and open.
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

        get connected() {
            let n = 0;
            for (const ws of this.sockets.values()) if (ws.readyState === 1) n++;
            return n;
        },

        onStatus(fn) { this._listeners.add(fn); },

        _emit() {
            for (const fn of this._listeners) { try { fn(this.connected, C.relays.length); } catch (_) { } }
        },

        connect() {
            for (const url of C.relays) this._open(url);
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
                this._emit();
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
                        // Two acceptances is enough redundancy for a fetch that
                        // hits sixteen relays; waiting for more just adds latency
                        // to every message.
                        if (accepted >= 2) finish();
                    }
                };
                for (const [, ws] of open) {
                    ws.addEventListener('message', onMessage);
                    try { ws.send(JSON.stringify(['EVENT', event])); } catch (_) { }
                }
                setTimeout(finish, timeoutMs || 4000);
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
