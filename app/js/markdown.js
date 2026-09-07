// Reply rendering. Small on purpose: escape first, then turn a known set of
// markdown constructs into markup, so nothing a model writes can inject HTML.
(function () {
    'use strict';

    function esc(s) {
        return String(s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    function safeUrl(href) {
        const u = String(href || '').trim();
        return /^(https?:\/\/|mailto:)/i.test(u) ? u : '';
    }

    function inline(text) {
        let out = esc(text);
        out = out.replace(/`([^`\n]+)`/g, (_, c) => `<code>${c}</code>`);
        out = out.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (m, label, href) => {
            const u = safeUrl(href);
            return u ? `<a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${label}</a>` : m;
        });
        out = out.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, (m, pre, u) =>
            `${pre}<a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${esc(u)}</a>`);
        out = out.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
        out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
        out = out.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');
        return out;
    }

    /// Images arrive as bare URLs the bot uploaded; showing them beats making
    /// someone open a link to find out what was generated.
    function mediaFor(url) {
        if (/\.(png|jpe?g|gif|webp|avif)(\?|$)/i.test(url)) {
            return `<img class="msg-media" src="${esc(url)}" alt="" loading="lazy">`;
        }
        if (/\.(mp3|wav|ogg|m4a|opus)(\?|$)/i.test(url)) {
            return `<audio class="msg-media" controls src="${esc(url)}"></audio>`;
        }
        return null;
    }

    function render(src) {
        const lines = String(src || '').replace(/\r\n/g, '\n').split('\n');
        const out = [];
        let i = 0;

        while (i < lines.length) {
            const line = lines[i];

            const fence = /^\s*```(\w*)\s*$/.exec(line);
            if (fence) {
                const lang = fence[1] || '';
                const body = [];
                i++;
                while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) body.push(lines[i++]);
                i++;
                out.push(`<pre class="code"${lang ? ` data-lang="${esc(lang)}"` : ''}><code>${esc(body.join('\n'))}</code></pre>`);
                continue;
            }

            const heading = /^(#{1,4})\s+(.*)$/.exec(line);
            if (heading) {
                const level = Math.min(heading[1].length + 2, 6);
                out.push(`<h${level}>${inline(heading[2])}</h${level}>`);
                i++;
                continue;
            }

            if (/^\s*(?:[-*_]\s*){3,}$/.test(line)) { out.push('<hr>'); i++; continue; }

            if (/^\s*>\s?/.test(line)) {
                const body = [];
                while (i < lines.length && /^\s*>\s?/.test(lines[i])) body.push(lines[i++].replace(/^\s*>\s?/, ''));
                out.push(`<blockquote>${render(body.join('\n'))}</blockquote>`);
                continue;
            }

            if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
                const ordered = /^\s*\d+\.\s+/.test(line);
                const items = [];
                while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
                    items.push(inline(lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, '')));
                    i++;
                }
                const tag = ordered ? 'ol' : 'ul';
                out.push(`<${tag}>${items.map(x => `<li>${x}</li>`).join('')}</${tag}>`);
                continue;
            }

            if (!line.trim()) { i++; continue; }

            const para = [];
            while (i < lines.length && lines[i].trim()
                && !/^\s*```/.test(lines[i]) && !/^#{1,4}\s/.test(lines[i])
                && !/^\s*>\s?/.test(lines[i]) && !/^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
                para.push(lines[i++]);
            }
            const text = para.join('\n');
            const bare = text.trim();
            const media = /^https?:\/\/\S+$/.test(bare) ? mediaFor(bare) : null;
            out.push(media || `<p>${inline(text).replace(/\n/g, '<br>')}</p>`);
        }

        return out.join('\n');
    }

    window.NymbotMarkdown = { render, escape: esc };
})();
