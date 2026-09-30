(function () {
    'use strict';

    const MAX_STALL_RESUMES = 3;
    const DEFAULT_STALL_MS = 20000;
    const MIN_STALL_MS = 1000;
    const MAX_STALL_MS = 120000;
    const WHEN_DONE_DEFAULT = 'pr';
    const WHEN_DONE = ['pr', 'merge', 'leave'];
    const BRANCH_RECORDS_MAX = 50;

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

    function whenDoneOf(raw) {
        return WHEN_DONE.includes(raw) ? raw : '';
    }

    function whenDoneFor(repo, settings) {
        return whenDoneOf(repo && repo.whenDone) || whenDoneOf(settings && settings.whenDone) || WHEN_DONE_DEFAULT;
    }

    function isJobBranch(name) {
        return /^nymbot\/[0-9a-f]{8,64}$/.test(String(name || ''));
    }

    function branchSteps(list) {
        const out = [];
        for (const s of Array.isArray(list) ? list : []) {
            if (!s || !isJobBranch(s.branch) || typeof s.repo !== 'string') continue;
            const at = out.findIndex(x => x.branch === s.branch);
            const one = { repo: s.repo, branch: s.branch, base: String(s.base || ''), sha: String(s.sha || '') };
            if (at === -1) out.push(one); else out[at] = one;
        }
        return out.slice(0, 4);
    }

    function jobBranchesOn(repo) {
        return !!repo && repo.jobBranches !== false;
    }

    function jobsOf(mark) {
        if (!mark) return [];
        return [mark].concat(Array.isArray(mark.also) ? mark.also : [])
            .filter(x => x && x.job && x.job.branch)
            .map(x => Object.assign({ repo: x.repo }, x.job));
    }

    function remember(list, job, now) {
        const out = (Array.isArray(list) ? list : []).filter(r => r && r.branch !== job.branch);
        out.push({
            branch: job.branch, base: job.base || '', sha: job.sha || '',
            pull: job.pull && job.pull.number ? { number: job.pull.number, url: job.pull.url || '' } : null,
            at: now || Date.now()
        });
        return out.slice(-BRANCH_RECORDS_MAX);
    }

    function forget(list, names) {
        const drop = new Set(names || []);
        return (Array.isArray(list) ? list : []).filter(r => r && !drop.has(r.branch));
    }

    function branchState(job) {
        if (job.deleted) return t('Branch deleted.');
        if (job.ended && !job.merged && !(job.pull && job.pull.number)) return t('The task ended early. The branch keeps what it committed.');
        if (job.merged) return t('Merged into {base}.', { base: job.base });
        if (job.conflict) return t('This branch conflicts with {base}.', { base: job.base });
        if (job.fallback === 'no-api') return t('This forge has no pull request API Nymbot can use, so the branch was left as it is.');
        if (job.fallback === 'failed') return t('The pull request could not be opened, so the branch was left as it is.');
        if (job.done === false) return t('The task is still working on this branch.');
        if (job.pull && job.pull.number) return t('Pull request #{n} is open.', { n: job.pull.number });
        if (job.whenDone === 'merge') return t('Ready to merge into {base}.', { base: job.base });
        return t('Left on its own branch for you to review.');
    }

    function branchChip(job, opts) {
        const options = opts || {};
        const chip = el('div', 'branch-chip' + (job.merged ? ' is-merged' : '') + (job.deleted ? ' is-deleted' : '')
            + (job.conflict ? ' is-conflict' : ''));
        chip.dataset.branch = job.branch;
        const name = el('div', 'branch-chip-name');
        name.appendChild(el('code', null, job.branch));
        if (job.base) name.appendChild(el('span', 'branch-chip-base', ' → ' + job.base));
        chip.appendChild(name);
        chip.appendChild(el('div', 'branch-chip-state', branchState(job)));
        if (job.deleted) return chip;
        const row = el('div', 'branch-chip-actions');
        const button = (act, label, primary) => {
            const b = el('button', 'btn btn-small ' + (primary ? 'btn-primary' : 'btn-ghost'), label);
            b.type = 'button';
            b.dataset.act = act;
            if (typeof options.onAction === 'function') b.addEventListener('click', () => options.onAction(act, b, job));
            return b;
        };
        const link = (label) => {
            const a = el('a', 'btn btn-small btn-ghost', label);
            a.href = job.pull.url;
            a.target = '_blank';
            a.rel = 'noopener noreferrer';
            a.dataset.act = 'branch-open';
            return a;
        };
        const hasUrl = !!(job.pull && /^https:\/\//i.test(job.pull.url || ''));
        if (job.conflict) {
            row.appendChild(hasUrl ? link(t('Open the PR to resolve')) : button('branch-pr', t('Open the PR to resolve')));
            row.appendChild(button('branch-update', t('Ask Nymbot to update the branch'), true));
        } else if (!job.merged && job.done !== false) {
            row.appendChild(hasUrl ? link(t('Open PR')) : button('branch-pr', t('Open PR')));
            row.appendChild(button('branch-merge', t('Merge'), job.whenDone === 'merge'));
        } else if (job.merged && hasUrl) {
            row.appendChild(link(t('Open PR')));
        }
        if (job.done !== false) row.appendChild(button('branch-delete', t('Delete')));
        chip.appendChild(row);
        return chip;
    }

    window.NymbotGitRun = {
        MAX_STALL_RESUMES,
        stallWait,
        stallLine,
        all,
        settled,
        stagedCard,
        WHEN_DONE_DEFAULT,
        WHEN_DONE,
        whenDoneOf,
        whenDoneFor,
        jobBranchesOn,
        isJobBranch,
        branchSteps,
        jobsOf,
        remember,
        forget,
        branchState,
        branchChip
    };
})();
