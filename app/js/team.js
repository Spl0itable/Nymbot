(function () {
    'use strict';

    const MIN_WORKERS = 2;
    const MAX_WORKERS = 4;
    const DEFAULT_WORKERS = 3;
    const FINAL = new Set(['done', 'stopped', 'failed', 'rework-failed']);
    const STATUSES = new Set(['done', 'stopped', 'failed', 'pending']);

    const $ = (id) => document.getElementById(id);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };
    const num = (v) => window.NymbotI18n.count(v);
    const credits = (v) => window.amount(Number(v) || 0, 3);

    let draft = null;
    let pricing = 0;
    let loading = null;

    function clampWorkers(n) {
        const v = Math.round(Number(n));
        if (!Number.isFinite(v)) return DEFAULT_WORKERS;
        return Math.min(MAX_WORKERS, Math.max(MIN_WORKERS, v));
    }

    function settingOf(conv) {
        const team = conv && conv.team;
        if (!team || typeof team !== 'object' || !team.model || !team.model.key) return null;
        return {
            workers: clampWorkers(team.workers),
            model: { key: String(team.model.key), label: String(team.model.label || team.model.key) }
        };
    }

    function lead(ui, conv) {
        const c = conv || ui.conv || {};
        if (ui.mediaModel(c)) return null;
        return c.proModel || (ui.settings && ui.settings.proModel) || null;
    }

    function reposOf(conv) {
        return window.NymbotChat ? window.NymbotChat.reposFor(conv || {}) : [];
    }

    function upcoming(ui, conv) {
        const c = conv || ui.conv;
        if (!c || !lead(ui, c)) return null;
        if (window.NymbotResearch && window.NymbotResearch.armed) return 'research';
        return reposOf(c).length ? 'repo' : null;
    }

    function available(ui, conv) {
        return !!upcoming(ui, conv);
    }

    function claim(ui, conv, research) {
        const team = settingOf(conv);
        if (!team || !lead(ui, conv)) return null;
        const mode = research ? 'research' : (reposOf(conv).length ? 'repo' : null);
        if (!mode) return null;
        return { workers: team.workers, model: team.model.key, mode };
    }

    function leadTools(conv, mode) {
        const c = conv || {};
        const Connectors = window.NymbotConnectors;
        const connectors = !!(Connectors && !c.anon && Connectors.forConv(c).length);
        const runs = mode === 'repo' && !!(c.serverRuns && reposOf(c).length);
        return connectors || runs;
    }

    function ensureModels(ui) {
        if (ui.models && ui.models.models) return Promise.resolve(ui.models);
        if (!loading) {
            loading = window.NymbotApi.models().then((data) => {
                if (data && data.models) ui.models = data;
                loading = null;
                return ui.models;
            }, () => { loading = null; return null; });
        }
        return loading;
    }

    function choices(ui) {
        const models = (ui.models && ui.models.models) || [];
        return models.filter(m => m && m.key && !m.command && (m.kind || 'chat') === 'chat');
    }

    function makerOf(ui, m) {
        const groups = (ui.models && ui.models.groups) || [];
        const group = groups.find(g => (g.keys || []).includes(m.key)) || {};
        return m.authorSlug || m.slug || group.authorSlug || null;
    }

    function defaultWorker(ui, leader) {
        const rows = choices(ui);
        if (!rows.length) return null;
        const full = leader ? rows.find(m => m.key === leader.key) : null;
        const family = full ? makerOf(ui, full) : (leader && leader.slug) || null;
        const metered = rows.filter(m => ui.modelTurnCredits(m) != null);
        const price = (m) => ui.modelSortPrice(m);
        const cheapest = (list) => list.slice().sort((a, b) => price(a) - price(b)
            || (Number(a.max) || Number(a.credits) || 0) - (Number(b.max) || Number(b.credits) || 0))[0] || null;
        const pick = (family && cheapest(metered.filter(m => makerOf(ui, m) === family)))
            || cheapest(metered)
            || cheapest(rows);
        return pick ? { key: pick.key, label: pick.label || pick.key } : null;
    }

    function labelOf(ui, key) {
        const models = (ui.models && ui.models.models) || [];
        const hit = models.find(m => m.key === key);
        return (hit && hit.label) || String(key || '');
    }

    function needsPro() {
        return t('Team mode needs a Pro model to lead it. Pick one with ?model first.');
    }

    function wrongTask() {
        return t('Team mode is for deep research and repository tasks. Turn Research on or connect a repository first.');
    }

    async function estimate(ui, conv, team, mode) {
        const leader = lead(ui, conv);
        if (!leader) return { error: needsPro() };
        const body = {
            proModel: leader.key,
            team: { workers: clampWorkers(team.workers), model: team.model, mode }
        };
        if (mode === 'research') body.research = true;
        if (mode === 'repo') body.repos = true;
        if (leadTools(conv, mode)) body.leadTools = true;
        const res = await window.NymbotApi.teamEstimate(body);
        const data = res && res.data;
        if (!res || res.status !== 200 || !data || data.error || !(Number(data.maxCredits) > 0)) {
            const said = res && res.status === 400 && data && typeof data.error === 'string' ? data.error.slice(0, 400) : '';
            return { error: said || t('Could not work out what this team would cost right now.') };
        }
        return {
            max: Math.ceil(Number(data.maxCredits)),
            typical: Math.max(0, Number(data.typicalCredits) || 0),
            data
        };
    }

    function priceLine(est) {
        return t('Up to {max} Pro credits · usually about {typical}', {
            max: num(est.max),
            typical: window.amount(est.typical, 1)
        });
    }

    function refreshChip(ui) {
        const chip = $('chipTeam');
        if (!chip) return;
        const conv = ui.conv || {};
        const team = settingOf(conv);
        chip.hidden = !available(ui, conv);
        chip.classList.toggle('is-active', !chip.hidden && !!team);
        chip.querySelector('.chip-label').textContent = team
            ? t('Team of {n}', { n: team.workers })
            : t('Team');
    }

    function show(ui) {
        if (!draft) return;
        const conv = ui.conv || {};
        const leader = lead(ui, conv);
        $('teamLead').textContent = leader
            ? t('Led by {model}, the model pinned to this chat.', { model: leader.label || leader.key })
            : needsPro();
        $('teamWorkers').value = String(draft.workers);
        $('teamModelName').textContent = draft.model
            ? draft.model.label
            : t('Loading the models…');
        $('teamLeadTools').hidden = !leadTools(conv, upcoming(ui, conv) || (reposOf(conv).length ? 'repo' : 'research'));
        $('teamOff').hidden = !settingOf(conv);
    }

    async function price(ui) {
        const box = $('teamPrice');
        if (!draft || !draft.model || !ui.conv) {
            box.textContent = '';
            return;
        }
        const mode = upcoming(ui, ui.conv) || (reposOf(ui.conv).length ? 'repo' : 'research');
        const seq = ++pricing;
        box.textContent = t('Working out the price…');
        box.classList.remove('is-warn');
        const est = await estimate(ui, ui.conv, { workers: draft.workers, model: draft.model.key }, mode);
        if (seq !== pricing) return;
        box.textContent = est.error ? est.error : priceLine(est);
        box.classList.toggle('is-warn', !!est.error);
    }

    function open(ui) {
        const conv = ui.conv;
        if (!conv) return;
        const leader = lead(ui, conv);
        if (!leader) {
            ui.toast(needsPro());
            return;
        }
        if (!upcoming(ui, conv)) {
            ui.toast(wrongTask());
            return;
        }
        const saved = settingOf(conv);
        draft = {
            workers: saved ? saved.workers : DEFAULT_WORKERS,
            model: saved ? saved.model : null
        };
        reopen(ui);
        return ensureModels(ui).then(() => {
            if (!draft) return;
            if (!draft.model) draft.model = defaultWorker(ui, leader);
            show(ui);
            return price(ui);
        });
    }

    function reopen(ui) {
        ui.openModal('modalTeam');
        ui.modalStatus('teamStatus', '');
        show(ui);
        price(ui);
    }

    function setWorkers(ui, value) {
        if (!draft) return;
        draft.workers = clampWorkers(value);
        price(ui);
    }

    function pickModel(ui) {
        if (!draft) return;
        ensureModels(ui).then(() => {
            ui.openModels(null, {
                title: t('Worker model'),
                current: draft && draft.model ? draft.model.key : null,
                pick: (m) => {
                    if (!draft) return;
                    draft.model = { key: m.key, label: m.label || m.key };
                    reopen(ui);
                }
            });
        });
    }

    function save(ui) {
        if (!ui.conv || !draft) return;
        if (!draft.model) {
            ui.modalStatus('teamStatus', t('Pick a model for the workers first.'), 'warn');
            return;
        }
        const team = { workers: clampWorkers(draft.workers), model: { key: draft.model.key, label: draft.model.label } };
        ui.conv = ui.patchChat(ui.conv, { team }) || ui.conv;
        draft = null;
        ui.closeModals();
        ui.refreshToolbar();
        ui.toast(t('Team mode is on for this chat: {n} workers on {model}.', { n: team.workers, model: team.model.label }));
    }

    function off(ui) {
        if (!ui.conv) return;
        ui.conv = ui.patchChat(ui.conv, { team: null }) || ui.conv;
        draft = null;
        ui.closeModals();
        ui.refreshToolbar();
        ui.toast(t('Team mode is off for this chat.'));
    }

    function stageLabel(stage) {
        switch (stage) {
            case 'split': return t('Splitting the question');
            case 'plan': return t('Planning the work');
            case 'tool': return t('Working');
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
            case 'assigned': return t('Given its part');
            case 'start': return t('Starting');
            case 'search': return t('Searching');
            case 'read': return t('Reading');
            case 'note': return t('Taking notes');
            case 'rework': return t('Reworking its part');
            case 'stopped': return t('Stopped at its budget');
            case 'failed': return t('Failed');
            case 'rework-failed': return t('The rework failed');
            default: return '';
        }
    }

    function stageOf(step) {
        return String((step && step.stage) || '').toLowerCase().replace(/[^a-z-]/g, '').slice(0, 30);
    }

    function laneLine(step) {
        const text = typeof step.text === 'string' ? step.text.replace(/\s+/g, ' ').trim().slice(0, 200) : '';
        return text || stageLabel(stageOf(step));
    }

    function render(box, steps, team) {
        box.innerHTML = '';
        const lanes = new Map();
        let workers = team && Number(team.workers) > 0 ? clampWorkers(team.workers) : 0;
        for (const step of steps || []) {
            if (!step) continue;
            if (step.kind === 'routing' && Number(step.team) > 0) workers = clampWorkers(step.team);
            if (step.kind !== 'team') continue;
            const lane = Math.floor(Number(step.lane) || 0);
            if (lane < 0 || lane > MAX_WORKERS) continue;
            if (lane === 0 && Number(step.workers) > 0) workers = clampWorkers(step.workers);
            if (lane > workers) workers = lane;
            const line = laneLine(step);
            if (!line) continue;
            const list = lanes.get(lane) || [];
            if (list.length && list[list.length - 1].line === line) continue;
            list.push({ line, stage: stageOf(step) });
            lanes.set(lane, list);
        }
        const wrap = el('div', 'team-lanes');
        for (let lane = 0; lane <= workers; lane++) {
            const lines = lanes.get(lane) || [];
            const last = lines[lines.length - 1];
            const state = last && FINAL.has(last.stage) ? last.stage : '';
            const section = el('section', 'team-lane' + (lane === 0 ? ' is-lead' : '') + (state ? ' is-' + state : ''));
            section.dataset.lane = String(lane);
            section.appendChild(el('div', 'team-lane-head', lane === 0 ? t('Lead') : t('Worker {n}', { n: lane })));
            section.appendChild(window.NymbotResearch.stepList(lines,
                lane === 0 ? t('Starting the team') : t('Waiting for its part'), !!state));
            wrap.appendChild(section);
        }
        box.appendChild(wrap);
    }

    function normalize(raw) {
        if (!raw || typeof raw !== 'object' || !Array.isArray(raw.workers)) return null;
        const workers = raw.workers.slice(0, MAX_WORKERS).filter(w => w && typeof w === 'object').map((w, i) => ({
            lane: Math.max(1, Math.floor(Number(w.lane) || (i + 1))),
            model: String(w.model || raw.workerModel || '').slice(0, 200),
            credits: Math.max(0, Number(w.credits) || 0),
            steps: Math.max(0, Math.floor(Number(w.steps) || 0)),
            status: STATUSES.has(w.status) ? w.status : 'done'
        }));
        return {
            mode: raw.mode === 'repo' ? 'repo' : 'research',
            workerModel: String(raw.workerModel || '').slice(0, 200),
            overseerCredits: Math.max(0, Number(raw.overseerCredits) || 0),
            workers,
            sequential: !!raw.sequential
        };
    }

    function carry(res) {
        return normalize(res && res.team);
    }

    function statusLabel(status) {
        switch (status) {
            case 'stopped': return t('stopped');
            case 'failed': return t('failed');
            case 'pending': return t('not run yet');
            default: return t('done');
        }
    }

    function summaryNode(ui, m) {
        const team = normalize(m && m.team);
        if (!team) return null;
        const box = el('div', 'team-summary');
        box.appendChild(el('div', 'team-summary-head', t('Team')));
        const row = (who, model, spent, status) => {
            const line = el('div', 'team-summary-row' + (status ? ' is-' + status : ''));
            line.appendChild(el('span', 'team-summary-who', who));
            if (model) line.appendChild(el('span', 'team-summary-model', model));
            line.appendChild(el('span', 'team-summary-credits', t('{credits} Pro credits', { credits: credits(spent) })));
            if (status) line.appendChild(el('span', 'team-summary-status', statusLabel(status)));
            box.appendChild(line);
        };
        row(t('Lead'), m.model || '', team.overseerCredits, '');
        for (const w of team.workers) {
            row(t('Worker {n}', { n: w.lane }), labelOf(ui, w.model), w.credits, w.status);
        }
        if (team.sequential) {
            box.appendChild(el('div', 'team-summary-note', t('The provider was busy, so the workers ran one at a time.')));
        }
        return box;
    }

    function costRows(ui, m) {
        const team = normalize(m && m.team);
        if (!team) return [];
        const rows = [[t('Team lead'), t('{credits} Pro credits', { credits: credits(team.overseerCredits) })]];
        for (const w of team.workers) {
            rows.push([
                t('Worker {n} · {model}', { n: w.lane, model: labelOf(ui, w.model) }),
                t('{credits} Pro credits · {status}', { credits: credits(w.credits), status: statusLabel(w.status) })
            ]);
        }
        return rows;
    }

    function refusal(err) {
        if (!err || !err.team) return null;
        if (err.noCredits) {
            return t('Team mode can use up to {n} Pro credits and you have {have}. Nothing was run or charged. Top up, use fewer or cheaper workers, or send it without Team mode.', {
                n: num(Math.ceil(Number(err.required) || 0)),
                have: window.amount(Number(err.balance) || 0, 2)
            });
        }
        return t('Team mode did not start: {reason} Nothing was sent to a model and nothing was charged.', {
            reason: String(err.message || '').slice(0, 400)
        });
    }

    function helpTopic() {
        return {
            title: t('Team mode'),
            body: t('With a Pro model pinned, the Team chip appears when Research is on or a repository is connected. Tap it to pick how many workers run (2 to 4) and which model they run on, and it shows the most the turn can cost and what it usually costs. The model you pinned leads: it splits the task, the workers run at the same time, and the lead checks and combines their work. While it runs you see one lane for the lead and one for each worker, and the reply lists what each part cost. The lead can also use this chat\'s connectors and server runs; the workers cannot. Every connector call and server run the lead wants waits for you to allow it, even a tool you always allow elsewhere, and the team carries on from there.')
        };
    }

    function handlers(ui) {
        return {
            'open-team': () => open(ui),
            'team-save': () => save(ui),
            'team-off': () => off(ui),
            'team-pick-model': () => pickModel(ui)
        };
    }

    function bind() {
        const select = $('teamWorkers');
        const U = () => window.NymbotUI;
        if (select) select.addEventListener('change', () => { if (U()) setWorkers(U(), select.value); });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', bind);
    } else {
        bind();
    }

    window.NymbotTeam = {
        MIN_WORKERS,
        MAX_WORKERS,
        DEFAULT_WORKERS,
        settingOf,
        available,
        upcoming,
        claim,
        leadTools,
        defaultWorker,
        estimate,
        priceLine,
        refreshChip,
        open,
        save,
        off,
        render,
        carry,
        summaryNode,
        costRows,
        refusal,
        helpTopic,
        handlers,
        get draft() { return draft; }
    };
})();
