// Building and opening NIP-59 gift wraps, for both logins.
//
// A local key can do the whole thing in one call. A signer holds only the
// identity key, so the seal's NIP-44 goes through it and the post-quantum layer
// and the wrap are assembled here — which is exactly why the pq2 format layers
// the two rather than combining them.
(function () {
    'use strict';

    const Identity = window.NymbotIdentity;
    const PQ = window.NymbotPQ;
    const NT = () => window.NostrTools;
    const NC = () => window.NymCrypto;

    function sharedId() {
        return window.NymbotHex.hex(crypto.getRandomValues(new Uint8Array(32)));
    }

    function tagValue(evt, name) {
        const t = (evt.tags || []).find(x => Array.isArray(x) && x[0] === name);
        return t ? t[1] : null;
    }

    const Wire = {
        sharedId,
        tagValue,

        /// The kind-14 rumor. `threadRoot` is the conversation this message
        /// belongs to: the worker scopes the model's context to the messages
        /// carrying the same marker, which is what keeps chats separate.
        rumor(content, recipientPubkey, threadRoot, msgId, senderPubkey) {
            const nowMs = Date.now();
            return {
                kind: 14,
                created_at: Math.floor(nowMs / 1000),
                tags: [
                    ['p', recipientPubkey],
                    ['x', msgId || sharedId()],
                    ['ms', String(nowMs)],
                    ...(threadRoot ? [['nymthread', threadRoot]] : [])
                ],
                content,
                pubkey: senderPubkey || Identity.pubkey
            };
        },

        /// Wraps `rumor` to one recipient. `kemPk` present means hybrid.
        /// `sender` overrides the identity with a local keypair — anonymous
        /// mode's throwaway key, which signs everything in its conversation.
        async wrap(rumor, recipientPubkey, kemPk, sender) {
            const T = NT();
            const NCx = NC();
            const sk = sender ? sender.sk : Identity._sk;
            if (sk) {
                return kemPk
                    ? NCx.pq2Nip59Wrap(rumor, sk, recipientPubkey, kemPk)
                    : NCx.nip59Wrap(rumor, sk, recipientPubkey);
            }

            // Signer path. The rumor is unsigned by design, so only its id is
            // computed here; the seal is signed by the extension.
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

        /// Opens a wrap addressed to us. Returns { seal, rumor } or null.
        /// `recipient` is { sk, kemSk, kemPk } when the wrap was addressed to a
        /// key other than the identity's.
        async unwrap(event, recipient) {
            const T = NT();
            const NCx = NC();
            const self = recipient || PQ.selfKeys();
            const sk = recipient ? recipient.sk : Identity._sk;
            if (sk) {
                const got = NCx.unwrapGiftWrap(event, [{
                    sk,
                    kemSk: self ? self.kemSk : undefined,
                    kemPk: self ? self.kemPk : undefined
                }]);
                return got ? { seal: got.seal, rumor: got.rumor } : null;
            }

            try {
                const open = async (content, senderPk) => {
                    if (NCx.isPq2Payload(content)) {
                        if (!self) throw new Error('no kem key');
                        const inner = NCx.pq2Open(content, senderPk, Identity.pubkey, self);
                        return Identity.decryptFrom(senderPk, inner);
                    }
                    // pq1 combines the ECDH output with the KEM secret, which a
                    // signer never exposes. Nothing addressed to a signer login
                    // should be pq1 — its announcement advertises pk2 only.
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
