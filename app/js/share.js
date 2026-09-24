(function () {
    'use strict';

    const C = window.NymbotConfig;
    const NT = () => window.NostrTools;
    const MD = () => window.NymbotMarkdown;

    const SCHEMA = 1;
    const FORMAT = 1;
    const IV_BYTES = 12;
    const TAG_BYTES = 16;
    const MAX_BYTES = 12 * 1024 * 1024;
    const APP = { name: 'nymbot-web', version: '1.0.0' };
    const RECORDS = C.storagePrefix + 'shares';
    const DEFAULTS = { upTo: null, reasoning: false, sources: true, files: false, images: false };

    function b64url(bytes) {
        let bin = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
            bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    function unb64url(text) {
        const clean = String(text || '');
        if (!/^[A-Za-z0-9_-]+$/.test(clean)) throw new Error('bad base64');
        const std = clean.replace(/-/g, '+').replace(/_/g, '/');
        const bin = atob(std + '==='.slice((std.length + 3) % 4));
        const out = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
        return out;
    }

    function hex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    function unhex(text) {
        const out = new Uint8Array(text.length / 2);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(text.substr(i * 2, 2), 16);
        return out;
    }

    const utf8 = (s) => new TextEncoder().encode(s);
    const unutf8 = (b) => new TextDecoder().decode(b);

    function roleOf(m) {
        if (!m) return null;
        if (m.role === 'self') return 'user';
        if (m.role === 'bot') return 'assistant';
        return null;
    }

    function shareable(messages) {
        return (messages || []).filter(m => roleOf(m)
            && (String(m.content || '').trim() || (m.attachments || []).length));
    }

    function safeLink(url) {
        return typeof url === 'string' && /^https?:\/\//i.test(url) ? url : '';
    }

    function cleanSources(list) {
        if (!Array.isArray(list)) return [];
        const out = [];
        for (const s of list) {
            if (!s || typeof s !== 'object') continue;
            const url = safeLink(s.url);
            if (!url) continue;
            const title = String(s.title || s.name || '').slice(0, 300);
            out.push(title ? { url, title } : { url });
        }
        return out.slice(0, 20);
    }

    function build(conv, messages, options) {
        const o = Object.assign({}, DEFAULTS, options || {});
        const list = shareable(messages);
        let end = list.length;
        if (o.upTo) {
            const at = list.findIndex(m => m.id === o.upTo);
            if (at !== -1) end = at + 1;
        }
        const out = [];
        for (const m of list.slice(0, end)) {
            const role = roleOf(m);
            const item = {
                role,
                content: String(m.content || ''),
                model: role === 'assistant' && m.model ? String(m.model) : null,
                ts: typeof m.ts === 'number' ? m.ts : null
            };
            if (o.sources) {
                const sources = cleanSources(m.sources);
                if (sources.length) item.sources = sources;
            }
            if (o.reasoning && m.thinking) item.reasoning = String(m.thinking);
            const files = [];
            for (const a of m.attachments || []) {
                if (a.kind === 'image' && o.images && /^data:image\/(png|jpe?g|gif|webp|avif);base64,/i.test(a.dataUrl || '')) {
                    files.push({ kind: 'image', name: String(a.name || 'image'), data: a.dataUrl });
                } else if (a.kind === 'text' && o.files) {
                    files.push({ kind: 'text', name: String(a.name || 'file'), text: typeof a.text === 'string' ? a.text : null });
                }
            }
            if (files.length) item.attachments = files;
            if (!item.content.trim() && !files.length) continue;
            out.push(item);
        }
        return {
            v: SCHEMA,
            title: String((conv && conv.title) || ''),
            sharedAt: Date.now(),
            app: Object.assign({}, APP),
            messages: out
        };
    }

    function valid(transcript) {
        return !!transcript && typeof transcript === 'object' && transcript.v === SCHEMA
            && Array.isArray(transcript.messages)
            && transcript.messages.every(m => m && (m.role === 'user' || m.role === 'assistant')
                && typeof m.content === 'string');
    }

    async function seal(transcript, fixed) {
        const f = fixed || {};
        const key = f.key || crypto.getRandomValues(new Uint8Array(32));
        const iv = f.iv || crypto.getRandomValues(new Uint8Array(IV_BYTES));
        const k = await crypto.subtle.importKey('raw', key, 'AES-GCM', false, ['encrypt']);
        const plain = utf8(typeof transcript === 'string' ? transcript : JSON.stringify(transcript));
        const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, tagLength: 128 }, k, plain));
        const bytes = new Uint8Array(1 + IV_BYTES + ct.length);
        bytes[0] = FORMAT;
        bytes.set(iv, 1);
        bytes.set(ct, 1 + IV_BYTES);
        return { bytes, key };
    }

    async function open(bytes, key) {
        const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
        if (data.length < 1 + IV_BYTES + TAG_BYTES || data[0] !== FORMAT) throw new Error('format');
        if (!key || key.length !== 32) throw new Error('key');
        const k = await crypto.subtle.importKey('raw', key, 'AES-GCM', false, ['decrypt']);
        const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: data.subarray(1, 1 + IV_BYTES), tagLength: 128 },
            k, data.subarray(1 + IV_BYTES));
        const transcript = JSON.parse(unutf8(new Uint8Array(plain)));
        if (!valid(transcript)) throw new Error('schema');
        return transcript;
    }

    function origin() {
        return location.protocol === 'https:' ? location.origin : `https://${C.apiHost}`;
    }

    function link(ref, key, base) {
        const head = b64url(utf8(JSON.stringify({ v: 1, s: ref.server, x: ref.sha256 })));
        return `${base || origin()}/app/share#${head}.${b64url(key)}`;
    }

    function parse(fragment) {
        const raw = String(fragment || '').replace(/^#/, '').trim();
        const dot = raw.indexOf('.');
        if (dot < 1) throw new Error('bad link');
        const head = JSON.parse(unutf8(unb64url(raw.slice(0, dot))));
        const key = unb64url(raw.slice(dot + 1));
        const server = String((head && head.s) || '');
        const sha256 = String((head && head.x) || '').toLowerCase();
        if (!/^https:\/\/[a-z0-9.-]+$/i.test(server)) throw new Error('bad server');
        if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error('bad hash');
        if (key.length !== 32) throw new Error('bad key');
        return { server, sha256, key };
    }

    function blobUrl(ref) {
        return `https://${C.apiHost}/api/proxy?action=share-blob&server=${encodeURIComponent(ref.server)}`
            + `&x=${encodeURIComponent(ref.sha256)}`;
    }

    async function sha256Hex(bytes) {
        return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
    }

    async function fetchBlob(ref, fetcher) {
        const resp = await (fetcher || fetch)(blobUrl(ref), { cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer' });
        if (resp.status === 404 || resp.status === 410) throw Object.assign(new Error('gone'), { gone: true });
        if (!resp.ok) throw new Error('HTTP ' + resp.status);
        const bytes = new Uint8Array(await resp.arrayBuffer());
        if (await sha256Hex(bytes) !== ref.sha256) throw new Error('hash');
        return bytes;
    }

    function proxied(url) {
        if (!/^https?:\/\//i.test(url)) return url;
        try {
            const u = new URL(url);
            if (u.origin === location.origin || (u.protocol === 'https:' && u.hostname === C.apiHost)) return url;
        } catch (_) { return url; }
        return `https://${C.apiHost}/api/proxy?url=${encodeURIComponent(url)}`;
    }

    function hostOf(url) {
        try { return new URL(url).hostname.replace(/^www\./, ''); } catch (_) { return ''; }
    }

    function stamp(ms) {
        if (!ms) return '';
        try {
            return new Date(ms).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
        } catch (_) { return new Date(ms).toISOString(); }
    }

    function el(tag, cls, text) {
        const node = document.createElement(tag);
        if (cls) node.className = cls;
        if (text != null) node.textContent = text;
        return node;
    }

    function messageNode(m) {
        const self = m.role === 'user';
        const node = el('div', 'chat-message share-message' + (self ? ' self' : ''));
        node.dataset.role = m.role;
        const who = el('span', 'message-author' + (self ? '' : ' bot-author'));
        who.appendChild(document.createTextNode(self ? t('User') : C.botName));
        if (m.model) who.appendChild(el('span', 'author-model', m.model));
        if (m.ts) who.appendChild(el('span', 'author-model', stamp(m.ts)));
        node.appendChild(who);
        const body = el('div', 'message-content');
        if (Array.isArray(m.attachments) && m.attachments.length) {
            const tray = el('div', 'msg-attachments');
            for (const a of m.attachments) {
                const chip = el('span', 'msg-attachment');
                if (a.kind === 'image' && /^data:image\//i.test(a.data || '')) {
                    const img = document.createElement('img');
                    img.src = a.data;
                    img.alt = a.name || '';
                    chip.appendChild(img);
                }
                chip.appendChild(el('span', null, a.name || t('file')));
                tray.appendChild(chip);
                if (a.kind === 'text' && typeof a.text === 'string') {
                    const pre = el('pre', 'share-file', a.text);
                    tray.appendChild(pre);
                }
            }
            body.appendChild(tray);
        }
        if (m.reasoning) {
            const details = el('details', 'share-reasoning');
            details.appendChild(el('summary', 'reasoning-chip', t('Reasoning')));
            details.appendChild(el('div', 'reasoning-body', m.reasoning));
            body.appendChild(details);
        }
        const text = el('div', 'msg-text');
        text.innerHTML = MD().render(m.content || '', { wrap: true, lineNumbers: false, media: null });
        for (const b of text.querySelectorAll('[data-act="code-preview"], [data-act="code-download"], [data-act="save-media"]')) b.remove();
        for (const media of text.querySelectorAll('img, audio, video, source')) {
            const src = media.getAttribute('src');
            if (src) media.setAttribute('src', proxied(src));
            media.setAttribute('referrerpolicy', 'no-referrer');
            const box = media.closest('.msg-media-box');
            if (box) {
                const settle = () => box.classList.remove('is-loading');
                for (const type of ['load', 'loadedmetadata', 'error']) media.addEventListener(type, settle);
            }
        }
        body.appendChild(text);
        if (Array.isArray(m.sources) && m.sources.length) {
            const wrap = el('div', 'share-sources');
            wrap.appendChild(el('p', 'citations-head',
                m.sources.length === 1 ? t('1 source') : t('{n} sources', { n: m.sources.length })));
            const list = el('ol');
            for (const s of m.sources) {
                const url = safeLink(s.url);
                if (!url) continue;
                const li = el('li');
                const a = el('a', null, s.title || hostOf(url) || url);
                a.href = url;
                a.target = '_blank';
                a.rel = 'noopener noreferrer';
                li.appendChild(a);
                const host = hostOf(url);
                if (host && s.title) li.appendChild(el('span', 'share-source-host', host));
                list.appendChild(li);
            }
            wrap.appendChild(list);
            body.appendChild(wrap);
        }
        node.appendChild(body);
        return node;
    }

    function render(root, transcript) {
        root.innerHTML = '';
        for (const m of transcript.messages) root.appendChild(messageNode(m));
        return root;
    }

    function summary(transcript) {
        const msgs = transcript.messages;
        const sources = msgs.reduce((n, m) => n + (m.sources ? m.sources.length : 0), 0);
        const images = msgs.reduce((n, m) => n + (m.attachments || []).filter(a => a.kind === 'image').length, 0);
        const files = msgs.reduce((n, m) => n + (m.attachments || []).filter(a => a.kind === 'text').length, 0);
        const reasoning = msgs.filter(m => m.reasoning).length;
        const parts = [msgs.length === 1 ? t('1 message') : t('{n} messages', { n: msgs.length })];
        if (sources) parts.push(sources === 1 ? t('1 source') : t('{n} sources', { n: sources }));
        if (reasoning) parts.push(t('reasoning on {n}', { n: reasoning }));
        if (files) parts.push(files === 1 ? t('1 file') : t('{n} files', { n: files }));
        if (images) parts.push(images === 1 ? t('1 image') : t('{n} images', { n: images }));
        return parts.join(' · ');
    }

    function readAll() {
        const S = window.NymbotStore;
        try {
            const raw = S ? null : localStorage.getItem(RECORDS);
            const parsed = S ? S.read('shares', {}) : (raw ? JSON.parse(raw) : {});
            return parsed && typeof parsed === 'object' ? parsed : {};
        } catch (_) { return {}; }
    }

    function writeAll(all) {
        const S = window.NymbotStore;
        if (S) {
            S.quiet(() => S.write('shares', all));
            return;
        }
        try { localStorage.setItem(RECORDS, JSON.stringify(all)); } catch (_) { }
    }

    function records(convId) {
        const list = readAll()[convId];
        return Array.isArray(list) ? list : [];
    }

    function remember(convId, record) {
        const all = readAll();
        all[convId] = records(convId).concat([record]);
        writeAll(all);
    }

    function patchRecord(convId, id, patch) {
        const all = readAll();
        all[convId] = records(convId).map(r => (r.id === id ? Object.assign({}, r, patch) : r));
        writeAll(all);
    }

    function forget(convId, id) {
        const all = readAll();
        const next = records(convId).filter(r => r.id !== id);
        if (next.length) all[convId] = next; else delete all[convId];
        writeAll(all);
    }

    function signerFor(skHex) {
        const sk = unhex(skHex);
        const pubkey = NT().getPublicKey(sk);
        return { pubkey, sign: (evt) => NT().finalizeEvent(Object.assign({ pubkey }, evt), sk) };
    }

    async function create(conv, messages, options) {
        const transcript = build(conv, messages, options);
        if (!transcript.messages.length) throw new Error(t('There is nothing to share in this chat yet.'));
        const sealed = await seal(transcript);
        if (sealed.bytes.length > MAX_BYTES) {
            throw new Error(t('That is too large to share. Leave the images out, or share less of the chat.'));
        }
        const sk = NT().generateSecretKey();
        const skHex = hex(sk);
        const placed = await window.NymbotBlossom.place(sealed.bytes, 'application/octet-stream',
            { signer: signerFor(skHex) });
        const o = Object.assign({}, DEFAULTS, options || {});
        const record = {
            id: hex(crypto.getRandomValues(new Uint8Array(8))),
            link: link({ server: placed.host, sha256: placed.sha256 }, sealed.key),
            server: placed.host,
            sha256: placed.sha256,
            createdAt: transcript.sharedAt,
            included: {
                messages: transcript.messages.length,
                upTo: o.upTo || null,
                reasoning: !!o.reasoning,
                sources: !!o.sources,
                files: !!o.files,
                images: !!o.images
            },
            sk: skHex,
            notes: []
        };
        remember(conv.id, record);
        return record;
    }

    async function stop(convId, record) {
        let status = 0;
        try {
            status = await window.NymbotBlossom.remove(record.server, record.sha256, { signer: signerFor(record.sk) });
        } catch (_) { status = 0; }
        forget(convId, record.id);
        return { deleted: status === 200 };
    }

    async function postNote(conv, record, comment) {
        if (!conv || conv.anon) throw new Error(t('An anonymous chat cannot be posted under your key.'));
        const note = String(comment || '').trim();
        const signed = await window.NymbotIdentity.signEvent({
            kind: 1,
            created_at: Math.floor(Date.now() / 1000),
            tags: [],
            content: note ? `${note}\n\n${record.link}` : record.link
        });
        const accepted = await window.NymbotRelays.publish(signed, 5000);
        if (accepted) patchRecord(conv.id, record.id, { notes: (record.notes || []).concat([signed.id]) });
        return accepted;
    }

    function includedText(inc) {
        const parts = [inc.messages === 1 ? t('1 message') : t('{n} messages', { n: inc.messages })];
        if (inc.sources) parts.push(t('sources'));
        if (inc.reasoning) parts.push(t('reasoning'));
        if (inc.files) parts.push(t('attached text'));
        if (inc.images) parts.push(t('images'));
        return parts.join(', ');
    }

    const Panel = {
        ui: null,
        conv: null,
        bound: false,

        $(id) { return document.getElementById(id); },

        options() {
            return {
                upTo: this.$('shareUpTo').value || null,
                sources: this.$('shareSources').checked,
                reasoning: this.$('shareReasoning').checked,
                files: this.$('shareFiles').checked,
                images: this.$('shareImages').checked
            };
        },

        bind() {
            if (this.bound) return;
            this.bound = true;
            for (const id of ['shareUpTo', 'shareSources', 'shareReasoning', 'shareFiles', 'shareImages']) {
                this.$(id).addEventListener('change', () => this.preview());
            }
            this.$('shareCreate').addEventListener('click', () => this.create());
            this.$('shareCopy').addEventListener('click', () => this.ui.writeClipboard(this.$('shareLink').value));
            this.$('shareSend').addEventListener('click', () => {
                navigator.share({ title: this.conv.title || t('Shared chat'), url: this.$('shareLink').value }).catch(() => { });
            });
            this.$('sharePost').addEventListener('click', () => this.post());
            this.$('shareList').addEventListener('click', (e) => {
                const btn = e.target.closest('button[data-share]');
                if (!btn) return;
                const record = records(this.conv.id).find(r => r.id === btn.dataset.share);
                if (!record) return;
                if (btn.dataset.do === 'copy') this.ui.writeClipboard(record.link);
                else if (btn.dataset.do === 'stop') this.stop(record);
            });
        },

        openFor(ui, conv) {
            this.ui = ui;
            this.conv = conv;
            this.bind();
            this.current = null;
            const select = this.$('shareUpTo');
            select.innerHTML = '';
            const whole = el('option', null, t('The whole chat'));
            whole.value = '';
            select.appendChild(whole);
            const list = shareable(window.NymbotStore.messages(conv.id));
            list.forEach((m, i) => {
                if (i === list.length - 1) return;
                const who = m.role === 'self' ? t('You') : C.botName;
                const text = (MD().plain(m.content || '') || t('(attachment)')).slice(0, 60);
                const opt = el('option', null, t('Up to {n}. {who}: {text}', { n: i + 1, who, text }));
                opt.value = m.id;
                select.appendChild(opt);
            });
            this.$('shareSources').checked = true;
            this.$('shareReasoning').checked = false;
            this.$('shareFiles').checked = false;
            this.$('shareImages').checked = false;
            this.$('shareResult').hidden = true;
            this.$('shareCreate').disabled = false;
            ui.modalStatus('shareStatus', '');
            this.preview();
            this.renderList();
            ui.openModal('modalShareChat');
        },

        preview() {
            const transcript = build(this.conv, window.NymbotStore.messages(this.conv.id), this.options());
            render(this.$('sharePreview'), transcript);
            this.$('shareSummary').textContent = summary(transcript);
            this.$('shareCreate').disabled = !transcript.messages.length;
        },

        async create() {
            const button = this.$('shareCreate');
            button.disabled = true;
            this.ui.modalStatus('shareStatus', t('Encrypting and uploading…'));
            try {
                const record = await create(this.conv, window.NymbotStore.messages(this.conv.id), this.options());
                this.current = record;
                this.$('shareLink').value = record.link;
                this.$('shareResult').hidden = false;
                this.$('shareSend').hidden = typeof navigator.share !== 'function';
                this.$('sharePost').hidden = !!this.conv.anon;
                this.ui.modalStatus('shareStatus',
                    t('Anyone with this link can read what you included. The host only holds ciphertext; the key is in the link.'), 'ok');
                this.renderList();
            } catch (e) {
                this.ui.modalStatus('shareStatus', (e && e.message) || t('The request failed.'), 'warn');
            } finally {
                button.disabled = false;
            }
        },

        renderList() {
            const box = this.$('shareList');
            const list = records(this.conv.id);
            box.innerHTML = '';
            this.$('shareListHead').hidden = !list.length;
            for (const r of list.slice().reverse()) {
                const row = el('div', 'share-record');
                const main = el('div', 'share-record-main');
                main.appendChild(el('strong', null, stamp(r.createdAt)));
                main.appendChild(el('span', null, includedText(r.included || {})));
                main.appendChild(el('span', 'share-record-host', hostOf(r.server)));
                row.appendChild(main);
                const copy = el('button', 'btn btn-small', t('Copy'));
                copy.type = 'button';
                copy.dataset.share = r.id;
                copy.dataset.do = 'copy';
                const stopBtn = el('button', 'btn btn-small btn-danger', t('Stop sharing'));
                stopBtn.type = 'button';
                stopBtn.dataset.share = r.id;
                stopBtn.dataset.do = 'stop';
                row.appendChild(copy);
                row.appendChild(stopBtn);
                box.appendChild(row);
            }
        },

        async stop(record) {
            const ok = await this.ui.ask({
                title: t('Stop sharing'),
                body: t('This deletes the encrypted copy from the media host and forgets the link on this device. Anyone who already opened it may have kept a copy, and that cannot be taken back.'),
                confirm: t('Stop sharing'),
                danger: true
            });
            if (!ok) return;
            this.ui.modalStatus('shareStatus', t('Deleting…'));
            const result = await stop(this.conv.id, record);
            if (this.current && this.current.id === record.id) {
                this.current = null;
                this.$('shareResult').hidden = true;
            }
            this.renderList();
            this.ui.modalStatus('shareStatus', result.deleted
                ? t('Deleted from the host. The link no longer opens. Anyone who already opened it may have kept a copy.')
                : t('The host did not confirm the delete, so the encrypted copy may stay there until it expires. The link is forgotten on this device. Anyone who already opened it may have kept a copy.'),
            result.deleted ? 'ok' : 'warn');
        },

        async post() {
            if (!this.current || this.conv.anon) return;
            const comment = await this.ui.ask({
                title: t('Post to Nostr'),
                body: t('This publishes a public note, signed by your key, that anyone can read and that cannot be reliably deleted. It contains the link, so anyone who sees the note can open this chat.'),
                area: true,
                label: t('Comment (optional)'),
                check: t('I understand this note is public and signed by my key'),
                confirm: t('Post publicly')
            });
            if (comment == null) return;
            if (!this.ui.dialogChecked) {
                this.ui.modalStatus('shareStatus', t('Nothing was posted. Tick the box to confirm it is public.'), 'warn');
                return;
            }
            this.ui.modalStatus('shareStatus', t('Publishing…'));
            try {
                const accepted = await postNote(this.conv, this.current, comment);
                this.ui.modalStatus('shareStatus', accepted
                    ? t('Posted to {n} relays.', { n: accepted })
                    : t('No relay accepted it. Check your connection and try again.'), accepted ? 'ok' : 'warn');
            } catch (e) {
                this.ui.modalStatus('shareStatus', (e && e.message) || t('The request failed.'), 'warn');
            }
        }
    };

    window.NymbotShare = {
        SCHEMA,
        FORMAT,
        DEFAULTS,
        build,
        valid,
        seal,
        open,
        link,
        parse,
        blobUrl,
        fetchBlob,
        render,
        summary,
        records,
        create,
        stop,
        postNote,
        b64url,
        unb64url,
        hex,
        unhex,
        openFor: (ui, conv) => Panel.openFor(ui, conv),
        panel: Panel
    };
})();
