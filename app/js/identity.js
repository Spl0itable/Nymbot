// The key, and everything that signs or decrypts with it.
//
// Two logins. A LOCAL key (generated here, or an nsec pasted in) can do
// everything itself. A NIP-07 EXTENSION holds the key and performs the seal's
// NIP-44 on our behalf; the wrap's ephemeral key is minted here either way, so
// both logins get the same post-quantum layer.
//
// The ML-KEM keypair comes from a root generated independently of the signing
// key (docs/PQ-ROOT-SPEC.md in nym-staging): the signing pubkey is published on
// every wrap, so a KEM key derived from it would fall with secp256k1.
(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;
    const NT = () => window.NostrTools;
    const NC = () => window.NymCrypto;

    function hex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    function unhex(str) {
        const out = new Uint8Array(str.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16);
        return out;
    }

    const Identity = {
        pubkey: null,
        method: null,     // 'local' | 'nip07'
        _sk: null,        // Uint8Array, local logins only
        _root: null,      // Uint8Array
        _kem: null,       // { publicKey, secretKey }
        // Which epoch of the root this account's KEM key is derived at.
        _epoch: 0,
        // True when the account already advertises a KEM key this device cannot
        // derive. Announcing over it would strand every other device, so we do
        // not, and the reply comes back classical until the root is linked.
        rootLocked: false,

        get skHex() { return this._sk ? hex(this._sk) : null; },
        get isLocal() { return this.method === 'local'; },
        get kemPk() { return this._kem ? this._kem.publicKey : null; },

        /// Restores whatever the last session left. Returns false when there is
        /// no identity yet and the caller should show the welcome screen.
        restore() {
            const saved = Store.identity();
            if (!saved || !saved.pubkey) return false;
            this.pubkey = saved.pubkey;
            this.method = saved.method || 'local';
            if (saved.secret) this._sk = unhex(saved.secret);
            if (saved.root) this._root = unhex(saved.root);
            this._epoch = Math.max(0, Math.floor(Number(saved.epoch) || 0));
            this._deriveKem();
            return true;
        },

        generate() {
            const sk = NT().generateSecretKey();
            this._adopt(sk, NT().getPublicKey(sk), 'local', NC().pqGenerateRoot());
            return this.rootCode();
        },

        /// Reads a key without adopting it, so the caller can ask what the
        /// account already has before deciding what root to give it.
        readSecret(input) {
            const text = String(input || '').trim();
            if (/^[0-9a-f]{64}$/i.test(text)) return unhex(text.toLowerCase());
            if (/^nsec1/.test(text)) {
                const d = NT().nip19.decode(text);
                if (d.type !== 'nsec') throw new Error(t('That is not a private key.'));
                return d.data;
            }
            throw new Error(t('Paste an nsec, or its 64-character hex form.'));
        },

        /// Accepts an `nsec1…` or a raw 64-character hex key.
        ///
        /// `root` decides the post-quantum half. Minting one unasked is what
        /// this used to do, and it is wrong for a key that has been used
        /// before: the account's announcement is replaceable, so a second root
        /// published over the first strands every settings row, every synced
        /// conversation and every reply sealed to the one it replaced. The
        /// caller looks the account up first and passes null to say "this
        /// account already has one, do not invent another".
        importSecret(input, root, epoch) {
            const sk = this.readSecret(input);
            const next = root === null ? null : (root || this._root || NC().pqGenerateRoot());
            this._adopt(sk, NT().getPublicKey(sk), 'local', next, epoch);
            this.rootLocked = !next;
        },

        async extensionPubkey() {
            if (!window.nostr || typeof window.nostr.getPublicKey !== 'function') {
                throw new Error(t('No Nostr extension found in this browser.'));
            }
            const pk = await window.nostr.getPublicKey();
            if (!/^[0-9a-f]{64}$/i.test(pk || '')) throw new Error(t('The extension returned no key.'));
            if (!window.nostr.nip44 || typeof window.nostr.nip44.encrypt !== 'function') {
                throw new Error(t('This extension cannot do NIP-44 encryption, which private messages need.'));
            }
            return pk.toLowerCase();
        },

        async useExtension(root, epoch) {
            const pk = await this.extensionPubkey();
            const next = root === null ? null : (root || this._root || NC().pqGenerateRoot());
            this._adopt(null, pk, 'nip07', next, epoch);
            this.rootLocked = !next;
        },

        _adopt(sk, pubkey, method, root, epoch) {
            this._sk = sk;
            this.pubkey = pubkey;
            this.method = method;
            this._root = root;
            this._epoch = Math.max(0, Math.floor(Number(epoch) || 0));
            this._deriveKem();
            this._persist();
        },

        _persist() {
            Store.setIdentity({
                pubkey: this.pubkey,
                method: this.method,
                secret: this._sk ? hex(this._sk) : undefined,
                root: this._root ? hex(this._root) : undefined,
                epoch: this._epoch || 0
            });
        },

        _deriveKem() {
            this._kem = null;
            if (!this._root) return;
            try { this._kem = NC().pqKeypairFromRoot(this._root, this._epoch || 0); } catch (_) { }
        },

        // --- the post-quantum root -----------------------------------------

        rootCode() {
            if (!this._root) return null;
            try { return NC().pqRootEncode(this._root); } catch (_) { return null; }
        },

        rootFingerprint() {
            if (!this._root) return null;
            try { return NC().pqRootFingerprint(this._root); } catch (_) { return null; }
        },

        /// Links this device to an existing account's root, pasted from the
        /// other app's identity settings.
        adoptRootCode(code, epoch) {
            const bytes = NC().pqRootDecode(String(code || '').trim());
            this._root = bytes;
            if (epoch != null) this._epoch = Math.max(0, Math.floor(Number(epoch) || 0));
            this._deriveKem();
            this.rootLocked = false;
            this._persist();
        },

        /// The KEM key a given code would produce, without adopting it — so a
        /// pasted code can be checked against what the account actually
        kemForCode(code, epoch) {
            try {
                const bytes = NC().pqRootDecode(String(code || '').trim());
                const pair = NC().pqKeypairFromRoot(bytes, Math.max(0, Math.floor(Number(epoch) || 0)));
                return pair ? pair.publicKey : null;
            } catch (_) { return null; }
        },

        /// Mints one now, for an account that turns out not to have one.
        mintRoot() {
            this._root = NC().pqGenerateRoot();
            this._epoch = 0;
            this._deriveKem();
            this.rootLocked = false;
            this._persist();
            return this.rootCode();
        },

        // --- signing --------------------------------------------------------

        async signEvent(event) {
            const evt = Object.assign({ pubkey: this.pubkey }, event);
            if (this._sk) return NT().finalizeEvent(evt, this._sk);
            const signed = await window.nostr.signEvent(evt);
            if (!signed || !signed.sig) throw new Error(t('The extension refused to sign.'));
            return signed;
        },

        /// NIP-44 to a peer, done by whoever holds the key.
        async encryptTo(peerPubkey, plaintext) {
            if (this._sk) {
                const T = NT();
                return T.nip44.encrypt(plaintext, T.nip44.getConversationKey(this._sk, peerPubkey));
            }
            return window.nostr.nip44.encrypt(peerPubkey, plaintext);
        },

        async decryptFrom(peerPubkey, payload) {
            if (this._sk) {
                const T = NT();
                return T.nip44.decrypt(payload, T.nip44.getConversationKey(this._sk, peerPubkey));
            }
            return window.nostr.nip44.decrypt(peerPubkey, payload);
        },

        forget() {
            this.pubkey = null;
            this.method = null;
            this._sk = null;
            this._root = null;
            this._kem = null;
            this.rootLocked = false;
        }
    };

    window.NymbotIdentity = Identity;
    window.NymbotHex = { hex, unhex };
})();
