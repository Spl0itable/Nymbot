(function () {
    'use strict';

    const Store = window.NymbotStore;

    function stamp(ms) {
        const d = new Date(ms || Date.now());
        const pad = (n) => String(n).padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }

    function slug(text) {
        return String(text || 'chat')
            .toLowerCase()
            .replace(/[^\w\s-]/g, '')
            .trim()
            .replace(/\s+/g, '-')
            .slice(0, 48) || 'chat';
    }

    function toMarkdown(conv, messages) {
        const lines = [];
        lines.push(`# ${conv.title || 'New chat'}`);
        lines.push('');
        lines.push(`_${stamp(conv.createdAt)} — ${stamp(conv.updatedAt)}_`);
        if (conv.anon) lines.push('');
        if (conv.anon) lines.push('> This conversation ran on a throwaway key.');
        if (conv.systemPrompt) {
            lines.push('');
            lines.push('## Custom instructions');
            lines.push('');
            lines.push(conv.systemPrompt);
        }
        const repos = (conv.repoIds || []).map(id => Store.repo(id)).filter(Boolean);
        if (repos.length) {
            lines.push('');
            lines.push('## Repositories');
            lines.push('');
            for (const r of repos) {
                lines.push(`- \`${r.repo}\`${r.branch ? ` (${r.branch})` : ''} — ${r.provider}${r.allowWrites ? ', writes on' : ''}`);
            }
        }
        lines.push('');
        lines.push('---');
        for (const m of messages) {
            lines.push('');
            const who = m.role === 'self' ? 'You' : m.role === 'bot' ? 'Nymbot' : m.role === 'error' ? 'Error' : 'Note';
            const meta = [];
            if (m.model) meta.push(m.model);
            if (m.cost) meta.push(`${m.cost} credits`);
            if (m.ts) meta.push(stamp(m.ts));
            lines.push(`### ${who}${meta.length ? ` — ${meta.join(' · ')}` : ''}`);
            lines.push('');
            if (m.thinking) {
                lines.push('<details><summary>Reasoning</summary>');
                lines.push('');
                lines.push(m.thinking);
                lines.push('');
                lines.push('</details>');
                lines.push('');
            }
            lines.push(m.content || '');
            for (const a of m.attachments || []) {
                lines.push('');
                lines.push(a.kind === 'image'
                    ? `![${a.name}](${a.dataUrl})`
                    : `**Attached:** \`${a.name}\``);
            }
        }
        lines.push('');
        return lines.join('\n');
    }

    function toText(conv, messages) {
        const out = [`${conv.title || 'New chat'}`, ''];
        for (const m of messages) {
            const who = m.role === 'self' ? 'you' : m.role === 'bot' ? 'Nymbot' : m.role;
            out.push(`[${who}] ${m.content || ''}`);
            out.push('');
        }
        return out.join('\n');
    }

    function toJson(conv, messages) {
        return JSON.stringify({
            version: 2,
            exportedAt: Date.now(),
            conversations: [{ conversation: conv, messages }]
        }, null, 2);
    }

    function download(name, mime, body) {
        const blob = new Blob([body], { type: mime + ';charset=utf-8' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = name;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 4000);
    }

    const Export = {
        toMarkdown,
        toText,
        toJson,

        conversation(conv, format) {
            const messages = Store.messages(conv.id);
            const base = slug(conv.title);
            if (format === 'json') {
                download(`${base}.json`, 'application/json', toJson(conv, messages));
            } else if (format === 'txt') {
                download(`${base}.txt`, 'text/plain', toText(conv, messages));
            } else {
                download(`${base}.md`, 'text/markdown', toMarkdown(conv, messages));
            }
        },

        everything() {
            download(`nymbot-export-${slug(stamp(Date.now()))}.json`,
                'application/json', JSON.stringify(Store.exportAll(), null, 2));
        },

        clipboardMarkdown(conv) {
            return toMarkdown(conv, Store.messages(conv.id));
        },

        async readFile(file) {
            const text = (file && typeof file.text === 'function')
                ? String(await file.text() || '')
                : await new Promise((resolve, reject) => {
                    if (typeof FileReader === 'undefined') {
                        reject(new Error('unreadable'));
                        return;
                    }
                    const r = new FileReader();
                    r.onload = () => resolve(String(r.result || ''));
                    r.onerror = () => reject(new Error('unreadable'));
                    r.readAsText(file);
                });
            try { return JSON.parse(text); }
            catch (_) { throw new Error('unreadable'); }
        },

        download
    };

    window.NymbotExport = Export;
})();
