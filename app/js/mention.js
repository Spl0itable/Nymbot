(function () {
    'use strict';

    const HEAD = /^(\s*)(!?)\s*@([A-Za-z0-9][A-Za-z0-9._:/+-]*)(?=\s|$)([\s\S]*)$/;
    const TYPING = /^\s*(!?)@([A-Za-z0-9._:/+-]*)$/;
    const LIMIT = 8;

    function parse(text) {
        const m = HEAD.exec(String(text || ''));
        if (!m) return null;
        const name = m[3].replace(/[.,:;!?]+$/, '');
        if (!name) return null;
        const rest = m[4].trim();
        const fresh = m[2] === '!' || /^!/.test(rest);
        const body = rest.replace(/^!\s*/, '');
        return { name, rest: body, fresh };
    }

    function chatModels(catalog) {
        const list = (catalog && Array.isArray(catalog.models)) ? catalog.models : [];
        return list.filter(m => m && m.key && (!m.kind || m.kind === 'chat') && !m.command);
    }

    function squash(s) {
        return String(s || '').toLowerCase().replace(/[^a-z0-9.]+/g, '');
    }

    function versionOf(key) {
        return (String(key).match(/\d+(?:\.\d+)?/g) || []).map(Number);
    }

    function newer(a, b) {
        const va = versionOf(a.key);
        const vb = versionOf(b.key);
        for (let i = 0; i < Math.max(va.length, vb.length); i++) {
            const x = va[i] || 0;
            const y = vb[i] || 0;
            if (x !== y) return x > y;
        }
        return a.key.length < b.key.length;
    }

    function resolve(name, catalog) {
        const n = String(name || '').trim().toLowerCase().replace(/^@/, '').replace(/[.,:;!?]+$/, '');
        if (!n) return null;
        const models = chatModels(catalog);
        if (!models.length) return null;
        const byKey = new Map(models.map(m => [m.key.toLowerCase(), m]));
        if (byKey.has(n)) return byKey.get(n);
        const aliases = (catalog && catalog.aliases) || {};
        const target = Object.prototype.hasOwnProperty.call(aliases, n) ? String(aliases[n]).toLowerCase() : '';
        if (target && byKey.has(target)) return byKey.get(target);
        const flat = squash(n);
        if (!flat) return null;
        const byLabel = models.find(m => squash(m.label) === flat || squash(m.key) === flat);
        if (byLabel) return byLabel;
        let best = null;
        let bestRank = 9;
        for (const m of models) {
            const k = squash(m.key);
            const l = squash(m.label);
            const rank = k.startsWith(flat) ? 0
                : (l.startsWith(flat) ? 1
                    : ((k.includes(flat) || l.includes(flat)) ? 2 : 9));
            if (rank === 9) continue;
            if (!best || rank < bestRank || (rank === bestRank && newer(m, best))) {
                best = m;
                bestRank = rank;
            }
        }
        return best;
    }

    function typing(text) {
        const m = TYPING.exec(String(text || ''));
        return m ? { fresh: m[1] === '!', query: m[2] } : null;
    }

    function words(s) {
        return String(s || '').toLowerCase().split(/[^a-z0-9.]+/).filter(Boolean);
    }

    function suggest(query, catalog, limit) {
        const q = squash(query);
        const models = chatModels(catalog);
        const aliases = (catalog && catalog.aliases) || {};
        const aliased = new Set(Object.keys(aliases)
            .filter(name => q && name.toLowerCase().startsWith(q))
            .map(name => String(aliases[name]).toLowerCase()));
        const scored = [];
        for (const m of models) {
            const k = squash(m.key);
            const l = squash(m.label);
            const a = squash(m.author || m.authorSlug);
            let rank;
            if (!q) rank = 5;
            else if (k.startsWith(q)) rank = 0;
            else if (l.startsWith(q)) rank = 1;
            else if (aliased.has(m.key.toLowerCase())
                || words(m.key).concat(words(m.label)).some(w => w.startsWith(q))) rank = 2;
            else if (k.includes(q) || l.includes(q)) rank = 3;
            else if (a.startsWith(q)) rank = 4;
            else continue;
            scored.push({ m, rank });
        }
        scored.sort((x, y) => x.rank - y.rank || (newer(x.m, y.m) ? -1 : (newer(y.m, x.m) ? 1 : 0)));
        return scored.slice(0, limit || LIMIT).map(s => s.m);
    }

    function completion(model, fresh) {
        return (fresh ? '!' : '') + '@' + model.key + ' ';
    }

    function apply(text, catalog) {
        const head = parse(text);
        if (!head) return null;
        const model = resolve(head.name, catalog);
        if (!model) return { unknown: head.name, text };
        return {
            model,
            name: head.name,
            fresh: head.fresh,
            text: head.rest ? (head.fresh ? '!' : '') + head.rest : ''
        };
    }

    function pinned(model) {
        return {
            key: model.key, label: model.label, credits: model.credits, max: model.max,
            slug: model.authorSlug || null
        };
    }

    window.NymbotMention = { parse, resolve, typing, suggest, completion, apply, pinned, chatModels };
})();
