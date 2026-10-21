(function () {
    'use strict';

    function listed(list, aliases, key) {
        if (!Array.isArray(list) || !key) return false;
        if (list.indexOf(key) >= 0) return true;
        const to = aliases && Object.prototype.hasOwnProperty.call(aliases, key) ? aliases[key] : null;
        return !!to && list.indexOf(to) >= 0;
    }

    function blocked(pair, catalog, proOk) {
        if (!pair.pro && !pair.media) return null;
        if (catalog) {
            const aliases = catalog.aliases || {};
            if (pair.pro && !listed(catalog.chat, aliases, pair.pro)) return 'missing';
            if (pair.media && !listed(catalog.media, aliases, pair.media)) return 'missing';
        }
        return proOk ? null : 'credits';
    }

    function resolve(input) {
        const i = input || {};
        const chat = i.chat || {};
        const global = { pro: (i.global && i.global.pro) || null, media: (i.global && i.global.media) || null };
        const catalog = i.catalog || null;
        const proOk = i.proOk !== false;
        let fallback = null;
        if (chat.pin || chat.pro || chat.media) {
            const pair = { pro: chat.pro || null, media: chat.media || null };
            const why = blocked(pair, catalog, proOk);
            if (!why) return { pro: pair.pro, media: pair.media, source: 'chat', fallback: null };
            fallback = { pro: pair.pro, media: pair.media, reason: why };
        } else if (i.reply && i.reply.key && catalog) {
            const key = i.reply.key;
            const pair = listed(catalog.media, catalog.aliases || {}, key) ? { pro: null, media: key } : { pro: key, media: null };
            if (!blocked(pair, catalog, proOk)) return { pro: pair.pro, media: pair.media, source: 'reply', fallback: null };
        }
        const why = blocked(global, catalog, proOk);
        if (!why) return { pro: global.pro, media: global.media, source: 'global', fallback: fallback };
        return { pro: null, media: null, source: 'default', fallback: fallback || { pro: global.pro, media: global.media, reason: why } };
    }

    window.NymbotChatModel = { resolve };
})();
