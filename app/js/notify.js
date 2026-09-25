(function () {
    'use strict';

    const API = window.NymbotApi;

    const PROACTIVE_MS = 10000;
    const ASKED_KEY = 'nymbot_reply_notify_asked';
    const CHAT_RE = /^[A-Za-z0-9_-]{1,64}$/;

    const b64ToBytes = (s) => {
        const p = String(s || '').replace(/-/g, '+').replace(/_/g, '/');
        const bin = atob(p + '==='.slice((p.length + 3) % 4));
        return Uint8Array.from(bin, (c) => c.charCodeAt(0));
    };

    const Notify = {
        enabled: () => false,
        titleOf: () => '',
        open: () => { },
        pending: new Map(),
        registered: new Set(),
        answered: new Set(),
        timers: new Map(),
        viewing: null,
        _key: undefined,
        _attached: false,

        supported() {
            return typeof window.Notification === 'function' && 'serviceWorker' in navigator;
        },

        pushSupported() {
            return this.supported() && 'PushManager' in window;
        },

        permission() {
            return this.supported() ? Notification.permission : 'denied';
        },

        allowed() {
            return this.enabled() && this.permission() === 'granted';
        },

        hidden() {
            return document.visibilityState === 'hidden';
        },

        attach(opts) {
            const o = opts || {};
            if (o.enabled) this.enabled = o.enabled;
            if (o.titleOf) this.titleOf = o.titleOf;
            if (o.open) this.open = o.open;
            if (this._attached || !this.supported()) return;
            this._attached = true;
            document.addEventListener('visibilitychange', () => {
                if (this.hidden()) this.registerAll();
            });
            window.addEventListener('pagehide', () => this.registerAll());
            navigator.serviceWorker.addEventListener('message', (e) => {
                const d = e.data || {};
                if (d.type === 'open-chat' && CHAT_RE.test(d.chat || '')) this.open(d.chat);
            });
            const m = /(?:^|[#&])chat=([A-Za-z0-9_-]{1,64})/.exec(location.hash || '');
            if (m) {
                history.replaceState(history.state, '', location.pathname + location.search);
                setTimeout(() => this.open(m[1]), 0);
            }
        },

        askOnce() {
            if (!this.supported() || !this.enabled() || this.permission() !== 'default') return;
            try {
                if (localStorage.getItem(ASKED_KEY)) return;
                localStorage.setItem(ASKED_KEY, '1');
            } catch (_) { return; }
            this.ask();
        },

        ask() {
            if (!this.supported()) return Promise.resolve(false);
            if (this.permission() !== 'default') return Promise.resolve(this.permission() === 'granted');
            try {
                const asked = Notification.requestPermission();
                return Promise.resolve(asked).then((p) => p === 'granted', () => false);
            } catch (_) {
                return Promise.resolve(false);
            }
        },

        settingChanged(on) {
            if (!this.supported()) return;
            if (!on) {
                for (const timer of this.timers.values()) clearTimeout(timer);
                this.timers.clear();
                return;
            }
            try { localStorage.setItem(ASKED_KEY, '1'); } catch (_) { }
            this.ask().then((ok) => { if (ok && this.hidden()) this.registerAll(); });
        },

        viewingChat(id) {
            this.viewing = id || null;
        },

        watch(convId, eventId, signer) {
            if (!this.supported() || !convId || !eventId) return;
            this.pending.set(convId, { eventId, signer: signer || null });
            clearTimeout(this.timers.get(convId));
            this.timers.delete(convId);
            if (!this.allowed() || !this.pushSupported()) return;
            if (this.hidden()) {
                this.register(convId);
                return;
            }
            this.timers.set(convId, setTimeout(() => {
                this.timers.delete(convId);
                const p = this.pending.get(convId);
                if (p && p.eventId === eventId && this.allowed()) this.register(convId);
            }, PROACTIVE_MS));
        },

        async settled(convId, opts) {
            if (!this.supported()) return;
            const o = opts || {};
            clearTimeout(this.timers.get(convId));
            this.timers.delete(convId);
            const p = this.pending.get(convId);
            if (!p) return;
            this.pending.delete(convId);
            const handled = this.registered.delete(p.eventId) | this.answered.delete(p.eventId);
            if (o.stopped || handled || !this.allowed()) return;
            if (!this.hidden() && this.viewing === convId) return;
            await this.show(convId, !!o.replied);
        },

        async show(convId, replied) {
            const title = String(this.titleOf(convId) || '').trim();
            const options = {
                body: title || t('Open the chat to read it.'),
                tag: 'reply-' + convId,
                data: { chat: convId },
                icon: '/app/icons/nymbot-192.png',
                badge: '/app/icons/nymbot-192.png'
            };
            const heading = replied ? t('Nymbot replied') : t('Nymbot could not finish that reply');
            try {
                const reg = await navigator.serviceWorker.getRegistration('/app/');
                if (reg && typeof reg.showNotification === 'function') {
                    await reg.showNotification(heading, options);
                    return true;
                }
            } catch (_) { }
            try {
                const n = new Notification(heading, options);
                n.onclick = () => { try { window.focus(); } catch (_) { } this.open(convId); n.close(); };
                return true;
            } catch (_) {
                return false;
            }
        },

        async serverKey() {
            if (this._key !== undefined) return this._key;
            try {
                const r = await API.pushKey();
                this._key = r && typeof r.key === 'string' && r.key ? r.key : null;
            } catch (_) {
                return null;
            }
            return this._key;
        },

        async subscription() {
            if (!this.pushSupported()) return null;
            const key = await this.serverKey();
            if (!key) return null;
            const reg = await navigator.serviceWorker.ready;
            let sub = await reg.pushManager.getSubscription();
            if (sub) {
                const held = sub.options && sub.options.applicationServerKey;
                if (held && btoa(String.fromCharCode(...new Uint8Array(held))) !== btoa(String.fromCharCode(...b64ToBytes(key)))) {
                    try { await sub.unsubscribe(); } catch (_) { }
                    sub = null;
                }
            }
            if (!sub) {
                sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(key) });
            }
            const json = sub && sub.toJSON ? sub.toJSON() : null;
            if (!json || !json.endpoint || !json.keys) return null;
            return { endpoint: json.endpoint, keys: { p256dh: json.keys.p256dh, auth: json.keys.auth } };
        },

        registerAll() {
            if (!this.allowed() || !this.pushSupported()) return;
            for (const convId of this.pending.keys()) this.register(convId);
        },

        async register(convId) {
            const p = this.pending.get(convId);
            if (!p || !CHAT_RE.test(convId) || this.registered.has(p.eventId) || p.registering) return;
            if (!this.allowed() || !this.pushSupported()) return;
            p.registering = true;
            let res = null;
            try {
                const subscription = await this.subscription();
                if (!subscription) return;
                res = await API.call('notify-turn', {
                    eventId: p.eventId,
                    env: 'web',
                    subscription,
                    chat: convId,
                    text: t('Your reply is ready').slice(0, 80)
                }, { signer: p.signer || undefined, timeout: 10000 });
            } catch (_) {
                res = null;
            } finally {
                p.registering = false;
            }
            const data = res && res.status ? res.data : null;
            const now = this.pending.get(convId);
            if (!data || !now || now.eventId !== p.eventId) return;
            if (data.done === true) {
                this.answered.add(p.eventId);
                if (this.hidden() || this.viewing !== convId) await this.show(convId, true);
                return;
            }
            if (data.ok === true) this.registered.add(p.eventId);
        }
    };

    window.NymbotNotify = Notify;
})();
