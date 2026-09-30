(function () {
    'use strict';

    const Store = window.NymbotStore;
    const Relays = window.NymbotRelays;
    const Avatar = window.NymbotAvatar;
    const NT = () => window.NostrTools;

    const MAX_AGE_MS = 6 * 3600 * 1000;
    const SAFE_IMAGE = /^https:\/\/[^\s"'<>]+$/i;
    const NICKNAME_MAX = 32;
    const INVISIBLE = /[\u0000-\u001F\u007F-\u009F\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180F\u200B-\u200F\u2028-\u202E\u2060-\u206F\u3164\uFEFF\uFFA0\uFFF9-\uFFFB\u{E0000}-\u{E007F}]/gu;

    function cleanNickname(value) {
        const text = String(value == null ? '' : value)
            .normalize('NFC')
            .replace(/[\t\n\v\f\r\u0085\u2028\u2029]/g, ' ')
            .replace(INVISIBLE, '')
            .replace(/\s+/g, ' ')
            .trim();
        return Array.from(text).slice(0, NICKNAME_MAX).join('').trim();
    }

    function shown(picture) {
        const C = window.NymbotConfig || {};
        const B = window.NymbotBlossom;
        if (!picture || !C.apiHost) return picture;
        let host;
        try { host = new URL(picture).hostname.toLowerCase(); } catch (_) { return picture; }
        const direct = [C.apiHost].concat(B && Array.isArray(B.HOSTS) ? B.HOSTS : []).some((h) => {
            try { return new URL(/^https:/.test(h) ? h : 'https://' + h).hostname.toLowerCase() === host; } catch (_) { return false; }
        });
        return direct ? picture : `https://${C.apiHost}/api/proxy?url=${encodeURIComponent(picture)}`;
    }

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

    /// The event's own hash and signature decide, never the relay; the same test applies to the D1 mirror.
    function authentic(event, pubkey) {
        try {
            const T = NT();
            if (!event || event.kind !== 0 || event.pubkey !== pubkey) return false;
            if (T.getEventHash(event) !== event.id) return false;
            return T.verifyEvent(event);
        } catch (_) { return false; }
    }

    /// Asked before the relays because it answers in one round trip.
    async function fromD1(pubkey) {
        const Sync = window.NymbotSync;
        if (!Sync || typeof Sync.profileEvents !== 'function') return null;
        let events;
        try { events = await Sync.profileEvents([pubkey]); } catch (_) { return null; }
        const event = events && events[pubkey];
        if (!event || !authentic(event, pubkey)) return null;
        return readMetadata(event);
    }

    function whenConnected() {
        if (Relays.connected > 0) return Promise.resolve();
        return new Promise((resolve) => {
            let done = false;
            const settle = () => { if (done) return; done = true; resolve(); };
            Relays.onStatus((n) => { if (n > 0) settle(); });
            setTimeout(settle, 6000);
        });
    }

    const Profile = {
        NICKNAME_MAX,
        cleanNickname,
        onChange: null,
        _inflight: new Map(),

        /// Never blocks, so a slow or unreachable relay costs nothing at render time.
        for(pubkey) {
            const key = String(pubkey || '');
            const hit = cached(key);
            const fallbackName = Avatar.nymName(key);
            return {
                pubkey: key,
                name: (hit && hit.name) || fallbackName,
                nip05: (hit && hit.nip05) || '',
                about: (hit && hit.about) || '',
                avatar: (hit && hit.picture && shown(hit.picture)) || Avatar.identicon(key),
                hasProfile: !!(hit && (hit.name || hit.picture)),
                colour: Avatar.colorClass(key)
            };
        },

        /// A miss is cached too, so a key with no profile is not re-asked on every render.
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
                let profile = await fromD1(key);
                if (!profile) {
                    if (opts.wait) await whenConnected();
                    let events = [];
                    try {
                        events = await Relays.fetch({ kinds: [0], authors: [key], limit: 4 }, 4000);
                    } catch (_) {
                        return hit;
                    }
                    const newest = events
                        .filter(e => authentic(e, key))
                        .sort((a, b) => (b.created_at || 0) - (a.created_at || 0))[0];
                    profile = newest ? readMetadata(newest) : null;
                }
                const value = profile || { fetchedAt: Date.now(), at: 0 };
                remember(key, value);
                if (this.onChange) { try { this.onChange(key); } catch (_) { } }
                return value;
            })().finally(() => this._inflight.delete(key));

            this._inflight.set(key, run);
            return run;
        },

        /// Only a mirror miss falls through to the relays, and only that waits for a socket.
        loadWhenConnected(pubkey, options) {
            return this.load(pubkey, Object.assign({}, options, { wait: true }));
        },

        forget(pubkey) {
            const all = Store.read('profiles', {}) || {};
            delete all[String(pubkey || '')];
            Store.write('profiles', all);
        }
    };

    window.NymbotProfile = Profile;
})();
