(function () {
    'use strict';

    const Store = window.NymbotStore;
    const NT = () => window.NostrTools;

    const KIND = 30078;
    const D_PREFIX = 'nym-bot-';
    const CAP = 60;

    function encode(text) {
        const bytes = new TextEncoder().encode(text);
        let binary = '';
        for (const b of bytes) binary += String.fromCharCode(b);
        return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    function decode(payload) {
        const padded = String(payload || '').replace(/-/g, '+').replace(/_/g, '/');
        const binary = atob(padded + '==='.slice((padded.length + 3) % 4));
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return new TextDecoder().decode(bytes);
    }

    function slug(name) {
        return String(name || 'bot').toLowerCase()
            .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'bot';
    }

    /// What travels when a bot is shared. Only the four things that make it what
    /// it is: no repositories, no tokens, no knowledge files, no transcript.
    /// A bot is a way of answering, not access to anything.
    function shareable(bot) {
        return {
            v: 1,
            name: String(bot.name || '').slice(0, 60),
            tagline: String(bot.tagline || '').slice(0, 160),
            icon: /^[a-z]+$/.test(bot.icon || '') ? bot.icon : 'robot',
            instructions: String(bot.instructions || '').slice(0, 6000),
            greeting: String(bot.greeting || '').slice(0, 400),
            model: bot.modelKey ? String(bot.modelKey).slice(0, 80) : null,
            modelLabel: bot.modelLabel ? String(bot.modelLabel).slice(0, 80) : null,
            starters: (bot.starters || []).slice(0, 6).map(s => String(s).slice(0, 200))
        };
    }

    const Bots = {
        all() {
            const list = Store.read('bots', []);
            return Array.isArray(list) ? list : [];
        },

        get(id) { return this.all().find(b => b.id === id) || null; },

        save(bot) {
            const list = this.all();
            const entry = Object.assign({
                name: '', tagline: '', icon: 'robot', instructions: '',
                greeting: '', modelKey: null, modelLabel: null, starters: [],
                author: '', naddr: '', createdAt: Date.now()
            }, bot);
            if (!entry.id) entry.id = Store.uid();
            entry.updatedAt = Date.now();
            entry.starters = (entry.starters || []).filter(Boolean).slice(0, 6);
            const i = list.findIndex(b => b.id === entry.id);
            if (i === -1) list.push(entry); else list[i] = entry;
            Store.write('bots', list.slice(-CAP));
            return entry;
        },

        remove(id) {
            Store.write('bots', this.all().filter(b => b.id !== id));
        },

        /// A link anyone can open. The bot rides in the fragment, which browsers
        /// never send to a server, so sharing one is not a request to anybody.
        link(bot, origin) {
            const base = (origin || location.origin) + '/app/';
            return base + '#bot=' + encode(JSON.stringify(shareable(bot)));
        },

        /// Reads a bot out of a link or a raw payload. Returns null for anything
        /// that is not one, so a stray fragment is ignored rather than trusted.
        fromLink(text) {
            const raw = String(text || '');
            const at = raw.indexOf('bot=');
            const payload = at === -1 ? raw : raw.slice(at + 4);
            let parsed;
            try {
                parsed = JSON.parse(decode(payload.split('&')[0]));
            } catch (_) {
                return null;
            }
            if (!parsed || typeof parsed !== 'object' || !parsed.name) return null;
            const clean = shareable(parsed);
            return {
                name: clean.name,
                tagline: clean.tagline,
                icon: clean.icon,
                instructions: clean.instructions,
                greeting: clean.greeting,
                modelKey: clean.model,
                modelLabel: clean.modelLabel,
                starters: clean.starters
            };
        },

        /// A replaceable kind 30078 event, so republishing the same bot replaces
        /// it rather than piling up copies. Signed by the account, never by the
        /// throwaway key: publishing is a claim of authorship.
        event(bot, pubkey) {
            return {
                kind: KIND,
                pubkey,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['d', D_PREFIX + slug(bot.name)],
                    ['title', String(bot.name || '').slice(0, 60)],
                    ['t', 'nymbot']
                ],
                content: JSON.stringify(shareable(bot))
            };
        },

        naddr(bot, pubkey) {
            const nt = NT();
            if (!nt || !nt.nip19 || !nt.nip19.naddrEncode) return '';
            try {
                return nt.nip19.naddrEncode({
                    identifier: D_PREFIX + slug(bot.name),
                    pubkey,
                    kind: KIND
                });
            } catch (_) {
                return '';
            }
        },

        fromEvent(event) {
            if (!event || event.kind !== KIND) return null;
            let parsed;
            try { parsed = JSON.parse(event.content || '{}'); } catch (_) { return null; }
            if (!parsed || !parsed.name) return null;
            const clean = shareable(parsed);
            return {
                name: clean.name,
                tagline: clean.tagline,
                icon: clean.icon,
                instructions: clean.instructions,
                greeting: clean.greeting,
                modelKey: clean.model,
                modelLabel: clean.modelLabel,
                starters: clean.starters,
                author: event.pubkey
            };
        },

        filterFor(pointer) {
            return {
                kinds: [KIND],
                authors: [pointer.pubkey],
                '#d': [pointer.identifier],
                limit: 2
            };
        },

        pointerFor(naddr) {
            const nt = NT();
            if (!nt || !nt.nip19) return null;
            try {
                const decoded = nt.nip19.decode(String(naddr || '').trim());
                if (decoded.type !== 'naddr') return null;
                const data = decoded.data;
                if (data.kind !== KIND) return null;
                return { pubkey: data.pubkey, identifier: data.identifier, kind: data.kind };
            } catch (_) {
                return null;
            }
        },

        slug,
        shareable,
        encode,
        decode,
        KIND,
        D_PREFIX
    };

    window.NymbotBots = Bots;
})();
