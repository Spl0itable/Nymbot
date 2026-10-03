const CACHE = 'nymbot-shell-v83';
const SHELL = [
    '/app/',
    '/app/index.html',
    '/app/css/app.css',
    '/app/css/svg-frame.css',
    '/app/css/viewer.css',
    '/app/manifest.webmanifest',
    '/app/js/config.js',
    '/app/js/edge.js',
    '/app/js/i18n.js',
    '/app/js/vendor/ml-kem.js',
    '/app/js/vendor/nostr-tools.js',
    '/app/js/vendor/nym-crypto.js',
    '/app/js/store.js',
    '/app/js/identity.js',
    '/app/js/nip46.js',
    '/app/js/relays.js',
    '/app/js/pq.js',
    '/app/js/wire.js',
    '/app/js/api.js',
    '/app/js/anon.js',
    '/app/js/icons.js',
    '/app/js/avatar.js',
    '/app/js/profile.js',
    '/app/js/blossom.js',
    '/app/js/attach.js',
    '/app/js/pdftext.js',
    '/app/js/docs.js',
    '/app/js/commands.js',
    '/app/js/speech.js',
    '/app/js/dictate.js',
    '/app/js/chat.js',
    '/app/js/highlight.js',
    '/app/js/files.js',
    '/app/js/markdown.js',
    '/app/js/compose.js',
    '/app/js/artifacts.js',
    '/app/js/export.js',
    '/app/js/bots.js',
    '/app/js/gitapi.js',
    '/app/js/ngit.js',
    '/app/js/memory.js',
    '/app/js/free.js',
    '/app/js/sync.js',
    '/app/js/qr.js',
    '/app/js/caps.js',
    '/app/js/share.js',
    '/app/js/mention.js',
    '/app/js/picedit.js',
    '/app/js/vault.js',
    '/app/js/keybackup.js',
    '/app/js/notify.js',
    '/app/js/rewind.js',
    '/app/js/viewer.js',
    '/app/js/integrity.js',
    '/app/js/canary.js',
    '/app/js/apikeys.js',
    '/app/js/support.js',
    '/app/js/ui.js',
    '/app/share.html',
    '/app/js/share-view.js',
    '/app/css/share.css',
    '/app/js/research.js',
    '/app/js/team.js',
    '/app/js/transcripts.js',
    '/app/js/tasks.js',
    '/app/js/runs.js',
    '/app/js/background.js',
    '/app/js/ask.js',
    '/app/js/plan.js',
    '/app/js/skills.js',
    '/app/js/gift.js',
    '/app/js/connectors.js',
    '/app/js/gitrun.js',
    '/app/js/prwatch.js',
    '/app/js/runner.js',
    '/app/js/serverrun.js',
    '/app/js/sw-register.js',
    '/app/icons/nymbot-192.png',
    '/app/icons/nymbot-512.png',
    '/app/icons/nymbot-maskable-512.png'
];
const NETWORK_WAIT_MS = 4000;
const STATIC = /\.(?:png|svg|ico|webp|woff2?)$/;
const MEDIA_CACHE = 'nymbot-media-v1';
const MEDIA_MAX_ENTRIES = 600;
const MEDIA_MAX_BYTES = 100 * 1024 * 1024;
const MEDIA_ENTRY_MAX_BYTES = 25 * 1024 * 1024;
const MEDIA_DAY_MS = 24 * 3600 * 1000;
const MEDIA_MAX_AGE_MS = 7 * MEDIA_DAY_MS;
const MEDIA_IMMUTABLE_AGE_MS = 30 * MEDIA_DAY_MS;
const MEDIA_REVALIDATE_MS = MEDIA_DAY_MS;
const MEDIA_STAMP = 'x-nymbot-cached-at';
const MEDIA_SIZE = 'x-nymbot-size';
const MEDIA_IMMUTABLE = 'x-nymbot-immutable';
const MEDIA_API_ORIGINS = ['https://nymbot.ai'];
const MEDIA_BLOSSOM_HOSTS = ['blossom.band', 'blossom.primal.net', 'nostr.download'];
const MEDIA_TYPE = /^(?:image|video|audio)\//i;
const CONTENT_HASH = /\/([0-9a-f]{64})(?:\.[a-z0-9]{1,8})?$/i;
const SHARE_CACHE = 'nymbot-share-v1';
const SHARE_PATH = '/app/share-target';
const SHARE_MAX_FILES = 10;
const SHARE_FILE_MAX_BYTES = 50 * 1024 * 1024;
const SHARE_TOTAL_MAX_BYTES = 80 * 1024 * 1024;
const SHARE_TEXT_MAX = 100000;
const SHARE_NAME_MAX = 120;
const SHARE_TTL_MS = 3600 * 1000;
let mediaGeneration = 0;
let mediaPruning = null;
let mediaPruneAgain = false;
let mediaStartupPruned = false;
const mediaFilling = new Map();

