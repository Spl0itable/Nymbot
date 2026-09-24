(function () {
    'use strict';

    const MAX_STALL_RESUMES = 3;
    const DEFAULT_STALL_MS = 20000;
    const MIN_STALL_MS = 1000;
    const MAX_STALL_MS = 120000;

    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };

    function stallWait(res) {
        if (!res || !res.stalled || !res.truncated || !res.resumeToken) return null;
        const ms = Number(res.retryAfterMs);
        const wait = Number.isFinite(ms) && ms > 0 ? ms : DEFAULT_STALL_MS;
        return Math.max(MIN_STALL_MS, Math.min(MAX_STALL_MS, Math.round(wait)));
    }

    function stallLine(msLeft, attempt) {
        return t('The gateway is busy. Resuming by itself in {n}s (try {try} of {of}). Stop cancels it.', {
            n: Math.max(1, Math.ceil(msLeft / 1000)), try: attempt, of: MAX_STALL_RESUMES
        });
    }

    function all(staged) {
        if (!staged) return [];
        return [staged].concat(Array.isArray(staged.also) ? staged.also : []);
    }

    function stats(staged) {
        const s = staged.stats || {};
        const files = Number(s.files) || (staged.files || []).length;
        const bits = [files === 1 ? t('1 file changed') : t('{n} files changed', { n: files })];
        if (s.added != null) bits.push('+' + (Number(s.added) || 0));
        if (s.removed != null) bits.push('−' + (Number(s.removed) || 0));
        return bits.join(' · ');
    }

    function settled(staged, how, extra) {
        const out = {
            repo: staged.repo, branch: staged.branch, message: staged.message || '',
            stats: staged.stats || null, diff: staged.diff || ''
        };
        if (how === 'applied') out.applied = true;
        if (how === 'discarded') out.discarded = true;
        if (staged.also) out.also = staged.also.map(s => settled(s, how));
        return Object.assign(out, extra || {});
    }

    function stagedCard(staged, opts) {
        const options = opts || {};
        const card = el('div', 'checkpoint-card staged-card'
            + (staged.applied ? ' is-applied' : '')
            + (staged.discarded ? ' is-undone' : ''));
        for (const one of all(staged)) {
            const head = el('div', 'checkpoint-head');
            head.appendChild(el('span', 'checkpoint-repo', one.repo + (one.branch ? ' · ' + one.branch : '')));
            card.appendChild(head);
            card.appendChild(el('div', 'checkpoint-what', stats(one)));
            if (one.message) card.appendChild(el('div', 'staged-message', one.message));
            if (one.diff && typeof options.code === 'function') {
                const diff = el('div', 'staged-diff');
                diff.innerHTML = options.code(one.diff, 'diff');
                card.appendChild(diff);
            }
        }
        if (staged.applied) {
            card.appendChild(el('div', 'checkpoint-note', t('Applied as one commit.')));
            return card;
        }
        if (staged.discarded) {
            card.appendChild(el('div', 'checkpoint-note', t('Discarded. Nothing was committed.')));
            return card;
        }
        card.appendChild(el('div', 'checkpoint-note',
            t('Nothing is committed until you apply it. Applying costs nothing.')));
        const row = el('div', 'staged-actions');
        const apply = el('button', 'btn btn-small btn-primary', t('Apply'));
        apply.type = 'button';
        apply.dataset.act = 'staged-apply';
        const discard = el('button', 'btn btn-small btn-ghost', t('Discard'));
        discard.type = 'button';
        discard.dataset.act = 'staged-discard';
        if (typeof options.onApply === 'function') apply.addEventListener('click', () => options.onApply(apply, discard));
        if (typeof options.onDiscard === 'function') discard.addEventListener('click', () => options.onDiscard(apply, discard));
        row.appendChild(apply);
        row.appendChild(discard);
        card.appendChild(row);
        return card;
    }

    window.NymbotGitRun = {
        MAX_STALL_RESUMES,
        stallWait,
        stallLine,
        all,
        settled,
        stagedCard
    };
})();
