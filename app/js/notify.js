(function () {
    'use strict';

    const API = window.NymbotApi;

    const PROACTIVE_MS = 10000;
    const ASKED_KEY = 'nymbot_reply_notify_asked';
    const CHAT_RE = /^[A-Za-z0-9_-]{1,64}$/;
    const ASKED_RE = /^[0-9a-f]{64}$/;
    const TEXT_CACHE = 'nymbot-notify';
    const TEXT_KEY = '/app/notify-text.json';
    const TEXT_MAX = 80;
    const PREF_DEFAULTS = { done: true, failed: true, waiting: true, paused: true, schedule: true, pr: true, minSeconds: 0 };
    const MIN_CHOICES = [0, 30, 120];
    const PUSH_STATES = ['done', 'failed', 'stopped', 'approval', 'question', 'expired', 'paused', 'pr', 'disabled', 'ci-failed', 'review'];
    const STATE_PREFS = {
        done: ['done'],
        failed: ['failed'],
        stopped: ['failed'],
        disabled: ['failed'],
        approval: ['waiting'],
        question: ['waiting', 'question'],
        expired: ['failed'],
        paused: ['paused'],
        pr: ['pr'],
        'ci-failed': ['pr'],
        review: ['pr']
    };

    const b64ToBytes = (s) => {
        const p = String(s || '').replace(/-/g, '+').replace(/_/g, '/');
        const bin = atob(p + '==='.slice((p.length + 3) % 4));
        return Uint8Array.from(bin, (c) => c.charCodeAt(0));
    };

    const Notify = {
        enabled: () => false,
        prefsOf: () => null,
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

        prefs() {
            const held = this.prefsOf();
            const out = Object.assign({}, PREF_DEFAULTS, held && typeof held === 'object' ? held : {});
            out.minSeconds = MIN_CHOICES.includes(Number(out.minSeconds)) ? Number(out.minSeconds) : 0;
            return out;
        },

        wants(state, kind) {
            const p = this.prefs();
            const st = state || 'done';
            if (kind === 'schedule' && st === 'due') return true;
            if (kind === 'schedule' && p.schedule === false) return false;
            if (kind === 'prwatch' && p.pr === false) return false;
            const keys = STATE_PREFS[st];
            if (!keys) return true;
            return keys.every(k => p[k] !== false);
        },

        wantList(kind) {
            const list = PUSH_STATES.filter(s => this.wants(s, kind));
            if (kind === 'schedule') list.push('due');
            return list;
        },

        minSeconds() {
            return this.prefs().minSeconds;
        },

        quick(startedAt) {
            const min = this.minSeconds();
            return min > 0 && Number(startedAt) > 0 && Date.now() - Number(startedAt) < min * 1000;
        },

        pushTexts(kind) {
            const all = {
                turn: {
                    done: t('Your reply is ready'),
                    failed: t('Nymbot could not finish that reply'),
                    approval: t('Nymbot is waiting for your approval'),
                    question: t('Nymbot has a question for you'),
                    expired: t('Nymbot stopped: no answer came within 24 hours'),
                    paused: t('Nymbot paused. Open the chat to carry on.')
                },
                background: {
                    done: t('Your task is done'),
                    failed: t('Your background task could not finish'),
                    approval: t('Your background task needs your approval'),
                    question: t('Your background task has a question for you'),
                    expired: t('Your background task stopped: no answer came within 24 hours'),
                    paused: t('Your background task paused')
                },
                schedule: {
                    done: t('Your scheduled prompt ran'),
                    failed: t('A scheduled prompt could not run'),
                    approval: t('A scheduled prompt needs your approval'),
                    question: t('A scheduled prompt has a question for you'),
                    expired: t('A scheduled prompt stopped: no answer came within 24 hours'),
                    paused: t('A scheduled prompt paused'),
                    due: t('A scheduled prompt is due'),
                    disabled: t('A scheduled prompt failed 3 times and was turned off')
                },
                prwatch: {
                    'ci-failed': t('CI failed on a pull request you watch'),
                    review: t('New review comments on a pull request you watch'),
                    pr: t('A pull request you watch changed'),
                    done: t('A fix run on a pull request you watch finished'),
                    failed: t('A fix run on a pull request you watch could not finish'),
                    approval: t('A fix run on a pull request you watch needs your approval'),
                    question: t('A fix run on a pull request you watch has a question for you'),
                    paused: t('A fix run on a pull request you watch paused')
                }
            };
            const out = {};
            const table = all[kind] || all.turn;
            for (const k of Object.keys(table)) out[k] = String(table[k]).slice(0, TEXT_MAX);
            return out;
        },

        pushOptions(kind) {
            const out = { texts: this.pushTexts(kind), want: this.wantList(kind) };
            const min = kind === 'schedule' ? 0 : this.minSeconds();
            if (min) out.min = min;
            return out;
        },

        stateText() {
            return {
                paused: t('Paused. Open the chat to carry on.'),
                approval: t('Waiting for your approval.'),
                expired: t('No answer came within 24 hours, so the task stopped.'),
                stopped: t('Stopped.'),
                failed: t('That request failed.'),
                question: t('Nymbot has a question for you'),
                due: t('A scheduled prompt is due. Open Nymbot to run it.'),
                disabled: t('A server schedule was turned off after failing 3 times in a row.'),
                'ci-failed': t('CI failed on a pull request you watch.'),
                review: t('New review comments on a pull request you watch.'),
                pr: t('A pull request changed. Open the chat to see it.')
            };
        },

        headingFor(state, replied) {
            if (state === 'failed' || state === 'stopped' || state === 'expired') return t('Nymbot could not finish that reply');
            if (state === 'question') return t('Nymbot has a question');
            if (state) return t('Nymbot replied');
            return replied ? t('Nymbot replied') : t('Nymbot could not finish that reply');
        },

        async shareStateText() {
            try {
                if (!window.caches) return;
                const cache = await caches.open(TEXT_CACHE);
                await cache.put(TEXT_KEY, new Response(JSON.stringify(this.stateText()), { headers: { 'content-type': 'application/json' } }));
            } catch (_) { }
        },

        attach(opts) {
            const o = opts || {};
            if (o.enabled) this.enabled = o.enabled;
            if (o.prefs) this.prefsOf = o.prefs;
            if (o.titleOf) this.titleOf = o.titleOf;
            if (o.open) this.open = o.open;
            if (this._attached || !this.supported()) return;
            this._attached = true;
            this.shareStateText();
            document.addEventListener('visibilitychange', () => {
                if (this.hidden()) this.registerAll().catch(() => { });
            });
            window.addEventListener('pagehide', () => { this.registerAll().catch(() => { }); });
            navigator.serviceWorker.addEventListener('message', (e) => {
                const d = e.data || {};
                if (d.type === 'open-chat' && CHAT_RE.test(d.chat || '')) {
                    this.open(d.chat, ASKED_RE.test(d.asked || '') ? d.asked : null);
                }
            });
            const m = /(?:^|[#&])chat=([A-Za-z0-9_-]{1,64})/.exec(location.hash || '');
            if (m) {
                const a = /(?:^|[#&])asked=([0-9a-f]{64})/.exec(location.hash || '');
                history.replaceState(history.state, '', location.pathname + location.search);
                setTimeout(() => this.open(m[1], a ? a[1] : null), 0);
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
            this.ask().then((ok) => { if (ok && this.hidden()) return this.registerAll(); }).catch(() => { });
        },

        viewingChat(id) {
            this.viewing = id || null;
        },

        watch(convId, eventId, signer, info) {
            if (!this.supported() || !convId || !eventId) return;
            const key = (info && info.key) || convId;
            const asked = info && ASKED_RE.test(info.asked || '') ? info.asked : null;
            const anon = !!(signer || (info && info.anon));
            const held = this.pending.get(key);
            const startedAt = (info && Number(info.startedAt)) || (held && held.startedAt) || Date.now();
            this.pending.set(key, { convId, eventId, signer: signer || null, asked, anon, startedAt });
            clearTimeout(this.timers.get(key));
            this.timers.delete(key);
            if (anon || !this.allowed() || !this.pushSupported()) return;
            if (this.hidden()) {
                this.register(key);
                return;
            }
            this.timers.set(key, setTimeout(() => {
                this.timers.delete(key);
                const p = this.pending.get(key);
                if (p && p.eventId === eventId && this.allowed()) this.register(key);
            }, PROACTIVE_MS));
        },

        async settled(key, opts) {
            if (!this.supported()) return;
            const o = opts || {};
            clearTimeout(this.timers.get(key));
            this.timers.delete(key);
            const p = this.pending.get(key);
            if (!p) return;
            this.pending.delete(key);
            const convId = p.convId || key;
            const handled = this.registered.delete(p.eventId) | this.answered.delete(p.eventId);
            if (o.stopped || handled || !this.allowed()) return;
            if (!this.hidden() && this.viewing === convId) return;
            const state = o.state || (o.replied ? 'done' : 'failed');
            if (!this.wants(state, 'turn') || this.quick(o.startedAt || p.startedAt)) return;
            await this.show(convId, !!o.replied, null, p.asked, o.state);
        },

        async show(convId, replied, heading, asked, state) {
            const title = String(this.titleOf(convId) || '').trim();
            const tagged = ASKED_RE.test(asked || '') ? asked : null;
            const said = Object.prototype.hasOwnProperty.call(this.stateText(), state || '') ? this.stateText()[state] : null;
            const options = {
                body: said || title || t('Open the chat to read it.'),
                tag: 'reply-' + convId + (tagged ? '-' + tagged.slice(0, 16) : ''),
                data: tagged ? { chat: convId, asked: tagged } : { chat: convId },
                icon: '/app/icons/nymbot-192.png',
                badge: '/app/icons/nymbot-192.png'
            };
            const shown = heading || this.headingFor(state, replied);
            try {
                const reg = await navigator.serviceWorker.getRegistration('/app/');
                if (reg && typeof reg.showNotification === 'function') {
                    await reg.showNotification(shown, options);
                    return true;
                }
            } catch (_) { }
            try {
                const n = new Notification(shown, options);
                n.onclick = () => { try { window.focus(); } catch (_) { } this.open(convId, tagged); n.close(); };
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

        async registerAll() {
            if (!this.allowed() || !this.pushSupported()) return;
            if (this._registering) return this._registering;
            this._registering = (async () => {
                let sent = 0;
                for (const [key, p] of [...this.pending.entries()]) {
                    if (!p || p.anon || this.registered.has(p.eventId) || p.registering) continue;
                    if (sent++) await API.jitter();
                    await this.register(key);
                }
            })();
            try { await this._registering; } finally { this._registering = null; }
        },

        async register(key) {
            const p = this.pending.get(key);
            const convId = p ? (p.convId || key) : '';
            if (!p || p.anon || !CHAT_RE.test(convId) || this.registered.has(p.eventId) || p.registering) return;
            if (!this.allowed() || !this.pushSupported()) return;
            p.registering = true;
            let res = null;
            try {
                const subscription = await this.subscription();
                if (!subscription) return;
                res = await API.call('notify-turn', Object.assign({
                    eventId: p.eventId,
                    env: 'web',
                    subscription,
                    chat: convId,
                    text: t('Your reply is ready').slice(0, TEXT_MAX)
                }, this.pushOptions('turn')), { timeout: 10000 });
            } catch (_) {
                res = null;
            } finally {
                p.registering = false;
            }
            const data = res && res.status ? res.data : null;
            const now = this.pending.get(key);
            if (!data || !now || now.eventId !== p.eventId) return;
            if (data.done === true) {
                this.answered.add(p.eventId);
                if ((this.hidden() || this.viewing !== convId) && this.wants('done', 'turn') && !this.quick(p.startedAt)) await this.show(convId, true, null, p.asked);
                return;
            }
            if (data.ok === true) this.registered.add(p.eventId);
        }
    };

    window.NymbotNotify = Notify;
})();
