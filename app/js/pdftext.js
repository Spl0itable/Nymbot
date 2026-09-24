(function () {
    'use strict';

    const BASE = '/app/js/vendor/pdfjs/';
    const MAX_PAGES = 2000;
    const MAX_HEADINGS = 40;

    let lib = null;

    async function pdfjs() {
        if (lib) return lib;
        const mod = await import(BASE + 'pdf.min.mjs');
        mod.GlobalWorkerOptions.workerSrc = BASE + 'pdf.worker.min.mjs';
        lib = mod;
        return lib;
    }

    function linesOf(items) {
        const lines = [];
        let text = '';
        let size = 0;
        const flush = () => {
            lines.push({ text: text.replace(/[ \t]+/g, ' ').trim(), size });
            text = '';
            size = 0;
        };
        for (const item of items) {
            if (typeof item.str !== 'string') continue;
            if (item.str) {
                if (text && !/\s$/.test(text) && !/^\s/.test(item.str)) text += ' ';
                text += item.str;
                size = Math.max(size, Math.abs(Number(item.height) || 0));
            }
            if (item.hasEOL) flush();
        }
        if (text) flush();
        return lines;
    }

    function median(values) {
        const sorted = values.filter(v => v > 0).sort((a, b) => a - b);
        if (!sorted.length) return 0;
        return sorted[Math.floor(sorted.length / 2)];
    }

    function looksLikeHeading(line, body) {
        const text = line.text;
        if (!text || text.length < 3 || text.length > 90) return false;
        if (/[.,;:]$/.test(text)) return false;
        if (!/[A-Za-zÀ-￿]/.test(text)) return false;
        return body > 0 && line.size >= body * 1.25;
    }

    async function extract(bytes, options) {
        const opts = options || {};
        const pdf = await pdfjs();
        const task = pdf.getDocument({
            data: bytes,
            isEvalSupported: false,
            disableFontFace: true,
            useSystemFonts: false,
            stopAtErrors: false
        });
        const doc = await task.promise;
        const count = Math.min(doc.numPages, opts.maxPages || MAX_PAGES);
        const pages = [];
        const pageLines = [];
        const sizes = [];
        try {
            for (let n = 1; n <= count; n++) {
                const page = await doc.getPage(n);
                const content = await page.getTextContent();
                const lines = linesOf(content.items || []);
                pageLines.push(lines);
                for (const l of lines) if (l.text) sizes.push(l.size);
                const parts = [];
                for (const l of lines) {
                    if (l.text) parts.push(l.text);
                    else if (parts.length && parts[parts.length - 1] !== '') parts.push('');
                }
                pages.push(parts.join('\n').replace(/\n{3,}/g, '\n\n').trim());
                if (page.cleanup) page.cleanup();
                if (typeof opts.onPage === 'function') opts.onPage(n, count);
            }
        } finally {
            try { await task.destroy(); } catch (_) { }
        }
        const body = median(sizes);
        const headings = [];
        pageLines.forEach((lines, i) => {
            for (const line of lines) {
                if (headings.length >= MAX_HEADINGS) return;
                if (looksLikeHeading(line, body)) headings.push({ title: line.text, page: i + 1 });
            }
        });
        return { pages, headings, total: doc.numPages };
    }

    window.NymbotPdfText = { extract };
})();
