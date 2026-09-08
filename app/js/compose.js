// The composer, which shows the markdown you write as what it means.
//
// A textarea can only ever show `**loud**` as five literal characters, so what
// you were writing and what you would be sending looked like two different
// things. This turns the field into an editable surface that styles the
// markup in place: the marks stay where you typed them, dimmed, and the text
// between them is drawn bold, italic or as code.
//
// Keeping the marks visible is not a compromise, it is what makes the caret
// arithmetic honest — every character of the source is present in the DOM, in
// order, so an offset into the text is an offset into what is on screen and
// nothing has to be guessed back.
//
// The element it is given keeps the interface a textarea had: `value`,
// `selectionStart`, `selectionEnd` and `setSelectionRange`, so everything that
// already spoke to the composer carries on speaking to it.
(function () {
    'use strict';

    // Typing is intercepted rather than left to the browser, which would
    // otherwise invent its own <div> and <span style> structure inside the
    // field and leave the text unreadable. The exception is an IME, which has
    // to be allowed to edit in place; that is picked up afterwards.
    const EDITS = {
        insertText: 1, insertReplacementText: 1, insertFromPaste: 1,
        insertFromDrop: 1, insertFromYank: 1, insertCompositionText: 0,
        insertLineBreak: 1, insertParagraph: 1,
        deleteContentBackward: 1, deleteContentForward: 1,
        deleteWordBackward: 1, deleteWordForward: 1,
        deleteSoftLineBackward: 1, deleteSoftLineForward: 1,
        deleteHardLineBackward: 1, deleteHardLineForward: 1,
        deleteByCut: 1, deleteByDrag: 1, deleteEntireSoftLine: 1,
    };

    const UNDO_MAX = 100;

    // Combining marks and the joiners that hold an emoji together: part of
    // the character before them, not a keystroke of their own.
    const COMBINING = /[\u0300-\u036f\u200d\ufe0f]/;

    function esc(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    const mark = (s) => '<span class="ce-mark">' + esc(s) + '</span>';

    // One pass, left to right. Each alternative captures its marks separately
    // from its body so both can be emitted, because dropping a mark would
    // shift every offset after it.
    const INLINE = /(`+)([^`]*?)\1|\*\*([\s\S]+?)\*\*|__([\s\S]+?)__|\*([^*\n]+?)\*|_([^_\n]+?)_|~~([\s\S]+?)~~|\[([^\][]*)\]\(([^()\s]*)\)/g;

    function inline(text) {
        let out = '';
        let at = 0;
        let m;
        INLINE.lastIndex = 0;
        while ((m = INLINE.exec(text))) {
            if (m.index > at) out += esc(text.slice(at, m.index));
            const whole = m[0];
            if (m[1] !== undefined) {
                out += mark(m[1]) + '<code class="ce-code">' + esc(m[2]) + '</code>' + mark(m[1]);
            } else if (m[3] !== undefined) {
                out += mark('**') + '<strong>' + esc(m[3]) + '</strong>' + mark('**');
            } else if (m[4] !== undefined) {
                out += mark('__') + '<strong>' + esc(m[4]) + '</strong>' + mark('__');
            } else if (m[5] !== undefined) {
                out += mark('*') + '<em>' + esc(m[5]) + '</em>' + mark('*');
            } else if (m[6] !== undefined) {
                out += mark('_') + '<em>' + esc(m[6]) + '</em>' + mark('_');
            } else if (m[7] !== undefined) {
                out += mark('~~') + '<s>' + esc(m[7]) + '</s>' + mark('~~');
            } else {
                out += mark('[') + '<span class="ce-link">' + esc(m[8]) + '</span>'
                    + mark('](') + '<span class="ce-url">' + esc(m[9]) + '</span>' + mark(')');
            }
            at = m.index + whole.length;
        }
        if (at < text.length) out += esc(text.slice(at));
        return out;
    }

    function lineHtml(line, inFence) {
        if (inFence) return '<span class="ce-incode">' + esc(line) + '</span>';
        let head = '';
        let rest = line;
        let wrap = null;

        const heading = rest.match(/^(#{1,6}[ \t]+)/);
        const quote = rest.match(/^([ \t]*>[ \t]?)/);
        const bullet = rest.match(/^([ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+)/);
        if (heading) { head = mark(heading[1]); rest = rest.slice(heading[1].length); wrap = 'ce-heading'; }
        else if (quote) { head = mark(quote[1]); rest = rest.slice(quote[1].length); wrap = 'ce-quote'; }
        else if (bullet) { head = mark(bullet[1]); rest = rest.slice(bullet[1].length); }

        const body = inline(rest);
        return head + (wrap ? '<span class="' + wrap + '">' + body + '</span>' : body);
    }

    /// The text as HTML: one element per line, so a line is addressable and an
    /// empty one still has a box to put the caret in.
    function render(text) {
        const lines = String(text == null ? '' : text).split('\n');
        let fence = false;
        let out = '';
        for (const line of lines) {
            const opener = /^[ \t]*(```|~~~)/.test(line);
            let cls = 'ce-line';
            let html;
            if (opener) {
                html = '<span class="ce-fence">' + esc(line) + '</span>';
                fence = !fence;
            } else {
                html = lineHtml(line, fence);
                if (fence) cls += ' is-code';
            }
            out += '<div class="' + cls + '">' + (html || '<br>') + '</div>';
        }
        return out || '<div class="ce-line"><br></div>';
    }

    /// The plain text behind the rendering. Every line is one child of the
    /// root, and the <br> padding an empty line contributes nothing to
    /// textContent, so the lines read back exactly as they were written.
    function readText(root) {
        const lines = [];
        for (const node of root.childNodes) {
            if (node.nodeType === 3) lines.push(node.data);
            else lines.push(node.textContent);
        }
        return lines.join('\n');
    }

    function lineLength(node) {
        return node.nodeType === 3 ? node.data.length : node.textContent.length;
    }

    /// How far into the text a (node, offset) selection point sits.
    function offsetOf(root, node, off) {
        if (!node) return 0;
        if (node === root) {
            let total = 0;
            let all = 0;
            for (let i = 0; i < root.childNodes.length; i++) {
                const len = lineLength(root.childNodes[i]);
                if (i < off) total += len + 1;
                all += len + (i ? 1 : 0);
            }
            return Math.min(total, all);
        }
        let before = 0;
        for (const line of root.childNodes) {
            if (line === node || line.contains(node)) {
                return before + within(line, node, off);
            }
            before += lineLength(line) + 1;
        }
        return before ? before - 1 : 0;
    }

    function within(line, node, off) {
        if (line === node) {
            let total = 0;
            for (let i = 0; i < off && i < line.childNodes.length; i++) {
                total += lineLength(line.childNodes[i]);
            }
            return total;
        }
        let total = 0;
        const walk = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
        let t;
        while ((t = walk.nextNode())) {
            if (t === node) return total + off;
            total += t.data.length;
        }
        // A caret parked on an element rather than in text: everything up to
        // that element has already been counted.
        if (node.nodeType === 1) {
            let sum = 0;
            const w2 = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
            let n;
            while ((n = w2.nextNode())) {
                if (node.contains(n)) break;
                sum += n.data.length;
            }
            let inner = 0;
            for (let i = 0; i < off && i < node.childNodes.length; i++) {
                inner += lineLength(node.childNodes[i]);
            }
            return sum + inner;
        }
        return total;
    }

    /// The reverse: which (node, offset) a text offset lands on.
    function pointAt(root, offset) {
        let left = Math.max(0, offset);
        for (const line of root.childNodes) {
            const len = lineLength(line);
            if (left <= len) {
                const walk = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
                let t;
                while ((t = walk.nextNode())) {
                    if (left <= t.data.length) return { node: t, offset: left };
                    left -= t.data.length;
                }
                return { node: line, offset: 0 };
            }
            left -= len + 1;
        }
        const last = root.lastChild;
        if (!last) return { node: root, offset: 0 };
        const walk = document.createTreeWalker(last, NodeFilter.SHOW_TEXT);
        let t, end = null;
        while ((t = walk.nextNode())) end = t;
        return end ? { node: end, offset: end.data.length } : { node: last, offset: 0 };
    }

    function attach(el) {
        if (!el || el._nymComposer) return el && el._nymComposer;

        const state = { text: '', start: 0, end: 0, composing: false, undo: [], redo: [] };

        const selection = () => {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount) return null;
            const range = sel.getRangeAt(0);
            if (!el.contains(range.startContainer)) return null;
            return range;
        };

        /// Reads where the caret is now, so an edit knows what it replaces.
        const readCaret = () => {
            const range = selection();
            if (!range) return;
            state.start = offsetOf(el, range.startContainer, range.startOffset);
            state.end = offsetOf(el, range.endContainer, range.endOffset);
            if (state.start > state.end) { const s = state.start; state.start = state.end; state.end = s; }
        };

        const place = (from, to) => {
            const a = pointAt(el, Math.min(from, state.text.length));
            const b = pointAt(el, Math.min(to, state.text.length));
            const sel = window.getSelection();
            if (!sel) return;
            const range = document.createRange();
            try {
                range.setStart(a.node, a.offset);
                range.setEnd(b.node, b.offset);
            } catch (_) { return; }
            sel.removeAllRanges();
            sel.addRange(range);
        };

        const paint = () => {
            const html = render(state.text);
            if (el.innerHTML !== html) el.innerHTML = html;
            el.classList.toggle('is-empty', state.text === '');
        };

        /// Puts the text on screen and the caret back where it belongs. The
        /// rendering is thrown away and rebuilt, so the caret has to be
        /// restored by offset — which is exactly why every mark stays in the
        /// DOM.
        const draw = (from, to) => {
            paint();
            state.start = from;
            state.end = to === undefined ? from : to;
            if (document.activeElement === el) place(state.start, state.end);
        };

        const remember = () => {
            state.undo.push({ text: state.text, start: state.start, end: state.end });
            if (state.undo.length > UNDO_MAX) state.undo.shift();
            state.redo.length = 0;
        };

        /// Replaces the current selection with `text` and tells everything
        /// downstream that the field changed.
        const replace = (text, from, to) => {
            const a = from === undefined ? state.start : from;
            const b = to === undefined ? state.end : to;
            remember();
            state.text = state.text.slice(0, a) + text + state.text.slice(b);
            draw(a + text.length);
            el.dispatchEvent(new Event('input', { bubbles: true }));
        };

        const step = (back) => {
            const from = back ? state.undo : state.redo;
            const to = back ? state.redo : state.undo;
            const was = from.pop();
            if (!was) return;
            to.push({ text: state.text, start: state.start, end: state.end });
            state.text = was.text;
            draw(was.start, was.end);
            el.dispatchEvent(new Event('input', { bubbles: true }));
        };

        // How far a delete reaches when nothing is selected. The browser has
        // already told us which flavour it is; all that is left is where the
        // boundary sits in the text.
        const reach = (type) => {
            const t = state.text;
            let a = state.start, b = state.end;
            if (a !== b) return [a, b];
            if (type === 'deleteContentBackward') return [Math.max(0, backOne(t, a)), b];
            if (type === 'deleteContentForward') return [a, Math.min(t.length, forwardOne(t, a))];
            if (type === 'deleteWordBackward') {
                let i = a;
                while (i > 0 && /\s/.test(t[i - 1])) i--;
                while (i > 0 && !/\s/.test(t[i - 1])) i--;
                return [i, b];
            }
            if (type === 'deleteWordForward') {
                let i = a;
                while (i < t.length && /\s/.test(t[i])) i++;
                while (i < t.length && !/\s/.test(t[i])) i++;
                return [a, i];
            }
            if (/Backward$/.test(type)) return [t.lastIndexOf('\n', a - 1) + 1, b];
            if (/Forward$/.test(type)) {
                const nl = t.indexOf('\n', a);
                return [a, nl === -1 ? t.length : nl];
            }
            if (type === 'deleteEntireSoftLine') {
                const nl = t.indexOf('\n', a);
                return [t.lastIndexOf('\n', a - 1) + 1, nl === -1 ? t.length : nl];
            }
            return [a, b];
        };

        // A surrogate pair or a combining mark is one thing to a reader, so
        // backspace takes the whole of it.
        function backOne(t, at) {
            if (at <= 0) return 0;
            let i = at - 1;
            if (i > 0 && /[\uDC00-\uDFFF]/.test(t[i]) && /[\uD800-\uDBFF]/.test(t[i - 1])) i--;
            while (i > 0 && COMBINING.test(t[i])) i--;
            return i;
        }
        function forwardOne(t, at) {
            if (at >= t.length) return t.length;
            let i = at + 1;
            if (/[\uD800-\uDBFF]/.test(t[at]) && i < t.length && /[\uDC00-\uDFFF]/.test(t[i])) i++;
            while (i < t.length && COMBINING.test(t[i])) i++;
            return i;
        }

        el.addEventListener('beforeinput', (e) => {
            if (state.composing) return;
            const type = e.inputType;
            if (type === 'historyUndo' || type === 'historyRedo') {
                e.preventDefault();
                step(type === 'historyUndo');
                return;
            }
            if (!(type in EDITS) || !EDITS[type]) return;
            readCaret();
            if (/^delete/.test(type)) {
                e.preventDefault();
                const [a, b] = reach(type);
                if (a === b) return;
                replace('', a, b);
                return;
            }
            e.preventDefault();
            let text = e.data;
            if (text == null && e.dataTransfer) text = e.dataTransfer.getData('text/plain');
            if (type === 'insertLineBreak' || type === 'insertParagraph') text = '\n';
            if (text == null) return;
            replace(String(text).replace(/\r\n?/g, '\n'));
        });

        // An IME needs the browser to edit in place; the text is read back off
        // the DOM once it has finished and the rendering catches up then.
        el.addEventListener('compositionstart', () => { state.composing = true; });
        el.addEventListener('compositionend', () => {
            state.composing = false;
            readCaret();
            state.text = readText(el);
            draw(state.start, state.end);
            el.dispatchEvent(new Event('input', { bubbles: true }));
        });

        // Anything that still slipped past — a drag inside the field, an
        // extension, a browser without beforeinput — leaves the DOM ahead of
        // the model, so the model follows it rather than fighting it.
        el.addEventListener('input', () => {
            if (state.composing) return;
            const shown = readText(el);
            if (shown === state.text) return;
            readCaret();
            state.text = shown;
            draw(state.start, state.end);
        });

        el.addEventListener('keyup', () => { if (!state.composing) readCaret(); });
        el.addEventListener('mouseup', () => { if (!state.composing) readCaret(); });
        // Focus lands the caret where the field was left, or where something
        // else asked for it — reading the browser's idea of it would send the
        // caret to the top every time a command filled the field in.
        el.addEventListener('focus', () => {
            if (selection()) readCaret();
            else place(state.start, state.end);
        });
        document.addEventListener('selectionchange', () => {
            if (!state.composing && document.activeElement === el) readCaret();
        });

        Object.defineProperty(el, 'value', {
            configurable: true,
            get() { return state.text; },
            set(next) {
                const text = String(next == null ? '' : next).replace(/\r\n?/g, '\n');
                if (text === state.text) { paint(); return; }
                state.undo.length = 0;
                state.redo.length = 0;
                state.text = text;
                draw(text.length);
            },
        });
        Object.defineProperty(el, 'selectionStart', {
            configurable: true,
            get() { return state.start; },
            set(v) { el.setSelectionRange(v, state.end); },
        });
        Object.defineProperty(el, 'selectionEnd', {
            configurable: true,
            get() { return state.end; },
            set(v) { el.setSelectionRange(state.start, v); },
        });
        el.setSelectionRange = function (from, to) {
            state.start = Math.max(0, Math.min(from, state.text.length));
            state.end = Math.max(state.start, Math.min(to === undefined ? from : to, state.text.length));
            if (document.activeElement === el) place(state.start, state.end);
        };
        el.select = function () { el.focus(); el.setSelectionRange(0, state.text.length); };

        el._nymComposer = { state, draw, render };
        paint();
        return el._nymComposer;
    }

    window.NymbotCompose = { attach, render, readText, offsetOf, pointAt };
})();