function contentHash(url) {
    const m = CONTENT_HASH.exec(url.pathname);
    return m ? m[1].toLowerCase() : '';
}

function mediaRoute(url) {
    const api = url.origin === location.origin || MEDIA_API_ORIGINS.includes(url.origin);
    if (api && url.pathname === '/api/proxy') {
        const action = url.searchParams.get('action');
        if (action === 'favicon') return url.searchParams.get('host') ? { hash: '' } : null;
        const target = url.searchParams.get('url');
        if (action || !target) return null;
        try {
            const u = new URL(target);
            if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
            return { hash: contentHash(u) };
        } catch (_) {
            return null;
        }
    }
    if (url.origin === location.origin && url.pathname.startsWith('/images/')) return { hash: '' };
    if (url.protocol === 'https:' && !url.port && !url.username && !url.password && !url.search
        && MEDIA_BLOSSOM_HOSTS.includes(url.hostname)) {
        const hash = contentHash(url);
        return hash ? { hash, cors: true } : null;
    }
    return null;
}

function mediaStamp(res) {
    const t = Number(res && res.headers && res.headers.get(MEDIA_STAMP));
    return Number.isFinite(t) && t > 0 ? t : 0;
}

function mediaAge(res, now) {
    const t = mediaStamp(res);
    return t > 0 && t <= now + 60000 ? now - t : Infinity;
}

function mediaLimit(res) {
    return res.headers.get(MEDIA_IMMUTABLE) === '1' ? MEDIA_IMMUTABLE_AGE_MS : MEDIA_MAX_AGE_MS;
}

function mediaFresh(res, now) {
    return mediaAge(res, now) < mediaLimit(res);
}

function cacheableMedia(res) {
    return !!res && res.status === 200 && res.type !== 'opaque' && res.type !== 'error'
        && MEDIA_TYPE.test(res.headers.get('content-type') || '');
}

async function sha256Hex(buf) {
    const digest = await crypto.subtle.digest('SHA-256', buf);
    return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function readCapped(res, cap) {
    const declared = Number(res.headers.get('content-length'));
    if (Number.isFinite(declared) && declared > cap) return null;
    if (!res.body || typeof res.body.getReader !== 'function') {
        const buf = await res.arrayBuffer();
        return buf.byteLength > cap ? null : buf;
    }
    const reader = res.body.getReader();
    const parts = [];
    let size = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > cap) {
            reader.cancel().catch(() => { });
            return null;
        }
        parts.push(value);
    }
    const out = new Uint8Array(size);
    let at = 0;
    for (const p of parts) {
        out.set(p, at);
        at += p.byteLength;
    }
    return out.buffer;
}

async function pruneMedia() {
    const cache = await caches.open(MEDIA_CACHE);
    const keys = await cache.keys();
    const now = Date.now();
    const live = [];
    const drop = [];
    for (const k of keys) {
        const res = await cache.match(k);
        if (!res || !mediaFresh(res, now)) {
            drop.push(k);
            continue;
        }
        live.push({ k, t: mediaStamp(res), size: Number(res.headers.get(MEDIA_SIZE)) || 0 });
    }
    live.sort((a, b) => a.t - b.t);
    let count = live.length;
    let bytes = live.reduce((n, x) => n + x.size, 0);
    for (const x of live) {
        if (count <= MEDIA_MAX_ENTRIES && bytes <= MEDIA_MAX_BYTES) break;
        drop.push(x.k);
        count--;
        bytes -= x.size;
    }
    await Promise.all(drop.map(k => cache.delete(k)));
}

