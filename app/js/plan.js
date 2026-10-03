(function () {
    'use strict';

    const LIMITS = { summary: 600, items: 20, item: 120, changes: 12, target: 120, what: 300, note: 2000, waitMs: 86400000 };
    const ID_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
    const BLOCK_RE = /<propose_plan>([\s\S]*?)<\/propose_plan>/g;
    const STATES = new Set(['waiting', 'sending', 'approved', 'edited', 'rejected', 'revised', 'expired']);
    const DECISIONS = new Set(['approve', 'reject', 'revise']);

    function clean(v, max) {
        let s = typeof v === 'string' ? v : '';
        s = s.replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, ' ').replace(/\s+/g, ' ').replace(/^ +| +$/g, '');
        if (max && s.length > max) s = s.slice(0, max - 1).replace(/ +$/, '') + '…';
        return s;
    }

    function note(v) {
        let s = typeof v === 'string' ? v : '';
        s = s.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f\u2028\u2029]/g, ' ').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').replace(/^\s+|\s+$/g, '');
        if (s.length > LIMITS.note) s = s.slice(0, LIMITS.note - 1).replace(/\s+$/, '') + '…';
        return s;
    }

    function items(raw) {
        if (!Array.isArray(raw) || raw.length < 1 || raw.length > LIMITS.items) return null;
        const out = [];
        for (const it of raw) {
            const text = clean(it && typeof it === 'object' && !Array.isArray(it) ? it.text : it, LIMITS.item);
            if (!text) return null;
            out.push(text);
        }
        return out;
    }

    function parse(raw) {
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'plan' };
        const summary = clean(raw.summary, LIMITS.summary);
        if (!summary) return { error: 'summary' };
        const steps = items(raw.items);
        if (!steps) return { error: 'items' };
        const list = raw.changes == null ? [] : raw.changes;
        if (!Array.isArray(list) || list.length > LIMITS.changes) return { error: 'changes' };
        const changes = [];
        for (const c of list) {
            if (!c || typeof c !== 'object' || Array.isArray(c)) return { error: 'changes' };
            const target = clean(c.target, LIMITS.target);
            const what = clean(c.what, LIMITS.what);
            if (!target || !what) return { error: 'changes' };
            changes.push({ target, what });
        }
        return { summary, items: steps, changes };
    }

    function decide(pending, raw) {
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'decision' };
        const decision = typeof raw.decision === 'string' && DECISIONS.has(raw.decision) ? raw.decision : '';
        if (!decision) return { error: 'decision' };
        const edits = raw.edits == null ? {} : raw.edits;
        if (!edits || typeof edits !== 'object' || Array.isArray(edits)) return { error: 'edits' };
        if (edits.note != null && typeof edits.note !== 'string') return { error: 'edits' };
        const said = note(edits.note);
        if (decision === 'approve') {
            let steps = pending.items;
            let edited = false;
            if (edits.items != null) {
                steps = items(edits.items);
                if (!steps) return { error: 'edits' };
                edited = JSON.stringify(steps) !== JSON.stringify(pending.items);
            }
            return { decision: 'approve', items: steps, note: said, edited };
        }
        if (edits.items != null) return { error: 'edits' };
        return { decision, note: said };
    }

    function take(text) {
        const src = typeof text === 'string' ? text : '';
        let last = null;
        let m;
        BLOCK_RE.lastIndex = 0;
        while ((m = BLOCK_RE.exec(src))) last = m[1];
        let rest = src.replace(BLOCK_RE, '');
        const open = rest.search(/<propose_plan\b/);
        if (open !== -1) rest = rest.slice(0, open);
        rest = rest.replace(/\n{3,}/g, '\n\n').replace(/^\s+|\s+$/g, '');
        let plan = null;
        if (last != null) {
            let obj = null;
            try { obj = JSON.parse(last); } catch (_) { obj = null; }
            const parsed = obj && typeof obj === 'object' ? parse(obj) : { error: 'json' };
            if (!parsed.error && typeof obj.id === 'string' && ID_RE.test(obj.id)) {
                plan = { id: obj.id, summary: parsed.summary, items: parsed.items, changes: parsed.changes };
            }
        }
        return { text: rest, plan };
    }

    function cut(text) {
        const s = String(text || '');
        const at = s.search(/<propose_plan\b/i);
        return at === -1 ? s : s.slice(0, at).replace(/\s+$/, '');
    }

    function record(took, data, now) {
        if (!took || !took.plan || !took.plan.id) return null;
        const d = data || {};
        const p = d.pendingTool && d.pendingTool.kind === 'plan' && d.pendingTool.id === took.plan.id ? d.pendingTool : null;
        const at = now || Date.now();
        const exp = p && Number(p.expiresAt) > 0 ? Math.min(Number(p.expiresAt), at + LIMITS.waitMs) : at + LIMITS.waitMs;
        const bg = d.background && d.background.waiting === true && /^[0-9a-f]{64}$/.test(String(d.background.runId || '')) ? String(d.background.runId) : null;
        const token = !bg && typeof d.resumeToken === 'string' && /^[0-9a-f]{32,64}$/i.test(d.resumeToken) ? d.resumeToken : null;
        return {
            id: took.plan.id,
            summary: took.plan.summary,
            items: took.plan.items,
            changes: took.plan.changes,
            plain: !bg && !token,
            token,
            runId: bg,
            expiresAt: exp,
            state: 'waiting'
        };
    }

    function stateOf(p, now) {
        if (!p || typeof p !== 'object') return null;
        const s = STATES.has(p.state) ? p.state : 'waiting';
        if ((s === 'waiting' || s === 'sending') && Number(p.expiresAt) > 0 && (now || Date.now()) >= Number(p.expiresAt)) return 'expired';
        if (s === 'waiting' && p.plain) return 'expired';
        return s;
    }

    function stageOf(p) {
        switch (stateOf(p)) {
            case 'approved': return 'approved';
            case 'edited': return 'edited';
            case 'rejected': return 'rejected';
            case 'expired': return 'expired';
            case 'revised': return null;
            default: return 'proposed';
        }
    }

    function pending(m, now) {
        return !!(m && m.proposal && stateOf(m.proposal, now) === 'waiting');
    }

    function grouped(changes) {
        const out = [];
        for (const c of Array.isArray(changes) ? changes : []) {
            const g = out.find(x => x.target === c.target);
            if (g) g.what.push(c.what);
            else out.push({ target: c.target, what: [c.what] });
        }
        return out;
    }

    function hoursLeft(p, now) {
        return Math.max(0, Math.ceil((Number(p.expiresAt) - (now || Date.now())) / 3600000));
    }

    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };

    const button = (label, cls, role, fn) => {
        const b = el('button', 'btn btn-small ' + cls, label);
        b.type = 'button';
        b.dataset.role = role;
        b.addEventListener('click', fn);
        return b;
    };

    const Store = () => window.NymbotStore;

    const drafts = new Map();

    const Plan = {
        drafts,
        LIMITS, clean, note, items, parse, decide, take, cut, record, stateOf, stageOf, pending, grouped,

        patch(ui, convId, m, patch) {
            const next = Object.assign({}, m.proposal, patch);
            Store().patchMessage(convId, m.id, { proposal: next });
            const fresh = Store().messages(convId).find(x => x.id === m.id);
            if (fresh && ui.conv && ui.conv.id === convId) ui.replaceMessage(fresh);
            if (window.NymbotTasks) window.NymbotTasks.refresh(ui);
            return fresh || Object.assign({}, m, { proposal: next });
        },

        statusText(p, state) {
            switch (state) {
                case 'approved': return t('Approved. Nymbot carried on with this plan.');
                case 'edited': return t('Approved with your edits. Nymbot carried on with them.');
                case 'rejected': return t('Rejected. Nothing was changed.');
                case 'revised': return t('Sent back for a revised plan.');
                case 'expired': return p.plain
                    ? t('This plan can no longer be approved. Ask again to start it fresh.')
                    : t('The plan was not approved within 24 hours, so this task stopped. Ask again to start it fresh.');
                case 'sending': return t('Sending your decision…');
                default: return p.error || '';
            }
        },

        card(ui, m) {
            const card = el('section', 'plan-card');
            card.dataset.id = m.id;
            card.setAttribute('aria-label', t('Nymbot\'s plan'));
            this.draw(ui, m, card);
            return card;
        },

        draw(ui, m, card) {
            const p = m.proposal;
            const state = stateOf(p);
            const live = state === 'waiting' || state === 'sending';
            const mode = live ? (drafts.get(m.id) || {}).mode || '' : '';
            card.className = 'plan-card is-' + state + (live ? '' : ' is-settled');
            card.textContent = '';
            const head = el('div', 'plan-head');
            head.appendChild(el('span', 'plan-title', t('Nymbot\'s plan')));
            if (state === 'waiting') {
                const h = hoursLeft(p);
                head.appendChild(el('span', 'plan-expiry', h <= 1 ? t('Waiting for your approval · expires within the hour') : t('Waiting for your approval · expires in {n} hours', { n: h })));
            }
            card.appendChild(head);
            card.appendChild(el('p', 'plan-summary', p.summary));
            if (mode === 'edit') {
                card.appendChild(this.editor(ui, m, card));
            } else {
                const shown = Array.isArray(p.approvedItems) ? p.approvedItems : p.items;
                const list = el('ol', 'plan-items');
                for (const it of shown) list.appendChild(el('li', 'plan-item', it));
                card.appendChild(list);
            }
            const groups = grouped(p.changes);
            if (groups.length && mode !== 'edit') {
                const box = el('div', 'plan-changes');
                box.appendChild(el('h4', 'plan-changes-title', t('What changes where')));
                const ul = el('ul', 'plan-targets');
                for (const g of groups) {
                    const li = el('li', 'plan-target');
                    li.appendChild(el('span', 'plan-target-name', g.target));
                    const inner = el('ul', 'plan-target-what');
                    for (const w of g.what) inner.appendChild(el('li', '', w));
                    li.appendChild(inner);
                    ul.appendChild(li);
                }
                box.appendChild(ul);
                card.appendChild(box);
            }
            if (p.note && !live) card.appendChild(el('p', 'plan-note', (state === 'rejected' ? t('Your reason: {text}', { text: p.note }) : t('Your note: {text}', { text: p.note }))));
            const status = el('p', 'plan-status');
            status.setAttribute('role', 'status');
            status.setAttribute('aria-live', 'polite');
            status.textContent = this.statusText(p, state);
            card.appendChild(status);
            if (!live) return;
            const busy = state === 'sending';
            if (mode === 'reject') {
                const d = drafts.get(m.id);
                const label = el('label', 'plan-label', t('Why? (optional)'));
                const reason = document.createElement('textarea');
                reason.className = 'plan-reason';
                reason.rows = 2;
                reason.maxLength = LIMITS.note;
                reason.value = d.note || '';
                reason.placeholder = t('Tell Nymbot what to change');
                reason.setAttribute('data-i18n-skip', '');
                reason.id = 'plan-reason-' + m.id;
                label.htmlFor = reason.id;
                reason.addEventListener('input', () => { d.note = reason.value; });
                card.appendChild(label);
                card.appendChild(reason);
                const row = el('div', 'plan-actions');
                const go = button(t('Reject the plan'), 'btn-danger', 'plan-reject-send', () => this.submit(ui, m, { decision: 'reject', edits: { note: reason.value } }));
                go.disabled = busy;
                row.appendChild(go);
                row.appendChild(button(t('Cancel'), 'btn-ghost', 'plan-cancel', () => { drafts.delete(m.id); this.draw(ui, m, card); }));
                card.appendChild(row);
                return;
            }
            if (mode === 'revise') {
                const d = drafts.get(m.id);
                const label = el('label', 'plan-label', t('What should change in the plan?'));
                const text = document.createElement('textarea');
                text.className = 'plan-revise-text';
                text.rows = 2;
                text.maxLength = LIMITS.note;
                text.value = d.note || '';
                text.setAttribute('data-i18n-skip', '');
                text.id = 'plan-revise-' + m.id;
                label.htmlFor = text.id;
                text.addEventListener('input', () => { d.note = text.value; });
                card.appendChild(label);
                card.appendChild(text);
                const row = el('div', 'plan-actions');
                const go = button(t('Revise plan'), 'btn-primary', 'plan-revise-send', () => this.revise(ui, m, text.value));
                go.disabled = busy;
                row.appendChild(go);
                row.appendChild(button(t('Cancel'), 'btn-ghost', 'plan-cancel', () => { drafts.delete(m.id); this.draw(ui, m, card); }));
                card.appendChild(row);
                return;
            }
            if (mode === 'edit') return;
            const row = el('div', 'plan-actions');
            const approve = button(t('Approve'), 'btn-primary', 'plan-approve', () => this.submit(ui, m, { decision: 'approve' }));
            const edit = button(t('Edit'), 'btn-ghost', 'plan-edit', () => {
                drafts.set(m.id, { mode: 'edit', items: (Array.isArray(p.items) ? p.items : []).slice(), note: '' });
                this.draw(ui, m, card);
                const first = card.querySelector('.plan-edit-input');
                if (first) first.focus();
            });
            const reject = button(t('Reject'), 'btn-ghost', 'plan-reject', () => {
                drafts.set(m.id, { mode: 'reject', note: '' });
                this.draw(ui, m, card);
                const field = card.querySelector('.plan-reason');
                if (field) field.focus();
            });
            const revise = button(t('Revise plan'), 'btn-ghost', 'plan-revise', () => {
                drafts.set(m.id, { mode: 'revise', note: '' });
                this.draw(ui, m, card);
                const field = card.querySelector('.plan-revise-text');
                if (field) field.focus();
            });
            for (const b of [approve, edit, reject, revise]) {
                b.disabled = busy;
                row.appendChild(b);
            }
            card.appendChild(row);
        },

        editor(ui, m, card) {
            const d = drafts.get(m.id);
            const box = el('div', 'plan-editor');
            const list = el('ol', 'plan-edit-list');
            const redraw = () => this.draw(ui, m, card);
            d.items.forEach((text, i) => {
                const li = el('li', 'plan-edit-row');
                const input = document.createElement('input');
                input.type = 'text';
                input.className = 'plan-edit-input';
                input.maxLength = LIMITS.item;
                input.value = text;
                input.setAttribute('aria-label', t('Step {n}', { n: i + 1 }));
                input.setAttribute('data-i18n-skip', '');
                input.addEventListener('input', () => { d.items[i] = input.value; });
                li.appendChild(input);
                const up = button('↑', 'btn-ghost plan-move', 'plan-up', () => {
                    if (i === 0) return;
                    [d.items[i - 1], d.items[i]] = [d.items[i], d.items[i - 1]];
                    redraw();
                });
                up.setAttribute('aria-label', t('Move step {n} up', { n: i + 1 }));
                up.disabled = i === 0;
                const down = button('↓', 'btn-ghost plan-move', 'plan-down', () => {
                    if (i >= d.items.length - 1) return;
                    [d.items[i + 1], d.items[i]] = [d.items[i], d.items[i + 1]];
                    redraw();
                });
                down.setAttribute('aria-label', t('Move step {n} down', { n: i + 1 }));
                down.disabled = i >= d.items.length - 1;
                const remove = button('×', 'btn-ghost plan-remove', 'plan-remove', () => {
                    d.items.splice(i, 1);
                    redraw();
                });
                remove.setAttribute('aria-label', t('Remove step {n}', { n: i + 1 }));
                remove.disabled = d.items.length <= 1;
                li.appendChild(up);
                li.appendChild(down);
                li.appendChild(remove);
                list.appendChild(li);
            });
            box.appendChild(list);
            const add = button(t('Add a step'), 'btn-ghost', 'plan-add', () => {
                if (d.items.length >= LIMITS.items) return;
                d.items.push('');
                redraw();
                const all = card.querySelectorAll('.plan-edit-input');
                if (all.length) all[all.length - 1].focus();
            });
            add.disabled = d.items.length >= LIMITS.items;
            box.appendChild(add);
            const label = el('label', 'plan-label', t('Note for Nymbot (optional)'));
            const field = document.createElement('textarea');
            field.className = 'plan-note-input';
            field.rows = 2;
            field.maxLength = LIMITS.note;
            field.value = d.note || '';
            field.id = 'plan-note-' + m.id;
            field.setAttribute('data-i18n-skip', '');
            label.htmlFor = field.id;
            field.addEventListener('input', () => { d.note = field.value; });
            box.appendChild(label);
            box.appendChild(field);
            if (d.error) box.appendChild(el('p', 'plan-edit-error', d.error));
            const row = el('div', 'plan-actions');
            const save = button(t('Approve with edits'), 'btn-primary', 'plan-approve-edits', () => {
                const steps = d.items.map(x => String(x || '').trim()).filter(Boolean);
                if (!steps.length) {
                    d.error = t('Keep at least one step.');
                    redraw();
                    return;
                }
                this.submit(ui, m, { decision: 'approve', edits: { items: steps, note: d.note || '' } });
            });
            save.disabled = stateOf(m.proposal) === 'sending';
            row.appendChild(save);
            row.appendChild(button(t('Cancel'), 'btn-ghost', 'plan-cancel', () => { drafts.delete(m.id); redraw(); }));
            box.appendChild(row);
            return box;
        },

        textFor(got) {
            if (got.decision === 'reject') return got.note ? t('Rejected the plan: {reason}', { reason: got.note }) : t('Rejected the plan.');
            if (got.decision === 'revise') return got.note ? t('Revise the plan: {text}', { text: got.note }) : t('Revise the plan.');
            if (got.edited) return t('Approved the plan with edits:') + '\n' + got.items.map((x, i) => (i + 1) + '. ' + x).join('\n') + (got.note ? '\n\n' + got.note : '');
            return got.note ? t('Approved the plan. {note}', { note: got.note }) : t('Approved the plan.');
        },

        keptFor(got) {
            if (got.decision === 'reject') return { state: 'rejected', note: got.note, error: '' };
            if (got.decision === 'revise') return { state: 'revised', note: got.note, error: '' };
            return { state: got.edited ? 'edited' : 'approved', approvedItems: got.items, note: got.note, error: '' };
        },

        async approveById(ui, messageId) {
            const conv = ui.conv;
            if (!conv) return;
            const m = Store().messages(conv.id).find(x => x.id === messageId);
            if (m && m.proposal) await this.submit(ui, m, { decision: 'approve' });
        },

        async submit(ui, m, raw) {
            const conv = ui.conv;
            if (!conv) return;
            const fresh = Store().messages(conv.id).find(x => x.id === m.id) || m;
            const p = fresh.proposal;
            if (!p || stateOf(p) === 'sending') return;
            if (stateOf(p) === 'expired') {
                drafts.delete(m.id);
                this.patch(ui, conv.id, fresh, { state: 'expired' });
                return;
            }
            if (stateOf(p) !== 'waiting') return;
            const got = decide(p, raw);
            if (got.error) {
                this.patch(ui, conv.id, fresh, { error: t('That decision does not fit the plan.') });
                return;
            }
            const capStop = ui.capStopsLeg(conv);
            if (capStop && !p.runId) {
                this.patch(ui, conv.id, fresh, { error: capStop });
                return;
            }
            drafts.delete(m.id);
            const body = { id: p.id, decision: got.decision };
            if (got.decision === 'approve' && got.edited) body.edits = { items: got.items, note: got.note };
            else if (got.note) body.edits = { note: got.note };
            const sending = this.patch(ui, conv.id, fresh, { state: 'sending', error: '' });
            if (p.runId) return this.answerServer(ui, conv, sending, body, this.keptFor(got));
            return this.answerHere(ui, conv, sending, body, this.keptFor(got), this.textFor(got));
        },

        async revise(ui, m, text) {
            const conv = ui.conv;
            if (!conv) return;
            const fresh = Store().messages(conv.id).find(x => x.id === m.id) || m;
            const p = fresh.proposal;
            const said = note(text);
            if (!p || stateOf(p) !== 'waiting') return;
            if (!said) {
                this.patch(ui, conv.id, fresh, { error: t('Say what should change.') });
                return;
            }
            const run = p.runId || fresh.replyTo;
            let steered = false;
            if (/^[0-9a-f]{64}$/.test(String(run || ''))) {
                try {
                    const res = await window.NymbotApi.steerRun(run, said, {});
                    steered = !!(res && res.status === 200 && res.data && res.data.ok);
                } catch (_) {
                    steered = false;
                }
                if (steered && window.NymbotTranscripts) window.NymbotTranscripts.steered(run, said, conv.id);
            }
            await this.submit(ui, fresh, steered ? { decision: 'revise' } : { decision: 'revise', edits: { note: said } });
        },

        async answerServer(ui, conv, m, body, kept) {
            const Api = window.NymbotApi;
            const payload = { runId: m.proposal.runId, pendingId: body.id, decision: body.decision };
            if (body.edits) payload.edits = body.edits;
            let res;
            try {
                res = await Api.call('pm-answer', payload, { timeout: 20000 });
            } catch (_) {
                res = { status: 0, data: {} };
            }
            const data = (res && res.data) || {};
            if (res && res.status === 200 && data.ok) {
                const done = this.patch(ui, conv.id, m, kept);
                if (window.NymbotBackground) window.NymbotBackground.answered(ui, conv, done, data);
                return;
            }
            if (res && (res.status === 410 || data.expired || (res.status === 409 && data.gone))) {
                this.patch(ui, conv.id, m, { state: 'expired' });
                return;
            }
            this.patch(ui, conv.id, m, { state: 'waiting', error: data.error || t('Could not send your decision. Try again.') });
        },

        async answerHere(ui, conv, m, body, kept, text) {
            const Chat = window.NymbotChat;
            const Caps = window.NymbotCaps;
            const p = m.proposal;
            const turn = ui.beginTurn(conv, t('Carrying on with your decision'), { asked: m.askedBy || null, runId: m.replyTo || null, resumed: true });
            turn.answering = m.id;
            const staged = Object.assign({}, m, { proposal: Object.assign({}, p, kept) });
            const stage = stageOf(staged.proposal);
            if (stage && window.NymbotTranscripts) window.NymbotTranscripts.planned(ui, turn, stage, staged);
            try {
                const opts = {
                    maxCost: Caps ? Caps.maxCost(conv, true, ui.models) : null,
                    controller: turn.controller,
                    onStatus: (s) => ui.turnStatus(turn, s),
                    onSlot: (waiting) => ui.turnState(turn, { slot: waiting }),
                    onClaiming: (on) => ui.turnState(turn, { claiming: on }),
                    onTurn: (eventId, signer, info) => {
                        ui.bindRun(turn, conv.id, null, eventId, signer, info);
                        ui.watchTurn(turn, eventId, signer);
                    },
                    resume: p.token,
                    pendingAnswer: body
                };
                const B = window.NymbotBackground;
                const grant = B ? await B.grantWithPush(ui, conv, turn, {}) : null;
                if (grant) opts.background = grant;
                const res = await Chat.send(conv, text, ui.settings, opts);
                ui.stopWatchingTurn(turn);
                this.patch(ui, conv.id, m, kept);
                if (turn.stopped) return;
                if (res.stopped) {
                    ui.runNote(turn, t('Stopped.'));
                    return;
                }
                await ui.acceptReply(turn, Store().conversation(conv.id) || conv, res);
            } catch (e) {
                ui.stopWatchingTurn(turn);
                if (e && e.resumeExpired) {
                    this.patch(ui, conv.id, m, { state: 'expired' });
                } else {
                    this.patch(ui, conv.id, m, { state: 'waiting', error: (e && e.message) || t('Could not send your decision. Try again.') });
                }
            } finally {
                ui.endTurn(turn);
            }
        },

        taskItem(m) {
            const p = m && m.proposal;
            if (!p || !Array.isArray(p.items) || !p.summary) return null;
            const state = stateOf(p);
            const shown = Array.isArray(p.approvedItems) ? p.approvedItems : p.items;
            const label = state === 'waiting' || state === 'sending' ? t('Plan waiting for your approval: {summary}', { summary: p.summary })
                : state === 'rejected' ? t('Plan rejected: {summary}', { summary: p.summary })
                    : state === 'expired' ? t('Plan expired: {summary}', { summary: p.summary })
                        : state === 'revised' ? t('Plan sent back for revision: {summary}', { summary: p.summary })
                            : t('Plan approved: {summary}', { summary: p.summary });
            const targets = grouped(p.changes).map(g => g.target);
            return {
                label,
                state: state === 'waiting' || state === 'sending' ? 'waiting' : (state === 'expired' ? 'stopped' : (state === 'rejected' || state === 'revised' ? 'skipped' : 'done')),
                detail: targets.length ? t('Changes: {targets}', { targets: targets.slice(0, 4).join(', ') }) : '',
                children: shown.slice(0, 6)
            };
        }
    };

    window.NymbotPlan = Plan;
})();
