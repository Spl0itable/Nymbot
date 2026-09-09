// Post-quantum capability announcements (kind 30078, d-tag `nym-pq`).
//
// Each side publishes the ML-KEM public key it can decapsulate with; the other
// seals to it. Ours also rides along with every worker request, signed, so the
// reply is sealed to it deterministically instead of depending on a lookup that
// could lose a race and leave the answer classical.
(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Relays = window.NymbotRelays;
    const Identity = window.NymbotIdentity;
    const NT = () => window.NostrTools;
    const NC = () => window.NymCrypto;

    const KEM_PK_LEN = 1184;

    function readKey(raw) {
        if (raw == null) return undefined;
        let k;
        try { k = NC()._b64uDecode(raw); } catch (_) { return null; }
        return (k instanceof Uint8Array && k.length === KEM_PK_LEN) ? k : null;
    }

    /// The newest signed, id-valid announcement by `author`. Relays are never
    /// trusted for key material.
    function verifiedNewest(events, author) {
        const T = NT();
        let newest = null;
        for (const evt of events || []) {
            if (!evt || evt.pubkey !== author || evt.kind !== 30078 || !evt.sig) continue;
            if (newest && evt.created_at <= newest.created_at) continue;
            try {
                if (T.getEventHash(evt) !== evt.id) continue;
                if (!T.verifyEvent(evt)) continue;
            } catch (_) { continue; }
            newest = evt;
        }
        return newest;
    }

    function parse(event, nowSec) {
        try {
            if (!event || !event.content) return null;
            const payload = JSON.parse(event.content);
            if (!payload || payload.alg !== C.pqAlg || payload.retracted) return null;
            const exp = parseInt(payload.exp, 10) || 0;
            if (exp <= (nowSec || Math.floor(Date.now() / 1000))) return null;
            const pk1 = readKey(payload.pk);
            const pk2 = readKey(payload.pk2);
            if (pk1 === null || pk2 === null) return null;
            return {
                pk1: pk1 || null,
                pk2: pk2 || null,
                rootSeeded: payload.v === 2 && payload.src === 'root',
                epoch: parseInt(payload.epoch, 10) || 0,
                exp
            };
        } catch (_) { return null; }
    }

    const PQ = {
        botKey: null,            // { pk, fmt } or null
        selfAnnouncement: null,  // the signed event the worker is handed

        async resolve(pubkey) {
            const events = await Relays.fetch(
                { kinds: [30078], authors: [pubkey], '#d': [C.pqDTag], limit: 3 }, 4000);
            const newest = verifiedNewest(events, pubkey);
            const parsed = newest ? parse(newest, Math.floor(Date.now() / 1000)) : null;
            if (!parsed) return null;
            if (parsed.pk2) return { pk: parsed.pk2, fmt: 'pq2' };
            if (parsed.pk1) return { pk: parsed.pk1, fmt: 'pq1' };
            return null;
        },

        async resolveBot() {
            this.botKey = await this.resolve(C.botPubkey);
            return this.botKey;
        },

        /// Publishes our announcement, unless the account already advertises a
        /// key we cannot derive — that one belongs to another device holding a
        /// different root, and kind 30078 is replaceable, so publishing over it
        /// would strand every message sealed to it.
        async announce() {
            if (!Identity.pubkey || !Identity.kemPk) return false;
            const mine = Identity.kemPk;
            const existing = await this.resolve(Identity.pubkey);
            if (existing && !sameBytes(existing.pk, mine)) {
                Identity.rootLocked = true;
                return false;
            }
            Identity.rootLocked = false;

            const nowSec = Math.max(Math.floor(Date.now() / 1000), (this._lastTs || 0) + 1);
            this._lastTs = nowSec;
            const exp = nowSec + C.pqTtlSec;
            const payload = {
                v: 2,
                src: 'root',
                alg: C.pqAlg,
                nym: 1,
                // Which epoch of the root this key came from.
                epoch: Identity._epoch || 0,
                // A local key can open either format; a signer login can only
                // do the layered one, and says so by advertising pk2 alone.
                ...(Identity.isLocal ? { pk: NC()._b64uEncode(mine) } : {}),
                pk2: NC()._b64uEncode(mine),
                exp,
                devices: []
            };
            const signed = await Identity.signEvent({
                kind: 30078,
                created_at: nowSec,
                tags: [['d', C.pqDTag], ['t', C.pqDTag], ['expiration', String(exp)]],
                content: JSON.stringify(payload)
            });
            await Relays.publish(signed, 4000);
            this.selfAnnouncement = signed;
            return true;
        },

        /// Our own KEM material, for opening replies and self-addressed copies.
        selfKeys() {
            if (!Identity._kem) return null;
            return { kemSk: Identity._kem.secretKey, kemPk: Identity._kem.publicKey };
        }
    };

    function sameBytes(a, b) {
        if (!a || !b || a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
        return true;
    }

    window.NymbotPQ = PQ;
})();