function trimMedia() {
    if (mediaPruning) {
        mediaPruneAgain = true;
        return mediaPruning;
    }
    mediaPruning = (async () => {
        try {
            do {
                mediaPruneAgain = false;
                await pruneMedia();
            } while (mediaPruneAgain);
        } catch (_) { }
        mediaPruning = null;
    })();
    return mediaPruning;
}

async function storeMedia(key, route, res) {
    const generation = mediaGeneration;
    try {
        const body = await readCapped(res, MEDIA_ENTRY_MAX_BYTES);
        if (!body || generation !== mediaGeneration) return;
        const headers = new Headers(res.headers);
        headers.set(MEDIA_STAMP, String(Date.now()));
        headers.set(MEDIA_SIZE, String(body.byteLength));
        if (route.hash && await sha256Hex(body) === route.hash) headers.set(MEDIA_IMMUTABLE, '1');
        else if (route.cors) return;
        else headers.delete(MEDIA_IMMUTABLE);
        const cache = await caches.open(MEDIA_CACHE);
        await cache.put(key, new Response(body, { status: 200, statusText: res.statusText, headers }));
        if (generation !== mediaGeneration) {
            await cache.delete(key);
            return;
        }
        await trimMedia();
    } catch (_) { }
}

function fetchMedia(request, url, route) {
    if (!route.cors || url.origin === location.origin) return fetch(request);
    return fetch(url.href, { mode: 'cors', credentials: 'omit', referrerPolicy: 'no-referrer' })
        .then(res => cacheableMedia(res) ? res : fetch(request), () => fetch(request));
}

function fillMedia(key, request, url, route, wait) {
    let run = mediaFilling.get(key);
    if (!run) {
        run = fetchMedia(request, url, route)
            .then((res) => {
                if (cacheableMedia(res)) wait(storeMedia(key, route, res.clone()));
                return res;
            })
            .finally(() => mediaFilling.delete(key));
        mediaFilling.set(key, run);
    }
    return run.then(res => res.clone());
}

function mediaRange(res, header) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(String(header || '').trim());
    if (!m || (!m[1] && !m[2])) return null;
    return res.arrayBuffer().then((buf) => {
        const size = buf.byteLength;
        let start;
        let end;
        if (!m[1]) {
            start = Math.max(0, size - Number(m[2]));
            end = size - 1;
        } else {
            start = Number(m[1]);
            end = m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
        }
        if (start >= size || start > end) return null;
        const headers = new Headers(res.headers);
        headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
        headers.set('Content-Length', String(end - start + 1));
        return new Response(buf.slice(start, end + 1), { status: 206, headers });
    });
}

async function serveMedia(event, url, route) {
    const request = event.request;
    const wait = (p) => { if (event.waitUntil) event.waitUntil(p.catch(() => { })); };
    const key = url.href;
    let hit;
    try {
        const cache = await caches.open(MEDIA_CACHE);
        hit = await cache.match(key, { ignoreVary: true });
    } catch (_) {
        hit = null;
    }
    const now = Date.now();
    const range = request.headers.get('range');
    if (hit && mediaFresh(hit, now)) {
        if (!hit.headers.get(MEDIA_IMMUTABLE) && mediaAge(hit, now) > MEDIA_REVALIDATE_MS) {
            wait(fillMedia(key, new Request(url.href, { credentials: 'omit', referrerPolicy: 'no-referrer' }), url, route, wait));
        }
        if (!range) return hit;
        const part = await mediaRange(hit, range).catch(() => null);
        if (part) return part;
        return fetch(request);
    }
    if (range) {
        if (route.hash) wait(fillMedia(key, new Request(url.href, { credentials: 'omit', referrerPolicy: 'no-referrer' }), url, route, wait));
        return fetch(request);
    }
    try {
        return await fillMedia(key, request, url, route, wait);
    } catch (err) {
        if (hit) return hit;
        throw err;
    }
}

function wipeMedia() {
    mediaGeneration++;
    return caches.delete(MEDIA_CACHE).catch(() => false);
}

function shareId() {
    return Array.from(crypto.getRandomValues(new Uint8Array(16))).map(b => b.toString(16).padStart(2, '0')).join('');
}

