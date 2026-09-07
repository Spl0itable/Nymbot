(function () {
    'use strict';

    const Store = window.NymbotStore;

    const MIN_LINES = 12;
    const MIN_CHARS = 320;
    const CAP = 60;

    const PREVIEWABLE = new Set(['html', 'svg', 'xml', 'markdown', 'md']);

    const TITLES = {
        html: 'Page', svg: 'Drawing', markdown: 'Document', md: 'Document',
        json: 'Data', csv: 'Table', sql: 'Query', diff: 'Patch', sh: 'Script'
    };

    function titleFor(lang, body) {
        const text = String(body || '');
        const title = /<title>([^<]{1,48})<\/title>/i.exec(text);
        if (title) return title[1].trim();
        const heading = /^#{1,3}\s+(.+)$/m.exec(text);
        if (heading) return heading[1].slice(0, 48);
        // \b matters: without it `<!doctype html>` reads as `type html`.
        const named = /\b(?:class|function|def|const|interface|struct|fn|type)\s+([A-Za-z_$][\w$]*)/.exec(text);
        if (named) return named[1];
        if (TITLES[lang]) return TITLES[lang];
        const first = text.split('\n').find(l => l.trim());
        return (first || 'Snippet').replace(/^[^\w<]+/, '').slice(0, 40) || 'Snippet';
    }

    function worthLifting(body, lang) {
        const text = String(body || '');
        if (!text.trim()) return false;
        const lines = text.split('\n').length;
        if (PREVIEWABLE.has(String(lang || '').toLowerCase())) return lines >= 4;
        return lines >= MIN_LINES || text.length >= MIN_CHARS;
    }

    function fences(markdown) {
        const out = [];
        const lines = String(markdown || '').replace(/\r\n/g, '\n').split('\n');
        let i = 0;
        while (i < lines.length) {
            const open = /^\s*(?:```|~~~)([\w+#.-]*)\s*$/.exec(lines[i]);
            if (!open) { i++; continue; }
            const lang = (open[1] || '').toLowerCase();
            const body = [];
            i++;
            while (i < lines.length && !/^\s*(?:```|~~~)\s*$/.test(lines[i])) body.push(lines[i++]);
            i++;
            out.push({ lang, body: body.join('\n') });
        }
        return out;
    }

    const Artifacts = {
        // A file lifted out of a ghost chat is still that chat: it stays in
        // memory with the rest of it.
        _ghosts: new Map(),

        all(convId) {
            if (Store.isGhost(convId)) return (this._ghosts.get(convId) || []).slice();
            const list = Store.read('artifacts_' + convId, []);
            return Array.isArray(list) ? list : [];
        },

        save(convId, list) {
            const kept = list.slice(-CAP);
            if (Store.isGhost(convId)) {
                this._ghosts.set(convId, kept);
                Store.drop('artifacts_' + convId);
                return;
            }
            this._ghosts.delete(convId);
            Store.write('artifacts_' + convId, kept);
        },

        get(convId, id) {
            return this.all(convId).find(a => a.id === id) || null;
        },

        create(convId, { title, lang, body, messageId }) {
            const list = this.all(convId);
            const entry = {
                id: Store.uid(),
                convId,
                messageId: messageId || null,
                title: title || titleFor(lang, body),
                lang: lang || '',
                body: body || '',
                versions: [{ at: Date.now(), body: body || '', note: 'first draft' }],
                createdAt: Date.now(),
                updatedAt: Date.now()
            };
            list.push(entry);
            this.save(convId, list);
            return entry;
        },

        update(convId, id, body, note) {
            const list = this.all(convId);
            const i = list.findIndex(a => a.id === id);
            if (i === -1) return null;
            const entry = list[i];
            if (entry.body === body) return entry;
            entry.versions = (entry.versions || []).concat([
                { at: Date.now(), body, note: note || 'edited here' }
            ]).slice(-30);
            entry.body = body;
            entry.updatedAt = Date.now();
            this.save(convId, list);
            return entry;
        },

        rename(convId, id, title) {
            const list = this.all(convId);
            const entry = list.find(a => a.id === id);
            if (!entry) return null;
            entry.title = title;
            entry.updatedAt = Date.now();
            this.save(convId, list);
            return entry;
        },

        revert(convId, id, index) {
            const entry = this.get(convId, id);
            if (!entry) return null;
            const version = (entry.versions || [])[index];
            if (!version) return entry;
            return this.update(convId, id, version.body, 'reverted');
        },

        remove(convId, id) {
            this.save(convId, this.all(convId).filter(a => a.id !== id));
        },

        drop(convId) {
            this._ghosts.delete(convId);
            Store.drop('artifacts_' + convId);
        },

        /// Lifts the substantial code blocks out of a reply. A block already
        /// carried by an earlier version of the same artifact updates it
        /// rather than piling up a second copy of the same file.
        harvest(convId, message) {
            if (!message || message.role !== 'bot') return [];
            const made = [];
            const existing = this.all(convId);
            for (const block of fences(message.content)) {
                if (!worthLifting(block.body, block.lang)) continue;
                const title = titleFor(block.lang, block.body);
                const prior = existing.find(a => a.title === title && a.lang === block.lang);
                if (prior) {
                    const updated = this.update(convId, prior.id, block.body, 'rewritten in chat');
                    if (updated) made.push(updated);
                } else {
                    made.push(this.create(convId, {
                        title, lang: block.lang, body: block.body, messageId: message.id
                    }));
                }
            }
            return made;
        },

        previewable(lang) {
            return PREVIEWABLE.has(String(lang || '').toLowerCase());
        },

        extensionFor(lang) {
            const map = {
                js: 'js', jsx: 'jsx', ts: 'ts', tsx: 'tsx', dart: 'dart', py: 'py',
                rb: 'rb', go: 'go', rust: 'rs', java: 'java', c: 'c', cpp: 'cpp',
                sh: 'sh', bash: 'sh', sql: 'sql', json: 'json', yaml: 'yml',
                html: 'html', css: 'css', svg: 'svg', xml: 'xml', markdown: 'md',
                md: 'md', csv: 'csv', diff: 'diff'
            };
            return map[String(lang || '').toLowerCase()] || 'txt';
        },

        titleFor,
        worthLifting,
        fences
    };

    window.NymbotArtifacts = Artifacts;
})();
