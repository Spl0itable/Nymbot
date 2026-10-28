(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;
    const Relays = window.NymbotRelays;
    const Identity = window.NymbotIdentity;
    const NT = () => window.NostrTools;
    const Wire = () => window.NymbotWire;
    const PQ = () => window.NymbotPQ;
    const Edge = () => window.NymbotEdge;

    const ID = 'support';
    const TAG = 'nymbot-support';
    const TOKENS_KEY = 'supportTokens';
    const CURSOR_KEY = 'supportCursor';
    const SEEN_KEY = 'supportSeen';
    const STORED_KEY = 'supportStored';
    const STORED_PAGES = 4;
    const STORED_LIMIT = 100;
    const STORED_OVERLAP_MS = 60000;
    const TOKENS_MAX = 4;
    const SEEN_MAX = 1000;
    const LOOKBACK_SEC = 2 * 86400;
    const TEXT_MAX = 20000;
    const HEX64 = /^[0-9a-f]{64}$/;

    function randomToken() {
        return Array.from(crypto.getRandomValues(new Uint8Array(32)))
            .map(b => b.toString(16).padStart(2, '0')).join('');
    }

    function tidyTokens(list) {
        const best = new Map();
        for (const entry of Array.isArray(list) ? list : []) {
            const token = entry && typeof entry.token === 'string' ? entry.token : '';
            if (!HEX64.test(token)) continue;
            const at = typeof entry.at === 'number' && Number.isFinite(entry.at) ? Math.trunc(entry.at) : 0;
            if (!best.has(token) || at < best.get(token)) best.set(token, at);
        }
        return Array.from(best, ([token, at]) => ({ token, at }))
            .sort((a, b) => (b.at - a.at) || (a.token < b.token ? -1 : a.token > b.token ? 1 : 0))
            .slice(0, TOKENS_MAX);
    }

    function tagValue(evt, name) {
        const hit = (evt && Array.isArray(evt.tags) ? evt.tags : []).find(x => Array.isArray(x) && x[0] === name);
        return hit ? hit[1] : null;
    }

    function tagValues(evt, name) {
        return (evt && Array.isArray(evt.tags) ? evt.tags : [])
            .filter(x => Array.isArray(x) && x[0] === name).map(x => x[1]);
    }

    const Support = {
        ID,
        _unsub: null,
        _key: null,
        _chain: Promise.resolve(),
        _wraps: new Set(),
        _resumeBound: false,
        _storing: null,
        viewing: () => false,
        changed: () => { },
        replied: () => { },

        attach(opts) {
            const o = opts || {};
            if (typeof o.viewing === 'function') this.viewing = o.viewing;
            if (typeof o.changed === 'function') this.changed = o.changed;
            if (typeof o.replied === 'function') this.replied = o.replied;
            if (!this._resumeBound) {
                this._resumeBound = true;
                document.addEventListener('visibilitychange', () => {
                    if (!document.hidden) this.catchUp();
                });
                window.addEventListener('online', () => this.catchUp());
            }
            this.start();
        },

        thread() {
            const conv = Store.conversation(ID);
            return conv && conv.support ? conv : null;
        },

        isSupport(conv) {
            return !!(conv && conv.support);
        },

        ensureThread(at) {
            const held = this.thread();
            if (held) return held;
            const when = Number(at) || Date.now();
            return Store.createConversation({
                id: ID,
                support: true,
                title: 'Support',
                anon: false,
                ephemeral: false,
                rootId: ID,
                unread: 0,
                createdAt: when,
                updatedAt: when
            });
        },

        tokens() {
            return tidyTokens(Store.read(TOKENS_KEY, []));
        },

        token(create) {
            const list = this.tokens();
            if (list.length) return list[0].token;
            if (!create) return null;
            const token = randomToken();
            Store.write(TOKENS_KEY, tidyTokens([{ token, at: Date.now() }]));
            return token;
        },

        syncCopy() {
            const list = this.tokens();
            return list.length ? list : null;
        },

        syncMerge(remote) {
            const mine = this.tokens();
            const merged = tidyTokens(mine.concat(Array.isArray(remote) ? remote : []));
            if (JSON.stringify(merged) === JSON.stringify(mine)) return false;
            Store.write(TOKENS_KEY, merged);
            return true;
        },

        cursor() {
            const held = Store.read(CURSOR_KEY, null);
            if (!held || typeof held !== 'object' || held.pk !== Identity.pubkey) return 0;
            return Number(held.at) || 0;
        },

        advance(createdAt) {
            const at = Math.min(Number(createdAt) || 0, Math.floor(Date.now() / 1000));
            if (!(at > this.cursor())) return;
            Store.write(CURSOR_KEY, { pk: Identity.pubkey, at });
        },

        seen() {
            const held = Store.read(SEEN_KEY, null);
            if (!held || typeof held !== 'object' || held.pk !== Identity.pubkey || !Array.isArray(held.ids)) return [];
            return held.ids;
        },

        markSeen(id) {
            const ids = this.seen().filter(x => x !== id);
            ids.push(id);
            Store.write(SEEN_KEY, { pk: Identity.pubkey, ids: ids.slice(-SEEN_MAX) });
        },

        since() {
            const cursor = this.cursor();
            let base = cursor;
            if (!base) {
                const msgs = Store.messages(ID);
                const first = msgs.reduce((m, x) => Math.min(m, Number(x.ts) || Infinity), Infinity);
                const conv = this.thread();
                const start = Number.isFinite(first) ? first : (conv && conv.createdAt) || Date.now();
                base = Math.floor(start / 1000);
            }
            return Math.max(0, base - LOOKBACK_SEC);
        },

        filter() {
            const tokens = this.tokens().map(x => x.token);
            if (!Identity.pubkey || !tokens.length || !this.thread()) return null;
            return { kinds: [1059], '#p': [Identity.pubkey], '#t': tokens, since: this.since() };
        },

        start(opts) {
            const filter = this.filter();
            if (!filter) {
                this.stop();
                return false;
            }
            const key = JSON.stringify([filter['#p'], filter['#t']]);
            if (this._unsub && this._key === key) return true;
            this.stop();
            this._key = key;
            this._unsub = Relays.subscribe(filter, (event) => this.receive(event));
            if (!(opts && opts.quiet)) this.stored().catch(() => { });
            return true;
        },

        catchUp() {
            if (!this.filter()) return Promise.resolve(0);
            this.stop();
            return this.refresh();
        },

        storedPlanFrom(held, pk, since) {
            const mine = held && typeof held === 'object' && held.pk === pk;
            const c = mine && held.cursor && typeof held.cursor === 'object' ? held.cursor : null;
            if (c && Number.isSafeInteger(c.s) && c.s >= 0 && typeof c.id === 'string' && (c.id === '' || HEX64.test(c.id))) {
                return { cursor: { s: Math.max(0, c.s - STORED_OVERLAP_MS), id: '' }, floor: { s: c.s, id: c.id } };
            }
            const at = mine ? Number(held.at) || 0 : 0;
            const was = mine ? Number(held.since) : NaN;
            const from = at && Number.isFinite(was) && held.after && typeof held.after === 'object' ? was
                : at ? at - LOOKBACK_SEC : since;
            const s = Math.max(0, Math.floor(from)) * 1000;
            return { cursor: { s, id: '' }, floor: { s, id: '' } };
        },

        storedLater(next, floor) {
            const ahead = next.s > floor.s || (next.s === floor.s && next.id > floor.id);
            return ahead ? { s: next.s, id: next.id } : { s: floor.s, id: floor.id };
        },

        storedWalk(next, floor, more, page) {
            const ahead = next.s > floor.s || (next.s === floor.s && next.id > floor.id);
            return more === true && !ahead && page < STORED_PAGES - 2;
        },

        storedPlan(pk) {
            return this.storedPlanFrom(Store.read(STORED_KEY, null), pk, this.since());
        },

        stored() {
            if (this._storing) return this._storing;
            const pk = Identity.pubkey;
            const tokens = this.tokens().map(x => x.token);
            if (!pk || !tokens.length || !this.thread() || !C.apiHost || !Edge()) return Promise.resolve(0);
            const plan = this.storedPlan(pk);
            const run = async () => {
                let cursor = plan.cursor;
                let floor = plan.floor;
                const handed = new Set();
                let got = 0;
                for (let page = 0; page < STORED_PAGES; page++) {
                    let data = null;
                    try {
                        const resp = await Edge().fetch('https://' + C.apiHost + '/api/storage', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ action: 'pm-support', pubkey: pk, tokens, cursor, limit: STORED_LIMIT })
                        });
                        data = resp && resp.ok ? await resp.json() : null;
                    } catch (_) { data = null; }
                    const next = data && data.cursor;
                    if (!data || !Array.isArray(data.events) || !next || !Number.isSafeInteger(next.s) || typeof next.id !== 'string') return got;
                    for (const event of data.events) {
                        const id = event && typeof event.id === 'string' ? event.id : '';
                        if (!id || handed.has(id) || this._wraps.has(id)) continue;
                        handed.add(id);
                        this.receive(event);
                        got++;
                    }
                    await this._chain;
                    if (Identity.pubkey !== pk) return got;
                    if (this.storedWalk(next, floor, data.more, page)) {
                        cursor = { s: next.s, id: next.id };
                        continue;
                    }
                    cursor = this.storedLater(next, floor);
                    floor = cursor;
                    Store.write(STORED_KEY, { pk, cursor });
                    if (data.more !== true) return got;
                }
                return got;
            };
            this._storing = run().finally(() => { this._storing = null; });
            return this._storing;
        },

        stop() {
            if (this._unsub) {
                try { this._unsub(); } catch (_) { }
            }
            this._unsub = null;
            this._key = null;
        },

        async refresh() {
            const filter = this.filter();
            if (!filter) return 0;
            this.start();
            let events = [];
            try { events = await Relays.fetch(filter, 5000); } catch (_) { events = []; }
            for (const event of events || []) this.receive(event);
            return (events || []).length;
        },

        receive(event) {
            if (!event || event.kind !== 1059 || typeof event.id !== 'string' || this._wraps.has(event.id)) return this._chain;
            if (!tagValues(event, 'p').includes(Identity.pubkey)) return this._chain;
            this._wraps.add(event.id);
            this._chain = this._chain.then(() => this.open(event)).catch(() => { });
            return this._chain;
        },

        async open(event) {
            if (!this.thread()) return null;
            const W = Wire();
            const me = Identity.pubkey;
            const dev = C.developerPubkey;
            const tokens = this.tokens().map(x => x.token);
            if (!tagValues(event, 't').some(v => tokens.includes(v))) return null;
            try {
                if (!NT().verifyEvent(event)) return null;
            } catch (_) { return null; }
            let opened = null;
            try { opened = await W.unwrap(event); } catch (_) { opened = null; }
            if (!opened || !opened.rumor) return null;
            const rumor = opened.rumor;
            if (rumor.kind !== 14 || typeof rumor.content !== 'string' || !Array.isArray(rumor.tags)) return null;
            let id;
            try { id = NT().getEventHash(rumor); } catch (_) { return null; }
            if (rumor.id !== id) return null;
            const ps = tagValues(rumor, 'p');
            let role = null;
            if (dev !== me && W.sealedBy(opened, dev)) {
                if (!ps.includes(me)) return null;
                role = 'bot';
            } else if (W.sealedBy(opened, me) && ps.includes(dev)) {
                role = 'self';
            }
            if (!role) return null;
            this.advance(event.created_at);
            return this.record(rumor, role, { incoming: true });
        },

        messageFor(rumor, role) {
            const ms = Number(tagValue(rumor, 'ms'));
            const sec = Number(rumor.created_at) || Math.floor(Date.now() / 1000);
            const ts = Number.isFinite(ms) && Math.abs(ms / 1000 - sec) < 600 ? ms : sec * 1000;
            return {
                id: rumor.id,
                role,
                content: String(rumor.content).slice(0, TEXT_MAX),
                support: true,
                ts
            };
        },

        record(rumor, role, opts) {
            const o = opts || {};
            if (!rumor || !HEX64.test(rumor.id || '')) return null;
            if (this.seen().includes(rumor.id)) return null;
            const msg = this.messageFor(rumor, role);
            const conv = this.ensureThread(msg.ts);
            const msgs = Store.messages(ID);
            if (msgs.some(m => m.id === rumor.id)) {
                this.markSeen(rumor.id);
                return null;
            }
            msgs.push(msg);
            msgs.sort((a, b) => (a.ts || 0) - (b.ts || 0));
            Store.saveMessages(ID, msgs);
            this.markSeen(rumor.id);
            const watching = !!this.viewing();
            const unread = role === 'bot' && o.incoming && !watching
                ? (Number(conv.unread) || 0) + 1
                : (Number(conv.unread) || 0);
            Store.updateConversation(ID, { unread });
            try { this.changed(msg, { incoming: !!o.incoming }); } catch (_) { }
            if (role === 'bot' && o.incoming) {
                try { this.replied(msg, { watching }); } catch (_) { }
            }
            this.start({ quiet: true });
            return msg;
        },

        markRead() {
            const conv = this.thread();
            if (conv && conv.unread) Store.updateConversation(ID, { unread: 0, silent: true });
        },

        async send(text, opts) {
            const o = opts || {};
            const W = Wire();
            const dev = C.developerPubkey;
            const me = Identity.pubkey;
            if (!me) throw new Error(t('Sign in first.'));
            const body = o.topic
                ? '[Nymbot contact — ' + o.topic + ']\n\n' + text
                : String(text);
            const token = this.token(true);
            let kem = null;
            try {
                const key = await PQ().resolve(dev);
                kem = key && key.pk ? key.pk : null;
            } catch (_) { kem = null; }
            const rumor = W.rumor(body, dev, null, null, me);
            rumor.tags.push([TAG, token]);
            rumor.id = NT().getEventHash(rumor);
            const outer = [['t', token]];
            const wrap = await W.wrap(rumor, dev, kem, undefined, outer);
            const selfKem = Identity.rootLocked || !Identity._kem ? null : Identity.kemPk;
            let copy = null;
            try { copy = await W.wrap(rumor, me, selfKem, undefined, outer); } catch (_) { copy = null; }
            const accepted = await Relays.publish(wrap, 5000);
            if (!(accepted > 0)) return accepted;
            this.record(rumor, 'self');
            if (copy) {
                try { await Relays.publish(copy, 5000); } catch (_) { }
            }
            this.start();
            return accepted;
        }
    };

    window.NymbotSupport = Support;
})();
