(function () {
    'use strict';

    const KINDS = new Set(['team', 'research', 'tool', 'connector', 'server-run', 'search', 'page']);
    const TEXT = ['stage', 'text', 'query', 'host', 'tool', 'target', 'connector', 'image', 'command', 'model'];
    const NUMBERS = ['lane', 'credits', 'code', 'subs', 'queries', 'found', 'sources', 'workers', 'ms', 'round'];
    const MAX_STEPS = 160;
    const HEAD_STEPS = 40;
    const MAX_WORKERS = 4;
    const ANNOUNCE_GAP = 1500;
    const RECENT = 40;
    const FINAL = { done: 'done', stopped: 'stopped', failed: 'failed', 'rework-failed': 'failed' };
    const MARKS = { done: 'check', failed: 'close', stopped: 'stop', waiting: 'dot', skipped: 'circle', pending: 'circle' };

    const $ = (id) => document.getElementById(id);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };
    const Store = () => window.NymbotStore;
    const credits = (v) => window.amount(Number(v) || 0, 3);

    let isOpen = false;
    let queued = false;
    let spoken = '';
    let spokenAt = 0;
    let speakTimer = null;
    let lastFocus = null;

    function clip(v, max) {
        return String(v == null ? '' : v).replace(/\s+/g, ' ').trim().slice(0, max);
    }

    function compact(step) {
        if (!step || typeof step !== 'object' || !KINDS.has(step.kind)) return null;
        const out = { kind: step.kind };
        for (const k of TEXT) {
            if (typeof step[k] === 'string' && step[k].trim()) out[k] = clip(step[k], 200);
        }
        for (const k of NUMBERS) {
            if (step[k] == null || typeof step[k] === 'boolean') continue;
            const n = Number(step[k]);
            if (Number.isFinite(n)) out[k] = n;
        }
        if (step.news === true) out.news = true;
        if (Array.isArray(step.questions)) {
            const q = step.questions.filter(x => typeof x === 'string').map(x => clip(x, 160)).filter(Boolean).slice(0, 5);
            if (q.length) out.questions = q;
        }
        return out;
    }

    function bounded(list) {
        if (list.length <= MAX_STEPS) return list;
        return list.slice(0, HEAD_STEPS).concat(list.slice(list.length - (MAX_STEPS - HEAD_STEPS)));
    }

    function modeOf(turn, steps) {
        if (turn && turn.team) return 'team';
        if (turn && turn.research) return 'research';
        if (steps.some(s => s.kind === 'tool' || s.kind === 'server-run')) return 'repo';
        return 'chat';
    }

    function record(turn, end) {
        const steps = bounded((turn && turn.tasksLog) || []);
        const mode = modeOf(turn, steps);
        if (!steps.length && mode === 'chat') return null;
        const out = { v: 1, mode, end, steps };
        const workers = turn && turn.team && Number(turn.team.workers);
        if (workers > 0) out.workers = Math.min(MAX_WORKERS, Math.floor(workers));
        return out;
    }

    function normalize(raw) {
        if (!raw || typeof raw !== 'object' || !Array.isArray(raw.steps)) return null;
        const mode = ['team', 'research', 'repo', 'chat'].includes(raw.mode) ? raw.mode : 'chat';
        const end = ['done', 'stopped', 'failed'].includes(raw.end) ? raw.end : 'done';
        const steps = bounded(raw.steps.map(compact).filter(Boolean));
        const workers = Math.min(MAX_WORKERS, Math.max(0, Math.floor(Number(raw.workers) || 0)));
        return { v: 1, mode, end, steps, workers };
    }

    function stageOf(step) {
        return String((step && step.stage) || '').toLowerCase().replace(/[^a-z-]/g, '').slice(0, 30);
    }

    function teamLine(step) {
        const text = clip(step.text, 200);
        return text || stageLabel(stageOf(step));
    }

    function stageLabel(stage) {
        switch (stage) {
            case 'split': return t('Splitting the question');
            case 'plan': return t('Planning the work');
            case 'reconcile': return t('Combining what the workers found');
            case 'contradictions': return t('Checking where the workers disagree');
            case 'send-back': return t('Sending work back for another pass');
            case 'review': return t('Reviewing the work');
            case 'write': return t('Writing the answer');
            case 'resume': return t('Picking the work back up');
            case 'pause': return t('Pausing here to carry on in a new step');
            case 'approval': return t('Waiting for your approval');
            case 'declined': return t('Carrying on without it');
            case 'done': return t('Done');
            default: return '';
        }
    }

    function modelLabel(ui, key) {
        if (!key) return '';
        const models = (ui.models && ui.models.models) || [];
        const hit = models.find(m => m.key === key);
        return (hit && hit.label) || String(key);
    }

    function statusLabel(state) {
        switch (state) {
            case 'done': return t('done');
            case 'failed': return t('failed');
            case 'stopped': return t('stopped');
            case 'waiting': return t('waiting for you');
            case 'active': return t('in progress');
            case 'skipped': return t('skipped');
            default: return t('not run yet');
        }
    }

    function item(label, state, extra) {
        return Object.assign({ label, state, detail: '', children: [], depth: 0, card: '', actions: [] }, extra || {});
    }

    function settle(items, live, end) {
        if (!items.length) return items;
        const last = items[items.length - 1];
        if (live) {
            if (last.state === 'done') last.state = 'active';
        } else if (end === 'stopped' && (last.state === 'active' || last.state === 'pending')) {
            last.state = 'stopped';
        }
        if (!live) {
            for (const it of items) if (it.state === 'active') it.state = end === 'failed' ? 'failed' : (end === 'stopped' ? 'stopped' : 'done');
        }
        return items;
    }

    function teamItems(ui, steps, m, live, end, workers0) {
        const lead = [];
        const lanes = new Map();
        let workers = workers0 || 0;
        let workerKey = '';
        let split = -1;
        for (const s of steps) {
            if (s.kind !== 'team') continue;
            const lane = Math.floor(Number(s.lane) || 0);
            if (lane < 0 || lane > MAX_WORKERS) continue;
            const stage = stageOf(s);
            if (lane === 0) {
                if (Number(s.workers) > 0) workers = Math.min(MAX_WORKERS, Number(s.workers));
                if (s.model) workerKey = s.model;
                const line = teamLine(s);
                if (!line || (lead.length && lead[lead.length - 1].label === line)) continue;
                const state = stage === 'approval' ? 'waiting' : (stage === 'declined' ? 'skipped' : 'done');
                lead.push(item(line, state, { stage, card: stage === 'approval' ? '.pending-tool' : '' }));
                continue;
            }
            if (lane > workers) workers = lane;
            const w = lanes.get(lane) || { assigned: '', lines: [], stage: '' };
            if (stage === 'assigned') {
                w.assigned = clip(s.text, 200);
                if (split < 0) split = lead.length;
            } else {
                const line = teamLine(s);
                if (line && w.lines[w.lines.length - 1] !== line) w.lines.push(line);
                w.stage = stage;
            }
            lanes.set(lane, w);
        }
        for (let i = 0; i < lead.length - 1; i++) {
            if (lead[i].state === 'waiting') lead[i].state = 'done';
        }
        const summary = m && m.team && Array.isArray(m.team.workers) ? m.team.workers : [];
        for (const w of summary) workers = Math.max(workers, Math.min(MAX_WORKERS, Math.floor(Number(w.lane) || 0)));
        const crew = [];
        for (let lane = 1; lane <= workers; lane++) {
            const w = lanes.get(lane) || { assigned: '', lines: [], stage: '' };
            const sum = summary.find(x => Math.floor(Number(x.lane)) === lane);
            let state = FINAL[w.stage] || '';
            if (!state) {
                if (live) state = w.lines.length ? 'active' : 'pending';
                else if (sum) state = sum.status === 'pending' ? 'pending' : (FINAL[sum.status] || 'done');
                else state = end === 'failed' ? 'failed' : (end === 'stopped' ? 'stopped' : 'done');
            }
            const bits = [t('Worker {n}', { n: lane })];
            const model = modelLabel(ui, (sum && sum.model) || (m && m.team && m.team.workerModel) || workerKey);
            if (model) bits.push(model);
            if (sum) bits.push(t('{credits} Pro credits', { credits: credits(sum.credits) }));
            bits.push(statusLabel(state));
            crew.push(item(w.assigned || t('Worker {n}', { n: lane }), state, {
                depth: 1, detail: bits.join(' · '), children: w.lines.slice(-6), card: '.team-summary'
            }));
        }
        const before = split < 0 ? lead.slice() : lead.slice(0, split);
        const after = split < 0 ? [] : lead.slice(split);
        const out = before;
        if (crew.length) {
            const busy = crew.some(c => c.state === 'active' || c.state === 'pending');
            const bad = crew.some(c => c.state === 'failed');
            const lead0 = m && m.team ? t('{credits} Pro credits', { credits: credits(m.team.overseerCredits) }) : '';
            out.push(item(t('{n} workers', { n: crew.length }), live && busy && !after.length ? 'active' : (bad ? 'failed' : 'done'), {
                detail: lead0 ? t('Lead: {cost}', { cost: lead0 }) : '', card: '.team-summary', group: true
            }));
            for (const c of crew) out.push(c);
        }
        for (const a of after) out.push(a);
        if (live) {
            const last = out.filter(x => !x.depth).pop();
            if (last && last.state === 'done' && !(last.group && crew.some(c => c.state === 'active'))) last.state = 'active';
        } else {
            settle(out.filter(x => !x.depth), false, end);
        }
        return out;
    }

    function hostOf(url) {
        try { return new URL(url).hostname.replace(/^www\./, ''); } catch (_) { return ''; }
    }

    function researchItems(steps, m, live, end) {
        const R = window.NymbotResearch;
        const out = [];
        let plan = null;
        const hosts = [];
        let writing = false;
        let lastStage = '';
        for (const s of steps) {
            if (s.kind !== 'research') continue;
            lastStage = s.stage || '';
            if (s.stage === 'plan') {
                if (!plan) plan = item(t('Planning the research'), 'active');
            } else if (s.stage === 'planned') {
                plan = plan || item('', 'done');
                plan.label = R.stepLine(s);
                plan.state = 'done';
                plan.children = (s.questions || []).slice(0, 5);
            } else if (s.stage === 'search') {
                const line = R.stepLine(s);
                if (!out.some(x => x.label === line)) out.push(item(line, 'done', { kind: 'search' }));
            } else if (s.stage === 'read') {
                const host = String(s.host || '').replace(/^www\./, '');
                if (host && !hosts.includes(host)) hosts.push(host);
            } else if (s.stage === 'write') {
                writing = true;
            }
        }
        if (plan && plan.state === 'active' && (out.length || !live)) plan.state = 'done';
        if (live && lastStage === 'search' && out.length) out[out.length - 1].state = 'active';
        const sources = m && Array.isArray(m.sources) ? m.sources : [];
        const shown = hosts.length ? hosts : sources.map(s => hostOf(s && s.url)).filter((h, i, a) => h && a.indexOf(h) === i);
        const items = [];
        if (plan) items.push(plan);
        for (const s of out) items.push(s);
        if (shown.length) {
            items.push(item(shown.length === 1 ? t('Read 1 source') : t('Read {n} sources', { n: shown.length }),
                live && lastStage === 'read' ? 'active' : 'done',
                { children: shown.slice(0, 12), favicons: true, card: '.citations' }));
        }
        let write = 'pending';
        if (!live) write = end === 'done' ? 'done' : (end === 'stopped' ? 'stopped' : 'failed');
        else if (writing) write = 'active';
        items.push(item(t('Writing the report'), write, { card: '.citations' }));
        if (!live) for (const it of items) if (it.state === 'active') it.state = write === 'done' ? 'done' : write;
        return items;
    }

    function runDetail(run) {
        const bits = [];
        if (run.image) bits.push(run.image);
        if (run.code != null) bits.push(t('exit {code}', { code: String(run.code) }));
        const ms = Number(run.ms != null ? run.ms : run.billedMs);
        if (ms > 0) bits.push(t('{n} s', { n: window.NymbotI18n.count(Math.max(1, Math.round(ms / 1000))) }));
        if (run.milli != null) bits.push(t('{credits} Pro credits', { credits: credits((Number(run.milli) || 0) / 1000) }));
        else if (run.credits != null) bits.push(t('{credits} Pro credits', { credits: credits(run.credits) }));
        return bits.join(' · ');
    }

    function runLabel(run) {
        return run.command
            ? t('Server run: {command}', { command: clip(run.command, 120) })
            : t('Server run on {image}', { image: run.image || '' });
    }

    function workItems(ui, steps, m, live, end) {
        const out = [];
        const runs = [];
        for (const s of steps) {
            if (s.kind === 'server-run') {
                if (s.stage === 'start') {
                    const it = item(runLabel(s), 'active', { run: { image: s.image, command: s.command }, card: '.server-run-summary' });
                    it.detail = s.image || '';
                    runs.push(it);
                    out.push(it);
                } else if (s.stage === 'done') {
                    const it = runs.filter(r => r.state === 'active').pop();
                    if (!it) continue;
                    Object.assign(it.run, { code: s.code, ms: s.ms, credits: s.credits });
                    it.state = s.code == null || s.code === 0 ? 'done' : 'failed';
                    it.detail = runDetail(it.run);
                }
                continue;
            }
            if (s.kind === 'tool' && !s.connector) {
                const prev = out[out.length - 1];
                const target = clip(s.target, 160);
                if (prev && prev.tool === s.tool && !prev.run) {
                    if (target && !prev.children.includes(target)) prev.children.push(target);
                    continue;
                }
                out.push(item(ui.toolLabel(s.tool), 'done', { tool: s.tool, children: target ? [target] : [] }));
                continue;
            }
            const line = ui.progressLine(s);
            if (!line || (out.length && out[out.length - 1].label === line)) continue;
            out.push(item(line, 'done'));
        }
        const kept = m && Array.isArray(m.serverRuns) ? m.serverRuns : [];
        kept.forEach((r, i) => {
            const it = runs[i];
            const state = r.code == null ? 'failed' : (r.code === 0 ? 'done' : 'failed');
            if (it) {
                Object.assign(it.run, r);
                it.label = runLabel(it.run);
                it.state = state;
                it.detail = runDetail(it.run);
            } else {
                out.push(item(runLabel(r), state, { run: r, detail: runDetail(r), card: '.server-run-summary' }));
            }
        });
        for (const it of out) if (it.children.length > 8) it.children = it.children.slice(-8);
        return settle(out, live, end);
    }

    function trailing(m) {
        const out = [];
        if (!m) return out;
        if (m.staged && window.NymbotGitRun) {
            const one = window.NymbotGitRun.all(m.staged);
            const state = m.staged.applied ? 'done' : (m.staged.discarded ? 'skipped' : 'waiting');
            out.push(item(m.staged.applied ? t('Staged changes applied')
                : (m.staged.discarded ? t('Staged changes discarded') : t('Changes staged for your review')), state, {
                detail: one.map(s => s.repo + (s.branch ? ' · ' + s.branch : '')).join(', '),
                children: one.map(s => s.message).filter(Boolean).slice(0, 3),
                card: '.staged-card'
            }));
        } else if (m.checkpoint && m.checkpoint.repo) {
            out.push(item(t('Changes committed to {repo}', { repo: m.checkpoint.repo }), 'done', { card: '.checkpoint-card' }));
        }
        const p = m.pendingTool;
        if (p && typeof p === 'object') {
            const run = p.kind === 'server-run';
            const state = p.state === 'allowed' ? 'done' : (p.state === 'denied' ? 'skipped' : 'waiting');
            const label = run
                ? t('Run on a Nymbot server: {command}', { command: clip(p.command, 120) })
                : t('Use {connector}: {tool}', { connector: p.connector || '', tool: p.tool || '' });
            const bits = [];
            if (p.team) bits.push(t('Asked by the team lead'));
            if (run && p.image) bits.push(p.image);
            if (run && p.maxCredits) bits.push(t('Up to {credits} Pro credits', { credits: credits(p.maxCredits) }));
            if (state !== 'waiting') bits.push(p.state === 'allowed' ? t('allowed once') : (run ? t('declined') : t('denied')));
            out.push(item(label, state, {
                detail: bits.join(' · '), card: '.pending-tool', approval: true,
                actions: state === 'waiting' ? [
                    { act: 'allow', label: t('Allow once'), primary: true },
                    { act: 'deny', label: run ? t('Decline') : t('Deny') }
                ] : []
            }));
        }
        return out;
    }

    function itemsFor(ui, mode, steps, m, live, end, workers) {
        let items;
        if (mode === 'team') items = teamItems(ui, steps, m, live, end, workers);
        else if (mode === 'research') items = researchItems(steps, m, live, end);
        else items = workItems(ui, steps, m, live, end);
        return items.concat(trailing(m));
    }

    function modeLabel(mode) {
        switch (mode) {
            case 'team': return t('Team');
            case 'research': return t('Research');
            case 'repo': return t('Repository task');
            case 'tool': return t('Tool call');
            default: return t('Reply');
        }
    }

    function askedBefore(list, i) {
        for (let j = i; j >= 0; j--) {
            if (list[j].role === 'self') return clip(list[j].content, 90);
        }
        return '';
    }

    function groupState(items, live, end) {
        if (live) return 'running';
        if (items.some(it => it.state === 'waiting')) return 'waiting';
        return end || 'done';
    }

    function groupOf(ui, m, list, i) {
        const rec = normalize(m.tasks);
        const runs = Array.isArray(m.serverRuns) && m.serverRuns.length;
        let mode = rec ? rec.mode : null;
        if (!mode) {
            if (m.team) mode = 'team';
            else if (runs || m.staged || m.checkpoint) mode = 'repo';
            else if (m.pendingTool) mode = 'tool';
        }
        if (!mode) return null;
        const end = rec ? rec.end : 'done';
        const items = itemsFor(ui, mode, rec ? rec.steps : [], m.role === 'bot' ? m : null, false, end, rec ? rec.workers : 0);
        if (!items.length) return null;
        return {
            id: m.id, messageId: m.id, mode, live: false,
            title: askedBefore(list, i) || modeLabel(mode),
            state: groupState(items, false, end), items, ts: m.ts || 0
        };
    }

    function liveGroup(ui, conv) {
        const turn = ui.turnOf && ui.turnOf(conv.id);
        if (!turn || turn.quiet) return null;
        const steps = turn.tasksLog || [];
        const mode = modeOf(turn, steps);
        const workers = turn.team && Number(turn.team.workers) > 0 ? Number(turn.team.workers) : 0;
        let items = mode === 'chat' && !steps.length ? [] : itemsFor(ui, mode, steps, null, true, '', workers);
        if (!items.length) items = [item(turn.status || turn.label || t('Nymbot is thinking'), 'active')];
        const list = Store().messages(conv.id);
        return {
            id: 'live', messageId: 'live', mode, live: true,
            title: turn.label || t('Nymbot is thinking'),
            asked: askedBefore(list, list.length - 1),
            state: 'running', items, ts: Date.now()
        };
    }

    function outline(ui, conv) {
        const c = conv || ui.conv;
        if (!c) return [];
        const list = Store().messages(c.id);
        const groups = [];
        const live = liveGroup(ui, c);
        if (live) groups.push(live);
        for (let i = list.length - 1; i >= 0; i--) {
            const m = list[i];
            if (m.role !== 'bot' && !(m.role === 'self' && m.tasks)) continue;
            const g = groupOf(ui, m, list, i);
            if (g) groups.push(g);
        }
        return groups;
    }

    function waitingCount(ui, conv) {
        const list = Store().messages(conv.id).slice(-RECENT);
        return list.filter(m => m.pendingTool && (!m.pendingTool.state || m.pendingTool.state === 'waiting')).length;
    }

    function began(ui, turn) {
        turn.tasksAt = Date.now();
        turn.tasksLog = [];
        refresh(ui);
    }

    function seen(ui, turn, steps) {
        if (!turn.tasksLog) turn.tasksLog = [];
        for (const s of steps || []) {
            const c = compact(s);
            if (c) turn.tasksLog.push(c);
        }
        refresh(ui);
    }

    function targetOf(turn) {
        const list = Store().messages(turn.convId);
        const since = turn.tasksAt || 0;
        for (let i = list.length - 1; i >= 0; i--) {
            const m = list[i];
            if (m.role === 'bot' && (m.ts || 0) >= since) return m;
            if (m.role === 'self' || m.role === 'bot') break;
        }
        for (let i = list.length - 1; i >= 0; i--) {
            const m = list[i];
            if (m.role === 'bot') return null;
            if (m.role === 'self') return m.tasks ? null : m;
        }
        return null;
    }

    function ended(ui, turn) {
        if (!turn || turn.tasksKept) return;
        turn.tasksKept = true;
        const log = turn.tasksLog || [];
        if (log.length || turn.team || turn.research) {
            const m = targetOf(turn);
            if (m) {
                const end = turn.stopped ? 'stopped' : (m.role === 'bot' ? 'done' : 'failed');
                const rec = record(turn, end);
                if (rec) Store().patchMessage(turn.convId, m.id, { tasks: rec, updatedAt: Date.now() });
            }
        }
        refresh(ui);
        if (isOpen && ui.conv && ui.conv.id === turn.convId) {
            speak(turn.stopped ? t('Stopped') : t('Finished'), true);
        }
    }

    function refresh(ui) {
        if (queued) return;
        queued = true;
        const run = () => {
            queued = false;
            render(ui);
        };
        if (typeof requestAnimationFrame === 'function' && document.visibilityState !== 'hidden') requestAnimationFrame(run);
        else setTimeout(run, 0);
    }

    function speak(text, now) {
        const box = $('tasksLive');
        if (!box || !text || text === spoken) return;
        const wait = now ? 0 : Math.max(0, ANNOUNCE_GAP - (Date.now() - spokenAt));
        clearTimeout(speakTimer);
        const say = () => {
            spoken = text;
            spokenAt = Date.now();
            box.textContent = text;
        };
        if (!wait) say();
        else speakTimer = setTimeout(say, wait);
    }

    function renderButton(ui, groups) {
        const btn = $('tasksBtn');
        if (!btn) return;
        const conv = ui.conv;
        const live = groups && groups[0] && groups[0].live ? groups[0] : null;
        const waiting = conv ? waitingCount(ui, conv) : 0;
        btn.classList.toggle('is-running', !!live);
        btn.classList.toggle('is-waiting', !live && waiting > 0);
        btn.classList.toggle('is-open', isOpen);
        btn.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
        const badge = btn.querySelector('.tasks-badge');
        let text = '';
        let label = t('Tasks');
        if (live) {
            const top = live.items.filter(x => !x.depth);
            const done = top.filter(x => x.state === 'done' || x.state === 'skipped').length;
            text = top.length > 1 ? done + '/' + top.length : '';
            label = t('Tasks: work is running');
        } else if (waiting) {
            text = String(waiting);
            label = waiting === 1 ? t('Tasks: 1 waiting for you') : t('Tasks: {n} waiting for you', { n: waiting });
        }
        if (badge) {
            badge.textContent = text;
            badge.hidden = !text;
        }
        btn.setAttribute('aria-label', label);
        btn.title = label;
    }

    function mark(state) {
        const span = el('span', 'task-mark is-' + state);
        span.setAttribute('aria-hidden', 'true');
        if (state === 'active') span.appendChild(el('span', 'task-spin'));
        else if (window.NymbotIcons) span.innerHTML = window.NymbotIcons.markup(MARKS[state] || 'circle', { size: 12, filled: state === 'waiting' || state === 'stopped', weight: 2.4 });
        return span;
    }

    function favicon(host) {
        const img = el('img', 'task-favicon');
        img.src = 'https://' + window.NymbotConfig.apiHost + '/api/proxy?action=favicon&host=' + encodeURIComponent(host);
        img.alt = '';
        img.loading = 'lazy';
        img.referrerPolicy = 'no-referrer';
        img.addEventListener('error', () => { img.hidden = true; });
        return img;
    }

    function itemNode(ui, g, it) {
        const li = el('li', 'task-item is-' + it.state + (it.depth ? ' is-nested' : ''));
        const row = el('button', 'task-row task-focus');
        row.type = 'button';
        row.tabIndex = -1;
        row.dataset.message = g.messageId;
        if (it.card) row.dataset.card = it.card;
        if (it.state === 'active') row.setAttribute('aria-current', 'step');
        row.appendChild(mark(it.state));
        const main = el('span', 'task-main');
        main.appendChild(el('span', 'task-label', it.label));
        const sr = el('span', 'sr-only', ' (' + statusLabel(it.state) + ')');
        main.appendChild(sr);
        if (it.detail) main.appendChild(el('span', 'task-detail', it.detail));
        row.appendChild(main);
        row.addEventListener('click', () => jump(ui, g.messageId, it.card));
        li.appendChild(row);
        if (it.children.length) {
            const kids = el('ul', 'task-children');
            for (const c of it.children) {
                const k = el('li', 'task-child');
                if (it.favicons) k.appendChild(favicon(c));
                k.appendChild(el('span', '', c));
                kids.appendChild(k);
            }
            li.appendChild(kids);
        }
        if (it.actions.length) {
            const row2 = el('div', 'task-actions');
            for (const a of it.actions) {
                const b = el('button', 'btn btn-small task-focus' + (a.primary ? ' btn-primary' : ' btn-ghost'), a.label);
                b.type = 'button';
                b.tabIndex = -1;
                b.dataset.role = a.act;
                b.addEventListener('click', () => approve(ui, g.messageId, a.act === 'allow'));
                row2.appendChild(b);
            }
            li.appendChild(row2);
        }
        return li;
    }

    function groupNode(ui, g) {
        const section = el('section', 'task-group is-' + g.state + (g.live ? ' is-live' : ''));
        section.dataset.group = g.id;
        const head = el('div', 'task-group-head');
        const jumpBtn = el('button', 'task-group-title task-focus');
        jumpBtn.type = 'button';
        jumpBtn.tabIndex = -1;
        jumpBtn.dataset.message = g.messageId;
        jumpBtn.appendChild(el('span', 'task-group-name', g.live && g.asked ? g.asked : g.title));
        const meta = [modeLabel(g.mode)];
        if (g.live) meta.push(t('running'));
        else if (g.state === 'waiting') meta.push(t('waiting for you'));
        else if (g.state === 'stopped') meta.push(t('stopped'));
        else if (g.state === 'failed') meta.push(t('failed'));
        else meta.push(t('done'));
        if (!g.live && g.ts && ui.timeLabel) meta.push(ui.timeLabel(g.ts));
        jumpBtn.appendChild(el('span', 'task-group-meta', meta.join(' · ')));
        jumpBtn.addEventListener('click', () => jump(ui, g.messageId, ''));
        head.appendChild(jumpBtn);
        if (g.live) {
            const stop = el('button', 'btn btn-small btn-ghost task-stop task-focus', t('Stop'));
            stop.type = 'button';
            stop.tabIndex = -1;
            stop.dataset.act = 'stop';
            head.appendChild(stop);
        }
        section.appendChild(head);
        const list = el('ol', 'task-list');
        for (const it of g.items) list.appendChild(itemNode(ui, g, it));
        section.appendChild(list);
        return section;
    }

    function render(ui) {
        const conv = ui.conv;
        const groups = conv ? outline(ui, conv) : [];
        renderButton(ui, groups);
        if (!isOpen) return;
        const body = $('tasksBody');
        if (!body) return;
        const had = document.activeElement && body.contains(document.activeElement)
            ? focusKey(document.activeElement) : null;
        body.innerHTML = '';
        if (!groups.length) {
            body.appendChild(el('p', 'tasks-empty', t('Nothing here yet. Research, Team mode, repository work, server runs and tool approvals in this chat are listed here, newest first.')));
        }
        for (const g of groups) body.appendChild(groupNode(ui, g));
        roving(body, had);
        const live = groups[0] && groups[0].live ? groups[0] : null;
        if (live) {
            const current = live.items.filter(x => x.state === 'active').pop() || live.items[live.items.length - 1];
            if (current) speak(current.label);
        }
    }

    function focusKey(node) {
        const all = Array.from($('tasksBody').querySelectorAll('.task-focus'));
        return { index: all.indexOf(node), text: node.textContent };
    }

    function roving(body, had) {
        const all = Array.from(body.querySelectorAll('.task-focus'));
        if (!all.length) return;
        let pick = null;
        if (had) pick = all.find(n => n.textContent === had.text) || all[Math.min(had.index, all.length - 1)];
        const chosen = pick || body.querySelector('.task-row[aria-current="step"]') || all[0];
        for (const n of all) n.tabIndex = n === chosen ? 0 : -1;
        if (had && pick) pick.focus({ preventScroll: true });
    }

    function onKey(e) {
        const body = $('tasksBody');
        if (e.key === 'Escape') {
            e.preventDefault();
            e.stopPropagation();
            close(window.NymbotUI, true);
            return;
        }
        if (!body || !body.contains(e.target)) return;
        const all = Array.from(body.querySelectorAll('.task-focus'));
        const at = all.indexOf(e.target);
        if (at < 0) return;
        let next = -1;
        if (e.key === 'ArrowDown') next = Math.min(all.length - 1, at + 1);
        else if (e.key === 'ArrowUp') next = Math.max(0, at - 1);
        else if (e.key === 'Home') next = 0;
        else if (e.key === 'End') next = all.length - 1;
        if (next < 0) return;
        e.preventDefault();
        for (const n of all) n.tabIndex = -1;
        all[next].tabIndex = 0;
        all[next].focus();
    }

    function narrow() {
        return !!(window.matchMedia && window.matchMedia('(max-width: 720px)').matches);
    }

    function jump(ui, messageId, card) {
        const box = $('messages');
        if (!box) return;
        let node = null;
        if (messageId === 'live') {
            const turn = ui.turnOf(ui.conv && ui.conv.id);
            node = turn && turn.node;
        } else {
            node = Array.from(box.querySelectorAll('.chat-message')).find(n => n.dataset.id === messageId) || null;
        }
        if (!node) return;
        const target = (card && node.querySelector(card)) || node;
        if (narrow()) close(ui, false);
        target.scrollIntoView({ block: 'center', behavior: ui.reducedMotion() ? 'auto' : 'smooth' });
        node.classList.add('is-hit');
        target.classList.add('is-task-hit');
        setTimeout(() => {
            node.classList.remove('is-hit');
            target.classList.remove('is-task-hit');
        }, 2200);
    }

    function approve(ui, messageId, yes) {
        const conv = ui.conv;
        if (!conv) return null;
        const m = Store().messages(conv.id).find(x => x.id === messageId);
        const p = m && m.pendingTool;
        if (!p || (p.state && p.state !== 'waiting')) return null;
        if (p.kind === 'server-run' && window.NymbotServerRun) return window.NymbotServerRun.resume(ui, m, yes);
        const K = window.NymbotConnectors;
        if (!K) return null;
        return yes ? K.allow(ui, m) : K.deny(ui, m);
    }

    function open(ui) {
        const panel = $('tasksPanel');
        if (!panel || !ui.conv) return;
        if (ui.artifact) ui.closeArtifact();
        lastFocus = document.activeElement;
        isOpen = true;
        panel.hidden = false;
        document.querySelector('.shell').classList.add('has-tasks');
        spoken = '';
        render(ui);
        const first = $('tasksBody').querySelector('.task-focus[tabindex="0"]') || $('tasksClose');
        if (first) first.focus({ preventScroll: true });
    }

    function close(ui, restore) {
        const panel = $('tasksPanel');
        if (!panel || !isOpen) return;
        isOpen = false;
        panel.hidden = true;
        document.querySelector('.shell').classList.remove('has-tasks');
        clearTimeout(speakTimer);
        if (ui) renderButton(ui, ui.conv ? outline(ui, ui.conv) : []);
        if (restore) {
            const back = $('tasksBtn') || lastFocus;
            if (back && back.focus) back.focus();
        }
    }

    function toggle(ui) {
        if (isOpen) close(ui, true);
        else open(ui);
    }

    function switched(ui) {
        spoken = '';
        refresh(ui);
    }

    function handlers(ui) {
        return {
            'open-tasks': () => toggle(ui),
            'tasks-close': () => close(ui, true)
        };
    }

    function helpTopic() {
        return {
            title: t('Tasks'),
            body: t('The checklist button at the top of a chat opens its Tasks pane: an outline of the multi-step work the chat has done, newest first. Research shows its plan, searches, the sources it read and the report; Team mode shows the lead\'s plan, each worker\'s part with its model, cost and status, and the lead\'s review; repository work shows its steps, server runs and staged changes. Anything waiting for your approval can be allowed or declined from there, and every step jumps to its place in the chat. The outline is kept with the chat\'s messages, so it is still there after the work finishes and on your other devices.')
        };
    }

    function bind() {
        const panel = $('tasksPanel');
        if (panel) panel.addEventListener('keydown', onKey);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', bind);
    } else {
        bind();
    }

    window.NymbotTasks = {
        compact,
        record,
        normalize,
        outline,
        began,
        seen,
        ended,
        refresh,
        switched,
        open,
        close,
        toggle,
        jump,
        approve,
        handlers,
        helpTopic,
        get isOpen() { return isOpen; }
    };
})();
