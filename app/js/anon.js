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
    const MAX_OUTPUTS = 32;
    const HTC_DOMAIN = 'Nymbot_Voucher_HashToCurve_v1';
    const DLEQ_DOMAIN = 'Nymbot_Voucher_DLEQ_v1';
    const PREV_MAX = 4;
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

    const Anon = {
        state: null,
        onKeysetChange: null,   // (oldId, newId) => Promise<boolean>

        // --- identity -------------------------------------------------------

        load() {
            this.state = Store.read('anon', null) || { current: null, prev: [], tokens: [], pending: null };
            return this.state;
        },

        save() { Store.write('anon', this.state); },

        enabled() { return !!Store.settings().anon; },

        setEnabled(on) {
            Store.setSettings({ anon: !!on });
            if (on) { this.ensure(); this.flush().catch(() => { }); }
        },

        ready() { return !!(this.enabled() && this.state && this.state.current); },

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

        /// The signing key material, for wrapping and for opening replies.
        sender() {
            const id = this.ensure();
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

        recipient() {
            const id = this.ensure();
            const kp = this.kem(id);
            return { sk: unhex(id.sk), kemSk: kp ? kp.secretKey : undefined, kemPk: kp ? kp.publicKey : undefined };
        },

        /// The auth signer the worker sees: this key, never the account's.
        signer() {
            const id = this.ensure();
            const sk = unhex(id.sk);
            return { pubkey: id.pk, sign: (evt) => NT().finalizeEvent(Object.assign({ pubkey: id.pk }, evt), sk) };
        },

        /// A signed announcement carrying the throwaway KEM key, handed to the
        /// worker with each request so the reply comes back hybrid without a
        /// lookup that would have nothing to find.
        announcement() {
            const id = this.ensure();
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
                this.state.prev = [old].concat(this.state.prev || []).slice(0, PREV_MAX);
            }
            this.state.current = this._newIdentity();
            this._annCache = null;
            this.save();
            if (!sweep || !old) return 0;
            return this._sweep(old);
        },

        /// Moves a previous key's balance onto the current one. The worker sees
        /// one anonymous key paying another, which is the documented limit.
        async _sweep(identity) {
            const sk = unhex(identity.sk);
            const signer = {
                pubkey: identity.pk,
                sign: (evt) => NT().finalizeEvent(Object.assign({ pubkey: identity.pk }, evt), sk)
            };
            const { data } = await Api.transferCredits(this.state.current.pk, { signer });
            return (data && !data.error) ? 1 : 0;
        },

        // --- vouchers -------------------------------------------------------

        async keyset(force) {
            if (this._keyset && !force) return this._keyset;
            const { status, data } = await Api.voucherKeys();
            if (status >= 400 || !data || data.error || !data.keys || !data.keysetId) {
                throw new Error((data && data.error) || t('Voucher keys are unavailable.'));
            }
            const pinned = Store.read('anon_keyset', null);
            if (pinned && pinned !== data.keysetId) {
                // A per-user keyset is exactly how a mint would tag its users,
                // so this is the user's call, not ours.
                const ok = this.onKeysetChange ? await this.onKeysetChange(pinned, data.keysetId) : false;
                if (!ok) throw new Error(t('Voucher keyset rejected.'));
            }
            Store.write('anon_keyset', data.keysetId);
            this._keyset = data;
            return data;
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
            this.save();
        },

        /// Finishes an issuance whose response was lost: the same reqId and the
        /// same outputs re-sign without a second debit.
        async _finishIssue(pending) {
            const keyset = await this.keyset();
            const { status, data } = await Api.voucherIssue({
                tier: pending.tier,
                reqId: pending.reqId,
                outputs: pending.outputs.map(o => ({ d: o.d, B: o.B }))
            });
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
                const err = new Error(pending.tier === 'pro'
                    ? t('Not enough Pro credits on your nym — {balance} left, {required} needed.',
                        { balance: data.balance, required: data.required })
                    : t('Not enough credits on your nym — {balance} left, {required} needed.',
                        { balance: data.balance, required: data.required }));
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

        async _redeem(tier) {
            const tokens = this._tokens(tier);
            if (!tokens.length) return 0;
            const claimed = tokens.find(t => t.redeemId);
            let redeemId, batch;
            if (claimed) {
                redeemId = claimed.redeemId;
                batch = tokens.filter(t => t.redeemId === redeemId).slice(0, MAX_OUTPUTS);
            } else {
                redeemId = hex(crypto.getRandomValues(new Uint8Array(32)));
                batch = tokens.slice(0, MAX_OUTPUTS);
                for (const t of batch) t.redeemId = redeemId;
                this.save();
            }
            const { status, data } = await Api.voucherRedeem({
                tier, redeemId,
                tokens: batch.map(t => ({ d: t.d, x: t.x, C: t.C }))
            }, { signer: this.signer() });
            if (status >= 400 || !data || data.error) {
                if (data && data.alreadySpent) this._dropTokens(batch);
                throw new Error((data && data.error) || t('Could not redeem vouchers.'));
            }
            this._dropTokens(batch);
            return data.credited || 0;
        },

        /// Resumes anything a previous session left half-done.
        async flush() {
            if (this._flushing || !this.ready()) return;
            const st = this.state;
            if (!st.pending && !(st.tokens || []).length) return;
            this._flushing = true;
            try {
                if (st.pending) await this._finishIssue(st.pending);
                for (const tier of ['standard', 'pro']) {
                    while (this._tokens(tier).length) await this._redeem(tier);
                }
            } catch (_) {
                // Left in place; the next flush picks it up.
            } finally {
                this._flushing = false;
            }
        },

        async moveCredits(amount, tier) {
            amount = Math.floor(Number(amount) || 0);
            tier = tier === 'pro' ? 'pro' : 'standard';
            if (amount <= 0) throw new Error(t('Enter how many credits to move.'));
            const denoms = splitAmount(amount);
            if (!denoms) throw new Error(t('That amount needs too many vouchers — move a smaller amount.'));
            this.ensure();
            await this.keyset();
            if (this.state.pending) await this._finishIssue(this.state.pending);

            const Pt = P();
            const outputs = denoms.map(d => {
                const x = crypto.getRandomValues(new Uint8Array(32));
                const r = randomScalar();
                const B = hashToCurve(x).add(Pt.BASE.multiply(r));
                return { d, x: hex(x), r: scalarHex(r), B: B.toHex(true) };
            });
            // Persisted BEFORE the call: a lost response has to be retried with
            // the same reqId and the same outputs, or it pays twice.
            this.state.pending = {
                tier,
                reqId: hex(crypto.getRandomValues(new Uint8Array(32))),
                outputs
            };
            this.save();
            await this._finishIssue(this.state.pending);

            let credited = 0;
            while (this._tokens(tier).length) credited += await this._redeem(tier);
            return credited;
        },

        async balances() {
            const out = { anon: null, anonPro: null, identity: null, identityPro: null };
            if (this.ready()) {
                const a = await Api.balance({ signer: this.signer() });
                if (a.data && !a.data.error) { out.anon = a.data.balance || 0; out.anonPro = a.data.proBalance || 0; }
            }
            const r = await Api.balance();
            if (r.data && !r.data.error) { out.identity = r.data.balance || 0; out.identityPro = r.data.proBalance || 0; }
            return out;
        }
    };

    window.NymbotAnon = Anon;
})();
