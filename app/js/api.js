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

    const MONEY = new Set([
        'transfer-credits', 'create-invoice', 'claim-credits',
        'clear-history', 'voucher-issue', 'voucher-redeem'
    ]);

    const url = () => `https://${C.apiHost}/api/bot`;

    const Api = {
        _authCache: new Map(),

        async auth(action, signer) {
            const nowSec = Math.floor(Date.now() / 1000);
            const key = action + '|' + (signer ? signer.pubkey : Identity.pubkey);
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
                ],
                content: 'nymbot-pm-auth'
            };
            const signed = signer ? signer.sign(event) : await Identity.signEvent(event);
            if (!MONEY.has(action)) this._authCache.set(key, signed);
            return signed;
        },

        /// `signer` overrides the identity — anonymous mode signs as its
        /// throwaway key, which is the whole point of it.
        async call(action, extra, opts) {
            const options = opts || {};
            const auth = await this.auth(action, options.signer);
            const body = Object.assign(
                { action, pubkey: options.signer ? options.signer.pubkey : Identity.pubkey, auth },
                extra || {});
            const controller = options.controller || new AbortController();
            const timer = setTimeout(() => controller.abort(), options.timeout || 30000);
            try {
                const resp = await fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body),
                    signal: controller.signal
                });
                const data = await resp.json().catch(() => ({}));
                return { status: resp.status, data: data || {} };
            } catch (e) {
                return { status: 0, data: { error: e.name === 'AbortError' ? t('timed out') : t('network error') } };
            } finally {
                clearTimeout(timer);
            }
        },

        balance(opts) { return this.call('balance', {}, opts); },

        clearHistory(opts) { return this.call('clear-history', {}, opts); },

        /// Public catalog data: it has to render before anyone has a balance,
        /// so it is the one call that needs no identity.
        async models() {
            try {
                const resp = await fetch(url(), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'models' })
                });
                return await resp.json();
            } catch (_) { return null; }
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

        voucherKeys() { return this.call('voucher-keys', {}); },
        voucherIssue(payload, opts) { return this.call('voucher-issue', payload, opts); },
        voucherRedeem(payload, opts) { return this.call('voucher-redeem', payload, opts); }
    };

    window.NymbotApi = Api;
})();
