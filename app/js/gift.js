(function () {
    'use strict';

    const PRESETS = { standard: [50, 100, 250, 500, 1000], pro: [1, 5, 10, 25, 50] };
    const MIN = { standard: 10, pro: 1 };
    const CODE_RE = /^GIFT-[0-9A-F]{32}$/;
    const KEPT = 50;

    const $ = (id) => document.getElementById(id);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };
    const num = (v) => window.NymbotI18n.count(v);
    const Api = () => window.NymbotApi;
    const Store = () => window.NymbotStore;

    let tier = 'standard';
    let pending = null;
    let made = null;
    let limits = { min: MIN, ttlDays: 30 };
    let peekSeq = 0;

    function codeOf(raw) {
        let s = String(raw == null ? '' : raw).trim();
        const at = s.search(/gift=/i);
        if (at !== -1) s = s.slice(at + 5);
        s = s.split(/[&\s]/)[0];
        try { s = decodeURIComponent(s); } catch (_) { }
        s = s.trim().toUpperCase();
        return CODE_RE.test(s) ? s : '';
    }

    function newCode() {
        const b = crypto.getRandomValues(new Uint8Array(16));
        return 'GIFT-' + Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('').toUpperCase();
    }

    function link(code) {
        return location.origin + '/app/#gift=' + code;
    }

    function kept() {
        const raw = Store().read('giftCodes', {});
        return raw && typeof raw === 'object' ? raw : {};
    }

    function keep(id, code) {
        const all = kept();
        all[id] = { code, at: Date.now() };
        const ids = Object.keys(all).sort((a, b) => (all[b].at || 0) - (all[a].at || 0)).slice(0, KEPT);
        const next = {};
        for (const k of ids) next[k] = all[k];
        Store().write('giftCodes', next);
    }

    function available(ui, which) {
        const v = Number(ui.balance && ui.balance[which]);
        return Number.isFinite(v) && v > 0 ? Math.floor(v) : 0;
    }

    function minOf(which) {
        const m = limits.min && Number(limits.min[which]);
        return m > 0 ? m : MIN[which];
    }

    function tierWord(which, n) {
        return which === 'pro'
            ? t('{n} Pro credits', { n: num(n) })
            : t('{n} credits', { n: num(n) });
    }

    function stamp(ms) {
        try {
            return new Date(ms).toLocaleDateString(undefined, { dateStyle: 'medium' });
        } catch (_) { return new Date(ms).toISOString().slice(0, 10); }
    }

    function renderPresets(ui) {
        const grid = $('giftPresets');
        grid.innerHTML = '';
        const most = available(ui, tier);
        for (const n of PRESETS[tier]) {
            const b = el('button', null, num(n));
            b.type = 'button';
            b.disabled = n > most;
            b.addEventListener('click', () => {
                $('giftAmount').value = String(n);
                check(ui);
            });
            grid.appendChild(b);
        }
        for (const b of document.querySelectorAll('#giftTier .tier-btn')) {
            b.classList.toggle('is-active', b.dataset.tier === tier);
        }
        const input = $('giftAmount');
        input.min = String(minOf(tier));
        input.max = String(Math.max(minOf(tier), most));
        $('giftLimits').textContent = t('At least {min}, at most the {most} you have free to give.', {
            min: num(minOf(tier)),
            most: num(most)
        });
        $('giftBalances').textContent = t('Your balance: {standard} credits · {pro} Pro credits', {
            standard: window.amount(Number(ui.balance && ui.balance.standard) || 0, 3),
            pro: window.amount(Number(ui.balance && ui.balance.pro) || 0, 3)
        });
    }

    function amountOf() {
        const raw = String($('giftAmount').value || '').trim();
        if (!/^\d+$/.test(raw)) return null;
        return parseInt(raw, 10);
    }

    function check(ui) {
        const n = amountOf();
        const most = available(ui, tier);
        let problem = '';
        if (n == null) problem = t('Enter a whole number of credits.');
        else if (n < minOf(tier)) problem = t('A gift is at least {n}.', { n: tierWord(tier, minOf(tier)) });
        else if (n > most) problem = t('You have {n} free to give.', { n: tierWord(tier, most) });
        $('giftMake').disabled = !!problem;
        ui.modalStatus('giftStatus', problem && $('giftAmount').value ? problem : '', problem ? 'warn' : null);
        return problem ? null : n;
    }

    function showMade(ui, code, gift) {
        made = { code, gift };
        const box = $('giftMade');
        box.hidden = false;
        const url = link(code);
        $('giftLink').value = url;
        $('giftCodeText').value = code;
        $('giftMadeWhat').textContent = t('A gift of {what}. It can be claimed once, until {date}.', {
            what: tierWord(gift.tier, gift.amount),
            date: stamp(gift.expiresAt)
        });
        try { window.NymbotQR.draw($('giftQr'), url, { width: 240 }); } catch (_) { }
        $('giftShare').hidden = typeof navigator.share !== 'function';
    }

    function hideMade() {
        made = null;
        $('giftMade').hidden = true;
    }

    function stateLine(g) {
        switch (g.state) {
            case 'redeemed': return t('Claimed {date}', { date: stamp(g.doneAt) });
            case 'canceled': return t('Canceled, credits returned {date}', { date: stamp(g.doneAt) });
            case 'expired': return t('Expired, credits returned {date}', { date: stamp(g.doneAt || g.expiresAt) });
            default: return t('Not claimed yet · until {date}', { date: stamp(g.expiresAt) });
        }
    }

    function renderList(ui, gifts) {
        const box = $('giftList');
        box.innerHTML = '';
        $('giftListHead').hidden = !gifts.length;
        const codes = kept();
        for (const g of gifts) {
            const row = el('div', 'gift-row is-' + g.state);
            row.dataset.id = g.id;
            const text = el('div', 'gift-row-text');
            text.appendChild(el('strong', null, tierWord(g.tier, g.amount)));
            text.appendChild(el('span', 'gift-row-state', stateLine(g)));
            row.appendChild(text);
            if (g.state === 'open') {
                const actions = el('div', 'gift-row-actions');
                const code = codes[g.id] && codes[g.id].code;
                if (code) {
                    const show = el('button', 'btn btn-small', t('Show'));
                    show.type = 'button';
                    show.dataset.role = 'show';
                    show.addEventListener('click', () => showMade(ui, code, g));
                    actions.appendChild(show);
                }
                const cancel = el('button', 'btn btn-small btn-ghost', t('Cancel gift'));
                cancel.type = 'button';
                cancel.dataset.role = 'cancel';
                cancel.addEventListener('click', () => cancelGift(ui, g));
                actions.appendChild(cancel);
                row.appendChild(actions);
            }
            box.appendChild(row);
        }
    }

    async function refreshList(ui) {
        let res;
        try { res = await Api().giftList(); } catch (_) { res = null; }
        const data = res && res.data;
        if (!data || data.error || !Array.isArray(data.gifts)) return;
        if (data.min && typeof data.min === 'object') limits.min = data.min;
        if (Number(data.ttlDays) > 0) limits.ttlDays = Number(data.ttlDays);
        renderList(ui, data.gifts);
        renderPresets(ui);
    }

    function open(ui) {
        tier = ui.proTier && ui.proTier() ? 'pro' : 'standard';
        pending = null;
        hideMade();
        $('giftAmount').value = '';
        renderPresets(ui);
        check(ui);
        ui.modalStatus('giftStatus', '');
        ui.openModal('modalGift');
        ui.refreshBalance().then(() => { renderPresets(ui); check(ui); }, () => { });
        refreshList(ui);
    }

    function setTier(ui, which) {
        tier = which === 'pro' ? 'pro' : 'standard';
        pending = null;
        renderPresets(ui);
        check(ui);
    }

    async function make(ui) {
        const n = check(ui);
        if (n == null) return;
        const ok = await ui.ask({
            title: t('Gift {what}?', { what: tierWord(tier, n) }),
            body: t('They leave your balance now. You get a link and a code that anyone can claim once. If nobody claims it, cancel it to get them back, or they come back by themselves after {days} days.', { days: num(limits.ttlDays) }),
            confirm: t('Make the gift')
        });
        if (!ok) return;
        if (!pending || pending.tier !== tier || pending.amount !== n) pending = { tier, amount: n, code: newCode() };
        const ask = pending;
        $('giftMake').disabled = true;
        ui.modalStatus('giftStatus', t('Making the gift…'));
        let res;
        try { res = await Api().giftCreate({ tier: ask.tier, amount: ask.amount, code: ask.code }); } catch (e) { res = { data: { error: e && e.message } }; }
        const data = res && res.data;
        $('giftMake').disabled = false;
        if (!data || data.error || !data.ok) {
            ui.modalStatus('giftStatus', (data && data.error) || t('The gift could not be made. Nothing left your balance.'), 'warn');
            return;
        }
        pending = null;
        keep(data.gift.id, ask.code);
        showMade(ui, ask.code, data.gift);
        ui.modalStatus('giftStatus', t('Done. Send the link or the code to whoever it is for.'), 'ok');
        $('giftAmount').value = '';
        await ui.refreshBalance().catch(() => { });
        renderPresets(ui);
        check(ui);
        refreshList(ui);
    }

    async function cancelGift(ui, g) {
        const ok = await ui.ask({
            title: t('Cancel this gift?'),
            body: t('{what} go back onto your balance, and the link and code stop working.', { what: tierWord(g.tier, g.amount) }),
            confirm: t('Cancel gift'),
            danger: true
        });
        if (!ok) return;
        let res;
        try { res = await Api().giftCancel(g.id); } catch (e) { res = { data: { error: e && e.message } }; }
        const data = res && res.data;
        if (!data || data.error) {
            ui.modalStatus('giftStatus', (data && data.error) || t('The gift could not be canceled.'), 'warn');
            refreshList(ui);
            return;
        }
        if (made && made.gift && made.gift.id === g.id) hideMade();
        ui.modalStatus('giftStatus', data.refunded
            ? t('Canceled. {what} are back on your balance.', { what: tierWord(data.tier, data.refunded) })
            : t('That gift was already closed.'), 'ok');
        await ui.refreshBalance().catch(() => { });
        renderPresets(ui);
        refreshList(ui);
    }

    async function share(ui) {
        if (!made || typeof navigator.share !== 'function') return;
        try {
            await navigator.share({
                title: t('A Nymbot gift'),
                text: t('A gift of {what} on Nymbot. Open the link to add them to your balance.', { what: tierWord(made.gift.tier, made.gift.amount) }),
                url: link(made.code)
            });
        } catch (_) { }
    }

    async function peek(ui) {
        const code = codeOf($('redeemCode').value);
        const what = $('redeemWhat');
        const seq = ++peekSeq;
        if (!code) {
            what.textContent = $('redeemCode').value.trim() ? t('That does not look like a gift link or code.') : '';
            $('redeemGo').disabled = true;
            return;
        }
        what.textContent = t('Looking it up…');
        let res;
        try { res = await Api().giftPeek(code); } catch (_) { res = null; }
        if (seq !== peekSeq) return;
        const data = res && res.data;
        if (!data || data.error || !data.gift) {
            what.textContent = (data && data.error) || t('That gift could not be looked up.');
            $('redeemGo').disabled = true;
            return;
        }
        const g = data.gift;
        if (g.own) {
            what.textContent = t('This is your own gift of {what}.', { what: tierWord(g.tier, g.amount) });
            $('redeemGo').disabled = true;
            return;
        }
        if (g.state !== 'open') {
            what.textContent = g.state === 'redeemed'
                ? t('This gift has already been claimed.')
                : (g.state === 'canceled' ? t('Whoever made this gift canceled it.') : t('This gift expired and went back to whoever made it.'));
            $('redeemGo').disabled = true;
            return;
        }
        what.textContent = t('A gift of {what}, waiting to be claimed.', { what: tierWord(g.tier, g.amount) });
        $('redeemGo').disabled = false;
    }

    function openRedeem(ui, prefill) {
        $('redeemCode').value = prefill || '';
        $('redeemWhat').textContent = '';
        $('redeemGo').disabled = true;
        ui.modalStatus('redeemStatus', '');
        ui.openModal('modalRedeemGift');
        if (prefill) peek(ui);
    }

    async function redeem(ui) {
        const code = codeOf($('redeemCode').value);
        if (!code) {
            ui.modalStatus('redeemStatus', t('That does not look like a gift link or code.'), 'warn');
            return;
        }
        $('redeemGo').disabled = true;
        ui.modalStatus('redeemStatus', t('Adding it to your balance…'));
        let res;
        try { res = await Api().giftRedeem(code); } catch (e) { res = { data: { error: e && e.message } }; }
        const data = res && res.data;
        if (!data || data.error || !data.ok) {
            ui.modalStatus('redeemStatus', (data && data.error) || t('The gift could not be claimed.'), 'warn');
            return;
        }
        ui.modalStatus('redeemStatus', t('Added {what} to your balance.', { what: tierWord(data.tier, data.credited) }), 'ok');
        $('redeemWhat').textContent = '';
        await ui.refreshBalance().catch(() => { });
    }

    function fromUrl(ui) {
        const hash = location.hash || '';
        if (!/(^|[#&])gift=/i.test(hash)) return false;
        const code = codeOf(hash);
        history.replaceState(null, '', location.pathname + location.search);
        openRedeem(ui, code || hash.replace(/^#/, ''));
        return true;
    }

    function handlers(ui) {
        return {
            'open-gift': () => open(ui),
            'gift-tier': (target) => setTier(ui, target.dataset.tier),
            'gift-make': () => make(ui),
            'gift-share': () => share(ui),
            'gift-redeem-open': () => openRedeem(ui, ''),
            'gift-redeem': () => redeem(ui)
        };
    }

    function bind() {
        const U = () => window.NymbotUI;
        const amount = $('giftAmount');
        if (amount) amount.addEventListener('input', () => { if (U()) check(U()); });
        const code = $('redeemCode');
        if (code) code.addEventListener('input', () => { if (U()) peek(U()); });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', bind);
    } else {
        bind();
    }

    window.NymbotGift = {
        PRESETS,
        MIN,
        codeOf,
        newCode,
        link,
        open,
        openRedeem,
        make,
        redeem,
        fromUrl,
        handlers,
        get pending() { return pending; },
        get made() { return made; }
    };
})();
