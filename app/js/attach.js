(function () {
    'use strict';

// A file travels inside the message rather than beside it, and a long message
// is split across several wraps — so the cap is about what a model will
// usefully read in one turn, not about what one event can hold. A document
// past this belongs in a workspace, which searches the whole of it rather
// than sending it.
    const MAX_TEXT_BYTES = 96 * 1024;
    const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
    const MAX_IMAGE_EDGE = 1280;

    const TEXTUAL = /\.(txt|md|markdown|json|jsonl|ya?ml|toml|ini|cfg|conf|env|csv|tsv|log|sql|sh|bash|zsh|fish|ps1|bat|js|mjs|cjs|jsx|ts|tsx|dart|py|rb|go|rs|java|kt|kts|swift|c|h|cc|cpp|hpp|cs|php|lua|r|scala|clj|ex|exs|erl|hs|ml|vue|svelte|html|htm|xml|svg|css|scss|less|gradle|properties|lock|diff|patch|gitignore|dockerfile|makefile)$/i;

    function looksTextual(file) {
        if (!file) return false;
        if (/^text\//i.test(file.type)) return true;
        if (/^application\/(json|xml|x-yaml|yaml|javascript|x-sh|sql)/i.test(file.type)) return true;
        if (!file.type && TEXTUAL.test(file.name || '')) return true;
        return TEXTUAL.test(file.name || '');
    }

    function langFor(name) {
        const ext = String(name || '').split('.').pop().toLowerCase();
        const map = {
            js: 'js', mjs: 'js', cjs: 'js', jsx: 'jsx', ts: 'ts', tsx: 'tsx',
            dart: 'dart', py: 'py', rb: 'ruby', go: 'go', rs: 'rust', java: 'java',
            kt: 'kotlin', swift: 'swift', c: 'c', h: 'c', cc: 'cpp', cpp: 'cpp', hpp: 'cpp',
            cs: 'csharp', php: 'php', lua: 'lua', sh: 'sh', bash: 'sh', zsh: 'sh',
            sql: 'sql', json: 'json', yml: 'yaml', yaml: 'yaml', toml: 'toml',
            md: 'markdown', markdown: 'markdown', html: 'html', htm: 'html', xml: 'xml',
            svg: 'svg', css: 'css', scss: 'scss', less: 'less', csv: 'csv',
            diff: 'diff', patch: 'diff', vue: 'html', svelte: 'html'
        };
        return map[ext] || '';
    }

    function readAsText(file) {
        return new Promise((resolve, reject) => {
            const r = new FileReader();
            r.onload = () => resolve(String(r.result || ''));
            r.onerror = () => reject(new Error('unreadable'));
            r.readAsText(file);
        });
    }

    function readAsDataUrl(file) {
        return new Promise((resolve, reject) => {
            const r = new FileReader();
            r.onload = () => resolve(String(r.result || ''));
            r.onerror = () => reject(new Error('unreadable'));
            r.readAsDataURL(file);
        });
    }

    function shrinkImage(dataUrl, type) {
        return new Promise((resolve) => {
            const img = new Image();
            img.onload = () => {
                const scale = Math.min(1, MAX_IMAGE_EDGE / Math.max(img.width, img.height));
                if (scale >= 1) { resolve(dataUrl); return; }
                const canvas = document.createElement('canvas');
                canvas.width = Math.round(img.width * scale);
                canvas.height = Math.round(img.height * scale);
                const ctx = canvas.getContext('2d');
                if (!ctx) { resolve(dataUrl); return; }
                ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                try {
                    resolve(canvas.toDataURL(type === 'image/png' ? 'image/png' : 'image/jpeg', 0.85));
                } catch (_) { resolve(dataUrl); }
            };
            img.onerror = () => resolve(dataUrl);
            img.src = dataUrl;
        });
    }

    async function fromFile(file) {
        if (!file) return null;
        if (/^image\//i.test(file.type)) {
            if (file.size > MAX_IMAGE_BYTES) throw new Error(t('That image is too large — 4 MB is the limit.'));
            const raw = await readAsDataUrl(file);
            const shrunk = await shrinkImage(raw, file.type);
            return {
                id: window.NymbotStore.uid(),
                kind: 'image',
                name: file.name || 'image',
                mime: file.type,
                size: file.size,
                dataUrl: shrunk
            };
        }
        if (!looksTextual(file)) throw new Error(t('Only text, code and image files can be attached.'));
        if (file.size > MAX_TEXT_BYTES) throw new Error(t('That file is too large to send in a message — 96 KB is the limit. Add it to a workspace instead, where the whole file is searched.'));
        const text = await readAsText(file);
        return {
            id: window.NymbotStore.uid(),
            kind: 'text',
            name: file.name || 'file.txt',
            mime: file.type || 'text/plain',
            size: file.size,
            lang: langFor(file.name),
            text
        };
    }

    // A wall of pasted text is a document, not a sentence. Past this it goes in
    // as an attachment rather than filling the composer, so the question you
    // are asking about it stays readable — and so the composer does not become
    // a scroll view of somebody's log file.
    const PASTE_AS_FILE_CHARS = 1500;
    const PASTE_AS_FILE_LINES = 30;

    function pasteIsLong(text) {
        const body = String(text || '');
        if (body.length >= PASTE_AS_FILE_CHARS) return true;
        return body.split('\n').length >= PASTE_AS_FILE_LINES;
    }

    /// Wraps pasted or dropped text as an attachment. Named rather than
    /// guessed at: calling it a .txt it is not would be worse than saying
    /// plainly where it came from.
    function fromText(text, name) {
        const body = String(text || '');
        const kept = body.length > MAX_TEXT_BYTES ? body.slice(0, MAX_TEXT_BYTES) : body;
        return {
            id: window.NymbotStore.uid(),
            kind: 'text',
            name: name || t('Pasted text'),
            mime: 'text/plain',
            size: kept.length,
            lang: '',
            lines: kept.split('\n').length,
            text: kept,
            truncated: kept.length < body.length
        };
    }

    async function fromClipboard(items) {
        const out = [];
        for (const item of items || []) {
            if (item.kind !== 'file') continue;
            const file = item.getAsFile();
            if (!file) continue;
            try {
                const built = await fromFile(file);
                if (built) out.push(built);
            } catch (_) { }
        }
        return out;
    }

    /// What an attachment looks like inside the message.
    function wireBlock(attachment) {
        if (!attachment) return '';
        if (attachment.kind === 'text') {
            return `\n\n--- attached file: ${attachment.name} ---\n\`\`\`${attachment.lang || ''}\n${attachment.text}\n\`\`\``;
        }
        if (attachment.url) {
            return `\n\n--- attached image: ${attachment.name} ---\n${attachment.url}`;
        }
        // Not uploaded, so say so rather than implying the model can see it.
        return `\n\n--- attached image: ${attachment.name} (${Math.round((attachment.size || 0) / 1024)} KB, could not be uploaded — you cannot see this one) ---`;
    }

    function humanSize(bytes) {
        const n = Number(bytes) || 0;
        if (n < 1024) return n + ' B';
        if (n < 1024 * 1024) return Math.round(n / 1024) + ' KB';
        return (n / (1024 * 1024)).toFixed(1) + ' MB';
    }

    window.NymbotAttach = {
        fromFile, fromClipboard, fromText, pasteIsLong,
        wireBlock, humanSize, looksTextual, langFor
    };
})();
