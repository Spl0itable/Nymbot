// Caches the shell so the app opens offline. Conversations are read from local
// storage, so what you have already said is there without a network; a reply is
// not, because the model is not on the device.
const CACHE = 'nymbot-shell-v12';
const SHELL = [
    '/app/',
    '/app/index.html',
    '/app/css/app.css',
    '/app/manifest.webmanifest',
    '/app/js/config.js',
    '/app/js/i18n.js',
    '/app/js/vendor/ml-kem.js',
    '/app/js/vendor/nostr-tools.js',
    '/app/js/vendor/nym-crypto.js',
    '/app/js/store.js',
    '/app/js/identity.js',
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
    '/app/js/commands.js',
    '/app/js/speech.js',
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
    '/app/js/ui.js'
];

self.addEventListener('install', (e) => {
    e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
    e.waitUntil(caches.keys()
        .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
        .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
    const url = new URL(e.request.url);
    if (e.request.method !== 'GET' || url.origin !== location.origin) return;
    if (!url.pathname.startsWith('/app/')) return;
    // Network first, so a deploy is picked up; the cache is the offline floor.
    e.respondWith(
        fetch(e.request)
            .then((res) => {
                const copy = res.clone();
                caches.open(CACHE).then(c => c.put(e.request, copy)).catch(() => { });
                return res;
            })
            .catch(() => caches.match(e.request).then(hit => hit || caches.match('/app/index.html')))
    );
});
