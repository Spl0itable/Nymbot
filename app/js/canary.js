(function () {
    'use strict';

    const C = window.NymbotConfig;
    const KIND = 30078;

    function parseContent(raw) {
        if (raw && typeof raw === 'object') return raw;
        if (typeof raw !== 'string') return null;
        try {
            const c = JSON.parse(raw);
            return c && typeof c === 'object' ? c : null;
        } catch (_) {
            return null;
        }
    }

    function dTag(doc) {
        const tag = Array.isArray(doc.tags) ? doc.tags.find((x) => Array.isArray(x) && x[0] === 'd') : null;
        return tag ? tag[1] : null;
    }

    function signature(doc, pubkey) {
        const NT = window.NostrTools;
        if (!NT || typeof NT.verifyEvent !== 'function') return 'invalid';
        try {
            const copy = JSON.parse(JSON.stringify(doc));
            if (copy.kind !== KIND || dTag(copy) !== C.canaryDTag || copy.pubkey !== pubkey) return 'invalid';
            return NT.verifyEvent(copy) ? 'valid' : 'invalid';
        } catch (_) {
            return 'invalid';
        }
    }

    function time(value) {
        const ms = typeof value === 'string' ? Date.parse(value) : NaN;
        return Number.isFinite(ms) ? ms : null;
    }

    function evaluate(doc, opts) {
        const o = opts || {};
        const pubkey = o.pubkey || C.developerPubkey;
        const now = typeof o.now === 'number' ? o.now : Date.now();
        const d = doc && typeof doc === 'object' ? doc : {};
        const signed = typeof d.sig === 'string' && d.sig !== '' && typeof d.id === 'string' && typeof d.pubkey === 'string';
        const sig = signed ? signature(d, pubkey) : 'unsigned';
        const c = parseContent(signed ? d.content : (typeof d.content === 'string' ? d.content : d)) || {};
        const updatedAt = time(c.updatedAt);
        const dueBy = time(c.nextUpdateBy);
        const overdue = dueBy === null || now > dueBy;
        let state;
        if (sig === 'invalid') state = 'forged';
        else if (sig === 'unsigned') state = 'unsigned';
        else state = c.allClear === true && !overdue ? 'ok' : 'stale';
        return {
            state,
            sig,
            statement: typeof c.statement === 'string' ? c.statement : '',
            allClear: c.allClear === true,
            updatedAt,
            dueBy,
            overdue,
            btcBlock: c.btcBlock && typeof c.btcBlock === 'object' ? c.btcBlock : null,
            id: signed ? d.id : '',
            pubkey: signed ? d.pubkey : ''
        };
    }

    async function run(opts) {
        const o = opts || {};
        const res = await fetch(o.url || C.canaryUrl, { cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer' });
        if (res.status === 404) return { state: 'gone' };
        if (!res.ok) throw new Error('http ' + res.status);
        return evaluate(await res.json(), o);
    }

    let pending = null;

    window.NymbotCanary = {
        KIND,
        PUBKEY: C.developerPubkey,
        D_TAG: C.canaryDTag,
        evaluate,
        run,
        check() {
            if (!pending) pending = run().catch((e) => { pending = null; throw e; });
            return pending;
        }
    };
})();
