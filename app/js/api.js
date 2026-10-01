// Every request carries a kind-27235 auth event bound to endpoint, method and action, so it cannot be replayed.
(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Identity = window.NymbotIdentity;
    const Edge = window.NymbotEdge;

    const MONEY = new Set([
        'transfer-credits', 'create-invoice', 'claim-credits',
        'clear-history', 'voucher-issue', 'voucher-redeem',
        'pm-revert', 'git-apply', 'git-branch', 'mcp-probe', 'runner-run', 'site-check',
        'gift-create', 'gift-redeem', 'gift-cancel',
        'schedule-put', 'schedule-delete', 'schedule-clear'
    ]);

    const SLOTTED = new Set(['pm']);
    const RUN_LIMIT = 3;
    const RUN_CEILING = 10;

    const BUSY_STATUS = new Set([429, 503, 529]);
    const BUSY_TEXT = /rate[- ]?limit|too many requests|overloaded|over capacity|no capacity|try again later|temporarily unavailable/i;

    const slots = { busy: 0, waiting: [] };

    function runLimit() {
        let n = RUN_LIMIT;
        try { n = Number(Api.runLimit()) || RUN_LIMIT; } catch (_) { n = RUN_LIMIT; }
        return Math.max(1, Math.min(RUN_CEILING, Math.floor(n)));
    }

    function pump() {
        while (slots.waiting.length && slots.busy < runLimit()) {
            const next = slots.waiting.shift();
            slots.busy++;
            next.grant();
        }
    }

    function takeSlot(signal, onSlot) {
        if (!slots.waiting.length && slots.busy < runLimit()) {
            slots.busy++;
            return Promise.resolve(true);
        }
        return new Promise((resolve) => {
            const entry = {
                grant: () => {
                    if (signal) signal.removeEventListener('abort', drop);
                    if (onSlot) { try { onSlot(false); } catch (_) { } }
                    resolve(true);
                }
            };
            const drop = () => {
                const at = slots.waiting.indexOf(entry);
                if (at !== -1) slots.waiting.splice(at, 1);
                if (onSlot) { try { onSlot(false); } catch (_) { } }
                resolve(false);
            };
            if (signal) {
                if (signal.aborted) { resolve(false); return; }
                signal.addEventListener('abort', drop, { once: true });
            }
            slots.waiting.push(entry);
            if (onSlot) { try { onSlot(true); } catch (_) { } }
        });
    }

    function freeSlot() {
        slots.busy = Math.max(0, slots.busy - 1);
        pump();
    }

    const url = () => `https://${C.apiHost}/api/bot`;

    const unreachable = () => ({
        error: navigator.onLine === false
            ? t('You are offline. Nothing was sent; try again once you are back online.')
            : t('Could not reach Nymbot. Nothing was sent; check your connection and try again.'),
        offline: true
    });

    const priceUnavailableText = () =>
        t('Nymbot could not check the bitcoin price just now, so nothing was sent or charged. Try again in a minute.');

    function priced(data) {
        if (!data || data.priceUnavailable !== true) return data;
        return Object.assign({}, data, { error: priceUnavailableText(), retryable: true });
    }

    function hex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    async function sha256Hex(text) {
        const bytes = new TextEncoder().encode(text);
        return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
    }

    function signedText(fields) {
        const out = {};
        for (const key of Object.keys(fields).filter(k => k !== 'auth').sort()) out[key] = fields[key];
        return JSON.stringify(out);
    }

    function withAuth(text, auth) {
        const tail = '"auth":' + JSON.stringify(auth) + '}';
        return text === '{}' ? '{' + tail : text.slice(0, -1) + ',' + tail;
    }

    const Api = {
        _authCache: new Map(),

        async auth(action, signer, payload) {
            const nowSec = Math.floor(Date.now() / 1000);
            const key = action + '|' + (signer ? signer.pubkey : Identity.pubkey) + '|' + (payload || '');
            if (!MONEY.has(action)) {
                const hit = this._authCache.get(key);
                // Well inside the worker's 120s window.
                if (hit && (nowSec - hit.created_at) < 90) return hit;
            }
            const event = {
                kind: 27235,
                created_at: nowSec,
                tags: [
                    ['domain', 'nymbot-pm'],
                    ['method', 'POST'],
                    ['u', url()],
                    ['action', action]
                ].concat(payload ? [['payload', payload]] : [])
                    .concat(MONEY.has(action) ? [['nonce', hex(crypto.getRandomValues(new Uint8Array(16)))]] : []),
                content: 'nymbot-pm-auth'
            };
            const signed = signer ? signer.sign(event) : await Identity.signEvent(event);
            if (!MONEY.has(action)) {
                for (const [stale, held] of this._authCache) {
                    if (nowSec - held.created_at >= 90) this._authCache.delete(stale);
                }
                this._authCache.set(key, signed);
            }
            return signed;
        },

        /// `signer` overrides the identity; anonymous mode signs as its throwaway key.
        async signedBody(action, extra, options) {
            const fields = Object.assign(
                { action, pubkey: options.signer ? options.signer.pubkey : Identity.pubkey },
                extra || {});
            const text = signedText(fields);
            const auth = await this.auth(action, options.signer, await sha256Hex(text));
            return withAuth(text, auth);
        },

        async stream(action, extra, opts) {
            const options = opts || {};
            const body = await this.signedBody(action, extra, options);
            try {
                const resp = await Edge.fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body,
                    signal: options.signal
                });
                if (resp.ok && /ndjson/i.test(resp.headers.get('content-type') || '')) {
                    return { status: resp.status, response: resp, data: null };
                }
                const data = await resp.json().catch(() => ({}));
                return { status: resp.status, response: null, data: priced(data || {}) };
            } catch (e) {
                const aborted = !!(e && e.name === 'AbortError');
                return { status: 0, response: null, aborted, data: aborted ? { error: t('Stopped.') } : unreachable() };
            }
        },

        async call(action, extra, opts) {
            const options = opts || {};
            const body = await this.signedBody(action, extra, options);
            const outer = options.controller ? options.controller.signal : (options.signal || null);
            const attempt = async () => {
                if (outer && outer.aborted) {
                    return { status: 0, aborted: true, data: { error: t('Stopped.') } };
                }
                const own = new AbortController();
                let timedOut = false;
                const relay = () => own.abort();
                if (outer) outer.addEventListener('abort', relay, { once: true });
                const timer = setTimeout(() => { timedOut = true; own.abort(); }, options.timeout || 30000);
                try {
                    const resp = await Edge.fetch(url(), {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body,
                        signal: own.signal
                    });
                    const data = await resp.json().catch(() => ({}));
                    return { status: resp.status, data: priced(data || {}) };
                } catch (e) {
                    if (e && e.name === 'AbortError') {
                        return timedOut
                            ? { status: 0, timedOut: true, data: { error: t('timed out') } }
                            : { status: 0, aborted: true, data: { error: t('Stopped.') } };
                    }
                    return { status: 0, data: unreachable() };
                } finally {
                    clearTimeout(timer);
                    if (outer) outer.removeEventListener('abort', relay);
                }
            };
            if (!SLOTTED.has(action) || options.slot === false) return attempt();
            const got = await takeSlot(outer, options.onSlot);
            if (!got) return { status: 0, aborted: true, data: { error: t('Stopped.') } };
            try {
                return await attempt();
            } finally {
                freeSlot();
            }
        },

        JITTER_MS: 2000,

        jitterMs(max) {
            const cap = Math.min(Number(max != null ? max : this.JITTER_MS) || 0, Number(this.JITTER_MS) || 0);
            if (!(cap > 0)) return 0;
            const r = crypto.getRandomValues(new Uint32Array(1))[0] / 4294967296;
            return Math.floor(cap * (0.25 + 0.75 * r));
        },

        jitter(max) {
            const ms = this.jitterMs(max);
            return ms > 0 ? new Promise(r => setTimeout(r, ms)) : Promise.resolve();
        },

        runLimit: () => RUN_LIMIT,
        RUN_LIMIT,
        RUN_CEILING,

        inFlight() { return { busy: slots.busy, waiting: slots.waiting.length }; },

        refreshSlots() { pump(); },

        cancelRun(replyTo, opts) {
            return this.call('pm-cancel', { replyTo }, Object.assign({ timeout: 10000 }, opts || {}));
        },

        steerRun(replyTo, text, opts) {
            return this.call('pm-steer', { replyTo, text }, Object.assign({ timeout: 10000 }, opts || {}));
        },

        steerStatus(ids, opts) {
            return this.call('pm-steer-status', { ids }, Object.assign({ timeout: 10000 }, opts || {}));
        },

        claimRun(eventId, opts) {
            return this.call('pm-claim', { eventId }, Object.assign({ timeout: 90000 }, opts || {}));
        },

        liveRuns(thread, opts) {
            return this.call('pm-runs', thread == null ? {} : { thread }, Object.assign({ timeout: 10000 }, opts || {}));
        },

        busy(status, data) {
            if (data && data.priceUnavailable === true) return false;
            if (BUSY_STATUS.has(status)) return true;
            const text = data && (data.error || data.message);
            return typeof text === 'string' && BUSY_TEXT.test(text);
        },

        balance(opts) { return this.call('balance', {}, opts); },

        transcribe(audio, opts) {
            return this.call('transcribe', { audio }, Object.assign({ timeout: 60000 }, opts || {}));
        },

        async models() {
            try {
                const resp = await Edge.fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'models' })
                });
                return await resp.json();
            } catch (_) { return null; }
        },

        async pqKey(pubkey, opts) {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), (opts && opts.timeout) || 3000);
            try {
                const resp = await Edge.fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'pq-key', pubkey }),
                    signal: controller.signal
                });
                if (!resp.ok) return null;
                const data = await resp.json();
                return (data && data.event && typeof data.event === 'object') ? data.event : null;
            } catch (_) {
                return null;
            } finally {
                clearTimeout(timer);
            }
        },

        async pushKey() {
            const resp = await Edge.fetch(url(), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'push-key' })
            });
            if (!resp.ok) throw new Error('push-key ' + resp.status);
            return await resp.json();
        },

        async runnerInfo() {
            try {
                const resp = await Edge.fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'runner-info' })
                });
                if (!resp.ok) return null;
                return await resp.json();
            } catch (_) { return null; }
        },

        async teamEstimate(body) {
            try {
                const resp = await Edge.fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(Object.assign({ action: 'team-estimate' }, body || {}))
                });
                const data = await resp.json().catch(() => ({}));
                return { status: resp.status, data: priced(data || {}) };
            } catch (_) {
                return { status: 0, data: unreachable() };
            }
        },

        async notices() {
            try {
                const resp = await Edge.fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'notices', platform: 'web' })
                });
                const data = await resp.json();
                return Array.isArray(data && data.notices) ? data.notices : [];
            } catch (_) { return []; }
        },

        createInvoice(amountSats, tier, recipientPubkey, opts) {
            return this.call('create-invoice', {
                amountSats, tier,
                ...(recipientPubkey ? { recipientPubkey } : {})
            }, opts);
        },

        checkInvoice(invoiceId, opts) { return this.call('check-invoice', { invoiceId }, opts); },
        claimCredits(invoiceId, opts) { return this.call('claim-credits', { invoiceId }, opts); },
        transferCredits(targetPubkey, opts) { return this.call('transfer-credits', { targetPubkey }, opts); },

        giftCreate(payload, opts) { return this.call('gift-create', payload, opts); },
        giftRedeem(code, opts) { return this.call('gift-redeem', { code }, opts); },
        giftCancel(id, opts) { return this.call('gift-cancel', { id }, opts); },
        giftList(opts) { return this.call('gift-list', {}, opts); },
        giftPeek(code, opts) { return this.call('gift-peek', { code }, opts); },

        async voucherKeys() {
            try {
                const resp = await Edge.fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'voucher-keys' })
                });
                const data = await resp.json().catch(() => ({}));
                return { status: resp.status, data: data || {} };
            } catch (_) {
                return { status: 0, data: unreachable() };
            }
        },
        voucherIssue(payload, opts) { return this.call('voucher-issue', payload, opts); },
        voucherRedeem(payload, opts) { return this.call('voucher-redeem', payload, opts); }
    };

    Api.signedText = signedText;
    Api.priced = priced;
    Api.withAuth = withAuth;
    Api.sha256Hex = sha256Hex;

    window.NymbotApi = Api;
})();
