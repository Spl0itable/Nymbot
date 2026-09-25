(function () {
    'use strict';

    const CONTEXT = 'nym-google-backup';
    const ITERATIONS = 600000;
    const PIN = /^[0-9]{4,8}$/;
    const NAME = /^nym_bk_[0-9a-f-]{36}\.bin$/;
    const GSI = 'https://accounts.google.com/gsi/client';
    const DRIVE_SCOPE = 'https://www.googleapis.com/auth/drive.appdata';
    const SCOPE = 'openid ' + DRIVE_SCOPE;
    const FILES = 'https://www.googleapis.com/drive/v3/files';
    const UPLOAD = 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart';
    const USERINFO = 'https://www.googleapis.com/oauth2/v3/userinfo';
    const FAILS = 'keybackup_fails';
    const BASE_DELAY_MS = 1000;
    const MAX_DELAY_MS = 5 * 60 * 1000;

    const enc = new TextEncoder();
    const subtle = () => globalThis.crypto.subtle;
    const nip44 = () => globalThis.NostrTools.nip44.v2;

    function hex(bytes) {
        return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
    }

    function unhex(str) {
        const out = new Uint8Array(str.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16);
        return out;
    }

    function validPin(pin) {
        return typeof pin === 'string' && PIN.test(pin);
    }

    async function salt(accountId, context) {
        const key = await subtle().importKey('raw', enc.encode(context || CONTEXT),
            { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
        return new Uint8Array(await subtle().sign('HMAC', key, enc.encode(String(accountId))));
    }

    async function deriveKey(pin, accountId, context) {
        if (!validPin(pin)) throw new Error(t('The PIN must be 4 to 8 digits.'));
        if (!accountId) throw new Error(t('No account to derive the key for.'));
        const base = await subtle().importKey('raw', enc.encode(pin), 'PBKDF2', false, ['deriveBits']);
        const bits = await subtle().deriveBits(
            { name: 'PBKDF2', salt: await salt(accountId, context), iterations: ITERATIONS, hash: 'SHA-256' },
            base, 256);
        return new Uint8Array(bits);
    }

    function bundle(secretKey, pq) {
        const text = typeof secretKey === 'string' ? secretKey.toLowerCase() : hex(secretKey);
        if (!/^[0-9a-f]{64}$/.test(text)) throw new Error(t('That is not a private key.'));
        const out = { v: 1, sk: text };
        if (typeof pq === 'string' && pq.trim()) out.pq = pq.trim();
        return JSON.stringify(out);
    }

    function readBundle(text) {
        if (typeof text !== 'string') return null;
        if (/^[0-9a-f]{64}$/.test(text)) return { sk: unhex(text), pq: null, pqBad: false };
        let parsed;
        try { parsed = JSON.parse(text); } catch (_) { return null; }
        if (!parsed || typeof parsed !== 'object' || parsed.v !== 1) return null;
        if (typeof parsed.sk !== 'string' || !/^[0-9a-f]{64}$/.test(parsed.sk)) return null;
        const has = Object.prototype.hasOwnProperty.call(parsed, 'pq');
        const pq = has && typeof parsed.pq === 'string' && parsed.pq.trim() ? parsed.pq.trim() : null;
        return { sk: unhex(parsed.sk), pq, pqBad: has && !pq };
    }

    function encrypt(secretKey, key, pq, nonce) {
        const text = bundle(secretKey, pq);
        return nonce ? nip44().encrypt(text, key, nonce) : nip44().encrypt(text, key);
    }

    function open(payload, key) {
        let text;
        try { text = nip44().decrypt(String(payload || '').trim(), key); } catch (_) { return null; }
        return readBundle(text);
    }

    function decrypt(payload, key) {
        const opened = open(payload, key);
        return opened ? opened.sk : null;
    }

    function wipe(bytes) {
        if (bytes && typeof bytes.fill === 'function') bytes.fill(0);
    }

    function clientId() {
        const C = globalThis.NymbotConfig || {};
        return String(C.googleClientId || '').trim();
    }

    function storageKey() {
        const C = globalThis.NymbotConfig || {};
        return (C.storagePrefix || 'nymbot_') + FAILS;
    }

    function readFails() {
        try {
            const saved = JSON.parse(localStorage.getItem(storageKey()) || 'null');
            if (saved && typeof saved.n === 'number') return saved;
        } catch (_) { }
        return { n: 0, until: 0 };
    }

    function writeFails(value) {
        try {
            if (value.n) localStorage.setItem(storageKey(), JSON.stringify(value));
            else localStorage.removeItem(storageKey());
        } catch (_) { }
    }

    function waitMs() {
        return Math.max(0, readFails().until - Date.now());
    }

    function failed() {
        const n = readFails().n + 1;
        const delay = Math.min(MAX_DELAY_MS, BASE_DELAY_MS * Math.pow(2, n - 1));
        writeFails({ n, until: Date.now() + delay });
        return delay;
    }

    function succeeded() {
        writeFails({ n: 0, until: 0 });
    }

    let gsiLoading = null;
    let session = null;

    function loadGsi() {
        const g = globalThis.google;
        if (g && g.accounts && g.accounts.oauth2) return Promise.resolve();
        if (gsiLoading) return gsiLoading;
        gsiLoading = new Promise((resolve, reject) => {
            const script = document.createElement('script');
            script.src = GSI;
            script.async = true;
            script.onload = () => resolve();
            script.onerror = () => {
                gsiLoading = null;
                script.remove();
                reject(new Error(t('Could not reach Google. Check your connection and try again.')));
            };
            document.head.appendChild(script);
        });
        return gsiLoading;
    }

    function requestToken(prompt) {
        return new Promise((resolve, reject) => {
            const oauth2 = globalThis.google.accounts.oauth2;
            const client = oauth2.initTokenClient({
                client_id: clientId(),
                scope: SCOPE,
                prompt,
                callback: (resp) => {
                    if (!resp || resp.error || !resp.access_token) {
                        reject(new Error(t('Google did not sign you in.')));
                        return;
                    }
                    if (typeof oauth2.hasGrantedAllScopes === 'function'
                        && !oauth2.hasGrantedAllScopes(resp, DRIVE_SCOPE)) {
                        reject(new Error(t('Nymbot needs permission to keep its own backup file in your Google Drive. Try again and allow it.')));
                        return;
                    }
                    resolve(resp.access_token);
                },
                error_callback: () => reject(new Error(t('Google sign-in was closed before it finished.')))
            });
            client.requestAccessToken();
        });
    }

    async function authorized(url, init, retried) {
        if (!session) throw new Error(t('Not signed in to Google.'));
        const headers = Object.assign({}, (init && init.headers) || {}, { Authorization: 'Bearer ' + session.token });
        const resp = await fetch(url, Object.assign({}, init || {}, { headers }));
        if (resp.status === 401 && !retried) {
            session.token = await requestToken('');
            return authorized(url, init, true);
        }
        if (resp.status === 401) {
            session = null;
            throw new Error(t('Google no longer accepts this sign-in. Sign in with Google again.'));
        }
        if (!resp.ok) throw new Error(t('Google Drive answered with an error ({status}). Try again.', { status: resp.status }));
        return resp;
    }

    async function signIn() {
        if (!clientId()) throw new Error(t('Google backup is not set up in this app.'));
        await loadGsi();
        const token = await requestToken(session ? '' : 'select_account');
        session = { token, sub: null };
        const info = await (await authorized(USERINFO)).json();
        if (!info || !info.sub) {
            session = null;
            throw new Error(t('Google did not say which account this is.'));
        }
        session.sub = String(info.sub);
        return session.sub;
    }

    function signOut() {
        session = null;
    }

    async function list() {
        const q = encodeURIComponent("name contains 'nym_bk_'");
        const fields = encodeURIComponent('files(id,name,modifiedTime)');
        const url = FILES + '?spaces=appDataFolder&q=' + q + '&fields=' + fields + '&pageSize=100';
        const body = await (await authorized(url)).json();
        const files = (body && Array.isArray(body.files)) ? body.files : [];
        return files
            .filter((f) => f && f.id && NAME.test(f.name || ''))
            .sort((a, b) => String(b.modifiedTime || '').localeCompare(String(a.modifiedTime || '')));
    }

    async function download(id) {
        return (await authorized(FILES + '/' + encodeURIComponent(id) + '?alt=media')).text();
    }

    async function upload(payload) {
        const boundary = 'nym' + hex(globalThis.crypto.getRandomValues(new Uint8Array(12)));
        const name = 'nym_bk_' + globalThis.crypto.randomUUID() + '.bin';
        const body = '--' + boundary + '\r\n'
            + 'Content-Type: application/json; charset=UTF-8\r\n\r\n'
            + JSON.stringify({ name, parents: ['appDataFolder'] }) + '\r\n'
            + '--' + boundary + '\r\n'
            + 'Content-Type: application/octet-stream\r\n\r\n'
            + payload + '\r\n'
            + '--' + boundary + '--';
        const resp = await authorized(UPLOAD, {
            method: 'POST',
            headers: { 'Content-Type': 'multipart/related; boundary=' + boundary },
            body
        });
        const made = await resp.json();
        return { id: made && made.id, name };
    }

    async function remove(id) {
        await authorized(FILES + '/' + encodeURIComponent(id), { method: 'DELETE' });
    }

    const PASSKEY_FORMAT = 'nym-passkey-backup-v1';
    const PRF_CONTEXT = 'nym-key-backup-v1';
    const ENC_LABEL = 'nym-passkey-enc';
    const LOCATOR_LABEL = 'nym-passkey-locator';
    const BACKUP_KIND = 30078;
    const BACKUP_D = 'nym-key-backup';
    const DEFAULT_RELAYS = Object.freeze([
        'wss://relay.damus.io',
        'wss://nos.lol',
        'wss://relay.primal.net',
        'wss://relay.nostr.band',
        'wss://nostr.mom'
    ]);
    const CURVE_N = BigInt('0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141');
    const HEX_KEY = /^[0-9a-f]{64}$/;
    const NT = () => globalThis.NostrTools;

    function bytesOf(value) {
        if (value instanceof Uint8Array) return value;
        if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
        return new Uint8Array(value);
    }

    function random(n) {
        return globalThis.crypto.getRandomValues(new Uint8Array(n));
    }

    function secretHex(secretKey) {
        const text = typeof secretKey === 'string' ? secretKey.toLowerCase() : hex(secretKey);
        if (!HEX_KEY.test(text)) throw new Error(t('That is not a private key.'));
        return text;
    }

    async function prfSalt() {
        return new Uint8Array(await subtle().digest('SHA-256', enc.encode(PRF_CONTEXT)));
    }

    async function hkdf(ikm, label) {
        const base = await subtle().importKey('raw', bytesOf(ikm), 'HKDF', false, ['deriveBits']);
        const bits = await subtle().deriveBits(
            { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: enc.encode(label) }, base, 256);
        return new Uint8Array(bits);
    }

    async function passkeyKeys(prfOutput) {
        const encKey = await hkdf(prfOutput, ENC_LABEL);
        const locatorSecret = await hkdf(prfOutput, LOCATOR_LABEL);
        const n = BigInt('0x' + hex(locatorSecret));
        if (n === BigInt(0) || n >= CURVE_N) {
            wipe(encKey);
            wipe(locatorSecret);
            throw new Error(t('This passkey gave a key that can\'t be used. Try another passkey.'));
        }
        return { encKey, locatorSecret, locatorPubkey: NT().getPublicKey(locatorSecret) };
    }

    function locatorEvent(payload, locatorSecret, createdAt) {
        return NT().finalizeEvent({
            kind: BACKUP_KIND,
            created_at: createdAt || Math.floor(Date.now() / 1000),
            tags: [['d', BACKUP_D]],
            content: payload
        }, locatorSecret);
    }

    function isBackupEvent(ev, locatorPubkey) {
        if (!ev || ev.kind !== BACKUP_KIND || ev.pubkey !== locatorPubkey || typeof ev.content !== 'string') return false;
        const tags = Array.isArray(ev.tags) ? ev.tags : [];
        if (!tags.some((tag) => Array.isArray(tag) && tag[0] === 'd' && tag[1] === BACKUP_D)) return false;
        const plain = {
            id: ev.id, pubkey: ev.pubkey, created_at: ev.created_at, kind: ev.kind,
            tags: ev.tags, content: ev.content, sig: ev.sig
        };
        try { return NT().verifyEvent(plain) === true; } catch (_) { return false; }
    }

    function newestBackup(events, locatorPubkey) {
        return (events || [])
            .filter((ev) => isBackupEvent(ev, locatorPubkey))
            .sort((a, b) => (b.created_at - a.created_at) || String(a.id).localeCompare(String(b.id)))[0] || null;
    }

    function backupRelays() {
        const C = globalThis.NymbotConfig || {};
        return Array.from(new Set([].concat(Array.isArray(C.relays) ? C.relays : [], DEFAULT_RELAYS)));
    }

    function blobFor(secretKey, pq) {
        return enc.encode(bundle(secretHex(secretKey), pq));
    }

    function readBlob(blob) {
        if (!blob) return null;
        const raw = bytesOf(blob);
        let text = null;
        try { text = new TextDecoder().decode(raw); } catch (_) { text = null; }
        wipe(raw);
        return readBundle(text);
    }

    function shortNpub(pubkey) {
        const npub = NT().nip19.npubEncode(pubkey);
        return npub.slice(0, 12) + '…' + npub.slice(-6);
    }

    function passkeyAvailable() {
        const V = globalThis.NymbotVault;
        if (V && typeof V.webauthnAvailable === 'function') return V.webauthnAvailable();
        const nav = globalThis.navigator;
        return !!(globalThis.PublicKeyCredential && nav && nav.credentials && nav.credentials.create && nav.credentials.get);
    }

    function passkeyError(e) {
        const V = globalThis.NymbotVault;
        const error = V && typeof V.passkeyError === 'function' ? V.passkeyError(e) : new Error(t('Your passkey could not be used.'));
        error.canceled = !!(e && e.name === 'NotAllowedError');
        return error;
    }

    function extensionResults(cred) {
        try { return (cred && cred.getClientExtensionResults && cred.getClientExtensionResults()) || {}; } catch (_) { return {}; }
    }

    function prfResult(cred) {
        const V = globalThis.NymbotVault;
        if (V && typeof V.prfResult === 'function') return V.prfResult(cred);
        const prf = extensionResults(cred).prf;
        return prf && prf.results && prf.results.first ? prf.results.first : null;
    }

    async function webauthn(kind, publicKey) {
        let cred;
        try { cred = await globalThis.navigator.credentials[kind]({ publicKey }); } catch (e) { throw passkeyError(e); }
        if (!cred) throw passkeyError(null);
        return cred;
    }

    function assertion(id, extensions) {
        return webauthn('get', {
            challenge: random(32),
            rpId: location.hostname,
            allowCredentials: [{ type: 'public-key', id }],
            userVerification: 'required',
            timeout: 60000,
            extensions
        });
    }

    function relays() {
        const R = globalThis.NymbotRelays;
        if (!R) throw new Error(t('Could not reach the relays. Check your connection and try again.'));
        return R;
    }

    async function publishWithPrf(secretKey, prfOutput, pq) {
        const keys = await passkeyKeys(prfOutput);
        try {
            const event = locatorEvent(encrypt(secretKey, keys.encKey, pq), keys.locatorSecret);
            const accepted = await relays().publishTo(backupRelays(), event, 8000);
            if (!accepted) throw new Error(t('No relay accepted the encrypted copy. Check your connection and try again.'));
            return { via: 'prf', relays: accepted };
        } finally {
            wipe(keys.encKey);
            wipe(keys.locatorSecret);
        }
    }

    async function passkeyBackup(secretKey, pq, progress) {
        if (!passkeyAvailable()) throw new Error(t('Passkeys are not available in this browser.'));
        const step = typeof progress === 'function' ? progress : () => { };
        const secret = typeof secretKey === 'string' ? unhex(secretHex(secretKey)) : secretKey;
        const name = 'Nymbot key backup · ' + shortNpub(NT().getPublicKey(secret));
        const salt = await prfSalt();
        const made = await webauthn('create', {
            challenge: random(32),
            rp: { id: location.hostname, name: 'Nymbot' },
            user: { id: random(16), name, displayName: name },
            pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
            authenticatorSelection: { residentKey: 'required', requireResidentKey: true, userVerification: 'required' },
            timeout: 60000,
            extensions: { prf: { eval: { first: salt } }, largeBlob: { support: 'preferred' } }
        });
        const ext = extensionResults(made);
        const id = new Uint8Array(made.rawId);
        let output = prfResult(made);
        if (!output && ext.prf && ext.prf.enabled === true) {
            step(t('Confirm with your passkey once more…'));
            output = prfResult(await assertion(id, { prf: { eval: { first: salt } } }));
        }
        if (output) {
            const prf = bytesOf(output);
            step(t('Saving the encrypted copy to Nostr relays…'));
            try { return await publishWithPrf(secret, prf, pq); } finally { wipe(prf); }
        }
        if (ext.largeBlob && ext.largeBlob.supported === true) {
            const blob = blobFor(secret, pq);
            step(t('Confirm with your passkey once more to save the backup in it…'));
            try {
                const written = extensionResults(await assertion(id, { largeBlob: { write: blob } })).largeBlob;
                if (!written || written.written !== true) {
                    throw new Error(t('The passkey did not save the backup. Try again, or use another passkey provider.'));
                }
                return { via: 'largeBlob' };
            } finally {
                wipe(blob);
            }
        }
        throw new Error(clientId()
            ? t('This passkey provider can\'t hold a key backup, so nothing was saved. You can delete the passkey it just made. Try another passkey provider, or Continue with Google.')
            : t('This passkey provider can\'t hold a key backup, so nothing was saved. You can delete the passkey it just made. Try another passkey provider, such as a password manager or your phone.'));
    }

    async function passkeyRestore(progress) {
        if (!passkeyAvailable()) throw new Error(t('Passkeys are not available in this browser.'));
        const step = typeof progress === 'function' ? progress : () => { };
        const salt = await prfSalt();
        const got = await webauthn('get', {
            challenge: random(32),
            rpId: location.hostname,
            userVerification: 'required',
            timeout: 60000,
            extensions: { prf: { eval: { first: salt } }, largeBlob: { read: true } }
        });
        const ext = extensionResults(got);
        const output = prfResult(got);
        let found = null;
        if (output) {
            const prf = bytesOf(output);
            let keys;
            try { keys = await passkeyKeys(prf); } finally { wipe(prf); }
            try {
                step(t('Looking for your encrypted key on Nostr relays…'));
                const events = await relays().fetchEach(backupRelays(),
                    { kinds: [BACKUP_KIND], authors: [keys.locatorPubkey], '#d': [BACKUP_D] }, 8000);
                const newest = newestBackup(events, keys.locatorPubkey);
                if (newest) found = open(newest.content, keys.encKey);
            } finally {
                wipe(keys.encKey);
                wipe(keys.locatorSecret);
            }
        }
        if (!found && ext.largeBlob && ext.largeBlob.blob) found = readBlob(ext.largeBlob.blob);
        return found;
    }

    const passkey = {
        FORMAT: PASSKEY_FORMAT,
        KIND: BACKUP_KIND,
        D_TAG: BACKUP_D,
        DEFAULT_RELAYS,
        available: passkeyAvailable,
        prfSalt,
        hkdf,
        keys: passkeyKeys,
        event: locatorEvent,
        isBackupEvent,
        newest: newestBackup,
        relays: backupRelays,
        blob: blobFor,
        readBlob,
        backup: passkeyBackup,
        restore: passkeyRestore
    };

    globalThis.NymbotKeyBackup = {
        CONTEXT,
        ITERATIONS,
        get enabled() { return !!clientId(); },
        get accountId() { return session ? session.sub : null; },
        validPin,
        salt,
        deriveKey,
        bundle,
        readBundle,
        encrypt,
        open,
        decrypt,
        wipe,
        hex,
        waitMs,
        failed,
        succeeded,
        signIn,
        signOut,
        list,
        download,
        upload,
        remove,
        passkey
    };
})();
