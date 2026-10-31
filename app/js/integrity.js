(function () {
    'use strict';

    const C = window.NymbotConfig;
    const MANIFEST_URL = '/app/build-manifest.json';

    const EDGE_NONCE = '[A-Za-z0-9+/=_-]*';
    const EDGE_NONCE_ATTR = '(?: nonce="' + EDGE_NONCE + '")?';
    const EDGE_PLATFORM_PATH = '/cdn-cgi/challenge-platform(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+';
    const EDGE_RAY_QUERY = '(?:\\?ray=[0-9a-f]+)?';
    const EDGE_BOOTSTRAP = "<script§NONCEATTR§>window.__CF$cv$params={r:'§RAY§',t:'§TOKEN§'§SESSION§};(function(){if(!document.body)return;var s=document.createElement('script');s.nonce='§NONCE§';s.src='§SRC§';document.head.appendChild(s);})();</script>";
    const EDGE_BOOTSTRAP_LEGACY = "<script§NONCEATTR§>(function(){function c(){var b=a.contentDocument||a.contentWindow.document;if(b){var d=b.createElement('script');d.innerHTML=\"window.__CF$cv$params={r:'§RAY§',t:'§TOKEN§'};var a=document.createElement('script');a.nonce='§NONCE§';a.src='§SRC§';document.getElementsByTagName('head')[0].appendChild(a);\";b.getElementsByTagName('head')[0].appendChild(d)}}if(document.body){var a=document.createElement('iframe');a.height=1;a.width=1;a.style.position='absolute';a.style.top=0;a.style.left=0;a.style.border='none';a.style.visibility='hidden';document.body.appendChild(a);if('loading'!==document.readyState)c();else if(window.addEventListener)document.addEventListener('DOMContentLoaded',c);else{var e=document.onreadystatechange||function(){};document.onreadystatechange=function(b){e(b);'loading'!==document.readyState&&(document.onreadystatechange=e,c())}}}})();</script>";
    const EDGE_BOOTSTRAP_ORIGIN = "<script§NONCEATTR§>window.__CF$cv$params={r:'§RAY§',t:'§TOKEN§'§SESSION§};(function(){if(!document.body)return;var l=window.location,o;try{o=new URL(l.origin).origin}catch(e){try{o=new URL(new URL(l.href).origin).origin}catch(e){o=''}}var u='§SRC§§RAYQUERY§',s=document.createElement('script');s.nonce='§NONCE§';s.src=o?new URL(u,o).href:u;document.head.appendChild(s);})();</script>";

    function escapeRe(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    function bootstrapRe(template) {
        return new RegExp(escapeRe(template)
            .replace('§NONCEATTR§', EDGE_NONCE_ATTR)
            .replace('§RAY§', '(?<ray>[0-9a-f]+)')
            .replace('§TOKEN§', '[A-Za-z0-9+/=]+')
            .replace('§SESSION§', "(?:,u:'[0-9a-f]+')?(?:,ut:'[A-Za-z0-9._-]+')?(?:,i:[0-9]+)?")
            .replace('§NONCE§', EDGE_NONCE)
            .replace('§SRC§', EDGE_PLATFORM_PATH)
            .replace('§RAYQUERY§', '(?:\\?ray=\\k<ray>)?'));
    }

    const EDGE_TAG = /<script((?:[\t\n\f\r ]+[a-z-]+(?:="[^"<>]*"|='[^'<>]*')?)+)><\/script>/g;
    const EDGE_TAG_ATTR = /[\t\n\f\r ]+([a-z-]+)(?:="([^"<>]*)"|='([^'<>]*)')?/g;
    const EDGE_TAG_EXTRA = ['nonce', 'defer', 'async', 'integrity', 'crossorigin', 'data-cf-beacon', 'data-cf-settings'];
    const EDGE_BEACON_SRC = /^https:\/\/static\.cloudflareinsights\.com\/beacon\.min\.js[^"<>]*$/;
    const EDGE_PLATFORM_SRC = new RegExp('^' + EDGE_PLATFORM_PATH + EDGE_RAY_QUERY + '$');
    const ROCKET_LOADER_SRC = /^\/cdn-cgi\/scripts\/[0-9a-f]+\/cloudflare-static\/rocket-loader\.min\.js$/;
    const ROCKET_LOADER_SETTINGS = /^([0-9a-f]+)-[^"<>]*$/;

    function edgeTag(attrs, src) {
        const seen = new Map();
        for (const [, name, dq, sq] of attrs.matchAll(EDGE_TAG_ATTR)) {
            const value = dq ?? sq ?? null;
            if (seen.has(name)) return null;
            if (name === 'type' ? value !== 'module' : name !== 'src' && !EDGE_TAG_EXTRA.includes(name)) return null;
            seen.set(name, value);
        }
        return src.test(seen.get('src') ?? '') ? seen : null;
    }

    const EDGE_PATTERNS = [
        [EDGE_TAG, EDGE_BEACON_SRC],
        [bootstrapRe(EDGE_BOOTSTRAP)],
        [bootstrapRe(EDGE_BOOTSTRAP_LEGACY)],
        [bootstrapRe(EDGE_BOOTSTRAP_ORIGIN)],
        [EDGE_TAG, EDGE_PLATFORM_SRC]
    ];
    const META_NONCE = new RegExp('(<meta http-equiv="Content-Security-Policy" content="[^"]*?script-src) \\\'nonce-' + EDGE_NONCE + '\\\'');
    const INLINE_SCRIPT = /<script(?:\s[^<>]*)?>[\s\S]*?<\/script>/g;

    function stripEdgeInjection(html) {
        let removed = 0;
        let marker = '';
        html = html.replace(EDGE_TAG, (tag, attrs) => {
            const loader = !marker && edgeTag(attrs, ROCKET_LOADER_SRC);
            const settings = loader && ROCKET_LOADER_SETTINGS.exec(loader.get('data-cf-settings') ?? '');
            if (!settings) return tag;
            marker = ' type="' + settings[1] + '-text/javascript"';
            removed++;
            return '';
        });
        if (marker) html = html.replace(/<script\s[^<>]*>/g, (tag) => tag.split(marker).join(''));
        for (const [re, src] of EDGE_PATTERNS) {
            html = html.replace(re, (tag, attrs) => {
                if (src && !edgeTag(attrs, src)) return tag;
                removed++;
                return '';
            });
        }
        html = html.replace(META_NONCE, '$1');
        return { html, removed };
    }

    function strayInlineScripts(html) {
        const out = [];
        for (const m of html.matchAll(INLINE_SCRIPT)) {
            const open = m[0].slice(0, m[0].indexOf('>') + 1);
            if (/\ssrc=/.test(open) || /\stype="application\/ld\+json"/.test(open)) continue;
            out.push(m[0]);
        }
        return out;
    }

    function fetchPath(path) {
        return path === '/app/index.html' ? '/app/' : path;
    }

    async function servedBytes(path) {
        const r = await fetch(fetchPath(path), { cache: 'no-store', credentials: 'same-origin' });
        if (!r.ok) throw new Error('http ' + r.status);
        if (!/\.html$/.test(path)) return { buf: await r.arrayBuffer(), removed: 0, stray: [] };
        const { html, removed } = stripEdgeInjection(await r.text());
        return { buf: new TextEncoder().encode(html), removed, stray: strayInlineScripts(html) };
    }

    async function digest(buf) {
        return new Uint8Array(await crypto.subtle.digest('SHA-256', buf));
    }

    async function sha256b64(buf) {
        const bytes = await digest(buf);
        let bin = '';
        for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return 'sha256-' + btoa(bin);
    }

    async function sha256hex(buf) {
        const bytes = await digest(buf);
        let hex = '';
        for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0');
        return hex;
    }

    async function checkAttestation(bundleHash) {
        try {
            const subject = await sha256hex(new TextEncoder().encode(bundleHash + '\n'));
            const res = await fetch(C.attestationApi + subject, {
                cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer'
            });
            if (res.status === 404) return false;
            if (!res.ok) return null;
            const data = await res.json();
            return Array.isArray(data.attestations) && data.attestations.length > 0;
        } catch (_) {
            return null;
        }
    }

    function stateOf(r) {
        if (!r.filesOk) return 'mismatch';
        if (r.anchored === false) return 'unofficial';
        if (r.anchored !== true) return 'unanchored';
        return r.officialHost ? 'verified' : 'mirror';
    }

    async function run(opts) {
        const o = opts || {};
        const res = await fetch(o.manifestUrl || MANIFEST_URL, { cache: 'no-store', credentials: 'same-origin' });
        if (!res.ok) throw new Error('manifest unavailable');
        const manifest = await res.json();
        const files = manifest && typeof manifest.files === 'object' && manifest.files ? manifest.files : {};
        const paths = Object.keys(files).filter((p) => typeof p === 'string' && p.startsWith('/app/'));
        const computed = {};
        const mismatches = [];
        let verified = 0;
        let idx = 0;
        let edgeInjected = 0;
        let strayScripts = 0;

        async function worker() {
            while (idx < paths.length) {
                const path = paths[idx++];
                try {
                    const { buf, removed, stray } = await servedBytes(path);
                    const got = await sha256b64(buf);
                    computed[path] = got;
                    edgeInjected += removed;
                    if (got === files[path]) verified++;
                    else {
                        mismatches.push(path);
                        strayScripts += stray.length;
                        for (const text of stray) console.warn('Nymbot integrity: unrecognized inline script in ' + path + ':\n' + text);
                    }
                } catch (_) {
                    mismatches.push(path);
                }
            }
        }

        const lanes = Math.min(6, paths.length) || 1;
        await Promise.all(Array.from({ length: lanes }, worker));
        mismatches.sort();

        const bundleHash = await sha256hex(new TextEncoder().encode(
            paths.slice().sort().map((p) => p + ':' + (computed[p] || '')).join('\n')
        ));
        const anchored = await checkAttestation(bundleHash);
        const filesOk = paths.length > 0 && mismatches.length === 0;
        const hosts = Array.isArray(o.officialHosts) ? o.officialHosts : C.officialHosts;
        const out = {
            commit: typeof manifest.commit === 'string' && manifest.commit ? manifest.commit : 'unknown',
            bundleHash,
            builtAt: manifest.builtAt || '',
            total: paths.length,
            verified,
            mismatches,
            anchored,
            filesOk,
            edgeInjected,
            strayScripts,
            officialHost: hosts.indexOf(location.hostname) !== -1
        };
        out.ok = filesOk && anchored === true;
        out.state = stateOf(out);
        return out;
    }

    let pending = null;

    window.NymbotIntegrity = {
        stripEdgeInjection,
        strayInlineScripts,
        run,
        verify() {
            if (!pending) pending = run().catch((e) => { pending = null; throw e; });
            return pending;
        }
    };
})();
