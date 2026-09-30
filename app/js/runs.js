(function () {
    'use strict';

    const POLL_MS = 5000;
    const HEX = /^[0-9a-f]{64}$/;
    const STEER_MAX = 2000;
    const KINDS = new Set(['chat', 'research', 'team', 'repo', 'connector', 'server-run', 'media', 'compare']);
    const STATES = new Set(['running', 'parked', 'waiting']);

    const $ = (id) => document.getElementById(id);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };
    const Api = () => window.NymbotApi;
    const Store = () => window.NymbotStore;
    const Chat = () => window.NymbotChat;

    let remote = [];
    let timer = null;
    let polling = null;
    const followers = new Set();

    function clip(v, max) {
        return String(v == null ? '' : v).replace(/[\x00-\x1f\x7f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max);
    }

    function clean(raw) {
        if (!raw || typeof raw !== 'object' || !HEX.test(String(raw.replyTo || ''))) return null;
        const plan = Chat() && Chat().planOf ? Chat().planOf(raw.plan) : null;
        return {
            replyTo: String(raw.replyTo),
            thread: typeof raw.thread === 'string' ? raw.thread : '',
            kind: KINDS.has(raw.kind) ? raw.kind : 'chat',
            label: clip(raw.label, 120),
            progress: clip(raw.progress, 200),
            plan: plan && plan.length ? plan : null,
            branches: window.NymbotGitRun ? window.NymbotGitRun.branchSteps(raw.branches) : [],
            state: STATES.has(raw.state) ? raw.state : 'running',
            background: raw.background === true,
            startedAt: Number(raw.startedAt) || 0,
            updatedAt: Number(raw.updatedAt) || 0
        };
    }

    function signerFor(conv) {
        const Anon = window.NymbotAnon;
        if (!conv || !conv.anon || !Anon) return null;
        const payer = Anon.forConv(conv);
        return payer ? Anon.signer(payer) : null;
    }

    function convForThread(thread) {
        const list = Store().conversations();
        if (thread) return list.find(c => c.rootId === thread) || null;
        return null;
    }

    function localRunIds(ui) {
        const ids = new Set();
        for (const turn of ui.turns.values()) if (turn.runId) ids.add(turn.runId);
        return ids;
    }

    function others(ui) {
        const mine = localRunIds(ui);
        return remote.filter(r => !mine.has(r.replyTo));
    }

    function entries(ui) {
        const out = [];
        for (const turn of ui.turns.values()) {
            if (turn.quiet) continue;
            const conv = Store().conversation(turn.convId);
            const q = Store().messages(turn.convId).find(m => m.id === turn.asked);
            out.push({
                key: 'local:' + turn.id,
                run: turn.id,
                convId: turn.convId,
                chat: conv ? (conv.title || t('New chat')) : t('Unknown chat'),
                label: q ? clip(q.content, 120) : ui.cardLabel(turn),
                progress: ui.cardLabel(turn),
                plan: turn.plan || null,
                branches: turn.branches || [],
                startedAt: turn.startedAt,
                steer: !!(turn.runId && turn.sent && !turn.slot && !turn.waiting)
            });
        }
        for (const r of others(ui)) {
            const conv = convForThread(r.thread);
            out.push({
                key: 'remote:' + r.replyTo,
                run: 'remote:' + r.replyTo,
                convId: conv ? conv.id : null,
                chat: conv ? (conv.title || t('New chat')) : t('Unknown chat'),
                label: r.label,
                progress: r.progress,
                plan: r.plan,
                branches: r.branches || [],
                startedAt: r.startedAt,
                steer: true,
                remote: true,
                background: !!r.background
            });
        }
        return out.sort((a, b) => (b.startedAt || 0) - (a.startedAt || 0));
    }

    async function poll(ui) {
        const Identity = window.NymbotIdentity;
        if (!Identity || !Identity.pubkey) return remote;
        if (polling) return polling;
        polling = (async () => {
            let mine = null;
            try {
                const res = await Api().liveRuns(null, {});
                if (res.status === 200 && res.data && Array.isArray(res.data.runs)) {
                    mine = res.data.runs.map(clean).filter(Boolean).slice(0, 20);
                    for (const r of mine) {
                        for (const b of r.branches) {
                            try { Chat().rememberBranchStep(b, null, null); } catch (_) { }
                        }
                    }
                } else if (res.status && res.status !== 429) {
                    mine = [];
                }
            } catch (_) { }
            const open = ui.conv && ui.conv.anon && HEX.test(String(ui.conv.rootId || '')) ? ui.conv : null;
            const signer = open ? signerFor(open) : null;
            let theirs = null;
            if (signer) {
                try {
                    await Api().jitter();
                    const res = await Api().liveRuns(open.rootId, { signer });
                    if (res.status === 200 && res.data && Array.isArray(res.data.runs)) {
                        theirs = res.data.runs.map(clean).filter(r => r && r.thread === open.rootId).slice(0, 20);
                        for (const r of theirs) {
                            for (const b of r.branches) {
                                try { Chat().rememberBranchStep(b, open); } catch (_) { }
                            }
                        }
                    }
                } catch (_) { }
            }
            const kept = remote.filter(r => r.anon);
            const nym = mine != null ? mine : remote.filter(r => !r.anon);
            const anon = theirs != null ? theirs.map(r => Object.assign(r, { anon: true }))
                : kept.filter(r => signer && r.thread === open.rootId);
            remote = nym.concat(anon);
            render(ui);
            return remote;
        })();
        try { return await polling; } finally { polling = null; }
    }

    function render(ui) {
        renderCount(ui);
        if (window.NymbotTasks) window.NymbotTasks.refresh(ui);
        const sheet = $('modalRunning');
        if (sheet && !sheet.hidden) renderSheet(ui);
    }

    function renderCount(ui) {
        const node = $('runningCount');
        if (!node) return;
        const n = entries(ui).length;
        node.textContent = n ? String(n) : '';
    }

    function visible(name) {
        if (name === 'tasks') return !!(window.NymbotTasks && window.NymbotTasks.isOpen);
        if (name === 'sheet') { const s = $('modalRunning'); return !!(s && !s.hidden); }
        return false;
    }

    function follow(ui, name, on) {
        if (on) followers.add(name); else followers.delete(name);
        if (on) poll(ui).catch(() => { });
        if (timer || !followers.size) return;
        const tick = () => {
            for (const f of [...followers]) if (!visible(f)) followers.delete(f);
            if (!followers.size) { timer = null; return; }
            poll(ui).catch(() => { }).then(() => { timer = setTimeout(tick, POLL_MS); });
        };
        timer = setTimeout(tick, POLL_MS);
    }

    function forConv(ui, conv) {
        if (!conv || !conv.rootId) return [];
        return others(ui).filter(r => r.thread === conv.rootId);
    }

    function age(ts) {
        if (!ts) return '';
        const mins = Math.max(0, Math.round((Date.now() - ts) / 60000));
        return mins < 1 ? t('Started just now') : t('Started {n} min ago', { n: mins });
    }

    function renderSheet(ui) {
        const box = $('runningList');
        if (!box) return;
        box.innerHTML = '';
        const list = entries(ui);
        if (!list.length) {
            box.appendChild(el('p', 'hint', t('Nothing is running right now.')));
            return;
        }
        for (const e of list) {
            const row = el('div', 'running-row');
            const main = el('div', 'running-main');
            main.appendChild(el('span', 'running-chat', e.chat));
            const label = el('span', 'running-label', e.label);
            label.dir = 'auto';
            main.appendChild(label);
            const bits = [e.progress, ...(e.branches || []).map(b => t('Working on branch {branch}', { branch: b.branch })),
                e.background ? t('In the background') : '', e.remote && !e.background ? t('On another device') : '', age(e.startedAt)].filter(Boolean);
            main.appendChild(el('span', 'running-meta', bits.join(' · ')));
            if (e.plan && e.plan.length) {
                const plan = el('ol', 'run-plan');
                ui.fillPlan(plan, e.plan);
                main.appendChild(plan);
            }
            row.appendChild(main);
            const actions = el('div', 'running-actions');
            const add = (text, act, data) => {
                const b = el('button', 'btn btn-small btn-ghost', text);
                b.type = 'button';
                b.dataset.act = act;
                Object.assign(b.dataset, data);
                actions.appendChild(b);
            };
            if (e.convId) add(t('Open'), 'running-open', { key: e.key });
            if (e.steer) add(t('Add instructions'), 'run-steer', { run: e.run });
            add(t('Stop'), 'run-stop', { run: e.run });
            row.appendChild(actions);
            box.appendChild(row);
        }
    }

    function open(ui) {
        renderSheet(ui);
        ui.openModal('modalRunning');
        follow(ui, 'sheet', true);
    }

    function openRun(ui, key) {
        const e = entries(ui).find(x => x.key === key);
        if (!e || !e.convId) return;
        const conv = Store().conversation(e.convId);
        if (!conv) return;
        ui.closeModals();
        ui.open(conv);
        if (e.remote) {
            ui.showAsked(conv.id, e.run.slice(7));
            return;
        }
        const turn = ui.turnById(e.run);
        const m = turn && Store().messages(conv.id).find(x => x.id === turn.asked);
        if (m && m.wire) ui.showAsked(conv.id, m.wire);
    }

    async function cancel(ui, conv, runId, signer) {
        if (!HEX.test(String(runId || ''))) return null;
        const res = await Api().cancelRun(runId, { signer: signer || signerFor(conv) });
        return res && res.status === 200 ? res.data : null;
    }

    async function stopRemote(ui, runId) {
        const r = remote.find(x => x.replyTo === runId);
        const conv = r ? convForThread(r.thread) : null;
        remote = remote.filter(x => x.replyTo !== runId);
        render(ui);
        await cancel(ui, conv, runId, null).catch(() => null);
        ui.toast(t('Stopped.'));
    }

    async function askSteer(ui) {
        const text = await ui.ask({
            title: t('Add instructions'),
            body: t('Nymbot passes this to the running request at its next step. It does not change what the request can spend.'),
            area: true,
            placeholder: t('For example: also cover the pricing'),
            confirm: t('Send to this request')
        });
        return text == null ? null : String(text).trim();
    }

    async function deliver(ui, conv, runId, signer, text) {
        if (!text) return;
        if (text.length > STEER_MAX) {
            ui.toast(t('That is too long. Instructions can be up to 2,000 characters.'));
            return;
        }
        let res;
        try {
            res = await Api().steerRun(runId, text, { signer: signer || signerFor(conv) });
        } catch (_) {
            res = { status: 0, data: {} };
        }
        if (res.status === 200 && res.data && res.data.ok) {
            ui.toast(t('Passed on. It applies at the next step.'));
            return;
        }
        if (res.status === 413) {
            ui.toast(t('That is too long. Instructions can be up to 2,000 characters.'));
            return;
        }
        if (res.status === 429 || res.status === 0 || res.status >= 500) {
            ui.toast(t('Could not pass that on. Try again in a moment.'));
            return;
        }
        const go = await ui.ask({
            title: t('That request has finished'),
            body: t('Send your instructions as a new message instead?'),
            confirm: t('Send as a message')
        });
        if (!go) return;
        const target = conv ? (Store().conversation(conv.id) || conv) : ui.conv;
        if (!target) return;
        if (!ui.conv || ui.conv.id !== target.id) ui.open(target);
        await ui.send(text, target, { attachments: [] });
    }

    async function steer(ui, turn) {
        if (!turn || !turn.runId) return;
        const text = await askSteer(ui);
        if (!text) return;
        const conv = Store().conversation(turn.convId);
        await deliver(ui, conv, turn.runId, turn.signer, text);
    }

    async function steerRemote(ui, runId) {
        const r = remote.find(x => x.replyTo === runId);
        const conv = r ? convForThread(r.thread) : null;
        const text = await askSteer(ui);
        if (!text) return;
        await deliver(ui, conv, runId, null, text);
    }

    window.NymbotRuns = {
        poll,
        follow,
        forConv,
        entries,
        renderCount,
        render,
        open,
        openRun,
        cancel,
        stopRemote,
        steer,
        steerRemote,
        get remote() { return remote.slice(); }
    };
})();
