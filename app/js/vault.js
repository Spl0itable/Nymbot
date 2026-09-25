(function () {
    'use strict';

    const P = window.NymbotConfig.storagePrefix;
    const NAMES = ['identity', 'signer', 'anon', 'repos', 'connectors', 'shares'];
    const PREFIX = 'enc:v1:';
    const CHECK = 'nymbot-vault-ok';
    const ROUNDS = 310000;
    const MIN_LENGTH = 4;
    const ENABLED = P + 'vault_enabled';
    const SALT = P + 'vault_salt';
    const CHECK_KEY = P + 'vault_check';
    const METHOD = P + 'vault_method';
    const CRED = P + 'vault_cred';
    const PASSKEYS = ['passkey', 'biometric'];
    const INFO = 'nym-vault';

    const enc = new TextEncoder();
    const dec = new TextDecoder();
    const $ = (id) => document.getElementById(id);

    function b64(bytes) {
        let s = '';
        for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return btoa(s);
    }

    function unb64(str) {
        const s = atob(str);
        const out = new Uint8Array(s.length);
        for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
        return out;
    }

    function getRaw(key) {
        try { return localStorage.getItem(key); } catch (_) { return null; }
    }

    function sealed(value) {
        return typeof value === 'string' && value.startsWith(PREFIX);
    }

    async function derive(passphrase, salt) {
        const base = await crypto.subtle.importKey('raw', enc.encode(passphrase), 'PBKDF2', false, ['deriveKey']);
        return crypto.subtle.deriveKey(
            { name: 'PBKDF2', salt, iterations: ROUNDS, hash: 'SHA-256' },
            base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    }

    async function seal(key, text) {
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(text));
        return PREFIX + b64(iv) + ':' + b64(new Uint8Array(ct));
    }

    async function open(key, blob) {
        const p = String(blob).split(':');
        if (p.length !== 4 || p[0] !== 'enc' || p[1] !== 'v1') throw new Error('bad blob');
        const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(p[2]) }, key, unb64(p[3]));
        return dec.decode(pt);
    }

    function failed() {
        return new Error(t('Could not set up encryption. Nothing was changed.'));
    }

    function random(n) {
        return crypto.getRandomValues(new Uint8Array(n));
    }

    async function expand(prf) {
        const base = await crypto.subtle.importKey('raw', new Uint8Array(prf), 'HKDF', false, ['deriveKey']);
        return crypto.subtle.deriveKey(
            { name: 'HKDF', salt: new Uint8Array(0), info: enc.encode(INFO), hash: 'SHA-256' },
            base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    }

    function prfOutput(cred) {
        const ext = cred && cred.getClientExtensionResults ? cred.getClientExtensionResults() : {};
        return ext && ext.prf && ext.prf.results && ext.prf.results.first ? ext.prf.results.first : null;
    }

    function noPrf() {
        return new Error(t('This passkey can\'t unlock an encrypted identity because it doesn\'t support the WebAuthn PRF extension. Nothing was changed. Try a different passkey or security key, or use a passphrase.'));
    }

    function authFailed(e) {
        if (e && e.name === 'NotAllowedError') return new Error(t('The passkey request was canceled or timed out.'));
        if (e && e.name === 'SecurityError') return new Error(t('Passkeys can\'t be used on this address.'));
        return new Error(t('Your passkey could not be used.'));
    }

    const Vault = {
        _key: null,
        _mem: null,
        _chain: Promise.resolve(),
        _form: null,

        enabled() { return getRaw(ENABLED) === '1'; },
        locked() { return this.enabled() && !this._key; },
        covers(name) { return NAMES.includes(name) && this.enabled(); },

        method() {
            const m = getRaw(METHOD);
            return PASSKEYS.includes(m) ? m : 'passphrase';
        },

        _isWebAuthn(method) { return PASSKEYS.includes(method); },

        prfResult(cred) { return prfOutput(cred); },

        passkeyError(e) { return authFailed(e); },

        webauthnAvailable() {
            return !!(window.PublicKeyCredential && navigator.credentials &&
                navigator.credentials.create && navigator.credentials.get);
        },

        async biometricAvailable() {
            try {
                if (!this.webauthnAvailable()) return false;
                if (!PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable) return false;
                return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
            } catch (_) { return false; }
        },

        _biometricRedundantWithPasskey() {
            try {
                const ua = navigator.userAgent || '';
                const iOS = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
                const macSafari = /Macintosh/.test(ua) && /Safari/.test(ua) && !/Chrome|Chromium|Edg|OPR/.test(ua);
                return iOS || macSafari;
            } catch (_) { return false; }
        },

        async methods() {
            const out = ['passphrase'];
            if (!this.webauthnAvailable()) return out;
            out.push('passkey');
            const bio = (await this.biometricAvailable()) && !this._biometricRedundantWithPasskey();
            if (bio || (this.enabled() && this.method() === 'biometric')) out.push('biometric');
            return out;
        },

        async _webauthnDeriveKey(credId, salt) {
            let got;
            try {
                got = await navigator.credentials.get({
                    publicKey: {
                        challenge: random(32),
                        rpId: location.hostname,
                        allowCredentials: [{ id: unb64(credId), type: 'public-key' }],
                        userVerification: 'required',
                        timeout: 60000,
                        extensions: { prf: { eval: { first: salt } } }
                    }
                });
            } catch (e) { throw authFailed(e); }
            if (!got) throw authFailed(null);
            const out = prfOutput(got);
            if (!out) throw noPrf();
            return expand(out);
        },

        async _webauthnEnroll(salt, platformOnly) {
            if (!this.webauthnAvailable()) throw new Error(t('Passkeys are not available in this browser.'));
            const selection = { userVerification: 'required', residentKey: 'required' };
            if (platformOnly) selection.authenticatorAttachment = 'platform';
            let made;
            try {
                made = await navigator.credentials.create({
                    publicKey: {
                        challenge: random(32),
                        rp: { name: 'Nymbot', id: location.hostname },
                        user: { id: random(16), name: 'Nymbot', displayName: 'Nymbot' },
                        pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
                        authenticatorSelection: selection,
                        timeout: 60000,
                        extensions: { prf: { eval: { first: salt } } }
                    }
                });
            } catch (e) { throw authFailed(e); }
            if (!made) throw authFailed(null);
            const ext = made.getClientExtensionResults ? made.getClientExtensionResults() : {};
            if (ext && ext.prf && ext.prf.enabled === false) throw noPrf();
            const cred = b64(new Uint8Array(made.rawId));
            const early = prfOutput(made);
            const key = await this._webauthnDeriveKey(cred, salt);
            const again = early ? await expand(early) : await this._webauthnDeriveKey(cred, salt);
            return { cred, key, again };
        },

        async _newKey(method, passphrase) {
            const salt = random(16);
            let key;
            let again;
            let cred = null;
            if (this._isWebAuthn(method)) {
                ({ key, again, cred } = await this._webauthnEnroll(salt, method === 'biometric'));
            } else {
                if (String(passphrase || '').length < MIN_LENGTH) throw new Error(t('Use at least 4 characters.'));
                key = await derive(String(passphrase), salt);
                again = key;
            }
            const check = await seal(key, CHECK);
            let back = null;
            try { back = await open(again, check); } catch (_) { }
            if (back !== CHECK) throw failed();
            return {
                key,
                meta: {
                    [SALT]: b64(salt),
                    [CHECK_KEY]: check,
                    [METHOD]: this._isWebAuthn(method) ? method : null,
                    [CRED]: cred
                }
            };
        },

        read(name, fallback) {
            if (!this._mem || !this._mem.has(name)) return fallback;
            try { return JSON.parse(this._mem.get(name)); } catch (_) { return fallback; }
        },

        write(name, text) {
            const key = this._key;
            if (!key || !this._mem) return false;
            if (this._mem.get(name) === text) return 'same';
            this._mem.set(name, text);
            this._chain = this._chain.then(async () => {
                const box = await seal(key, text);
                if (this._key !== key || !this._mem || this._mem.get(name) !== text) return;
                localStorage.setItem(P + name, box);
            }).catch(() => { });
            return true;
        },

        drop(name) {
            if (this._mem) this._mem.delete(name);
        },

        clear() {
            this._key = null;
            this._mem = null;
        },

        settled() { return this._chain; },

        async _verified(passphrase) {
            const salt = getRaw(SALT);
            const check = getRaw(CHECK_KEY);
            if (!salt || !check) return null;
            let key;
            if (this._isWebAuthn(this.method())) {
                const cred = getRaw(CRED);
                if (!cred) return null;
                key = await this._webauthnDeriveKey(cred, unb64(salt));
            } else {
                if (!passphrase) return null;
                try { key = await derive(String(passphrase), unb64(salt)); } catch (_) { return null; }
            }
            try { return (await open(key, check)) === CHECK ? key : null; } catch (_) { return null; }
        },

        async check(passphrase) {
            if (!this.enabled()) return false;
            return !!(await this._verified(passphrase));
        },

        async _plain(key) {
            const out = new Map();
            for (const name of NAMES) {
                if (this._mem && this._mem.has(name)) {
                    out.set(name, this._mem.get(name));
                    continue;
                }
                const value = getRaw(P + name);
                if (value == null) continue;
                out.set(name, sealed(value) ? await open(key, value) : value);
            }
            return out;
        },

        async _sealAll(key, plain) {
            const boxes = new Map();
            for (const [name, value] of plain) {
                const box = await seal(key, value);
                if ((await open(key, box)) !== value) throw failed();
                boxes.set(name, box);
            }
            return boxes;
        },

        _commit(meta, boxes) {
            const before = new Map();
            for (const k of [ENABLED, SALT, CHECK_KEY, METHOD, CRED]) before.set(k, getRaw(k));
            for (const name of boxes.keys()) before.set(P + name, getRaw(P + name));
            try {
                for (const [k, v] of Object.entries(meta)) {
                    if (v == null) localStorage.removeItem(k);
                    else localStorage.setItem(k, v);
                }
                for (const [name, value] of boxes) {
                    localStorage.setItem(P + name, value);
                    if (getRaw(P + name) !== value) throw failed();
                }
            } catch (e) {
                for (const [k, v] of before) {
                    try {
                        if (v == null) localStorage.removeItem(k);
                        else localStorage.setItem(k, v);
                    } catch (_) { }
                }
                throw e;
            }
        },

        async unlock(passphrase) {
            if (!this.enabled()) return true;
            const key = await this._verified(passphrase);
            if (!key) return false;
            let plain;
            try {
                this._mem = null;
                plain = await this._plain(key);
            } catch (_) {
                throw new Error(t('Your saved identity could not be decrypted.'));
            }
            this._key = key;
            this._mem = plain;
            for (const name of NAMES) {
                const value = getRaw(P + name);
                if (value != null && !sealed(value)) this._reseal(name, value);
            }
            return true;
        },

        _reseal(name, value) {
            const key = this._key;
            this._chain = this._chain.then(async () => {
                const box = await seal(key, value);
                if (this._key === key && this._mem && this._mem.get(name) === value && getRaw(P + name) === value) {
                    localStorage.setItem(P + name, box);
                }
            }).catch(() => { });
        },

        async enable(passphrase, method) {
            if (this.enabled()) throw new Error(t('Identity encryption is already on.'));
            const to = this._isWebAuthn(method) ? method : 'passphrase';
            if (to === 'passphrase' && String(passphrase || '').length < MIN_LENGTH) throw new Error(t('Use at least 4 characters.'));
            const fresh = await this._newKey(to, passphrase);
            const key = fresh.key;
            for (let attempt = 0; attempt < 5; attempt++) {
                const plain = await this._plain(key);
                const boxes = await this._sealAll(key, plain);
                if (NAMES.some(n => getRaw(P + n) !== (plain.has(n) ? plain.get(n) : null))) continue;
                this._commit(Object.assign({}, fresh.meta, { [ENABLED]: '1' }), boxes);
                this._key = key;
                this._mem = plain;
                return;
            }
            throw failed();
        },

        async disable(passphrase) {
            if (!this.enabled()) return true;
            const key = await this._verified(passphrase);
            if (!key) return false;
            await this._chain;
            const plain = await this._plain(key);
            this._commit({ [ENABLED]: null, [SALT]: null, [CHECK_KEY]: null, [METHOD]: null, [CRED]: null }, plain);
            this.clear();
            return true;
        },

        _moved(plain) {
            if (!this._mem) return false;
            return NAMES.some((n) => (this._mem.has(n) ? this._mem.get(n) : null) !== (plain.has(n) ? plain.get(n) : null));
        },

        async change(current, next, method) {
            if (!this.enabled()) throw new Error(t('Identity encryption is off.'));
            const to = this._isWebAuthn(method) ? method : 'passphrase';
            if (to === 'passphrase' && String(next || '').length < MIN_LENGTH) throw new Error(t('Use at least 4 characters.'));
            const key = await this._verified(current);
            if (!key) return false;
            const fresh = await this._newKey(to, next);
            for (let attempt = 0; attempt < 5; attempt++) {
                await this._chain;
                const plain = await this._plain(key);
                const boxes = await this._sealAll(fresh.key, plain);
                if (this._moved(plain)) continue;
                this._commit(fresh.meta, boxes);
                this._key = fresh.key;
                this._mem = plain;
                return true;
            }
            throw failed();
        },

        gate() {
            if (!this.locked()) return Promise.resolve(true);
            const pk = this._gateMode();
            $('vaultGate').hidden = false;
            $('vaultGatePass').value = '';
            $(pk ? 'vaultGateUnlock' : 'vaultGatePass').focus();
            return new Promise((resolve) => { this._gateDone = resolve; });
        },

        _gateMode() {
            const m = this.method();
            const pk = this._isWebAuthn(m);
            $('vaultGatePassRow').hidden = pk;
            $('vaultGateLede').textContent = {
                passphrase: t('Your Nymbot identity is encrypted on this device. Enter your passphrase to unlock it.'),
                passkey: t('Your Nymbot identity is encrypted on this device. Use your passkey to unlock it.'),
                biometric: t('Your Nymbot identity is encrypted on this device. Use your fingerprint, face or device unlock to open it.')
            }[m];
            $('vaultGateUnlock').textContent = {
                passphrase: t('Unlock'),
                passkey: t('Unlock with passkey'),
                biometric: t('Unlock with biometrics')
            }[m];
            $('vaultGateForget').textContent = pk ? t('Lost your passkey?') : t('Forgot your passphrase?');
            return pk;
        },

        async _gateUnlock() {
            if (this._unlocking) return;
            const pk = this._isWebAuthn(this.method());
            const input = $('vaultGatePass');
            const error = $('vaultGateError');
            const busy = $('vaultGateBusy');
            if (!pk && !input.value) {
                error.textContent = t('Enter your passphrase.');
                error.hidden = false;
                return;
            }
            error.hidden = true;
            busy.hidden = false;
            this._unlocking = true;
            let ok = false;
            let message = pk ? t('That passkey did not unlock this identity. Try again.') : t('Wrong passphrase. Try again.');
            try { ok = await this.unlock(pk ? null : input.value); } catch (e) { message = e.message; }
            this._unlocking = false;
            busy.hidden = true;
            if (!ok) {
                input.value = '';
                if (!pk) input.focus();
                error.textContent = message;
                error.hidden = false;
                return;
            }
            $('vaultGate').hidden = true;
            const done = this._gateDone;
            this._gateDone = null;
            if (done) done(true);
        },

        async _gateForget(ui) {
            const yes = await ui.ask({
                title: t('Forget this identity?'),
                body: this._isWebAuthn(this.method())
                    ? t('Without your passkey, the encrypted key on this device cannot be recovered. Starting over permanently deletes it and everything else Nymbot keeps on this device. If you saved your nsec somewhere else, you can sign back in with it afterwards.')
                    : t('Without the passphrase, the encrypted key on this device cannot be recovered. Starting over permanently deletes it and everything else Nymbot keeps on this device. If you saved your nsec somewhere else, you can sign back in with it afterwards.'),
                confirm: t('Delete and start over'),
                danger: true
            });
            if (!yes) return;
            await Promise.race([
                Promise.all([
                    window.NymbotDocs ? window.NymbotDocs.wipe().catch(() => { }) : null,
                    ui.clearCaches()
                ]),
                new Promise((done) => setTimeout(done, 3000))
            ]);
            this.clear();
            window.NymbotStore.wipe();
            location.reload();
        },

        render() {
            const on = this.enabled();
            const m = this.method();
            $('vaultState').textContent = !on
                ? t('Off. Add a passphrase or passkey so your saved key can\'t be read from this device without unlocking.')
                : {
                    passphrase: t('On. Your saved key is encrypted, and Nymbot asks for your passphrase each time it opens.'),
                    passkey: t('On. Your saved key is encrypted, and Nymbot asks for your passkey each time it opens.'),
                    biometric: t('On. Your saved key is encrypted, and Nymbot asks for your fingerprint, face or device unlock each time it opens.')
                }[m];
            $('vaultChange').textContent = this.webauthnAvailable() || m !== 'passphrase'
                ? t('Change unlock method…')
                : t('Change passphrase…');
            $('vaultEnable').hidden = on;
            $('vaultChange').hidden = !on;
            $('vaultDisable').hidden = !on;
        },

        _chosen() {
            return $('vaultMethodRow').hidden ? 'passphrase' : $('vaultMethod').value;
        },

        _syncMethod() {
            const action = this._form;
            const to = this._chosen();
            const pk = this._isWebAuthn(to);
            $('vaultNextRow').hidden = action === 'disable' || pk;
            const hint = $('vaultMethodHint');
            hint.hidden = action === 'disable' || !pk;
            hint.textContent = to === 'biometric'
                ? t('You\'ll be asked to confirm with this device\'s fingerprint, face or device unlock a few times. It has to support the WebAuthn PRF extension; if it doesn\'t, nothing changes and you can use a passphrase instead.')
                : t('You\'ll be asked to create a passkey and then use it a few times. It can live on this device, in your password manager or on a security key, and it has to support the WebAuthn PRF extension; if it doesn\'t, nothing changes and you can use a passphrase instead.');
            $('vaultNextLabel').textContent = action === 'change' && this.method() === 'passphrase' ? t('New passphrase') : t('Passphrase');
        },

        async openForm(ui, action) {
            this._form = action;
            const from = this.method();
            const pkNow = action !== 'enable' && this._isWebAuthn(from);
            const methods = action === 'disable' ? ['passphrase'] : await this.methods();
            if (this._form !== action) return;
            const asksCurrent = action !== 'enable' && !pkNow;
            const select = $('vaultMethod');
            const names = {
                passphrase: t('Passphrase'),
                passkey: t('Passkey (this device, a password manager or a security key)'),
                biometric: t('Biometrics (Face ID, Touch ID, Windows Hello)')
            };
            select.textContent = '';
            for (const m of methods) {
                const opt = document.createElement('option');
                opt.value = m;
                opt.textContent = names[m];
                select.appendChild(opt);
            }
            select.value = action === 'change' && methods.includes(from) ? from : 'passphrase';
            $('vaultMethodRow').hidden = methods.length < 2;
            const renames = action === 'change' && (methods.length > 1 || pkNow);
            $('vaultTitle').textContent = {
                enable: t('Encrypt your identity'),
                change: renames ? t('Change unlock method') : t('Change passphrase'),
                disable: t('Turn off identity encryption')
            }[action];
            $('vaultLede').textContent = {
                enable: methods.length > 1
                    ? t('Protect the key saved on this device with a passphrase or a passkey. Nymbot will ask for it every time it opens, and nothing syncs or sends until it is unlocked. If you lose it, the key on this device cannot be recovered, so keep your nsec saved somewhere safe.')
                    : t('Protect the key saved on this device with a passphrase. Nymbot will ask for it every time it opens, and nothing syncs or sends until it is unlocked. If you forget it, the key on this device cannot be recovered, so keep your nsec saved somewhere safe.'),
                change: pkNow
                    ? t('Choose how Nymbot unlocks from now on. You\'ll confirm with your current passkey first.')
                    : (renames ? t('Enter your current passphrase, then choose how Nymbot unlocks from now on.') : t('Enter your current passphrase, then choose a new one.')),
                disable: pkNow
                    ? t('Confirm with your passkey to turn off identity encryption. Your key will be kept on this device without a passphrase again.')
                    : t('Enter your passphrase to turn off identity encryption. Your key will be kept on this device without a passphrase again.')
            }[action];
            $('vaultCurrentRow').hidden = !asksCurrent;
            $('vaultCurrentLabel').textContent = action === 'change' ? t('Current passphrase') : t('Passphrase');
            for (const id of ['vaultCurrent', 'vaultNext', 'vaultConfirm']) $(id).value = '';
            this._syncMethod();
            const submit = $('vaultSubmit');
            submit.textContent = { enable: t('Turn on'), change: t('Change'), disable: t('Turn off') }[action];
            submit.classList.toggle('btn-danger', action === 'disable');
            submit.classList.toggle('btn-primary', action !== 'disable');
            submit.disabled = false;
            ui.modalStatus('vaultStatus', '');
            ui.openModal('modalVault');
            if (asksCurrent) $('vaultCurrent').focus();
            else if (!$('vaultNextRow').hidden) $('vaultNext').focus();
            else submit.focus();
        },

        async submitForm(ui) {
            const action = this._form;
            if (!action) return;
            const from = this.method();
            const to = this._chosen();
            const current = $('vaultCurrent').value;
            const next = $('vaultNext').value;
            if (action !== 'enable' && from === 'passphrase' && !current) {
                ui.modalStatus('vaultStatus', t('Enter your passphrase.'), 'warn');
                return;
            }
            if (action !== 'disable' && to === 'passphrase') {
                if (next.length < MIN_LENGTH) {
                    ui.modalStatus('vaultStatus', t('Use at least 4 characters.'), 'warn');
                    return;
                }
                if (next !== $('vaultConfirm').value) {
                    ui.modalStatus('vaultStatus', t('The two entries do not match.'), 'warn');
                    return;
                }
            }
            const prompts = (action !== 'enable' && this._isWebAuthn(from)) || (action !== 'disable' && this._isWebAuthn(to));
            const submit = $('vaultSubmit');
            submit.disabled = true;
            ui.modalStatus('vaultStatus', prompts ? t('Follow the prompts from your device…') : t('Working…'));
            let ok = true;
            try {
                if (action === 'enable') await this.enable(next, to);
                else if (action === 'change') ok = await this.change(current, next, to);
                else ok = await this.disable(current);
            } catch (e) {
                submit.disabled = false;
                ui.modalStatus('vaultStatus', e.message, 'warn');
                return;
            }
            submit.disabled = false;
            if (!ok) {
                if (from === 'passphrase') {
                    $('vaultCurrent').value = '';
                    $('vaultCurrent').focus();
                    ui.modalStatus('vaultStatus', t('Wrong passphrase.'), 'warn');
                } else {
                    ui.modalStatus('vaultStatus', t('That passkey did not unlock this identity.'), 'warn');
                }
                return;
            }
            this._form = null;
            ui.openSettings();
            ui.toast(action === 'enable' ? {
                passphrase: t('Identity encryption is on. You\'ll be asked for your passphrase next time Nymbot opens.'),
                passkey: t('Identity encryption is on. You\'ll be asked for your passkey next time Nymbot opens.'),
                biometric: t('Identity encryption is on. You\'ll be asked for your fingerprint, face or device unlock next time Nymbot opens.')
            }[to] : action === 'change'
                ? (from === 'passphrase' && to === 'passphrase' ? t('Passphrase changed.') : t('Unlock method changed.'))
                : t('Identity encryption is off.'));
        },

        handlers(ui) {
            if (!this._keys) {
                this._keys = true;
                const onEnter = (id, fn) => $(id).addEventListener('keydown', (e) => {
                    if (e.key === 'Enter') { e.preventDefault(); fn(); }
                });
                onEnter('vaultGatePass', () => this._gateUnlock());
                onEnter('vaultCurrent', () => {
                    if (this._form === 'disable' || $('vaultNextRow').hidden) this.submitForm(ui);
                    else $('vaultNext').focus();
                });
                onEnter('vaultNext', () => $('vaultConfirm').focus());
                onEnter('vaultConfirm', () => this.submitForm(ui));
                $('vaultMethod').addEventListener('change', () => this._syncMethod());
            }
            return {
                'vault-unlock': () => this._gateUnlock(),
                'vault-forget': () => this._gateForget(ui),
                'vault-enable': () => this.openForm(ui, 'enable'),
                'vault-change': () => this.openForm(ui, 'change'),
                'vault-disable': () => this.openForm(ui, 'disable'),
                'vault-submit': () => this.submitForm(ui),
                'vault-back': () => { this._form = null; ui.openSettings(); }
            };
        }
    };

    window.NymbotVault = Vault;
})();