function shareName(raw) {
    let name = String(raw || '').split(/[\\/]/).pop();
    name = name.replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '');
    name = name.trim().replace(/^\.+/, '').trim();
    if (name.length > SHARE_NAME_MAX) {
        const dot = name.lastIndexOf('.');
        const ext = dot > 0 && name.length - dot <= 10 ? name.slice(dot) : '';
        name = name.slice(0, SHARE_NAME_MAX - ext.length) + ext;
    }
    return name || 'shared';
}

function shareText(form) {
    const parts = [];
    for (const key of ['title', 'text', 'url']) {
        const value = form.get(key);
        if (typeof value !== 'string') continue;
        const trimmed = value.trim();
        if (!trimmed || parts.some(p => p.includes(trimmed))) continue;
        parts.push(trimmed);
    }
    return parts.join('\n\n').slice(0, SHARE_TEXT_MAX);
}

async function pruneShares(cache, now) {
    for (const key of await cache.keys()) {
        const url = new URL(key.url);
        if (!/^\/app\/share-target\/[0-9a-f]{32}$/.test(url.pathname)) continue;
        const res = await cache.match(key);
        let at = 0;
        try { at = Number((await res.json()).at) || 0; } catch (_) { at = 0; }
        if (now - at <= SHARE_TTL_MS) continue;
        const prefix = url.pathname + '/';
        await Promise.all((await cache.keys())
            .filter(k => k.url === key.url || new URL(k.url).pathname.startsWith(prefix))
            .map(k => cache.delete(k)));
    }
}

async function stashShare(request) {
    const form = await request.formData();
    const text = shareText(form);
    const picked = [];
    let total = 0;
    for (const file of form.getAll('files')) {
        if (!file || typeof file !== 'object' || typeof file.arrayBuffer !== 'function') continue;
        if (picked.length >= SHARE_MAX_FILES) break;
        const size = Number(file.size) || 0;
        if (size <= 0 || size > SHARE_FILE_MAX_BYTES || total + size > SHARE_TOTAL_MAX_BYTES) continue;
        total += size;
        picked.push(file);
    }
    if (!text && !picked.length) return '';
    const id = shareId();
    const base = new URL(SHARE_PATH + '/' + id, location.origin).href;
    const cache = await caches.open(SHARE_CACHE);
    await pruneShares(cache, Date.now()).catch(() => { });
    const files = [];
    for (let i = 0; i < picked.length; i++) {
        const file = picked[i];
        const type = String(file.type || '');
        await cache.put(base + '/' + i, new Response(file, { headers: { 'content-type': type || 'application/octet-stream' } }));
        files.push({ name: shareName(file.name), type, size: Number(file.size) || 0 });
    }
    await cache.put(base, new Response(JSON.stringify({ at: Date.now(), text, files }), { headers: { 'content-type': 'application/json' } }));
    return id;
}

async function receiveShare(request) {
    let id = '';
    try { id = await stashShare(request); } catch (_) { id = ''; }
    const target = new URL('/app/' + (id ? '#share=' + id : ''), location.origin).href;
    return Response.redirect(target, 303);
}

self.addEventListener('install', (e) => {
    e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
    e.waitUntil(caches.keys()
        .then(keys => Promise.all(keys.filter(k => k !== CACHE && k !== MEDIA_CACHE && k !== SHARE_CACHE && k !== NOTIFY_CACHE).map(k => caches.delete(k))))
        .then(() => {
            mediaStartupPruned = true;
            return trimMedia();
        })
        .then(() => self.clients.claim()));
});

self.addEventListener('message', (e) => {
    if (e.data && e.data.type === 'nymbot-wipe-media') {
        const done = wipeMedia();
        if (e.waitUntil) e.waitUntil(done);
    }
});

const CHAT_RE = /^[A-Za-z0-9_-]{1,64}$/;
const ASKED_RE = /^[0-9a-f]{64}$/;
const NOTIFY_CACHE = 'nymbot-notify';
const NOTIFY_TEXT = '/app/notify-text.json';
const RUN_STATES = ['paused', 'approval', 'stopped', 'failed', 'due', 'disabled', 'question', 'expired', 'ci-failed', 'review', 'pr'];

function stateText(state) {
    if (!RUN_STATES.includes(state)) return Promise.resolve('');
    return caches.open(NOTIFY_CACHE)
        .then(c => c.match(NOTIFY_TEXT))
        .then(r => (r ? r.json() : null))
        .then(words => (words && typeof words[state] === 'string' ? words[state].slice(0, 120) : ''))
        .catch(() => '');
}

