(function () {
    'use strict';

    const SHA_RE = /^[0-9a-f]{40,64}$/i;
    const REVERT_FORGES = ['github', 'gitlab'];

    function canRevertOn(provider) {
        return REVERT_FORGES.includes(String(provider || 'github').toLowerCase());
    }

    function after(list, msgId) {
        const i = (list || []).findIndex(m => m && m.id === msgId);
        return i < 0 ? [] : list.slice(i + 1);
    }

    function marksOf(mark) {
        if (!mark || typeof mark !== 'object') return [];
        return [mark].concat(Array.isArray(mark.also) ? mark.also : []).filter(x => x && x.repo);
    }

    function openJob(job) {
        return !!(job && job.branch && !job.merged && !job.deleted);
    }

    function pullNo(p) {
        const n = Number(p && p.number);
        return Number.isInteger(n) && n > 0 ? n : 0;
    }

    function closable(x) {
        const out = [];
        const job = x && x.job;
        const jobNo = job ? pullNo(job.pull) : 0;
        if (jobNo && job.branch && !job.merged && !job.closed && !job.deleted && job.done !== false) {
            out.push({ number: jobNo, url: String(job.pull.url || ''), branch: job.branch, sha: String(job.sha || ''), job: true });
        }
        for (const p of Array.isArray(x && x.prs) ? x.prs : []) {
            const n = pullNo(p);
            if (!n || n === jobNo || !p.head || p.closed || p.merged) continue;
            out.push({ number: n, url: String(p.url || ''), branch: String(p.head), sha: '', job: false });
        }
        return out;
    }

    function revertable(x) {
        const job = x && x.job;
        const n = job ? pullNo(job.pull) : 0;
        if (!n || !job.merged || job.reverted || !job.branch) return null;
        return { number: n, url: String(job.pull.url || ''), branch: job.branch, base: String(job.base || ''), sha: String(job.sha || '') };
    }

    function effects(dropped) {
        const out = [];
        for (const m of dropped || []) {
            if (!m || !m.id) continue;
            const mark = m.checkpoint;
            for (const x of marksOf(mark)) {
                const paths = Array.isArray(x.paths) ? x.paths.filter(p => typeof p === 'string') : [];
                if (paths.length) {
                    const can = !!x.undoable && !x.undone;
                    out.push({
                        id: 'files:' + m.id + ':' + x.repo,
                        kind: 'files', msgId: m.id, repo: x.repo, branch: x.branch || '', paths, mark: x,
                        can, why: can ? '' : (x.undone ? 'undone' : 'unrecorded')
                    });
                }
                if (openJob(x.job)) {
                    const job = Object.assign({ repo: x.repo }, x.job);
                    const can = SHA_RE.test(String(job.sha || ''));
                    out.push({
                        id: 'branch:' + m.id + ':' + x.repo + ':' + job.branch,
                        kind: 'branch', msgId: m.id, repo: x.repo, branch: job.branch, base: job.base || '', job,
                        can, why: can ? '' : 'unrecorded'
                    });
                }
                for (const p of closable(x)) {
                    const can = !p.job || SHA_RE.test(p.sha);
                    out.push({
                        id: 'pull:' + m.id + ':' + x.repo + ':' + p.number,
                        kind: 'pull', msgId: m.id, repo: x.repo, branch: p.branch, sha: p.sha, number: p.number, url: p.url,
                        job: p.job, can, why: can ? '' : 'unrecorded'
                    });
                }
                const back = revertable(x);
                if (back) {
                    const recorded = SHA_RE.test(back.sha);
                    const can = recorded && canRevertOn(x.provider);
                    out.push({
                        id: 'revert:' + m.id + ':' + x.repo + ':' + back.number,
                        kind: 'revert', msgId: m.id, repo: x.repo, provider: String(x.provider || 'github'), branch: back.branch,
                        base: back.base, sha: back.sha, number: back.number, url: back.url,
                        can, why: can ? '' : (recorded ? 'forge' : 'unrecorded')
                    });
                }
            }
            for (const a of Array.isArray(m.actions) ? m.actions : []) {
                if (!a || !a.tool) continue;
                out.push({
                    id: 'connector:' + m.id + ':' + out.length,
                    kind: 'connector', msgId: m.id, connector: String(a.connector || ''), tool: String(a.tool),
                    args: String(a.args || ''), at: Number(a.at) || 0, can: false, why: 'final'
                });
            }
            const runs = Array.isArray(m.serverRuns) ? m.serverRuns.length : 0;
            if (runs) {
                out.push({ id: 'run:' + m.id, kind: 'run', msgId: m.id, count: runs, can: false, why: 'sandboxed' });
            }
        }
        return out;
    }

    function picks(items) {
        return new Set((items || []).filter(i => i.can && i.kind !== 'revert').map(i => i.id));
    }

    function plan(items, picked) {
        const chosen = (items || []).filter(i => i.can && picked && picked.has(i.id));
        const gone = new Set(chosen.filter(i => i.kind === 'branch').map(i => i.repo + '\n' + i.branch));
        const steps = [];
        for (const i of chosen.slice().reverse()) {
            if (i.kind === 'files' && gone.has(i.repo + '\n' + i.branch)) {
                steps.push({ item: i, skip: 'branch' });
                continue;
            }
            steps.push({ item: i });
        }
        return steps;
    }

    async function run(steps, ops) {
        const results = [];
        for (const s of steps) {
            if (s.skip) {
                results.push({ id: s.item.id, item: s.item, ok: true, skipped: s.skip });
                continue;
            }
            try {
                const kind = s.item.kind;
                const got = kind === 'files' ? await ops.revert(s.item)
                    : kind === 'pull' ? await ops.closePull(s.item)
                        : kind === 'revert' ? await ops.revertPull(s.item)
                            : await ops.deleteBranch(s.item);
                results.push({ id: s.item.id, item: s.item, ok: true, got });
            } catch (e) {
                results.push({ id: s.item.id, item: s.item, ok: false, error: (e && e.message) || '', gone: !!(e && e.gone), moved: !!(e && e.moved) });
            }
        }
        return results;
    }

    function settled(messages, results) {
        const byMsg = new Map();
        for (const r of results || []) {
            if (!r.ok && !r.gone) continue;
            if (!byMsg.has(r.item.msgId)) byMsg.set(r.item.msgId, []);
            byMsg.get(r.item.msgId).push(r);
        }
        return (messages || []).map((m) => {
            const done = byMsg.get(m.id);
            if (!done || !m.checkpoint) return m;
            const fix = (x) => {
                if (!x) return x;
                let next = x;
                for (const r of done) {
                    const i = r.item;
                    if (i.repo !== x.repo) continue;
                    if (i.kind === 'files' && !r.skipped && (x.branch || '') === i.branch) next = Object.assign({}, next, { undone: true });
                    if (i.kind === 'branch' && next.job && next.job.branch === i.branch) {
                        next = Object.assign({}, next, { job: Object.assign({}, next.job, { deleted: true }) });
                    }
                    if (i.kind === 'pull' && r.ok) {
                        if (i.job && next.job && next.job.branch === i.branch && pullNo(next.job.pull) === i.number) {
                            next = Object.assign({}, next, { job: Object.assign({}, next.job, { closed: true }) });
                        } else if (Array.isArray(next.prs)) {
                            next = Object.assign({}, next, { prs: next.prs.map(p => pullNo(p) === i.number ? Object.assign({}, p, { closed: true }) : p) });
                        }
                    }
                    if (i.kind === 'revert' && r.ok && next.job && next.job.branch === i.branch) {
                        const got = r.got || {};
                        next = Object.assign({}, next, { job: Object.assign({}, next.job, { reverted: {
                            branch: String(got.branch || ''), base: String(got.base || ''), sha: String(got.sha || ''),
                            pull: got.pull && pullNo(got.pull) ? { number: pullNo(got.pull), url: String(got.pull.url || '') } : null
                        } }) });
                    }
                }
                return next;
            };
            const mark = Object.assign({}, fix(m.checkpoint));
            if (Array.isArray(m.checkpoint.also)) mark.also = m.checkpoint.also.map(fix);
            return Object.assign({}, m, { checkpoint: mark });
        });
    }

    window.NymbotRewind = { after, effects, picks, plan, run, settled, closable, revertable, canRevertOn };
})();
