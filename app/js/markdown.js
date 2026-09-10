(function () {
    'use strict';

    const HL = () => window.NymbotHighlight;

    function esc(s) {
        return String(s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    function safeUrl(href) {
        const u = String(href || '').trim();
        return /^(https?:\/\/|mailto:|lightning:|bitcoin:|nostr:)/i.test(u) ? u : '';
    }

    function inline(text) {
        let out = esc(text);

        const codes = [];
        out = out.replace(/`([^`\n]+)`/g, (_, c) => {
            codes.push(c);
            return `@@NYMCODE${codes.length - 1}@@`;
        });

        out = out.replace(/!\[([^\]\n]*)\]\(([^)\s]+)\)/g, (m, alt, href) => {
            const u = safeUrl(href);
            return u ? `<img class="msg-media" src="${esc(u)}" alt="${alt}" loading="lazy">` : m;
        });
        out = out.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (m, label, href) => {
            const u = safeUrl(href);
            return u ? `<a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${label}</a>` : m;
        });
        out = out.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, (m, pre, u) =>
            `${pre}<a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${esc(u)}</a>`);

        out = out.replace(/\*\*\*([^*\n]+)\*\*\*/g, '<strong><em>$1</em></strong>');
        out = out.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
        out = out.replace(/(^|[^*\w])\*([^*\n]+)\*(?!\w)/g, '$1<em>$2</em>');
        out = out.replace(/(^|[^_\w])__([^_\n]+)__(?!\w)/g, '$1<strong>$2</strong>');
        out = out.replace(/(^|[^_\w])_([^_\n]+)_(?!\w)/g, '$1<em>$2</em>');
        out = out.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');
        out = out.replace(/==([^=\n]+)==/g, '<mark>$1</mark>');
        out = out.replace(/\^\(([^)\n]+)\)/g, '<sup>$1</sup>');
        out = out.replace(/\[\^(\d+)\]/g, '<sup class="md-footnote">$1</sup>');
        out = out.replace(/(^|[^\\$])\$([^$\n]{1,200})\$(?!\d)/g, (m, pre, body) =>
            `${pre}<span class="md-math">${body}</span>`);

        out = out.replace(/@@NYMCODE(\d+)@@/g, (_, i) => `<code>${codes[Number(i)]}</code>`);
        return out;
    }

    const SAVE_ICON = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none"'
        + ' stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'
        + '<path d="M12 3v12"></path><polyline points="7 11 12 16 17 11"></polyline>'
        + '<path d="M4 20h16"></path></svg>';

    function mediaBox(inner, url) {
        return `<figure class="msg-media-box">${inner}`
            + `<button class="msg-media-save" type="button" data-act="save-media"`
            + ` data-url="${esc(url)}" title="${esc(t('Save this file'))}"`
            + ` aria-label="${esc(t('Save this file'))}">${SAVE_ICON}</button></figure>`;
    }

    function mediaFor(url, kind) {
        const bare = !/\.[a-z0-9]{2,5}(\?|$)/i.test(url);
        if (/\.(png|jpe?g|gif|webp|avif|bmp)(\?|$)/i.test(url) || (bare && kind === 'image')) {
            return mediaBox(`<img class="msg-media" src="${esc(url)}" alt="" loading="lazy">`, url);
        }
        if (/\.(mp3|wav|ogg|m4a|opus|flac)(\?|$)/i.test(url) || (bare && kind === 'speak')) {
            return mediaBox(`<audio class="msg-media" controls preload="none" src="${esc(url)}"></audio>`, url);
        }
        if (/\.(mp4|webm|mov)(\?|$)/i.test(url) || (bare && kind === 'video')) {
            return mediaBox(`<video class="msg-media" controls preload="none" src="${esc(url)}"></video>`, url);
        }
        return null;
    }

    /// Splits a unified diff into files, counted, so a patch can be read as a
    /// patch rather than as coloured text. Anything before the first file
    /// header is kept under an empty path, so a bare hunk still renders.
    function diffFiles(source) {
        const files = [];
        let current = null;
        let oldNo = 0;
        let newNo = 0;
        const start = (path) => {
            current = { path, lines: [], added: 0, removed: 0 };
            files.push(current);
        };
        for (const raw of String(source || '').replace(/\r\n/g, '\n').split('\n')) {
            const git = /^diff --git a\/(\S+) b\/(\S+)/.exec(raw);
            if (git) { start(git[2]); continue; }
            if (raw.startsWith('+++ ')) {
                const path = raw.slice(4).trim().replace(/^b\//, '');
                if (path !== '/dev/null') {
                    if (current && !current.lines.length) files.pop();
                    start(path);
                }
                continue;
            }
            if (/^(--- |index |new file|deleted file|similarity index|rename )/.test(raw)) continue;
            const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw);
            if (hunk) {
                if (!current) start('');
                oldNo = Number(hunk[1]);
                newNo = Number(hunk[2]);
                current.lines.push({ kind: 'hunk', text: raw });
                continue;
            }
            if (!current) {
                if (!raw.trim()) continue;
                start('');
            }
            if (raw.startsWith('+')) {
                current.lines.push({ kind: 'add', text: raw, newNo: newNo++ });
                current.added++;
            } else if (raw.startsWith('-')) {
                current.lines.push({ kind: 'del', text: raw, oldNo: oldNo++ });
                current.removed++;
            } else if (raw.startsWith('\\')) {
                current.lines.push({ kind: 'meta', text: raw });
            } else {
                current.lines.push({ kind: 'ctx', text: raw, oldNo: oldNo++, newNo: newNo++ });
            }
        }
        return files.filter(f => f.lines.length);
    }

    function diffBlock(body) {
        const files = diffFiles(body);
        if (!files.length) return '';
        const id = 'diff-' + Math.random().toString(36).slice(2, 10);
        const panels = files.map(file => {
            const rows = file.lines.map(line => [
                `<div class="diff-line is-${line.kind}">`,
                `<span class="diff-no">${line.oldNo == null ? '' : line.oldNo}</span>`,
                `<span class="diff-no">${line.newNo == null ? '' : line.newNo}</span>`,
                `<span class="diff-text">${esc(line.text)}</span>`,
                '</div>'
            ].join('')).join('');
            return [
                '<div class="diff-file">',
                '<div class="diff-head">',
                `<span class="diff-path">${esc(file.path || t('patch'))}</span>`,
                `<span class="diff-added">+${file.added}</span>`,
                `<span class="diff-removed">\u2212${file.removed}</span>`,
                '</div>',
                `<div class="diff-body">${rows}</div>`,
                '</div>'
            ].join('');
        }).join('');
        return [
            `<div class="diff-block" data-code-id="${id}">`,
            '<div class="code-head">',
            `<span class="code-lang">diff</span>`,
            `<span class="code-lines">${files.length} ${files.length === 1 ? t('file') : t('files')}</span>`,
            '<span class="code-actions">',
            `<button type="button" class="code-btn" data-act="code-copy" data-code-id="${id}">${esc(t('Copy'))}</button>`,
            '</span>',
            '</div>',
            panels,
            `<textarea class="code-source" hidden readonly>${esc(body)}</textarea>`,
            '</div>'
        ].join('');
    }

    function codeBlock(body, lang, options) {
        // A patch is read as a patch: per file, with what it costs on the
        // header rather than counted off the `+` lines by eye.
        if (lang === 'diff' || lang === 'patch') {
            const rendered = diffBlock(body);
            if (rendered) return rendered;
        }
        const opts = options || {};
        const hl = HL();
        const label = hl ? hl.displayName(lang) : (lang || 'text');
        const highlighted = hl ? hl.highlight(body, lang) : esc(body);
        const canPreview = hl && hl.previewable(lang);
        const lines = body.split('\n');
        const gutter = opts.lineNumbers
            ? `<span class="code-gutter" aria-hidden="true">${lines.map((_, i) => i + 1).join('\n')}</span>`
            : '';
        const id = 'code-' + Math.random().toString(36).slice(2, 10);
        return [
            `<div class="code-block${opts.wrap ? ' is-wrapped' : ''}" data-code-id="${id}">`,
            '<div class="code-head">',
            `<span class="code-lang">${esc(label)}</span>`,
            `<span class="code-lines">${lines.length} ${lines.length === 1 ? 'line' : 'lines'}</span>`,
            '<span class="code-actions">',
            canPreview ? `<button type="button" class="code-btn" data-act="code-preview" data-code-id="${id}">${esc(t('Preview'))}</button>` : '',
            `<button type="button" class="code-btn" data-act="code-wrap" data-code-id="${id}">${esc(t('Wrap'))}</button>`,
            `<button type="button" class="code-btn" data-act="code-download" data-code-id="${id}" data-lang="${esc(label)}">${esc(t('Save'))}</button>`,
            `<button type="button" class="code-btn" data-act="code-copy" data-code-id="${id}">${esc(t('Copy'))}</button>`,
            '</span>',
            '</div>',
            `<pre class="code"${lang ? ` data-lang="${esc(lang)}"` : ''}>${gutter}<code>${highlighted}</code></pre>`,
            `<textarea class="code-source" hidden readonly>${esc(body)}</textarea>`,
            '</div>'
        ].join('');
    }

    function tableBlock(rows, align) {
        const head = rows[0] || [];
        const body = rows.slice(1);
        const cell = (text, i, tag) => {
            const a = align[i] ? ` style="text-align:${align[i]}"` : '';
            return `<${tag}${a}>${inline(text)}</${tag}>`;
        };
        return [
            '<div class="table-wrap"><table class="md-table">',
            '<thead><tr>', head.map((c, i) => cell(c, i, 'th')).join(''), '</tr></thead>',
            '<tbody>',
            body.map(r => `<tr>${r.map((c, i) => cell(c, i, 'td')).join('')}</tr>`).join(''),
            '</tbody></table></div>'
        ].join('');
    }

    function splitRow(line) {
        return line.replace(/^\s*\|/, '').replace(/\|\s*$/, '')
            .split('|').map(c => c.trim());
    }

    function isTableDivider(line) {
        return /^\s*\|?[\s:-]*-[\s|:-]*\|?\s*$/.test(line) && line.includes('-');
    }

    function listBlock(lines, start, ordered) {
        const items = [];
        let i = start;
        const baseIndent = (lines[i].match(/^\s*/) || [''])[0].length;
        while (i < lines.length) {
            const line = lines[i];
            const m = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line);
            if (!m) break;
            const indent = m[1].length;
            if (indent < baseIndent) break;
            if (indent > baseIndent) {
                const nested = listBlock(lines, i, /^\d/.test(m[2]));
                if (items.length) items[items.length - 1].children.push(nested.html);
                i = nested.next;
                continue;
            }
            const isOrdered = /^\d/.test(m[2]);
            if (isOrdered !== ordered && items.length) break;
            items.push({ text: m[3], children: [] });
            i++;
            while (i < lines.length && lines[i].trim() && !/^(\s*)([-*+]|\d+[.)])\s+/.test(lines[i])
                && ((lines[i].match(/^\s*/) || [''])[0].length > baseIndent)) {
                items[items.length - 1].text += '\n' + lines[i].trim();
                i++;
            }
        }
        const tag = ordered ? 'ol' : 'ul';
        const html = `<${tag}>` + items.map((it) => {
            const task = /^\[([ xX])\]\s+(.*)$/.exec(it.text);
            if (task) {
                const done = task[1].toLowerCase() === 'x';
                return `<li class="task-item"><input type="checkbox" disabled${done ? ' checked' : ''}><span>${inline(task[2])}</span>${it.children.join('')}</li>`;
            }
            return `<li>${inline(it.text)}${it.children.join('')}</li>`;
        }).join('') + `</${tag}>`;
        return { html, next: i };
    }

    function render(src, options) {
        const opts = options || {};
        const lines = String(src || '').replace(/\r\n/g, '\n').split('\n');
        const out = [];
        let i = 0;

        while (i < lines.length) {
            const line = lines[i];

            const fence = /^\s*(?:```|~~~)([\w+#.-]*)\s*$/.exec(line);
            if (fence) {
                const lang = fence[1] || '';
                const body = [];
                i++;
                while (i < lines.length && !/^\s*(?:```|~~~)\s*$/.test(lines[i])) body.push(lines[i++]);
                i++;
                out.push(codeBlock(body.join('\n'), lang, opts));
                continue;
            }

            if (/^\s*\|/.test(line) && i + 1 < lines.length && isTableDivider(lines[i + 1])) {
                const head = splitRow(line);
                const align = splitRow(lines[i + 1]).map((c) => {
                    if (/^:.*:$/.test(c)) return 'center';
                    if (/:$/.test(c)) return 'right';
                    if (/^:/.test(c)) return 'left';
                    return '';
                });
                const rows = [head];
                i += 2;
                while (i < lines.length && /\|/.test(lines[i]) && lines[i].trim()) {
                    rows.push(splitRow(lines[i++]));
                }
                out.push(tableBlock(rows, align));
                continue;
            }

            const heading = /^(#{1,6})\s+(.*)$/.exec(line);
            if (heading) {
                const level = Math.min(heading[1].length + 2, 6);
                out.push(`<h${level}>${inline(heading[2])}</h${level}>`);
                i++;
                continue;
            }

            if (/^\s*(?:[-*_]\s*){3,}$/.test(line)) { out.push('<hr>'); i++; continue; }

            const callout = /^\s*>\s*\[!(\w+)\]\s*(.*)$/.exec(line);
            if (callout) {
                const kind = callout[1].toLowerCase();
                const body = callout[2] ? [callout[2]] : [];
                i++;
                while (i < lines.length && /^\s*>\s?/.test(lines[i])) body.push(lines[i++].replace(/^\s*>\s?/, ''));
                out.push(`<div class="callout is-${esc(kind)}"><span class="callout-tag">${esc(kind)}</span>${render(body.join('\n'), opts)}</div>`);
                continue;
            }

            if (/^\s*>\s?/.test(line)) {
                const body = [];
                while (i < lines.length && /^\s*>\s?/.test(lines[i])) body.push(lines[i++].replace(/^\s*>\s?/, ''));
                out.push(`<blockquote>${render(body.join('\n'), opts)}</blockquote>`);
                continue;
            }

            if (/^(\s*)([-*+]|\d+[.)])\s+/.test(line)) {
                const ordered = /^\s*\d+[.)]\s+/.test(line);
                const block = listBlock(lines, i, ordered);
                out.push(block.html);
                i = block.next;
                continue;
            }

            if (!line.trim()) { i++; continue; }

            const para = [];
            while (i < lines.length && lines[i].trim()
                && !/^\s*(?:```|~~~)/.test(lines[i]) && !/^#{1,6}\s/.test(lines[i])
                && !/^\s*>\s?/.test(lines[i]) && !/^(\s*)([-*+]|\d+[.)])\s+/.test(lines[i])
                && !(/^\s*\|/.test(lines[i]) && isTableDivider(lines[i + 1] || ''))) {
                para.push(lines[i++]);
            }
            const text = para.join('\n');
            const bare = text.trim();
            const media = /^https?:\/\/\S+$/.test(bare)
                ? mediaFor(bare, opts.media) : null;
            out.push(media || `<p>${inline(text).replace(/\n/g, '<br>')}</p>`);
        }

        return out.join('\n');
    }

    function plain(src) {
        return String(src || '')
            .replace(/```[\s\S]*?```/g, ' ')
            .replace(/`([^`]+)`/g, '$1')
            .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
            .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
            .replace(/[#*_>|~]/g, '')
            .replace(/\s+/g, ' ')
            .trim();
    }

    window.NymbotMarkdown = { render, escape: esc, plain, inline, diffFiles };
})();
