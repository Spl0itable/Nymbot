(function () {
    'use strict';

    const C = window.NymbotConfig;
    const MANIFEST_URL = '/app/build-manifest.json';

    const EDGE_NONCE = '[A-Za-z0-9+/=_-]*';
    const EDGE_NONCE_ATTR = '(?: nonce="' + EDGE_NONCE + '")?';
    const EDGE_PLATFORM_PATH = '/cdn-cgi/challenge-platform/[A-Za-z0-9_./-]+';
    const EDGE_BOOTSTRAP = "<script§NONCEATTR§>window.__CF$cv$params={r:'§RAY§',t:'§TOKEN§'§SESSION§};(function(){if(!document.body)return;var s=document.createElement('script');s.nonce='§NONCE§';s.src='§SRC§';document.head.appendChild(s);})();</script>";
    const EDGE_BOOTSTRAP_LEGACY = "<script§NONCEATTR§>(function(){function c(){var b=a.contentDocument||a.contentWindow.document;if(b){var d=b.createElement('script');d.innerHTML=\"window.__CF$cv$params={r:'§RAY§',t:'§TOKEN§'};var a=document.createElement('script');a.nonce='§NONCE§';a.src='§SRC§';document.getElementsByTagName('head')[0].appendChild(a);\";b.getElementsByTagName('head')[0].appendChild(d)}}if(document.body){var a=document.createElement('iframe');a.height=1;a.width=1;a.style.position='absolute';a.style.top=0;a.style.left=0;a.style.border='none';a.style.visibility='hidden';document.body.appendChild(a);if('loading'!==document.readyState)c();else if(window.addEventListener)document.addEventListener('DOMContentLoaded',c);else{var e=document.onreadystatechange||function(){};document.onreadystatechange=function(b){e(b);'loading'!==document.readyState&&(document.onreadystatechange=e,c())}}}})();</script>";

    function escapeRe(s) {
        return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    function bootstrapRe(template) {
        return new RegExp(escapeRe(template)
            .replace('§NONCEATTR§', EDGE_NONCE_ATTR)
            .replace('§RAY§', '[0-9a-f]+')
            .replace('§TOKEN§', '[A-Za-z0-9+/=]+')
            .replace('§SESSION§', "(?:,u:'[0-9a-f]+')?(?:,ut:'[A-Za-z0-9._-]+')?(?:,i:[0-9]+)?")
            .replace('§NONCE§', EDGE_NONCE)
            .replace('§SRC§', EDGE_PLATFORM_PATH), 'g');
    }

    const EDGE_PATTERNS = [
        new RegExp('<script(?=[^<>]*\\ssrc="https://static\\.cloudflareinsights\\.com/beacon\\.min\\.js[^"<>]*")[^<>]*></script>', 'g'),
        bootstrapRe(EDGE_BOOTSTRAP),
        bootstrapRe(EDGE_BOOTSTRAP_LEGACY),
        new RegExp('<script(?=[^<>]*\\ssrc="' + EDGE_PLATFORM_PATH + '")[^<>]*></script>', 'g')
    ];
    const ROCKET_LOADER = /<script(?=[^<>]*\ssrc="\/cdn-cgi\/scripts\/[0-9a-f]+\/cloudflare-static\/rocket-loader\.min\.js")(?=[^<>]*\sdata-cf-settings="([0-9a-f]+)-[^"<>]*")[^<>]*><\/script>/;
    const META_NONCE = new RegExp('(<meta http-equiv="Content-Security-Policy" content="[^"]*?script-src) \\\'nonce-' + EDGE_NONCE + '\\\'');
    const INLINE_SCRIPT = /<script(?:\s[^<>]*)?>[\s\S]*?<\/script>/g;

    function stripEdgeInjection(html) {
        let removed = 0;
        const loader = html.match(ROCKET_LOADER);
        if (loader) {
            html = html.replace(loader[0], '');
            removed++;
            const marker = ' type="' + loader[1] + '-text/javascript"';
            html = html.replace(/<script\s[^<>]*>/g, (tag) => tag.split(marker).join(''));
        }
        for (const re of EDGE_PATTERNS) {
            html = html.replace(re, () => { removed++; return ''; });
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
