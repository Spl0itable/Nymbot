(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;
    const Identity = window.NymbotIdentity;
    const Relays = window.NymbotRelays;
    const PQ = window.NymbotPQ;
    const Wire = window.NymbotWire;
    const Api = window.NymbotApi;
    const Anon = window.NymbotAnon;
    const Attach = () => window.NymbotAttach;
    const Hex = window.NymbotHex;

    function splitThinking(text) {
        const patterns = [
            /^\s*<think>([\s\S]*?)<\/think>\s*/i,
            /^\s*<thinking>([\s\S]*?)<\/thinking>\s*/i,
            /^\s*<reasoning>([\s\S]*?)<\/reasoning>\s*/i
        ];
        for (const re of patterns) {
            const m = re.exec(text || '');
            if (m) return { thinking: m[1].trim(), body: (text || '').slice(m[0].length) };
        }
        return { thinking: null, body: text || '' };
    }

    function titleFor(text) {
        let title = String(text || '')
            .replace(/```[\s\S]*?```/g, ' ')
            .replace(/[`*_>#|]/g, '')
            .replace(/https?:\/\/\S+/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        if (!title) return t('New chat');
        const cmd = /^\?(\w+)\s*(.*)$/.exec(title);
        if (cmd) title = cmd[2] || cmd[1];
        title = title.replace(/^[!\s]+/, '');
        if (title.length <= 48) return title.charAt(0).toUpperCase() + title.slice(1);
        const cut = title.slice(0, 48);
        const space = cut.lastIndexOf(' ');
        return (space > 24 ? cut.slice(0, space) : cut).replace(/[,;:.\-]$/, '') + '…';
    }

    const KNOWLEDGE_FILE_CAP = 24000;
    const KNOWLEDGE_TOTAL_CAP = 90000;

    function workspaceFor(conv) {
        return conv && conv.workspaceId ? Store.workspace(conv.workspaceId) : null;
    }

    function botFor(conv) {
        const Bots = window.NymbotBots;
        return conv && conv.botId && Bots ? Bots.get(conv.botId) : null;
    }

    /// A chat sees its own repositories plus the ones its workspace carries, in
    /// that order and without duplicates.
    function reposFor(conv) {
        const space = workspaceFor(conv);
        const ids = (Array.isArray(conv.repoIds) ? conv.repoIds : [])
            .concat(space && Array.isArray(space.repoIds) ? space.repoIds : []);
        const seen = new Set();
        return ids
            .filter(id => !seen.has(id) && seen.add(id))
            .map(id => Store.repo(id))
            .filter(r => r && r.enabled !== false && r.token && r.repo);
    }

    /// The workspace's files, trimmed to something a context window can hold.
    /// A file that is cut says so, so nothing silently half-arrives.
    function knowledgeBlock(space) {
        const files = (space && space.files) || [];
        if (!files.length) return '';
        const parts = [];
        let budget = KNOWLEDGE_TOTAL_CAP;
        for (const file of files) {
            if (budget <= 0) break;
            const room = Math.min(KNOWLEDGE_FILE_CAP, budget);
            const body = String(file.body || '');
            const cut = body.length > room;
            const text = cut ? body.slice(0, room) : body;
            budget -= text.length;
            parts.push(`--- ${file.name || 'untitled'} ---\n${text}`
                + (cut ? '\n[…trimmed to fit]' : ''));
        }
        const left = files.length - parts.length;
        return '[project knowledge]\n' + parts.join('\n\n')
            + (left > 0 ? `\n\n[${left} more file(s) not sent — too much to fit]` : '');
    }

    function repoPayload(repo) {
        return {
            provider: repo.provider || 'github',
            host: repo.host || '',
            token: repo.token,
            repo: repo.repo,
            branch: repo.branch || '',
            allowWrites: !!repo.allowWrites,
            paths: repo.paths || '',
            label: repo.label || repo.repo
        };
    }

    function preambleFor(conv, repos) {
        const parts = [];
        const space = workspaceFor(conv);
        const bot = botFor(conv);
        const personaId = conv.personaId || (space ? space.personaId : null);
        const persona = personaId ? Store.persona(personaId) : null;
        const instructions = [
            bot ? (bot.instructions || '') : '',
            persona ? persona.instructions : '',
            space ? (space.instructions || '') : '',
            conv.systemPrompt || ''
        ].filter(Boolean).join('\n\n').trim();
        if (instructions) {
            parts.push('[custom instructions]\n' + instructions);
        }
        if (repos.length > 1) {
            parts.push('[repositories in scope]\n' + repos.map((r, i) =>
                `${i + 1}. ${r.repo}${r.branch ? '@' + r.branch : ''} (${r.provider || 'github'}${r.allowWrites ? ', writable' : ', read-only'})${r.paths ? ' paths: ' + r.paths : ''}`
            ).join('\n') + '\nRefer to a repository by its name when you cite a file.');
        }
        if (space) {
            const knowledge = knowledgeBlock(space);
            if (knowledge) parts.push(knowledge);
        }
        if (conv.seed) {
            parts.push('[earlier in this conversation]\n' + conv.seed);
        }
        return parts.length ? parts.join('\n\n') + '\n\n' : '';
    }

    function estimateCredits(text, settings, conv) {
        const model = (conv && conv.proModel) || settings.proModel;
        if (!model) return { tier: 'standard', low: 1, high: 1 };
        const size = String(text || '').length;
        const bump = size > 4000 ? 2 : size > 1200 ? 1 : 0;
        const low = model.credits || 1;
        const high = Math.max(low, (model.max || low) + bump);
        return { tier: 'pro', low, high };
    }

    const Chat = {
        onStatus: null,
        controller: null,

        _say(text) { if (this.onStatus) this.onStatus(text); },

        abort() {
            if (this.controller) {
                try { this.controller.abort(); } catch (_) { }
                this.controller = null;
                return true;
            }
            return false;
        },

        async send(conv, text, settings, options) {
            const opts = options || {};
            if (!PQ.botKey) { try { await PQ.resolveBot(); } catch (_) { } }
            if (Relays.connected === 0) {
                throw new Error(t('Not connected to any relay yet — your message cannot be published.'));
            }

            const anon = !!conv.anon && Anon.ready();
            const sender = anon ? Anon.sender() : null;
            const senderPubkey = anon ? sender.pubkey : Identity.pubkey;
            const selfKemPk = anon
                ? (Anon.kem() ? Anon.kem().publicKey : null)
                : Identity.kemPk;

            const repos = reposFor(conv);
            const attachments = opts.attachments || [];
            const attachText = attachments.map(a => Attach() ? Attach().wireBlock(a) : '').join('');
            const isFresh = /^\s*!\s*\S/.test(text);
            const firstTurn = Store.thread(conv.id).length === 0;
            const preamble = (firstTurn || isFresh) ? preambleFor(conv, repos) : '';
            const quoted = opts.quote
                ? `> ${String(opts.quote).replace(/\n/g, '\n> ')}\n\n`
                : '';
            const wireText = preamble + quoted + text + attachText;

            const botKem = PQ.botKey ? PQ.botKey.pk : null;
            // A continued leg is a new message on the wire, so it needs an id
            // of its own — reusing the first leg's would land it in the
            // de-duplicator and replay the answer we are trying to move past.
            const msgId = Wire.sharedId();
            const rumor = Wire.rumor(wireText, C.botPubkey, conv.rootId, msgId, senderPubkey);

            const wrap = await Wire.wrap(rumor, C.botPubkey, botKem, sender);
            const accepted = await Relays.publish(wrap, 5000);
            if (accepted === 0) {
                throw new Error(t('No relay accepted your message. Check your connection and try again.'));
            }

            // A ghost chat publishes nothing it does not have to. The wrap to
            // the bot is how the message gets there at all; the archive copy
            // and the reply's re-publish are for restoring a conversation
            // later, which is exactly what a ghost chat is refusing.
            const ghost = !!conv.ephemeral;
            if (!ghost) {
                try {
                    const selfWrap = await Wire.wrap(rumor, senderPubkey, selfKemPk, sender);
                    Relays.publish(selfWrap, 3000);
                } catch (_) { }
            }

            const model = conv.proModel || settings.proModel;
            // The turn is now identifiable, so anything watching it can start
            // before the answer comes back.
            if (typeof opts.onTurn === 'function') {
                try { opts.onTurn(wrap.id, anon ? Anon.signer() : null); } catch (_) { }
            }

            const extra = {
                eventId: wrap.id,
                fresh: isFresh
            };
            // Continuing a run that stopped at its tool-call cap. The token is
            // single-use and the worker only redeems it for the key that made
            // it, so nothing here is worth intercepting.
            if (opts.resume) extra.resume = opts.resume;
            const announcement = anon ? Anon.announcement() : PQ.selfAnnouncement;
            if (announcement) extra.pqAnnouncement = announcement;
            if (settings.webSearch || opts.web) extra.web = true;
            if (attachments.length) {
                extra.attachments = attachments.map(a => ({
                    kind: a.kind, name: a.name, mime: a.mime, size: a.size,
                    ...(a.kind === 'image' ? { dataUrl: a.dataUrl } : {})
                }));
            }
            if (model) {
                extra.proModel = model.key;
                if (repos.length) {
                    extra.git = repoPayload(repos[0]);
                    extra.repos = repos.map(repoPayload);
                }
            }

            const controller = opts.controller || new AbortController();
            const ownsController = !opts.controller;
            if (ownsController) this.controller = controller;
            let status, data;
            try {
                for (let tries = 0; ; tries++) {
                    ({ status, data } = await Api.call('pm', extra, {
                        timeout: C.pmTimeoutMs,
                        signer: anon ? Anon.signer() : null,
                        controller
                    }));
                    if (!data || !data.pending || tries >= 5) break;
                    this._say(t('Still working on that one…'));
                    await new Promise(r => setTimeout(r, 3000));
                }
            } finally {
                if (ownsController) this.controller = null;
            }

            if (data && data.pending) {
                throw new Error(data.message
                    || t('Nymbot is still working on that message — its reply will arrive shortly.'));
            }
            if (data && data.noCredits) {
                const err = new Error(data.error
                    || (data.pro ? t('You are out of Pro credits.') : t('You are out of credits.')));
                err.noCredits = true;
                err.pro = !!data.pro;
                err.balance = data.balance || 0;
                throw err;
            }
            if (status >= 400 || !data || data.error) {
                throw new Error((data && data.error) || t('The request failed.'));
            }
            if (!data.event) throw new Error(t('Nymbot sent no reply.'));

            if (!ghost) {
                Relays.publish(data.event, 3000);
                if (data.selfEvent && /^[0-9a-f]{64}$/i.test(data.selfEvent.id || '')) {
                    Relays.publish(data.selfEvent, 3000);
                }
            }

            const opened = await Wire.unwrap(data.event, anon ? Anon.recipient() : null);
            if (!opened || !opened.rumor) throw new Error(t('Nymbot replied, but this device could not decrypt it.'));

            const ids = Store.thread(conv.id);
            ids.push(wrap.id);
            if (data.selfEvent && data.selfEvent.id) ids.push(data.selfEvent.id);
            Store.setThread(conv.id, ids);

            if (conv.seed) Store.updateConversation(conv.id, { seed: null, silent: true });

            const split = splitThinking(opened.rumor.content || '');
            return {
                reply: split.body,
                thinking: split.thinking,
                cost: data.cost || 0,
                balance: typeof data.balance === 'number' ? data.balance : null,
                pro: !!data.pro,
                modelCalls: data.modelCalls || 1,
                lowBalance: !!data.lowBalance,
                // Set when the run hit its cap with work left. The token buys
                // one more leg; the client decides whether to spend it.
                truncated: !!data.truncated,
                resumeToken: data.resumeToken || null,
                nextReserve: data.nextReserve || 0,
                taskType: data.taskType || null,
                sources: Array.isArray(data.sources) ? data.sources : null,
                repos: repos.map(r => r.repo),
                eventId: wrap.id
            };
        },

        /// Runs one prompt past two models at once, each on a thread of its own
        /// so neither answer is in the other's context and the real chat is not
        /// touched until you keep one. Two replies, so two charges.
        async compare(conv, text, settings, models, options) {
            const opts = options || {};
            const runs = models.filter(Boolean).map(model => ({
                model,
                scratch: Object.assign({}, conv, {
                    id: 'cmp-' + Store.uid(),
                    rootId: Hex.hex(crypto.getRandomValues(new Uint8Array(32))),
                    proModel: model,
                    seed: opts.seed || conv.seed || null
                })
            }));
            if (runs.length < 2) throw new Error(t('Pick two models to compare.'));

            const controller = new AbortController();
            this.controller = controller;
            let settled;
            try {
                settled = await Promise.allSettled(runs.map(r => this.send(
                    r.scratch, text, settings,
                    { attachments: opts.attachments || [], quote: opts.quote, controller }
                )));
            } finally {
                this.controller = null;
                for (const r of runs) Store.dropThread(r.scratch.id);
            }

            return runs.map((r, i) => ({
                model: r.model,
                ok: settled[i].status === 'fulfilled',
                result: settled[i].status === 'fulfilled' ? settled[i].value : null,
                error: settled[i].status === 'rejected'
                    ? ((settled[i].reason && settled[i].reason.message) || t('The request failed.'))
                    : null
            }));
        },

        /// Asks the worker what the turn answering [eventId] is doing. Purely
        /// advisory: a failure returns nothing rather than disturbing the turn.
        async progress(eventId, after, opts) {
            const options = opts || {};
            try {
                const { data } = await Api.call('pm-progress',
                    { eventId, after: after || 0 },
                    { timeout: 8000, signer: options.signer || null });
                return Array.isArray(data && data.steps) ? data.steps : [];
            } catch (_) {
                return [];
            }
        },

        titleFor,
        splitThinking,
        reposFor,
        workspaceFor,
        botFor,
        knowledgeBlock,
        estimateCredits,
        preambleFor
    };

    window.NymbotChat = Chat;
})();
