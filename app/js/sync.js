// Your settings and your conversations, on every device you sign in on.
(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;
    const Identity = window.NymbotIdentity;
    const NT = () => window.NostrTools;
    const NC = () => window.NymCrypto;

    const url = () => `https://${C.apiHost}/api/storage`;

    // One row per conversation, plus the four fixed ones.
    const MAX_CHATS = 400;
    // Messages per conversation.
    const MAX_MESSAGES = 400;
    // Deleting on one device must not be undone by another that still has the record.
    const TOMBSTONE_MS = 60 * 24 * 3600 * 1000;

    const LIBRARY = [
        ['personas', () => Store.customPersonas(), (v) => Store.write('personas', v)],
        ['prompts', () => Store.read('prompts', null), (v) => Store.write('prompts', v)],
        ['workspaces', () => Store.workspaces(), (v) => Store.write('workspaces', v)],
        ['folders', () => Store.folders(), (v) => Store.write('folders', v)],
        ['schedules', () => Store.schedules(), (v) => Store.write('schedules', v)],
        ['memories', () => Store.memories(), (v) => Store.write('memories', v)],
        ['bots', () => Store.read('bots', null), (v) => Store.write('bots', v)],
        ['favouriteModels', () => Store.read('favouriteModels', null), (v) => Store.write('favouriteModels', v)]
    ];

    function hex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    async function sha256Hex(text) {
        const bytes = new TextEncoder().encode(text);
        return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
    }

    /// The name the row is stored under.
    async function categoryFor(dTag) {
        return 'nymbot-' + (await sha256Hex(Identity.pubkey + '|d1:' + dTag)).slice(0, 48);
    }

    /// Sealing hybrid is only worth it if this device can also open it again: the
    /// KEM secret is derived from the root, which a signer login does not have.
    function selfKem() {
        return (Identity._sk && Identity._kem) ? Identity.kemPk : null;
    }

    async function seal(plaintext) {
        const kem = selfKem();
        if (Identity._sk) {
            if (kem) {
                try { return NC().pq2Encrypt(plaintext, Identity._sk, Identity.pubkey, kem); } catch (_) { }
            }
            const T = NT();
            return T.nip44.encrypt(plaintext, T.nip44.getConversationKey(Identity._sk, Identity.pubkey));
        }
        // An extension holds the key: it does the NIP-44 on our behalf, which is
        // classical only.
        return window.nostr.nip44.encrypt(Identity.pubkey, plaintext);
    }

    async function open(blob) {
        const NCx = NC();
        if (Identity._sk) {
            if (NCx.isPq2Payload(blob) && Identity._kem) {
                return NCx.pq2Decrypt(blob, Identity.pubkey, {
                    sk: Identity._sk,
                    kemSk: Identity._kem.secretKey,
                    kemPk: Identity._kem.publicKey
                });
            }
            const T = NT();
            return T.nip44.decrypt(blob, T.nip44.getConversationKey(Identity._sk, Identity.pubkey));
        }
        // A signer login cannot open the hybrid layer: it never holds the KEM secret.
        if (NCx.isPq2Payload(blob)) throw new Error('needs the local key');
        return window.nostr.nip44.decrypt(Identity.pubkey, blob);
    }

    async function auth(action) {
        const event = {
            kind: 27235,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['domain', 'nymbot-sync'],
                ['method', 'POST'],
                ['u', url()],
                ['action', action]
            ],
            content: 'nymbot-sync-auth'
        };
        return Identity.signEvent(event);
    }

    async function call(action, extra) {
        const body = Object.assign(
            { action, pubkey: Identity.pubkey, auth: await auth(action) }, extra || {});
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 20000);
        try {
            const resp = await fetch(url(), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body),
                signal: controller.signal
            });
            return await resp.json().catch(() => null);
        } catch (_) {
            return null;
        } finally {
            clearTimeout(timer);
        }
    }

    /// Newest wins, by whatever each record calls its clock.
    function stamp(record) {
        if (!record || typeof record !== 'object') return 0;
        return Number(record.updatedAt || record.at || record.createdAt || record.ts) || 0;
    }

    /// Merges two lists of {id} records: the union, newest of each, minus
    /// anything either side has since deleted.
    function mergeById(mine, theirs, graves) {
        const out = new Map();
        for (const record of [].concat(theirs || [], mine || [])) {
            if (!record || !record.id) continue;
            if (graves && graves[record.id]) continue;
            const held = out.get(record.id);
            if (!held || stamp(record) >= stamp(held)) out.set(record.id, record);
        }
        return Array.from(out.values());
    }

    const Sync = {
        /// Set once a pull has come back with rows this device could not open — a
        /// key that has not been linked yet.
        blocked: false,
        lastAt: 0,
        _timer: null,
        _running: null,
        _following: null,
        _again: false,
        _hashes: new Map(),
        onChange: null,

        enabled() {
            return !!(Identity.pubkey && Store.settings().sync !== false);
        },

        /// Every record this device has deleted, so a device that still holds it
        /// does not push it back.
        graves() {
            const held = Store.read('sync_graves', {}) || {};
            const cutoff = Date.now() - TOMBSTONE_MS;
            let changed = false;
            for (const id of Object.keys(held)) {
                if (!(held[id] > cutoff)) { delete held[id]; changed = true; }
            }
            if (changed) Store.write('sync_graves', held);
            return held;
        },

        bury(id) {
            if (!id) return;
            const held = this.graves();
            held[id] = Date.now();
            Store.write('sync_graves', held);
        },

        /// What this device would put on the server right now.
        snapshot() {
            const graves = this.graves();
            const out = {};
            out['settings'] = Store.settings();

            const library = {};
            for (const [name, get] of LIBRARY) {
                const value = get();
                if (value != null) library[name] = value;
            }
            // A repository travels without its token: the token stays on the
            // device that was given it and is sent per request.
            library.repos = Store.repos().map(r => {
                const copy = Object.assign({}, r);
                delete copy.token;
                copy.tokenElsewhere = !!r.token;
                return copy;
            });
            out['library'] = library;

            const chats = Store.conversations()
                .filter(c => c && c.id && !c.ephemeral && !Store.isGhost(c.id) && !graves[c.id])
                .slice(0, MAX_CHATS);
            out['chats'] = chats.map(c => Object.assign({}, c));
            for (const conv of chats) {
                const msgs = Store.messages(conv.id);
                if (!msgs.length) continue;
                out['chat-' + conv.id] = { id: conv.id, messages: msgs.slice(-MAX_MESSAGES) };
            }
            out['graves'] = graves;
            return out;
        },

        /// Folds what came back into what is here.
        apply(remote) {
            if (!remote || typeof remote !== 'object') return [];
            const touched = [];
            const graves = Object.assign({}, this.graves(), remote.graves || {});
            Store.write('sync_graves', graves);

            if (remote.settings && typeof remote.settings === 'object') {
                // The local ones win on the keys this device has changed since
                // its last push; everything else comes across.
                const merged = Object.assign({}, remote.settings, Store.read('settings', {}) || {});
                Store.write('settings', merged);
                touched.push('settings');
            }

            if (remote.library && typeof remote.library === 'object') {
                for (const [name, get, set] of LIBRARY) {
                    const theirs = remote.library[name];
                    if (!Array.isArray(theirs)) continue;
                    const mine = get() || [];
                    // A list of ids merges by id; a list of plain values (the
                    // favourites) is a set.
                    const merged = theirs.length && typeof theirs[0] === 'object'
                        ? mergeById(mine, theirs, graves)
                        : Array.from(new Set([].concat(mine, theirs)));
                    set(merged);
                    touched.push(name);
                }
                if (Array.isArray(remote.library.repos)) {
                    const mine = Store.repos();
                    const byId = new Map(mine.map(r => [r.id, r]));
                    const merged = mergeById(mine, remote.library.repos, graves).map(r => {
                        // Never let a remote row blank a token this device holds.
                        const held = byId.get(r.id);
                        const copy = Object.assign({}, r);
                        if (held && held.token) copy.token = held.token;
                        else delete copy.token;
                        return copy;
                    });
                    Store.saveRepos(merged);
                    touched.push('repos');
                }
            }

            if (Array.isArray(remote.chats)) {
                const mine = Store.conversations();
                const ghosts = new Set(mine.filter(c => Store.isGhost(c.id)).map(c => c.id));
                const incoming = remote.chats.filter(c => c && c.id && !ghosts.has(c.id));
                const merged = mergeById(mine, incoming, graves)
                    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
                Store.saveConversations(merged);
                touched.push('chats');
            }

            for (const key of Object.keys(remote)) {
                if (key.indexOf('chat-') !== 0) continue;
                const entry = remote[key];
                if (!entry || !entry.id || !Array.isArray(entry.messages)) continue;
                if (graves[entry.id] || Store.isGhost(entry.id)) continue;
                const mine = Store.messages(entry.id);
                const merged = mergeById(mine, entry.messages, graves)
                    .sort((a, b) => (a.ts || 0) - (b.ts || 0));
                if (merged.length !== mine.length) {
                    Store.saveMessages(entry.id, merged);
                    touched.push(key);
                }
            }
            return touched;
        },

        /// Reads every row back and decrypts it.
        async pull() {
            const data = await call('settings-get', {});
            if (!data || !data.categories || typeof data.categories !== 'object') return null;
            const out = {};
            let unreadable = 0;
            for (const entry of Object.values(data.categories)) {
                if (!entry || typeof entry.blob !== 'string') continue;
                let payload;
                try {
                    payload = JSON.parse(await open(entry.blob));
                } catch (_) { unreadable++; continue; }
                if (!payload || typeof payload !== 'object') continue;
                const name = typeof payload.__cat === 'string' ? payload.__cat : null;
                if (!name) continue;
                delete payload.__cat;
                out[name] = payload.v !== undefined ? payload.v : payload;
            }
            // Rows exist and none of them opened: this device holds a key that
            // cannot read the account's own settings, so it must not write.
            this.blocked = unreadable > 0 && Object.keys(out).length === 0;
            return out;
        },

        async push(dTag, value) {
            if (this.blocked) return false;
            const plain = JSON.stringify({ __cat: dTag, v: value });
            const category = await categoryFor(dTag);
            const hash = await sha256Hex(Identity.pubkey + '|' + (selfKem() ? 'pq' : 'c') + '|' + plain);
            if (this._hashes.get(category) === hash) return true;
            const blob = await seal(plain);
            if (!blob) return false;
            const resp = await call('settings-set', { category, blob, contentHash: hash });
            if (!resp || resp.error) return false;
            this._hashes.set(category, hash);
            return true;
        },

        /// One round: read what is there, fold it in, write back what changed.
        async run(opts) {
            if (!this.enabled()) return { skipped: true };
            // Already going.
            if (this._running) {
                this._again = true;
                return this._running;
            }
            const options = opts || {};
            this._running = (async () => {
                let touched = [];
                try {
                    const remote = await this.pull();
                    if (remote === null) return { offline: true };
                    touched = this.apply(remote);
                    if (this.blocked) return { blocked: true };
                    const local = this.snapshot();
                    // A row the server holds for a conversation this device has
                    // since deleted is emptied rather than left behind.
                    for (const key of Object.keys(remote)) {
                        if (key.indexOf('chat-') === 0 && !local[key]) local[key] = { id: '', messages: [] };
                    }
                    for (const [dTag, value] of Object.entries(local)) {
                        await this.push(dTag, value);
                    }
                    this.lastAt = Date.now();
                } catch (_) {
                    return { failed: true };
                } finally {
                    this._running = null;
                    if (this._again) {
                        this._again = false;
                        this.touch(600);
                    }
                }
                if (touched.length && typeof this.onChange === 'function') {
                    try { this.onChange(touched); } catch (_) { }
                }
                return { ok: true, touched, quiet: !!options.quiet };
            })();
            return this._running;
        },

        /// Follows the store, so nothing has to remember to call touch().
        follow() {
            if (this._following) return;
            this._following = Store.watch(() => this.touch());
        },

        /// Something changed here.
        touch(delay) {
            if (!this.enabled()) return;
            if (this._timer) clearTimeout(this._timer);
            this._timer = setTimeout(() => {
                this._timer = null;
                this.run({ quiet: true }).catch(() => { });
            }, delay || 4000);
        },

        /// Deletes this account's rows on the server, on the way out. Signed
        /// while the key is still here, sent keepalive so a reload cannot
        /// cancel it.
        async purge() {
            if (!Identity.pubkey) return false;
            let body;
            try {
                body = JSON.stringify({
                    action: 'account-purge',
                    app: 'nymbot',
                    pubkey: Identity.pubkey,
                    auth: await auth('account-purge')
                });
            } catch (_) { return false; }
            try {
                await fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body,
                    keepalive: true
                });
                return true;
            } catch (_) { return false; }
        },

        /// Everything this account has on the server, gone.
        async wipeRemote() {
            if (!Identity.pubkey) return false;
            const remote = await this.pull();
            if (!remote) return false;
            this.blocked = false;
            this._hashes.clear();
            for (const dTag of Object.keys(remote)) await this.push(dTag, null);
            return true;
        }
    };

    window.NymbotSync = Sync;
})();
