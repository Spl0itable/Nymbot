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

    // Project knowledge is retrieved per message rather than poured into the
    // first one. The old caps sent up to 90,000 characters in turn one, where
    // the worker cut it to 1000 the moment it became history — so a workspace
    // stopped applying after a single reply. A few relevant passages, sent
    // every turn, are both smaller on the wire and actually there when the
    // question needs them.
    const KNOWLEDGE_CHUNK_MAX = 1200;
    const KNOWLEDGE_SEND_CAP = 5000;
    const KNOWLEDGE_FILE_CAP = 24000;

    // Marks where the context the client repeats every turn ends and the
    // message begins, so the worker can drop the repeats from historical
    // turns. A block of knowledge has blank lines in it, so the boundary
    // cannot be found by looking — it has to be written down.
    const STANDING_END = '[end of standing context]';

    // Words too common to say anything about which passage is wanted.
    const STOP_WORDS = new Set(('a an and are as at be but by can could did do does for from '
        + 'had has have how i if in is it its me my not of on or our so than that the their '
        + 'them then there these they this to was we were what when where which who why will '
        + 'with would you your').split(' '));

    function terms(text) {
        return String(text || '').toLowerCase().split(/[^a-z0-9]+/)
            .filter(w => w.length > 1 && !STOP_WORDS.has(w));
    }

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

    /// Splits one file into retrievable passages, on blank lines and headings,
    /// each under a ceiling. A markdown heading is carried onto the passages
    /// beneath it, so a passage still says what it is about once it has been
    /// lifted out of the file it came from.
    function chunkFile(file) {
        const body = String(file.body || '').slice(0, KNOWLEDGE_FILE_CAP);
        const name = file.name || 'untitled';
        const chunks = [];
        let heading = '';
        let buffer = [];
        let at = 0;

        const flush = () => {
            const text = buffer.join('\n\n').trim();
            buffer = [];
            if (!text) return;
            chunks.push({ file: name, at: at++, heading, text });
        };

        for (const para of body.split(/\n\s*\n/)) {
            const block = para.trim();
            if (!block) continue;
            const head = /^(#{1,6})\s+(.*)$/.exec(block.split('\n')[0]);
            if (head) {
                flush();
                heading = head[2].trim();
            }
            // A single paragraph over the ceiling is cut into pieces rather
            // than dropped: a long table or code block is often the answer.
            if (block.length > KNOWLEDGE_CHUNK_MAX) {
                flush();
                for (let i = 0; i < block.length; i += KNOWLEDGE_CHUNK_MAX) {
                    buffer.push(block.slice(i, i + KNOWLEDGE_CHUNK_MAX));
                    flush();
                }
                continue;
            }
            const running = buffer.join('\n\n').length;
            if (running + block.length > KNOWLEDGE_CHUNK_MAX) flush();
            buffer.push(block);
        }
        flush();
        return chunks;
    }

    /// Ranks passages against the question with BM25 over plain terms.
    ///
    /// Deliberately not embeddings: this runs on the device, for every message,
    /// with no model to call and nothing downloaded. Term overlap is weaker
    /// than a vector search and enormously better than sending the first
    /// 90,000 characters and hoping.
    function rankChunks(chunks, query) {
        const want = terms(query);
        if (!want.length || !chunks.length) return [];
        const K = 1.2;
        const B = 0.75;
        const docs = chunks.map(c => terms(c.heading + ' ' + c.text));
        const avg = docs.reduce((n, d) => n + d.length, 0) / docs.length || 1;
        const df = new Map();
        for (const doc of docs) {
            for (const term of new Set(doc)) df.set(term, (df.get(term) || 0) + 1);
        }
        const scored = chunks.map((chunk, i) => {
            const doc = docs[i];
            const freq = new Map();
            for (const term of doc) freq.set(term, (freq.get(term) || 0) + 1);
            let score = 0;
            for (const term of new Set(want)) {
                const tf = freq.get(term) || 0;
                if (!tf) continue;
                const n = df.get(term) || 0;
                const idf = Math.log(1 + (chunks.length - n + 0.5) / (n + 0.5));
                score += idf * (tf * (K + 1)) / (tf + K * (1 - B + B * doc.length / avg));
            }
            return { chunk, score };
        });
        return scored.filter(x => x.score > 0).sort((a, b) => b.score - a.score);
    }

    /// The passages of the workspace's files that bear on this question, plus
    /// the names of every file so the model knows what else it could be told
    /// about. When nothing matches, the opening of each file goes instead —
    /// enough to say what the project is rather than nothing at all.
    function knowledgeBlock(space, query) {
        const files = (space && space.files) || [];
        if (!files.length) return '';
        const chunks = [];
        for (const file of files) chunks.push(...chunkFile(file));
        if (!chunks.length) return '';

        let budget = KNOWLEDGE_SEND_CAP;
        const picked = [];
        const take = (chunk) => {
            if (picked.includes(chunk) || chunk.text.length > budget) return;
            budget -= chunk.text.length;
            picked.push(chunk);
        };
        for (const hit of rankChunks(chunks, query)) take(hit.chunk);
        if (!picked.length) {
            for (const file of files) {
                const first = chunks.find(c => c.file === (file.name || 'untitled'));
                if (first) take(first);
            }
        }
        if (!picked.length) return '';

        // Back into document order, so passages from one file read forwards.
        picked.sort((a, b) => a.file.localeCompare(b.file) || a.at - b.at);
        const names = files.map(f => f.name || 'untitled');
        const parts = [];
        let last = null;
        for (const chunk of picked) {
            const label = chunk.file + (chunk.heading ? ' — ' + chunk.heading : '');
            if (label !== last) parts.push('--- ' + label + ' ---');
            last = label;
            parts.push(chunk.text);
        }
        const partial = picked.length < chunks.length;
        return '[project knowledge]\n'
            + 'Files in this workspace: ' + names.join(', ') + '.\n'
            + (partial ? 'The passages below are the parts that match this question.\n' : '')
            + parts.join('\n\n');
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
            label: repo.label || repo.repo,
            // Where it was announced, when it was.
            ...(repo.ngit ? {
                ngit: {
                    naddr: repo.ngit.naddr || '',
                    repoId: repo.ngit.repoId || '',
                    name: repo.ngit.name || '',
                    web: repo.ngit.web || '',
                    maintainers: (repo.ngit.maintainers || []).slice(0, 8)
                }
            } : {})
        };
    }

    /// The context that holds for every message in a chat: who the bot is being,
    /// what it can read, and the part of the workspace that bears on what was
    /// just asked.
    ///
    /// Sent on every message rather than only the first. It used to go once, at
    /// the top of turn one, and the worker cut that turn to 1000 characters the
    /// moment it became history — so instructions and project knowledge stopped
    /// applying after a single reply, silently. The worker strips these blocks
    /// from historical turns, so repeating them costs one copy, not twenty.
    function standingContext(conv, repos, query) {
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
            const knowledge = knowledgeBlock(space, query);
            if (knowledge) parts.push(knowledge);
        }
        const Memory = window.NymbotMemory;
        if (Memory) {
            const remembered = Memory.block(conv, query);
            if (remembered) parts.push(remembered);
        }
        return parts;
    }

    function wireTextFor(conv, text, opts) {
        const repos = reposFor(conv);
        const attachments = opts.attachments || [];
        const attachText = attachments.map(a => Attach() ? Attach().wireBlock(a) : '').join('');
        const preamble = preambleFor(conv, repos, text);
        const quoted = opts.quote
            ? `> ${String(opts.quote).replace(/\n/g, '\n> ')}\n\n`
            : '';
        return preamble + quoted + text + attachText;
    }

    /// Says what is too big and by how much, rather than the byte count the
    /// crypto would have thrown. A file is named as the thing to move,
    /// because a workspace holds a document the wire cannot.
    function overLimitMessage(wireText) {
        const kb = Math.round(Wire.bodyCost(wireText) / 1024);
        const max = Math.round((Wire.BODY_MAX * Wire.PARTS_MAX) / 1024);
        return t('This message is {n} KB, and the most one question can carry is about {max} KB. Put a long file in a workspace instead, where the whole of it is searched rather than sent.', { n: kb, max: max });
    }

    function preambleFor(conv, repos, query) {
        const standing = standingContext(conv, repos, query);
        const parts = standing.length
            ? [standing.join('\n\n') + '\n\n' + STANDING_END]
            : [];
        // Past the marker, because nothing re-sends it: the client clears the
        // seed after the first message, so stripping it from history would
        // lose what the branch was branched from.
        if (conv.seed) {
            parts.push('[earlier in this conversation]\n' + conv.seed);
        }
        return parts.length ? parts.join('\n\n') + '\n\n' : '';
    }

    // How hard a reply is asked to think, as the number of model calls it takes.
    // A careful reply plans before it answers; a deep one also reads its answer
    // back against the question before sending it. Both are charged as what
    // they are — more model calls — so the price says what the work was.
    const EFFORT = { normal: 1, careful: 2, deep: 3 };

    function effortOf(conv) {
        const name = conv && conv.effort;
        return EFFORT[name] ? name : 'normal';
    }

    function effortCalls(conv) { return EFFORT[effortOf(conv)] || 1; }

    /// A question too long for one wrap travels as several, and the worker
    /// charges a credit for each extra one. Splitting is a transport detail,
    /// but the input it carries is real and the published price has never
    /// charged for input — so the surcharge is counted here too, against the
    /// same text, and quoted before it is spent rather than after.
    function partSurcharge(conv, text, options) {
        const parts = Wire.split(wireTextFor(conv || {}, text || '', options || {})).length;
        return Math.max(0, parts - 1);
    }

    function estimateCredits(text, settings, conv, options) {
        const extra = partSurcharge(conv, text, options);
        const model = (conv && conv.proModel) || settings.proModel;
        if (!model) return { tier: 'standard', low: 1 + extra, high: 1 + extra, parts: extra + 1 };
        const size = String(text || '').length;
        const bump = size > 4000 ? 2 : size > 1200 ? 1 : 0;
        // A repo task loops on its own budget and ignores the effort level.
        const calls = reposFor(conv || {}).length ? 1 : effortCalls(conv);
        const low = (model.credits || 1) * calls + extra;
        const high = Math.max(low, ((model.max || model.credits || 1) + bump) * calls + extra);
        return { tier: 'pro', low, high, calls, parts: extra + 1 };
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

        /// Exactly what `send` will put on the wire: the standing context, the
        /// quoted line, the message and the attachments, assembled the same
        /// way. Split out so the composer can price a message before it is
        /// committed to the transcript rather than after.
        wireTextFor(conv, text, options) {
            return wireTextFor(conv, text, options || {});
        },

        /// What the message would cost on the wire, and what is left.
        wireCost(conv, text, options) {
            const used = Wire.bodyCost(wireTextFor(conv, text, options || {}));
            const max = Wire.BODY_MAX * Wire.PARTS_MAX;
            return { used, max, over: Math.max(0, used - max) };
        },

        overLimitMessage,
        partSurcharge,

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
            // A '!' question is answered outside the conversation.
            const isFresh = opts.fresh === true || /^\s*!\s*\S/.test(text);
            const wireText = wireTextFor(conv, text, opts);
            // NIP-44 caps one plaintext, and a gift wrap holds two of them
            // nested, so a long message does not fit in one event. Rather than
            // refuse it, it travels as several — each tagged with where it
            // sits, all sharing one message id, joined back into one question
            // by the worker. What stays capped is how many: past that it is
            // not a message.
            const bodies = Wire.split(wireText);
            if (bodies.length > Wire.PARTS_MAX) {
                throw new Error(overLimitMessage(wireText));
            }

            const botKem = PQ.botKey ? PQ.botKey.pk : null;
            // A continued leg is a new message on the wire, so it needs an id
            // of its own — reusing the first leg's would land it in the
            // de-duplicator and replay the answer we are trying to move past.
            const msgId = Wire.sharedId();
            // A ghost chat publishes nothing it does not have to. The wrap to
            // the bot is how the message gets there at all; the archive copy
            // and the reply's re-publish are for restoring a conversation
            // later, which is exactly what a ghost chat is refusing.
            const ghost = !!conv.ephemeral;
            const partIds = [];
            let wrap = null;
            for (let i = 0; i < bodies.length; i++) {
                const rumor = Wire.rumor(bodies[i], C.botPubkey, conv.rootId, msgId, senderPubkey,
                    bodies.length > 1 ? { index: i + 1, of: bodies.length } : null);
                wrap = await Wire.wrap(rumor, C.botPubkey, botKem, sender);
                const accepted = await Relays.publish(wrap, 5000);
                if (accepted === 0) {
                    throw new Error(t('No relay accepted your message. Check your connection and try again.'));
                }
                partIds.push(wrap.id);
                if (!ghost) {
                    try {
                        const selfWrap = await Wire.wrap(rumor, senderPubkey, selfKemPk, sender);
                        Relays.publish(selfWrap, 3000);
                    } catch (_) { }
                }
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
            // Every event the question was split across, in order. The last is
            // `eventId`, which is what a single-event message has always sent
            // and what an older worker will still answer from.
            if (partIds.length > 1) extra.parts = partIds;
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
                // How hard this chat asked the reply to think. Only meaningful
                // on Pro, and only outside a repo task, which does its own
                // looping and is charged for that.
                const effort = effortOf(conv);
                if (effort !== 'normal' && !repos.length) extra.effort = effort;
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
                // Present when it was the day's free allowance that ran out
                // rather than a balance, which is a time rather than a wall.
                err.free = data.free || null;
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

            // A '!' question is answered without the conversation and stays out
            // of it, on this side as on the worker's: it was asked that way so
            // it would not become context. The chat still shows it.
            if (!isFresh) {
                const ids = Store.thread(conv.id);
                ids.push(wrap.id);
                if (data.selfEvent && data.selfEvent.id) ids.push(data.selfEvent.id);
                Store.setThread(conv.id, ids);
            }

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
                // What this reply changed in a repository, and where the
                // branch stood before it did.
                checkpoint: data.checkpoint || null,
                resumeToken: data.resumeToken || null,
                nextReserve: data.nextReserve || 0,
                taskType: data.taskType || null,
                sources: Array.isArray(data.sources) ? data.sources : null,
                // What the day's free allowance has left, when this reply came
                // out of it rather than out of a balance.
                free: data.free || null,
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
                    {
                        attachments: opts.attachments || [], quote: opts.quote, controller,
                        // Neither run touches the conversation's stored thread:
                        // the seed carries what was said, and the real chat is
                        fresh: true
                    }
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
        chunkFile,
        rankChunks,
        /// Puts a repo run back: each path the run wrote is read at the commit
        /// the branch stood on before it and committed as it was. A revert,
        /// not a rewrite — what the model did stays in the history, it is
        /// simply no longer the state of the branch. Costs nothing: it touches
        /// no model.
        async revert(conv, checkpoint) {
            const repos = reposFor(conv);
            const repo = repos.find(r => r.repo === checkpoint.repo) || repos[0];
            if (!repo) throw new Error(t('That repository is no longer connected.'));
            if (!repo.allowWrites) throw new Error(t('Writes are off for that repository.'));
            const anon = !!(conv.anon && Anon.ready());
            const signer = anon ? Anon.signer() : null;
            const { status, data } = await Api.call('pm-revert', {
                git: repoPayload(repo),
                checkpoint: {
                    repo: checkpoint.repo,
                    branch: checkpoint.branch,
                    baseSha: checkpoint.baseSha,
                    paths: checkpoint.paths || [],
                    branches: checkpoint.branches || [],
                    pulls: checkpoint.pulls || []
                }
            }, { signer });
            if (status >= 400 || !data || data.error) {
                throw new Error((data && data.error) || t('Could not put that back.'));
            }
            return data;
        },

        estimateCredits,
        effortOf,
        effortCalls,
        EFFORT,
        preambleFor
    };

    window.NymbotChat = Chat;
})();
