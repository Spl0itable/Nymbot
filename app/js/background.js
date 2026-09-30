(function () {
    'use strict';

    const HEX = /^[0-9a-f]{64}$/;
    const CHAT_RE = /^[A-Za-z0-9_-]{1,64}$/;
    const MAX_LEGS = 40;
    const WINDOW_MS = 6 * 3600000;
    const KEEP_MS = WINDOW_MS + 24 * 3600000;
    const SCHED_MS = 90 * 86400000;
    const PROMPT_MAX = 4000;
    const TITLE_MAX = 120;
    const PUSH_WAIT_MS = 4000;
    const RUNS_KEY = 'bg_runs';
    const SEEN_KEY = 'sched_seen';
    const COLLECTED_KEY = 'sched_collected';
    const WRAP_SKEW_MS = 2 * 86400000;
    const LIVE = new Set(['running', 'parked', 'waiting']);

    const Store = () => window.NymbotStore;
    const Api = () => window.NymbotApi;
    const Chat = () => window.NymbotChat;
    const Notify = () => window.NymbotNotify;

    function hex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    async function sha256Hex(text) {
        return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))));
    }

    function within(promise, ms) {
        return Promise.race([promise, new Promise(r => setTimeout(() => r(null), ms))]);
    }

    function consentText(n) {
        return t('When this is on, Nymbot\'s server keeps a copy of this scheduled prompt and its settings, sealed with a key the server holds, so it can run it at the set time while your app is closed. The server can read it when it runs, the same as any message you send. It spends up to {n} credits per run from your balance. Turning this off, deleting the schedule, or wiping the app deletes the server copy at once.', { n });
    }

    const Background = {
        POLL_MS: 5000,
        COLLECT_EVERY_MS: 120000,
        MAX_LEGS,
        _lastCollect: 0,
        _collecting: null,

        eligible(ui, conv) {
            return !!(conv && !conv.anon && !conv.support && !conv.ephemeral);
        },

        paidFor(ui, conv) {
            const media = conv.mediaModel || ui.settings.mediaModel;
            const pro = !!(conv.proModel || ui.settings.proModel || (media && media.proKey));
            const bal = ui.balance || {};
            return Number(pro ? bal.pro : bal.standard) > 0;
        },

        budget(ui, turn) {
            const left = ui.continueBudget(turn || {});
            return Number.isFinite(left) ? Math.floor(left) : 0;
        },

        grantFor(ui, conv, turn, opts) {
            const o = opts || {};
            if (ui.settings.backgroundJobs !== true) return null;
            if (!this.eligible(ui, conv) || !this.paidFor(ui, conv)) return null;
            if (o.research || o.team) return { maxLegs: MAX_LEGS };
            const credits = this.budget(ui, turn);
            return credits >= 1 ? { maxCredits: credits, maxLegs: MAX_LEGS } : null;
        },

        async grantWithPush(ui, conv, turn, opts) {
            const grant = this.grantFor(ui, conv, turn, opts);
            if (!grant) return null;
            const push = await this.pushFor(conv.id, t('Your task is done'));
            if (push) grant.notify = push;
            return grant;
        },

        async pushFor(chat, text) {
            const N = Notify();
            if (!N || !CHAT_RE.test(String(chat || '')) || !N.pushSupported() || N.permission() !== 'granted') return null;
            try {
                const subscription = await within(N.subscription(), PUSH_WAIT_MS);
                if (!subscription) return null;
                return { env: 'web', subscription, chat, text: String(text || '').slice(0, 80) };
            } catch (_) {
                return null;
            }
        },

        async askOnce(ui, conv, turn, opts) {
            const o = opts || {};
            const held = ui.settings.backgroundJobs;
            if (held === true || held === false) return held;
            if (!this.eligible(ui, conv) || !this.paidFor(ui, conv)) return false;
            const own = !!(o.research || o.team);
            const credits = this.budget(ui, turn);
            if (!own && credits < 1) return false;
            const spend = own
                ? t('It spends no more than this task\'s own credit limit and deletes it all when the task ends.')
                : t('It spends up to {n} credits on this task and deletes it all when the task ends.', { n: credits });
            const yes = await ui.ask({
                title: t('Keep long tasks going while the app is closed?'),
                body: t('This task needs more steps than one turn holds. Nymbot\'s server can carry it on by itself, so it finishes even if you close the app. To do that, the server keeps what the next step needs, sealed with a key the server holds, for at most 6 hours: the task\'s saved progress and its settings, including the tokens for the repositories and connectors it uses.')
                    + ' ' + spend + ' ' + t('You can change this at any time in Settings.'),
                confirm: t('Keep going on the server'),
                cancel: t('Keep it on this device')
            });
            ui.saveSettings({ backgroundJobs: !!yes });
            return !!yes;
        },

        runs() {
            const list = Store().read(RUNS_KEY, []);
            return Array.isArray(list) ? list.filter(r => r && HEX.test(String(r.runId || '')) && r.convId) : [];
        },

        keep(rec) {
            const list = this.runs().filter(r => r.runId !== rec.runId);
            list.push(rec);
            Store().write(RUNS_KEY, list.slice(-20));
        },

        forget(runId) {
            const list = this.runs();
            const kept = list.filter(r => r.runId !== runId);
            if (kept.length !== list.length) Store().write(RUNS_KEY, kept);
        },

        async follow(ui, turn, res) {
            const bg = res.background;
            const runId = String(bg.runId);
            const until = Number(bg.until) || (Date.now() + WINDOW_MS);
            if (!turn.runId) turn.runId = runId;
            turn.sent = true;
            const rec = { runId, convId: turn.convId, asked: turn.asked || null, claimed: [], at: Date.now(), until };
            this.keep(rec);
            return this.track(ui, turn, rec);
        },

        mark(ui, turn) {
            turn.background = true;
            ui.turnLabel(turn, t('Working in the background'));
            ui.turnStatus(turn, t('You can close the app. Nymbot\'s server carries this on for up to 6 hours.'));
        },

        async wait(turn, ms) {
            const until = Date.now() + ms;
            while (!turn.stopped && Date.now() < until) {
                await new Promise(r => setTimeout(r, Math.min(250, Math.max(1, until - Date.now()))));
            }
        },

        async status(rec) {
            try {
                const live = await Api().liveRuns(null, {});
                const runs = live && live.status === 200 && live.data && Array.isArray(live.data.runs) ? live.data.runs : null;
                const hit = runs ? runs.find(r => r && r.replyTo === rec.runId) : null;
                if (hit) return { state: LIVE.has(hit.state) ? hit.state : 'running', legs: this.legIds(hit.legs), listed: true };
                const done = await Api().call('pm-done-since', { since: Math.max(0, (Number(rec.at) || Date.now()) - 60000) }, { timeout: 10000 });
                const ended = done && done.status === 200 && done.data && Array.isArray(done.data.runs) ? done.data.runs : null;
                const end = ended ? ended.find(r => r && r.replyTo === rec.runId) : null;
                if (end) return { state: String(end.state || ''), legs: this.legIds(end.legs), listed: false };
                return runs || ended ? { state: '', legs: [], listed: false } : null;
            } catch (_) {
                return null;
            }
        },

        legIds(raw) {
            return Array.isArray(raw) ? raw.filter(x => typeof x === 'string' && x && x.length <= 128) : [];
        },

        async claimLeg(ui, turn, rec, legId) {
            let res;
            try {
                res = await Api().claimRun(legId, { controller: turn.controller });
            } catch (_) {
                return { wait: true };
            }
            if (!res || res.aborted || turn.stopped) return { wait: true };
            const data = res.data || {};
            if (res.status === 202 || data.pending) return { wait: true };
            if (res.status === 404 || data.unknown) return { skip: true };
            if (data.noCredits) return { end: 'nocredits' };
            if (data.capExceeded) return { end: 'capexceeded' };
            if (!data.event) return res.status >= 500 || res.status === 0 ? { wait: true } : { skip: true };
            const conv = Store().conversation(rec.convId);
            if (!conv) return { end: 'gone' };
            let next;
            try {
                next = await Chat().settle(conv, data, {
                    anon: false, payer: null, ghost: true, repos: Chat().reposFor(conv), isFresh: true,
                    eventId: null, msgId: null, partWraps: []
                });
            } catch (_) {
                return { skip: true };
            }
            if (turn.stopped) return { wait: true };
            if (next.stopped) return { end: 'stopped' };
            ui.placeLeg(turn, conv, next);
            if (next.background) return { more: true };
            if (next.pendingTool) return { end: 'approval', next };
            const paused = data.background && data.background.state === 'paused' ? String(data.background.reason || '') : '';
            if (paused || next.capStopped) return { end: 'paused', reason: paused, next };
            if (next.resumeToken) return { end: 'paused', reason: '', next };
            return { end: 'done', next };
        },

        async track(ui, turn, rec) {
            this.mark(ui, turn);
            const claimed = new Set(rec.claimed || []);
            let end = null;
            let misses = 0;
            while (!turn.stopped && !end) {
                await this.wait(turn, this.POLL_MS);
                if (turn.stopped) break;
                if (Date.now() > (Number(rec.until) || 0) + KEEP_MS) { end = { end: 'lost' }; break; }
                const seen = await this.status(rec);
                if (turn.stopped) break;
                if (!seen) continue;
                let waiting = false;
                const over = seen.state === 'failed' || seen.state === 'stopped';
                for (const leg of seen.legs) {
                    if (claimed.has(leg)) continue;
                    const got = await this.claimLeg(ui, turn, rec, leg);
                    if (turn.stopped) break;
                    if (got.wait && !over) { waiting = true; break; }
                    claimed.add(leg);
                    rec.claimed = [...claimed];
                    this.keep(rec);
                    if (got.end) { end = got; break; }
                }
                if (turn.stopped || end || waiting) continue;
                if (seen.state === 'failed') end = { end: 'failed' };
                else if (seen.state === 'stopped') end = { end: 'stopped' };
                else if (seen.state === 'done' && seen.legs.length) end = { end: 'done' };
                else if (!seen.state && !seen.listed && ++misses >= 3 && Date.now() > (Number(rec.until) || 0)) end = { end: 'lost' };
            }
            this.forget(rec.runId);
            if (turn.stopped || !end) return;
            await this.finish(ui, turn, end);
        },

        async finish(ui, turn, got) {
            switch (got.end) {
                case 'done':
                    turn.outcome = 'done';
                    ui.runNote(turn, t('Finished in the background.'));
                    return;
                case 'approval':
                    turn.outcome = 'approval';
                    return;
                case 'failed':
                case 'lost':
                    turn.outcome = 'failed';
                    ui.runNote(turn, t('That task failed in the background. Nothing more was charged.'));
                    return;
                case 'stopped':
                    turn.outcome = 'stopped';
                    ui.runNote(turn, t('Stopped.'));
                    return;
                case 'nocredits':
                    turn.outcome = 'paused';
                    ui.runNote(turn, t('Paused in the background: you are out of credits. Top up, then ask it to carry on.'));
                    return;
                case 'capexceeded':
                    turn.outcome = 'paused';
                    ui.runNote(turn, t('Paused in the background: carrying on could go past this chat\'s spending cap.'));
                    return;
                case 'gone':
                    return;
                default:
                    break;
            }
            turn.outcome = 'paused';
            const why = {
                legs: t('Paused: the task took the most steps one background run may take.'),
                credits: t('Paused: the task spent the credit limit it had for running in the background.'),
                time: t('Paused: the task reached the 6-hour limit for running in the background.')
            }[got.reason];
            if (why) ui.runNote(turn, why);
            const next = got.next;
            if (next && next.resumeToken && got.reason !== 'credits' && this.budget(ui, turn) > 0) {
                turn.bgOff = true;
                await ui.continueRun(turn, next);
            } else if (!why && next && next.resumeToken) {
                ui.runNote(turn, t('Paused. Open the chat to carry on.'));
            }
        },

        resume(ui) {
            const now = Date.now();
            for (const rec of this.runs()) {
                if (now > (Number(rec.until) || 0) + KEEP_MS) { this.forget(rec.runId); continue; }
                const conv = Store().conversation(rec.convId);
                if (!conv) { this.forget(rec.runId); continue; }
                const live = [...ui.turns.values()].some(x => x.runId === rec.runId || (rec.asked && x.asked === rec.asked));
                if (live) continue;
                const turn = ui.beginTurn(conv, t('Working in the background'), { asked: rec.asked, runId: rec.runId, resumed: true });
                turn.sent = true;
                this.track(ui, turn, rec).catch(() => { }).finally(() => ui.endTurn(turn));
            }
        },

        schedulesOn(ui) {
            return ui.settings.serverSchedules === true;
        },

        dailyCap(ui) {
            const n = Number(ui.settings.scheduleDailyCap);
            return n >= 1 && n <= 10000 ? Math.floor(n) : 50;
        },

        runsOnServer(ui, entry) {
            return !!(entry && entry.server === 'run' && entry.serverSha && this.schedulesOn(ui)
                && (!entry.serverExpiresAt || entry.serverExpiresAt > Date.now()));
        },

        consentText,

        modelFor(ui, entry) {
            const conv = entry.convId ? Store().conversation(entry.convId) : null;
            const model = (conv && conv.proModel) || ui.settings.proModel || null;
            return { conv, model };
        },

        payloadFor(ui, entry, mode) {
            if (mode === 'notify') return JSON.stringify({ repeat: entry.repeat || 'once', nextAt: entry.nextAt });
            const { conv, model } = this.modelFor(ui, entry);
            return JSON.stringify({
                repeat: entry.repeat || 'once',
                nextAt: entry.nextAt,
                prompt: String(entry.prompt || '').slice(0, PROMPT_MAX),
                title: String(entry.title || '').slice(0, TITLE_MAX),
                thread: conv && HEX.test(String(conv.rootId || '')) ? conv.rootId : '',
                model: model && model.key ? String(model.key) : '',
                tier: model && model.key ? 'pro' : 'standard'
            });
        },

        async put(ui, entry, mode, cap) {
            if (mode === 'run') {
                const { model } = this.modelFor(ui, entry);
                const bal = ui.balance || {};
                if (!(Number(model && model.key ? bal.pro : bal.standard) > 0)) {
                    return { error: t('Server schedules spend your paid balance, which is empty. Top up first.') };
                }
            }
            const chat = CHAT_RE.test(String(entry.convId || '')) ? entry.convId : entry.id;
            const push = await this.pushFor(chat, mode === 'notify' ? t('A scheduled prompt is due') : t('Your scheduled prompt ran'));
            if (mode === 'notify' && !push) {
                return { error: t('Notifications are off for this app, so the server cannot tell you when it is due. Allow notifications first.') };
            }
            const payload = this.payloadFor(ui, entry, mode);
            const sha = await sha256Hex(payload);
            const schedule = {
                id: entry.id,
                mode,
                sha256: sha,
                expiresAt: Date.now() + SCHED_MS - 60000,
                dailyCap: this.dailyCap(ui),
                payload
            };
            if (mode === 'run') schedule.maxCreditsPerRun = cap;
            if (push) schedule.push = push;
            let res;
            try {
                res = await Api().call('schedule-put', { schedule }, { timeout: 15000 });
            } catch (_) {
                res = { status: 0, data: {} };
            }
            const data = (res && res.data) || {};
            if (res && res.status === 200 && data.ok) {
                const saved = Store().saveSchedule(Object.assign({}, entry, {
                    server: mode, serverCap: mode === 'run' ? cap : null, serverSha: sha,
                    serverExpiresAt: Number(data.expiresAt) || schedule.expiresAt, serverError: '', serverOff: false
                }));
                return { ok: true, entry: saved };
            }
            if (res && res.status === 409 && data.limit) {
                return { error: t('The server keeps up to 10 schedules. Delete one first, or keep this one on this device.') };
            }
            if (!res || !res.status || res.status === 503 || data.unavailable || data.error === 'Unknown action' || res.status >= 500) {
                return { error: t('Server schedules are not available right now, so this one runs only while the app is open.') };
            }
            return { error: t('The server could not take this schedule: {error}', { error: String(data.error || res.status) }) };
        },

        async remove(ui, id) {
            if (!CHAT_RE.test(String(id || ''))) return false;
            try {
                const res = await Api().call('schedule-delete', { id }, { timeout: 15000 });
                return !!(res && res.status === 200);
            } catch (_) {
                return false;
            }
        },

        dropServer(entry) {
            return Object.assign({}, entry, { server: null, serverSha: null, serverExpiresAt: 0, serverError: '', serverOff: false });
        },

        async clear(ui) {
            let ok = false;
            try {
                const res = await Api().call('schedule-clear', {}, { timeout: 15000 });
                ok = !!(res && res.status === 200);
            } catch (_) {
                ok = false;
            }
            for (const s of Store().schedules()) {
                if (s.server || s.serverSha) Store().saveSchedule(this.dropServer(s));
            }
            return ok;
        },

        async refresh(ui) {
            if (!this.schedulesOn(ui) || !Store().schedules().some(s => s.serverSha)) return null;
            let res;
            try {
                res = await Api().call('schedule-list', {}, { timeout: 10000 });
            } catch (_) {
                return null;
            }
            if (!res || res.status !== 200 || !res.data || !Array.isArray(res.data.schedules)) return null;
            const held = new Map(res.data.schedules.filter(x => x && typeof x.id === 'string').map(x => [x.id, x]));
            for (const s of Store().schedules()) {
                if (!s.serverSha) continue;
                const there = held.get(s.id);
                if (!there || there.sha256 !== s.serverSha) {
                    Store().saveSchedule(Object.assign(this.dropServer(s), { server: s.server }));
                    continue;
                }
                const off = there.enabled === false;
                if (off !== !!s.serverOff || Number(there.expiresAt) !== Number(s.serverExpiresAt)) {
                    Store().saveSchedule(Object.assign({}, s, { serverOff: off, serverExpiresAt: Number(there.expiresAt) || s.serverExpiresAt }));
                }
            }
            return res.data;
        },

        seen() {
            const list = Store().read(SEEN_KEY, []);
            return Array.isArray(list) ? list : [];
        },

        async collect(ui, opts) {
            const o = opts || {};
            const Identity = window.NymbotIdentity;
            if (!Identity || !Identity.pubkey) return 0;
            const now = Date.now();
            if (!o.force) {
                if (!Store().schedules().some(s => s.server === 'run')) return 0;
                if (now - this._lastCollect < this.COLLECT_EVERY_MS) return 0;
            }
            if (this._collecting) return this._collecting;
            this._lastCollect = now;
            this._collecting = (async () => {
                const last = Number(Store().read(COLLECTED_KEY, 0)) || (now - 7 * 86400000);
                let events = [];
                try {
                    events = await window.NymbotRelays.fetch({
                        kinds: [1059], '#p': [Identity.pubkey], since: Math.floor((last - WRAP_SKEW_MS) / 1000)
                    }, 6000);
                } catch (_) {
                    events = [];
                }
                let filed = 0;
                for (const ev of events || []) {
                    try {
                        if (await this.file(ui, ev)) filed++;
                    } catch (_) { }
                }
                Store().write(COLLECTED_KEY, now);
                return filed;
            })();
            try { return await this._collecting; } finally { this._collecting = null; }
        },

        async file(ui, ev) {
            const C = window.NymbotConfig;
            const opened = await window.NymbotWire.unwrap(ev, null, { from: C.botPubkey });
            const rumor = opened && opened.rumor;
            if (!rumor || !Array.isArray(rumor.tags)) return false;
            const tag = rumor.tags.find(x => Array.isArray(x) && x[0] === 'nymsched');
            if (!tag || !CHAT_RE.test(String(tag[1] || ''))) return false;
            const id = String(tag[1]);
            const firedAt = Number(tag[2]) || 0;
            const key = id + ':' + firedAt;
            const seen = this.seen();
            if (seen.includes(key)) return false;
            const threadTag = rumor.tags.find(x => Array.isArray(x) && x[0] === 'nymthread');
            const thread = threadTag && HEX.test(String(threadTag[1] || '')) ? String(threadTag[1]) : '';
            const link = Chat().linkOf(rumor, null);
            const entry = Store().schedule(id);
            const S = Store();
            let conv = thread ? S.conversations().find(c => c.rootId === thread) : null;
            if (!conv && entry && entry.convId) conv = S.conversation(entry.convId);
            if (!conv) {
                const patch = { title: (entry && entry.title) || t('Scheduled prompt') };
                if (thread) patch.rootId = thread;
                conv = ui.newConversation(patch);
            }
            const when = firedAt || (Number(rumor.created_at) * 1000) || Date.now();
            if (link.replyTo && S.messages(conv.id).some(m => m.role === 'bot' && m.replyTo === link.replyTo)) {
                S.write(SEEN_KEY, seen.concat([key]).slice(-200));
                return false;
            }
            const asked = {
                id: S.uid(), role: 'self', content: (entry && entry.prompt) || t('A scheduled prompt'),
                scheduled: id, wire: link.replyTo || null, ts: when
            };
            S.addMessage(conv.id, asked);
            const split = Chat().splitThinking(rumor.content || '');
            const modelTag = rumor.tags.find(x => Array.isArray(x) && x[0] === 'model');
            ui.placeMessage(conv.id, {
                id: S.uid(), role: 'bot', content: split.body, thinking: split.thinking || null,
                model: modelTag ? String(modelTag[1] || '') || null : null,
                replyTo: link.replyTo || null, askedBy: asked.id, scheduled: id, ts: when + 1
            });
            S.write(SEEN_KEY, seen.concat([key]).slice(-200));
            if (entry) {
                S.saveSchedule(Object.assign({}, entry, {
                    lastRunAt: Math.max(Number(entry.lastRunAt) || 0, when), lastConvId: conv.id, runs: (entry.runs || 0) + 1
                }));
            }
            ui.renderList();
            if (ui.conv && ui.conv.id === conv.id) ui.renderMessages({ keep: true });
            return true;
        }
    };

    window.NymbotBackground = Background;
})();
