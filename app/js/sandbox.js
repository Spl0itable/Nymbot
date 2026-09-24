(function () {
    'use strict';

    const WORKER = '/app/sandbox-worker.js';
    const PDF_MAX = 40 * 1024 * 1024;

    let worker = null;
    let pending = null;

    function bridge() {
        const b = window.NymbotBridge;
        return b && typeof b.postMessage === 'function' ? b : null;
    }

    function post(msg) {
        const b = bridge();
        if (b) {
            b.postMessage(JSON.stringify(msg));
            return;
        }
        if (window.parent && window.parent !== window) window.parent.postMessage(msg, '*');
    }

    function fromBase64(b64) {
        const binary = atob(String(b64 || ''));
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes;
    }

    function startWorker() {
        const src = new URL(WORKER, location.href).href;
        let w = null;
        try {
            w = new Worker(src);
        } catch (_) {
            const shim = new Blob(['importScripts(' + JSON.stringify(src) + ');'], { type: 'text/javascript' });
            w = new Worker(URL.createObjectURL(shim));
        }
        w.addEventListener('message', (e) => {
            const msg = e.data;
            if (!msg || typeof msg !== 'object') return;
            if (msg.type === 'result' && msg.id === pending) pending = null;
            if (msg.type === 'status' || msg.type === 'result') post(msg);
        });
        w.addEventListener('error', (e) => {
            if (e && e.preventDefault) e.preventDefault();
            if (!pending) return;
            const id = pending;
            pending = null;
            worker = null;
            w.terminate();
            post({
                type: 'result', id, stdout: '', stderr: '', images: [], files: [], ms: 0,
                error: 'The sandbox could not start: ' + String((e && e.message) || 'unknown error')
            });
        });
        w.postMessage({ type: 'init', base: location.href });
        return w;
    }

    function run(msg) {
        if (!worker) worker = startWorker();
        pending = msg.id;
        worker.postMessage({
            type: 'run',
            id: msg.id,
            code: msg.code,
            language: msg.language,
            files: Array.isArray(msg.files) ? msg.files : []
        });
    }

    async function pdf(msg) {
        try {
            if (!window.NymbotPdfText) throw new Error('PDF reader missing');
            const bytes = fromBase64(msg.data);
            if (bytes.length > PDF_MAX) throw new Error('too large');
            const got = await window.NymbotPdfText.extract(bytes, {
                onPage: (n, of) => post({ type: 'pdf-progress', id: msg.id, page: n, of })
            });
            post({ type: 'pdf-result', id: msg.id, pages: got.pages, headings: got.headings, total: got.total, error: null });
        } catch (e) {
            post({ type: 'pdf-result', id: msg.id, pages: [], headings: [], total: 0, error: String((e && e.message) || e) });
        }
    }

    function handle(msg) {
        if (!msg || typeof msg !== 'object' || typeof msg.type !== 'string') return;
        if (msg.type === 'run' && typeof msg.code === 'string') run(msg);
        else if (msg.type === 'pdf' && typeof msg.data === 'string') pdf(msg);
        else if (msg.type === 'ping') post({ type: 'ready' });
    }

    window.addEventListener('message', (e) => {
        if (window.parent === window || e.source !== window.parent) return;
        handle(e.data);
    });

    window.nymbotSandbox = {
        receive(json) {
            let msg = json;
            if (typeof json === 'string') {
                try { msg = JSON.parse(json); } catch (_) { return; }
            }
            handle(msg);
        }
    };

    post({ type: 'ready' });
})();
