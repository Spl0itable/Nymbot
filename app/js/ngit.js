// Repositories announced on Nostr (NIP-34).
(function () {
    'use strict';

    const Relays = window.NymbotRelays;
    const NT = () => window.NostrTools;

    const KIND_REPO = 30617;
    const KIND_STATE = 30618;

    // The relays an naddr does not name.
    const FALLBACK_RELAYS = [
        'wss://relay.ngit.dev',
        'wss://relay.damus.io',
        'wss://nos.lol',
        'wss://relay.primal.net'
    ];

    function tagValues(event, name) {
        const out = [];
        for (const tag of (event && event.tags) || []) {
            if (!Array.isArray(tag) || tag[0] !== name) continue;
            for (let i = 1; i < tag.length; i++) {
                if (typeof tag[i] === 'string' && tag[i]) out.push(tag[i]);
            }
        }
        return out;
    }

    function firstTag(event, name) {
        const all = tagValues(event, name);
        return all.length ? all[0] : '';
    }

    /// Reads whatever somebody pasted: an naddr, a `nostr://` clone URL, or the
    /// npub-and- identifier the URL is made of.
    function parseAddress(input) {
        const text = String(input || '').trim();
        if (!text) return null;

        const naddr = /^(?:nostr:)?(naddr1[0-9a-z]+)$/i.exec(text);
        if (naddr) return fromNaddr(naddr[1]);

        // nostr://<naddr> — the same thing wearing a URL.
        const wrapped = /^nostr:\/\/(naddr1[0-9a-z]+)\/?$/i.exec(text);
        if (wrapped) return fromNaddr(wrapped[1]);

        // nostr://<npub|nip05>[/<relay-hint>]/<identifier>, each part percent-encoded.
        const url = /^nostr:\/\/(.+)$/i.exec(text);
        if (url) {
            const parts = url[1].split('/').filter(Boolean).map(decodeURIComponent);
            if (parts.length < 2) return null;
            const who = parts[0];
            const identifier = parts[parts.length - 1];
            const hint = parts.length > 2 ? parts[1] : '';
            const pubkey = toPubkey(who);
            if (!pubkey) return null;
            return {
                pubkey,
                identifier,
                relays: hint ? [withScheme(hint)] : [],
                nip05: /^[0-9a-f]{64}$/i.test(who) || /^npub1/i.test(who) ? '' : who
            };
        }
        return null;
    }

    function withScheme(host) {
        return /^wss?:\/\//i.test(host) ? host : 'wss://' + host;
    }

    function toPubkey(who) {
        if (/^[0-9a-f]{64}$/i.test(who)) return who.toLowerCase();
        if (/^npub1/i.test(who)) {
            try {
                const d = NT().nip19.decode(who);
                return d.type === 'npub' ? d.data : null;
            } catch (_) { return null; }
        }
        // A NIP-05 name needs a lookup this module does not do; the caller is
        // told what is missing rather than handed a silent failure.
        return null;
    }

    function fromNaddr(naddr) {
        try {
            const d = NT().nip19.decode(naddr);
            if (d.type !== 'naddr' || !d.data) return null;
            if (d.data.kind !== KIND_REPO) return null;
            return {
                pubkey: d.data.pubkey,
                identifier: d.data.identifier,
                relays: Array.isArray(d.data.relays) ? d.data.relays.map(withScheme) : []
            };
        } catch (_) { return null; }
    }

    function newest(events) {
        let best = null;
        for (const ev of events || []) {
            if (!ev || typeof ev.created_at !== 'number') continue;
            if (!best || ev.created_at > best.created_at) best = ev;
        }
        return best;
    }

    /// Which forge a clone URL points at, and what to call the repo there.
    function forgeFor(cloneUrl) {
        let parsed;
        try {
            parsed = new URL(String(cloneUrl).replace(/^git\+/, ''));
        } catch (_) { return null; }
        if (!/^https?:$/.test(parsed.protocol)) return null;
        const host = parsed.hostname.toLowerCase();
        const path = parsed.pathname.replace(/^\/+|\/+$/g, '').replace(/\.git$/i, '');
        const segments = path.split('/').filter(Boolean);
        if (segments.length < 2) return null;

        if (host === 'github.com' || host === 'www.github.com') {
            return { provider: 'github', host: 'github.com', repo: segments.slice(0, 2).join('/') };
        }
        if (host === 'gitlab.com' || host === 'www.gitlab.com') {
            // GitLab allows nested groups, which the worker accepts up to four.
            return { provider: 'gitlab', host: 'gitlab.com', repo: segments.slice(0, 4).join('/') };
        }
        if (host === 'codeberg.org') {
            return { provider: 'gitea', host: 'codeberg.org', repo: segments.slice(0, 2).join('/') };
        }
        // Self-hosted.
        const provider = /gitlab/.test(host) ? 'gitlab' : 'gitea';
        return {
            provider,
            host,
            repo: segments.slice(0, provider === 'gitlab' ? 4 : 2).join('/'),
            guessed: true
        };
    }

    const Ngit = {
        KIND_REPO,
        KIND_STATE,
        parseAddress,
        forgeFor,
        tagValues,

        /// Looks an announcement up and reads everything off it.
        async resolve(input) {
            const address = parseAddress(input);
            if (!address) {
                throw new Error(t('That is not a repository address. Paste an naddr, or a nostr:// URL from the repository page.'));
            }
            if (!address.pubkey) {
                throw new Error(t('That address names its owner by a NIP-05 name, which this app cannot look up yet. Use the naddr instead.'));
            }
            const where = Array.from(new Set([].concat(address.relays || [], FALLBACK_RELAYS)));
            const filter = {
                kinds: [KIND_REPO],
                authors: [address.pubkey],
                '#d': [address.identifier],
                limit: 4
            };
            // Both: the pool for anything mirrored to the usual relays, and the
            // announcement's own for anything that is not.
            const events = [].concat(
                await Relays.fetch(filter, 5000),
                await Relays.fetchFrom(where, filter, 6000));
            const announcement = newest(events);
            if (!announcement) {
                throw new Error(t('No repository announcement was found at that address. It may be on relays this app is not connected to.'));
            }

            const clone = tagValues(announcement, 'clone');
            const relays = tagValues(announcement, 'relays');
            let forge = null;
            for (const url of clone) {
                forge = forgeFor(url);
                if (forge && !forge.guessed) break;
            }
            if (!forge && clone.length) forge = forgeFor(clone[0]);

            const state = await this.state(address, relays);
            return {
                address,
                naddr: this.naddrFor(address),
                repoId: address.identifier,
                owner: address.pubkey,
                name: firstTag(announcement, 'name') || address.identifier,
                description: firstTag(announcement, 'description'),
                web: tagValues(announcement, 'web'),
                clone,
                relays,
                maintainers: tagValues(announcement, 'maintainers'),
                euc: (announcement.tags || []).filter(x => x[0] === 'r' && x[2] === 'euc').map(x => x[1])[0] || '',
                forge,
                head: state.head,
                refs: state.refs,
                announcedAt: announcement.created_at
            };
        },

        /// The branch the repository says is current, from its kind-30618.
        async state(address, extraRelays) {
            const where = Array.from(new Set([].concat(
                address.relays || [], extraRelays || [], FALLBACK_RELAYS)));
            let events = [];
            try {
                const filter = {
                    kinds: [KIND_STATE],
                    authors: [address.pubkey],
                    '#d': [address.identifier],
                    limit: 4
                };
                events = [].concat(
                    await Relays.fetch(filter, 4000),
                    await Relays.fetchFrom(where, filter, 5000));
            } catch (_) { events = []; }
            const state = newest(events);
            if (!state) return { head: '', refs: {} };
            const refs = {};
            for (const tag of state.tags || []) {
                if (!Array.isArray(tag) || typeof tag[0] !== 'string') continue;
                if (tag[0].indexOf('refs/') === 0 && tag[1]) refs[tag[0]] = tag[1];
            }
            let head = '';
            const raw = firstTag(state, 'HEAD');
            const named = /^ref:\s*refs\/heads\/(.+)$/.exec(raw || '');
            if (named) head = named[1].trim();
            return { head, refs };
        },

        naddrFor(address) {
            try {
                return NT().nip19.naddrEncode({
                    kind: KIND_REPO,
                    pubkey: address.pubkey,
                    identifier: address.identifier,
                    relays: (address.relays || []).slice(0, 3)
                });
            } catch (_) { return ''; }
        },

        /// What to store as a repository, once an announcement has been read.
        repoFrom(resolved, extra) {
            if (!resolved.forge) {
                throw new Error(t('That repository is announced, but none of its clone URLs is on a git host Nymbot can read files from.'));
            }
            return Object.assign({
                provider: resolved.forge.provider,
                host: resolved.forge.host,
                repo: resolved.forge.repo,
                branch: resolved.head || '',
                ngit: {
                    naddr: resolved.naddr,
                    repoId: resolved.repoId,
                    owner: resolved.owner,
                    name: resolved.name,
                    web: resolved.web[0] || '',
                    relays: resolved.relays.slice(0, 6),
                    maintainers: resolved.maintainers.slice(0, 8),
                    euc: resolved.euc,
                    guessedForge: !!resolved.forge.guessed
                }
            }, extra || {});
        }
    };

    window.NymbotNgit = Ngit;
})();
