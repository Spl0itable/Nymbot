// Caches the shell so the app opens offline. Conversations are read from local
// storage, so what you have already said is there without a network; a reply is
// not, because the model is not on the device.
const CACHE = 'nymbot-shell-v39';
const SHELL = [
    '/app/',
    '/app/index.html',
    '/app/css/app.css',
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
    '/app/js/ui.js',
    '/app/share.html',
    '/app/js/share-view.js',
    '/app/css/share.css',
    '/app/js/research.js',
    '/app/js/team.js',
    '/app/js/gift.js',
    '/app/js/connectors.js',
    '/app/js/gitrun.js',
    '/app/js/runner.js',
    '/app/js/serverrun.js',
    '/app/js/sw-register.js',
    '/app/icons/nymbot-192.png',
    '/app/icons/nymbot-512.png',
    '/app/icons/nymbot-maskable-512.png'
];
const NETWORK_WAIT_MS = 4000;
const STATIC = /\.(?:js|css|png|svg|ico|webp|woff2?)$/;

self.addEventListener('install', (e) => {
    e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
    e.waitUntil(caches.keys()
        .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
        .then(() => self.clients.claim()));
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
    if (e.request.method !== 'GET' || url.origin !== location.origin) return;
    if (!url.pathname.startsWith('/app/')) return;
    if (url.searchParams.has('edge-probe') || url.searchParams.has('edge-reload')) return;
    const navigate = e.request.mode === 'navigate';
    if (!navigate && STATIC.test(url.pathname)) {
        e.respondWith(staleWhileRevalidate(e.request));
        return;
    }
    e.respondWith(networkFirst(e.request, navigate));
});
