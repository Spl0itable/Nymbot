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

    // What one gift wrap can carry.
    //
    // NIP-44 v2 refuses a plaintext over 65535 bytes, and the wrap's plaintext
    // is the serialized seal — which holds the base64 of the sealed rumor. So
    // a message pays for base64 expansion (4/3), NIP-44's padding (up to 1/8)
    // and the envelope's own fields, twice over. The post-quantum layer adds
    // an ML-KEM ciphertext to each of those two encryptions, which is the
    // other fifth.
    //
    // Measured rather than guessed: the largest message that wraps is 40,537
    // bytes over NIP-44 alone and 32,345 with pq2, falling to 26,460 when
    // every character needs a JSON escape. The cap below is that worst case
    // with room left, and it is applied to the escaped UTF-8 length so a
    // message of quotes and newlines is measured as what it will really cost.
    const BODY_MAX = 24000;

    /// What `text` costs on the wire: its JSON-escaped length in UTF-8 bytes.
    /// A quote or a newline is two bytes there, not one, and an emoji is four
    /// bytes rather than one character.
    function bodyCost(text) {
        const json = JSON.stringify(String(text == null ? '' : text));
        return new TextEncoder().encode(json).length - 2;
    }

    function fits(text) {
        return bodyCost(text) <= BODY_MAX;
    }

    // How many wraps one question may be split across. A message past this is
    // not a message, and eight of them is roughly 180 KB — well past anything
    // a model would read in one turn anyway.
    const PARTS_MAX = 8;

    /// Cuts `text` into pieces each of which fits in one wrap.
    ///
    /// The cut is taken at the last line break inside the budget rather than
    /// at the byte, so a split lands between lines and a fenced block or a
    /// sentence is not sawn in half. A single line longer than a whole wrap
    /// has nowhere better to go and is cut where it must be.
    ///
    /// Budget is spent in escaped UTF-8 bytes, which is what the wire charges,
    /// so the walk is a binary search on the character count rather than a
    /// count of characters — a line of quotes costs twice what its length
    /// suggests, and an emoji four times.
    function split(text) {
        const whole = String(text == null ? '' : text);
        if (bodyCost(whole) <= BODY_MAX) return [whole];
        const parts = [];
        let rest = whole;
        while (rest) {
            if (bodyCost(rest) <= BODY_MAX) { parts.push(rest); break; }
            // The largest prefix that still fits.
            let lo = 1;
            let hi = rest.length;
            while (lo < hi) {
                const mid = Math.ceil((lo + hi) / 2);
                if (bodyCost(rest.slice(0, mid)) <= BODY_MAX) lo = mid; else hi = mid - 1;
            }
            let cut = lo;
            // Back up to a line break, but not so far that a part is mostly
            // empty — a long unbroken run has to be cut somewhere.
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

        /// The kind-14 rumor. `threadRoot` is the conversation this message
        /// belongs to: the worker scopes the model's context to the messages
        /// carrying the same marker, which is what keeps chats separate.
        rumor(content, recipientPubkey, threadRoot, msgId, senderPubkey, part) {
            const nowMs = Date.now();
            return {
                kind: 14,
                created_at: Math.floor(nowMs / 1000),
                tags: [
                    ['p', recipientPubkey],
                    ['x', msgId || sharedId()],
                    ['ms', String(nowMs)],
                    // One question too long for a single wrap travels as
                    // several, each saying where it sits so the worker can put
                    // them back in order rather than trusting the relays to
                    // deliver them in one.
                    ...(part ? [['part', String(part.index), String(part.of)]] : []),
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
