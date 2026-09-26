// Uploading a file so the model can actually see it.
(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Edge = window.NymbotEdge;

    // The same hosts Nymchat mirrors across, so a blob uploaded in one app
    // resolves in the other.
    const HOSTS = [
        'https://blossom.band',
        'https://blossom.primal.net',
        'https://nostr.download'
    ];


    // Uploads go through the worker's media proxy: it holds the CORS headers the
    // hosts do not all send, and it keeps the uploader's address off them.
    const proxyBase = () => `https://${C.apiHost}/api/proxy`;

    function hex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    async function sha256Hex(bytes) {
        const digest = await crypto.subtle.digest('SHA-256', bytes);
        return hex(new Uint8Array(digest));
    }

    function throwaway() {
        const T = window.NostrTools;
        const sk = T.generateSecretKey();
        const pubkey = T.getPublicKey(sk);
        return { pubkey, sign: (evt) => T.finalizeEvent(Object.assign({ pubkey }, evt), sk) };
    }

    /// BUD-02 upload auth.
    async function auth(hashHex, signer, verb) {
        const now = Math.floor(Date.now() / 1000);
        const action = verb || 'upload';
        const event = {
            kind: 24242,
            created_at: now,
            tags: [
                ['t', action],
                ['x', hashHex],
                ['expiration', String(now + 600)]
            ],
            content: action === 'delete' ? 'Delete blob' : 'Uploading blob with SHA-256 hash'
        };
        const who = signer || throwaway();
        const signed = await who.sign(Object.assign({ pubkey: who.pubkey }, event));
        return 'Nostr ' + btoa(JSON.stringify(signed));
    }

    async function putTo(host, bytes, mime, header, signal) {
        const url = `${proxyBase()}?action=upload&server=${encodeURIComponent(host)}`;
        const resp = await Edge.fetch(url, {
            method: 'PUT',
            headers: { 'Authorization': header, 'Content-Type': mime || 'application/octet-stream' },
            body: bytes,
            signal
        });
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        const data = await resp.json().catch(() => null);
        const got = data && (data.url || (data.nip94 && data.nip94.url));
        if (!got) throw new Error('no url');
        return String(got);
    }

    function bytesOfDataUrl(dataUrl) {
        const at = String(dataUrl || '').indexOf(',');
        if (at === -1) throw new Error('not a data url');
        const raw = atob(String(dataUrl).slice(at + 1));
        const out = new Uint8Array(raw.length);
        for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
        return out;
    }

    function mimeOfDataUrl(dataUrl) {
        const m = /^data:([^;,]+)/i.exec(String(dataUrl || ''));
        return m ? m[1] : 'application/octet-stream';
    }

    const Blossom = {
        HOSTS,
        throwaway,

        /// Uploads bytes and returns the public URL.
        async put(bytes, mime, opts) {
            return (await this.place(bytes, mime, opts)).url;
        },

        async place(bytes, mime, opts) {
            const options = opts || {};
            const sha256 = await sha256Hex(bytes);
            const header = await auth(sha256, options.signer);
            let last = null;
            for (const host of HOSTS) {
                if (options.signal && options.signal.aborted) throw new Error(t('Canceled.'));
                try {
                    return { url: await putTo(host, bytes, mime, header, options.signal), host, sha256 };
                } catch (e) { last = e; }
            }
            throw new Error(t('The file could not be uploaded — every media host refused it.')
                + (last && last.message ? ' (' + last.message + ')' : ''));
        },

        async remove(host, hashHex, opts) {
            const options = opts || {};
            const header = await auth(hashHex, options.signer, 'delete');
            const url = `${proxyBase()}?action=delete&server=${encodeURIComponent(host)}`
                + `&x=${encodeURIComponent(hashHex)}`;
            const resp = await Edge.fetch(url, { method: 'POST', headers: { 'Authorization': header } });
            return resp.status;
        },

        /// Uploads one attachment and records where it landed.
        async upload(attachment, opts) {
            if (!attachment || attachment.kind !== 'image') return attachment;
            if (attachment.url) return attachment;
            const bytes = bytesOfDataUrl(attachment.dataUrl);
            attachment.url = await this.put(bytes, attachment.mime || mimeOfDataUrl(attachment.dataUrl), opts);
            return attachment;
        },

        /// Uploads everything a message carries.
        async uploadAll(attachments, opts) {
            const list = attachments || [];
            const failed = [];
            for (const a of list) {
                try {
                    await this.upload(a, opts);
                } catch (e) {
                    failed.push({ name: a.name, error: (e && e.message) || String(e) });
                }
            }
            return failed;
        }
    };

    window.NymbotBlossom = Blossom;
})();
