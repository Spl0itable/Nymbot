(function () {
    'use strict';

    const Store = window.NymbotStore;
    const Relays = window.NymbotRelays;
    const Avatar = window.NymbotAvatar;

    const MAX_AGE_MS = 6 * 3600 * 1000;
    const SAFE_IMAGE = /^https:\/\/[^\s"'<>]+$/i;

    function cached(pubkey) {
        const all = Store.read('profiles', {}) || {};
        return all[pubkey] || null;
    }

    function remember(pubkey, profile) {
        const all = Store.read('profiles', {}) || {};
        const keys = Object.keys(all);
        if (keys.length > 40) {
            for (const k of keys.slice(0, keys.length - 40)) delete all[k];
        }
        all[pubkey] = profile;
        Store.write('profiles', all);
    }

    function readMetadata(event) {
        let meta;
        try { meta = JSON.parse(event.content || '{}'); } catch (_) { return null; }
        if (!meta || typeof meta !== 'object') return null;
        const pick = (...keys) => {
            for (const k of keys) {
                const v = meta[k];
                if (typeof v === 'string' && v.trim()) return v.trim();
            }
            return '';
        };
        const picture = pick('picture', 'image');
        const banner = pick('banner');
        return {
            name: pick('display_name', 'displayName', 'name').slice(0, 60),
            handle: pick('name', 'display_name').slice(0, 60),
            about: pick('about').slice(0, 400),
            nip05: pick('nip05').slice(0, 120),
            picture: SAFE_IMAGE.test(picture) ? picture : '',
            banner: SAFE_IMAGE.test(banner) ? banner : '',
            lud16: pick('lud16', 'lud06').slice(0, 120),
            at: event.created_at || 0,
            fetchedAt: Date.now()
        };
    }

    const Profile = {
        onChange: null,
        _inflight: new Map(),

        /// What to draw for a key right now: the published profile when there
        /// is one, and the generated nym when there is not. Never blocks, so a
        /// relay that is slow or unreachable costs nothing at render time.
        for(pubkey) {
            const key = String(pubkey || '');
            const hit = cached(key);
            const fallbackName = Avatar.nymName(key);
            const suffix = Avatar.suffix(key);
            return {
                pubkey: key,
                name: (hit && hit.name) || fallbackName,
                suffix,
                nip05: (hit && hit.nip05) || '',
                about: (hit && hit.about) || '',
                avatar: (hit && hit.picture) || Avatar.identicon(key),
                hasProfile: !!(hit && (hit.name || hit.picture)),
                colour: Avatar.colorClass(key)
            };
        },

        /// Reads kind 0 off the relays and caches it. A miss is remembered too,
        /// so a key with no profile is not re-asked on every render.
        async load(pubkey, options) {
            const opts = options || {};
            const key = String(pubkey || '');
            if (!/^[0-9a-f]{64}$/i.test(key)) return null;

            const hit = cached(key);
            if (!opts.force && hit && Date.now() - (hit.fetchedAt || 0) < MAX_AGE_MS) {
                return hit;
            }
            if (this._inflight.has(key)) return this._inflight.get(key);

            const run = (async () => {
                let events = [];
                try {
                    events = await Relays.fetch({ kinds: [0], authors: [key], limit: 4 }, 4000);
                } catch (_) {
                    return hit;
                }
                const newest = events
                    .filter(e => e && e.pubkey === key)
                    .sort((a, b) => (b.created_at || 0) - (a.created_at || 0))[0];
                const profile = newest ? readMetadata(newest) : null;
                const value = profile || { fetchedAt: Date.now(), at: 0 };
                remember(key, value);
                if (this.onChange) { try { this.onChange(key); } catch (_) { } }
                return value;
            })().finally(() => this._inflight.delete(key));

            this._inflight.set(key, run);
            return run;
        },

        /// Waits for the pool to have a socket before asking, so a profile is
        /// not written off as missing because the app had only just started.
        loadWhenConnected(pubkey, options) {
            if (Relays.connected > 0) return this.load(pubkey, options);
            return new Promise((resolve) => {
                let done = false;
                const settle = () => {
                    if (done) return;
                    done = true;
                    resolve(this.load(pubkey, options));
                };
                Relays.onStatus((n) => { if (n > 0) settle(); });
                setTimeout(settle, 6000);
            });
        },

        forget(pubkey) {
            const all = Store.read('profiles', {}) || {};
            delete all[String(pubkey || '')];
            Store.write('profiles', all);
        }
    };

    window.NymbotProfile = Profile;
})();
