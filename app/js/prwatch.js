(function () {
    'use strict';

    const FIX_MODES = ['off', 'ask', 'auto'];
    const FIX_DEFAULT = 'ask';
    const CAP_DEFAULT = 20;
    const CAP_CHOICES = [5, 10, 20, 50, 100];
    const MAX = 5;
    const LIST_EVERY_MS = 120000;
    const PEEK_EVERY_MS = 120000;
    const KEY = 'pr_watches';
    const RECORDS_MAX = 20;
    const KINDS = ['ci-failed', 'ci-passed', 'review', 'merged', 'closed', 'auth', 'expired', 'gone', 'limit', 'fix'];
    const STAGES = { 'ci-failed': 'ci-failed', 'ci-passed': 'ci-passed', review: 'review', merged: 'merged', closed: 'closed', fix: 'fix',
        auth: 'stopped', expired: 'stopped', gone: 'stopped', limit: 'stopped' };

    const Store = () => window.NymbotStore;
    const Api = () => window.NymbotApi;
    const Chat = () => window.NymbotChat;

    function watchDefault(settings) {
        return !(settings && settings.prWatch === false);
    }

    function repoChoice(raw) {
        return raw === 'on' || raw === 'off' ? raw : '';
    }

    function watchOn(repo, settings) {
        const own = repoChoice(repo && repo.prWatch);
        return own ? own === 'on' : watchDefault(settings);
    }

    function fixMode(settings) {
        const v = settings && settings.prFix;
        return FIX_MODES.includes(v) ? v : FIX_DEFAULT;
    }

    function fixCap(settings) {
        const n = Number(settings && settings.prFixCap);
        return Number.isFinite(n) && n > 0 && n <= 1000 ? n : CAP_DEFAULT;
    }

    function pullNo(job) {
        const n = Number(job && job.pull && job.pull.number);
        return Number.isInteger(n) && n > 0 ? n : 0;
    }

    function canWatch(job) {
        return !!job && pullNo(job) > 0 && !job.merged && !job.closed && !job.deleted && job.done !== false;
    }

    function keyOf(repo, branch) {
        return String(repo || '') + '#' + String(branch || '');
    }

    function liveText(live) {
        if (!live) return '';
        if (live.pr === 'merged' || live.state === 'merged') return t('Merged.');
        if (live.pr === 'closed' || live.state === 'closed') return t('Closed without merging.');
        const bits = [];
        if (live.ci === 'failing') bits.push(t('CI failing'));
        else if (live.ci === 'passing') bits.push(t('CI passing'));
        else if (live.ci === 'running') bits.push(t('CI running'));
        const n = Number(live.comments) || 0;
        if (n) bits.push(n === 1 ? t('1 review comment') : t('{n} review comments', { n }));
        if (live.state === 'stopped') bits.push(t('No longer watched.'));
        return bits.join(' · ');
    }

    function watchBody(git, job, o) {
        const opts = o || {};
        const fix = FIX_MODES.includes(opts.fix) ? opts.fix : FIX_DEFAULT;
        const model = typeof opts.model === 'string' ? opts.model : '';
        const watch = {
            number: pullNo(job),
            branch: String(job.branch || job.head || ''),
            base: String(job.base || ''),
            sha: /^[0-9a-f]{40,64}$/i.test(String(job.sha || '')) ? String(job.sha) : '',
            thread: /^[0-9a-f]{64}$/.test(String(opts.thread || '')) ? String(opts.thread) : '',
            fix: fix !== 'off' && !model ? 'off' : fix,
            cap: Number(opts.cap) > 0 ? Number(opts.cap) : CAP_DEFAULT,
            model: fix !== 'off' ? model : '',
            planFirst: ['always', 'changing', 'never'].includes(opts.planFirst) ? opts.planFirst : 'changing'
        };
        if (opts.push) watch.push = opts.push;
        return { git, watch };
    }

    function fresh(watch, seen) {
        const after = Number(seen) || 0;
        return (Array.isArray(watch && watch.events) ? watch.events : [])
            .filter(e => e && Number(e.seq) > after && KINDS.includes(e.kind))
            .sort((a, b) => a.seq - b.seq);
    }

    function eventMessage(watch, ev, id) {
        const out = {
            id,
            role: 'bot',
            content: String(ev.text || ''),
            cost: 0,
            prWatch: { id: watch.id, kind: ev.kind, seq: ev.seq, number: watch.number, repo: watch.repo, branch: watch.branch },
            ts: Number(ev.at) || Date.now()
        };
        if (ev.offer) out.prWatch.offer = true;
        return out;
    }

    function stageOf(kind) {
        return STAGES[kind] || '';
    }

    function records() {
        const list = Store().read(KEY, []);
        return Array.isArray(list) ? list.filter(r => r && /^[0-9a-f]{32}$/.test(String(r.id || '')) && r.convId) : [];
    }

    function saveRecords(list) {
        Store().write(KEY, list.slice(-RECORDS_MAX));
    }

    function recordFor(repo, branch) {
        return records().find(r => r.repo === repo && r.branch === branch && !r.stopped) || null;
    }

    const PrWatch = {
        FIX_MODES, FIX_DEFAULT, CAP_DEFAULT, CAP_CHOICES, MAX, LIST_EVERY_MS, PEEK_EVERY_MS,
        watchDefault, repoChoice, watchOn, fixMode, fixCap, canWatch, keyOf, liveText, watchBody, fresh, eventMessage, stageOf,
        records, recordFor,
        live: new Map(),
        peeked: new Map(),
        _listedAt: 0,
        _listing: null,

        any() {
            return records().some(r => !r.stopped);
        },

        liveFor(repo, branch) {
            const rec = recordFor(repo, branch);
            if (rec && this.live.has(rec.id)) return this.live.get(rec.id);
            const held = this.peeked.get(keyOf(repo, branch));
            return held ? held.live : null;
        },

        chipOptions(conv, job) {
            if (!conv || conv.anon || !job || !job.repo) return null;
            const rec = recordFor(job.repo, job.branch);
            if (!rec && !canWatch(job)) return null;
            return { on: !!rec, live: this.liveFor(job.repo, job.branch) };
        },

        async start(ui, conv, m, job, opts) {
            const o = opts || {};
            if (!conv || conv.anon) throw new Error(t('Watching pull requests is not available in anonymous chats.'));
            const repo = Chat().reposFor(conv).find(r => r.repo === job.repo);
            if (!repo) throw new Error(t('That repository is no longer connected.'));
            if (!repo.allowWrites) throw new Error(t('Writes are off for that repository.'));
            const settings = ui.settings || {};
            const policy = Chat().policyFor(conv, settings) || {};
            const model = (conv.proModel && conv.proModel.key) || (settings.proModel && settings.proModel.key) || '';
            const Bg = window.NymbotBackground;
            const push = Bg && typeof Bg.pushFor === 'function' ? await Bg.pushFor(conv.id, t('A pull request you watch changed'), 'prwatch') : null;
            const body = watchBody(Chat().repoPayload(repo), job, {
                thread: conv.rootId, fix: fixMode(settings), cap: fixCap(settings), model, planFirst: policy.planFirst, push
            });
            const { status, data } = await Api().call('pr-watch-put', body, { timeout: 20000 });
            if (status !== 200 || !data || !data.ok) {
                const err = new Error((data && data.error) || t('The pull request could not be watched.'));
                err.limit = !!(data && data.limit);
                err.quiet = !!o.auto;
                throw err;
            }
            const list = records().filter(r => !(r.repo === job.repo && r.branch === body.watch.branch));
            list.push({ id: data.id, repo: job.repo, branch: body.watch.branch, number: body.watch.number, convId: conv.id, msgId: m ? m.id : null, at: Date.now(), seen: 0 });
            saveRecords(list);
            if (data.watch) this.live.set(data.id, data.watch);
            this.transcript(ui, conv.id, m ? m.id : null, 'watch', t('Watching pull request #{n}.', { n: body.watch.number }));
            return data;
        },

        async stop(ui, rec) {
            if (!rec) return null;
            const res = await Api().call('pr-watch-stop', { id: rec.id }, { timeout: 20000 });
            if (res.status !== 200 || !res.data || res.data.error) {
                throw new Error((res.data && res.data.error) || t('The watch could not be stopped.'));
            }
            saveRecords(records().filter(r => r.id !== rec.id));
            this.live.delete(rec.id);
            return res.data;
        },

        async stopRepo(ui, repo) {
            const mine = records().filter(r => r.repo === (repo && repo.repo));
            for (const rec of mine) {
                try { await this.stop(ui, rec); } catch (_) { }
            }
            return mine.length;
        },

        async auto(ui, conv, m) {
            if (!conv || conv.anon || !m || !m.checkpoint) return 0;
            const GitRun = window.NymbotGitRun;
            let n = 0;
            for (const job of GitRun.jobsOf(m.checkpoint)) {
                if (!canWatch(job) || recordFor(job.repo, job.branch)) continue;
                const repo = Chat().reposFor(conv).find(r => r.repo === job.repo);
                if (!repo || !repo.allowWrites || !watchOn(repo, ui.settings)) continue;
                if (records().filter(r => !r.stopped).length >= MAX) break;
                try {
                    await this.start(ui, conv, m, job, { auto: true });
                    n++;
                } catch (_) { }
            }
            if (n && ui.conv && ui.conv.id === conv.id) ui.replaceMessage(Store().messages(conv.id).find(x => x.id === m.id) || m);
            return n;
        },

        async toggle(ui, conv, m, job, button) {
            const rec = recordFor(job.repo, job.branch);
            if (button) button.disabled = true;
            try {
                if (rec) {
                    await this.stop(ui, rec);
                    ui.note(t('Stopped watching pull request #{n}.', { n: rec.number }), conv.id);
                } else {
                    const got = await this.start(ui, conv, m, job);
                    ui.note(t('Watching pull request #{n}. Nymbot posts here when CI fails, a reviewer comments, or it is merged or closed, even with the app closed.', { n: got.watch ? got.watch.number : pullNo(job) }), conv.id);
                }
            } catch (e) {
                ui.note((e && e.message) || t('The forge could not be reached.'), conv.id);
            } finally {
                if (button) button.disabled = false;
                if (m) ui.replaceMessage(Store().messages(conv.id).find(x => x.id === m.id) || m);
            }
        },

        async fix(ui, conv, m) {
            const w = m && m.prWatch;
            if (!w || !w.offer || w.fixed) return;
            const res = await Api().call('pr-watch-fix', { id: w.id, seq: w.seq }, { timeout: 20000 });
            if (res.status !== 200 || !res.data || !res.data.ok) {
                ui.note((res.data && res.data.error) || t('The fix could not be started.'), conv.id);
                return;
            }
            Store().patchMessage(conv.id, m.id, { prWatch: Object.assign({}, w, { fixed: true }) });
            ui.replaceMessage(Store().messages(conv.id).find(x => x.id === m.id) || m);
            ui.note(t('Nymbot will start a fix run on {branch} in a moment. Its reply lands here.', { branch: w.branch }), conv.id);
        },

        transcript(ui, convId, msgId, kind, text) {
            const T = window.NymbotTranscripts;
            if (!T || typeof T.prEvent !== 'function' || !msgId) return;
            try { T.prEvent(ui, convId, msgId, stageOf(kind) || kind, text); } catch (_) { }
        },

        async refresh(ui, force) {
            if (!this.any() && !force) return 0;
            const now = Date.now();
            if (!force && now - this._listedAt < LIST_EVERY_MS) return 0;
            if (this._listing) return this._listing;
            this._listedAt = now;
            this._listing = (async () => {
                let res;
                try { res = await Api().call('pr-watch-list', {}, { timeout: 20000 }); } catch (_) { return 0; }
                if (!res || res.status !== 200 || !res.data || !Array.isArray(res.data.watches)) return 0;
                return this.apply(ui, res.data.watches);
            })();
            try { return await this._listing; } finally { this._listing = null; }
        },

        async apply(ui, watches) {
            const byId = new Map(watches.filter(w => w && w.id).map(w => [w.id, w]));
            let filed = 0;
            const list = records();
            for (const rec of list) {
                const w = byId.get(rec.id);
                if (!w) {
                    rec.stopped = true;
                    this.live.delete(rec.id);
                    continue;
                }
                this.live.set(rec.id, w);
                const conv = Store().conversation(rec.convId);
                if (!conv) continue;
                for (const ev of fresh(w, rec.seen)) {
                    rec.seen = ev.seq;
                    if (ev.kind === 'fix') {
                        if (ev.eventId && ev.state !== 'failed') await this.fileFix(ui, conv, rec, ev);
                        else if (ev.text) this.place(ui, conv, eventMessage(w, ev, Store().uid()));
                        this.transcript(ui, conv.id, rec.msgId, 'fix', ev.text || '');
                        filed++;
                        continue;
                    }
                    this.place(ui, conv, eventMessage(w, ev, Store().uid()));
                    this.transcript(ui, conv.id, rec.msgId, ev.kind, ev.text);
                    filed++;
                }
                if (w.fixSha && rec.msgId) this.moveHead(ui, conv, rec, w.fixSha);
                if (w.state === 'stopped' || w.pr === 'merged' || w.pr === 'closed') {
                    rec.stopped = true;
                    if (rec.msgId) this.settleJob(ui, conv, rec, w);
                }
            }
            saveRecords(list.filter(r => !r.stopped || Date.now() - r.at < 7 * 86400000));
            if (filed) ui.renderList();
            if (ui.conv && list.some(r => r.convId === ui.conv.id)) ui.renderMessages({ keep: true });
            return filed;
        },

        place(ui, conv, msg) {
            ui.placeMessage(conv.id, msg);
            if (!ui.conv || ui.conv.id !== conv.id) {
                const c = Store().conversation(conv.id);
                if (c) Store().updateConversation(c.id, { unread: (c.unread || 0) + 1 });
            }
        },

        async fileFix(ui, conv, rec, ev) {
            let res;
            try {
                res = await Chat().claimStored(conv, ev.eventId, { msgId: null });
            } catch (_) {
                return false;
            }
            const asked = {
                id: Store().uid(), role: 'self', content: t('Fix what was reported on pull request #{n}.', { n: rec.number }),
                prWatch: { id: rec.id, kind: 'fix', seq: ev.seq }, wire: res.replyTo || null, ts: Number(ev.at) || Date.now()
            };
            Store().addMessage(conv.id, asked);
            const C = window.NymbotConnectors;
            const reply = {
                id: Store().uid(), role: 'bot', content: res.reply || '', thinking: res.thinking || null, cost: res.cost || 0, pro: !!res.pro,
                checkpoint: res.checkpoint || null, pendingTool: C ? C.pendingFrom(res) : null, ask: res.ask || null,
                proposal: res.proposal || null, staged: res.staged || null, replyTo: res.replyTo || null, askedBy: asked.id,
                prWatch: { id: rec.id, kind: 'fix', seq: ev.seq }, ts: (Number(ev.at) || Date.now()) + 1
            };
            ui.placeMessage(conv.id, reply);
            if (reply.checkpoint) Chat().rememberBranches(conv, reply.checkpoint);
            return true;
        },

        moveHead(ui, conv, rec, sha) {
            const m = Store().messages(conv.id).find(x => x.id === rec.msgId);
            const jobs = m && m.checkpoint ? window.NymbotGitRun.jobsOf(m.checkpoint) : [];
            const job = jobs.find(j => j.branch === rec.branch);
            if (!job || job.sha === sha) return;
            ui.patchJob(conv.id, m, rec.branch, { sha });
            Chat().rememberBranchStep({ repo: rec.repo, branch: rec.branch, base: job.base, sha }, conv);
        },

        settleJob(ui, conv, rec, w) {
            const m = Store().messages(conv.id).find(x => x.id === rec.msgId);
            if (!m || !m.checkpoint) return;
            if (w.pr === 'merged') ui.patchJob(conv.id, m, rec.branch, { merged: true });
            else if (w.pr === 'closed') ui.patchJob(conv.id, m, rec.branch, { closed: true });
        },

        async peek(ui, conv, job) {
            if (!conv || conv.anon || !job || !canWatch(job)) return null;
            const key = keyOf(job.repo, job.branch);
            const held = this.peeked.get(key);
            if (held && Date.now() - held.at < PEEK_EVERY_MS) return held.live;
            const repo = Chat().reposFor(conv).find(r => r.repo === job.repo);
            if (!repo) return null;
            this.peeked.set(key, { at: Date.now(), live: held ? held.live : null });
            let res;
            try {
                res = await Api().call('pr-watch-peek', { git: Chat().repoPayload(repo), watch: { number: pullNo(job), branch: job.branch } }, { timeout: 20000 });
            } catch (_) {
                return null;
            }
            if (!res || res.status !== 200 || !res.data || res.data.error) return null;
            this.peeked.set(key, { at: Date.now(), live: res.data });
            return res.data;
        },

        async peekVisible(ui) {
            const conv = ui.conv;
            if (!conv || conv.anon || document.visibilityState === 'hidden') return 0;
            const GitRun = window.NymbotGitRun;
            let n = 0;
            for (const m of Store().messages(conv.id)) {
                if (!m.checkpoint) continue;
                for (const job of GitRun.jobsOf(m.checkpoint)) {
                    if (!canWatch(job) || recordFor(job.repo, job.branch)) continue;
                    const before = this.peeked.get(keyOf(job.repo, job.branch));
                    const live = await this.peek(ui, conv, job);
                    if (live && (!before || JSON.stringify(before.live) !== JSON.stringify(live))) {
                        n++;
                        ui.replaceMessage(m);
                    }
                }
            }
            return n;
        },

        async tick(ui) {
            await this.refresh(ui).catch(() => 0);
            await this.peekVisible(ui).catch(() => 0);
        }
    };

    window.NymbotPrWatch = PrWatch;
})();
