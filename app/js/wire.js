// A signer exposes only identity-key NIP-44, which is why pq2 layers the PQ encryption rather than combining.
(function () {
    'use strict';

    const Identity = window.NymbotIdentity;
    const PQ = window.NymbotPQ;
    const NT = () => window.NostrTools;
    const NC = () => window.NymCrypto;

    function sharedId() {
        return window.NymbotHex.hex(crypto.getRandomValues(new Uint8Array(32)));
    }

    // NIP-44 caps plaintext at 65535 bytes; the measured worst case is 26,460 bytes (pq2, fully escaped).
    const BODY_MAX = 24000;

    /// JSON-escaped length in UTF-8 bytes.
    function bodyCost(text) {
        const json = JSON.stringify(String(text == null ? '' : text));
        return new TextEncoder().encode(json).length - 2;
    }

    function fits(text) {
        return bodyCost(text) <= BODY_MAX;
    }

    const PARTS_MAX = 8;

    /// Cuts at the last line break within budget; binary-searches characters because cost is escaped UTF-8 bytes.
    function split(text) {
        const whole = String(text == null ? '' : text);
        if (bodyCost(whole) <= BODY_MAX) return [whole];
        const parts = [];
        let rest = whole;
        while (rest) {
            if (bodyCost(rest) <= BODY_MAX) { parts.push(rest); break; }
            let lo = 1;
            let hi = rest.length;
            while (lo < hi) {
                const mid = Math.ceil((lo + hi) / 2);
                if (bodyCost(rest.slice(0, mid)) <= BODY_MAX) lo = mid; else hi = mid - 1;
            }
            let cut = lo;
            // Back up to a line break, but not so far that a part is mostly empty.
            const nl = rest.lastIndexOf('\n', cut - 1);
            if (nl > cut * 0.5) cut = nl + 1;
            parts.push(rest.slice(0, cut));
            rest = rest.slice(cut);
        }
        return parts;
    }

    function tagValue(evt, name) {
        const t = (evt.tags || []).find(x => Array.isArray(x) && x[0] === name);
        return t ? t[1] : null;
    }

    const Wire = {
        sharedId,
        tagValue,
        BODY_MAX,
        PARTS_MAX,
        bodyCost,
        fits,
        split,

        /// `threadRoot` scopes the worker's model context, which keeps chats separate.
        rumor(content, recipientPubkey, threadRoot, msgId, senderPubkey, part) {
            const nowMs = Date.now();
            return {
                kind: 14,
                created_at: Math.floor(nowMs / 1000),
                tags: [
                    ['p', recipientPubkey],
                    ['x', msgId || sharedId()],
                    ['ms', String(nowMs)],
                    // Parts carry their position so the worker reorders them instead of trusting relay delivery order.
                    ...(part ? [['part', String(part.index), String(part.of)]] : []),
                    ...(threadRoot ? [['nymthread', threadRoot]] : [])
                ],
                content,
                pubkey: senderPubkey || Identity.pubkey
            };
        },

        /// `kemPk` present means hybrid; `sender` overrides the identity with a local keypair.
        async wrap(rumor, recipientPubkey, kemPk, sender) {
            const T = NT();
            const NCx = NC();
            const sk = sender ? sender.sk : Identity._sk;
            if (sk) {
                return kemPk
                    ? NCx.pq2Nip59Wrap(rumor, sk, recipientPubkey, kemPk)
                    : NCx.nip59Wrap(rumor, sk, recipientPubkey);
            }

            // The rumor is unsigned by design; the extension signs the seal.
            const inner = Object.assign({}, rumor, { pubkey: Identity.pubkey });
            inner.id = T.getEventHash(inner);
            const sealPlain = JSON.stringify(inner);
            const sealInner = await Identity.encryptTo(recipientPubkey, sealPlain);
            const sealContent = kemPk
                ? NCx.pq2Seal(sealInner, Identity.pubkey, recipientPubkey, kemPk)
                : sealInner;
            const seal = await Identity.signEvent({
                kind: 13,
                created_at: NCx.randomNow(),
                tags: [],
                content: sealContent
            });

            const ephSk = T.generateSecretKey();
            const wrapContent = kemPk
                ? NCx.pq2Encrypt(JSON.stringify(seal), ephSk, recipientPubkey, kemPk)
                : T.nip44.encrypt(JSON.stringify(seal),
                    T.nip44.getConversationKey(ephSk, recipientPubkey));
            return T.finalizeEvent({
                kind: 1059,
                content: wrapContent,
                created_at: NCx.randomNow(),
                tags: [['p', recipientPubkey]],
                pubkey: T.getPublicKey(ephSk)
            }, ephSk);
        },

        /// Returns { seal, rumor } or null; `recipient` is { sk, kemSk, kemPk } for a key other than the identity's.
        async unwrap(event, recipient, options) {
            const opened = await this.openWrap(event, recipient);
            const from = options && options.from;
            if (!opened || !from) return opened;
            return this.sealedBy(opened, from) ? opened : null;
        },

        sealedBy(opened, author) {
            const T = NT();
            const seal = opened && opened.seal;
            const rumor = opened && opened.rumor;
            if (!seal || !rumor || typeof seal !== 'object' || typeof rumor !== 'object') return false;
            if (seal.kind !== 13 || seal.pubkey !== author || rumor.pubkey !== seal.pubkey) return false;
            try {
                if (T.getEventHash(seal) !== seal.id) return false;
                return !!T.verifyEvent(seal);
            } catch (_) {
                return false;
            }
        },

        async openWrap(event, recipient) {
            const T = NT();
            const NCx = NC();
            const selves = recipient
                ? [{ kemSk: recipient.kemSk, kemPk: recipient.kemPk }]
                : PQ.selfCandidates();
            const sk = recipient ? recipient.sk : Identity._sk;
            if (sk) {
                const candidates = selves.length
                    ? selves.map(s => ({ sk, kemSk: s.kemSk, kemPk: s.kemPk }))
                    : [{ sk }];
                const got = NCx.unwrapGiftWrap(event, candidates);
                return got ? { seal: got.seal, rumor: got.rumor } : null;
            }

            try {
                const open = async (content, senderPk) => {
                    if (NCx.isPq2Payload(content)) {
                        const usable = selves.filter(s => s && s.kemSk && s.kemPk);
                        if (!usable.length) throw new Error('no kem key');
                        let inner = null;
                        let lastErr = null;
                        for (const self of usable) {
                            try { inner = NCx.pq2Open(content, senderPk, Identity.pubkey, self); break; }
                            catch (e) { lastErr = e; }
                        }
                        if (inner == null) throw lastErr || new Error('post-quantum layer did not open');
                        return Identity.decryptFrom(senderPk, inner);
                    }
                    // pq1 needs the ECDH output, which a signer never exposes; signer logins advertise pk2 only.
                    if (NCx.isPqPayload(content)) throw new Error('pq1 needs a local key');
                    return Identity.decryptFrom(senderPk, content);
                };
                const seal = JSON.parse(await open(event.content, event.pubkey));
                const rumor = JSON.parse(await open(seal.content, seal.pubkey));
                return { seal, rumor };
            } catch (_) {
                return null;
            }
        }
    };

    window.NymbotWire = Wire;
})();
