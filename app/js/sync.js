(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;
    const Identity = window.NymbotIdentity;
    const Edge = window.NymbotEdge;
    const NT = () => window.NostrTools;
    const NC = () => window.NymCrypto;

    const url = () => `https://${C.apiHost}/api/storage`;

    // One row per conversation, plus the four fixed ones.
    const MAX_CHATS = 400;
    // Messages per conversation.
    const MAX_MESSAGES = 400;
    const ART_VERSIONS = 5;
    const ART_KEEP_VERSIONS = 30;
    const ART_MAX_CHARS = 240000;
    const ROW_MAX_BYTES = 240000;
    const ROW_HARD_BYTES = 880000;
    const SEAL_MAX_BYTES = 900000;
    const OVERLAP_MS = 10000;
    const FULL_EVERY_MS = 24 * 3600 * 1000;
    const PART_BYTES = 60000;
    const PARTS_PREFIX = 'parts1:';
    // Deleting on one device must not be undone by another that still has the record.
    const TOMBSTONE_MS = 60 * 24 * 3600 * 1000;
    const SUPPORT_ID = 'support';
    const CAS_RETRIES = 3;

    // Nymchat's row name, hashed its way: one account, one root, whichever app reached it first.
    const PQ_ROOT_D_TAG = 'nymchat-pq-root';

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

    async function categoryFor(dTag) {
        return 'nymbot-' + (await sha256Hex(Identity.pubkey + '|d1:' + dTag)).slice(0, 48);
    }

    /// Must match Nymchat's `_d1Category` byte for byte, or the root row is invisible to the other app.
    async function nymchatCategoryFor(pubkey, dTag) {
        return 'nymchat-' + await sha256Hex(pubkey + ':d1:' + dTag);
    }

    /// Hybrid only if this device can reopen it: signer logins lack the root, and a locked device holds a foreign one.
    function selfKem() {
        if (Identity.rootLocked) return null;
        return Identity._kem ? Identity.kemPk : null;
    }

    function utf8Bytes(text) {
        return new TextEncoder().encode(text).length;
    }

    function charBytes(ch) {
        const cp = ch.codePointAt(0);
        return cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    }

    function splitParts(text) {
        const parts = [];
        let current = '';
        let size = 0;
        for (const ch of text) {
            const n = charBytes(ch);
            if (size + n > PART_BYTES) {
                parts.push(current);
                current = '';
                size = 0;
            }
            current += ch;
            size += n;
        }
        if (current) parts.push(current);
        return parts;
    }

    function isParts(blob) {
        return typeof blob === 'string' && blob.startsWith(PARTS_PREFIX);
    }

    function partsOf(blob) {
        const parts = JSON.parse(blob.slice(PARTS_PREFIX.length));
        if (!Array.isArray(parts) || !parts.length || parts.some(p => typeof p !== 'string' || !p)) throw new Error('bad parts');
        return parts;
    }

    function blobMode(blob) {
        const first = isParts(blob) ? partsOf(blob)[0] : blob;
        return NC().isPq2Payload(first) ? 'pq' : 'c';
    }

    function fitMessages(msgs) {
        let total = 64;
        const sizes = msgs.map(m => {
            const n = utf8Bytes(JSON.stringify(m)) + 1;
            total += n;
            return n;
        });
        const budget = sizes.length && 64 + sizes[sizes.length - 1] > ROW_MAX_BYTES ? ROW_HARD_BYTES : ROW_MAX_BYTES;
        let start = 0;
        while (total > budget && start < msgs.length - 1) total -= sizes[start++];
        return start ? msgs.slice(start) : msgs;
    }

    async function seal(plaintext) {
        const size = utf8Bytes(plaintext);
        if (size > SEAL_MAX_BYTES) return null;
        if (size <= PART_BYTES) return sealPart(plaintext);
        const sealed = [];
        for (const part of splitParts(plaintext)) {
            const blob = await sealPart(part);
            if (!blob) return null;
            sealed.push(blob);
        }
        return PARTS_PREFIX + JSON.stringify(sealed);
    }

    async function sealPart(plaintext) {
        const kem = selfKem();
        if (Identity._sk) {
            if (kem) {
                try { return NC().pq2Encrypt(plaintext, Identity._sk, Identity.pubkey, kem); } catch (_) { }
            }
            const T = NT();
            return T.nip44.encrypt(plaintext, T.nip44.getConversationKey(Identity._sk, Identity.pubkey));
        }
        const inner = await Identity.encryptTo(Identity.pubkey, plaintext);
        if (kem) {
            try { return NC().pq2Seal(inner, Identity.pubkey, Identity.pubkey, kem); } catch (_) { }
        }
        return inner;
    }

    function selfCandidates() {
        const PQ = window.NymbotPQ;
        if (PQ && typeof PQ.selfCandidates === 'function') return PQ.selfCandidates();
        return Identity._kem ? [{ kemSk: Identity._kem.secretKey, kemPk: Identity._kem.publicKey }] : [];
    }

    const OPENED_MAX = 2000;
    const opened = new Map();

    function remember(key, plain) {
        if (opened.size >= OPENED_MAX) opened.delete(opened.keys().next().value);
        opened.set(key, plain);
    }

    async function open(blob) {
        if (!Identity.isRemote) return openWith(blob);
        const key = await sha256Hex(blob);
        if (opened.has(key)) return opened.get(key);
        const plain = await openWith(blob);
        remember(key, plain);
        return plain;
    }

    async function openWith(blob) {
        if (!isParts(blob)) return openPart(blob);
        let plain = '';
        for (const part of partsOf(blob)) plain += await openPart(part);
        return plain;
    }

    async function openPart(blob) {
        const NCx = NC();
        if (Identity._sk) {
            if (NCx.isPq2Payload(blob)) {
                let lastErr = null;
                for (const c of selfCandidates()) {
                    try {
                        return NCx.pq2Decrypt(blob, Identity.pubkey, { sk: Identity._sk, kemSk: c.kemSk, kemPk: c.kemPk });
                    } catch (e) { lastErr = e; }
                }
                throw lastErr || new Error('no kem key');
            }
            const T = NT();
            return T.nip44.decrypt(blob, T.nip44.getConversationKey(Identity._sk, Identity.pubkey));
        }
        if (NCx.isPq2Payload(blob)) {
            let inner = null;
            let lastErr = null;
            for (const c of selfCandidates()) {
                try { inner = NCx.pq2Open(blob, Identity.pubkey, Identity.pubkey, c); break; }
                catch (e) { lastErr = e; }
            }
            if (inner == null) throw lastErr || new Error('needs the root');
            return Identity.decryptFrom(Identity.pubkey, inner);
        }
        return Identity.decryptFrom(Identity.pubkey, blob);
    }

    /// Never hybrid: the root row says which root to derive, so sealing it that way locks it behind itself.
    async function sealClassical(plaintext) {
        if (Identity._sk) {
            const T = NT();
            return T.nip44.encrypt(plaintext, T.nip44.getConversationKey(Identity._sk, Identity.pubkey));
        }
        return Identity.encryptTo(Identity.pubkey, plaintext);
    }

    /// `account` stands in for the identity during sign-in, before this device is given a root.
    async function auth(action, account, payload) {
        const event = {
            kind: 27235,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['domain', 'nymbot-sync'],
                ['method', 'POST'],
                ['u', url()],
                ['action', action]
            ].concat(payload ? [['payload', payload]] : []),
            content: 'nymbot-sync-auth'
        };
        return account ? account.sign(event) : Identity.signEvent(event);
    }

    async function signedBody(action, fields, account) {
        const Api = window.NymbotApi;
        const text = Api.signedText(fields);
        return Api.withAuth(text, await auth(action, account, await sha256Hex(text)));
    }

    async function call(action, extra, account) {
        const pubkey = account ? account.pubkey : Identity.pubkey;
        const body = await signedBody(action, Object.assign({ action, pubkey }, extra || {}), account);
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 20000);
        try {
            const resp = await Edge.fetch(url(), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body,
                signal: controller.signal
            });
            return await resp.json().catch(() => null);
        } catch (_) {
            return null;
        } finally {
            clearTimeout(timer);
        }
    }

    /// Public and unauthenticated since kind 0 is public; returns unverified events for the caller to check.
    async function profileEventsFromD1(pubkeys) {
        const wanted = (pubkeys || [])
            .filter(pk => /^[0-9a-f]{64}$/i.test(pk || ''))
            .map(pk => pk.toLowerCase())
            .slice(0, 100);
        if (!wanted.length) return {};
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 8000);
        try {
            const resp = await Edge.fetch(url(), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'profile-get', pubkeys: wanted }),
                signal: controller.signal
            });
            if (!resp.ok) return null;
            const out = {};
            for (const line of (await resp.text()).split('\n')) {
                if (!line.trim()) continue;
                let item;
                try { item = JSON.parse(line); } catch (_) { continue; }
                if (!Array.isArray(item) || item.length < 2) continue;
                const rec = item[1];
                if (rec && rec.event) out[item[0]] = rec.event;
            }
            return out;
        } catch (_) {
            return null;
        } finally {
            clearTimeout(timer);
        }
    }

    /// Null means the read failed, not "no root"; `present` counts rows this device cannot open.
    async function rootRecordFor(account) {
        const pubkey = account ? account.pubkey : Identity.pubkey;
        if (!pubkey) return null;
        const hashed = await nymchatCategoryFor(pubkey, PQ_ROOT_D_TAG);
        const data = await call('settings-get', { only: [hashed, PQ_ROOT_D_TAG] }, account);
        if (!data || !data.categories || typeof data.categories !== 'object') return null;
        let blob = null;
        for (const name of [hashed, PQ_ROOT_D_TAG]) {
            const entry = data.categories[name];
            if (entry && typeof entry.blob === 'string' && entry.blob) { blob = entry.blob; break; }
        }
        if (!blob) return { present: false, record: null };
        let record = null;
        try {
            const payload = JSON.parse(account ? await account.open(blob) : await open(blob));
            if (payload && payload.v === 2 && typeof payload.fp === 'string' && payload.fp) {
                record = payload;
            }
        } catch (_) { }
        return { present: true, record };
    }

    /// Without this row every other device reads "no root" and mints a rival one.
    async function publishRootRecord() {
        const fingerprint = Identity.rootFingerprint();
        if (!Identity.pubkey || !fingerprint) return false;
        const plain = JSON.stringify({
            v: 2,
            fp: fingerprint,
            wraps: [],
            ts: Math.floor(Date.now() / 1000),
            __cat: PQ_ROOT_D_TAG
        });
        let blob;
        try { blob = await sealClassical(plain); } catch (_) { return false; }
        if (!blob) return false;
        const category = await nymchatCategoryFor(Identity.pubkey, PQ_ROOT_D_TAG);
        const hash = await sha256Hex(Identity.pubkey + '|c|' + plain);
        const resp = await call('settings-set', { category, blob, contentHash: hash });
        return !!(resp && !resp.error);
    }

    function stamp(record) {
        if (!record || typeof record !== 'object') return 0;
        return Number(record.updatedAt || record.at || record.createdAt || record.ts) || 0;
    }

    function fitArtifacts(convId, list) {
        let arts = list.map(a => Object.assign({}, a, { versions: (a.versions || []).slice(-ART_VERSIONS) }));
        const size = () => JSON.stringify({ id: convId, artifacts: arts }).length;
        if (size() > ART_MAX_CHARS) arts = arts.map(a => Object.assign({}, a, { versions: (a.versions || []).slice(-1) }));
        arts.sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
        while (arts.length && size() > ART_MAX_CHARS) arts.shift();
        return arts;
    }

    function mergeVersions(a, b) {
        const seen = new Map();
        for (const v of [].concat(a || [], b || [])) {
            if (!v || typeof v.body !== 'string') continue;
            const key = (Number(v.at) || 0) + '|' + v.body;
            if (!seen.has(key)) seen.set(key, v);
        }
        return [...seen.values()].sort((x, y) => (Number(x.at) || 0) - (Number(y.at) || 0)).slice(-ART_KEEP_VERSIONS);
    }

    function mergeArtifacts(mine, theirs, graves) {
        const byId = new Map();
        for (const a of mine) if (a && a.id && !graves[a.id]) byId.set(a.id, a);
        for (const t of theirs) {
            if (!t || typeof t.id !== 'string' || !t.id || graves[t.id]) continue;
            const m = byId.get(t.id);
            if (!m) { byId.set(t.id, Object.assign({}, t, { versions: mergeVersions([], t.versions) })); continue; }
            const newer = (Number(t.updatedAt) || 0) > (Number(m.updatedAt) || 0) ? t : m;
            byId.set(t.id, Object.assign({}, newer, { versions: mergeVersions(m.versions, t.versions) }));
        }
        return [...byId.values()].sort((a, b) => (Number(a.createdAt) || 0) - (Number(b.createdAt) || 0));
    }

    function sentAt(message) {
        if (!message || typeof message !== 'object') return 0;
        return Number(message.ts) || Number(message.at) || 0;
    }

    function supportOutlives(graves, lists) {
        const at = Number(graves[SUPPORT_ID]) || 0;
        if (!at) return 0;
        for (const list of lists) {
            if (Array.isArray(list) && list.some(m => sentAt(m) > at)) return at;
        }
        return 0;
    }

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

    function carriesSecret(row, marks) {
        return !!row && marks.some(f => typeof row[f] === 'string');
    }

    function secretOf(row, fields, at, from) {
        const out = { from };
        for (const f of fields) out[f] = row && typeof row[f] === 'string' ? row[f] : '';
        out[at] = row ? Number(row[at]) || 0 : 0;
        return out;
    }

    function pickSecret(mine, theirs, fields, at, marks) {
        const held = secretOf(mine, fields, at, 'mine');
        if (!carriesSecret(theirs, marks || fields)) return held;
        const came = secretOf(theirs, fields, at, 'theirs');
        if (came[at] > held[at]) return came;
        if (fields.some(f => held[f])) return held;
        if (came[at] === 0 || came[at] === held[at]) return fields.some(f => came[f]) ? came : held;
        return held;
    }

    const Sync = {
        pickSecret,

        /// Set once a pull returns rows this device cannot open, i.e. an unlinked key.
        blocked: false,
        lastAt: 0,
        _timer: null,
        _running: null,
        _following: null,
        _again: false,
        _hashes: new Map(),
        _names: new Map(),
        _statePk: null,
        _pending: null,
        onChange: null,

        rootRecord(account) { return rootRecordFor(account); },
        publishRootRecord() { return publishRootRecord(); },
        profileEvents(pubkeys) { return profileEventsFromD1(pubkeys); },

        enabled() {
            return !!(Identity.pubkey && Store.settings().sync !== false);
        },

        _load() {
            const pk = Identity.pubkey || null;
            if (this._statePk === pk) return;
            this._statePk = pk;
            this._pending = null;
            const held = pk ? Store.read('sync_hashes', null) : null;
            const mine = !!(held && typeof held === 'object' && held.pk === pk);
            const map = (v) => new Map(mine && v && typeof v === 'object' ? Object.entries(v).filter(e => typeof e[1] === 'string') : []);
            this._hashes = map(held && held.hashes);
            this._names = map(held && held.names);
        },

        _saveHashes() {
            if (!this._statePk || this._statePk !== Identity.pubkey) return;
            Store.write('sync_hashes', {
                pk: this._statePk,
                hashes: Object.fromEntries(this._hashes),
                names: Object.fromEntries(this._names)
            });
        },

        cursor() {
            const held = Store.read('sync_cursor', null);
            if (!held || typeof held !== 'object' || !Identity.pubkey || held.pk !== Identity.pubkey) return null;
            if (!Number.isFinite(held.cursor) || !Number.isFinite(held.now)) return null;
            return held;
        },

        since() {
            if (this.blocked) return null;
            const held = this.cursor();
            if (!held) return null;
            const age = Date.now() - (Number(held.fullAt) || 0);
            if (!(age >= 0 && age < FULL_EVERY_MS)) return null;
            return Math.max(0, Math.min(held.cursor, held.now - OVERLAP_MS));
        },

        _commit() {
            const p = this._pending;
            this._pending = null;
            if (!p || p.pk !== Identity.pubkey) return;
            const held = this.cursor();
            Store.write('sync_cursor', {
                pk: p.pk,
                cursor: p.cursor,
                now: p.now,
                fullAt: p.full ? p.at : (held ? Number(held.fullAt) || 0 : 0)
            });
        },

        forget() {
            this.blocked = false;
            this._hashes = new Map();
            this._names = new Map();
            this._pending = null;
            this._statePk = Identity.pubkey || null;
            Store.drop('sync_cursor');
            Store.drop('sync_hashes');
        },

        /// So a device that still holds a deleted record does not push it back.
        graves() {
            const held = Store.read('sync_graves', {}) || {};
            const cutoff = Date.now() - TOMBSTONE_MS;
            let changed = false;
            for (const id of Object.keys(held)) {
                if (!(held[id] > cutoff)) { delete held[id]; changed = true; }
            }
            if (held[SUPPORT_ID] && supportOutlives(held, [Store.messages(SUPPORT_ID)])) {
                delete held[SUPPORT_ID];
                changed = true;
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

        snapshot() {
            const graves = this.graves();
            const out = {};
            out['settings'] = Store.settings();

            const library = {};
            for (const [name, get] of LIBRARY) {
                const value = get();
                if (value != null) library[name] = value;
            }
            library.repos = Store.repos().map(r => {
                const copy = Object.assign({}, r);
                copy.token = r.token || '';
                copy.tokenAt = Number(r.tokenAt) || 0;
                copy.tokenElsewhere = !!r.token;
                return copy;
            });
            if (window.NymbotConnectors) library.connectors = window.NymbotConnectors.syncCopy();
            out['library'] = library;

            const chats = Store.conversations()
                .filter(c => c && c.id && !c.ephemeral && !Store.isGhost(c.id) && !graves[c.id])
                .slice(0, MAX_CHATS);
            out['chats'] = chats.map(c => Object.assign({}, c));
            for (const conv of chats) {
                const msgs = Store.messages(conv.id);
                if (!msgs.length) continue;
                out['chat-' + conv.id] = { id: conv.id, messages: fitMessages(msgs.slice(-MAX_MESSAGES)) };
            }
            const Artifacts = window.NymbotArtifacts;
            if (Artifacts) {
                for (const conv of chats) {
                    const arts = Artifacts.all(conv.id).filter(a => a && a.id && !graves[a.id]);
                    if (arts.length) out['arts-' + conv.id] = { id: conv.id, artifacts: fitArtifacts(conv.id, arts) };
                }
            }
            out['graves'] = graves;
            const anonKeys = window.NymbotAnon ? window.NymbotAnon.syncCopy() : null;
            if (anonKeys) out['anonKeys'] = anonKeys;
            const supportTokens = window.NymbotSupport ? window.NymbotSupport.syncCopy() : null;
            if (supportTokens) out['supportTokens'] = supportTokens;
            return out;
        },

        /// Muted: server data is not a local change, or the sync chases its own tail.
        apply(remote) {
            return Store.quiet(() => this._apply(remote));
        },

        _apply(remote) {
            if (!remote || typeof remote !== 'object') return [];
            const touched = [];
            const mineGraves = this.graves();
            const theirGraves = remote.graves && typeof remote.graves === 'object' ? remote.graves : {};
            const graves = Object.assign({}, mineGraves, theirGraves);
            if (graves[SUPPORT_ID]) {
                graves[SUPPORT_ID] = Math.max(Number(mineGraves[SUPPORT_ID]) || 0, Number(theirGraves[SUPPORT_ID]) || 0);
            }
            const supportEntry = remote['chat-' + SUPPORT_ID];
            const supportCut = supportOutlives(graves, [
                Store.messages(SUPPORT_ID),
                supportEntry && supportEntry.messages
            ]);
            if (supportCut) {
                delete graves[SUPPORT_ID];
                const held = Store.messages(SUPPORT_ID);
                const kept = held.filter(m => sentAt(m) > supportCut);
                if (kept.length !== held.length) {
                    Store.saveMessages(SUPPORT_ID, kept);
                    touched.push('chat-' + SUPPORT_ID);
                }
            }
            Store.write('sync_graves', graves);

            if (remote.settings && typeof remote.settings === 'object') {
                // Local values win on keys changed here since the last push.
                const local = Store.read('settings', {}) || {};
                const theirs = Object.assign({}, remote.settings);
                delete theirs.git;
                delete local.git;
                const merged = Object.assign({}, theirs, local);
                if ((Number(remote.settings.nicknameAt) || 0) > (Number(local.nicknameAt) || 0)) {
                    merged.nickname = typeof remote.settings.nickname === 'string' ? remote.settings.nickname : '';
                    merged.nicknameAt = Number(remote.settings.nicknameAt);
                }
                Store.write('settings', merged);
                touched.push('settings');
            }

            if (remote.library && typeof remote.library === 'object') {
                for (const [name, get, set] of LIBRARY) {
                    const theirs = remote.library[name];
                    if (!Array.isArray(theirs)) continue;
                    const mine = get() || [];
                    // Lists of ids merge by id; lists of plain values (favorites) merge as a set.
                    const merged = theirs.length && typeof theirs[0] === 'object'
                        ? mergeById(mine, theirs, graves)
                        : Array.from(new Set([].concat(mine, theirs)));
                    set(merged);
                    touched.push(name);
                }
                if (Array.isArray(remote.library.repos)) {
                    const mine = Store.repos();
                    const byId = new Map(mine.map(r => [r.id, r]));
                    const theirsById = new Map(remote.library.repos.filter(r => r && r.id).map(r => [r.id, r]));
                    const merged = mergeById(mine, remote.library.repos, graves).map(r => {
                        const copy = Object.assign({}, r);
                        const kept = pickSecret(byId.get(r.id), theirsById.get(r.id), ['token'], 'tokenAt');
                        delete copy.token;
                        delete copy.tokenAt;
                        if (kept.token) {
                            copy.token = kept.token;
                            delete copy.tokenElsewhere;
                        }
                        if (kept.tokenAt) copy.tokenAt = kept.tokenAt;
                        return copy;
                    });
                    Store.saveRepos(merged);
                    touched.push('repos');
                }
                if (Array.isArray(remote.library.connectors) && window.NymbotConnectors) {
                    const Connectors = window.NymbotConnectors;
                    Connectors.syncMerge(mergeById(Connectors.list(), remote.library.connectors, graves), remote.library.connectors);
                    touched.push('connectors');
                }
            }

            if (Array.isArray(remote.chats)) {
                const mine = Store.conversations();
                const ghosts = new Set(mine.filter(c => Store.isGhost(c.id)).map(c => c.id));
                const incoming = remote.chats.filter(c => c && c.id && !ghosts.has(c.id));
                const anonPks = new Map();
                for (const c of [].concat(mine, incoming)) {
                    if (c && c.id && typeof c.anonPk === 'string' && !anonPks.has(c.id)) anonPks.set(c.id, c.anonPk);
                }
                const merged = mergeById(mine, incoming, graves)
                    .map(c => c.anonPk || !anonPks.has(c.id) ? c : Object.assign({}, c, { anonPk: anonPks.get(c.id) }))
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
                const theirs = supportCut && entry.id === SUPPORT_ID
                    ? entry.messages.filter(m => sentAt(m) > supportCut)
                    : entry.messages;
                const merged = mergeById(mine, theirs, graves)
                    .sort((a, b) => (a.ts || 0) - (b.ts || 0));
                if (merged.length !== mine.length) {
                    Store.saveMessages(entry.id, merged);
                    touched.push(key);
                }
            }

            if (remote.anonKeys && typeof remote.anonKeys === 'object' && window.NymbotAnon) {
                if (window.NymbotAnon.syncMerge(remote.anonKeys)) touched.push('anonKeys');
            }

            if (Array.isArray(remote.supportTokens) && window.NymbotSupport) {
                if (window.NymbotSupport.syncMerge(remote.supportTokens)) touched.push('supportTokens');
            }

            const Artifacts = window.NymbotArtifacts;
            for (const key of Object.keys(remote)) {
                if (key.indexOf('arts-') !== 0 || !Artifacts) continue;
                const entry = remote[key];
                if (!entry || typeof entry.id !== 'string' || !entry.id || !Array.isArray(entry.artifacts)) continue;
                if (graves[entry.id] || Store.isGhost(entry.id)) continue;
                const mine = Artifacts.all(entry.id);
                const merged = mergeArtifacts(mine, entry.artifacts, graves);
                if (JSON.stringify(merged) !== JSON.stringify(mine)) {
                    Artifacts.save(entry.id, merged);
                    touched.push(key);
                }
            }
            return touched;
        },

        async pull(opts) {
            this._load();
            const since = opts && opts.full ? null : this.since();
            const data = await call('settings-get', since == null ? {} : { since });
            if (!data || !data.categories || typeof data.categories !== 'object') return null;
            const full = data.full !== false;
            const out = {};
            let unreadable = 0;
            for (const [category, entry] of Object.entries(data.categories)) {
                if (!entry || typeof entry.blob !== 'string') continue;
                let payload;
                try {
                    payload = JSON.parse(await open(entry.blob));
                } catch (_) { unreadable++; continue; }
                if (!payload || typeof payload !== 'object') continue;
                const name = typeof payload.__cat === 'string' ? payload.__cat : null;
                if (!name) continue;
                // Key material has its own reader and writer; keep it out of the snapshot and remote wipes.
                if (name === PQ_ROOT_D_TAG) continue;
                delete payload.__cat;
                out[name] = payload.v !== undefined ? payload.v : payload;
                if (category === await categoryFor(name)) {
                    const plain = JSON.stringify({ __cat: name, v: out[name] });
                    const mode = blobMode(entry.blob);
                    this._hashes.set(category, await sha256Hex(Identity.pubkey + '|' + mode + '|' + plain));
                    this._names.set(category, name);
                }
            }
            // Rows exist but none opened: this key cannot read the account's settings, so it must not write.
            if (full) this.blocked = unreadable > 0 && Object.keys(out).length === 0;
            this._pending = Number.isFinite(data.cursor) && Number.isFinite(data.now)
                ? { pk: Identity.pubkey, cursor: data.cursor, now: data.now, full, at: Date.now() }
                : null;
            this._saveHashes();
            return out;
        },

        async push(dTag, value, opts) {
            if (this.blocked) return false;
            this._load();
            const force = !!(opts && opts.force);
            const category = await categoryFor(dTag);
            let current = value;
            let base = this._hashes.has(category) ? this._hashes.get(category) : '';
            for (let attempt = 0; attempt <= CAS_RETRIES; attempt++) {
                const plain = JSON.stringify({ __cat: dTag, v: current });
                const hash = await sha256Hex(Identity.pubkey + '|' + (selfKem() ? 'pq' : 'c') + '|' + plain);
                if (this._hashes.get(category) === hash) return true;
                let blob;
                try { blob = await seal(plain); } catch (_) { return false; }
                if (!blob) return false;
                const fields = { category, blob, contentHash: hash };
                if (!force) fields.baseHash = base || '';
                const resp = await call('settings-set', fields);
                if (resp && resp.conflict === true && !force) {
                    const merged = await this._mergeRemote(category, dTag, current);
                    if (!merged) return false;
                    current = merged.value;
                    base = typeof resp.contentHash === 'string' ? resp.contentHash : '';
                    continue;
                }
                if (!resp || resp.error) return false;
                this._hashes.set(category, hash);
                this._names.set(category, dTag);
                if (Identity.isRemote) remember(await sha256Hex(blob), plain);
                return true;
            }
            return false;
        },

        async _mergeRemote(category, dTag, fallback) {
            const data = await call('settings-get', { only: [category] });
            if (!data || !data.categories || typeof data.categories !== 'object') return null;
            const entry = data.categories[category];
            if (entry && typeof entry.blob === 'string') {
                let payload;
                try { payload = JSON.parse(await open(entry.blob)); } catch (_) { return null; }
                if (!payload || typeof payload !== 'object' || payload.__cat !== dTag) return null;
                const theirs = payload.v !== undefined ? payload.v : payload;
                const touched = this.apply({ [dTag]: theirs });
                if (touched.length && typeof this.onChange === 'function') {
                    try { this.onChange(touched); } catch (_) { }
                }
            }
            const local = this.snapshot();
            return { value: dTag in local ? local[dTag] : fallback };
        },

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
                let failed = false;
                try {
                    const remote = await this.pull();
                    if (remote === null) return { offline: true };
                    touched = this.apply(remote);
                    if (this.blocked) return { blocked: true };
                    this._commit();
                    const local = this.snapshot();
                    // Server rows for conversations deleted here are emptied rather than left behind.
                    for (const key of new Set(Object.keys(remote).concat([...this._names.values()]))) {
                        if (key.indexOf('chat-') === 0 && !local[key]) local[key] = { id: '', messages: [] };
                    }
                    try {
                        for (const [dTag, value] of Object.entries(local)) {
                            await this.push(dTag, value);
                        }
                    } finally {
                        this._saveHashes();
                    }
                    this.lastAt = Date.now();
                } catch (_) {
                    failed = true;
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
                if (failed) return { failed: true, touched };
                return { ok: true, touched, quiet: !!options.quiet };
            })();
            return this._running;
        },

        follow() {
            if (this._following) return;
            this._following = Store.watch(() => this.touch());
        },

        touch(delay) {
            if (!this.enabled()) return;
            if (this._timer) clearTimeout(this._timer);
            this._timer = setTimeout(() => {
                this._timer = null;
                this.run({ quiet: true }).catch(() => { });
            }, delay || 4000);
        },

        /// Signed while the key is still here and sent keepalive so a reload cannot cancel it.
        async purge() {
            if (!Identity.pubkey) return false;
            let body;
            try {
                body = await signedBody('account-purge', {
                    action: 'account-purge',
                    app: 'nymbot',
                    pubkey: Identity.pubkey
                });
            } catch (_) { return false; }
            this.forget();
            try {
                await Edge.fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body,
                    keepalive: true
                });
                return true;
            } catch (_) { return false; }
        },

        async wipeRemote() {
            if (!Identity.pubkey) return false;
            const remote = await this.pull({ full: true });
            if (!remote) return false;
            this.forget();
            for (const dTag of Object.keys(remote)) await this.push(dTag, null, { force: true });
            this._saveHashes();
            return true;
        }
    };

    window.NymbotSync = Sync;
})();
