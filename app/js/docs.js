(function () {
    'use strict';

    const Store = window.NymbotStore;

    const INLINE_MAX = 96 * 1024;
    const DOC_MAX_CHARS = 8 * 1024 * 1024;
    const FILE_MAX_BYTES = 50 * 1024 * 1024;
    const CHUNK_TARGET = 1500;
    const CHUNK_MAX = 2000;
    const TURN_BUDGET = 12000;
    const DOC_MIN_BUDGET = 3000;
    const OUTLINE_MAX = 24;
    const FILES_PER_CHAT = 20;
    const DB_NAME = 'nymbot-docs';
    const STORE = 'files';

    const K1 = 1.2;
    const B = 0.75;

    const STOP = new Set(('a an and are as at be but by can could did do does for from had has have how i if in into is it its '
        + 'me my of on or our so than that the their them then there these they this those to was we were what when where '
        + 'which who why will with would you your about also any just not no yes one all more most other some such only own '
        + 'same very s t d ll m re ve please tell show give find does doesn document file pdf page pages').split(' '));

    function fold(text) {
        return String(text || '').toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '');
    }

    function tokens(text) {
        const out = [];
        for (const w of fold(text).split(/[^\p{L}\p{N}]+/u)) {
            if (!w) continue;
            if (w.length < 2 && !/\d/.test(w)) continue;
            if (STOP.has(w)) continue;
            out.push(w.length > 4 ? stem(w) : w);
        }
        return out;
    }

    function stem(w) {
        if (/ies$/.test(w)) return w.slice(0, -3) + 'y';
        if (/(sses|xes|ches|shes)$/.test(w)) return w.slice(0, -2);
        if (/[^s]s$/.test(w)) return w.slice(0, -1);
        if (/ing$/.test(w) && w.length > 6) return w.slice(0, -3);
        if (/ed$/.test(w) && w.length > 5) return w.slice(0, -2);
        return w;
    }

    const indexes = new WeakMap();

    function indexOf(chunks) {
        let idx = indexes.get(chunks);
        if (idx) return idx;
        const docs = chunks.map((c) => {
            const tf = new Map();
            const words = tokens(c.t);
            for (const w of words) tf.set(w, (tf.get(w) || 0) + 1);
            return { tf, len: words.length };
        });
        const df = new Map();
        for (const d of docs) for (const w of d.tf.keys()) df.set(w, (df.get(w) || 0) + 1);
        const avg = docs.reduce((n, d) => n + d.len, 0) / Math.max(1, docs.length);
        idx = { docs, df, avg: avg || 1 };
        indexes.set(chunks, idx);
        return idx;
    }

    function rank(chunks, query) {
        const list = Array.isArray(chunks) ? chunks : [];
        if (!list.length) return [];
        const idx = indexOf(list);
        const terms = Array.from(new Set(tokens(query)));
        const n = list.length;
        const scored = [];
        idx.docs.forEach((d, i) => {
            let score = 0;
            for (const w of terms) {
                const tf = d.tf.get(w);
                if (!tf) continue;
                const df = idx.df.get(w) || 0;
                const idf = Math.log(1 + (n - df + 0.5) / (df + 0.5));
                score += idf * (tf * (K1 + 1)) / (tf + K1 * (1 - B + B * d.len / idx.avg));
            }
            if (score > 0) scored.push({ index: i, score });
        });
        scored.sort((a, b) => b.score - a.score || a.index - b.index);
        return scored;
    }

    function select(doc, query, budget) {
        const chunks = doc.chunks || [];
        const ranked = rank(chunks, query);
        const picked = [];
        let used = 0;
        const take = (i) => {
            const c = chunks[i];
            if (!c || picked.includes(i)) return false;
            if (used + c.t.length > budget && picked.length) return false;
            picked.push(i);
            used += c.t.length;
            return true;
        };
        for (const r of ranked) {
            if (used >= budget) break;
            take(r.index);
        }
        const matched = picked.length > 0;
        if (!matched) {
            for (let i = 0; i < chunks.length && used < budget; i++) {
                if (!take(i)) break;
            }
        }
        picked.sort((a, b) => a - b);
        return { chunks: picked.map(i => chunks[i]), matched };
    }

    function splitLong(text) {
        const out = [];
        let rest = text;
        while (rest.length > CHUNK_MAX) {
            let cut = rest.lastIndexOf('\n', CHUNK_TARGET);
            if (cut < CHUNK_TARGET / 2) cut = rest.lastIndexOf('. ', CHUNK_TARGET) + 1;
            if (cut < CHUNK_TARGET / 2) cut = rest.lastIndexOf(' ', CHUNK_TARGET);
            if (cut < CHUNK_TARGET / 2) cut = CHUNK_TARGET;
            out.push(rest.slice(0, cut).trim());
            rest = rest.slice(cut);
        }
        if (rest.trim()) out.push(rest.trim());
        return out;
    }

    function chunkText(text) {
        const out = [];
        let cur = '';
        const paras = String(text || '').split(/\n\s*\n/);
        for (const raw of paras) {
            const p = raw.trim();
            if (!p) continue;
            const pieces = p.length > CHUNK_MAX ? splitLong(p) : [p];
            for (const piece of pieces) {
                if (cur && cur.length + piece.length + 2 > CHUNK_TARGET) {
                    out.push(cur);
                    cur = piece;
                } else {
                    cur = cur ? cur + '\n\n' + piece : piece;
                }
            }
        }
        if (cur) out.push(cur);
        return out;
    }

    function chunkTable(text, sep) {
        const lines = String(text || '').split(/\r?\n/);
        const head = lines.shift() || '';
        const out = [];
        let cur = [];
        let size = head.length;
        for (const line of lines) {
            if (!line.trim()) continue;
            if (cur.length && size + line.length + 1 > CHUNK_TARGET) {
                out.push(head + '\n' + cur.join('\n'));
                cur = [];
                size = head.length;
            }
            cur.push(line.length > CHUNK_MAX ? line.slice(0, CHUNK_MAX) : line);
            size += line.length + 1;
        }
        if (cur.length) out.push(head + '\n' + cur.join('\n'));
        return { chunks: out, columns: head.split(sep).map(s => s.trim().replace(/^"|"$/g, '')).filter(Boolean), rows: lines.filter(l => l.trim()).length };
    }

    function chunkPages(pages) {
        const out = [];
        pages.forEach((text, i) => {
            for (const piece of chunkText(text)) out.push({ n: i + 1, t: piece });
        });
        return out;
    }

    function markdownHeadings(text) {
        const out = [];
        const re = /^(#{1,3})\s+(.{2,90})$/gm;
        let m;
        while ((m = re.exec(text)) && out.length < OUTLINE_MAX) out.push({ title: m[2].trim(), page: null });
        return out;
    }

    function extOf(name) {
        return String(name || '').split('.').pop().toLowerCase();
    }

    function stripHtml(html) {
        const doc = new DOMParser().parseFromString(String(html || ''), 'text/html');
        for (const n of doc.querySelectorAll('script, style, noscript, template, svg, iframe, object')) n.remove();
        const parts = [];
        const BLOCK = /^(p|div|section|article|header|footer|main|aside|li|ul|ol|table|tr|blockquote|pre|br|hr|dt|dd|figure|figcaption|nav)$/i;
        const walk = (node) => {
            for (const child of node.childNodes) {
                if (child.nodeType === 3) {
                    parts.push(child.nodeValue.replace(/\s+/g, ' '));
                } else if (child.nodeType === 1) {
                    const tag = child.tagName.toLowerCase();
                    const h = /^h([1-6])$/.exec(tag);
                    if (h) {
                        parts.push('\n\n' + '#'.repeat(Math.min(3, Number(h[1]))) + ' ' + child.textContent.replace(/\s+/g, ' ').trim() + '\n\n');
                        continue;
                    }
                    if (tag === 'td' || tag === 'th') parts.push('\t');
                    const block = BLOCK.test(tag);
                    const single = tag === 'br' || tag === 'li' || tag === 'tr';
                    if (block) parts.push(single ? '\n' : '\n\n');
                    walk(child);
                    if (block && !single) parts.push('\n\n');
                }
            }
        };
        walk(doc.body || doc.documentElement);
        return parts.join('').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    }

    const UNZIP_MAX = 32 * 1024 * 1024;

    async function inflateRaw(bytes, cap) {
        if (typeof DecompressionStream === 'undefined') throw new Error('unzip');
        const limit = cap || UNZIP_MAX;
        const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw')).getReader();
        const parts = [];
        let total = 0;
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            total += value.length;
            if (total > limit) {
                try { await reader.cancel(); } catch (_) { }
                throw new Error('zip');
            }
            parts.push(value);
        }
        const out = new Uint8Array(total);
        let at = 0;
        for (const part of parts) {
            out.set(part, at);
            at += part.length;
        }
        return out;
    }

    async function unzipEntry(buffer, wanted, cap) {
        const limit = cap || UNZIP_MAX;
        const bytes = new Uint8Array(buffer);
        const view = new DataView(buffer);
        if (bytes.length < 22) throw new Error('zip');
        let end = -1;
        for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--) {
            if (view.getUint32(i, true) === 0x06054b50) { end = i; break; }
        }
        if (end < 0) throw new Error('zip');
        const count = view.getUint16(end + 10, true);
        let at = view.getUint32(end + 16, true);
        const decoder = new TextDecoder();
        for (let k = 0; k < count && at + 46 <= bytes.length; k++) {
            if (view.getUint32(at, true) !== 0x02014b50) break;
            const method = view.getUint16(at + 10, true);
            const size = view.getUint32(at + 20, true);
            const full = view.getUint32(at + 24, true);
            const nameLen = view.getUint16(at + 28, true);
            const extraLen = view.getUint16(at + 30, true);
            const commentLen = view.getUint16(at + 32, true);
            const local = view.getUint32(at + 42, true);
            if (at + 46 + nameLen > bytes.length) throw new Error('zip');
            const name = decoder.decode(bytes.subarray(at + 46, at + 46 + nameLen));
            if (name === wanted) {
                if (full > limit) throw new Error('zip');
                if (local + 30 > bytes.length || view.getUint32(local, true) !== 0x04034b50) throw new Error('zip');
                const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
                if (start + size > bytes.length) throw new Error('zip');
                const data = bytes.subarray(start, start + size);
                if (method === 0) {
                    if (size > limit) throw new Error('zip');
                    return data;
                }
                if (method === 8) return inflateRaw(data, limit);
                throw new Error('zip');
            }
            at += 46 + nameLen + extraLen + commentLen;
        }
        return null;
    }

    function docxText(xml) {
        const doc = new DOMParser().parseFromString(xml, 'application/xml');
        const out = [];
        for (const p of doc.getElementsByTagNameNS('*', 'p')) {
            let text = '';
            const walk = (node) => {
                for (const child of node.childNodes) {
                    if (child.nodeType !== 1) continue;
                    const name = child.localName;
                    if (name === 't') text += child.textContent;
                    else if (name === 'tab') text += '\t';
                    else if (name === 'br' || name === 'cr') text += '\n';
                    else if (name !== 'p' && name !== 'pPr' && name !== 'rPr') walk(child);
                }
            };
            walk(p);
            const style = p.getElementsByTagNameNS('*', 'pStyle')[0];
            const val = style ? (style.getAttribute('w:val') || style.getAttributeNS(style.namespaceURI, 'val') || '') : '';
            const h = /^heading\s?(\d)/i.exec(val);
            if (text.trim() && (h || /^title$/i.test(val))) {
                out.push('#'.repeat(h ? Math.min(3, Number(h[1])) : 1) + ' ' + text.trim());
            } else {
                out.push(text);
            }
        }
        return out.join('\n\n').replace(/\n{3,}/g, '\n\n').trim();
    }

    function isPdf(file) {
        return /^application\/pdf$/i.test(file.type || '') || extOf(file.name) === 'pdf';
    }

    function isDocx(file) {
        return /wordprocessingml/i.test(file.type || '') || extOf(file.name) === 'docx';
    }

    function handles(file) {
        return !!file && (isPdf(file) || isDocx(file));
    }

    function pageMarked(pages) {
        if (pages.length === 1) return pages[0];
        return pages.map((p, i) => `[page ${i + 1}]\n${p}`).join('\n\n');
    }

    function wireCost(text) {
        const json = JSON.stringify(String(text || ''));
        return new TextEncoder().encode(json).length - 2;
    }

    function uid() {
        return Store && Store.uid ? Store.uid() : Math.random().toString(36).slice(2);
    }

    function inlineText(meta, text) {
        return {
            id: uid(),
            kind: 'text',
            name: meta.name,
            mime: meta.mime,
            size: meta.size,
            lang: meta.lang || '',
            lines: text.split('\n').length,
            text
        };
    }

    function asDoc(meta, chunks, outline, extra) {
        const paged = !!meta.paged;
        const count = paged ? meta.pages : chunks.length;
        const label = paged
            ? t('{n} pages · searched', { n: count })
            : t('{n} parts · searched', { n: count });
        return Object.assign({
            id: uid(),
            kind: 'doc',
            name: meta.name,
            mime: meta.mime,
            size: meta.size,
            format: meta.format,
            paged,
            pages: count,
            outline: (outline || []).slice(0, OUTLINE_MAX),
            chunks,
            chars: chunks.reduce((n, c) => n + c.t.length, 0),
            label
        }, extra || {});
    }

    function fromPages(meta, pages, headings) {
        const text = pageMarked(pages);
        if (wireCost(text) <= INLINE_MAX) return inlineText(meta, text);
        return asDoc(Object.assign({}, meta, { paged: true, pages: pages.length }), chunkPages(pages), headings);
    }

    function fromText(text, meta) {
        let body = String(text || '');
        if (body.length > DOC_MAX_CHARS) throw new Error(t('That document is too large to read on this device — 8 MB of text is the limit.'));
        const info = Object.assign({ name: 'file.txt', mime: 'text/plain', size: body.length }, meta || {});
        const ext = extOf(info.name);
        if (ext === 'html' || ext === 'htm' || ext === 'xhtml') body = stripHtml(body);
        if (ext === 'csv' || ext === 'tsv') {
            const table = chunkTable(body, ext === 'tsv' ? '\t' : ',');
            const chunks = table.chunks.map((c, i) => ({ n: i + 1, t: c }));
            return asDoc(Object.assign({}, info, { format: ext }), chunks,
                [{ title: t('Columns: {names}', { names: table.columns.slice(0, 30).join(', ') }), page: null },
                    { title: t('{n} rows', { n: table.rows }), page: null }],
                { raw: String(text || '') });
        }
        const chunks = chunkText(body).map((c, i) => ({ n: i + 1, t: c }));
        return asDoc(Object.assign({}, info, { format: ext || 'txt' }), chunks, markdownHeadings(body),
            { raw: String(text || '') });
    }

    async function fromFile(file) {
        if ((file.size || 0) > FILE_MAX_BYTES) throw new Error(t('That document is too large — 50 MB is the limit.'));
        const meta = { name: file.name || 'document', mime: file.type || '', size: file.size || 0 };
        if (isPdf(file)) {
            if (!window.NymbotPdfText) throw new Error(t('PDFs cannot be read on this device.'));
            const U = window.NymbotUI;
            if (U && typeof U.toast === 'function') U.toast(t('Reading {name} on this device…', { name: meta.name }));
            const bytes = new Uint8Array(await file.arrayBuffer());
            let got;
            try {
                got = await window.NymbotPdfText.extract(bytes);
            } catch (_) {
                throw new Error(t('That PDF could not be read. It may be damaged or password-protected.'));
            }
            if (!got.pages.some(p => p.trim())) {
                throw new Error(t('That PDF has no text in it — it looks like a scan, which cannot be read on this device.'));
            }
            return fromPages(Object.assign(meta, { mime: 'application/pdf', format: 'pdf' }), got.pages, got.headings);
        }
        if (isDocx(file)) {
            let xml;
            try {
                const entry = await unzipEntry(await file.arrayBuffer(), 'word/document.xml');
                if (!entry) throw new Error('docx');
                xml = new TextDecoder().decode(entry);
            } catch (_) {
                throw new Error(t('That Word document could not be read.'));
            }
            const text = docxText(xml);
            if (!text.trim()) throw new Error(t('That Word document has no text in it.'));
            Object.assign(meta, { format: 'docx' });
            if (wireCost(text) <= INLINE_MAX) return inlineText(meta, text);
            return fromText(text, meta);
        }
        return null;
    }

    let dbp = null;

    function db() {
        if (dbp) return dbp;
        dbp = new Promise((resolve) => {
            try {
                const req = indexedDB.open(DB_NAME, 1);
                req.onupgradeneeded = () => {
                    const s = req.result.createObjectStore(STORE, { keyPath: 'key' });
                    s.createIndex('conv', 'convId');
                };
                req.onsuccess = () => resolve(req.result);
                req.onerror = () => resolve(null);
                req.onblocked = () => resolve(null);
            } catch (_) {
                resolve(null);
            }
        });
        return dbp;
    }

    function tx(mode, fn) {
        return db().then((d) => new Promise((resolve) => {
            if (!d) { resolve(null); return; }
            try {
                const trans = d.transaction(STORE, mode);
                const out = fn(trans.objectStore(STORE));
                trans.oncomplete = () => resolve(out && 'result' in out ? out.result : null);
                trans.onerror = () => resolve(null);
                trans.onabort = () => resolve(null);
            } catch (_) {
                resolve(null);
            }
        }));
    }

    const cache = new Map();
    const loading = new Map();

    function ghost(convId) {
        return !!(Store && Store.isGhost && Store.isGhost(convId));
    }

    function load(convId) {
        if (!convId) return Promise.resolve([]);
        if (cache.has(convId)) return Promise.resolve(cache.get(convId));
        if (loading.has(convId)) return loading.get(convId);
        const p = (ghost(convId)
            ? Promise.resolve([])
            : tx('readonly', s => s.index('conv').getAll(convId)))
            .then((rows) => {
                const list = (rows || []).slice().sort((a, b) => (a.addedAt || 0) - (b.addedAt || 0));
                if (!cache.has(convId)) cache.set(convId, list);
                loading.delete(convId);
                return cache.get(convId);
            });
        loading.set(convId, p);
        return p;
    }

    function loaded(convId) {
        return cache.has(convId);
    }

    function list(convId) {
        return cache.get(convId) || [];
    }

    function entryFor(convId, a) {
        const base = {
            key: convId + ':' + a.id, convId, id: a.id, kind: a.kind, name: a.name,
            mime: a.mime || '', size: a.size || 0, addedAt: Date.now()
        };
        if (a.kind === 'doc') {
            return Object.assign(base, {
                format: a.format, paged: !!a.paged, pages: a.pages, outline: a.outline || [],
                chunks: a.chunks || [], chars: a.chars || 0, label: a.label || '',
                raw: typeof a.raw === 'string' ? a.raw : null
            });
        }
        return Object.assign(base, { text: String(a.text || '') });
    }

    async function keep(convId, attachments) {
        const wanted = (attachments || []).filter(a => a && (a.kind === 'doc' || (a.kind === 'text' && typeof a.text === 'string')));
        if (!convId || !wanted.length) return;
        await load(convId);
        const current = list(convId).slice();
        const added = [];
        for (const a of wanted) {
            if (current.some(e => e.id === a.id)) continue;
            const entry = entryFor(convId, a);
            current.push(entry);
            added.push(entry);
        }
        const dropped = current.length > FILES_PER_CHAT ? current.splice(0, current.length - FILES_PER_CHAT) : [];
        cache.set(convId, current);
        if (ghost(convId)) return;
        await tx('readwrite', (s) => {
            for (const e of added) if (!dropped.includes(e)) s.put(e);
            for (const e of dropped) s.delete(e.key);
        });
    }

    async function remove(convId, id) {
        await load(convId);
        cache.set(convId, list(convId).filter(e => e.id !== id));
        if (!ghost(convId)) await tx('readwrite', s => s.delete(convId + ':' + id));
    }

    async function forget(convId) {
        const rows = await load(convId);
        cache.delete(convId);
        if (!ghost(convId)) await tx('readwrite', (s) => { for (const e of rows || []) s.delete(e.key); });
    }

    function searchable(conv, attachments) {
        const out = [];
        const seen = new Set();
        const add = (d) => {
            if (!d || d.kind !== 'doc' || seen.has(d.id)) return;
            seen.add(d.id);
            out.push(d);
        };
        if (conv && conv.id) list(conv.id).forEach(add);
        (attachments || []).forEach(add);
        return out;
    }

    function unitName(doc, plural) {
        if (doc.paged) return plural ? 'pages' : 'page';
        return plural ? 'parts' : 'part';
    }

    function outlineLine(doc) {
        const bits = (doc.outline || []).map(h => h.page ? `${h.title} (p. ${h.page})` : h.title);
        return bits.length ? 'Outline: ' + bits.join('; ') + '\n' : '';
    }

    function plan(conv, question, attachments) {
        const docs = searchable(conv, attachments);
        if (!docs.length) return [];
        const per = Math.max(DOC_MIN_BUDGET, Math.floor(TURN_BUDGET / docs.length));
        return docs.map((doc) => {
            const sel = select(doc, question, per);
            return { doc, chunks: sel.chunks, matched: sel.matched };
        });
    }

    function wireFor(conv, question, attachments) {
        let out = '';
        for (const p of plan(conv, question, attachments)) {
            const doc = p.doc;
            out += `\n\n--- attached document: ${doc.name} (${doc.pages} ${unitName(doc, doc.pages !== 1)}, searched rather than read whole) ---\n`;
            out += outlineLine(doc);
            out += p.matched
                ? 'This document is too long to send whole. These are the passages, found on the user\'s device, that best match the question; the rest of it was not sent. If the answer may be in a part not shown, say so.\n'
                : 'This document is too long to send whole, and nothing in it matched the question, so this is its beginning; the rest of it was not sent. Say so if the answer is not here.\n';
            for (const c of p.chunks) {
                out += `\n[${unitName(doc, false)} ${c.n}]\n${c.t}\n`;
            }
            out += `--- end of excerpts from ${doc.name} ---`;
        }
        return out;
    }

    function usage(conv, question, attachments) {
        const out = plan(conv, question, attachments).map(p => ({
            id: p.doc.id,
            name: p.doc.name,
            paged: !!p.doc.paged,
            total: p.doc.pages,
            used: Array.from(new Set(p.chunks.map(c => c.n))),
            matched: p.matched
        }));
        return out.length ? out : null;
    }

    function usedNode(docs) {
        if (!Array.isArray(docs) || !docs.length) return null;
        const box = document.createElement('div');
        box.className = 'doc-used';
        for (const d of docs) {
            const line = document.createElement('div');
            const where = (d.used || []).join(', ');
            line.textContent = d.paged
                ? t('Searched {name}, not read whole — used pages {pages} of {total}', { name: d.name, pages: where, total: d.total })
                : t('Searched {name}, not read whole — used parts {pages} of {total}', { name: d.name, pages: where, total: d.total });
            box.appendChild(line);
        }
        return box;
    }

    function files(convId) {
        const out = [];
        for (const e of list(convId)) {
            if (e.kind === 'text') out.push({ name: e.name, text: e.text });
            else if (typeof e.raw === 'string') out.push({ name: e.name, text: e.raw });
            else {
                const body = e.chunks.map(c => c.t).join('\n\n');
                out.push({ name: /\.txt$/i.test(e.name) ? e.name : e.name + '.txt', text: body });
            }
        }
        return out;
    }

    let trayConv = null;

    function renderTray(conv) {
        const tray = document.getElementById('docTray');
        if (!tray) return;
        const convId = conv && conv.id;
        trayConv = convId || null;
        if (convId && !cache.has(convId)) {
            load(convId).then(() => { if (trayConv === convId) renderTray(conv); });
        }
        const docs = convId ? list(convId).filter(e => e.kind === 'doc') : [];
        tray.innerHTML = '';
        if (!docs.length) { tray.hidden = true; return; }
        const label = document.createElement('span');
        label.className = 'doc-tray-label';
        label.textContent = t('Searched in this chat:');
        tray.appendChild(label);
        for (const d of docs) {
            const item = document.createElement('span');
            item.className = 'attach-item doc-item';
            const name = document.createElement('span');
            name.textContent = `${d.name} · ${d.paged ? t('{n} pages', { n: d.pages }) : t('{n} parts', { n: d.pages })}`;
            item.appendChild(name);
            const x = document.createElement('button');
            x.type = 'button';
            x.textContent = '×';
            x.title = t('Remove from this chat');
            x.setAttribute('aria-label', t('Remove from this chat'));
            x.addEventListener('click', async () => {
                await remove(convId, d.id);
                renderTray(conv);
                const U = window.NymbotUI;
                if (U && typeof U.updateHints === 'function') U.updateHints();
            });
            item.appendChild(x);
            tray.appendChild(item);
        }
        tray.hidden = false;
    }

    async function wipe() {
        cache.clear();
        const open = dbp;
        dbp = null;
        try {
            const d = open ? await open : null;
            if (d) d.close();
        } catch (_) { }
        await new Promise((resolve) => {
            try {
                const req = indexedDB.deleteDatabase(DB_NAME);
                req.onsuccess = () => resolve(true);
                req.onerror = () => resolve(false);
                req.onblocked = () => resolve(false);
            } catch (_) {
                resolve(false);
            }
        });
    }

    window.NymbotDocs = {
        INLINE_MAX, CHUNK_TARGET, TURN_BUDGET,
        handles, fromFile, fromText, fromPages,
        tokens, rank, select, chunkText, chunkPages, chunkTable, stripHtml, docxText, unzipEntry,
        load, loaded, list, keep, remove, forget, files, wipe,
        wireFor, usage, usedNode, renderTray
    };
})();
