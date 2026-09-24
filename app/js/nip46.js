(function () {
    'use strict';

    const NT = () => window.NostrTools;

    const KIND = 24133;
    const DEFAULT_RELAY = 'wss://relay.primal.net';
    const PERMS = [
        'get_public_key',
        'sign_event:27235',
        'sign_event:13',
        'sign_event:30078',
        'sign_event:1',
        'nip44_encrypt',
        'nip44_decrypt'
    ];
    const TIMEOUT_MS = 60000;
    const PAIRING_MS = 300000;
    const SLOW_MS = 1000;
    const SEEN_MAX = 500;

    const waitingListeners = new Set();
    const authListeners = new Set();
    let late = 0;

    function hex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    function unhex(str) {
        const out = new Uint8Array(str.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16);
        return out;
    }

    function randomHex(n) {
        return hex(crypto.getRandomValues(new Uint8Array(n)));
    }

    function failure(message) {
        const e = new Error(message);
        e.signer = true;
        return e;
    }

    function isKey(value) {
        return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
    }

    function canonicalRelay(url) {
        const trimmed = String(url || '').trim();
        return trimmed.endsWith('/') ? trimmed.slice(0, -1) : trimmed;
    }

    function validRelay(url) {
        try {
            const u = new URL(String(url || '').trim());
            return (u.protocol === 'wss:' || u.protocol === 'ws:') && !!u.hostname;
        } catch (_) {
            return false;
        }
    }

    function encode(value) {
        return encodeURIComponent(value).replace(/%20/g, '+');
    }

    function decode(value) {
        try { return decodeURIComponent(String(value).replace(/\+/g, ' ')); } catch (_) { return ''; }
    }

    function parseBunker(input) {
        const text = String(input || '').trim();
        if (!text.toLowerCase().startsWith('bunker://')) {
            throw failure(t('Paste a bunker:// link from your signer.'));
        }
        const rest = text.slice('bunker://'.length);
        const q = rest.indexOf('?');
        const host = (q < 0 ? rest : rest.slice(0, q)).trim().toLowerCase();
        if (!isKey(host)) throw failure(t('That bunker link does not name a valid signer key.'));
        const relays = [];
        let secret = null;
        if (q >= 0) {
            for (const part of rest.slice(q + 1).split('&')) {
                if (!part) continue;
                const eq = part.indexOf('=');
                const key = eq < 0 ? part : part.slice(0, eq);
                const value = decode(eq < 0 ? '' : part.slice(eq + 1));
                if (key === 'relay' && validRelay(value)) {
                    const relay = canonicalRelay(value);
                    if (!relays.includes(relay)) relays.push(relay);
                } else if (key === 'secret' && value) {
                    secret = value;
                }
            }
        }
        if (!relays.length) throw failure(t('That bunker link names no relay.'));
        return { pubkey: host, relays, secret };
    }

    function verified(event) {
        try {
            const T = NT();
            return typeof event.id === 'string'
                && T.getEventHash(event) === event.id
                && !!T.verifyEvent(event);
        } catch (_) {
            return false;
        }
    }

    function checkSigned(asked, got) {
        const same = !!got && typeof got === 'object'
            && got.pubkey === asked.pubkey
            && got.kind === asked.kind
            && got.created_at === asked.created_at
            && got.content === asked.content
            && JSON.stringify(got.tags) === JSON.stringify(asked.tags);
        const clean = same ? {
            id: got.id,
            pubkey: got.pubkey,
            created_at: got.created_at,
            kind: got.kind,
            tags: got.tags,
            content: got.content,
            sig: got.sig
        } : null;
        if (!clean || typeof clean.sig !== 'string' || !verified(clean)) {
            throw failure(t('Your signer returned a signature that does not match, so it was not used.'));
        }
        return clean;
    }

    function emitWaiting() {
        for (const fn of waitingListeners) { try { fn(late > 0); } catch (_) { } }
    }

    function emitAuth(url) {
        for (const fn of authListeners) { try { fn(url); } catch (_) { } }
    }

    function client(opts) {
        const sk = opts.sk;
        const clientPubkey = NT().getPublicKey(sk);
        const timeout = opts.timeout || TIMEOUT_MS;
        let remote = opts.remote || null;
        let user = opts.user || null;
        let conversation = null;
        let conversationFor = null;
        let subId = '';
        let counter = 0;
        let closed = false;
        let pairing = null;
        let sawBareAck = false;
        let tail = Promise.resolve();
        const open = new Map();
        const pending = new Map();
        const seen = new Set();

        const keyFor = (peer) => {
            if (conversationFor === peer && conversation) return conversation;
            const ck = NT().nip44.getConversationKey(sk, peer);
            if (peer === remote) {
                conversation = ck;
                conversationFor = peer;
            }
            return ck;
        };

        const send = (entry, frame) => {
            if (entry.ws.readyState === 1) {
                try { entry.ws.send(frame); } catch (_) { }
            } else if (entry.ws.readyState === 0) {
                entry.outbox.push(frame);
            }
        };

        const ensureOpen = () => {
            if (closed) throw failure(t('The signer connection is closed.'));
            if (!subId) subId = 'nymbot-nip46-' + randomHex(6);
            for (const relay of api.relays) {
                if (open.has(relay)) continue;
                let ws;
                try { ws = new WebSocket(relay); } catch (_) { continue; }
                const entry = { ws, outbox: [] };
                open.set(relay, entry);
                ws.addEventListener('open', () => {
                    const queued = entry.outbox.splice(0);
                    for (const frame of queued) {
                        try { ws.send(frame); } catch (_) { }
                    }
                });
                ws.addEventListener('message', (m) => onFrame(m.data));
                ws.addEventListener('error', () => { });
                ws.addEventListener('close', () => {
                    if (open.get(relay) === entry) open.delete(relay);
                });
                send(entry, JSON.stringify(['REQ', subId, {
                    kinds: [KIND],
                    '#p': [clientPubkey],
                    since: Math.floor(Date.now() / 1000) - 10
                }]));
            }
            if (!open.size) throw failure(t('Could not reach the signer relay.'));
        };

        const onFrame = (data) => {
            let frame;
            try { frame = JSON.parse(data); } catch (_) { return; }
            if (!Array.isArray(frame) || frame.length < 3 || frame[0] !== 'EVENT') return;
            if (frame[1] !== subId || !frame[2] || typeof frame[2] !== 'object') return;
            try { onEvent(frame[2]); } catch (_) { }
        };

        const onEvent = (event) => {
            if (event.kind !== KIND || !isKey(event.pubkey)) return;
            const tags = Array.isArray(event.tags) ? event.tags : [];
            if (!tags.some(x => Array.isArray(x) && x[0] === 'p' && x[1] === clientPubkey)) return;
            if (remote && event.pubkey !== remote) return;
            if (typeof event.id !== 'string' || seen.has(event.id) || !verified(event)) return;
            seen.add(event.id);
            if (seen.size > SEEN_MAX) seen.delete(seen.values().next().value);
            let reply;
            try {
                const T = NT();
                reply = JSON.parse(T.nip44.decrypt(event.content, keyFor(event.pubkey)));
            } catch (_) {
                return;
            }
            if (!reply || typeof reply !== 'object' || Array.isArray(reply)) return;
            const result = reply.result;
            const error = reply.error;
            if (!remote) {
                if (!api.secret || !pairing || pairing.done) return;
                if (typeof result === 'string' && result === api.secret) {
                    remote = event.pubkey;
                    pairing.done = true;
                    pairing.resolve(event.pubkey);
                } else if (result === 'ack') {
                    sawBareAck = true;
                }
                return;
            }
            const id = reply.id;
            if (typeof id !== 'string') return;
            const waiting = pending.get(id);
            if (!waiting) return;
            if (result === 'auth_url') {
                let url = null;
                try { url = typeof error === 'string' ? new URL(error) : null; } catch (_) { url = null; }
                if (url && url.protocol === 'https:') {
                    clearTimeout(waiting.timer);
                    waiting.timer = setTimeout(() => expire(id), timeout * 3);
                    emitAuth(url.href);
                }
                return;
            }
            pending.delete(id);
            clearTimeout(waiting.timer);
            if (typeof error === 'string' && error) {
                waiting.reject(failure(t('Your signer declined: {reason}', { reason: error })));
            } else {
                waiting.resolve(result);
            }
        };

        const expire = (id) => {
            const waiting = pending.get(id);
            if (!waiting) return;
            pending.delete(id);
            waiting.reject(failure(t('Your signer did not answer in time.')));
        };

        const request = (method, params) => {
            if (!remote) return Promise.reject(failure(t('No signer is connected.')));
            try { ensureOpen(); } catch (e) { return Promise.reject(e); }
            const T = NT();
            const id = randomHex(8) + (counter++);
            const content = T.nip44.encrypt(JSON.stringify({ id, method, params }), keyFor(remote));
            const event = T.finalizeEvent({
                kind: KIND,
                created_at: Math.floor(Date.now() / 1000),
                tags: [['p', remote]],
                content
            }, sk);
            return new Promise((resolve, reject) => {
                pending.set(id, { resolve, reject, timer: setTimeout(() => expire(id), timeout) });
                const frame = JSON.stringify(['EVENT', event]);
                for (const entry of Array.from(open.values())) send(entry, frame);
            });
        };

        const queued = (body) => {
            let counted = false;
            const timer = setTimeout(() => {
                counted = true;
                late++;
                emitWaiting();
            }, SLOW_MS);
            const run = tail.then(body);
            tail = run.then(() => { }, () => { });
            return run.finally(() => {
                clearTimeout(timer);
                if (counted) late--;
                emitWaiting();
            });
        };

        const fetchUser = async () => {
            const result = await request('get_public_key', []);
            const text = typeof result === 'string' ? result.trim().toLowerCase() : '';
            let key = text;
            if (text.startsWith('npub1')) {
                try {
                    const d = NT().nip19.decode(text);
                    key = d && d.type === 'npub' ? d.data : null;
                } catch (_) {
                    key = null;
                }
            }
            let onCurve = false;
            if (isKey(key)) {
                try { NT().nip44.getConversationKey(sk, key); onCurve = true; } catch (_) { onCurve = false; }
            }
            if (!onCurve) throw failure(t('The signer returned a public key that is not valid.'));
            user = key;
        };

        const api = {
            relays: opts.relays.slice(),
            secret: opts.secret || null,
            clientPubkey,
            isRemote: true,
            method: 'nip46',

            get pubkey() { return user || ''; },
            get remotePubkey() { return remote; },
            get closed() { return closed; },
            get sockets() { return open.size; },

            get session() {
                return {
                    method: 'nip46',
                    client: hex(sk),
                    remote,
                    relays: api.relays.slice(),
                    pubkey: user
                };
            },

            get connectUri() {
                const params = api.relays.map(r => 'relay=' + encode(r)).concat([
                    'secret=' + encode(api.secret || ''),
                    'perms=' + encode(PERMS.join(',')),
                    'name=Nymbot',
                    'url=' + encode('https://nymbot.ai'),
                    'metadata=' + encode(JSON.stringify({ name: 'Nymbot' }))
                ]);
                return 'nostrconnect://' + clientPubkey + '?' + params.join('&');
            },

            async waitForSigner(within) {
                if (!api.secret) throw new Error('not an offer');
                if (!pairing) {
                    pairing = { done: false };
                    pairing.promise = new Promise((resolve, reject) => {
                        pairing.resolve = resolve;
                        pairing.reject = reject;
                    });
                }
                ensureOpen();
                const limit = within || PAIRING_MS;
                let timer = null;
                const expired = new Promise((_, reject) => {
                    timer = setTimeout(() => reject(failure(sawBareAck
                        ? t('A signer answered without the connection secret, so Nymbot did not trust it. Update your signer app, or paste a bunker:// link instead.')
                        : t('No signer answered in time. Try again.'))), limit);
                });
                try {
                    await Promise.race([pairing.promise, expired]);
                } finally {
                    clearTimeout(timer);
                }
                await fetchUser();
            },

            async connectBunker(secret) {
                const result = await request('connect', secret
                    ? [remote, secret, PERMS.join(',')]
                    : [remote]);
                if (result !== 'ack' && (!secret || result !== secret)) {
                    throw failure(t('The signer did not accept the connection.'));
                }
                await fetchUser();
            },

            sign(event) {
                return queued(async () => {
                    const asked = {
                        pubkey: user,
                        created_at: Number.isInteger(event.created_at) ? event.created_at : Math.floor(Date.now() / 1000),
                        kind: event.kind,
                        tags: Array.isArray(event.tags) ? event.tags : [],
                        content: typeof event.content === 'string' ? event.content : ''
                    };
                    const result = await request('sign_event', [JSON.stringify(asked)]);
                    let parsed = result;
                    if (typeof result === 'string') {
                        try { parsed = JSON.parse(result); } catch (_) { parsed = null; }
                    }
                    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
                        throw failure(t('Your signer returned something that is not a signed event.'));
                    }
                    return checkSigned(asked, parsed);
                });
            },

            nip44Encrypt(peer, plaintext) {
                return queued(async () => {
                    const result = await request('nip44_encrypt', [peer, plaintext]);
                    if (typeof result !== 'string' || !result) throw failure(t('Your signer could not encrypt that.'));
                    return result;
                });
            },

            nip44Decrypt(peer, payload) {
                return queued(async () => {
                    const result = await request('nip44_decrypt', [peer, payload]);
                    if (typeof result !== 'string') throw failure(t('Your signer could not decrypt that.'));
                    return result;
                });
            },

            close(reason) {
                if (closed) return;
                closed = true;
                for (const [id, waiting] of Array.from(pending)) {
                    pending.delete(id);
                    clearTimeout(waiting.timer);
                    waiting.reject(failure(t('The signer connection is closed.')));
                }
                if (pairing && !pairing.done) {
                    pairing.done = true;
                    pairing.reject(failure(reason || t('Canceled.')));
                }
                for (const entry of Array.from(open.values())) {
                    send(entry, JSON.stringify(['CLOSE', subId]));
                    try { entry.ws.close(); } catch (_) { }
                }
                open.clear();
            }
        };
        return api;
    }

    function cleanRelays(list) {
        const out = [];
        for (const r of list || []) {
            if (!validRelay(r)) continue;
            const relay = canonicalRelay(r);
            if (!out.includes(relay)) out.push(relay);
        }
        return out;
    }

    const Nip46 = {
        KIND,
        DEFAULT_RELAY,
        PERMS,
        TIMEOUT_MS,
        PAIRING_MS,
        parseBunker,
        canonicalRelay,
        validRelay,
        checkSigned,

        offer(options) {
            const o = options || {};
            const relays = cleanRelays(o.relays || [DEFAULT_RELAY]);
            if (!relays.length) throw failure(t('Enter a relay address that starts with wss://.'));
            return client({
                sk: NT().generateSecretKey(),
                relays,
                secret: randomHex(16),
                timeout: o.timeout
            });
        },

        async bunker(link, options) {
            const o = options || {};
            const parsed = parseBunker(link);
            const c = client({
                sk: NT().generateSecretKey(),
                relays: parsed.relays,
                remote: parsed.pubkey,
                timeout: o.timeout
            });
            if (typeof o.started === 'function') o.started(c);
            try {
                await c.connectBunker(parsed.secret);
                return c;
            } catch (e) {
                c.close();
                throw e;
            }
        },

        restore(session, options) {
            try {
                if (!session || session.method !== 'nip46') return null;
                const relays = cleanRelays(session.relays);
                if (!/^[0-9a-f]{64}$/.test(session.client || '') || !isKey(session.remote)
                    || !isKey(session.pubkey) || !relays.length) return null;
                return client({
                    sk: unhex(session.client),
                    relays,
                    remote: session.remote,
                    user: session.pubkey,
                    timeout: options && options.timeout
                });
            } catch (_) {
                return null;
            }
        },

        onWaiting(fn) { waitingListeners.add(fn); },
        onAuthUrl(fn) { authListeners.add(fn); },
        get waiting() { return late > 0; }
    };

    window.NymbotNip46 = Nip46;
})();
