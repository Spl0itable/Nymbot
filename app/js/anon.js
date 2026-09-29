// Anonymous mode: a throwaway key the whole conversation runs under, and blind
// vouchers that move credits onto it without handing the worker the link.
//
// Ported from the Nymchat client so both apps agree byte for byte — the domain
// constants, the hash-to-curve, the DLEQ check and the denominations are all
// part of the wire format (docs/ANON-NYMBOT-SPEC.md in nym-staging).
(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;
    const Api = window.NymbotApi;
    const NT = () => window.NostrTools;
    const NC = () => window.NymCrypto;
    const P = () => NT()._secp256k1.ProjectivePoint;

    const N = BigInt('0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141');
    const DENOMS = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];
    const TIERS = ['standard', 'pro'];
    const MAX_OUTPUTS = 32;
    const HTC_DOMAIN = 'Nymbot_Voucher_HashToCurve_v1';
    const DLEQ_DOMAIN = 'Nymbot_Voucher_DLEQ_v1';
    const PREV_MAX = 4;
    const SYNC_KEYS_MAX = 32;
    const SYNC_TOKENS_MAX = 512;
    const SPENT_MAX = 1024;
    const HEX64 = /^[0-9a-f]{64}$/;
    const ANNOUNCE_TTL_SEC = 7 * 24 * 3600;

    const enc = new TextEncoder();
    const { hex, unhex } = window.NymbotHex;

    function cat() {
        let len = 0;
        for (const a of arguments) len += a.length;
        const out = new Uint8Array(len);
        let at = 0;
        for (const a of arguments) { out.set(a, at); at += a.length; }
        return out;
    }

    function le32(n) {
        return new Uint8Array([n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255]);
    }

    const scalarFrom = (bytes) => BigInt('0x' + hex(bytes)) % N;
    const scalarHex = (v) => v.toString(16).padStart(64, '0');

    function randomScalar() {
        let v = 0n;
        while (v === 0n) v = scalarFrom(crypto.getRandomValues(new Uint8Array(32)));
        return v;
    }

    function hashToCurve(xBytes) {
        const sha = NT()._sha256;
        const base = sha(cat(enc.encode(HTC_DOMAIN), xBytes));
        for (let i = 0; i < 512; i++) {
            try { return P().fromHex('02' + hex(sha(cat(base, le32(i))))); } catch (_) { }
        }
        throw new Error('hash-to-curve failed');
    }

    function keysetFrom(keys) {
        if (!keys || typeof keys !== 'object') return null;
        const clean = {};
        const parts = [];
        for (const tier of TIERS) {
            const row = keys[tier];
            if (!row || typeof row !== 'object') return null;
            clean[tier] = {};
            for (const denom of DENOMS) {
                const key = row[String(denom)];
                if (typeof key !== 'string' || !/^0[23][0-9a-f]{64}$/.test(key)) return null;
                try { P().fromHex(key); } catch (_) { return null; }
                clean[tier][String(denom)] = key;
                parts.push(tier + ':' + denom + ':' + key);
            }
        }
        const id = hex(NT()._sha256(enc.encode(parts.join('|')))).slice(0, 16);
        return { id, keys: clean };
    }

    function splitAmount(amount) {
        const out = [];
        let left = Math.floor(amount);
        for (let i = DENOMS.length - 1; i >= 0 && left > 0; i--) {
            while (left >= DENOMS[i] && out.length < MAX_OUTPUTS) {
                out.push(DENOMS[i]);
                left -= DENOMS[i];
            }
        }
        return left === 0 ? out : null;
    }

    function denomsFor(amount) {
        const out = [];
        let left = Math.floor(amount);
        for (let i = DENOMS.length - 1; i >= 0 && left > 0; i--) {
            while (left >= DENOMS[i]) {
                out.push(DENOMS[i]);
                left -= DENOMS[i];
            }
        }
        return out;
    }

    const newestKey = (a, b) => (b.createdAt - a.createdAt) || (a.pk < b.pk ? 1 : a.pk > b.pk ? -1 : 0);
    const beats = (a, b) => a.createdAt > b.createdAt || (a.createdAt === b.createdAt && a.pk > b.pk);

    function tokenOf(t) {
        if (!t || typeof t !== 'object') return null;
        const d = Number(t.d);
        if (!DENOMS.includes(d)) return null;
        if (typeof t.x !== 'string' || !HEX64.test(t.x)) return null;
        if (typeof t.C !== 'string' || !/^0[23][0-9a-f]{64}$/.test(t.C)) return null;
        const tier = t.tier || 'standard';
        if (!TIERS.includes(tier)) return null;
        return { d, x: t.x, C: t.C, tier };
    }

    function creditsOf(data, tier) {
        if (!data || data.error) return null;
        const v = tier === 'pro'
            ? (data.proBalanceCredits != null ? data.proBalanceCredits : data.proBalance)
            : (data.balanceCredits != null ? data.balanceCredits : data.balance);
        return Number(v) || 0;
    }

    const Anon = {
        state: null,
        onKeysetChange: null,   // (oldId, newId) => Promise<boolean>

        // --- identity -------------------------------------------------------

        load() {
            this.state = Store.read('anon', null) || { current: null, prev: [], tokens: [], pending: null, spent: [] };
            return this.state;
        },

        save() { Store.write('anon', this.state); },

        enabled() { return !!Store.settings().anon; },

        setEnabled(on) {
            Store.setSettings({ anon: !!on });
            if (on) {
                this.ensure();
                this.flush().then(() => this.autoTopUp()).catch(() => { });
            }
        },

        ready() { return !!(this.enabled() && this.state && this.state.current); },

        holds() { return !!(this.state && this.state.current); },

        _newIdentity() {
            const sk = NT().generateSecretKey();
            return {
                sk: hex(sk),
                pk: NT().getPublicKey(sk),
                root: hex(NC().pqGenerateRoot()),
                createdAt: Date.now()
            };
        },

        ensure() {
            if (!this.state) this.load();
            if (!this.state.current) {
                this.state.current = this._newIdentity();
                this.save();
            }
            return this.state.current;
        },

        pubkey() { return this.state && this.state.current ? this.state.current.pk : null; },

        held() {
            const st = this.state || this.load();
            const out = [];
            for (const id of [st.current].concat(st.prev || [])) {
                if (id && id.pk && !out.some(o => o.pk === id.pk)) out.push(id);
            }
            return out;
        },

        identity(pk) {
            if (!pk) return null;
            return this.held().find(id => id.pk === pk) || null;
        },

        forConv(conv) {
            try {
                return (conv && this.identity(conv.anonPk)) || this.ensure();
            } catch (_) {
                return null;
            }
        },

        bind(conv) {
            const id = this.forConv(conv);
            if (!id) return null;
            if (conv && conv.anonPk !== id.pk) {
                conv.anonPk = id.pk;
                if (conv.id) Store.updateConversation(conv.id, { anonPk: id.pk, silent: true });
            }
            return id;
        },

        _referenced(chatsOnly) {
            const out = new Set();
            for (const c of Store.conversations()) {
                if (c && typeof c.anonPk === 'string') out.add(c.anonPk);
            }
            if (chatsOnly) return out;
            const st = this.state || this.load();
            if (st.pending && st.pending.from) out.add(st.pending.from);
            for (const t of st.tokens || []) if (t && t.redeemTo) out.add(t.redeemTo);
            return out;
        },

        _prune() {
            const st = this.state;
            const refs = this._referenced();
            const cur = st.current ? st.current.pk : null;
            const seen = new Set(cur ? [cur] : []);
            let spare = 0;
            st.prev = (st.prev || []).filter(id => {
                if (!id || !id.pk || seen.has(id.pk)) return false;
                seen.add(id.pk);
                return refs.has(id.pk) || spare++ < PREV_MAX;
            });
        },

        /// The signing key material, for wrapping and for opening replies.
        sender(identity) {
            const id = identity || this.ensure();
            return { sk: unhex(id.sk), pubkey: id.pk };
        },

        kem(identity) {
            const id = identity || this.ensure();
            if (!id || !id.root) return null;
            // Separate entropy from the signing key on purpose: the throwaway
            // pubkey is published on every wrap, so a KEM key derived from it
            // would fall with secp256k1.
            try { return NC().pqKeypairFromRoot(unhex(id.root), 0); } catch (_) { return null; }
        },

        recipient(identity) {
            const id = identity || this.ensure();
            const kp = this.kem(id);
            return { sk: unhex(id.sk), kemSk: kp ? kp.secretKey : undefined, kemPk: kp ? kp.publicKey : undefined };
        },

        openers(identity, event) {
            const tags = event && Array.isArray(event.tags) ? event.tags : [];
            const tagged = (tags.find(t => Array.isArray(t) && t[0] === 'p') || [])[1];
            const out = [];
            for (const id of [this.identity(tagged), identity || this.ensure()].concat(this.held())) {
                if (id && !out.includes(id)) out.push(id);
            }
            return out.map(id => this.recipient(id));
        },

        /// The auth signer the worker sees: this key, never the account's.
        signer(identity) {
            const id = identity || this.ensure();
            const sk = unhex(id.sk);
            return { pubkey: id.pk, sign: (evt) => NT().finalizeEvent(Object.assign({ pubkey: id.pk }, evt), sk) };
        },

        /// A signed announcement carrying the throwaway KEM key, handed to the
        /// worker with each request so the reply comes back hybrid without a
        /// lookup that would have nothing to find.
        announcement(identity) {
            const id = identity || this.ensure();
            const kp = this.kem(id);
            if (!kp) return null;
            const nowSec = Math.floor(Date.now() / 1000);
            if (this._annCache && this._annCache.pk === id.pk && this._annCache.exp > nowSec + 3600) {
                return this._annCache.event;
            }
            const b64 = NC()._b64uEncode(kp.publicKey);
            const exp = nowSec + ANNOUNCE_TTL_SEC;
            const event = NT().finalizeEvent({
                kind: 30078,
                created_at: nowSec,
                tags: [['d', C.pqDTag], ['t', C.pqDTag], ['expiration', String(exp)]],
                content: JSON.stringify({
                    v: 2, src: 'root', alg: C.pqAlg, nym: 1, epoch: 0,
                    pk: b64, pk2: b64, exp, devices: []
                })
            }, unhex(id.sk));
            this._annCache = { pk: id.pk, exp, event };
            return event;
        },

        async rotate(sweep) {
            this.ensure();
            const old = this.state.current;
            if (old) {
                this.state.prev = [old].concat(this.state.prev || []);
            }
            this.state.current = this._newIdentity();
            this._annCache = null;
            this._prune();
            this.save();
            if (!sweep || !old) return 0;
            return this._sweep(old);
        },

        async _sweep(identity) {
            const { data } = await Api.balance({ signer: this.signer(identity) });
            if (!data || data.error) return 0;
            this.rememberData(identity.pk, data);
            let issued = 0;
            for (const tier of TIERS) {
                const whole = Math.floor(creditsOf(data, tier) || 0);
                if (whole <= 0) continue;
                try {
                    const tokens = await this._issue(whole, tier, identity);
                    issued += tokens.reduce((n, t) => n + t.d, 0);
                } catch (_) { }
            }
            return issued;
        },

        _checked(k) {
            if (!k || typeof k !== 'object') return null;
            if (typeof k.pk !== 'string' || !HEX64.test(k.pk)) return null;
            if (typeof k.sk !== 'string' || !HEX64.test(k.sk)) return null;
            if (typeof k.root !== 'string' || !/^([0-9a-f]{2})*$/.test(k.root)) return null;
            const createdAt = Number(k.createdAt);
            if (!Number.isFinite(createdAt) || createdAt < 0) return null;
            try {
                if (NT().getPublicKey(unhex(k.sk)) !== k.pk) return null;
            } catch (_) { return null; }
            return { sk: k.sk, pk: k.pk, root: k.root, createdAt };
        },

        syncCopy() {
            const st = this.state || this.load();
            if (!st.current) return null;
            const refs = this._referenced(true);
            const all = this.held().slice().sort(newestKey);
            const keys = all.filter((id, i) => i < SYNC_KEYS_MAX || id.pk === st.current.pk || refs.has(id.pk))
                .map(id => ({ pk: id.pk, sk: id.sk, root: id.root || '', createdAt: Number(id.createdAt) || 0 }));
            const tokens = (st.tokens || []).map(tokenOf).filter(Boolean)
                .sort((a, b) => (a.x < b.x ? -1 : a.x > b.x ? 1 : 0)).slice(0, SYNC_TOKENS_MAX);
            const spent = [...new Set((st.spent || []).filter(x => typeof x === 'string' && HEX64.test(x)))]
                .sort().slice(0, SPENT_MAX);
            return { v: 1, current: st.current.pk, keys, tokens, spent };
        },

        syncMerge(remote) {
            if (!remote || typeof remote !== 'object' || remote.v !== 1 || !Array.isArray(remote.keys)) return false;
            const st = this.state || this.load();
            const before = JSON.stringify(this.syncCopy());
            const byPk = new Map();
            for (const id of this.held()) byPk.set(id.pk, id);
            const theirs = new Map();
            for (const k of remote.keys) {
                const id = this._checked(k);
                if (!id) continue;
                theirs.set(id.pk, id);
                if (!byPk.has(id.pk)) byPk.set(id.pk, id);
            }
            const mine = st.current;
            const came = typeof remote.current === 'string' && theirs.has(remote.current) ? byPk.get(remote.current) : null;
            const winner = came && (!mine || beats(came, mine)) ? came : mine;
            if (winner && (!mine || winner.pk !== mine.pk)) this._annCache = null;
            st.current = winner || null;
            st.prev = [...byPk.values()].filter(id => !winner || id.pk !== winner.pk).sort(newestKey);

            const theirSpent = [];
            for (const x of Array.isArray(remote.spent) ? remote.spent : []) {
                if (typeof x === 'string' && HEX64.test(x) && !theirSpent.includes(x)) theirSpent.push(x);
            }
            const mySpent = (st.spent || []).filter(x => typeof x === 'string' && HEX64.test(x));
            const spent = new Set(mySpent.concat(theirSpent));
            st.spent = mySpent.filter(x => !theirSpent.includes(x)).concat(theirSpent).slice(0, SPENT_MAX);

            const local = (st.tokens || []).filter(tk => tk && !spent.has(tk.x));
            const localByX = new Map(local.map(tk => [tk.x, tk]));
            const arrived = [];
            for (const raw of Array.isArray(remote.tokens) ? remote.tokens : []) {
                const tk = tokenOf(raw);
                if (!tk || spent.has(tk.x) || arrived.some(a => a.x === tk.x)) continue;
                arrived.push(localByX.get(tk.x) || tk);
            }
            const arrivedX = new Set(arrived.map(tk => tk.x));
            const newestFirst = local.filter(tk => !arrivedX.has(tk.x)).reverse().concat(arrived).slice(0, SYNC_TOKENS_MAX);
            st.tokens = newestFirst.reverse();
            this.save();
            return JSON.stringify(this.syncCopy()) !== before;
        },

        // --- vouchers -------------------------------------------------------

        async keyset(force) {
            if (this._keyset && !force) return this._keyset;
            const { status, data } = await Api.voucherKeys();
            if (status >= 400 || !data || data.error || !data.keys || !data.keysetId) {
                throw new Error((data && data.error) || t('Voucher keys are unavailable.'));
            }
            const checked = keysetFrom(data.keys);
            if (!checked || checked.id !== String(data.keysetId)) {
                throw new Error(t('Voucher keyset rejected.'));
            }
            const pinned = Store.read('anon_keyset', null);
            if (pinned && pinned !== checked.id) {
                // A per-user keyset is exactly how a mint would tag its users,
                // so this is the user's call, not ours.
                const ok = this.onKeysetChange ? await this.onKeysetChange(pinned, checked.id) : false;
                if (!ok) throw new Error(t('Voucher keyset rejected.'));
            }
            Store.write('anon_keyset', checked.id);
            const keyset = Object.assign({}, data, { keysetId: checked.id, keys: checked.keys });
            this._keyset = keyset;
            return keyset;
        },

        _verifyDleq(keyHex, blindedHex, sig) {
            try {
                const Pt = P();
                const K = Pt.fromHex(keyHex);
                const B = Pt.fromHex(blindedHex);
                const Cp = Pt.fromHex(sig.C);
                const e = BigInt('0x' + sig.e);
                const s = BigInt('0x' + sig.s);
                if (e <= 0n || e >= N || s <= 0n || s >= N) return false;
                const R1 = Pt.BASE.multiply(s).subtract(K.multiply(e));
                const R2 = B.multiply(s).subtract(Cp.multiply(e));
                const check = scalarFrom(NT()._sha256(cat(
                    enc.encode(DLEQ_DOMAIN),
                    R1.toRawBytes(true), R2.toRawBytes(true),
                    K.toRawBytes(true), Cp.toRawBytes(true)
                )));
                return scalarHex(check) === String(sig.e).toLowerCase();
            } catch (_) { return false; }
        },

        _tokens(tier) {
            const list = (this.state && this.state.tokens) || [];
            return list.filter(t => t && (t.tier || 'standard') === tier);
        },

        _dropTokens(batch) {
            const gone = new Set(batch.map(t => t.x));
            this.state.tokens = (this.state.tokens || []).filter(t => !gone.has(t.x));
            this.state.spent = [...gone].concat((this.state.spent || []).filter(x => !gone.has(x))).slice(0, SPENT_MAX);
            this.save();
        },

        vouchers() {
            const out = { standard: 0, pro: 0 };
            for (const tier of TIERS) out[tier] = this._tokens(tier).reduce((n, t) => n + (Number(t.d) || 0), 0);
            return out;
        },

        /// Finishes an issuance whose response was lost: the same reqId and the
        /// same outputs re-sign without a second debit.
        async _finishIssue(pending) {
            const keyset = await this.keyset();
            const from = pending.from ? this.identity(pending.from) : null;
            if (pending.from && !from) {
                this.state.pending = null;
                this.save();
                throw new Error(t('Could not issue vouchers.'));
            }
            const { status, data } = await Api.voucherIssue({
                tier: pending.tier,
                reqId: pending.reqId,
                outputs: pending.outputs.map(o => ({ d: o.d, B: o.B }))
            }, from ? { signer: this.signer(from) } : {});
            if (status >= 400 || !data || data.error) {
                if (status >= 400 && status < 500 && !(data && data.insufficient)) {
                    this.state.pending = null;
                    this.save();
                }
                throw new Error((data && data.error) || t('Could not issue vouchers.'));
            }
            if (data.insufficient) {
                this.state.pending = null;
                this.save();
                const num = (v) => window.NymbotI18n.count(v);
                const err = new Error(pending.tier === 'pro'
                    ? t('Not enough Pro credits on your nym — {balance} left, {required} needed.',
                        { balance: num(data.balance), required: num(data.required) })
                    : t('Not enough credits on your nym — {balance} left, {required} needed.',
                        { balance: num(data.balance), required: num(data.required) }));
                err.insufficient = true;
                throw err;
            }
            const sigs = Array.isArray(data.signatures) ? data.signatures : [];
            if (sigs.length !== pending.outputs.length) throw new Error(t('The voucher response did not match the request.'));
            const Pt = P();
            const tokens = [];
            for (let i = 0; i < sigs.length; i++) {
                const out = pending.outputs[i];
                const sig = sigs[i];
                if (!sig || Number(sig.d) !== out.d) throw new Error(t('Voucher denomination mismatch.'));
                const keyHex = keyset.keys[pending.tier] && keyset.keys[pending.tier][String(out.d)];
                if (!keyHex) throw new Error(t('Unknown voucher denomination.'));
                if (!this._verifyDleq(keyHex, out.B, sig)) {
                    throw new Error(t('Nymbot returned a voucher signature it could not prove. Refusing it — an unprovable signature can be used to tag you. Nothing was spent anonymously.'));
                }
                const K = Pt.fromHex(keyHex);
                const unblinded = Pt.fromHex(sig.C).subtract(K.multiply(BigInt('0x' + out.r)));
                tokens.push({ d: out.d, x: out.x, C: unblinded.toHex(true), tier: pending.tier });
            }
            this.state.tokens = (this.state.tokens || []).concat(tokens);
            this.state.pending = null;
            this.save();
            return tokens;
        },

        _pick(tokens, want) {
            if (!(want > 0)) return tokens.slice(0, MAX_OUTPUTS);
            const out = [];
            let sum = 0;
            for (const tk of tokens.slice().sort((a, b) => b.d - a.d)) {
                if (sum >= want || out.length >= MAX_OUTPUTS) break;
                out.push(tk);
                sum += tk.d;
            }
            return out;
        },

        async _redeem(tier, identity, options) {
            const opts = options || {};
            const target = identity || this.ensure();
            let tokens = this._tokens(tier);
            if (opts.only) tokens = tokens.filter(tk => opts.only.has(tk.x));
            if (!tokens.length) return 0;
            const claimed = tokens.find(tk => tk.redeemId);
            let redeemId, batch, to;
            if (claimed) {
                redeemId = claimed.redeemId;
                batch = tokens.filter(tk => tk.redeemId === redeemId).slice(0, MAX_OUTPUTS);
                to = claimed.redeemTo ? this.identity(claimed.redeemTo) : this.ensure();
                if (!to) {
                    for (const tk of batch) { delete tk.redeemId; delete tk.redeemTo; }
                    this.save();
                    return 0;
                }
            } else {
                redeemId = hex(crypto.getRandomValues(new Uint8Array(32)));
                batch = this._pick(tokens, opts.want);
                to = target;
                for (const tk of batch) { tk.redeemId = redeemId; tk.redeemTo = to.pk; }
                this.save();
            }
            const { status, data } = await Api.voucherRedeem({
                tier, redeemId,
                tokens: batch.map(tk => ({ d: tk.d, x: tk.x, C: tk.C }))
            }, { signer: this.signer(to) });
            if (status >= 400 || !data || data.error) {
                if (data && data.alreadySpent) {
                    if (batch.length === 1) {
                        this._dropTokens(batch);
                        return 0;
                    }
                    for (const tk of batch) { delete tk.redeemId; delete tk.redeemTo; }
                    this.save();
                    let credited = 0;
                    for (const tk of batch) {
                        try {
                            credited += await this._redeem(tier, to, { only: new Set([tk.x]) });
                        } catch (_) { }
                    }
                    return to.pk === target.pk ? credited : 0;
                }
                throw new Error((data && data.error) || t('Could not redeem vouchers.'));
            }
            this._dropTokens(batch);
            if (typeof data.balance === 'number') this.remember(to.pk, tier, data.balance);
            return to.pk === target.pk ? (data.credited || 0) : 0;
        },

        async _fromVouchers(tier, identity, want) {
            let credited = 0;
            while (credited < want && this._tokens(tier).length) {
                credited += await this._redeem(tier, identity, { want: want - credited });
            }
            return credited;
        },

        /// Resumes anything a previous session left half-done.
        async flush() {
            if (this._flushing || !this.holds()) return;
            const st = this.state;
            const claimed = (tier) => this._tokens(tier).filter(tk => tk.redeemId);
            if (!st.pending && !claimed('standard').length && !claimed('pro').length) return;
            this._flushing = true;
            try {
                if (st.pending) await this._finishIssue(st.pending);
                for (const tier of TIERS) {
                    while (claimed(tier).length) {
                        const only = new Set(claimed(tier).map(tk => tk.x));
                        await this._redeem(tier, null, { only });
                    }
                }
            } catch (_) {
                // Left in place; the next flush picks it up.
            } finally {
                this._flushing = false;
            }
        },

        async _issue(amount, tier, from) {
            this.ensure();
            await this.keyset();
            if (this.state.pending) await this._finishIssue(this.state.pending);
            const denoms = denomsFor(amount);
            const Pt = P();
            let tokens = [];
            for (let i = 0; i < denoms.length; i += MAX_OUTPUTS) {
                const outputs = denoms.slice(i, i + MAX_OUTPUTS).map(d => {
                    const x = crypto.getRandomValues(new Uint8Array(32));
                    const r = randomScalar();
                    const B = hashToCurve(x).add(Pt.BASE.multiply(r));
                    return { d, x: hex(x), r: scalarHex(r), B: B.toHex(true) };
                });
                // Persisted BEFORE the call: a lost response has to be retried
                // with the same reqId and the same outputs, or it pays twice.
                this.state.pending = Object.assign({
                    tier,
                    reqId: hex(crypto.getRandomValues(new Uint8Array(32))),
                    outputs
                }, from ? { from: from.pk } : {});
                this.save();
                tokens = tokens.concat(await this._finishIssue(this.state.pending));
            }
            return tokens;
        },

        async moveCredits(amount, tier, identity) {
            amount = Math.floor(Number(amount) || 0);
            tier = tier === 'pro' ? 'pro' : 'standard';
            if (amount <= 0) throw new Error(t('Enter how many credits to move.'));
            if (!splitAmount(amount)) throw new Error(t('That amount needs too many vouchers — move a smaller amount.'));
            const target = identity || this.ensure();
            const issued = await this._issue(amount, tier, null);
            const fresh = new Set(issued.map(tk => tk.x));
            let credited = 0;
            while (this._tokens(tier).some(tk => fresh.has(tk.x))) {
                credited += await this._redeem(tier, target, { only: fresh });
            }
            return credited;
        },

        /// Moves credits across on its own, so anonymous mode does not mean
        /// remembering to fund a key by hand before every chat.
        ///
        /// Only ever moves from the nym to the throwaway key, never the other
        /// way, and never more than the nym actually holds. One call at a time:
        /// a second while the first is still minting would spend the same
        /// balance twice.
        async autoTopUp(options) {
            const opts = options || {};
            const settings = Store.settings();
            if (!settings.anonAutoTop || !(opts.identity || this.ready())) return null;
            if (this._topping) return this._topping;
            const target = opts.identity || this.ensure();

            const floor = Math.max(0, parseInt(settings.anonAutoTopFloor, 10) || 0);
            const amount = Math.max(1, parseInt(settings.anonAutoTopAmount, 10) || 25);
            const want = settings.anonAutoTopTier || 'both';
            const tiers = want === 'both' ? ['standard', 'pro'] : [want];

            this._topping = (async () => {
                const moved = {};
                try {
                    const b = await this.balances(target);
                    for (const tier of tiers) {
                        const here = tier === 'pro' ? b.anonPro : b.anon;
                        const nym = tier === 'pro' ? b.identityPro : b.identity;
                        if (here == null) continue;
                        if (!opts.force && here >= floor) continue;
                        if (opts.force && here >= floor + amount) continue;
                        let credited = 0;
                        try {
                            credited += await this._fromVouchers(tier, target, amount);
                        } catch (_) { }
                        const take = Math.min(amount - credited, nym || 0);
                        if (take > 0) {
                            try {
                                credited += await this.moveCredits(take, tier, target);
                            } catch (_) {
                            }
                        }
                        if (credited > 0) moved[tier] = credited;
                    }
                } catch (_) {
                    return null;
                } finally {
                    this._topping = null;
                }
                return Object.keys(moved).length ? moved : null;
            })();
            return this._topping;
        },

        async fund(identity, tier, need, known) {
            if (!identity && !this.ready()) return null;
            const target = identity || this.ensure();
            const which = tier === 'pro' ? 'pro' : 'standard';
            const want = Math.max(0, Number(need) || 0);
            if (known != null && known >= want) return null;
            while (this._topping) await this._topping;
            this._topping = (async () => {
                try {
                    const { data } = await Api.balance({ signer: this.signer(target) });
                    this.rememberData(target.pk, data);
                    const here = creditsOf(data, which);
                    if (here == null || here >= want) return null;
                    if (which === 'standard' && data.free && Number(data.free.left) > 0) return null;
                    const short = Math.ceil(want - here);
                    let credited = 0;
                    try {
                        credited = await this._fromVouchers(which, target, short);
                    } catch (_) { }
                    const settings = Store.settings();
                    if (credited < short && settings.anonAutoTop) {
                        const amount = Math.max(short - credited, parseInt(settings.anonAutoTopAmount, 10) || 25);
                        const r = await Api.balance();
                        const take = Math.min(amount, Math.floor(creditsOf(r && r.data, which) || 0));
                        if (take > 0) {
                            try {
                                credited += await this.moveCredits(take, which, target);
                            } catch (_) { }
                        }
                    }
                    return credited > 0 ? { [which]: credited } : null;
                } catch (_) {
                    return null;
                } finally {
                    this._topping = null;
                }
            })();
            return this._topping;
        },

        known() {
            const held = Store.read('anon_balances', null);
            return held && typeof held === 'object' ? held : {};
        },

        remember(pk, tier, value) {
            if (!pk || value == null || !Number.isFinite(Number(value))) return;
            const all = this.known();
            const row = Object.assign({ standard: null, pro: null }, all[pk]);
            row[tier === 'pro' ? 'pro' : 'standard'] = Number(value);
            row.at = Date.now();
            all[pk] = row;
            Store.quiet(() => Store.write('anon_balances', all));
        },

        rememberData(pk, data) {
            if (!pk || !data || data.error) return;
            this.remember(pk, 'standard', creditsOf(data, 'standard'));
            this.remember(pk, 'pro', creditsOf(data, 'pro'));
        },

        lastKnown() {
            const all = this.known();
            const out = { keys: {}, total: { standard: 0, pro: 0 } };
            const round = (v) => Math.round(v * 1000) / 1000;
            for (const id of this.held()) {
                const row = all[id.pk];
                if (!row) continue;
                out.keys[id.pk] = row;
                out.total.standard = round(out.total.standard + (Number(row.standard) || 0));
                out.total.pro = round(out.total.pro + (Number(row.pro) || 0));
            }
            return out;
        },

        async balances(identity) {
            const out = { anon: null, anonPro: null, identity: null, identityPro: null };
            if (identity || this.ready()) {
                const payer = identity || this.ensure();
                const a = await Api.balance({ signer: this.signer(payer) });
                this.rememberData(payer.pk, a.data);
                if (a.data && !a.data.error) { out.anon = a.data.balance || 0; out.anonPro = a.data.proBalance || 0; }
            }
            const r = await Api.balance();
            if (r.data && !r.data.error) { out.identity = r.data.balance || 0; out.identityPro = r.data.proBalance || 0; }
            return out;
        }
    };

    window.NymbotAnon = Anon;
})();
