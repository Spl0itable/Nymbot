(function () {
    'use strict';

    const V = 1;
    const MAX_ENTRIES = 2000;
    const HEAD = 100;
    const TEXT_MAX = 300;
    const LABEL_MAX = 120;
    const MODEL_MAX = 80;
    const REPO_MAX = 120;
    const PLAN_MAX = 20;
    const BRANCH_MAX = 20;
    const REPLY_MAX = 50;
    const MAX_PER_CHAT = 100;
    const STORE_MAX_CHARS = 400000;
    const SYNC_MAX_CHARS = 200000;
    const FLUSH_MS = 1000;
    const POLL_MS = 5000;
    const LOG_EVERY_MS = 30000;
    const HEX = /^[0-9a-f]{64}$/;
    const KINDS = ['chat', 'research', 'team', 'repo', 'connector', 'server-run', 'media', 'compare'];
    const ENDS = ['completed', 'failed', 'canceled'];
    const STATES = ['running', 'parked', 'waiting', 'resumed'];
    const PLAN_STATES = ['planned', 'doing', 'done', 'skipped', 'removed'];
    const TYPES = ['start', 'progress', 'plan', 'branch', 'steer', 'state', 'run', 'worker', 'error', 'retry', 'cost', 'end', 'omitted', 'question', 'pr'];
    const PR_STAGES = ['watch', 'ci-failed', 'ci-passed', 'review', 'fix', 'merged', 'closed', 'stopped'];
    const QUESTION_STAGES = ['asked', 'answered', 'skipped', 'expired'];
    const PROPOSAL_STAGES = ['proposed', 'approved', 'edited', 'rejected', 'expired'];

    function clean(v, max) {
        const s = String(v == null ? '' : v).replace(/[\x00-\x1f\x7f]+/g, ' ').replace(/\s+/g, ' ').trim();
        return s.length > max ? s.slice(0, max - 1) + '…' : s;
    }

    function int(v) {
        if (v == null || typeof v === 'boolean' || v === '') return null;
        const n = Number(v);
        return Number.isFinite(n) ? Math.floor(n) : null;
    }

    function money(v) {
        if (v == null || typeof v === 'boolean' || v === '') return null;
        const n = Number(v);
        if (!Number.isFinite(n) || n <= 0) return null;
        return Math.round(n * 1e6) / 1e6;
    }

    function entryOf(raw) {
        if (!raw || typeof raw !== 'object' || !TYPES.includes(raw.type)) return null;
        const t = int(raw.t);
        if (t == null || t < 0) return null;
        const out = { t, type: raw.type };
        const text = clean(raw.text, raw.type === 'start' ? LABEL_MAX : TEXT_MAX);
        const n = int(raw.n);
        switch (raw.type) {
            case 'start': {
                out.kind = KINDS.includes(raw.kind) ? raw.kind : 'chat';
                out.text = text;
                const model = clean(raw.model, MODEL_MAX);
                if (model) out.model = model;
                break;
            }
            case 'progress':
                if (!text) return null;
                out.text = text;
                if (n != null && n > 1) out.n = n;
                if (raw.s === 1 || raw.s === true) out.s = 1;
                break;
            case 'plan':
                if (!text) return null;
                out.text = text;
                if (raw.stage != null) {
                    if (!PROPOSAL_STAGES.includes(raw.stage)) return null;
                    out.stage = raw.stage;
                    if (n != null && n > 1) out.n = n;
                    break;
                }
                out.state = PLAN_STATES.includes(raw.state) ? raw.state : 'planned';
                break;
            case 'branch': {
                if (!text) return null;
                out.text = text;
                const repo = clean(raw.repo, REPO_MAX);
                if (repo) out.repo = repo;
                break;
            }
            case 'state':
                if (!STATES.includes(raw.state)) return null;
                out.state = raw.state;
                break;
            case 'run': {
                out.stage = raw.stage === 'done' ? 'done' : 'start';
                if (text) out.text = text;
                for (const k of ['code', 'ms', 'lines', 'files']) {
                    const v = int(raw[k]);
                    if (v != null && (k === 'code' || v >= 0)) out[k] = v;
                }
                const cost = money(raw.cost);
                if (cost != null) out.cost = cost;
                break;
            }
            case 'worker': {
                const lane = int(raw.lane);
                if (!text || lane == null || lane < 1) return null;
                out.lane = lane;
                out.text = text;
                if (n != null && n > 1) out.n = n;
                break;
            }
            case 'cost': {
                const cost = money(raw.cost);
                if (cost == null) return null;
                out.cost = cost;
                if (text) out.text = text;
                break;
            }
            case 'end': {
                out.state = ENDS.includes(raw.state) ? raw.state : 'completed';
                const ms = int(raw.ms);
                out.ms = ms != null && ms > 0 ? ms : 0;
                const cost = money(raw.cost);
                if (cost != null) out.cost = cost;
                break;
            }
            case 'omitted':
                if (n == null || n < 1) return null;
                out.n = n;
                break;
            case 'question':
                if (!QUESTION_STAGES.includes(raw.stage)) return null;
                out.stage = raw.stage;
                if (text) out.text = text;
                if (n != null && n > 1) out.n = n;
                break;
            case 'pr':
                if (!PR_STAGES.includes(raw.stage)) return null;
                out.stage = raw.stage;
                if (text) out.text = text;
                break;
            default:
                if (!text) return null;
                out.text = text;
        }
        return out;
    }

    function capped(tx) {
        const list = tx.entries;
        if (list.length <= MAX_ENTRIES) return tx;
        const k = list.length - MAX_ENTRIES;
        const mark = list[HEAD];
        if (mark && mark.type === 'omitted') {
            mark.n += k;
            list.splice(HEAD + 1, k);
        } else {
            const gone = list.splice(HEAD, k + 1);
            list.splice(HEAD, 0, { t: gone[0].t, type: 'omitted', n: k + 1 });
        }
        return tx;
    }

    function same(a, b) {
        if (!a || a.type !== b.type || a.text !== b.text) return false;
        if (a.type === 'progress') return !!a.s === !!b.s;
        if (a.type === 'worker') return a.lane === b.lane;
        return false;
    }

    function push(tx, raw) {
        const e = entryOf(raw);
        if (!e) return null;
        const last = tx.entries[tx.entries.length - 1];
        if ((e.type === 'progress' || e.type === 'worker') && same(last, e)) {
            last.n = (last.n || 1) + 1;
        } else {
            tx.entries.push(e);
        }
        if (e.t > (tx.updatedAt || 0)) tx.updatedAt = e.t;
        capped(tx);
        return e;
    }

    function create(o) {
        const at = int(o.at) || 0;
        const kind = KINDS.includes(o.kind) ? o.kind : 'chat';
        const tx = {
            v: V,
            id: String(o.id || ''),
            conv: String(o.conv || ''),
            kind,
            label: clean(o.label, LABEL_MAX),
            startedAt: at,
            updatedAt: at,
            state: 'running',
            cost: 0,
            serverAt: 0,
            seenAt: 0,
            plan: [],
            branches: [],
            replies: [],
            entries: []
        };
        if (o.run) tx.run = String(o.run);
        if (o.ask) tx.ask = String(o.ask);
        const model = clean(o.model, MODEL_MAX);
        if (model) tx.model = model;
        push(tx, { t: at, type: 'start', kind, text: tx.label, model });
        return tx;
    }

    function progress(tx, text, at, server) {
        return push(tx, { t: at, type: 'progress', text, s: server ? 1 : 0 });
    }

    function planItems(raw) {
        const out = [];
        for (const it of Array.isArray(raw) ? raw : []) {
            if (!it || typeof it !== 'object') continue;
            const text = clean(it.text, LABEL_MAX);
            if (!text || out.some(x => x.text === text)) continue;
            out.push({ text, state: ['planned', 'doing', 'done', 'skipped'].includes(it.state) ? it.state : 'planned' });
            if (out.length >= PLAN_MAX) break;
        }
        return out;
    }

    function plan(tx, items, at) {
        const next = planItems(items);
        const old = tx.plan || [];
        let changed = 0;
        for (const it of next) {
            const was = old.find(x => x.text === it.text);
            if (was && was.state === it.state) continue;
            if (push(tx, { t: at, type: 'plan', text: it.text, state: it.state })) changed++;
        }
        for (const it of old) {
            if (next.some(x => x.text === it.text)) continue;
            if (push(tx, { t: at, type: 'plan', text: it.text, state: 'removed' })) changed++;
        }
        tx.plan = next;
        return changed;
    }

    function branch(tx, repo, name, at) {
        const b = clean(name, TEXT_MAX);
        if (!b || (tx.branches || []).includes(b)) return null;
        tx.branches = (tx.branches || []).concat([b]).slice(-BRANCH_MAX);
        return push(tx, { t: at, type: 'branch', text: b, repo });
    }

    function steer(tx, text, at) {
        return push(tx, { t: at, type: 'steer', text });
    }

    function state(tx, s, at) {
        if (!STATES.includes(s)) return null;
        const next = s === 'resumed' ? 'running' : s;
        if (s !== 'resumed' && tx.state === next) return null;
        tx.state = next;
        return push(tx, { t: at, type: 'state', state: s });
    }

    function addCost(tx, amount) {
        const c = money(amount);
        if (c != null) tx.cost = Math.round(((Number(tx.cost) || 0) + c) * 1e6) / 1e6;
        return c;
    }

    function run(tx, o, at) {
        const e = push(tx, Object.assign({}, o, { t: at, type: 'run' }));
        if (e && e.cost != null) addCost(tx, e.cost);
        return e;
    }

    function question(tx, stage, text, count, at) {
        const e = push(tx, { t: at, type: 'question', stage, text, n: count });
        if (e && stage === 'asked') state(tx, 'waiting', at);
        return e;
    }

    function proposal(tx, stage, text, count, at) {
        const e = push(tx, { t: at, type: 'plan', stage, text, n: count });
        if (e && stage === 'proposed') state(tx, 'waiting', at);
        return e;
    }

    function pr(tx, stage, text, at) {
        return push(tx, { t: at, type: 'pr', stage, text });
    }

    function worker(tx, lane, text, at) {
        return push(tx, { t: at, type: 'worker', lane, text });
    }

    function error(tx, text, at) {
        return push(tx, { t: at, type: 'error', text });
    }

    function retry(tx, text, at) {
        return push(tx, { t: at, type: 'retry', text });
    }

    function cost(tx, amount, text, at) {
        const e = push(tx, { t: at, type: 'cost', cost: amount, text });
        if (e) addCost(tx, e.cost);
        return e;
    }

    function end(tx, s, at, total) {
        if (tx.end) return null;
        const final = ENDS.includes(s) ? s : 'completed';
        const sum = money(total);
        if (sum != null) tx.cost = sum;
        const t0 = int(at) || 0;
        const e = push(tx, { t: t0, type: 'end', state: final, ms: t0 - (tx.startedAt || 0), cost: tx.cost });
        tx.end = final;
        tx.endedAt = t0;
        return e;
    }

    function step(tx, raw, line, at) {
        const s = raw && typeof raw === 'object' ? raw : {};
        const t0 = int(at);
        if (t0 != null && t0 > (tx.seenAt || 0)) tx.seenAt = t0;
        if (s.kind === 'server-run') {
            if (s.stage === 'done') {
                return run(tx, { stage: 'done', text: s.command || s.image, code: s.code, ms: s.ms, lines: s.lines, files: s.files, cost: s.credits }, at);
            }
            return run(tx, { stage: 'start', text: s.command || s.image }, at);
        }
        if (s.kind === 'team' && int(s.lane) > 0) return worker(tx, int(s.lane), s.text || line, at);
        if (!line) return null;
        return progress(tx, line, at);
    }

    function logOf(raw) {
        const out = [];
        for (const it of Array.isArray(raw) ? raw : []) {
            if (!Array.isArray(it)) continue;
            const t = int(it[0]);
            const text = clean(it[1], TEXT_MAX);
            if (t == null || t < 0 || !text) continue;
            out.push([t, text]);
        }
        return out.sort((a, b) => a[0] - b[0]);
    }

    function merge(tx, raw) {
        const log = logOf(raw);
        if (!log.length) return 0;
        const cutoff = Math.max(tx.serverAt || 0, tx.seenAt || 0);
        let added = 0;
        for (const [t, text] of log) {
            if (t > (tx.serverAt || 0)) tx.serverAt = t;
            if (t <= cutoff) continue;
            let at = tx.entries.length;
            while (at > 0 && tx.entries[at - 1].t > t) at--;
            const prev = tx.entries[at - 1];
            if (prev && prev.type === 'progress' && prev.s && prev.text === text) {
                prev.n = (prev.n || 1) + 1;
            } else {
                tx.entries.splice(at, 0, { t, type: 'progress', text, s: 1 });
            }
            if (t > (tx.updatedAt || 0)) tx.updatedAt = t;
            added++;
        }
        capped(tx);
        return added;
    }

    function link(tx, id) {
        const s = String(id || '');
        if (!s || tx.replies.includes(s)) return false;
        tx.replies = tx.replies.concat([s]).slice(-REPLY_MAX);
        return true;
    }

    function normalize(raw) {
        if (!raw || typeof raw !== 'object' || !Array.isArray(raw.entries)) return null;
        const id = String(raw.id || '');
        if (!id || id.length > 128) return null;
        const tx = {
            v: V,
            id,
            conv: String(raw.conv || '').slice(0, 128),
            kind: KINDS.includes(raw.kind) ? raw.kind : 'chat',
            label: clean(raw.label, LABEL_MAX),
            startedAt: Math.max(0, int(raw.startedAt) || 0),
            updatedAt: Math.max(0, int(raw.updatedAt) || 0),
            state: ['running', 'parked', 'waiting'].includes(raw.state) ? raw.state : 'running',
            cost: money(raw.cost) || 0,
            serverAt: Math.max(0, int(raw.serverAt) || 0),
            seenAt: Math.max(0, int(raw.seenAt) || 0),
            plan: planItems(raw.plan),
            branches: (Array.isArray(raw.branches) ? raw.branches : []).map(b => clean(b, TEXT_MAX)).filter(Boolean).slice(-BRANCH_MAX),
            replies: (Array.isArray(raw.replies) ? raw.replies : []).filter(x => typeof x === 'string' && x && x.length <= 128).slice(-REPLY_MAX),
            entries: []
        };
        if (typeof raw.run === 'string' && raw.run && raw.run.length <= 128) tx.run = raw.run;
        if (typeof raw.ask === 'string' && raw.ask && raw.ask.length <= 128) tx.ask = raw.ask;
        const model = clean(raw.model, MODEL_MAX);
        if (model) tx.model = model;
        if (ENDS.includes(raw.end)) {
            tx.end = raw.end;
            tx.endedAt = Math.max(0, int(raw.endedAt) || 0);
        }
        for (const e of raw.entries) {
            const got = entryOf(e);
            if (got) tx.entries.push(got);
        }
        if (!tx.entries.length) return null;
        for (const e of tx.entries) if (e.t > tx.updatedAt) tx.updatedAt = e.t;
        capped(tx);
        return tx;
    }

    function keyOf(tx) {
        return tx.run || tx.id;
    }

    function newer(a, b) {
        if ((a.updatedAt || 0) !== (b.updatedAt || 0)) return (a.updatedAt || 0) > (b.updatedAt || 0) ? a : b;
        if (a.entries.length !== b.entries.length) return a.entries.length > b.entries.length ? a : b;
        return a;
    }

    function mergeList(mine, theirs) {
        const byKey = new Map();
        for (const raw of [].concat(mine || [])) {
            const tx = normalize(raw);
            if (tx) byKey.set(keyOf(tx), byKey.has(keyOf(tx)) ? newer(byKey.get(keyOf(tx)), tx) : tx);
        }
        for (const raw of [].concat(theirs || [])) {
            const tx = normalize(raw);
            if (!tx) continue;
            const k = keyOf(tx);
            byKey.set(k, byKey.has(k) ? newer(byKey.get(k), tx) : tx);
        }
        const out = [...byKey.values()].sort((a, b) => (a.startedAt - b.startedAt) || (a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)));
        return out.length > MAX_PER_CHAT ? out.slice(out.length - MAX_PER_CHAT) : out;
    }

    function fit(list, max) {
        const out = list.slice();
        const size = () => JSON.stringify(out).length;
        while (out.length > 1 && size() > max) {
            let at = 0;
            for (let i = 1; i < out.length; i++) {
                if (!out[at].end && out[i].end) at = i;
                else if (!!out[at].end === !!out[i].end && out[i].startedAt < out[at].startedAt) at = i;
            }
            out.splice(at, 1);
        }
        return out;
    }

    function rel(ms) {
        const total = Math.max(0, Math.floor((Number(ms) || 0) / 1000));
        const h = Math.floor(total / 3600);
        const m = Math.floor((total % 3600) / 60);
        const s = total % 60;
        const two = (n) => String(n).padStart(2, '0');
        return h ? h + ':' + two(m) + ':' + two(s) : m + ':' + two(s);
    }

    const Core = {
        V, MAX_ENTRIES, HEAD, TEXT_MAX, LABEL_MAX, MAX_PER_CHAT, KINDS, ENDS, STATES, TYPES,
        PR_STAGES,
        clean, create, push, progress, plan, branch, steer, state, run, worker, error, retry, cost, end, step, question, proposal, pr,
        merge, logOf, link, normalize, mergeList, fit, rel, keyOf
    };

    const $ = (id) => typeof document === 'undefined' ? null : document.getElementById(id);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };
    const Store = () => window.NymbotStore;
    const Api = () => window.NymbotApi;

    const live = new Map();
    const dirty = new Set();
    const fetched = new Map();
    const missed = new Map();
    const saved = new WeakSet();
    let flushTimer = null;
    let view = null;
    let viewTimer = null;
    let viewPoll = null;
    let spoken = '';

    function listOf(convId) {
        const S = Store();
        if (!S || !convId || typeof S.transcripts !== 'function') return [];
        return S.transcripts(convId);
    }

    function held(convId, pick) {
        for (const x of live.values()) if (x.conv === convId && pick(x)) return x;
        return listOf(convId).find(pick) || null;
    }

    function find(convId, id) {
        if (!id) return null;
        return held(convId, x => x.id === id || x.run === id);
    }

    function forMessage(convId, m) {
        if (!m) return null;
        const list = listOf(convId);
        const all = [...live.values()].filter(x => x.conv === convId).concat(list);
        return all.find(x => x.replies.includes(m.id))
            || (m.replyTo ? all.find(x => x.run === m.replyTo && (m.role === 'bot' || m.role === 'note')) : null)
            || (m.role === 'self' ? all.find(x => x.ask === m.id || (m.wire && x.run === m.wire)) : null)
            || null;
    }

    function touch(tx) {
        if (!tx || !tx.conv) return;
        dirty.add(tx.conv);
        if (!flushTimer) flushTimer = setTimeout(flush, FLUSH_MS);
        if (view && view.tx === tx) paint();
    }

    function flush() {
        clearTimeout(flushTimer);
        flushTimer = null;
        const S = Store();
        if (!S || typeof S.saveTranscripts !== 'function') { dirty.clear(); return; }
        for (const convId of [...dirty]) {
            dirty.delete(convId);
            if (!S.conversation(convId)) continue;
            const mine = [...live.values()].filter(x => x.conv === convId);
            const kept = listOf(convId).filter(x => !mine.some(y => y.id === x.id));
            const list = kept.concat(mine).sort((a, b) => a.startedAt - b.startedAt);
            const trimmed = list.length > MAX_PER_CHAT ? list.slice(list.length - MAX_PER_CHAT) : list;
            const write = () => S.saveTranscripts(convId, fit(trimmed, STORE_MAX_CHARS));
            const loud = mine.some(x => x.end && !saved.has(x));
            for (const x of mine) if (x.end) saved.add(x);
            if (loud || typeof S.quiet !== 'function') write();
            else S.quiet(write);
        }
        for (const [id, x] of [...live]) if (x.end && !(view && view.tx === x)) live.delete(id);
    }

    function kindOf(turn) {
        if (turn.team) return 'team';
        if (turn.research) return 'research';
        if (turn.compare) return 'compare';
        if (turn.media) return 'media';
        const steps = turn.steps || [];
        if (steps.some(s => s && (s.kind === 'tool' && s.connector))) return 'connector';
        if (steps.some(s => s && (s.kind === 'tool' || s.kind === 'server-run'))) return 'repo';
        return 'chat';
    }

    function modelOf(ui, conv) {
        const pick = (conv && conv.proModel) || (ui && ui.settings && ui.settings.proModel) || null;
        return pick && pick.label ? pick.label : '';
    }

    function txOf(turn) {
        return turn && turn.transcript ? live.get(turn.transcript) || null : null;
    }

    function begin(ui, turn, opts) {
        if (!turn || turn.quiet) return null;
        const o = opts || {};
        const now = Date.now();
        let tx = null;
        if (o.resumed && (turn.runId || turn.asked)) {
            tx = held(turn.convId, x => !x.end && ((turn.runId && x.run === turn.runId) || (turn.asked && x.ask === turn.asked)));
            if (tx) {
                tx = live.get(tx.id) || normalize(tx);
                state(tx, 'resumed', now);
            }
        }
        if (!tx) {
            const S = Store();
            const conv = S ? S.conversation(turn.convId) : null;
            const q = turn.asked && S ? S.messages(turn.convId).find(m => m.id === turn.asked) : null;
            tx = create({
                id: turn.id, conv: turn.convId, kind: kindOf(turn), at: now,
                label: q ? q.content : turn.label, model: modelOf(ui, conv),
                run: HEX.test(String(turn.runId || '')) ? turn.runId : null, ask: turn.asked
            });
        }
        live.set(tx.id, tx);
        turn.transcript = tx.id;
        turn.transcriptSeen = { label: '', status: '', waiting: false };
        touch(tx);
        return tx;
    }

    function observe(ui, turn) {
        const tx = txOf(turn);
        if (!tx || tx.end) return;
        const seen = turn.transcriptSeen || (turn.transcriptSeen = {});
        const now = Date.now();
        let changed = false;
        if (HEX.test(String(turn.runId || '')) && tx.run !== turn.runId) { tx.run = turn.runId; changed = true; }
        if (turn.asked && !tx.ask) { tx.ask = turn.asked; changed = true; }
        const kind = kindOf(turn);
        if (kind !== 'chat' && tx.kind !== kind) { tx.kind = kind; changed = true; }
        const label = ui && ui.cardLabel ? ui.cardLabel(turn) : turn.label;
        if (label && label !== seen.label) {
            seen.label = label;
            if (progress(tx, label, now)) changed = true;
        }
        const waiting = !!(turn.slot || turn.waiting);
        if (waiting !== !!seen.waiting) {
            seen.waiting = waiting;
            if (state(tx, waiting ? 'waiting' : 'running', now)) changed = true;
        }
        if (turn.plan && plan(tx, turn.plan, now)) changed = true;
        const Git = window.NymbotGitRun;
        const branches = Git ? Git.branchSteps(turn.branches || []) : [];
        for (const b of branches) if (branch(tx, b.repo, b.branch, now)) changed = true;
        if (changed) touch(tx);
    }

    function steps(ui, turn, list) {
        const tx = txOf(turn);
        if (!tx || tx.end) return;
        const now = Date.now();
        let changed = false;
        for (const s of list || []) {
            if (!s || typeof s !== 'object') continue;
            if (s.kind === 'branch') {
                if (branch(tx, s.repo, s.branch, now)) changed = true;
                continue;
            }
            if (s.kind === 'plan') {
                const items = window.NymbotChat && window.NymbotChat.planOf ? window.NymbotChat.planOf(s.items) : s.items;
                if (items && plan(tx, items, now)) changed = true;
                continue;
            }
            const line = lineOf(ui, s);
            if (step(tx, s, line, now)) changed = true;
        }
        const kind = kindOf(turn);
        if (kind !== 'chat' && tx.kind !== kind) { tx.kind = kind; changed = true; }
        if (changed) touch(tx);
    }

    function lineOf(ui, s) {
        if (s.kind === 'research' && window.NymbotResearch && window.NymbotResearch.stepLine) {
            try { return window.NymbotResearch.stepLine(s); } catch (_) { }
        }
        if (s.kind === 'team' && typeof s.text === 'string' && s.text.trim()) return s.text;
        try { return ui && ui.progressLine ? ui.progressLine(s) : ''; } catch (_) { return ''; }
    }

    function status(ui, turn, text) {
        const tx = txOf(turn);
        if (!tx || tx.end || !text) return;
        if (progress(tx, text, Date.now())) touch(tx);
    }

    function note(ui, turn, text, kind) {
        const tx = txOf(turn);
        if (!tx || !text) return;
        const now = Date.now();
        let e;
        if (kind === 'retry') e = retry(tx, text, now);
        else if (turn.outcome === 'failed') e = error(tx, text, now);
        else e = progress(tx, text, now);
        if (e) touch(tx);
    }

    function placed(ui, turn, m) {
        const tx = txOf(turn);
        if (!tx || !m) return;
        const now = Date.now();
        if (m.role === 'bot') {
            link(tx, m.id);
            if (m.ask && Array.isArray(m.ask.questions) && m.ask.questions.length) {
                question(tx, 'asked', m.ask.questions[0].question, m.ask.questions.length, now);
            }
            if (m.proposal && Array.isArray(m.proposal.items) && m.proposal.summary) {
                proposal(tx, 'proposed', m.proposal.summary, m.proposal.items.length, now);
            }
            if (m.model && !tx.model) tx.model = clean(m.model, MODEL_MAX);
            const R = window.NymbotServerRun;
            const spent = R && R.totalCost ? R.totalCost(m) : m.cost;
            if (Number(spent) > 0) cost(tx, spent, '', now);
        } else if (m.role === 'error') {
            link(tx, m.id);
            error(tx, m.content, now);
        } else if (m.role === 'note') {
            link(tx, m.id);
        }
        touch(tx);
    }

    function finish(ui, turn) {
        const tx = txOf(turn);
        if (!tx) return;
        if (tx.end) return;
        observe(ui, turn);
        if (turn.background && !turn.stopped && !turn.outcome) {
            state(tx, 'parked', Date.now());
            touch(tx);
            flush();
            return;
        }
        const out = turn.outcome;
        let s = 'completed';
        if (turn.stopped || out === 'stopped') s = 'canceled';
        else if (out === 'failed' || (!turn.lastReplyId && out !== 'approval' && out !== 'paused' && out !== 'done')) s = 'failed';
        if (out === 'approval' || out === 'question') state(tx, 'waiting', Date.now());
        if (out === 'paused') state(tx, 'parked', Date.now());
        end(tx, s, Date.now());
        touch(tx);
        flush();
    }

    function asked(ui, turn, stage, m) {
        const tx = txOf(turn);
        const a = m && m.ask;
        if (!tx || !a || !Array.isArray(a.questions) || !a.questions.length) return;
        if (question(tx, stage, a.questions[0].question, a.questions.length, Date.now())) touch(tx);
    }

    function planned(ui, turn, stage, m) {
        const tx = txOf(turn);
        const p = m && m.proposal;
        if (!tx || !p || !p.summary) return;
        const items = Array.isArray(p.approvedItems) ? p.approvedItems : p.items;
        if (proposal(tx, stage, p.summary, Array.isArray(items) ? items.length : 0, Date.now())) touch(tx);
    }

    function steered(runId, text, convId) {
        if (!runId || !text) return;
        let tx = null;
        for (const x of live.values()) if (x.run === runId || x.id === runId) tx = x;
        if (!tx && convId) {
            const got = find(convId, runId);
            if (got) { tx = normalize(got); live.set(tx.id, tx); }
        }
        if (!tx) return;
        steer(tx, text, Date.now());
        touch(tx);
    }

    function signerFor(conv) {
        const Anon = window.NymbotAnon;
        if (!conv || !conv.anon || !Anon) return null;
        const payer = Anon.forConv(conv);
        return payer ? Anon.signer(payer) : null;
    }

    function convOfThread(thread) {
        if (!thread) return null;
        const S = Store();
        return S ? S.conversations().find(c => c.rootId === thread) || null : null;
    }

    function remoteTx(convId, r) {
        let tx = held(convId, x => x.run === r.replyTo);
        if (tx) {
            const got = live.get(tx.id);
            if (got) return got;
            tx = normalize(tx);
            live.set(tx.id, tx);
            return tx;
        }
        tx = create({
            id: r.replyTo, conv: convId, run: r.replyTo, kind: r.kind, label: r.label,
            at: Number(r.startedAt) || Date.now()
        });
        live.set(tx.id, tx);
        return tx;
    }

    function noteRemote(tx, r, at) {
        let changed = false;
        if (r.state && state(tx, r.state, at)) changed = true;
        if (r.plan && plan(tx, r.plan, at)) changed = true;
        for (const b of r.branches || []) if (branch(tx, b.repo, b.branch, at)) changed = true;
        if (Array.isArray(r.log) && merge(tx, r.log)) changed = true;
        if (changed) touch(tx);
        return changed;
    }

    function remote(ui, list) {
        const now = Date.now();
        for (const r of list || []) {
            if (!r || !HEX.test(String(r.replyTo || ''))) continue;
            const conv = convOfThread(r.thread);
            if (!conv) continue;
            const mine = ui && ui.turns ? [...ui.turns.values()].some(x => x.runId === r.replyTo) : false;
            if (mine) continue;
            const tx = remoteTx(conv.id, r);
            if (tx.end) continue;
            noteRemote(tx, r, now);
            if (now - (fetched.get(tx.id) || 0) > LOG_EVERY_MS) refresh(tx).catch(() => { });
        }
        for (const tx of [...live.values()]) {
            if (tx.end || !tx.run || tx.id !== tx.run) continue;
            if ((list || []).some(r => r && r.replyTo === tx.run)) continue;
            if (ui && ui.turns && [...ui.turns.values()].some(x => x.runId === tx.run)) continue;
            if (now - (fetched.get(tx.id) || 0) <= LOG_EVERY_MS) continue;
            refresh(tx).catch(() => { });
        }
    }

    async function fetchLog(conv, runId, since) {
        const signer = signerFor(conv);
        if (conv && conv.anon && !signer) return null;
        const opts = { timeout: 10000, signer };
        const body = { log: runId };
        if (conv && conv.anon && conv.rootId) body.thread = conv.rootId;
        let res = await Api().call('pm-runs', body, opts);
        const runs = res && res.status === 200 && res.data && Array.isArray(res.data.runs) ? res.data.runs : null;
        const hit = runs ? runs.find(r => r && r.replyTo === runId) : null;
        if (hit) return { live: true, run: hit };
        res = await Api().call('pm-done-since', { since: Math.max(0, (Number(since) || Date.now()) - 60000), log: runId }, opts);
        const ended = res && res.status === 200 && res.data && Array.isArray(res.data.runs) ? res.data.runs : null;
        const done = ended ? ended.find(r => r && r.replyTo === runId) : null;
        if (done) return { live: false, run: done };
        return runs || ended ? { live: false, run: null } : null;
    }

    async function refresh(tx) {
        if (!tx || !tx.run || !HEX.test(tx.run) || !Api()) return false;
        fetched.set(tx.id, Date.now());
        const S = Store();
        const conv = S ? S.conversation(tx.conv) : null;
        if (!conv) return false;
        let got;
        try { got = await fetchLog(conv, tx.run, tx.startedAt); } catch (_) { got = null; }
        if (!got) return false;
        const now = Date.now();
        if (!got.live && !got.run && tx.id === tx.run && !(view && view.tx === tx)) {
            const n = (missed.get(tx.id) || 0) + 1;
            missed.set(tx.id, n);
            if (n >= 3) { live.delete(tx.id); missed.delete(tx.id); }
            return false;
        }
        if (got.run) noteRemote(tx, got.run, now);
        if (!got.live && got.run && !tx.end && tx.id === tx.run) {
            const s = String(got.run.state || '');
            if (['done', 'stopped', 'failed'].includes(s)) {
                const at = Number(got.run.finishedAt) || now;
                end(tx, s === 'done' ? 'completed' : (s === 'stopped' ? 'canceled' : 'failed'), at);
                touch(tx);
            }
        }
        if (got.live && got.run && got.run.state) state(tx, got.run.state, now);
        return true;
    }

    function server(ui, turn, seen) {
        const tx = txOf(turn);
        if (!tx || !seen) return;
        const at = Date.now();
        let changed = false;
        if (seen.state && ['running', 'parked', 'waiting'].includes(seen.state) && state(tx, seen.state, at)) changed = true;
        if (Array.isArray(seen.log) && merge(tx, seen.log)) changed = true;
        if (changed) touch(tx);
    }

    async function scheduled(ui, conv, reply, runId, label) {
        if (!conv || !reply || !HEX.test(String(runId || ''))) return null;
        if (find(conv.id, runId)) return null;
        const at = Number(reply.ts) || Date.now();
        const tx = create({ id: runId, conv: conv.id, run: runId, kind: 'chat', label, at: at - 1 });
        link(tx, reply.id);
        live.set(tx.id, tx);
        try {
            const got = await fetchLog(conv, runId, at - 3600000);
            if (got && got.run) {
                if (Array.isArray(got.run.log)) merge(tx, got.run.log);
                const first = tx.entries.find(e => e.type === 'progress');
                if (first && first.t < tx.startedAt) {
                    tx.startedAt = first.t;
                    tx.entries[0].t = first.t;
                }
            }
        } catch (_) { }
        end(tx, 'completed', Math.max(at, tx.updatedAt || 0));
        touch(tx);
        flush();
        return tx;
    }

    function prEvent(ui, convId, msgId, stage, text) {
        const S = Store();
        if (!S || !convId || !msgId) return null;
        const m = S.messages(convId).find(x => x.id === msgId);
        const tx = forMessage(convId, m);
        if (!tx) return null;
        const e = pr(tx, stage, text, Date.now());
        if (!e) return null;
        if (!live.has(tx.id)) live.set(tx.id, tx);
        touch(tx);
        return e;
    }

    function exportText(tx) {
        const lines = [];
        const head = headOf(tx);
        lines.push(t('Transcript') + ': ' + head.title);
        for (const [k, v] of head.facts) lines.push(k + ': ' + v);
        lines.push('');
        for (const e of tx.entries) lines.push('+' + rel(e.t - tx.startedAt) + '  ' + entryLine(e));
        return lines.join('\n') + '\n';
    }

    function kindLabel(kind) {
        switch (kind) {
            case 'research': return t('Research');
            case 'team': return t('Team');
            case 'repo': return t('Repository task');
            case 'connector': return t('Connector');
            case 'server-run': return t('Server run');
            case 'media': return t('Media');
            case 'compare': return t('Compare');
            default: return t('Reply');
        }
    }

    function endLabel(tx, running) {
        if (tx.end === 'completed') return t('Completed');
        if (tx.end === 'failed') return t('Failed');
        if (tx.end === 'canceled') return t('Canceled');
        if (running) return tx.state === 'parked' ? t('In the background') : (tx.state === 'waiting' ? t('Waiting') : t('Running'));
        return t('Unfinished');
    }

    function stateLabel(s) {
        switch (s) {
            case 'parked': return t('Parked');
            case 'waiting': return t('Waiting');
            case 'resumed': return t('Resumed');
            default: return t('Running');
        }
    }

    function planLabel(s) {
        switch (s) {
            case 'doing': return t('doing');
            case 'done': return t('done');
            case 'skipped': return t('skipped');
            case 'removed': return t('removed');
            default: return t('planned');
        }
    }

    function credits(v) {
        return typeof window.amount === 'function' ? window.amount(Number(v) || 0, 3) : String(v);
    }

    function seconds(ms) {
        const n = Math.max(0, Math.round((Number(ms) || 0) / 1000));
        const I = window.NymbotI18n;
        return t('{n} s', { n: I && I.count ? I.count(n) : String(n) });
    }

    function entryLine(e) {
        const times = e.n > 1 ? ' ' + t('(×{n})', { n: e.n }) : '';
        switch (e.type) {
            case 'start': return t('Started: {label}', { label: e.text || '' }) + (e.model ? ' · ' + e.model : '');
            case 'progress': return e.text + times;
            case 'plan': {
                if (!e.stage) return t('Plan: {item} ({state})', { item: e.text, state: planLabel(e.state) });
                const steps = e.n > 1 ? ' ' + t('({n} steps)', { n: e.n }) : '';
                switch (e.stage) {
                    case 'approved': return t('You approved the plan: {summary}', { summary: e.text }) + steps;
                    case 'edited': return t('You edited and approved the plan: {summary}', { summary: e.text }) + steps;
                    case 'rejected': return t('You rejected the plan: {summary}', { summary: e.text });
                    case 'expired': return t('The plan was not approved in time: {summary}', { summary: e.text });
                    default: return t('Nymbot proposed a plan: {summary}', { summary: e.text }) + steps;
                }
            }
            case 'branch': return t('Working on branch {branch}', { branch: e.text }) + (e.repo ? ' · ' + e.repo : '');
            case 'steer': return t('You added instructions: {text}', { text: e.text });
            case 'state': return t('State: {state}', { state: stateLabel(e.state) });
            case 'run': {
                if (e.stage === 'start') return t('Server run started: {command}', { command: e.text || '' });
                const bits = [];
                if (e.code != null) bits.push(t('exit {code}', { code: String(e.code) }));
                if (e.ms != null) bits.push(seconds(e.ms));
                if (e.lines != null) bits.push(t('{n} output lines', { n: e.lines }));
                if (e.files != null) bits.push(t('{n} files', { n: e.files }));
                if (e.cost != null) bits.push(t('{credits} credits', { credits: credits(e.cost) }));
                return t('Server run finished') + (bits.length ? ': ' + bits.join(' · ') : '');
            }
            case 'worker': return t('Worker {n}: {text}', { n: e.lane, text: e.text }) + times;
            case 'error': return t('Error: {text}', { text: e.text });
            case 'retry': return t('Retrying: {text}', { text: e.text });
            case 'cost': return t('Step cost: {credits} credits', { credits: credits(e.cost) });
            case 'end': {
                const what = e.state === 'failed' ? t('Failed') : (e.state === 'canceled' ? t('Canceled') : t('Completed'));
                return what + ' · ' + rel(e.ms) + (e.cost != null ? ' · ' + t('{credits} credits', { credits: credits(e.cost) }) : '');
            }
            case 'omitted': return e.n === 1 ? t('1 step omitted') : t('{n} steps omitted', { n: e.n });
            case 'pr': {
                const said = e.text || '';
                switch (e.stage) {
                    case 'watch': return t('Pull request watch: {text}', { text: said });
                    case 'ci-failed': return t('CI failed: {text}', { text: said });
                    case 'ci-passed': return t('CI passing again: {text}', { text: said });
                    case 'review': return t('Review comments: {text}', { text: said });
                    case 'fix': return t('Fix run: {text}', { text: said });
                    case 'merged': return t('Pull request merged: {text}', { text: said });
                    case 'closed': return t('Pull request closed: {text}', { text: said });
                    default: return t('Stopped watching: {text}', { text: said });
                }
            }
            case 'question': {
                const what = e.stage === 'answered' ? t('You answered: {question}', { question: e.text || '' })
                    : e.stage === 'skipped' ? t('You skipped: {question}', { question: e.text || '' })
                        : e.stage === 'expired' ? t('No answer came in time: {question}', { question: e.text || '' })
                            : t('Nymbot asked: {question}', { question: e.text || '' });
                return what.replace(/: $/, '') + (e.stage === 'asked' && e.n > 1 ? ' ' + t('(+{n} more)', { n: e.n - 1 }) : '');
            }
            default: return e.text || '';
        }
    }

    function stamp(ms) {
        const d = new Date(ms);
        const two = (n) => String(n).padStart(2, '0');
        return d.getFullYear() + '-' + two(d.getMonth() + 1) + '-' + two(d.getDate()) + ' ' + two(d.getHours()) + ':' + two(d.getMinutes());
    }

    function headOf(tx) {
        const running = !tx.end && live.has(tx.id) && (Date.now() - (tx.updatedAt || 0) < 6 * 3600000);
        const lastAt = tx.end ? (tx.endedAt || tx.updatedAt) : (running ? Date.now() : tx.updatedAt);
        const facts = [
            [t('Kind'), kindLabel(tx.kind)],
            [t('Started'), stamp(tx.startedAt || Date.now())],
            [t('Duration'), rel((lastAt || tx.startedAt) - tx.startedAt)],
            [t('State'), endLabel(tx, running)]
        ];
        if (tx.model) facts.push([t('Model'), tx.model]);
        if (tx.cost > 0) facts.push([t('Total cost'), t('{credits} credits', { credits: credits(tx.cost) })]);
        return { title: tx.label || kindLabel(tx.kind), facts, running };
    }

    function paint() {
        if (viewTimer) return;
        const go = () => { viewTimer = null; render(); };
        if (typeof requestAnimationFrame === 'function' && document.visibilityState !== 'hidden') viewTimer = requestAnimationFrame(go);
        else viewTimer = setTimeout(go, 0);
    }

    function render() {
        const modal = $('modalTranscript');
        if (!view || !modal || modal.hidden) return;
        const tx = view.tx;
        const head = headOf(tx);
        $('transcriptTitle').textContent = head.title;
        const facts = $('transcriptFacts');
        facts.innerHTML = '';
        for (const [k, v] of head.facts) {
            const row = el('div', 'transcript-fact');
            row.appendChild(el('dt', null, k));
            row.appendChild(el('dd', null, v));
            facts.appendChild(row);
        }
        const list = $('transcriptSteps');
        const near = list.scrollHeight - list.scrollTop - list.clientHeight < 40;
        list.innerHTML = '';
        for (const e of tx.entries) {
            const li = el('li', 'transcript-step is-' + e.type + (e.state ? ' is-' + e.state : ''));
            const when = el('time', 'transcript-when', '+' + rel(e.t - tx.startedAt));
            when.dateTime = new Date(e.t).toISOString();
            li.appendChild(when);
            const text = el('span', 'transcript-text', entryLine(e));
            text.dir = 'auto';
            li.appendChild(text);
            list.appendChild(li);
        }
        $('transcriptEmpty').hidden = tx.entries.length > 1;
        if (near || view.first) list.scrollTop = list.scrollHeight;
        view.first = false;
        const last = tx.entries[tx.entries.length - 1];
        const say = last && head.running ? entryLine(last) : '';
        const box = $('transcriptLive');
        if (box && say && say !== spoken) {
            spoken = say;
            box.textContent = say;
        }
    }

    function stopPoll() {
        clearTimeout(viewPoll);
        viewPoll = null;
    }

    function poll() {
        stopPoll();
        const modal = $('modalTranscript');
        if (!view || !modal || modal.hidden) { view = null; return; }
        const tx = view.tx;
        if (tx.end || !view.remote) return;
        viewPoll = setTimeout(async () => {
            if (!view || view.tx !== tx) return;
            await refresh(tx).catch(() => { });
            paint();
            poll();
        }, POLL_MS);
    }

    function show(ui, tx, opts) {
        if (!tx) {
            ui.toast(t('There is no transcript for this yet.'));
            return;
        }
        if (!live.has(tx.id)) live.set(tx.id, tx);
        view = { tx, first: true, remote: !!(opts && opts.remote) };
        spoken = '';
        ui.openModal('modalTranscript');
        render();
        if (view.remote && !tx.end) {
            refresh(tx).then(() => paint()).catch(() => { });
            poll();
        }
    }

    function openFor(ui, convId, key) {
        const k = String(key || '');
        let tx = null;
        let far = false;
        if (k.startsWith('remote:')) {
            const id = k.slice(7);
            tx = find(convId, id);
            far = true;
            if (!tx) {
                const Runs = window.NymbotRuns;
                const r = Runs ? Runs.remote.find(x => x.replyTo === id) : null;
                if (r) tx = remoteTx(convId, r);
            } else {
                tx = live.get(tx.id) || normalize(tx);
            }
        } else if (k) {
            const turn = ui.turnById ? ui.turnById(k) : null;
            tx = turn ? txOf(turn) : null;
            if (!tx) {
                const got = find(convId, k);
                tx = got ? (live.get(got.id) || normalize(got)) : null;
            }
        }
        show(ui, tx, { remote: far || !!(tx && tx.id === tx.run && !tx.end) });
    }

    function openMessage(ui, convId, msgId) {
        const S = Store();
        const m = S ? S.messages(convId).find(x => x.id === msgId) : null;
        const got = forMessage(convId, m);
        const tx = got ? (live.get(got.id) || normalize(got)) : null;
        show(ui, tx, { remote: !!(tx && tx.id === tx.run && !tx.end) });
    }

    function closed() {
        stopPoll();
        view = null;
    }

    function copy(ui) {
        if (!view) return;
        ui.writeClipboard(exportText(view.tx));
    }

    function save() {
        if (!view) return;
        const tx = view.tx;
        const E = window.NymbotExport;
        const name = 'nymbot-transcript-' + new Date(tx.startedAt || Date.now()).toISOString().slice(0, 19).replace(/[:T]/g, '-') + '.txt';
        if (E && E.download) E.download(name, 'text/plain', exportText(tx));
    }

    function handlers(ui) {
        return {
            'open-transcript': (target) => {
                const convId = (target && target.dataset.conv) || (ui.conv && ui.conv.id);
                if (target && target.dataset.msg) openMessage(ui, convId, target.dataset.msg);
                else openFor(ui, convId, target && target.dataset.tx);
            },
            'transcript-copy': () => copy(ui),
            'transcript-save': () => save()
        };
    }

    function has(convId, key) {
        const k = String(key || '');
        if (!k) return false;
        if (k.startsWith('remote:')) return true;
        if (live.has(k)) return true;
        return !!find(convId, k);
    }

    function hasMessage(convId, m) {
        return !!forMessage(convId, m);
    }

    function bind() {
        const modal = $('modalTranscript');
        if (!modal) return;
        const watch = new MutationObserver(() => { if (modal.hidden) closed(); });
        watch.observe(modal, { attributes: true, attributeFilter: ['hidden'] });
        window.addEventListener('pagehide', flush);
        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') flush(); });
    }

    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
        else bind();
    }

    window.NymbotTranscripts = {
        Core,
        SYNC_MAX_CHARS,
        begin,
        observe,
        steps,
        status,
        note,
        placed,
        finish,
        asked,
        planned,
        steered,
        remote,
        server,
        scheduled,
        prEvent,
        refresh,
        flush,
        find,
        forMessage,
        has,
        hasMessage,
        openFor,
        openMessage,
        exportText,
        entryLine,
        handlers,
        get viewing() { return view ? view.tx : null; },
        live: () => [...live.values()]
    };
})();
