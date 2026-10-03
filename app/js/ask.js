(function () {
    'use strict';

    const LIMITS = { questions: 4, optionsMin: 2, optionsMax: 4, question: 300, header: 30, label: 60, description: 160, other: 500, waitMs: 86400000 };
    const ID_RE = /^[A-Za-z0-9_.:-]{1,128}$/;
    const BLOCK_RE = /<ask_user>([\s\S]*?)<\/ask_user>/g;
    const STATES = new Set(['waiting', 'sending', 'answered', 'skipped', 'expired']);

    function clean(v, max) {
        let s = typeof v === 'string' ? v : '';
        s = s.replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, ' ').replace(/\s+/g, ' ').replace(/^ +| +$/g, '');
        if (max && s.length > max) s = s.slice(0, max - 1).replace(/ +$/, '') + '…';
        return s;
    }

    function parse(raw) {
        const list = raw && typeof raw === 'object' && Array.isArray(raw.questions) ? raw.questions : null;
        if (!list || list.length < 1 || list.length > LIMITS.questions) return { error: 'questions' };
        const out = [];
        for (const q of list) {
            if (!q || typeof q !== 'object' || Array.isArray(q)) return { error: 'question' };
            const text = clean(q.question, LIMITS.question);
            if (!text) return { error: 'question' };
            const opts = Array.isArray(q.options) ? q.options : [];
            const seen = new Set();
            const kept = [];
            for (const o of opts) {
                const obj = o && typeof o === 'object';
                const label = clean(obj ? o.label : o, LIMITS.label);
                if (!label) return { error: 'label' };
                const key = label.toLowerCase();
                if (key === 'other') continue;
                if (seen.has(key)) return { error: 'duplicate' };
                seen.add(key);
                kept.push({ label, description: clean(obj ? o.description : '', LIMITS.description) });
            }
            if (kept.length < LIMITS.optionsMin || kept.length > LIMITS.optionsMax) return { error: 'options' };
            out.push({ question: text, header: clean(q.header, LIMITS.header), multi: q.multiSelect === true || q.multi === true, options: kept });
        }
        return { questions: out };
    }

    function answers(questions, raw) {
        if (!Array.isArray(questions) || !questions.length) return { error: 'questions' };
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { error: 'answers' };
        if (raw.skipped === true) return { skipped: true };
        const list = Array.isArray(raw.answers) ? raw.answers : null;
        if (!list || list.length !== questions.length) return { error: 'answers' };
        const out = [];
        for (let i = 0; i < questions.length; i++) {
            const a = list[i];
            if (!a || typeof a !== 'object' || Array.isArray(a)) return { error: 'answers' };
            const sel = a.selected == null ? [] : a.selected;
            if (!Array.isArray(sel)) return { error: 'selected' };
            const picked = [];
            for (const n of sel) {
                if (typeof n !== 'number' || !Number.isInteger(n) || n < 0 || n >= questions[i].options.length || picked.includes(n)) {
                    return { error: 'selected' };
                }
                picked.push(n);
            }
            picked.sort((x, y) => x - y);
            const other = clean(a.other, LIMITS.other);
            const count = picked.length + (other ? 1 : 0);
            if (questions[i].multi ? count < 1 : count !== 1) return { error: questions[i].multi ? 'empty' : 'single' };
            out.push({ selected: picked, other });
        }
        return { answers: out };
    }

    function answerText(questions, answered) {
        if (answered && answered.skipped) {
            return 'The user chose not to answer these questions. Carry on with your best judgment and say which assumptions you made.';
        }
        const lines = ['The user answered:'];
        questions.forEach((q, i) => {
            const a = answered.answers[i];
            const parts = a.selected.map(n => q.options[n].label);
            if (a.other) parts.push('Other: ' + a.other);
            lines.push((i + 1) + '. ' + q.question);
            lines.push('Answer: ' + parts.join('; '));
        });
        return lines.join('\n');
    }

    function take(text) {
        const src = typeof text === 'string' ? text : '';
        let last = null;
        let m;
        BLOCK_RE.lastIndex = 0;
        while ((m = BLOCK_RE.exec(src))) last = m[1];
        let rest = src.replace(BLOCK_RE, '');
        const open = rest.search(/<ask_user\b/);
        if (open !== -1) rest = rest.slice(0, open);
        rest = rest.replace(/\n{3,}/g, '\n\n').replace(/^\s+|\s+$/g, '');
        let ask = null;
        if (last != null) {
            let obj = null;
            try { obj = JSON.parse(last); } catch (_) { obj = null; }
            const parsed = obj && typeof obj === 'object' ? parse(obj) : { error: 'json' };
            if (!parsed.error) ask = { id: typeof obj.id === 'string' && ID_RE.test(obj.id) ? obj.id : '', questions: parsed.questions };
        }
        return { text: rest, ask };
    }

    function cut(text) {
        const s = String(text || '');
        const at = s.search(/<ask_user\b/i);
        return at === -1 ? s : s.slice(0, at).replace(/\s+$/, '');
    }

    function record(took, data, now) {
        if (!took || !took.ask || !took.ask.id) return null;
        const d = data || {};
        const p = d.pendingTool && d.pendingTool.kind === 'question' && d.pendingTool.id === took.ask.id ? d.pendingTool : null;
        const at = now || Date.now();
        const exp = p && Number(p.expiresAt) > 0 ? Math.min(Number(p.expiresAt), at + LIMITS.waitMs) : at + LIMITS.waitMs;
        const bg = d.background && d.background.waiting === true && /^[0-9a-f]{64}$/.test(String(d.background.runId || '')) ? String(d.background.runId) : null;
        const token = !bg && typeof d.resumeToken === 'string' && /^[0-9a-f]{32,64}$/i.test(d.resumeToken) ? d.resumeToken : null;
        return {
            id: took.ask.id,
            questions: took.ask.questions,
            plain: !bg && !token,
            token,
            runId: bg,
            expiresAt: exp,
            state: 'waiting'
        };
    }

    function stateOf(a, now) {
        if (!a || typeof a !== 'object') return null;
        const s = STATES.has(a.state) ? a.state : 'waiting';
        if ((s === 'waiting' || s === 'sending') && Number(a.expiresAt) > 0 && (now || Date.now()) >= Number(a.expiresAt)) return 'expired';
        return s;
    }

    function pending(m, now) {
        return !!(m && m.ask && stateOf(m.ask, now) === 'waiting');
    }

    function errorText(code) {
        switch (code) {
            case 'single': return t('Pick one answer for each question, or write your own.');
            case 'empty': return t('Pick at least one answer for each question, or write your own.');
            default: return t('That answer does not fit the question.');
        }
    }

    function hoursLeft(a, now) {
        return Math.max(0, Math.ceil((Number(a.expiresAt) - (now || Date.now())) / 3600000));
    }

    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };

    const Store = () => window.NymbotStore;

    const drafts = new Map();

    const Ask = {
        drafts,
        LIMITS, clean, parse, answers, answerText, take, cut, record, stateOf, pending, errorText,

        patch(ui, convId, m, patch) {
            const next = Object.assign({}, m.ask, patch);
            Store().patchMessage(convId, m.id, { ask: next });
            const fresh = Store().messages(convId).find(x => x.id === m.id);
            if (fresh && ui.conv && ui.conv.id === convId) ui.replaceMessage(fresh);
            if (window.NymbotTasks) window.NymbotTasks.refresh(ui);
            return fresh || Object.assign({}, m, { ask: next });
        },

        read(card, questions) {
            return questions.map((q, i) => {
                const picked = Array.from(card.querySelectorAll('input[data-q="' + i + '"][data-o]:checked')).map(x => Number(x.dataset.o));
                const other = card.querySelector('input[data-q="' + i + '"][data-other]');
                const field = card.querySelector('[data-other-text="' + i + '"]');
                const wrote = other && other.checked && field ? field.value : '';
                return { selected: picked, other: wrote };
            });
        },

        card(ui, m) {
            const a = m.ask;
            const state = stateOf(a);
            const done = state !== 'waiting' && state !== 'sending';
            const card = el('section', 'ask-card' + (done ? ' is-settled' : '') + ' is-' + state);
            card.dataset.id = m.id;
            card.setAttribute('aria-label', t('Nymbot has a question'));
            const head = el('div', 'ask-head');
            head.appendChild(el('span', 'ask-title', a.questions.length > 1 ? t('Nymbot has {n} questions', { n: a.questions.length }) : t('Nymbot has a question')));
            if (state === 'waiting') {
                const h = hoursLeft(a);
                head.appendChild(el('span', 'ask-expiry', h <= 1 ? t('Waiting for your answer · expires within the hour') : t('Waiting for your answer · expires in {n} hours', { n: h })));
            }
            card.appendChild(head);
            const form = el('form', 'ask-form');
            form.noValidate = true;
            const given = Array.isArray(a.answers) ? a.answers : (drafts.get(m.id) || (Array.isArray(a.draft) ? a.draft : null));
            a.questions.forEach((q, i) => {
                const set = el('fieldset', 'ask-q');
                set.disabled = done || state === 'sending';
                const legend = el('legend', 'ask-q-text');
                if (q.header) legend.appendChild(el('span', 'ask-q-header', q.header));
                legend.appendChild(el('span', 'ask-q-body', q.question));
                set.appendChild(legend);
                if (q.multi) set.appendChild(el('p', 'ask-q-hint', t('Pick any that apply.')));
                const name = 'ask-' + m.id + '-' + i;
                const opts = el('div', 'ask-options');
                opts.setAttribute('role', q.multi ? 'group' : 'radiogroup');
                const mine = given && given[i] ? given[i] : null;
                q.options.forEach((o, j) => {
                    const row = el('label', 'ask-option');
                    const input = document.createElement('input');
                    input.type = q.multi ? 'checkbox' : 'radio';
                    input.name = name;
                    input.dataset.q = String(i);
                    input.dataset.o = String(j);
                    if (mine && Array.isArray(mine.selected) && mine.selected.includes(j)) input.checked = true;
                    row.appendChild(input);
                    const text = el('span', 'ask-option-text');
                    text.appendChild(el('span', 'ask-option-label', o.label));
                    if (o.description) text.appendChild(el('span', 'ask-option-desc', o.description));
                    row.appendChild(text);
                    opts.appendChild(row);
                });
                const otherRow = el('label', 'ask-option ask-other');
                const otherInput = document.createElement('input');
                otherInput.type = q.multi ? 'checkbox' : 'radio';
                otherInput.name = name;
                otherInput.dataset.q = String(i);
                otherInput.dataset.other = '1';
                if (mine && mine.other) otherInput.checked = true;
                otherRow.appendChild(otherInput);
                otherRow.appendChild(el('span', 'ask-option-label', t('Other')));
                opts.appendChild(otherRow);
                const field = document.createElement('input');
                field.type = 'text';
                field.className = 'ask-other-text';
                field.maxLength = LIMITS.other;
                field.dataset.otherText = String(i);
                field.setAttribute('aria-label', t('Your own answer to: {question}', { question: q.question }));
                field.placeholder = t('Write your own answer');
                field.setAttribute('data-i18n-skip', '');
                if (mine && mine.other) field.value = mine.other;
                field.addEventListener('input', () => { if (field.value.trim()) otherInput.checked = true; });
                opts.appendChild(field);
                set.appendChild(opts);
                form.appendChild(set);
            });
            const status = el('p', 'ask-status');
            status.setAttribute('role', 'status');
            status.setAttribute('aria-live', 'polite');
            if (state === 'answered') status.textContent = t('Answered. Nymbot carried on from here.');
            else if (state === 'skipped') status.textContent = t('Skipped. Nymbot carried on with its own judgment.');
            else if (state === 'expired') status.textContent = t('No answer came within 24 hours, so this task stopped. Ask again to start it fresh.');
            else if (state === 'sending') status.textContent = t('Sending your answer…');
            else if (a.error) status.textContent = a.error;
            form.appendChild(status);
            if (!done) {
                const row = el('div', 'ask-actions');
                const send = el('button', 'btn btn-small btn-primary', t('Submit'));
                send.type = 'submit';
                send.dataset.role = 'ask-submit';
                send.disabled = state === 'sending';
                const skip = el('button', 'btn btn-small btn-ghost', t('Skip'));
                skip.type = 'button';
                skip.dataset.role = 'ask-skip';
                skip.disabled = state === 'sending';
                skip.addEventListener('click', () => this.submit(ui, m, { skipped: true }));
                row.appendChild(send);
                row.appendChild(skip);
                form.appendChild(row);
                const keep = () => drafts.set(m.id, this.read(form, a.questions));
                form.addEventListener('input', keep);
                form.addEventListener('change', keep);
                form.addEventListener('submit', (e) => {
                    e.preventDefault();
                    this.submit(ui, m, { answers: this.read(form, a.questions) });
                });
            }
            card.appendChild(form);
            return card;
        },

        async submit(ui, m, raw) {
            const conv = ui.conv;
            if (!conv) return;
            const fresh = Store().messages(conv.id).find(x => x.id === m.id) || m;
            const a = fresh.ask;
            if (!a || stateOf(a) === 'sending') return;
            if (stateOf(a) === 'expired') {
                this.patch(ui, conv.id, fresh, { state: 'expired' });
                return;
            }
            if (stateOf(a) !== 'waiting') return;
            const got = answers(a.questions, raw);
            if (got.error) {
                this.patch(ui, conv.id, fresh, { error: errorText(got.error), draft: Array.isArray(raw.answers) ? raw.answers : null });
                return;
            }
            drafts.delete(m.id);
            const capStop = ui.capStopsLeg(conv);
            if (capStop && !a.plain && !a.runId) {
                this.patch(ui, conv.id, fresh, { error: capStop });
                return;
            }
            const body = got.skipped ? { id: a.id, skipped: true } : { id: a.id, answers: got.answers };
            const kept = { state: got.skipped ? 'skipped' : 'answered', answers: got.skipped ? null : got.answers, error: '' };
            const sending = this.patch(ui, conv.id, fresh, { state: 'sending', error: '' });
            if (a.runId) return this.answerServer(ui, conv, sending, body, kept);
            return this.answerHere(ui, conv, sending, body, kept, answerText(a.questions, got));
        },

        async answerServer(ui, conv, m, body, kept) {
            const Api = window.NymbotApi;
            const payload = { runId: m.ask.runId, pendingId: body.id };
            if (body.skipped) payload.skipped = true;
            else payload.answers = body.answers;
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
            if (res && (res.status === 410 || data.expired)) {
                this.patch(ui, conv.id, m, { state: 'expired' });
                return;
            }
            if (res && res.status === 409 && data.gone) {
                this.patch(ui, conv.id, m, { state: 'expired' });
                return;
            }
            this.patch(ui, conv.id, m, { state: 'waiting', error: data.error || t('Could not send your answer. Try again.') });
        },

        async answerHere(ui, conv, m, body, kept, text) {
            const Chat = window.NymbotChat;
            const Caps = window.NymbotCaps;
            const a = m.ask;
            const turn = ui.beginTurn(conv, t('Carrying on with your answer'), { asked: m.askedBy || null, runId: m.replyTo || null, resumed: true });
            turn.answering = m.id;
            if (window.NymbotTranscripts) window.NymbotTranscripts.asked(ui, turn, kept.state === 'skipped' ? 'skipped' : 'answered', m);
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
                    }
                };
                if (a.token) {
                    opts.resume = a.token;
                    opts.pendingAnswer = body;
                    const B = window.NymbotBackground;
                    const grant = B ? await B.grantWithPush(ui, conv, turn, {}) : null;
                    if (grant) opts.background = grant;
                }
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
                    this.patch(ui, conv.id, m, { state: 'waiting', error: (e && e.message) || t('Could not send your answer. Try again.') });
                }
            } finally {
                ui.endTurn(turn);
            }
        },

        taskItem(m) {
            const a = m && m.ask;
            if (!a || !Array.isArray(a.questions)) return null;
            const state = stateOf(a);
            const first = a.questions[0] ? a.questions[0].question : '';
            const label = state === 'expired' ? t('Question expired: {question}', { question: first })
                : (state === 'waiting' || state === 'sending' ? t('Waiting for your answer: {question}', { question: first })
                    : t('Answered: {question}', { question: first }));
            return { label, state: state === 'waiting' || state === 'sending' ? 'waiting' : (state === 'expired' ? 'stopped' : 'done') };
        }
    };

    window.NymbotAsk = Ask;
})();