function appClients() {
    return self.clients.matchAll({ type: 'window', includeUncontrolled: true })
        .then(list => list.filter(c => new URL(c.url).pathname.startsWith('/app/')));
}

self.addEventListener('push', (e) => {
    let data = {};
    try { data = e.data ? e.data.json() : {}; } catch (_) { data = {}; }
    const chat = typeof data.chat === 'string' && CHAT_RE.test(data.chat) ? data.chat : '';
    const asked = typeof data.asked === 'string' && ASKED_RE.test(data.asked) ? data.asked : '';
    const title = typeof data.title === 'string' && data.title ? data.title.slice(0, 60) : 'Nymbot';
    const sent = typeof data.body === 'string' && data.body ? data.body.slice(0, 120) : '';
    const state = typeof data.state === 'string' ? data.state : '';
    e.waitUntil(appClients().then((list) => {
        if (list.some(c => c.focused && c.visibilityState === 'visible')) return undefined;
        return stateText(state).then(said => self.registration.showNotification(title, {
            body: said || sent,
            tag: chat ? 'reply-' + chat + (asked ? '-' + asked.slice(0, 16) : '') : 'reply',
            data: asked ? { chat, asked } : { chat },
            icon: '/app/icons/nymbot-192.png',
            badge: '/app/icons/nymbot-192.png'
        }));
    }));
});

self.addEventListener('notificationclick', (e) => {
    const data = (e.notification && e.notification.data) || {};
    const chat = CHAT_RE.test(data.chat || '') ? data.chat : '';
    const asked = chat && ASKED_RE.test(data.asked || '') ? data.asked : '';
    e.notification.close();
    e.waitUntil(appClients().then((list) => {
        const open = list[0];
        if (open) {
            if (chat) open.postMessage(asked ? { type: 'open-chat', chat, asked } : { type: 'open-chat', chat });
            return open.focus ? open.focus() : undefined;
        }
        return self.clients.openWindow('/app/' + (chat ? '#chat=' + chat + (asked ? '&asked=' + asked : '') : ''));
    }));
});

function keep(request, res) {
    if (res && res.ok && res.type === 'basic') {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(request, copy)).catch(() => { });
    }
    return res;
}

function staleWhileRevalidate(request) {
    return caches.match(request).then((hit) => {
        const fresh = fetch(request).then(res => keep(request, res));
        if (hit) {
            fresh.catch(() => { });
            return hit;
        }
        return fresh.catch(() => Response.error());
    });
}

function networkFirst(request, navigate) {
    const fallback = () => caches.match(request)
        .then(hit => hit || (navigate ? caches.match('/app/index.html') : undefined));
    const network = fetch(request).then(res => keep(request, res));
    return new Promise((resolve) => {
        let done = false;
        const finish = (res) => {
            if (done || !res) return;
            done = true;
            resolve(res);
        };
        network.then(finish, () => fallback().then(hit => finish(hit || Response.error()), () => finish(Response.error())));
        new Promise((wait) => setTimeout(wait, NETWORK_WAIT_MS))
            .then(fallback)
            .then(finish, () => { });
    });
}

self.addEventListener('fetch', (e) => {
    const url = new URL(e.request.url);
    if (e.request.method === 'POST' && url.origin === location.origin && url.pathname === SHARE_PATH) {
        e.respondWith(receiveShare(e.request));
        return;
    }
    if (e.request.method !== 'GET') return;
    const media = e.request.cache === 'no-store' ? null : mediaRoute(url);
    if (media) {
        if (!mediaStartupPruned) {
            mediaStartupPruned = true;
            if (e.waitUntil) e.waitUntil(trimMedia());
        }
        e.respondWith(serveMedia(e, url, media));
        return;
    }
    if (url.origin !== location.origin) return;
    if (!url.pathname.startsWith('/app/')) return;
    if (e.request.cache === 'no-store') return;
    if (url.searchParams.has('edge-probe') || url.searchParams.has('edge-reload')) return;
    const navigate = e.request.mode === 'navigate';
    if (!navigate && STATIC.test(url.pathname)) {
        e.respondWith(staleWhileRevalidate(e.request));
        return;
    }
    e.respondWith(networkFirst(e.request, navigate));
});
