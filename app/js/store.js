(function () {
    'use strict';

    const P = window.NymbotConfig.storagePrefix;
    const MSG_CAP = 800;
    // A memory is one standing fact, not a transcript: short enough that a
    // handful of them cost a paragraph of context, and capped in number so the
    // list stays something a person can actually read through.
    const MEMORY_TEXT_CAP = 400;
    const MEMORY_MAX = 200;

    function read(key, fallback) {
        try {
            const raw = localStorage.getItem(P + key);
            return raw == null ? fallback : JSON.parse(raw);
        } catch (_) { return fallback; }
    }

    // Anything that wants to know when this device changed something.
    const QUIET = /^(?:draft_|thread_|sync_|free_)/;
    const watchers = [];

    function announce(key) {
        if (QUIET.test(key)) return;
        for (const fn of watchers) {
            try { fn(key); } catch (_) { }
        }
    }

    function write(key, value) {
        try {
            localStorage.setItem(P + key, JSON.stringify(value));
            announce(key);
            return true;
        } catch (_) { return false; }
    }

    function drop(key) {
        try { localStorage.removeItem(P + key); } catch (_) { }
        announce(key);
    }

    function uid() {
        const b = crypto.getRandomValues(new Uint8Array(8));
        return Array.from(b).map(x => x.toString(16).padStart(2, '0')).join('');
    }

    const DEFAULT_SETTINGS = {
        tier: 'standard',
        proModel: null,
        git: null,
        anon: false,
        anonAutoTop: true,
        anonAutoTopFloor: 10,
        anonAutoTopAmount: 25,
        anonAutoTopTier: 'both',
        autoDeleteDays: 0,
        // Whether a durable fact you mention in passing is offered to memory.
        // Explicit saves work either way; this is only the noticing.
        memoryCapture: true,
        // A repo task can stop at its tool-call cap with work left. This is
        // how much you are willing to spend letting it carry on: 0 is never,
        // -1 is whatever the balance holds.
        autoContinue: 0,
        showProgress: true,
        // Your settings, library and conversations, sealed to your own key and
        // kept where every device you sign in on can read them back.
        sync: true,
        theme: 'system',
        density: 'comfortable',
        fontScale: 1,
        bubbles: true,
        avatars: true,
        timestamps: true,
        typewriter: true,
        typewriterSpeed: 'normal',
        sendOnEnter: true,
        soundOnReply: false,
        hapticOnReply: true,
        autoSpeak: false,
        voiceUri: null,
        speechRate: 1,
        showReasoningByDefault: false,
        codeWrap: false,
        lineNumbers: false,
        reduceMotion: false,
        monospaceReplies: false,
        webSearch: false,
        showTokenEstimate: true,
        confirmSend: false,
        enterToSendOnMobile: false,
        sidebarGrouping: 'date',
        defaultPersona: null,
        defaultRepos: []
    };

    const DEFAULT_PERSONAS = [
        {
            id: 'builtin-engineer',
            builtin: true,
            icon: 'tools',
            name: 'Staff engineer',
            instructions: 'You are a meticulous staff software engineer. Prefer precise, working code over prose. Name the files and lines you mean. Call out edge cases, failure modes and the cheapest correct fix. Never invent APIs — say when you are unsure.'
        },
        {
            id: 'builtin-reviewer',
            builtin: true,
            icon: 'search',
            name: 'Code reviewer',
            instructions: 'Review the code as a demanding reviewer would. Report only real defects and concrete simplifications, most severe first, each with the failing scenario that proves it. No praise, no summary of what the code does.'
        },
        {
            id: 'builtin-writer',
            builtin: true,
            icon: 'pen',
            name: 'Editor',
            instructions: 'You are a ruthless editor. Cut every sentence that carries no information. Prefer plain words, active voice and concrete nouns. Preserve the author\'s meaning and voice exactly.'
        },
        {
            id: 'builtin-socratic',
            builtin: true,
            icon: 'graduation',
            name: 'Tutor',
            instructions: 'Teach by building the idea up from what the reader already knows. Give one worked example before any abstraction, check understanding with a single pointed question, and never dump a wall of definitions.'
        },
        {
            id: 'builtin-analyst',
            builtin: true,
            icon: 'chart',
            name: 'Analyst',
            instructions: 'Answer with structure: the claim, the evidence, the uncertainty. Quantify wherever a number exists. State explicitly which parts are estimates and what would change your mind.'
        },
        {
            id: 'builtin-terse',
            builtin: true,
            icon: 'terse',
            name: 'Terse',
            instructions: 'Answer in as few words as the question allows. No preamble, no restating the question, no closing offer of further help.'
        }
    ];

    const DEFAULT_PROMPTS = [
        { id: 'p-explain', title: 'Explain this code', body: 'Explain what this code does, then name the three things most likely to break it:\n\n```\n{{code}}\n```' },
        { id: 'p-review', title: 'Review a diff', body: 'Review this diff for correctness bugs and simplifications. Most severe first, each with a concrete failing case.\n\n```diff\n{{diff}}\n```' },
        { id: 'p-tests', title: 'Write tests', body: 'Write thorough tests for the following, covering the boundary and failure cases as well as the happy path:\n\n```\n{{code}}\n```' },
        { id: 'p-refactor', title: 'Refactor', body: 'Refactor this for clarity without changing behaviour. Show the diff and say what each change buys.\n\n```\n{{code}}\n```' },
        { id: 'p-commit', title: 'Commit message', body: 'Write a commit message for this diff: a subject under 60 characters in the imperative, then a body explaining why rather than what.\n\n```diff\n{{diff}}\n```' },
        { id: 'p-summarise', title: 'Summarise', body: 'Summarise the following in {{count}} bullet points, keeping every number and name intact:\n\n{{text}}' },
        { id: 'p-translate', title: 'Translate', body: 'Translate the following into {{language}}, preserving tone and formatting:\n\n{{text}}' },
        { id: 'p-brainstorm', title: 'Brainstorm', body: 'Give me {{count}} genuinely different approaches to {{goal}}. For each: the idea in one line, why it might win, and what would sink it.' }
    ];

    const Store = {
        uid,
        read,
        write,
        drop,

        /// Called with the storage key whenever this device changes something worth keeping.
        watch(fn) {
            watchers.push(fn);
            return () => {
                const at = watchers.indexOf(fn);
                if (at !== -1) watchers.splice(at, 1);
            };
        },

        DEFAULT_SETTINGS,
        DEFAULT_PERSONAS,

        identity() { return read('identity', null); },
        setIdentity(id) { return write('identity', id); },
        clearIdentity() { drop('identity'); },

        settings() {
            return Object.assign({}, DEFAULT_SETTINGS, read('settings', {}));
        },
        setSettings(patch) {
            const next = Object.assign(this.settings(), patch);
            write('settings', next);
            return next;
        },
        resetSettings() {
            drop('settings');
            return this.settings();
        },

        repos() {
            const list = read('repos', null);
            if (Array.isArray(list)) return list;
            const legacy = (read('settings', {}) || {}).git;
            if (legacy && legacy.repo && legacy.token) {
                const migrated = [Object.assign({ id: uid(), enabled: true }, legacy)];
                write('repos', migrated);
                return migrated;
            }
            return [];
        },

        saveRepos(list) {
            write('repos', list.slice(0, 40));
            return list;
        },

        repo(id) { return this.repos().find(r => r.id === id) || null; },

        addRepo(cfg) {
            const list = this.repos();
            const entry = Object.assign({ id: uid(), enabled: true, addedAt: Date.now() }, cfg);
            const at = list.findIndex(r =>
                r.repo === entry.repo && (r.host || '') === (entry.host || '') && r.provider === entry.provider);
            if (at === -1) list.push(entry);
            else { entry.id = list[at].id; list[at] = Object.assign(list[at], entry); }
            this.saveRepos(list);
            return entry;
        },

        updateRepo(id, patch) {
            const list = this.repos();
            const i = list.findIndex(r => r.id === id);
            if (i === -1) return null;
            list[i] = Object.assign(list[i], patch);
            this.saveRepos(list);
            return list[i];
        },

        deleteRepo(id) {
            this.bury(id);
            this.saveRepos(this.repos().filter(r => r.id !== id));
            for (const conv of this.conversations()) {
                if (Array.isArray(conv.repoIds) && conv.repoIds.includes(id)) {
                    this.updateConversation(conv.id, { repoIds: conv.repoIds.filter(x => x !== id) });
                }
            }
        },

        personas() {
            const custom = read('personas', []);
            return DEFAULT_PERSONAS.concat(Array.isArray(custom) ? custom : []);
        },

        customPersonas() {
            const custom = read('personas', []);
            return Array.isArray(custom) ? custom : [];
        },

        persona(id) { return this.personas().find(p => p.id === id) || null; },

        savePersona(persona) {
            const list = this.customPersonas();
            const entry = Object.assign({ id: persona.id || uid() }, persona, { builtin: false });
            // Anything stored before the icon set existed carried an emoji.
            if (!entry.icon || !/^[a-z]+$/.test(entry.icon)) entry.icon = 'robot';
            delete entry.emoji;
            const i = list.findIndex(p => p.id === entry.id);
            if (i === -1) list.push(entry); else list[i] = entry;
            write('personas', list.slice(0, 60));
            return entry;
        },

        deletePersona(id) {
            this.bury(id);
            write('personas', this.customPersonas().filter(p => p.id !== id));
            for (const conv of this.conversations()) {
                if (conv.personaId === id) this.updateConversation(conv.id, { personaId: null });
            }
        },

        prompts() {
            const stored = read('prompts', null);
            if (Array.isArray(stored)) return stored;
            write('prompts', DEFAULT_PROMPTS);
            return DEFAULT_PROMPTS.slice();
        },

        savePrompt(prompt) {
            const list = this.prompts();
            const entry = Object.assign({ id: prompt.id || uid() }, prompt);
            const i = list.findIndex(p => p.id === entry.id);
            if (i === -1) list.unshift(entry); else list[i] = entry;
            write('prompts', list.slice(0, 200));
            return entry;
        },

        deletePrompt(id) {
            this.bury(id);
            write('prompts', this.prompts().filter(p => p.id !== id));
        },

        folders() {
            const list = read('folders', []);
            return Array.isArray(list) ? list : [];
        },

        saveFolder(folder) {
            const list = this.folders();
            const entry = Object.assign({ id: folder.id || uid() }, folder);
            const i = list.findIndex(f => f.id === entry.id);
            if (i === -1) list.push(entry); else list[i] = entry;
            write('folders', list.slice(0, 100));
            return entry;
        },

        deleteFolder(id) {
            this.bury(id);
            write('folders', this.folders().filter(f => f.id !== id));
            for (const conv of this.conversations()) {
                if (conv.folderId === id) this.updateConversation(conv.id, { folderId: null });
            }
        },

        schedules() {
            const list = read('schedules', []);
            return Array.isArray(list) ? list : [];
        },

        schedule(id) { return this.schedules().find(s => s.id === id) || null; },

        saveSchedule(entry) {
            const list = this.schedules();
            const next = Object.assign({
                id: uid(), title: '', prompt: '', repeat: 'once',
                convId: null, nextAt: Date.now(), lastRunAt: 0, lastError: '',
                enabled: true, runs: 0, createdAt: Date.now()
            }, entry);
            if (!next.id) next.id = uid();
            const i = list.findIndex(s => s.id === next.id);
            if (i === -1) list.push(next); else list[i] = next;
            write('schedules', list.slice(0, 40));
            return next;
        },

        deleteSchedule(id) {
            this.bury(id);
            write('schedules', this.schedules().filter(s => s.id !== id));
        },

        /// What Nymbot has been told to remember about you: standing facts, kept
        /// as separate readable entries rather than one summary, so each can be
        /// read, corrected or thrown away on its own. Never leaves the device
        /// except as the handful of entries that bear on a question.
        memories() {
            const list = read('memories', []);
            return Array.isArray(list) ? list : [];
        },

        memory(id) { return this.memories().find(m => m.id === id) || null; },

        saveMemory(memory) {
            const list = this.memories();
            const entry = Object.assign({
                id: uid(), text: '', topic: '', scope: null,
                source: 'you', convId: null, createdAt: Date.now()
            }, memory);
            if (!entry.id) entry.id = uid();
            entry.text = String(entry.text || '').trim().slice(0, MEMORY_TEXT_CAP);
            entry.topic = String(entry.topic || '').trim().slice(0, 60);
            entry.updatedAt = Date.now();
            if (!entry.text) return null;
            // The same fact told twice is one fact. Matching on the text keeps
            // a chat that repeats itself from filling memory with copies.
            const same = list.findIndex(m => m.id !== entry.id
                && m.scope === entry.scope
                && m.text.toLowerCase() === entry.text.toLowerCase());
            if (same !== -1) list.splice(same, 1);
            const at = list.findIndex(m => m.id === entry.id);
            if (at === -1) list.unshift(entry); else list[at] = entry;
            write('memories', list.slice(0, MEMORY_MAX));
            return entry;
        },

        deleteMemory(id) {
            this.bury(id);
            write('memories', this.memories().filter(m => m.id !== id));
        },

        clearMemories(scope) {
            write('memories', scope === undefined
                ? []
                : this.memories().filter(m => m.scope !== scope));
        },

        workspaces() {
            const list = read('workspaces', []);
            return Array.isArray(list) ? list : [];
        },

        workspace(id) { return this.workspaces().find(w => w.id === id) || null; },

        saveWorkspace(workspace) {
            const list = this.workspaces();
            const entry = Object.assign({
                id: uid(), name: '', instructions: '', files: [],
                repoIds: [], personaId: null, createdAt: Date.now()
            }, workspace);
            if (!entry.id) entry.id = uid();
            entry.updatedAt = Date.now();
            entry.files = (entry.files || []).slice(0, 40);
            entry.repoIds = (entry.repoIds || []).slice(0, 40);
            const i = list.findIndex(w => w.id === entry.id);
            if (i === -1) list.push(entry); else list[i] = entry;
            write('workspaces', list.slice(0, 40));
            return entry;
        },

        deleteWorkspace(id) {
            this.bury(id);
            write('workspaces', this.workspaces().filter(w => w.id !== id));
            for (const conv of this.conversations()) {
                if (conv.workspaceId === id) {
                    this.updateConversation(conv.id, { workspaceId: null, silent: true });
                }
            }
        },

        conversations() {
            const list = read('conversations', []);
            return Array.isArray(list) ? list : [];
        },

        saveConversations(list) {
            write('conversations', list.slice(0, 500));
        },

        conversation(id) {
            return this.conversations().find(c => c.id === id) || null;
        },

        createConversation(patch) {
            const conv = Object.assign({
                id: uid(),
                title: '',
                createdAt: Date.now(),
                updatedAt: Date.now(),
                pinned: false,
                archived: false,
                folderId: null,
                tags: [],
                repoIds: [],
                personaId: null,
                workspaceId: null,
                botId: null,
                systemPrompt: '',
                proModel: null,
                seed: null,
                stats: { messages: 0, credits: 0 }
            }, patch || {});
            const list = this.conversations();
            list.unshift(conv);
            this.saveConversations(list);
            return conv;
        },

        updateConversation(id, patch) {
            const list = this.conversations();
            const i = list.findIndex(c => c.id === id);
            if (i === -1) return null;
            const bump = patch && patch.silent ? false : true;
            if (patch) delete patch.silent;
            list[i] = Object.assign(list[i], patch, bump ? { updatedAt: Date.now() } : {});
            const conv = list[i];
            if (bump) {
                list.splice(i, 1);
                list.unshift(conv);
            }
            this.saveConversations(list);
            return conv;
        },

        deleteConversation(id) {
            this.bury(id);
            this._ghosts.delete(id);
            if (window.NymbotArtifacts) window.NymbotArtifacts._ghosts.delete(id);
            this.saveConversations(this.conversations().filter(c => c.id !== id));
            drop('msgs_' + id);
            drop('thread_' + id);
            drop('draft_' + id);
            drop('artifacts_' + id);
        },

        duplicateConversation(id, title) {
            const source = this.conversation(id);
            if (!source) return null;
            const copy = this.createConversation({
                title: title || source.title,
                anon: source.anon,
                ephemeral: source.ephemeral,
                folderId: source.folderId,
                tags: (source.tags || []).slice(),
                repoIds: (source.repoIds || []).slice(),
                personaId: source.personaId,
                workspaceId: source.workspaceId || null,
                botId: source.botId || null,
                systemPrompt: source.systemPrompt,
                proModel: source.proModel,
                rootId: window.NymbotHex.hex(crypto.getRandomValues(new Uint8Array(32)))
            });
            this.saveMessages(copy.id, this.messages(id));
            return copy;
        },

        /// Ghost chats live here and nowhere else: the map goes when the tab
        /// does, which is the whole promise.
        _ghosts: new Map(),

        /// A record this device deleted, remembered for long enough that every
        /// other device has been online since.
        bury(id) {
            if (!id) return;
            const Sync = window.NymbotSync;
            if (Sync && typeof Sync.bury === 'function') Sync.bury(id);
        },

        /// Either signal is enough.
        isGhost(convId) {
            if (this._ghosts.has(convId)) return true;
            const conv = this.conversations().find(c => c.id === convId);
            return !!(conv && conv.ephemeral);
        },

        messages(convId) {
            if (this.isGhost(convId)) return (this._ghosts.get(convId) || []).slice();
            const list = read('msgs_' + convId, []);
            return Array.isArray(list) ? list : [];
        },

        saveMessages(convId, list) {
            const kept = list.slice(-MSG_CAP);
            if (this.isGhost(convId)) {
                this._ghosts.set(convId, kept);
                drop('msgs_' + convId);
                return;
            }
            this._ghosts.delete(convId);
            write('msgs_' + convId, kept);
        },

        /// Moves what a chat has already said into memory and off the disk,
        /// which is what turning ghost mode on part-way through has to mean.
        makeGhost(convId) {
            const list = read('msgs_' + convId, []);
            this._ghosts.set(convId, Array.isArray(list) ? list : []);
            drop('msgs_' + convId);
            const Artifacts = window.NymbotArtifacts;
            if (Artifacts) {
                const lifted = read('artifacts_' + convId, []);
                Artifacts._ghosts.set(convId, Array.isArray(lifted) ? lifted : []);
                drop('artifacts_' + convId);
            }
        },

        /// Writes a ghost chat back, so turning the mode off keeps what is on
        /// screen rather than dropping it.
        unmakeGhost(convId) {
            const kept = this._ghosts.get(convId) || [];
            this._ghosts.delete(convId);
            write('msgs_' + convId, kept.slice(-MSG_CAP));
            const Artifacts = window.NymbotArtifacts;
            if (Artifacts) {
                const lifted = Artifacts._ghosts.get(convId) || [];
                Artifacts._ghosts.delete(convId);
                write('artifacts_' + convId, lifted);
            }
        },

        /// Two sweeps, both at startup: a ghost chat has nothing left to show
        /// once the tab it lived in is gone, and a chat older than the
        /// auto-delete window is one you have already said you do not want.
        sweepOldChats(days) {
            const cutoff = Date.now() - (days || 0) * 86400000;
            const doomed = this.conversations().filter(c => c.ephemeral
                || (days > 0 && !c.pinned && (c.updatedAt || 0) < cutoff));
            for (const conv of doomed) this.deleteConversation(conv.id);
            return doomed.length;
        },

        addMessage(convId, msg) {
            const list = this.messages(convId);
            list.push(msg);
            this.saveMessages(convId, list);
            return msg;
        },

        patchMessage(convId, msgId, patch) {
            const list = this.messages(convId);
            const i = list.findIndex(m => m.id === msgId);
            if (i === -1) return null;
            list[i] = Object.assign(list[i], patch);
            this.saveMessages(convId, list);
            return list[i];
        },

        deleteMessage(convId, msgId) {
            this.saveMessages(convId, this.messages(convId).filter(m => m.id !== msgId));
        },

        truncateFrom(convId, msgId, inclusive) {
            const list = this.messages(convId);
            const i = list.findIndex(m => m.id === msgId);
            if (i === -1) return list;
            const kept = list.slice(0, inclusive ? i : i + 1);
            this.saveMessages(convId, kept);
            return kept;
        },

        pinnedMessages() {
            const out = [];
            for (const conv of this.conversations()) {
                for (const m of this.messages(conv.id)) {
                    if (m.pinned) out.push({ conv, message: m });
                }
            }
            return out.sort((a, b) => (b.message.ts || 0) - (a.message.ts || 0));
        },

        searchAll(term, options) {
            const opts = options || {};
            const needle = String(term || '').toLowerCase().trim();
            if (!needle) return [];
            const out = [];
            for (const conv of this.conversations()) {
                if (!opts.includeArchived && conv.archived) continue;
                if ((conv.title || '').toLowerCase().includes(needle)) {
                    out.push({ conv, message: null, excerpt: conv.title });
                }
                for (const m of this.messages(conv.id)) {
                    const body = (m.content || '').toLowerCase();
                    const at = body.indexOf(needle);
                    if (at === -1) continue;
                    const from = Math.max(0, at - 40);
                    out.push({
                        conv,
                        message: m,
                        excerpt: (from > 0 ? '…' : '') + m.content.slice(from, at + needle.length + 80).trim()
                    });
                    if (out.length > 300) return out;
                }
            }
            return out;
        },

        draft(convId) { return read('draft_' + convId, '') || ''; },
        setDraft(convId, text) {
            if (!text) drop('draft_' + convId);
            else write('draft_' + convId, text);
        },

        thread(convId) {
            const ids = read('thread_' + convId, []);
            return Array.isArray(ids) ? ids : [];
        },

        setThread(convId, ids) {
            write('thread_' + convId, ids.slice(-40));
        },

        dropThread(convId) { drop('thread_' + convId); },

        usage() {
            return Object.assign({ credits: 0, replies: 0, since: Date.now() }, read('usage', {}));
        },

        recordUsage(cost) {
            const u = this.usage();
            u.credits += cost || 0;
            u.replies += 1;
            write('usage', u);
            return u;
        },

        exportAll() {
            return {
                version: 2,
                exportedAt: Date.now(),
                settings: this.settings(),
                folders: this.folders(),
                personas: this.customPersonas(),
                prompts: this.prompts(),
                workspaces: this.workspaces(),
                memories: this.memories(),
                schedules: this.schedules(),
                bots: (function () { const b = read('bots', []); return Array.isArray(b) ? b : []; })(),
                conversations: this.conversations().map(c => ({
                    conversation: c,
                    messages: this.messages(c.id)
                }))
            };
        },

        importAll(payload, mode) {
            if (!payload || !Array.isArray(payload.conversations)) throw new Error('unreadable');
            if (mode === 'replace') {
                for (const c of this.conversations()) this.deleteConversation(c.id);
            }
            if (Array.isArray(payload.folders)) write('folders', payload.folders);
            if (Array.isArray(payload.personas)) write('personas', payload.personas);
            if (Array.isArray(payload.prompts)) write('prompts', payload.prompts);
            if (Array.isArray(payload.workspaces)) write('workspaces', payload.workspaces);
            if (Array.isArray(payload.memories)) write('memories', payload.memories);
            if (Array.isArray(payload.schedules)) write('schedules', payload.schedules);
            if (Array.isArray(payload.bots)) write('bots', payload.bots);
            let count = 0;
            const list = this.conversations();
            for (const entry of payload.conversations) {
                const conv = Object.assign({}, entry.conversation, { id: uid() });
                list.unshift(conv);
                this.saveMessages(conv.id, Array.isArray(entry.messages) ? entry.messages : []);
                count++;
            }
            this.saveConversations(list);
            return count;
        },

        wipe() {
            const keys = [];
            for (let i = 0; i < localStorage.length; i++) {
                const k = localStorage.key(i);
                if (k && k.startsWith(P)) keys.push(k);
            }
            for (const k of keys) localStorage.removeItem(k);
        }
    };

    window.NymbotStore = Store;
})();
