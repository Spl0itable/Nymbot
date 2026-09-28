(function () {
    'use strict';

    const SELECTOR = '.message-content img.msg-media, .msg-attachment img, #attachTray .attach-item img, img.run-image';
    const MIN_SCALE = 1;
    const MAX_SCALE = 5;
    const DOUBLE_TAP_MS = 300;
    const TYPES = {
        'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp',
        'image/avif': 'avif', 'image/bmp': 'bmp', 'image/svg+xml': 'svg'
    };

    let root = null;
    let img = null;
    let prevBtn = null;
    let nextBtn = null;
    let saveBtn = null;
    let closeBtn = null;
    let counter = null;
    let items = [];
    let index = 0;
    let opener = null;
    let heldInert = null;
    let saving = false;

    let scale = 1, tx = 0, ty = 0;
    let startScale = 1, startTx = 0, startTy = 0;
    let startDist = 0, startMidX = 0, startMidY = 0;
    let startX = 0, startY = 0;
    let mode = null;
    let moved = false;
    let lastTap = 0;
    let tapTimer = null;
    let navTimer = null;
    const pointers = new Map();

    function button(cls, label, icon) {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'viewer-btn ' + cls;
        b.title = label;
        b.setAttribute('aria-label', label);
        const Icons = window.NymbotIcons;
        if (Icons && Icons.node) b.appendChild(Icons.node(icon, { size: 20 }));
        return b;
    }

    function build() {
        if (root) return;
        root = document.createElement('div');
        root.className = 'viewer';
        root.id = 'mediaViewer';
        root.hidden = true;
        root.setAttribute('role', 'dialog');
        root.setAttribute('aria-modal', 'true');
        root.setAttribute('aria-label', t('Image viewer'));

        img = document.createElement('img');
        img.className = 'viewer-img';
        img.alt = '';
        img.draggable = false;
        img.decoding = 'async';
        img.referrerPolicy = 'no-referrer';

        saveBtn = button('viewer-save', t('Save this file'), 'save');
        closeBtn = button('viewer-close', t('Close'), 'close');
        prevBtn = button('viewer-nav viewer-prev', t('Previous image'), 'chevron');
        nextBtn = button('viewer-nav viewer-next', t('Next image'), 'chevron');
        counter = document.createElement('div');
        counter.className = 'viewer-count';
        counter.setAttribute('aria-live', 'polite');

        root.appendChild(img);
        root.appendChild(prevBtn);
        root.appendChild(nextBtn);
        root.appendChild(counter);
        root.appendChild(saveBtn);
        root.appendChild(closeBtn);
        document.body.appendChild(root);

        closeBtn.addEventListener('click', (e) => { e.stopPropagation(); close(); });
        saveBtn.addEventListener('click', (e) => { e.stopPropagation(); save(); });
        prevBtn.addEventListener('click', (e) => { e.stopPropagation(); navigate(-1); });
        nextBtn.addEventListener('click', (e) => { e.stopPropagation(); navigate(1); });
        root.addEventListener('click', (e) => { if (e.target === root) close(); });
        img.addEventListener('pointerdown', onDown);
        img.addEventListener('pointermove', onMove);
        img.addEventListener('pointerup', onUp);
        img.addEventListener('pointercancel', onUp);
        img.addEventListener('click', (e) => e.stopPropagation());
        img.addEventListener('dragstart', (e) => e.preventDefault());
        root.addEventListener('wheel', onWheel, { passive: false });
        root.addEventListener('touchmove', (e) => e.preventDefault(), { passive: false });
    }

    function proxiedTarget(src) {
        try {
            const u = new URL(src, location.href);
            if (u.pathname === '/api/proxy' && u.searchParams.get('url')) return u.searchParams.get('url');
        } catch (_) { }
        return src;
    }

    function attachmentName(node) {
        if (node.closest('.msg-attachment')) return node.alt || '';
        const item = node.closest('#attachTray .attach-item');
        if (!item) return '';
        const U = window.NymbotUI;
        const at = Array.from(item.parentElement.children).filter((n) => n.classList.contains('attach-item')).indexOf(item);
        const held = U && Array.isArray(U.attachments) ? U.attachments[at] : null;
        if (held && held.name) return held.name;
        const label = item.querySelector('span');
        return label ? label.textContent.split(' · ')[0].trim() : '';
    }

    function describe(node) {
        const src = node.currentSrc || node.src || '';
        const box = node.closest('.msg-media-box');
        const saveEl = box ? box.querySelector('[data-act="save-media"]') : null;
        const raw = (saveEl && saveEl.dataset.url) || proxiedTarget(src);
        return { src, raw, name: attachmentName(node), alt: node.alt || '' };
    }

    function apply(animate) {
        img.classList.toggle('is-animating', !!animate);
        img.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
        root.classList.toggle('is-zoomed', scale > MIN_SCALE);
    }

    function fade(value) {
        root.style.setProperty('--viewer-fade', String(value));
    }

    function reset(animate) {
        scale = 1; tx = 0; ty = 0;
        if (!img) return;
        apply(animate);
        fade(1);
    }

    function clampPan() {
        const w = img.offsetWidth, h = img.offsetHeight;
        const maxX = Math.max(0, (w * scale - w) / 2);
        const maxY = Math.max(0, (h * scale - h) / 2);
        tx = Math.min(maxX, Math.max(-maxX, tx));
        ty = Math.min(maxY, Math.max(-maxY, ty));
    }

    function show() {
        const it = items[index];
        img.src = it.src;
        img.alt = it.alt;
        const many = items.length > 1;
        prevBtn.hidden = !many || index === 0;
        nextBtn.hidden = !many || index === items.length - 1;
        counter.hidden = !many;
        counter.textContent = many ? t('{n} of {total}', { n: index + 1, total: items.length }) : '';
    }

    function navigate(delta) {
        const next = index + delta;
        if (!root || root.hidden || next < 0 || next >= items.length) return false;
        index = next;
        scale = 1; tx = 0; ty = 0;
        fade(1);
        img.classList.remove('is-animating');
        img.classList.add('is-fading');
        img.style.transform = 'translate(0px, 0px) scale(1)';
        root.classList.remove('is-zoomed');
        clearTimeout(navTimer);
        navTimer = setTimeout(() => {
            show();
            img.classList.remove('is-fading');
        }, 120);
        const focused = document.activeElement;
        if ((focused === prevBtn && index === 0) || (focused === nextBtn && index === items.length - 1)) {
            closeBtn.focus();
        }
        return true;
    }

    function open(target) {
        build();
        const scope = target.closest('.message-content, #attachTray') || target.parentElement || document.body;
        const nodes = Array.from(scope.querySelectorAll(SELECTOR))
            .filter((n) => !n.closest('a') && (n.currentSrc || n.src));
        if (!nodes.includes(target)) nodes.splice(0, nodes.length, target);
        items = nodes.map(describe);
        index = Math.max(0, nodes.indexOf(target));
        if (!items.length || !items[index].src) return;
        const wasOpen = !root.hidden;
        reset(false);
        img.classList.remove('is-fading');
        show();
        if (!wasOpen) {
            opener = document.activeElement;
            root.hidden = false;
            document.documentElement.classList.add('viewer-open');
            const shell = document.getElementById('shell');
            if (shell) { heldInert = shell.inert; shell.inert = true; }
        }
        closeBtn.focus();
    }

    function close() {
        if (!root || root.hidden) return;
        clearTimeout(tapTimer);
        clearTimeout(navTimer);
        pointers.clear();
        mode = null;
        root.hidden = true;
        reset(false);
        img.classList.remove('is-fading');
        img.removeAttribute('src');
        items = [];
        document.documentElement.classList.remove('viewer-open');
        const shell = document.getElementById('shell');
        if (shell && heldInert !== null) shell.inert = heldInert;
        heldInert = null;
        if (opener && opener.focus && document.contains(opener)) opener.focus();
        opener = null;
    }

    function dataBlob(url) {
        const comma = url.indexOf(',');
        const head = url.slice(5, comma);
        const body = url.slice(comma + 1);
        const type = head.split(';')[0] || 'application/octet-stream';
        if (/;base64$/i.test(head)) {
            const bin = atob(body);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            return new Blob([bytes], { type });
        }
        return new Blob([decodeURIComponent(body)], { type });
    }

    function fileName(it, mime) {
        const ext = TYPES[String(mime || '').split(';')[0].toLowerCase()];
        if (it.name && /\.[a-z0-9]{2,5}$/i.test(it.name)) return it.name;
        if (it.name) return ext ? it.name + '.' + ext : it.name;
        const U = window.NymbotUI;
        if (/^https?:/i.test(it.raw) && U && typeof U.mediaName === 'function') {
            const named = U.mediaName(it.raw, mime);
            if (/\.[a-z0-9]{2,5}$/i.test(named) || !ext) return named;
            return named + '.' + ext;
        }
        return 'nymbot.' + (ext || 'png');
    }

    function toast(text) {
        const U = window.NymbotUI;
        if (U && typeof U.toast === 'function') U.toast(text);
    }

    function saveBlob(name, blob) {
        const E = window.NymbotExport;
        if (E && typeof E.saveBlob === 'function') { E.saveBlob(name, blob); return; }
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = name;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 4000);
    }

    async function save() {
        const it = items[index];
        if (!it || saving) return;
        saving = true;
        saveBtn.disabled = true;
        try {
            let blob;
            if (/^data:/i.test(it.src)) {
                blob = dataBlob(it.src);
            } else if (/^blob:/i.test(it.src)) {
                const a = document.createElement('a');
                a.href = it.src;
                a.download = fileName(it, '');
                document.body.appendChild(a);
                a.click();
                a.remove();
                return;
            } else {
                const res = await fetch(it.src);
                if (!res.ok) throw new Error('HTTP ' + res.status);
                blob = await res.blob();
            }
            saveBlob(fileName(it, blob.type), blob);
            toast(t('Saved.'));
        } catch (_) {
            const out = /^https?:/i.test(it.raw) ? it.raw : it.src;
            if (/^https?:/i.test(out)) {
                window.open(out, '_blank', 'noopener');
                toast(t('Opened it in a new tab — save it from there.'));
            } else {
                toast(t('That file could not be saved.'));
            }
        } finally {
            saving = false;
            saveBtn.disabled = false;
        }
    }

    function spread() {
        const p = Array.from(pointers.values());
        return {
            dist: Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y),
            midX: (p[0].x + p[1].x) / 2,
            midY: (p[0].y + p[1].y) / 2
        };
    }

    function begin() {
        startScale = scale; startTx = tx; startTy = ty;
        if (pointers.size >= 2) {
            const s = spread();
            mode = 'pinch';
            startDist = s.dist || 1;
            startMidX = s.midX;
            startMidY = s.midY;
        } else if (pointers.size === 1) {
            const p = pointers.values().next().value;
            startX = p.x;
            startY = p.y;
            mode = scale > MIN_SCALE ? 'pan' : 'swipe';
        } else {
            mode = null;
        }
    }

    function onDown(e) {
        if (e.pointerType === 'mouse' && e.button !== 0) return;
        e.preventDefault();
        try { img.setPointerCapture(e.pointerId); } catch (_) { }
        if (pointers.size === 0) moved = false;
        pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
        img.classList.remove('is-animating');
        begin();
    }

    function onMove(e) {
        if (!pointers.has(e.pointerId)) return;
        pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
        if (mode === 'pinch' && pointers.size >= 2) {
            const s = spread();
            moved = true;
            scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, startScale * (s.dist / startDist)));
            tx = startTx + (s.midX - startMidX);
            ty = startTy + (s.midY - startMidY);
            apply(false);
        } else if (mode === 'pan') {
            if (Math.hypot(e.clientX - startX, e.clientY - startY) > 4) moved = true;
            tx = startTx + (e.clientX - startX);
            ty = startTy + (e.clientY - startY);
            apply(false);
        } else if (mode === 'swipe') {
            const dx = e.clientX - startX;
            const dy = e.clientY - startY;
            if (Math.hypot(dx, dy) > 6) moved = true;
            if (!moved) return;
            tx = dx; ty = dy;
            const progress = Math.min(1, Math.hypot(dx, dy) / 300);
            fade(1 - progress);
            apply(false);
        }
    }

    function tapped() {
        const now = Date.now();
        clearTimeout(tapTimer);
        if (now - lastTap < DOUBLE_TAP_MS) {
            lastTap = 0;
            if (scale > MIN_SCALE) reset(true);
            else { scale = 2.5; apply(true); }
            return;
        }
        lastTap = now;
        if (scale > MIN_SCALE) return;
        tapTimer = setTimeout(() => { if (scale <= MIN_SCALE) close(); }, DOUBLE_TAP_MS);
    }

    function onUp(e) {
        if (!pointers.has(e.pointerId)) return;
        pointers.delete(e.pointerId);
        try { img.releasePointerCapture(e.pointerId); } catch (_) { }
        const was = mode;
        if (pointers.size > 0) { begin(); return; }
        mode = null;
        if (!moved && e.type === 'pointerup') { tapped(); return; }
        if (was === 'swipe') {
            const many = items.length > 1;
            const horizontal = Math.abs(tx) > Math.abs(ty);
            if (many && horizontal) {
                if (Math.abs(tx) > 60 && navigate(tx < 0 ? 1 : -1)) return;
                reset(true);
                return;
            }
            const travel = many ? Math.abs(ty) : Math.hypot(tx, ty);
            if (travel > 100) { close(); return; }
            reset(true);
        } else if (was === 'pinch' || was === 'pan') {
            if (scale <= MIN_SCALE) reset(true);
            else { clampPan(); apply(true); }
        }
    }

    function onWheel(e) {
        if (!root || root.hidden) return;
        e.preventDefault();
        const next = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale * Math.exp(-e.deltaY * 0.002)));
        if (next === scale) return;
        const r = root.getBoundingClientRect();
        const px = e.clientX - (r.left + r.width / 2);
        const py = e.clientY - (r.top + r.height / 2);
        tx = px - (px - tx) * (next / scale);
        ty = py - (py - ty) * (next / scale);
        scale = next;
        if (scale <= MIN_SCALE) { reset(false); return; }
        clampPan();
        apply(false);
    }

    function focusables() {
        return [prevBtn, nextBtn, saveBtn, closeBtn].filter((b) => !b.hidden && !b.disabled);
    }

    function onKey(e) {
        if (!root || root.hidden) return;
        if (e.key === 'Escape') {
            e.preventDefault();
            e.stopImmediatePropagation();
            close();
        } else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
            e.preventDefault();
            e.stopImmediatePropagation();
            navigate(e.key === 'ArrowLeft' ? -1 : 1);
        } else if (e.key === 'Tab') {
            const list = focusables();
            e.stopImmediatePropagation();
            if (!list.length) { e.preventDefault(); return; }
            const at = list.indexOf(document.activeElement);
            e.preventDefault();
            const step = e.shiftKey ? -1 : 1;
            list[(at + step + list.length) % list.length].focus();
        }
    }

    function onClick(e) {
        const target = e.target && e.target.closest ? e.target.closest(SELECTOR) : null;
        if (!target || target.closest('a') || target.closest('#mediaViewer')) return;
        if (!(target.currentSrc || target.src)) return;
        e.preventDefault();
        e.stopPropagation();
        open(target);
    }

    function focusIn(e) {
        if (!root || root.hidden || root.contains(e.target)) return;
        closeBtn.focus();
    }

    if (typeof document !== 'undefined' && document.addEventListener) {
        document.addEventListener('click', onClick);
        window.addEventListener('keydown', onKey, true);
        document.addEventListener('focusin', focusIn);
    }

    window.NymbotViewer = {
        open,
        close,
        next: () => navigate(1),
        prev: () => navigate(-1),
        save,
        isOpen: () => !!root && !root.hidden,
        current: () => (items[index] ? Object.assign({ index, count: items.length }, items[index]) : null),
        fileName
    };
})();
