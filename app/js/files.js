(function () {
    'use strict';

    const LINE = /^\[([^\]\n]{1,200})\]\((https:\/\/[^\s)#]+)#nymbot-file&([^\s)]*)\)$/;
    const PENDING = /^nymbot-file\b/i;

    const KINDS = {
        pdf: { label: 'PDF', kind: 'pdf', open: true },
        docx: { label: 'Word', kind: 'doc' },
        xlsx: { label: 'Excel', kind: 'sheet' },
        csv: { label: 'CSV', kind: 'sheet', open: true },
        md: { label: 'Markdown', kind: 'text', open: true },
        txt: { label: 'Text', kind: 'text', open: true },
        json: { label: 'JSON', kind: 'text', open: true },
        html: { label: 'HTML', kind: 'code' },
        zip: { label: 'ZIP', kind: 'archive' }
    };

    const OPEN_TYPES = {
        pdf: 'application/pdf',
        csv: 'text/plain;charset=utf-8',
        md: 'text/plain;charset=utf-8',
        txt: 'text/plain;charset=utf-8',
        json: 'text/plain;charset=utf-8'
    };

    const SAFE_TYPES = {
        pdf: 'application/pdf',
        docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        csv: 'text/csv',
        md: 'text/markdown',
        txt: 'text/plain',
        json: 'application/json',
        html: 'application/octet-stream',
        zip: 'application/zip'
    };

    const DOC_ICON = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.8"'
        + ' stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
        + '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"></path>'
        + '<polyline points="14 3 14 8 19 8"></polyline></svg>';

    function esc(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function size(bytes) {
        const n = Number(bytes) || 0;
        if (n < 1024) return t('{n} B', { n });
        if (n < 1024 * 1024) return t('{n} KB', { n: Math.max(1, Math.round(n / 1024)) });
        return t('{n} MB', { n: (n / (1024 * 1024)).toFixed(1) });
    }

    function cleanName(raw) {
        const s = String(raw || '').replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, '')
            .replace(/[\\/:*?"<>|]/g, '_').trim();
        return s.slice(0, 120) || 'file';
    }

    function parse(line) {
        const m = LINE.exec(String(line || '').trim());
        if (!m) return null;
        let u;
        try { u = new URL(m[2]); } catch (_) { return null; }
        if (u.protocol !== 'https:' || u.username || u.password) return null;
        const params = {};
        for (const kv of m[3].split('&')) {
            const at = kv.indexOf('=');
            if (at <= 0) continue;
            try { params[kv.slice(0, at)] = decodeURIComponent(kv.slice(at + 1)); } catch (_) { }
        }
        const name = cleanName(params.name || m[1]);
        const ext = (/\.([a-z0-9]{1,8})$/i.exec(name) || [])[1];
        const key = ext ? ext.toLowerCase() : '';
        const meta = KINDS[key] || { label: key ? key.toUpperCase() : t('File'), kind: 'file' };
        return {
            url: u.href,
            name,
            ext: key,
            label: meta.label,
            kind: meta.kind,
            open: !!meta.open,
            type: SAFE_TYPES[key] || 'application/octet-stream',
            size: Math.max(0, Number(params.size) || 0)
        };
    }

    function card(info) {
        const sub = info.size ? t('{type} · {size}', { type: info.label, size: size(info.size) }) : info.label;
        const data = `data-file-url="${esc(info.url)}" data-file-name="${esc(info.name)}" data-file-ext="${esc(info.ext)}"`;
        const open = info.open
            ? `<button type="button" class="btn btn-small file-card-open" data-act="file-open" ${data}>${esc(t('Open'))}</button>`
            : '';
        const share = canShare()
            ? `<button type="button" class="btn btn-small file-card-share" data-act="file-share" ${data}>${esc(t('Share'))}</button>`
            : '';
        return `<div class="file-card is-${esc(info.kind)}" data-file-card="1" ${data}>`
            + `<span class="file-card-icon">${DOC_ICON}<span class="file-card-ext">${esc((info.ext || '').toUpperCase().slice(0, 4))}</span></span>`
            + `<span class="file-card-meta"><span class="file-card-name" title="${esc(info.name)}">${esc(info.name)}</span>`
            + `<span class="file-card-sub">${esc(sub)}</span></span>`
            + `<span class="file-card-actions">${open}`
            + `<button type="button" class="btn btn-small btn-primary file-card-save" data-act="file-save" ${data}>${esc(t('Download'))}</button>`
            + `${share}</span></div>`;
    }

    function pendingCard(info) {
        const name = (/(?:name|filename)\s*=\s*"([^"]{1,200})"/i.exec(info) || /(?:name|filename)\s*=\s*([^\s"']{1,200})/i.exec(info) || [])[1];
        return `<div class="file-card is-pending" role="status"><span class="file-card-icon">${DOC_ICON}</span>`
            + `<span class="file-card-meta"><span class="file-card-name">${esc(cleanName(name || t('File')))}</span>`
            + `<span class="file-card-sub">${esc(t('Making the file…'))}</span></span></div>`;
    }

    function paragraph(text) {
        const lines = String(text || '').split('\n').map((l) => l.trim()).filter(Boolean);
        if (!lines.length) return null;
        const infos = lines.map(parse);
        if (infos.some((i) => !i)) return null;
        return `<div class="file-cards">${infos.map(card).join('')}</div>`;
    }

    function canShare() {
        try {
            return typeof navigator !== 'undefined' && typeof navigator.share === 'function' && typeof navigator.canShare === 'function'
                && typeof File === 'function' && navigator.canShare({ files: [new File(['x'], 'x.txt', { type: 'text/plain' })] });
        } catch (_) {
            return false;
        }
    }

    function infoOf(el) {
        const ext = String(el.dataset.fileExt || '').toLowerCase();
        return {
            url: el.dataset.fileUrl,
            name: cleanName(el.dataset.fileName),
            ext,
            type: SAFE_TYPES[ext] || 'application/octet-stream'
        };
    }

    async function blobOf(info) {
        const res = await fetch(info.url, { credentials: 'omit', referrerPolicy: 'no-referrer', cache: 'force-cache' });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const bytes = await res.arrayBuffer();
        return new Blob([bytes], { type: info.type });
    }

    function toast(text) {
        const U = window.NymbotUI;
        if (U && typeof U.toast === 'function') U.toast(text);
    }

    function saveBlob(name, blob) {
        const Exporter = window.NymbotExport;
        if (Exporter && typeof Exporter.saveBlob === 'function') { Exporter.saveBlob(name, blob); return; }
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = name;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 4000);
    }

    async function save(info) {
        toast(t('Downloading {name}…', { name: info.name }));
        try {
            saveBlob(info.name, await blobOf(info));
            toast(t('Saved {name}.', { name: info.name }));
        } catch (_) {
            window.open(info.url, '_blank', 'noopener,noreferrer');
            toast(t('Opened it in a new tab — save it from there.'));
        }
    }

    async function open(info) {
        const kind = OPEN_TYPES[info.ext];
        if (!kind) return save(info);
        const tab = window.open('', '_blank');
        try {
            const blob = await blobOf(info);
            const url = URL.createObjectURL(new Blob([await blob.arrayBuffer()], { type: kind }));
            if (tab) {
                try { tab.opener = null; } catch (_) { }
                tab.location.href = url;
            } else {
                window.open(url, '_blank', 'noopener');
            }
            setTimeout(() => URL.revokeObjectURL(url), 60000);
        } catch (_) {
            if (tab) tab.close();
            window.open(info.url, '_blank', 'noopener,noreferrer');
        }
    }

    async function share(info) {
        try {
            const blob = await blobOf(info);
            const file = new File([blob], info.name, { type: info.type });
            await navigator.share({ files: [file], title: info.name });
        } catch (e) {
            if (e && e.name === 'AbortError') return;
            save(info);
        }
    }

    function bytesOfBase64(b64) {
        const raw = atob(String(b64 || ''));
        const out = new Uint8Array(raw.length);
        for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
        return out;
    }

    async function convertArtifact(entry, format, conv, body) {
        const Api = window.NymbotApi;
        const Anon = window.NymbotAnon;
        if (!Api || !entry || (format !== 'pdf' && format !== 'docx')) return false;
        const text = typeof body === 'string' ? body : entry.body;
        if (!String(text || '').trim()) {
            toast(t('This artifact is empty.'));
            return false;
        }
        const signer = conv && conv.anon && Anon ? Anon.signer(Anon.forConv(conv)) : null;
        toast(format === 'pdf' ? t('Making the PDF…') : t('Making the DOCX…'));
        const res = await Api.call('file-render', { format, title: entry.title || '', lang: entry.lang || '', body: text }, { signer, timeout: 60000 });
        const data = res && res.data;
        if (!res || res.status !== 200 || !data || typeof data.data !== 'string') {
            toast((data && data.error) || t('That could not be converted.'));
            return false;
        }
        const ext = format === 'pdf' ? 'pdf' : 'docx';
        const name = cleanName(data.name || ((entry.title || 'artifact') + '.' + ext));
        saveBlob(name, new Blob([bytesOfBase64(data.data)], { type: SAFE_TYPES[ext] }));
        toast(t('Saved {name}.', { name }));
        return true;
    }

    const ACTIONS = { 'file-save': save, 'file-open': open, 'file-share': share };

    if (typeof document !== 'undefined' && document.addEventListener) {
        document.addEventListener('click', (e) => {
            const btn = e.target && e.target.closest ? e.target.closest('[data-act^="file-"]') : null;
            if (!btn || !ACTIONS[btn.dataset.act] || !btn.dataset.fileUrl) return;
            e.preventDefault();
            ACTIONS[btn.dataset.act](infoOf(btn));
        });
        document.addEventListener('click', (e) => {
            const btn = e.target && e.target.closest ? e.target.closest('[data-act="artifact-export"]') : null;
            const U = window.NymbotUI;
            if (!btn || !U || !U.artifact) return;
            e.preventDefault();
            const field = document.getElementById('artifactBody');
            convertArtifact(U.artifact, btn.dataset.format, U.conv, field ? field.value : undefined);
        });
    }

    window.NymbotFiles = { parse, card, paragraph, pendingCard, convertArtifact, isPending: (info) => PENDING.test(String(info || '').trim()), save, open, share, size, SAFE_TYPES };
})();
