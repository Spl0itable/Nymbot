// The Nymbot worker client.
//
// Every request carries a kind-27235 auth event bound to this endpoint, method
// and action, so a captured signature cannot be replayed against a different
// one. The money actions are signed fresh each time; the worker enforces
// single-use for those.
(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Identity = window.NymbotIdentity;
    const Edge = window.NymbotEdge;

    const MONEY = new Set([
        'transfer-credits', 'create-invoice', 'claim-credits',
        'clear-history', 'voucher-issue', 'voucher-redeem',
        'pm-revert', 'git-apply', 'mcp-probe', 'runner-run',
        'gift-create', 'gift-redeem', 'gift-cancel'
    ]);

    const SERIAL = new Set(['pm']);

    const BUSY_STATUS = new Set([429, 503, 529]);
    const BUSY_TEXT = /rate[- ]?limit|too many requests|overloaded|over capacity|no capacity|try again later|temporarily unavailable/i;

    let gate = Promise.resolve();

    function queued(run) {
        const mine = gate.then(run, run);
        gate = mine.then(() => { }, () => { });
        return mine;
    }

    const url = () => `https://${C.apiHost}/api/bot`;

    const unreachable = () => ({
        error: navigator.onLine === false
            ? t('You are offline. Nothing was sent; try again once you are back online.')
            : t('Could not reach Nymbot. Nothing was sent; check your connection and try again.'),
        offline: true
    });

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
                // Well inside the worker's 120s window, so an edge-of-window
                // reject is not something a cached signature can cause.
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

        /// `signer` overrides the identity — anonymous mode signs as its
        /// throwaway key, which is the whole point of it.
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
                return { status: resp.status, response: null, data: data || {} };
            } catch (e) {
                const aborted = !!(e && e.name === 'AbortError');
                return { status: 0, response: null, aborted, data: aborted ? { error: t('Stopped.') } : unreachable() };
            }
        },

        async call(action, extra, opts) {
            const options = opts || {};
            const body = await this.signedBody(action, extra, options);
            const controller = options.controller || new AbortController();
            const attempt = async () => {
                if (controller.signal.aborted) {
                    return { status: 0, data: { error: t('timed out') } };
                }
                const timer = setTimeout(() => controller.abort(), options.timeout || 30000);
                try {
                    const resp = await Edge.fetch(url(), {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body,
                        signal: controller.signal
                    });
                    const data = await resp.json().catch(() => ({}));
                    return { status: resp.status, data: data || {} };
                } catch (e) {
                    return { status: 0, data: e.name === 'AbortError' ? { error: t('timed out') } : unreachable() };
                } finally {
                    clearTimeout(timer);
                }
            };
            return SERIAL.has(action) ? queued(attempt) : attempt();
        },

        busy(status, data) {
            if (BUSY_STATUS.has(status)) return true;
            const text = data && (data.error || data.message);
            return typeof text === 'string' && BUSY_TEXT.test(text);
        },

        balance(opts) { return this.call('balance', {}, opts); },

        transcribe(audio, opts) {
            return this.call('transcribe', { audio }, Object.assign({ timeout: 60000 }, opts || {}));
        },

        /// Public catalog data: it has to render before anyone has a balance,
        /// so it is the one call that needs no identity.
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
                return { status: resp.status, data: data || {} };
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

        voucherKeys() { return this.call('voucher-keys', {}); },
        voucherIssue(payload, opts) { return this.call('voucher-issue', payload, opts); },
        voucherRedeem(payload, opts) { return this.call('voucher-redeem', payload, opts); }
    };

    Api.signedText = signedText;
    Api.withAuth = withAuth;
    Api.sha256Hex = sha256Hex;

    window.NymbotApi = Api;
})();
