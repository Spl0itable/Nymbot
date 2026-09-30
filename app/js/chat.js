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

    const CLEANUP_EVERY_MS = 6 * 60 * 60 * 1000;

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

    function followUpsOf(raw) {
        if (!Array.isArray(raw)) return null;
        const out = [];
        const seen = new Set();
        for (const item of raw) {
            if (typeof item !== 'string') continue;
            const text = item.replace(/\s+/g, ' ').trim();
            const key = text.toLowerCase();
            if (text.length < 2 || text.length > 80 || /^[?!/@]/.test(text)
                || /[<>\x00-\x1f\x7f]|https?:\/\//i.test(text) || seen.has(key)) continue;
            seen.add(key);
            out.push(text);
            if (out.length === 3) break;
        }
        return out.length ? out : null;
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

    // Knowledge is retrieved per message because the worker truncates historical turns.
    const KNOWLEDGE_CHUNK_MAX = 1200;
    const KNOWLEDGE_SEND_CAP = 5000;
    const KNOWLEDGE_FILE_CAP = 24000;

    // Knowledge contains blank lines, so the end of the per-turn context is marked explicitly for the worker to strip.
    const STANDING_END = '[end of standing context]';

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

    /// Own repositories first, then the workspace's, deduplicated.
    function reposFor(conv) {
        const space = workspaceFor(conv);
        const ids = (Array.isArray(conv.repoIds) ? conv.repoIds : [])
            .concat(space && Array.isArray(space.repoIds) ? space.repoIds : []);
        const seenId = new Set();
        const seenWhere = new Set();
        const out = [];
        for (const id of ids) {
            if (seenId.has(id)) continue;
            seenId.add(id);
            const repo = Store.repo(id);
            if (!repo || repo.enabled === false || !repo.token || !repo.repo) continue;
            const where = [repo.provider || 'github', repo.host || '',
                repo.repo, repo.branch || ''].join('|');
            if (seenWhere.has(where)) continue;
            seenWhere.add(where);
            out.push(repo);
        }
        return out;
    }

    /// Markdown headings are carried onto the passages beneath them.
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
            // Oversized paragraphs are cut rather than dropped; a long table or code block is often the answer.
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

    /// BM25 on device, deliberately not embeddings: no model call or download per message.
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

    /// When nothing matches, each file's opening goes instead.
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
            approve: !!repo.approve,
            jobBranches: window.NymbotGitRun.jobBranchesOn(repo),
            whenDone: window.NymbotGitRun.whenDoneFor(repo, Store.settings()),
            paths: repo.paths || '',
            label: repo.label || repo.repo,
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

    /// Sent every message; the worker strips these blocks from historical turns.
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
        const docText = window.NymbotDocs ? window.NymbotDocs.wireFor(conv, text, attachments) : '';
        const preamble = preambleFor(conv, repos, text);
        const quoted = opts.quote
            ? `> ${String(opts.quote).replace(/\n/g, '\n> ')}\n\n`
            : '';
        return preamble + quoted + text + attachText + docText;
    }

    function connectorsFor(conv) {
        return window.NymbotConnectors ? window.NymbotConnectors.forConv(conv) : [];
    }

    function repoNeedsPro(conv, settings) {
        return reposFor(conv || {}).length > 0
            && !((conv && conv.proModel) || (settings && settings.proModel));
    }

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
        // Past the marker because the seed is cleared after the first message and nothing re-sends it.
        if (conv.seed) {
            parts.push('[earlier in this conversation]\n' + conv.seed);
        }
        return parts.length ? parts.join('\n\n') + '\n\n' : '';
    }

    // Model calls per reply: careful plans first, deep also checks its answer; charged per call.
    const EFFORT = { normal: 1, careful: 2, deep: 3 };

    const BUSY_WAITS = [4000, 9000, 16000];
    const CLAIM_MS = 60 * 60 * 1000;
    const HEX64 = /^[0-9a-f]{64}$/;

    function validRuns(n) {
        const v = Number(n);
        return Number.isInteger(v) && v >= 1 ? Math.min(10, v) : null;
    }

    function policyFor(conv, settings) {
        const own = (conv && conv.policy) || {};
        const base = (settings && settings.policy) || {};
        const pick = (mine, fallback) => (mine === 'allow' || mine === 'ask') ? mine : (fallback === 'allow' ? 'allow' : 'ask');
        return {
            readOnlyTools: pick(own.readOnlyTools, base.readOnlyTools),
            serverRuns: pick(own.serverRuns, base.serverRuns)
        };
    }

    function linkOf(rumor, data) {
        const tag = rumor && Array.isArray(rumor.tags) ? rumor.tags.find(x => Array.isArray(x) && x[0] === 'nymreply') : null;
        const run = tag && HEX64.test(String(tag[1] || '')) ? String(tag[1]) : (data && HEX64.test(String(data.replyTo || '')) ? String(data.replyTo) : null);
        const leg = tag && HEX64.test(String(tag[2] || '')) ? String(tag[2]) : (data && HEX64.test(String(data.askedId || '')) ? String(data.askedId) : null);
        return { replyTo: run, askedId: leg };
    }

    function planOf(raw) {
        if (!Array.isArray(raw)) return null;
        const states = new Set(['planned', 'doing', 'done', 'skipped']);
        const out = raw.filter(x => x && typeof x.text === 'string' && x.text.trim())
            .slice(0, 20)
            .map(x => ({ text: x.text.replace(/\s+/g, ' ').trim().slice(0, 120), state: states.has(x.state) ? x.state : 'planned' }));
        return out;
    }

    const HELD_MAX = 8;
    const HELD_SEND = 4;
    const HELD_BYTES = 96 * 1024;
    const heldWraps = new Map();

    function holdWraps(convId, events) {
        if (!convId) return;
        const list = (heldWraps.get(convId) || []).concat(events.filter(e => e && /^[0-9a-f]{64}$/i.test(e.id || '')));
        heldWraps.set(convId, list.slice(-HELD_MAX));
    }

    function heldHistory(convId, threadIds) {
        const list = heldWraps.get(convId) || [];
        const want = new Set(threadIds || []);
        const out = [];
        let bytes = 0;
        for (let i = list.length - 1; i >= 0 && out.length < HELD_SEND; i--) {
            const e = list[i];
            if (!want.has(e.id)) continue;
            bytes += String(e.content || '').length;
            if (bytes > HELD_BYTES) break;
            out.unshift(e);
        }
        return out;
    }

    function pause(ms, signal) {
        return new Promise(resolve => {
            let timer = 0;
            const done = () => {
                clearTimeout(timer);
                if (signal) signal.removeEventListener('abort', done);
                resolve();
            };
            timer = setTimeout(done, ms);
            if (signal) signal.addEventListener('abort', done);
        });
    }

    function effortOf(conv) {
        const name = conv && conv.effort;
        return EFFORT[name] ? name : 'normal';
    }

    function effortCalls(conv) { return EFFORT[effortOf(conv)] || 1; }

    /// Each extra wrap costs a credit, so the surcharge is quoted before sending.
    function partSurcharge(conv, text, options) {
        const parts = Wire.split(wireTextFor(conv || {}, text || '', options || {})).length;
        return Math.max(0, parts - 1);
    }

    function estBudgets(pricing) {
        return (pricing && pricing.estimate) || {};
    }

    function estTokens(chars, b) {
        const per = Number(b && b.charsPerToken) > 0 ? Number(b.charsPerToken) : 4;
        return Math.ceil(Math.max(0, Number(chars) || 0) / per);
    }

    function estMessages(conv) {
        if (conv && Array.isArray(conv.messages)) return conv.messages;
        if (!conv || !conv.id || !Store || typeof Store.messages !== 'function') return [];
        const list = Store.messages(conv.id);
        return Array.isArray(list) ? list : [];
    }

    function estHistory(conv) {
        return estMessages(conv).filter(function (m) {
            return m && (m.role === 'self' || m.role === 'bot');
        }).map(function (m) {
            return { bot: m.role === 'bot', text: String((m.content != null ? m.content : m.text) || '') };
        }).filter(function (h) { return h.text; });
    }

    function estWindow(history, b) {
        const h = b.history;
        if (!h) return { chars: history.reduce(function (n, x) { return n + x.text.length; }, 0), kept: history, dropped: 0 };
        const recent = history.slice(-h.turns);
        let budget = h.chars;
        let chars = 0;
        const kept = [];
        for (let i = recent.length - 1; i >= 0; i--) {
            if (budget < h.turnMinChars) break;
            const len = Math.min(recent[i].text.length, h.turnChars, budget);
            budget -= len;
            chars += len;
            kept.unshift(recent[i]);
        }
        return { chars: chars, kept: kept, dropped: history.length - kept.length };
    }

    function estPattern(b, name) {
        const src = b.patterns && b.patterns[name];
        return src ? new RegExp(src, 'gi') : null;
    }

    function estUrls(text, b, bare, attached, max) {
        const out = [];
        const add = function (u) { if (u && out.indexOf(u) === -1 && out.length < max) out.push(u); };
        const tagged = estPattern(b, attached);
        let m;
        while (tagged && (m = tagged.exec(text)) !== null) add(m[1]);
        const plain = estPattern(b, bare);
        while (plain && (m = plain.exec(text)) !== null) add(m[0]);
        return out;
    }

    function estLinks(text, b) {
        const all = estPattern(b, 'link');
        const skip = b.patterns && b.patterns.linkSkip ? new RegExp(b.patterns.linkSkip, 'i') : null;
        const max = (b.links && b.links.pages) || 0;
        const out = [];
        let m;
        while (all && out.length < max && (m = all.exec(text)) !== null) {
            const url = m[0].replace(/[.,;:!?]+$/, '');
            if (skip && skip.test(url)) continue;
            if (out.indexOf(url) === -1) out.push(url);
        }
        return out.length;
    }

    function estMedia(wire, kept, model, b) {
        const canSee = model ? !!model.vision : true;
        if (!canSee) return { images: 0, videos: 0 };
        const maxImages = b.maxImages || 0;
        const video = b.video || {};
        const shown = estUrls(wire, b, 'image', 'attachedImage', maxImages).length;
        const clips = estUrls(wire, b, 'video', 'attachedVideo', video.max || 0).length;
        const watches = !!(model && model.video);
        const frames = !watches && clips ? Math.min(video.frames || 0, maxImages - shown) : 0;
        let room = maxImages - shown - frames;
        let videoRoom = watches ? (video.max || 0) - clips : 0;
        let images = shown + frames;
        let videos = watches ? clips : 0;
        const asked = kept.filter(function (h) { return !h.bot; }).slice(-(b.visionHistoryTurns || 0)).reverse();
        for (let i = 0; i < asked.length && (room > 0 || videoRoom > 0); i++) {
            const pics = Math.min(room, estUrls(asked[i].text, b, 'image', 'attachedImage', maxImages).length);
            const films = Math.min(videoRoom, watches ? estUrls(asked[i].text, b, 'video', 'attachedVideo', video.max || 0).length : 0);
            room -= pics;
            videoRoom -= films;
            images += pics;
            videos += films;
        }
        return { images: images, videos: videos };
    }

    function estInput(wire, history, model, web, b) {
        const tier = model ? 'pro' : 'standard';
        const win = estWindow(history, b);
        const media = estMedia(wire, win.kept, model, b);
        const video = b.video || {};
        const links = b.links || {};
        const recall = b.recall || {};
        const index = model && win.dropped
            ? Math.min(win.dropped, recall.indexMax || 0) * (recall.lineChars || 0) : 0;
        return {
            tokens: ((b.systemTokens && b.systemTokens[tier]) || 0) + (b.scaffoldTokens || 0)
                + estTokens(wire.length + win.chars + index, b)
                + media.images * (b.imageTokens || 0)
                + media.videos * (video.seconds || 0) * (video.tokensPerSecond || 0)
                + estLinks(wire, b) * estTokens(links.chars || 0, b)
                + (web ? ((b.webTokens && b.webTokens[tier]) || 0) : 0),
            dropped: win.dropped
        };
    }

    function estPrice(rates, inTok, outTok, legs, cached) {
        const pin = Number(rates.inUsdPerMTok);
        const pout = Number(rates.outUsdPerMTok);
        if (!(pin > 0) || !(pout > 0)) return null;
        const pcr = Number(rates.cacheReadUsdPerMTok) > 0 ? Number(rates.cacheReadUsdPerMTok) : pin * 0.1;
        const n = Math.max(1, legs);
        return (inTok * pin + inTok * (n - 1) * (cached ? pcr : pin)
            + outTok * n * pout + outTok * n * (n - 1) / 2 * pin) / 1e6;
    }

    function estTurn(opts) {
        const pricing = opts.pricing || {};
        const b = estBudgets(pricing);
        const model = opts.model || null;
        const cached = !!(model && model.cachesLegs === true);
        const floor = Number(pricing.minChargeCredits) || 0;
        const input = estInput(opts.wire, opts.history, model, opts.web, b);
        const agent = b.agent || {};
        const typicalOf = function (reasons, ceiling) {
            return Math.min(ceiling, reasons ? (b.reasoningOutTokens || 0) : (b.typicalOutTokens || 0));
        };
        const longOf = function (reasons, ceiling) {
            const long = reasons ? (b.reasoningLongOutTokens || 0) : (b.longOutTokens || 0);
            return Math.min(ceiling, long > 0 ? long : typicalOf(reasons, ceiling));
        };
        if (!model) {
            const usd = Number(pricing.standardUsdPerCredit) || 0;
            const routes = (pricing.standardRoutes || []).filter(function (r) { return estPrice(r, 1, 1, 1, false) != null; });
            if (!routes.length || !(usd > 0)) return null;
            const general = routes.filter(function (r) { return r.task === 'general'; });
            const usual = general.length ? general : routes;
            const priced = function (r, out) { return estPrice(r, input.tokens, out, 1, false) / usd; };
            const low = Math.max(floor, Math.min.apply(null, usual.map(function (r) { return priced(r, typicalOf(r.reasoning === true, r.maxTokens || 0)); })));
            const high = Math.max(low, Math.max.apply(null, usual.map(function (r) { return priced(r, longOf(r.reasoning === true, r.maxTokens || 0)); })));
            const max = Math.max(high, Math.max.apply(null, routes.map(function (r) { return priced(r, r.maxTokens || 0); })));
            return { low: low, high: high, max: max };
        }
        const usd = Number(pricing.usdPerCredit) || 0;
        if (!(usd > 0) || estPrice(model, 1, 1, 1, false) == null) return null;
        const ceiling = Number(model.outTokens) > 0 ? Number(model.outTokens) : (b.typicalOutTokens || 0);
        const reasons = model.reasoning === true;
        const lowLegs = opts.agent ? (agent.typicalCalls || 1) : opts.calls;
        const longLegs = opts.agent ? (agent.longCalls || lowLegs) : opts.calls;
        const maxLegs = opts.agent ? (agent.calls || 1)
            : opts.calls + (input.dropped ? ((b.recall && b.recall.calls) || 0) : 0);
        const workIn = input.tokens + (opts.agent ? (agent.toolTokens || 0) + (agent.treeTokens || 0) : 0);
        const low = Math.max(floor, estPrice(model, workIn, typicalOf(reasons, ceiling), lowLegs, cached) / usd);
        const high = Math.max(low, estPrice(model, workIn, longOf(reasons, ceiling), longLegs, cached) / usd);
        const max = Math.max(high, estPrice(model, input.tokens + (opts.agent ? (agent.inTokens || 0) : 0), ceiling, maxLegs, cached) / usd);
        return { low: low, high: high, max: max };
    }

    function catalogModel(saved, pricing) {
        if (!saved || !pricing || !Array.isArray(pricing.models)) return saved;
        const aliases = pricing.aliases || {};
        const find = (k) => pricing.models.find(m => m && m.key === k && (!m.kind || m.kind === 'chat'));
        const row = find(saved.key) || (aliases[saved.key] ? find(aliases[saved.key]) : null);
        return row ? Object.assign({}, saved, row) : saved;
    }

    function estimateCredits(text, settings, conv, options, pricing) {
        const extra = partSurcharge(conv, text, options);
        const model = catalogModel((conv && conv.proModel) || (settings && settings.proModel), pricing);
        const wire = wireTextFor(conv || {}, text || '', options || {});
        const web = !!((settings && settings.webSearch) || (options && options.web));
        const history = estHistory(conv);
        const unpriced = !!(pricing && pricing.priceUnavailable === true);
        if (!model) {
            const std = unpriced ? null : estTurn({ wire: wire, history: history, model: null, web: web, pricing: pricing });
            if (std) {
                return { tier: 'standard', low: std.low + extra, high: std.high + extra, max: std.max + extra,
                    parts: extra + 1, metered: true };
            }
            return { tier: 'standard', low: 1 + extra, high: 1 + extra, max: 1 + extra, parts: extra + 1, unpriced: unpriced };
        }
        const repoTask = reposFor(conv || {}).length > 0 || connectorsFor(conv || {}).length > 0;
        const calls = repoTask ? 1 : effortCalls(conv);
        const pro = unpriced ? null : estTurn({ wire: wire, history: history, model: model, web: web, pricing: pricing,
            calls: calls, agent: repoTask });
        if (pro) {
            return { tier: 'pro', low: pro.low + extra, high: pro.high + extra, max: pro.max + extra,
                calls, parts: extra + 1, repoTask, metered: true };
        }
        const size = String(text || '').length;
        const bump = size > 4000 ? 2 : size > 1200 ? 1 : 0;
        const base = (repoTask ? model.repoCredits : model.credits) || model.credits || 1;
        const worst = (repoTask ? model.repoMax : model.max) || model.max || base;
        const low = base * calls + extra;
        const high = Math.max(low, (worst + bump) * calls + extra);
        return { tier: 'pro', low, high, max: high, calls, parts: extra + 1, repoTask, unpriced: unpriced };
    }

    function estimateLine(est, amount) {
        const fmt = amount || function (v) { return String(v); };
        const pro = est.tier === 'pro';
        if (est.unpriced) {
            return pro ? t('— Pro credits (price unavailable right now)') : t('— standard credits (price unavailable right now)');
        }
        if (!est.metered) {
            if (pro) {
                return fmt(est.low) === fmt(est.high)
                    ? t('About {n} Pro credits', { n: fmt(est.low) })
                    : t('About {low}–{high} Pro credits', { low: fmt(est.low), high: fmt(est.high) });
            }
            return est.low === 1 ? t('1 standard credit') : t('{n} standard credits', { n: fmt(est.low) });
        }
        const top = Number(est.max) || 0;
        const low = fmt(est.low);
        const high = fmt(est.high);
        const max = fmt(top >= 1 ? Math.ceil(top) : top);
        const same = low === high;
        if (max === high) {
            if (pro) {
                return same ? t('About {n} Pro credits', { n: low }) : t('About {low}–{high} Pro credits', { low, high });
            }
            return same ? t('{n} standard credits', { n: low }) : t('About {low}–{high} standard credits', { low, high });
        }
        if (pro) {
            return same
                ? t('About {n} Pro credits (up to {max})', { n: low, max })
                : t('About {low}–{high} Pro credits (up to {max})', { low, high, max });
        }
        return same
            ? t('About {n} standard credits (up to {max})', { n: low, max })
            : t('About {low}–{high} standard credits (up to {max})', { low, high, max });
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

        /// Assembled exactly as `send` does, so the composer can price a message before committing it.
        wireTextFor(conv, text, options) {
            return wireTextFor(conv, text, options || {});
        },

        wireCost(conv, text, options) {
            const used = Wire.bodyCost(wireTextFor(conv, text, options || {}));
            const max = Wire.BODY_MAX * Wire.PARTS_MAX;
            return { used, max, over: Math.max(0, used - max) };
        },

        overLimitMessage,
        repoNeedsPro,
        partSurcharge,

        async send(conv, text, settings, options) {
            if (conv && conv.support) throw new Error(t('Support messages go to the developer, not to Nymbot.'));
            const opts = options || {};
            const say = (line) => {
                if (typeof opts.onStatus === 'function') opts.onStatus(line);
                else this._say(line);
            };
            const anon = !!conv.anon;
            const payer = anon ? Anon.bind(conv) : null;
            if (anon && !payer) {
                throw new Error(t('This chat is anonymous, but no throwaway key could be used on this device, so nothing was sent.'));
            }
            const signer = anon ? Anon.signer(payer) : null;
            const repos = reposFor(conv);
            if (repos.length && !opts.replay) this.cleanupSoon(conv);
            const ghost = !!conv.ephemeral;
            let prepared = opts.replay && opts.replay.extra ? opts.replay : null;
            if (!prepared) prepared = await this.prepare(conv, text, settings, opts, { anon, payer, repos, ghost });
            const extra = Object.assign({}, prepared.extra);
            const runs = validRuns(opts.maxRuns != null ? opts.maxRuns : settings && settings.maxRuns);
            if (runs) extra.maxRuns = runs;
            else delete extra.maxRuns;
            const replay = { extra: Object.assign({}, extra), msgId: prepared.msgId, isFresh: prepared.isFresh, partWraps: prepared.partWraps };
            if (typeof opts.onTurn === 'function') {
                try { opts.onTurn(extra.eventId, signer, { msgId: prepared.msgId, replay }); } catch (_) { }
            }

            const controller = opts.controller || new AbortController();
            const ownsController = !opts.controller;
            if (ownsController) this.controller = controller;
            const stoppedErr = () => {
                const err = new Error(t('Stopped.'));
                err.name = 'AbortError';
                err.stopped = true;
                return err;
            };
            const fail = (err, data) => {
                if (data && data.checkpoint) {
                    try { this.rememberBranches(conv, data.checkpoint); } catch (_) { }
                    err.checkpoint = data.checkpoint;
                }
                err.eventId = extra.eventId;
                err.msgId = prepared.msgId;
                err.replay = replay;
                if (data && HEX64.test(String(data.replyTo || ''))) err.replyTo = data.replyTo;
                return err;
            };
            let status, data;
            try {
                let waited = 0;
                let late = false;
                for (;;) {
                    let res = await Api.call('pm', extra, {
                        timeout: C.pmTimeoutMs,
                        signer,
                        controller,
                        onSlot: opts.onSlot
                    });
                    if (res.aborted || controller.signal.aborted) throw fail(stoppedErr());
                    if ((res.data && res.data.pending) || res.timedOut) {
                        late = true;
                        say(t('Still working on that one…'));
                        if (typeof opts.onClaiming === 'function') { try { opts.onClaiming(true); } catch (_) { } }
                        res = await this.claim(extra, { signer, controller, onSlot: opts.onSlot });
                        if (controller.signal.aborted) throw fail(stoppedErr());
                        if (typeof opts.onClaiming === 'function') { try { opts.onClaiming(false); } catch (_) { } }
                    }
                    ({ status, data } = res);
                    if (data && data.lost) {
                        const err = fail(new Error(t('Nymbot could not finish that one. Try again; it will not be charged twice.')));
                        err.late = true;
                        throw err;
                    }
                    if (data && data.runCap === true) break;
                    const failed = status >= 400 || !data || !!data.error;
                    if (!late && failed && !(data && data.noCredits) && waited < BUSY_WAITS.length
                        && Api.busy(status, data) && !controller.signal.aborted) {
                        const wait = BUSY_WAITS[waited++];
                        say(t('Too many requests just now — waiting {n} seconds rather than asking again straight away.',
                            { n: Math.round(wait / 1000) }));
                        await pause(wait, controller.signal);
                        if (controller.signal.aborted) throw fail(stoppedErr());
                        continue;
                    }
                    break;
                }
            } finally {
                if (ownsController && this.controller === controller) this.controller = null;
            }

            if (data && data.runCap === true) {
                const err = fail(new Error(data.error || t('The request failed.')), data);
                err.runCap = true;
                err.freeCap = data.free === true;
                err.running = Number(data.running) || 0;
                err.limit = Number(data.limit) || 0;
                err.ceiling = Number(data.ceiling) || 0;
                err.reserve = data.reserve && typeof data.reserve === 'object' ? data.reserve : null;
                err.balance = Number(data.balance) || 0;
                throw err;
            }
            if (data && data.noCredits) {
                const err = fail(new Error(data.error
                    || (data.pro ? t('You are out of Pro credits.') : t('You are out of credits.'))), data);
                err.noCredits = true;
                err.pro = !!data.pro;
                err.balance = data.balanceCredits != null
                    ? data.balanceCredits : (data.balance || 0);
                err.balanceCredits = data.balanceCredits;
                err.free = data.free || null;
                err.team = !!data.team;
                err.required = Number(data.required) || 0;
                throw err;
            }
            if (status >= 400 || !data || data.error) {
                const err = fail(new Error((data && data.error) || t('The request failed.')), data);
                if (!status && data && data.offline) err.offline = true;
                if (data && data.team) err.team = true;
                if (data && data.capExceeded) {
                    err.capExceeded = true;
                    err.required = Number(data.required) || 0;
                    err.pro = !!data.pro;
                }
                if (data && data.resumable && data.resumeToken) {
                    err.resumeToken = data.resumeToken;
                    err.resumable = true;
                }
                if (data && data.retryable) err.retryable = true;
                if (data && data.priceUnavailable) err.priceUnavailable = true;
                throw err;
            }
            return this.settle(conv, data, {
                anon, payer, ghost, repos, isFresh: prepared.isFresh, eventId: extra.eventId,
                msgId: prepared.msgId, partWraps: prepared.partWraps || []
            });
        },

        async prepare(conv, text, settings, opts, ctx) {
            if (!PQ.botKey) { try { await PQ.resolveBot(); } catch (_) { } }
            const { anon, payer, repos, ghost } = ctx;
            const sender = anon ? Anon.sender(payer) : null;
            const senderPubkey = anon ? sender.pubkey : Identity.pubkey;
            const payerKem = anon ? Anon.kem(payer) : null;
            const selfKemPk = anon
                ? (payerKem ? payerKem.publicKey : null)
                : (Identity.rootLocked || !Identity._kem ? null : Identity.kemPk);
            const attachments = opts.attachments || [];
            const isFresh = opts.fresh === true || /^\s*!\s*\S/.test(text);
            const wireText = wireTextFor(conv, text, opts);
            const bodies = Wire.split(wireText);
            if (bodies.length > Wire.PARTS_MAX) {
                throw new Error(overLimitMessage(wireText));
            }
            const botKem = PQ.botKey ? PQ.botKey.pk : null;
            const msgId = Wire.sharedId();
            if (typeof opts.onStep === 'function') {
                try { opts.onStep({ kind: 'stage', stage: 'encrypting', local: true }); } catch (_) { }
            }
            const partIds = [];
            const partWraps = [];
            let wrap = null;
            for (let i = 0; i < bodies.length; i++) {
                const rumor = Wire.rumor(bodies[i], C.botPubkey, conv.rootId, msgId, senderPubkey,
                    bodies.length > 1 ? { index: i + 1, of: bodies.length } : null);
                wrap = await Wire.wrap(rumor, C.botPubkey, botKem, sender);
                Relays.publish(wrap, 5000);
                partIds.push(wrap.id);
                partWraps.push(wrap);
                if (!ghost) {
                    try {
                        const selfWrap = await Wire.wrap(rumor, senderPubkey, selfKemPk, sender);
                        Relays.publish(selfWrap, 3000);
                    } catch (_) { }
                }
            }

            const model = conv.proModel || settings.proModel;
            const media = conv.mediaModel || settings.mediaModel;
            const extra = {
                eventId: wrap.id,
                wrap,
                fresh: isFresh,
                followUps: true,
                draft: true
            };
            if (!isFresh) {
                const handed = heldHistory(conv.id, Store.thread(conv.id));
                if (handed.length) extra.history = handed;
            }
            if (partIds.length > 1) {
                extra.parts = partIds;
                extra.wraps = partWraps;
            }
            if (opts.resume) extra.resume = opts.resume;
            if (anon) extra.anon = true;
            else if (opts.background && typeof opts.background === 'object') extra.background = opts.background;
            if (Number(opts.maxCost) > 0) extra.maxCost = Number(opts.maxCost);
            const proTurn = !!(model || (media && media.proKey));
            const connectors = window.NymbotConnectors && !conv.anon && proTurn && (!opts.research || opts.team)
                ? window.NymbotConnectors.payloadFor(conv) : [];
            if (connectors.length) extra.mcp = connectors;
            if (opts.mcpApprove) extra.mcpApprove = opts.mcpApprove;
            if (opts.mcpDecline) extra.mcpDecline = opts.mcpDecline;
            const announcement = anon ? Anon.announcement(payer) : PQ.selfAnnouncement;
            if (announcement) extra.pqAnnouncement = announcement;
            else if (!anon && (Identity.rootLocked || !PQ.selfKeys())) extra.pqClassical = true;
            if (settings.webSearch || opts.web) extra.web = true;
            if (attachments.length) {
                extra.attachments = attachments.map(a => ({
                    kind: a.kind, name: a.name, mime: a.mime, size: a.size,
                    ...(a.kind === 'image' ? { dataUrl: a.dataUrl } : {})
                }));
            }
            if (!model && media && media.proKey) extra.proModel = media.proKey;
            if (model) {
                extra.proModel = model.key;
                const effort = effortOf(conv);
                if (effort !== 'normal' && !repos.length && !connectors.length) extra.effort = effort;
                if (repos.length) {
                    extra.git = repoPayload(repos[0]);
                    extra.repos = repos.map(repoPayload);
                    if (conv.serverRuns || opts.serverRuns) extra.serverRuns = true;
                    if (opts.runApprove) extra.runApprove = opts.runApprove;
                    if (opts.runDecline) extra.runDecline = opts.runDecline;
                }
                if (opts.research) extra.research = opts.research;
                if (opts.team) extra.team = opts.team;
            }
            extra.policy = policyFor(conv, settings);
            if (opts.forkOf && typeof opts.forkOf === 'object' && HEX64.test(String(opts.forkOf.before || ''))) {
                extra.forkOf = { thread: String(opts.forkOf.thread || ''), before: String(opts.forkOf.before) };
            }
            if (opts.runKind === 'compare') extra.runKind = 'compare';
            return { extra, msgId, isFresh, partWraps };
        },

        async claim(extra, opts) {
            const options = opts || {};
            const controller = options.controller;
            const waits = Array.isArray(this.CLAIM_WAITS) && this.CLAIM_WAITS.length ? this.CLAIM_WAITS : [3000];
            const began = Date.now();
            let step = 0;
            let resent = false;
            while (!(controller && controller.signal.aborted) && Date.now() - began < CLAIM_MS) {
                const base = waits[Math.min(step, waits.length - 1)];
                const wait = step < waits.length ? base : Math.min(60000, base * Math.pow(2, step - waits.length + 1));
                step++;
                await pause(wait, controller ? controller.signal : null);
                if (controller && controller.signal.aborted) break;
                const res = await Api.claimRun(extra.eventId, { signer: options.signer, controller });
                if (res.aborted) break;
                if (res.status === 200 && res.data && !res.data.pending && !res.data.unknown) return res;
                if (res.status === 202 || (res.data && res.data.pending)) continue;
                if (res.status === 404 && res.data && res.data.unknown) return { status: 0, data: { lost: true } };
                if (res.status === 0 && !res.timedOut) continue;
                if (res.status === 400 || res.status === 403 || res.status === 405) {
                    if (resent) continue;
                    const again = await Api.call('pm', extra, { timeout: C.pmTimeoutMs, signer: options.signer, controller, onSlot: options.onSlot });
                    if (again.aborted) break;
                    if (again.data && again.data.pending) { resent = true; continue; }
                    if (again.timedOut) continue;
                    return again;
                }
                if (res.status >= 400) return res;
            }
            if (controller && controller.signal.aborted) return { status: 0, aborted: true, data: { error: t('Stopped.') } };
            return { status: 0, data: { lost: true } };
        },

        async settle(conv, data, ctx) {
            const { anon, payer, ghost } = ctx;
            if (!data.event) throw new Error(t('Nymbot sent no reply.'));
            if (!ghost) {
                Relays.publish(data.event, 3000);
                if (data.selfEvent && /^[0-9a-f]{64}$/i.test(data.selfEvent.id || '')) {
                    Relays.publish(data.selfEvent, 3000);
                }
            }
            const opened = anon
                ? await this.openReply(data.event, payer)
                : await Wire.unwrap(data.event, null, { from: C.botPubkey });
            if (!opened || !opened.rumor) throw new Error(t('Nymbot replied, but this device could not decrypt it.'));

            if (!ctx.isFresh && ctx.eventId) {
                const ids = Store.thread(conv.id);
                if (!ids.includes(ctx.eventId)) {
                    ids.push(ctx.eventId);
                    if (data.selfEvent && data.selfEvent.id) ids.push(data.selfEvent.id);
                    Store.setThread(conv.id, ids);
                }
                holdWraps(conv.id, (ctx.partWraps || []).concat(data.selfEvent ? [data.selfEvent] : []));
            }

            if (conv.seed) Store.updateConversation(conv.id, { seed: null, silent: true });

            const split = splitThinking(opened.rumor.content || '');
            const link = linkOf(opened.rumor, data);
            if (data.checkpoint) {
                try { this.rememberBranches(conv, data.checkpoint); } catch (_) { }
            }
            return {
                reply: split.body,
                thinking: split.thinking,
                cost: data.costCredits != null ? data.costCredits : (data.cost || 0),
                balance: typeof data.balance === 'number' ? data.balance : null,
                balanceCredits: typeof data.balanceCredits === 'number'
                    ? data.balanceCredits : null,
                dustMilli: typeof data.dustMilli === 'number' ? data.dustMilli : 0,
                pro: !!data.pro,
                modelCalls: data.modelCalls || 1,
                lowBalance: !!data.lowBalance,
                truncated: !!data.truncated,
                capStopped: !!data.capStopped,
                checkpoint: data.checkpoint || null,
                pendingTool: data.pendingTool || null,
                staged: data.staged && typeof data.staged === 'object' ? data.staged : null,
                stalled: !!data.stalled,
                retryAfterMs: Number(data.retryAfterMs) || 0,
                resumeToken: data.resumeToken || null,
                nextReserve: data.nextReserve || 0,
                background: data.background && typeof data.background === 'object' && HEX64.test(String(data.background.runId || ''))
                    ? { runId: String(data.background.runId), until: Number(data.background.until) || 0 } : null,
                research: !!data.research,
                taskType: data.taskType || null,
                modelLabel: data.modelLabel || null,
                modelKey: typeof data.proModel === 'string' ? data.proModel : null,
                sources: Array.isArray(data.sources) ? data.sources : null,
                team: data.team && typeof data.team === 'object' && Array.isArray(data.team.workers) ? data.team : null,
                followUps: followUpsOf(data.followUps),
                serverRuns: Array.isArray(data.serverRuns) && data.serverRuns.length ? data.serverRuns : null,
                serverRunCredits: Number(data.serverRunCredits) > 0 ? Number(data.serverRunCredits) : 0,
                free: data.free || null,
                repos: (ctx.repos || []).map(r => r.repo),
                stopped: data.stopped === true,
                plan: planOf(data.plan),
                replyTo: link.replyTo,
                askedId: link.askedId,
                msgId: ctx.msgId || null,
                eventId: ctx.eventId
            };
        },

        async claimStored(conv, eventId, opts) {
            const options = opts || {};
            const anon = !!conv.anon;
            const payer = anon ? Anon.forConv(conv) : null;
            const signer = payer ? Anon.signer(payer) : null;
            const res = await this.claim({ eventId }, { signer, controller: options.controller });
            if (res.aborted) {
                const err = new Error(t('Stopped.'));
                err.name = 'AbortError';
                err.stopped = true;
                throw err;
            }
            if (!res.data || res.data.lost || res.status !== 200) {
                const err = new Error(t('Nymbot could not finish that one. Try again; it will not be charged twice.'));
                err.late = true;
                err.eventId = eventId;
                throw err;
            }
            return this.settle(conv, res.data, {
                anon, payer, ghost: !!conv.ephemeral, repos: reposFor(conv), isFresh: !!options.isFresh,
                eventId, msgId: options.msgId || null, partWraps: []
            });
        },

        /// Each model runs on its own thread so neither sees the other; two replies, two charges.
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

            const controller = opts.controller || new AbortController();
            if (!opts.controller) this.controller = controller;
            let settled;
            try {
                settled = await Promise.allSettled(runs.map(r => this.send(
                    r.scratch, text, settings,
                    {
                        attachments: opts.attachments || [], quote: opts.quote, controller,
                        maxCost: opts.maxCost || null,
                        runKind: 'compare',
                        fresh: true
                    }
                )));
            } finally {
                if (this.controller === controller) this.controller = null;
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

        /// Advisory: a failure returns nothing rather than disturbing the turn.
        async progress(eventId, after, opts) {
            const options = opts || {};
            try {
                const { data } = await Api.call('pm-progress',
                    { eventId, after: after || 0, draftAfter: options.draftAfter || 0 },
                    { timeout: 8000, signer: options.signer || null });
                const draft = data && data.draft;
                if (typeof options.onDraft === 'function' && draft && typeof draft.text === 'string'
                    && Number(draft.seq) > 0) {
                    options.onDraft({ text: draft.text, seq: Number(draft.seq) });
                }
                const plan = planOf(data && data.plan);
                if (typeof options.onPlan === 'function' && plan) options.onPlan(plan);
                return Array.isArray(data && data.steps) ? data.steps : [];
            } catch (_) {
                return [];
            }
        },

        titleFor,
        splitThinking,
        policyFor,
        planOf,
        linkOf,
        validRuns,
        CLAIM_WAITS: [3000, 6000, 12000, 24000, 48000, 60000],
        followUpsOf,
        reposFor,
        connectorsFor,
        workspaceFor,
        botFor,
        knowledgeBlock,
        chunkFile,
        rankChunks,

        async openReply(event, identity) {
            for (const recipient of Anon.openers(identity, event)) {
                try {
                    const opened = await Wire.unwrap(event, recipient, { from: C.botPubkey });
                    if (opened && opened.rumor) return opened;
                } catch (_) { }
            }
            return null;
        },

        /// Reverts each written path to the pre-run commit; history is kept and no model is charged.
        async revert(conv, checkpoint) {
            const repos = reposFor(conv);
            const repo = repos.find(r => r.repo === checkpoint.repo) || repos[0];
            if (!repo) throw new Error(t('That repository is no longer connected.'));
            if (!repo.allowWrites) throw new Error(t('Writes are off for that repository.'));
            const anon = !!conv.anon;
            const signer = anon ? Anon.signer(Anon.forConv(conv)) : null;
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

        rememberBranches(conv, mark) {
            const GitRun = window.NymbotGitRun;
            const jobs = GitRun.jobsOf(mark);
            if (!jobs.length) return 0;
            const repos = reposFor(conv);
            let n = 0;
            for (const job of jobs) {
                const repo = repos.find(r => r.repo === job.repo);
                if (!repo || !job.sha) continue;
                Store.updateRepo(repo.id, { nymBranches: GitRun.remember(repo.nymBranches, job) });
                n++;
            }
            return n;
        },

        rememberBranchStep(step, conv) {
            const GitRun = window.NymbotGitRun;
            if (!step || !GitRun.isJobBranch(step.branch) || !/^[0-9a-f]{40,64}$/i.test(String(step.sha || ''))) return false;
            const pool = conv ? reposFor(conv) : Store.repos();
            const repo = pool.find(r => r.repo === step.repo && r.allowWrites);
            if (!repo) return false;
            const fresh = Store.repo(repo.id) || repo;
            const had = (fresh.nymBranches || []).find(r => r.branch === step.branch);
            if (had && had.sha === step.sha) return false;
            Store.updateRepo(repo.id, {
                nymBranches: GitRun.remember(fresh.nymBranches, {
                    branch: step.branch, base: step.base || (had && had.base) || '', sha: step.sha,
                    pull: had ? had.pull : null
                }, had ? had.at : undefined)
            });
            return true;
        },

        async branchOp(conv, repoName, op, job) {
            const repo = reposFor(conv).find(r => r.repo === repoName);
            if (!repo) throw new Error(t('That repository is no longer connected.'));
            if (!repo.allowWrites) throw new Error(t('Writes are off for that repository.'));
            const anon = !!conv.anon;
            const signer = anon ? Anon.signer(Anon.forConv(conv)) : null;
            const { status, data } = await Api.call('git-branch', {
                git: repoPayload(repo),
                op,
                branch: job.branch,
                base: job.base || '',
                sha: job.sha || '',
                pull: job.pull && job.pull.number ? { number: job.pull.number } : null
            }, { signer });
            const out = data || {};
            if (status >= 400 || out.error) {
                const err = new Error(out.error || t('The forge could not be reached.'));
                err.conflict = !!out.conflict;
                err.moved = !!out.moved;
                err.gone = !!out.gone;
                err.unsupported = !!out.unsupported;
                err.pull = out.pull || null;
                throw err;
            }
            const GitRun = window.NymbotGitRun;
            const fresh = Store.repo(repo.id) || repo;
            if (op === 'delete') {
                Store.updateRepo(repo.id, { nymBranches: GitRun.forget(fresh.nymBranches, [job.branch]) });
            } else if (out.sha && op === 'update') {
                Store.updateRepo(repo.id, { nymBranches: GitRun.remember(fresh.nymBranches, Object.assign({}, job, { sha: out.sha, pull: out.pull || job.pull })) });
            } else if (out.pull) {
                const had = (fresh.nymBranches || []).find(r => r.branch === job.branch);
                if (had) Store.updateRepo(repo.id, { nymBranches: GitRun.remember(fresh.nymBranches, Object.assign({}, had, { pull: out.pull })) });
            }
            return out;
        },

        async cleanupBranches(repo, opts) {
            const options = opts || {};
            const list = (repo && Array.isArray(repo.nymBranches)) ? repo.nymBranches.slice(-20) : [];
            if (!repo || !repo.allowWrites || !repo.token || !list.length) return { deleted: [], gone: [], kept: [] };
            const { status, data } = await Api.call('git-branch', {
                git: repoPayload(repo),
                op: 'cleanup',
                branches: list.map(r => ({ branch: r.branch, sha: r.sha, base: r.base, pull: r.pull, at: r.at }))
            }, { signer: options.signer || null });
            if (status >= 400 || !data || data.error) throw new Error((data && data.error) || t('The forge could not be reached.'));
            const done = (data.deleted || []).concat(data.gone || []);
            const fresh = Store.repo(repo.id) || repo;
            if (done.length) Store.updateRepo(repo.id, { nymBranches: window.NymbotGitRun.forget(fresh.nymBranches, done) });
            return data;
        },

        cleanupSoon(conv) {
            const now = Date.now();
            this._cleaned = this._cleaned || {};
            for (const repo of reposFor(conv)) {
                if (!repo.allowWrites || conv.anon || !(repo.nymBranches || []).length) continue;
                if (now - (this._cleaned[repo.id] || 0) < CLEANUP_EVERY_MS) continue;
                this._cleaned[repo.id] = now;
                this.cleanupBranches(repo).catch(() => { });
            }
        },

        async applyStaged(conv, staged) {
            const repos = reposFor(conv);
            const repo = repos.find(r => r.repo === staged.repo);
            if (!repo) throw new Error(t('That repository is no longer connected.'));
            if (!repo.allowWrites) throw new Error(t('Writes are off for that repository.'));
            const anon = !!conv.anon;
            const signer = anon ? Anon.signer(Anon.forConv(conv)) : null;
            const { status, data } = await Api.call('git-apply', {
                git: repoPayload(repo),
                staged: {
                    repo: staged.repo,
                    branch: staged.branch,
                    baseSha: staged.baseSha || null,
                    message: staged.message || '',
                    files: staged.files || []
                }
            }, { signer });
            if (status >= 400 || !data || data.error) {
                const err = new Error((data && data.error) || t('Could not apply those changes.'));
                err.conflict = (data && data.conflict) || null;
                throw err;
            }
            return data;
        },

        estimateCredits,
        estimateLine,
        estTurn,
        effortOf,
        effortCalls,
        EFFORT,
        preambleFor
    };

    window.NymbotChat = Chat;
})();
