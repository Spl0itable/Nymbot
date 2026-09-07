(function () {
    'use strict';

    const ADJECTIVES = [
        'quantum', 'neon', 'cyber', 'shadow', 'plasma',
        'echo', 'nexus', 'void', 'flux', 'ghost',
        'phantom', 'stealth', 'cryptic', 'dark', 'neural',
        'binary', 'matrix', 'digital', 'virtual', 'zero',
        'null', 'anon', 'masked', 'hidden', 'cipher',
        'enigma', 'spectral', 'rogue', 'omega', 'alpha',
        'delta', 'sigma', 'vortex', 'turbo', 'razor',
        'blade', 'frost', 'storm', 'glitch', 'pixel',
        'hyper', 'proto', 'nano', 'micro', 'ultra',
        'silent', 'feral', 'lucid', 'primal', 'astral',
        'cobalt', 'onyx', 'crimson', 'obsidian', 'iron',
        'solar', 'lunar', 'stellar', 'cosmic', 'atomic',
        'toxic', 'rapid', 'swift', 'fierce'
    ];

    const NOUNS = [
        'ghost', 'nomad', 'drift', 'pulse', 'wave',
        'spark', 'node', 'byte', 'mesh', 'link',
        'runner', 'hacker', 'coder', 'agent', 'proxy',
        'daemon', 'virus', 'worm', 'bot', 'droid',
        'reaper', 'shadow', 'wraith', 'specter', 'shade',
        'entity', 'unit', 'core', 'nexus', 'cypher',
        'breach', 'exploit', 'overflow', 'inject', 'root',
        'kernel', 'shell', 'terminal', 'console', 'script',
        'raven', 'wolf', 'viper', 'hawk', 'lynx',
        'phantom', 'signal', 'cipher', 'vector', 'forge',
        'circuit', 'photon', 'glider', 'shard', 'vault',
        'beacon', 'torrent', 'crypt', 'grid', 'orbit'
    ];

    function fnv(key) {
        let h = 2166136261 >>> 0;
        const s = String(key == null ? '' : key);
        for (let i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i);
            h = Math.imul(h, 16777619) >>> 0;
        }
        return h;
    }

    function rng(seed) {
        let s = seed || 1;
        return () => {
            s = (s + 0x6D2B79F5) >>> 0;
            let x = Math.imul(s ^ (s >>> 15), 1 | s);
            x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
            return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
        };
    }

    const cache = new Map();

    function identicon(seed) {
        const key = String(seed == null ? '' : seed);
        const hit = cache.get(key);
        if (hit) return hit;

        const rand = rng(fnv(key));
        const hue = Math.floor(rand() * 360);
        const sat = 60 + Math.floor(rand() * 25);
        const light = 50 + Math.floor(rand() * 15);
        const fg = `hsl(${hue},${sat}%,${light}%)`;
        const bg = `hsl(${(hue + 180) % 360},25%,18%)`;

        const cell = 16;
        const cols = 5;
        const rows = 5;
        const half = Math.ceil(cols / 2);
        let rects = '';
        for (let y = 0; y < rows; y++) {
            for (let x = 0; x < half; x++) {
                if (rand() < 0.5) {
                    rects += `<rect x="${x * cell}" y="${y * cell}" width="${cell}" height="${cell}"/>`;
                    const mirror = cols - 1 - x;
                    if (mirror !== x) {
                        rects += `<rect x="${mirror * cell}" y="${y * cell}" width="${cell}" height="${cell}"/>`;
                    }
                }
            }
        }

        const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80" width="80" height="80" shape-rendering="crispEdges"><rect width="80" height="80" fill="${bg}"/><g fill="${fg}">${rects}</g></svg>`;
        const uri = 'data:image/svg+xml;base64,' + btoa(svg);
        if (cache.size > 200) cache.clear();
        cache.set(key, uri);
        return uri;
    }

    function nymName(pubkey) {
        const key = String(pubkey || '');
        const rand = rng(fnv(key));
        const adj = ADJECTIVES[Math.floor(rand() * ADJECTIVES.length)];
        const noun = NOUNS[Math.floor(rand() * NOUNS.length)];
        return `${adj}_${noun}`;
    }

    function suffix(pubkey) {
        const key = String(pubkey || '');
        return key.length >= 4 ? key.slice(-4) : (fnv(key).toString(16) + '0000').slice(0, 4);
    }

    function colorClass(pubkey) {
        return 'user-color-' + (fnv(String(pubkey || '')) % 8);
    }

    window.NymbotAvatar = { identicon, nymName, suffix, colorClass };
})();
