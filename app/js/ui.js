(function () {
    'use strict';

    const C = window.NymbotConfig;
    const Store = window.NymbotStore;
    const Identity = window.NymbotIdentity;
    const Relays = window.NymbotRelays;
    const PQ = window.NymbotPQ;
    const Api = window.NymbotApi;
    const Anon = window.NymbotAnon;
    const Chat = window.NymbotChat;
    const MD = window.NymbotMarkdown;
    const QR = window.NymbotQR;
    const Avatar = window.NymbotAvatar;
    const Attach = window.NymbotAttach;
    const Bots = window.NymbotBots;
    const Commands = window.NymbotCommands;
    const Speech = window.NymbotSpeech;
    const Exporter = window.NymbotExport;
    const Icons = window.NymbotIcons;
    const Profile = window.NymbotProfile;
    const Artifacts = window.NymbotArtifacts;
    const NT = () => window.NostrTools;

    const $ = (id) => document.getElementById(id);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };

    const BOT_SUFFIX = C.botPubkey.slice(-4);
    const MODIFIER = /Mac|iPhone|iPad/.test(navigator.platform || '') ? 'Cmd' : 'Ctrl';

    const shortcuts = () => [
        { keys: [MODIFIER, 'K'], what: t('Command palette') },
        { keys: [MODIFIER, 'Shift', 'F'], what: t('Search every chat') },
        { keys: [MODIFIER, 'F'], what: t('Find in this chat') },
        { keys: [MODIFIER, 'N'], what: t('New chat') },
        { keys: [MODIFIER, 'B'], what: t('Show or hide the chat list') },
        { keys: [MODIFIER, 'Enter'], what: t('Send, whatever the Enter setting is') },
        { keys: [MODIFIER, 'Shift', 'C'], what: t('Copy the last reply') },
        { keys: [MODIFIER, 'Shift', 'S'], what: t('Ask the last question again') },
        { keys: [MODIFIER, 'Shift', 'M'], what: t('Pick a model') },
        { keys: [MODIFIER, 'Shift', 'G'], what: t('Repositories') },
        { keys: [MODIFIER, 'Shift', 'P'], what: t('Prompt library') },
        { keys: ['Shift', 'Esc'], what: t('Stop the reply') },
        { keys: ['\u2191'], what: t('Edit your last message, from an empty composer') },
        { keys: ['Esc'], what: t('Close whatever is open') },
        { keys: ['?'], what: t('Commands, typed at the start of a message') }
    ];

    const starters = () => [
        { title: t('Explain something'), body: t('Explain ML-KEM in three sentences, then tell me what it does not protect.') },
        { title: t('Work in a repo'), body: t('Read the repositories I connected and tell me where the retry logic gives up too early.') },
        { title: t('Write code'), body: t('Write a small, dependency-free function that debounces an async call and cancels the pending one.') },
        { title: t('Draft something'), body: t('Draft a short, plain-spoken release note for a change that made the app twice as fast to start.') },
        { title: t('Compare options'), body: t('Give me three genuinely different ways to store 200 MB of user data offline in a browser, with what sinks each.') },
        { title: t('Generate a picture'), body: '?image a lighthouse at dusk, long exposure, muted palette' }
    ];

    const UI = {
        conv: null,
        settings: Store.settings(),
        models: null,
        balance: { standard: null, pro: null },
        sending: false,
        invoice: null,
        attachments: [],
        quote: null,
        editing: null,
        convFilter: 'all',
        modelFilter: 'all',
        favourites: [],
        findMatches: [],
        findAt: 0,
        paletteAt: 0,
        paletteRows: [],
        suggestAt: 0,
        suggestRows: [],
        repoEditing: null,
        artifact: null,
        artifactTab: 'preview',
        compare: null,
        stopped: false,
        _turnWatch: null,
        personaEditing: null,
        workspaceEditing: null,
        workspaceDraft: null,
        scheduleEditing: null,
        _schedulerTimer: null,
        botEditing: null,
        botIcon: 'robot',
        sharingBot: null,
        pendingBot: null,
        personaIcon: 'robot',
        promptEditing: null,
        _lastGroup: null,
        _lastKey: null,

        // --- boot -----------------------------------------------------------

        async start() {
            // The pack decides what every string below reads as, so nothing is
            // rendered until it has landed (or failed, which is English).
            await window.NymbotI18n.ready;
            this.favourites = Store.read('favouriteModels', []) || [];
            const brand = $('brand');
            brand.appendChild(Icons.wordmark({ size: 26 }));
            brand.appendChild(el('span', 'brand-name', 'nymbot'));
            this.applyAppearance();
            this.bind();
            Anon.load();
            Anon.onKeysetChange = () => this.ask({
                title: t('Voucher keys changed'),
                body: t('Nymbot\'s voucher signing keys changed since you last moved credits.\n\nThat happens on a legitimate key rotation, but it is also what a server would do to tag your vouchers. Continue anyway?'),
                confirm: t('Continue'),
                danger: true
            });

            if (!Identity.restore()) {
                $('gate').hidden = false;
                if (window.nostr) $('gateExtension').hidden = false;
                return;
            }
            this.enter();
        },

        enter() {
            $('gate').hidden = true;
            $('reveal').hidden = true;
            $('shell').hidden = false;

            Relays.onStatus((n) => {
                $('relayDot').classList.toggle('is-live', n > 0);
                $('relayDot').title = t('{n} relays connected', { n });
            });
            Relays.connect();

            // Before anything is drawn: a ghost chat has nothing left to show
            // now the tab it lived in is gone, and a chat past the auto-delete
            // window is one you have already said you do not want kept.
            const swept = Store.sweepOldChats(this.settings.autoDeleteDays || 0);

            const list = Store.conversations().filter(c => !c.archived);
            this.open(list.length ? list[0] : this.newConversation());
            this.renderList();
            if (swept) {
                this.toast(swept === 1
                    ? t('1 chat swept.')
                    : t('{n} chats swept.', { n: swept }));
            }
            this.renderIdentity();
            this.refreshToolbar();

            if (Speech.canListen()) $('micBtn').hidden = false;
            Speech.onListenChange = (on) => {
                $('micBtn').classList.toggle('is-on', on);
                if (!on) this.status(null);
                else this.status(t('Listening…'));
            };
            Speech.onTranscript = (text) => {
                $('input').value = text;
                this.autoGrow();
                this.updateHints();
            };

            // The announcement and the bot's key are what make a reply
            // post-quantum; neither blocks the first message.
            setTimeout(async () => {
                try { await PQ.resolveBot(); } catch (_) { }
                try { await PQ.announce(); } catch (_) { }
                if (Identity.rootLocked) this.toast(t('This account already uses another device\'s post-quantum key. Open Identity to link this one.'));
                this.refreshBalance();
                Anon.flush().then(() => this.runAutoTopUp()).catch(() => { });
            }, 300);

            Chat.onStatus = (text) => this.status(text);

            // A published profile is what the account already tells the world;
            // showing it here costs no privacy and makes the app feel signed
            // in rather than anonymous-by-accident.
            Profile.onChange = (pubkey) => {
                if (pubkey === Identity.pubkey) {
                    this.renderIdentity();
                    this.renderMessages();
                }
            };
            Profile.loadWhenConnected(Identity.pubkey).catch(() => { });
            this.offerBotFromUrl();
            this.watchScrolling();
            this.startScheduler();
            setTimeout(() => this.runDueSchedules().catch(() => { }), 4000);
        },

        applyAppearance() {
            const s = this.settings;
            const root = document.documentElement;
            if (s.theme && s.theme !== 'system') root.setAttribute('data-theme', s.theme);
            else root.removeAttribute('data-theme');
            root.setAttribute('data-density', s.density || 'comfortable');
            root.setAttribute('data-bubbles', s.bubbles === false ? 'off' : 'on');
            root.setAttribute('data-avatars', s.avatars === false ? 'off' : 'on');
            root.setAttribute('data-timestamps', s.timestamps === false ? 'off' : 'on');
            root.setAttribute('data-mono', s.monospaceReplies ? 'on' : 'off');
            root.setAttribute('data-motion', s.reduceMotion ? 'reduce' : 'full');
            root.style.setProperty('--font-scale', String(s.fontScale || 1));
        },

        saveSettings(patch) {
            this.settings = Store.setSettings(patch);
            this.applyAppearance();
            return this.settings;
        },

        // --- conversations ---------------------------------------------------

        newConversation(patch) {
            const conv = Store.createConversation(Object.assign({
                rootId: window.NymbotHex.hex(crypto.getRandomValues(new Uint8Array(32))),
                anon: Anon.enabled(),
                repoIds: (this.settings.defaultRepos || []).slice(),
                personaId: this.settings.defaultPersona || null,
                workspaceId: (this.conv && this.conv.workspaceId) || null
            }, patch || {}));
            return conv;
        },

        open(conv) {
            if (!conv) return;
            if (this.conv && !this.editing) Store.setDraft(this.conv.id, $('input') ? $('input').value : '');
            this.conv = conv;
            this.attachments = [];
            this.quote = null;
            this.editing = null;
            this.renderAttachments();
            this.renderQuote();
            $('chatTitle').textContent = conv.title || t('New chat');
            $('chatAnon').hidden = !conv.anon;
            this.toggleSidebar(false);
            this.closeFind();
            this.closeArtifact();
            this.renderMessages();
            this.renderList();
            this.refreshToolbar();
            this.renderArtifactStrip();
            const input = $('input');
            input.value = Store.draft(conv.id);
            this.autoGrow();
            this.updateHints();
            input.focus();
        },

        filteredConversations() {
            const term = ($('convSearch').value || '').toLowerCase().trim();
            return Store.conversations().filter((conv) => {
                if (this.convFilter === 'archived') { if (!conv.archived) return false; }
                else if (conv.archived) return false;
                if (this.convFilter === 'pinned' && !conv.pinned) return false;
                if (this.convFilter === 'anon' && !conv.anon) return false;
                if (this.convFilter === 'repos' && !(conv.repoIds || []).length) return false;
                if (!term) return true;
                if ((conv.title || '').toLowerCase().includes(term)) return true;
                if ((conv.tags || []).some(x => x.toLowerCase().includes(term))) return true;
                return Store.messages(conv.id).some(m => (m.content || '').toLowerCase().includes(term));
            });
        },

        groupLabel(conv) {
            if (conv.pinned) return t('Pinned');
            if (this.settings.sidebarGrouping === 'flat') return '';
            if (this.settings.sidebarGrouping === 'folder') {
                const folder = (Store.folders().find(f => f.id === conv.folderId) || {}).name;
                return folder || t('No folder');
            }
            const day = 24 * 3600 * 1000;
            const age = Date.now() - (conv.updatedAt || 0);
            if (age < day) return t('Today');
            if (age < 2 * day) return t('Yesterday');
            if (age < 7 * day) return t('This week');
            if (age < 30 * day) return t('This month');
            return t('Older');
        },

        renderList() {
            const list = $('convList');
            list.innerHTML = '';
            const conversations = this.filteredConversations();
            const repos = Store.repos();
            let group = null;
            for (const conv of conversations) {
                const label = this.groupLabel(conv);
                if (label && label !== group) {
                    group = label;
                    const head = el('li', 'conv-group', label);
                    list.appendChild(head);
                }
                const li = el('li');
                const btn = el('button', 'conv-item' + (this.conv && conv.id === this.conv.id ? ' is-active' : ''));
                btn.type = 'button';
                if (conv.pinned) {
                    const pin = el('span', 'conv-pin');
                    pin.appendChild(Icons.node('star', { size: 11, filled: true }));
                    btn.appendChild(pin);
                }
                const main = el('div', 'conv-main');
                main.appendChild(el('span', 'conv-title', conv.title || t('New chat')));
                const bits = [];
                const convRepos = (conv.repoIds || []).map(id => repos.find(r => r.id === id)).filter(Boolean);
                if (convRepos.length) bits.push(convRepos.map(r => r.label || r.repo).join(', '));
                if ((conv.tags || []).length) bits.push((conv.tags || []).map(x => '#' + x).join(' '));
                if (bits.length) main.appendChild(el('span', 'conv-sub', bits.join(' · ')));
                btn.appendChild(main);
                if (conv.anon) btn.appendChild(el('span', 'conv-badge', 'anon'));
                btn.addEventListener('click', () => this.open(Store.conversation(conv.id)));
                li.appendChild(btn);
                list.appendChild(li);
            }
            if (!conversations.length) {
                const empty = el('li', 'conv-group', t('Nothing here.'));
                list.appendChild(empty);
            }
            $('repoCount').textContent = repos.length ? String(repos.length) : '';
        },

        /// Who the messages in this chat are from. An anonymous chat is
        /// deliberately NOT the account: it shows the throwaway key's own
        /// generated nym, never the published profile, or the whole point of
        /// the mode would be undone by the avatar.
        selfIdentity() {
            const anon = !!(this.conv && this.conv.anon && Anon.ready() && Anon.sender());
            const pk = anon ? Anon.sender().pubkey : Identity.pubkey;
            if (anon) {
                return {
                    pubkey: pk,
                    name: Avatar.nymName(pk),
                    suffix: Avatar.suffix(pk),
                    colour: Avatar.colorClass(pk),
                    avatar: Avatar.identicon(pk),
                    nip05: ''
                };
            }
            return Profile.for(pk);
        },

        renderMessages() {
            const box = $('messages');
            box.innerHTML = '';
            this._lastGroup = null;
            this._lastKey = null;
            const msgs = Store.messages(this.conv.id);
            if (!msgs.length) {
                box.appendChild(this.emptyState());
                return;
            }
            let lastDay = null;
            for (const m of msgs) {
                const day = new Date(m.ts || Date.now()).toDateString();
                if (day !== lastDay) {
                    lastDay = day;
                    this._lastGroup = null;
                    this._lastKey = null;
                    box.appendChild(el('div', 'day-divider', this.dayLabel(m.ts)));
                }
                this.appendMessage(m, true);
            }
            this.scrollToBottom(true);
        },

        dayLabel(ts) {
            const d = new Date(ts || Date.now());
            const today = new Date();
            const yesterday = new Date(today.getTime() - 86400000);
            if (d.toDateString() === today.toDateString()) return t('Today');
            if (d.toDateString() === yesterday.toDateString()) return t('Yesterday');
            return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
        },

        timeLabel(ts) {
            return new Date(ts || Date.now())
                .toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
        },

        emptyState() {
            const bot = Chat.botFor(this.conv);
            const wrap = el('div', 'empty');
            wrap.appendChild(el('h2', null, bot ? bot.name : t('Ask Nymbot anything')));
            wrap.appendChild(el('p', null, bot
                ? (bot.tagline || t('This chat answers the way that bot was written to.'))
                : t('End-to-end encrypted, paid a reply at a time. Type ? for commands, or start with one of these.')));
            const cards = el('div', 'empty-cards');
            const own = bot && (bot.starters || []).length
                ? bot.starters.map(body => ({ title: bot.name, body }))
                : starters();
            for (const starter of own) {
                const b = el('button', 'empty-card');
                b.type = 'button';
                b.appendChild(el('strong', null, starter.title));
                b.appendChild(el('span', null, starter.body));
                b.addEventListener('click', () => {
                    $('input').value = starter.body;
                    this.autoGrow();
                    this.updateHints();
                    $('input').focus();
                });
                cards.appendChild(b);
            }
            wrap.appendChild(cards);
            const tips = el('div', 'empty-tips');
            for (const tip of ['?help', '?balance', '?model', '?git', '?prompt', '?anon']) {
                const b = el('button', null, tip);
                b.type = 'button';
                b.addEventListener('click', () => {
                    $('input').value = tip;
                    this.autoGrow();
                    $('input').focus();
                });
                tips.appendChild(b);
            }
            wrap.appendChild(tips);
            return wrap;
        },

        groupFor(m) {
            const box = $('messages');
            const self = m.role === 'self';
            const key = m.role === 'bot' ? 'bot' : self ? 'self' : m.role + '-' + m.id;
            if (this._lastGroup && this._lastKey === key && this._lastGroup.isConnected) {
                return { group: this._lastGroup, grouped: true };
            }
            const system = m.role === 'note' || m.role === 'error';
            const group = el('div', 'message-group'
                + (self ? ' group-self' : '')
                + (system ? ' group-system' : ''));
            const avatarBox = el('div', 'message-group-avatar');
            if (!system) {
                const img = document.createElement('img');
                img.className = 'avatar-bubble';
                img.alt = '';
                img.loading = 'lazy';
                img.src = m.role === 'bot' ? C.botAvatar : this.selfIdentity().avatar;
                avatarBox.appendChild(img);
            }
            const stack = el('div', 'message-group-stack');
            group.appendChild(avatarBox);
            group.appendChild(stack);
            box.appendChild(group);
            this._lastGroup = group;
            this._lastKey = key;
            return { group, grouped: false };
        },

        messageNode(m, grouped) {
            const self = m.role === 'self';
            const node = el('div', 'chat-message'
                + (self ? ' self' : '')
                + (grouped ? ' bubble-grouped' : '')
                + (m.role === 'note' ? ' is-note' : '')
                + (m.role === 'error' ? ' is-error' : ''));
            node.dataset.id = m.id;
            node.dataset.role = m.role;

            if (m.role === 'self' || m.role === 'bot') {
                const who = el('span', 'message-author' + (m.role === 'bot' ? ' bot-author' : ''));
                if (m.role === 'bot') {
                    who.appendChild(document.createTextNode(C.botName.toLowerCase()));
                    who.appendChild(el('span', 'nym-suffix', '#' + BOT_SUFFIX));
                    const tick = el('span', 'verified-tick');
                    tick.title = t('Verified');
                    tick.appendChild(Icons.node('verified', { size: 12 }));
                    who.appendChild(tick);
                    if (m.model) who.appendChild(el('span', 'author-model', m.model));
                    if (m.cost) {
                        const cost = el('button', 'cost-chip');
                        cost.type = 'button';
                        cost.dataset.act = 'msg-cost';
                        cost.dataset.id = m.id;
                        cost.title = t('What this reply cost');
                        cost.appendChild(Icons.node('bolt', { size: 10, filled: false }));
                        cost.appendChild(el('span', null, String(m.cost)));
                        who.appendChild(cost);
                    }
                } else {
                    const me = this.selfIdentity();
                    who.classList.add(me.colour);
                    who.appendChild(document.createTextNode(me.name));
                    // The suffix is what tells two generated nyms apart. A
                    // published name is already unique enough to stand alone.
                    if (!me.hasProfile) who.appendChild(el('span', 'nym-suffix', '#' + me.suffix));
                    if (m.edited) who.appendChild(el('span', 'author-model', t('edited')));
                }
                node.appendChild(who);
            }

            const body = el('span', 'message-content');

            if (m.attachments && m.attachments.length) {
                const tray = el('div', 'msg-attachments');
                for (const a of m.attachments) {
                    const chip = el('span', 'msg-attachment');
                    if (a.kind === 'image' && a.dataUrl) {
                        const img = document.createElement('img');
                        img.src = a.dataUrl;
                        img.alt = a.name || '';
                        chip.appendChild(img);
                    }
                    chip.appendChild(el('span', null, a.name || 'file'));
                    tray.appendChild(chip);
                }
                body.appendChild(tray);
            }

            if (m.repos && m.repos.length) {
                for (const r of m.repos) body.appendChild(el('span', 'repo-chip', r));
            }

            if (m.thinking) {
                const chip = el('button', 'reasoning-chip');
                chip.type = 'button';
                chip.appendChild(Icons.node('thought', { size: 11 }));
                chip.appendChild(el('span', null, t('Reasoning')));
                const panel = el('div', 'reasoning-body', m.thinking);
                panel.hidden = !this.settings.showReasoningByDefault;
                chip.addEventListener('click', () => { panel.hidden = !panel.hidden; });
                body.appendChild(chip);
                body.appendChild(panel);
            }

            const text = el('div', 'msg-text');
            if (m.role === 'bot') {
                text.innerHTML = MD.render(m.content, {
                    wrap: this.settings.codeWrap,
                    lineNumbers: this.settings.lineNumbers
                });
            } else {
                text.style.whiteSpace = 'pre-wrap';
                text.textContent = m.content;
            }
            body.appendChild(text);

            if (m.sources && m.sources.length) {
                body.appendChild(this.citationCards(m.sources));
            }


            const made = m.role === 'bot'
                ? Artifacts.all(this.conv.id).filter(a => a.messageId === m.id)
                : [];
            if (made.length) {
                const tray = el('div', 'artifact-tray');
                for (const a of made) {
                    const card = el('button', 'artifact-card');
                    card.type = 'button';
                    card.dataset.act = 'artifact-open';
                    card.dataset.artifact = a.id;
                    card.appendChild(Icons.node(
                        Artifacts.previewable(a.lang) ? 'prompt' : 'copy', { size: 14 }));
                    const main = el('span', 'artifact-card-main');
                    main.appendChild(el('strong', null, a.title));
                    main.appendChild(el('span', null, [
                        a.lang || 'text',
                        t('{n} lines', { n: a.body.split('\n').length }),
                        (a.versions || []).length > 1
                            ? t('v{n}', { n: a.versions.length })
                            : ''
                    ].filter(Boolean).join(' · ')));
                    card.appendChild(main);
                    tray.appendChild(card);
                }
                body.appendChild(tray);
            }

            body.appendChild(el('span', 'bubble-time-inner', this.timeLabel(m.ts)));
            node.appendChild(body);
            const actions = this.actionsFor(m);
            node.appendChild(actions);

            // On a touch screen there is no hover to reveal a row with, so a
            // tap on the bubble does it — and only one row is open at a time,
            // so the thread does not fill up with them.
            body.addEventListener('click', (e) => {
                if (!matchMedia('(pointer: coarse)').matches) return;
                if (e.target.closest('a, button, input, textarea, .code-block, .artifact-card')) return;
                const open = actions.classList.contains('is-open');
                for (const row of $('messages').querySelectorAll('.msg-actions.is-open')) {
                    row.classList.remove('is-open');
                }
                actions.classList.toggle('is-open', !open);
            });
            return node;
        },

        actionsFor(m) {
            const row = el('div', 'msg-actions');
            const add = (icon, title, act, extra) => {
                const b = el('button', 'msg-action' + (extra && extra.cls ? ' ' + extra.cls : ''));
                b.type = 'button';
                // data-tip draws the label; title is kept so a screen reader
                // and a native tooltip still have it.
                b.title = title;
                b.dataset.tip = title;
                b.setAttribute('aria-label', title);
                b.dataset.act = act;
                b.dataset.id = m.id;
                b.appendChild(Icons.node(icon, { size: 14, filled: !!(extra && extra.filled) }));
                row.appendChild(b);
                return b;
            };

            if (m.role === 'bot' || m.role === 'self') {
                add('copy', t('Copy'), 'msg-copy');
            }
            if (m.role === 'bot') {
                add('refresh', t('Ask again'), 'msg-regenerate');
                if (Speech.canSpeak()) {
                    add(Speech.speakingId === m.id ? 'mute' : 'speaker', t('Read aloud'), 'msg-speak');
                }
                add('branch', t('Branch from here'), 'msg-fork');
                add('quote', t('Quote'), 'msg-quote');
                const up = add('thumbUp', t('Good reply'), 'msg-up', { filled: m.rating === 1 });
                if (m.rating === 1) up.classList.add('is-on');
                const down = add('thumbDown', t('Poor reply'), 'msg-down',
                    { cls: 'is-down', filled: m.rating === -1 });
                if (m.rating === -1) down.classList.add('is-on');
            }
            if (m.role === 'self') {
                add('pencil', t('Edit and resend'), 'msg-edit');
                add('sendAgain', t('Send again'), 'msg-resend');
            }
            if (m.role === 'bot' || m.role === 'self') {
                const pin = add('star', t('Save this message'), 'msg-pin', { filled: !!m.pinned });
                if (m.pinned) pin.classList.add('is-on');
            }
            if (m.role === 'error') {
                add('refresh', t('Try again'), 'msg-retry');
            }
            add('close', t('Delete'), 'msg-delete');
            return row;
        },

        appendMessage(m, quiet) {
            const box = $('messages');
            if (box.querySelector('.empty')) {
                box.innerHTML = '';
                this._lastGroup = null;
                this._lastKey = null;
            }
            const { group, grouped } = this.groupFor(m);
            const node = this.messageNode(m, grouped);
            group.querySelector('.message-group-stack').appendChild(node);
            if (!quiet) this.scrollToBottom();
            return node;
        },

        replaceMessage(m) {
            const old = $('messages').querySelector(`.chat-message[data-id="${m.id}"]`);
            if (!old) return null;
            const grouped = old.classList.contains('bubble-grouped');
            const node = this.messageNode(m, grouped);
            old.replaceWith(node);
            return node;
        },

        thinkingNode(label) {
            const node = el('div', 'bot-thinking');
            node.id = 'thinkingNode';
            const img = document.createElement('img');
            img.className = 'avatar-bubble';
            img.src = C.botAvatar;
            img.alt = '';
            node.appendChild(img);
            const head = el('div', 'bot-thinking-head');
            head.appendChild(el('span', 'bot-thinking-label', label || t('Nymbot is thinking')));
            head.appendChild(el('span', 'typing-dot'));
            head.appendChild(el('span', 'typing-dot'));
            head.appendChild(el('span', 'typing-dot'));
            node.appendChild(head);
            // Filled in as the worker reports what it is doing.
            node.appendChild(el('div', 'bot-progress', ''));
            return node;
        },

        // --- carrying a capped run on ------------------------------------------

        /// What is left of this chat's continuation budget. A budget of -1 is
        /// "whatever the balance holds", which is still a real ceiling — it is
        /// just the user's own balance rather than a number they typed.
        continueBudget() {
            const cap = Number(this.settings.autoContinue) || 0;
            const spent = this.conv._continued || 0;
            if (cap === 0) return 0;
            if (cap < 0) {
                const have = this.balance.pro;
                return have == null ? 0 : Math.max(0, have);
            }
            return Math.max(0, cap - spent);
        },

        /// A repo run stopped at its tool-call cap with work left. Spend the
        /// budget the user set on carrying it on, one leg at a time, and say
        /// what each leg cost as it goes — never silently.
        async continueRun(res, firstReply) {
            let token = res.resumeToken;
            let reserve = res.nextReserve || 0;
            if (!token) {
                this.note(t('That answer stopped early and could not be resumed. Ask again to pick it up.'));
                return;
            }
            let left = this.continueBudget();
            if (left <= 0) {
                this.note(t('That answer stopped early. Turn on continuing in Appearance, or ask it to carry on.'));
                return;
            }
            if (reserve && reserve > left) {
                this.note(t('That answer stopped early. Carrying on reserves {n} more credits than the budget left.',
                    { n: reserve - left }));
                return;
            }

            const box = $('messages');
            while (token && left > 0 && !this.stopped) {
                const pending = this.thinkingNode(t('Carrying on where it left off'));
                box.appendChild(pending);
                this.scrollToBottom();
                let next;
                try {
                    next = await Chat.send(this.conv, t('Continue.'), this.settings, {
                        resume: token,
                        onTurn: (eventId, signer) => this.watchTurn(eventId, signer)
                    });
                } catch (e) {
                    this.stopWatchingTurn();
                    pending.remove();
                    this.note((e && e.message) || t('Could not carry on from there.'));
                    return;
                }
                this.stopWatchingTurn();
                pending.remove();

                const more = {
                    id: Store.uid(),
                    role: 'bot',
                    content: next.reply,
                    thinking: next.thinking || null,
                    cost: next.cost || 0,
                    model: next.pro ? ((this.conv.proModel || this.settings.proModel || {}).label || null) : null,
                    sources: next.sources || null,
                    calls: next.modelCalls || 1,
                    task: next.taskType || null,
                    continued: true,
                    ts: Date.now()
                };
                Store.addMessage(this.conv.id, more);
                Artifacts.harvest(this.conv.id, more);
                this.appendMessage(more);
                Store.recordUsage(more.cost);
                this.bumpStats(more.cost);

                const spent = (this.conv._continued || 0) + (more.cost || 0);
                this.conv._continued = spent;
                if (next.balance != null) {
                    this.balance[next.pro ? 'pro' : 'standard'] = next.balance;
                    this.renderBalance();
                }
                left = this.continueBudget();
                token = next.truncated ? next.resumeToken : null;
                reserve = next.nextReserve || 0;

                if (token && reserve && reserve > left) {
                    this.note(t('Stopped: carrying on again needs {n} credits and {left} are left in the budget.',
                        { n: reserve, left }));
                    return;
                }
                if (token && left <= 0) {
                    this.note(t('Budget spent — {n} credits on carrying that on. Raise it in Appearance to go further.',
                        { n: spent }));
                    return;
                }
            }
            if (this.conv._continued) {
                this.note(t('Finished. Carrying on cost {n} extra credits.', { n: this.conv._continued }));
                this.conv._continued = 0;
            }
        },

        // --- watching a turn as it runs ----------------------------------------

        /// What one progress step reads as. The worker sends facts; the words
        /// are the client's, so they translate with everything else.
        progressLine(step) {
            switch (step && step.kind) {
                case 'routing':
                    return step.resumed
                        ? t('Carrying on where it left off')
                        : (step.model && step.model !== 'auto'
                            ? t('Routing to {model}', { model: step.model })
                            : t('Routing this one'));
                case 'search':
                    return t('Searching the web for “{query}”', { query: step.query || '' });
                case 'model':
                    return step.of > 1
                        ? t('Model call {n} of {total}', { n: step.call, total: step.of })
                        : t('Asking {model}', { model: step.model || '' });
                case 'tool':
                    return step.target
                        ? t('{tool}: {target}', { tool: this.toolLabel(step.tool), target: step.target })
                        : this.toolLabel(step.tool);
                case 'thinking':
                    return step.text || '';
                default:
                    return '';
            }
        },

        toolLabel(name) {
            switch (name) {
                case 'list_directory': return t('Listing files');
                case 'read_file': return t('Reading');
                case 'search_code': return t('Searching the code');
                case 'write_file': return t('Writing');
                case 'create_branch': return t('Creating a branch');
                case 'open_pull_request': return t('Opening a pull request');
                default: return t('Working');
            }
        },

        renderProgress(steps) {
            const node = document.getElementById('thinkingNode');
            if (!node || !this.settings.showProgress) return;
            const box = node.querySelector('.bot-progress');
            if (!box) return;
            box.innerHTML = '';
            // The last few only: this sits under a spinner, not in a log view.
            for (const step of steps.slice(-4)) {
                const line = this.progressLine(step);
                if (!line) continue;
                const row = el('div', 'progress-step'
                    + (step.kind === 'thinking' ? ' is-thought' : ''), line);
                box.appendChild(row);
            }
            this.scrollToBottom();
        },

        /// Polls the worker for what the turn is doing. Stops the moment the
        /// turn is over, and never keeps the send waiting on it.
        watchTurn(eventId, signer) {
            this.stopWatchingTurn();
            if (!this.settings.showProgress) return;
            const seen = [];
            let after = 0;
            let alive = true;
            this._turnWatch = () => { alive = false; };
            const tick = async () => {
                while (alive) {
                    const steps = await Chat.progress(eventId, after, { signer });
                    if (!alive) return;
                    if (steps.length) {
                        after = steps[steps.length - 1].n || after;
                        for (const s of steps) seen.push(s);
                        this.renderProgress(seen);
                    }
                    await new Promise(r => setTimeout(r, 2000));
                }
            };
            tick().catch(() => { });
        },

        stopWatchingTurn() {
            if (this._turnWatch) {
                try { this._turnWatch(); } catch (_) { }
                this._turnWatch = null;
            }
        },

        scrollToBottom(instant) {
            const box = $('messages');
            if (instant) {
                const before = box.style.scrollBehavior;
                box.style.scrollBehavior = 'auto';
                box.scrollTop = box.scrollHeight;
                box.style.scrollBehavior = before;
            } else {
                box.scrollTop = box.scrollHeight;
            }
            $('jumpBtn').hidden = true;
        },

        nearBottom() {
            const box = $('messages');
            return box.scrollHeight - box.scrollTop - box.clientHeight < 120;
        },

        typeInto(node, message) {
            const speeds = { slow: 26, normal: 12, fast: 5 };
            const step = speeds[this.settings.typewriterSpeed] || 12;
            const target = message.content || '';
            const text = node.querySelector('.msg-text');
            if (!text) return Promise.resolve();
            const caret = el('span', 'stream-caret');
            let at = 0;
            const stick = this.nearBottom();
            return new Promise((resolve) => {
                const tick = () => {
                    if (!node.isConnected) { resolve(); return; }
                    at = Math.min(target.length, at + Math.max(2, Math.round(target.length / 90)));
                    const partial = target.slice(0, at);
                    text.innerHTML = MD.render(partial, {
                        wrap: this.settings.codeWrap,
                        lineNumbers: this.settings.lineNumbers
                    });
                    text.appendChild(caret);
                    if (stick) $('messages').scrollTop = $('messages').scrollHeight;
                    if (at >= target.length) {
                        caret.remove();
                        if (message.cost) {
                            const chip = el('span', 'cost-chip');
                            chip.appendChild(Icons.node('bolt', { size: 10 }));
                            chip.appendChild(el('span', null, String(message.cost)));
                            text.appendChild(chip);
                        }
                        resolve();
                        return;
                    }
                    this._typeTimer = setTimeout(tick, step);
                };
                tick();
            });
        },

        // --- sending ----------------------------------------------------------

        async send(override) {
            const input = $('input');
            const text = override != null ? override : input.value.trim();
            if (!text || this.sending) return;

            if (override == null && await this.handleCommand(text)) {
                input.value = '';
                Store.setDraft(this.conv.id, '');
                this.autoGrow();
                this.updateHints();
                this.hideSuggest();
                return;
            }

            if (override == null) {
                input.value = '';
                Store.setDraft(this.conv.id, '');
                this.autoGrow();
                this.updateHints();
                this.hideSuggest();
            }

            const attachments = this.attachments.slice();
            const quote = this.quote;
            this.attachments = [];
            this.quote = null;
            this.renderAttachments();
            this.renderQuote();

            const mine = {
                id: Store.uid(),
                role: 'self',
                content: text,
                ts: Date.now(),
                attachments: attachments.map(a => ({
                    id: a.id, kind: a.kind, name: a.name, mime: a.mime, size: a.size,
                    ...(a.kind === 'image' ? { dataUrl: a.dataUrl } : {})
                })),
                quote: quote ? quote.slice(0, 200) : null
            };
            Store.addMessage(this.conv.id, mine);
            this.appendMessage(mine);

            if (!this.conv.title) {
                const title = Chat.titleFor(text);
                this.conv = Store.updateConversation(this.conv.id, { title });
                $('chatTitle').textContent = title;
                this.renderList();
            }

            this.stopped = false;
            this.setSending(true);
            const box = $('messages');
            const repos = Chat.reposFor(this.conv);
            const pending = this.thinkingNode(repos.length && (this.conv.proModel || this.settings.proModel)
                ? t('Nymbot is reading your repositories')
                : t('Nymbot is thinking'));
            box.appendChild(pending);
            this.scrollToBottom();

            try {
                const res = await Chat.send(this.conv, text, this.settings, {
                    attachments, quote,
                    onTurn: (eventId, signer) => this.watchTurn(eventId, signer)
                });
                this.stopWatchingTurn();
                pending.remove();
                const reply = {
                    id: Store.uid(),
                    role: 'bot',
                    content: res.reply,
                    thinking: res.thinking || null,
                    cost: res.cost || 0,
                    model: res.pro ? ((this.conv.proModel || this.settings.proModel || {}).label || null) : null,
                    sources: res.sources || null,
                    repos: (res.repos && res.repos.length > 1) ? res.repos : null,
                    // Kept so the cost breakdown reports what the worker said
                    // it did rather than re-deriving a guess after the fact.
                    calls: res.modelCalls || 1,
                    task: res.taskType || null,
                    ts: Date.now()
                };
                Store.addMessage(this.conv.id, reply);
                const lifted = Artifacts.harvest(this.conv.id, reply);
                const node = this.appendMessage(reply);
                if (lifted.length) this.renderArtifactStrip();
                if (this.settings.typewriter && reply.content.length < 12000) {
                    await this.typeInto(node, reply);
                }
                Store.recordUsage(reply.cost);
                this.bumpStats(reply.cost);
                this.renderList();
                this.notifyReply(reply);

                if (res.balance != null) {
                    this.balance[res.pro ? 'pro' : 'standard'] = res.balance;
                    this.renderBalance();
                }
                if (res.lowBalance) {
                    // In an anonymous chat a low balance is usually the
                    // throwaway key running dry rather than the nym, and that
                    // is exactly what the automatic transfer is for.
                    const topped = this.conv.anon ? await this.runAutoTopUp() : null;
                    if (!topped) {
                        this.note(res.pro
                            ? t('Pro credits running low: {balance} left. Tap Buy to top up.', { balance: res.balance })
                            : t('Credits running low: {balance} left. Tap Buy to top up.', { balance: res.balance }));
                    }
                }
                if (res.truncated) await this.continueRun(res, reply);
            } catch (e) {
                this.stopWatchingTurn();
                pending.remove();
                if (e && e.name === 'AbortError') {
                    this.note(t('Stopped. That reply was not charged for unless it had already finished.'));
                } else if (e && e.noCredits) {
                    this.balance[e.pro ? 'pro' : 'standard'] = e.balance;
                    this.renderBalance();
                    const topped = this.conv.anon
                        ? await this.runAutoTopUp({ force: true })
                        : null;
                    if (topped) {
                        this.note(t('Topped the throwaway key up. Send that again when you are ready.'));
                    } else {
                        this.note(e.message);
                        if (this.conv.anon) this.openAnon(); else this.openCredits();
                    }
                } else {
                    const err = {
                        id: Store.uid(),
                        role: 'error',
                        content: (e && e.message) || t('Something went wrong.'),
                        retry: text,
                        ts: Date.now()
                    };
                    Store.addMessage(this.conv.id, err);
                    this.appendMessage(err);
                }
            } finally {
                this.setSending(false);
                this.status(null);
            }
        },

        setSending(on) {
            this.sending = on;
            $('sendBtn').hidden = on;
            $('stopBtn').hidden = !on;
            $('sendBtn').disabled = on;
        },

        stop() {
            clearTimeout(this._typeTimer);
            // Stop means stop: a run carrying itself on must not start another
            // leg after the one being aborted.
            this.stopped = true;
            this.stopWatchingTurn();
            if (!Chat.abort()) this.setSending(false);
        },

        bumpStats(cost) {
            const stats = Object.assign({ messages: 0, credits: 0 }, this.conv.stats || {});
            stats.messages += 1;
            stats.credits += cost || 0;
            this.conv = Store.updateConversation(this.conv.id, { stats });
        },

        notifyReply(reply) {
            if (this.settings.soundOnReply) this.beep();
            if (this.settings.hapticOnReply && navigator.vibrate) {
                try { navigator.vibrate(12); } catch (_) { }
            }
            if (this.settings.autoSpeak && Speech.canSpeak()) {
                Speech.speak(reply.id, MD.plain(reply.content), {
                    rate: this.settings.speechRate,
                    voiceUri: this.settings.voiceUri
                });
            }
        },

        beep() {
            try {
                const Ctx = window.AudioContext || window.webkitAudioContext;
                if (!Ctx) return;
                const ctx = this._audio || (this._audio = new Ctx());
                const osc = ctx.createOscillator();
                const gain = ctx.createGain();
                osc.frequency.value = 660;
                gain.gain.value = 0.04;
                osc.connect(gain).connect(ctx.destination);
                osc.start();
                osc.stop(ctx.currentTime + 0.09);
            } catch (_) { }
        },

        note(text) {
            const m = { id: Store.uid(), role: 'note', content: text, ts: Date.now() };
            Store.addMessage(this.conv.id, m);
            this.appendMessage(m);
        },

        message(id) {
            return Store.messages(this.conv.id).find(m => m.id === id) || null;
        },

        messageAction(act, id) {
            const m = this.message(id);
            if (!m) return;
            switch (act) {
                case 'msg-cost':
                    this.openCost(m);
                    return;
                case 'msg-copy':
                    this.writeClipboard(m.content);
                    return;
                case 'msg-speak':
                    if (Speech.toggleSpeak(m.id, MD.plain(m.content), {
                        rate: this.settings.speechRate, voiceUri: this.settings.voiceUri
                    }) === false) this.toast(t('Stopped reading.'));
                    return;
                case 'msg-regenerate':
                    this.regenerate(m);
                    return;
                case 'msg-resend':
                    this.send(m.content);
                    return;
                case 'msg-edit':
                    this.editMessage(m);
                    return;
                case 'msg-quote':
                    this.quote = MD.plain(m.content).slice(0, 400);
                    this.renderQuote();
                    $('input').focus();
                    return;
                case 'msg-fork':
                    this.forkAt(m);
                    return;
                case 'msg-up':
                case 'msg-down': {
                    const want = act === 'msg-up' ? 1 : -1;
                    const rating = m.rating === want ? 0 : want;
                    Store.patchMessage(this.conv.id, m.id, { rating });
                    this.replaceMessage(Object.assign({}, m, { rating }));
                    return;
                }
                case 'msg-pin': {
                    const pinned = !m.pinned;
                    Store.patchMessage(this.conv.id, m.id, { pinned });
                    this.replaceMessage(Object.assign({}, m, { pinned }));
                    this.toast(pinned ? t('Saved.') : t('Removed from saved messages.'));
                    return;
                }
                case 'msg-retry':
                    if (m.retry) {
                        Store.deleteMessage(this.conv.id, m.id);
                        this.renderMessages();
                        this.send(m.retry);
                    }
                    return;
                case 'msg-delete':
                    Store.deleteMessage(this.conv.id, m.id);
                    this.renderMessages();
                    return;
            }
        },

        async regenerate(botMessage) {
            const msgs = Store.messages(this.conv.id);
            const at = msgs.findIndex(m => m.id === botMessage.id);
            let question = null;
            for (let i = at - 1; i >= 0; i--) {
                if (msgs[i].role === 'self') { question = msgs[i]; break; }
            }
            if (!question) { this.toast(t('There is nothing to ask again.')); return; }
            Store.deleteMessage(this.conv.id, botMessage.id);
            this.renderMessages();
            await this.send(question.content);
        },

        async editMessage(m) {
            const value = await this.ask({
                title: t('Edit and resend'),
                area: true,
                label: t('Your message'),
                value: m.content,
                confirm: t('Send')
            });
            if (value == null || !value.trim()) return;
            Store.truncateFrom(this.conv.id, m.id, true);
            this.renderMessages();
            await this.send(value.trim());
        },

        forkAt(m) {
            const msgs = Store.messages(this.conv.id);
            const at = msgs.findIndex(x => x.id === m.id);
            const kept = msgs.slice(0, at + 1);
            const seed = kept
                .filter(x => x.role === 'self' || x.role === 'bot')
                .slice(-8)
                .map(x => `${x.role === 'self' ? 'User' : 'Assistant'}: ${MD.plain(x.content).slice(0, 700)}`)
                .join('\n\n');
            const copy = Store.createConversation({
                title: (this.conv.title || t('New chat')) + ' ' + t('(branch)'),
                rootId: window.NymbotHex.hex(crypto.getRandomValues(new Uint8Array(32))),
                anon: this.conv.anon,
                folderId: this.conv.folderId,
                tags: (this.conv.tags || []).slice(),
                repoIds: (this.conv.repoIds || []).slice(),
                personaId: this.conv.personaId,
                systemPrompt: this.conv.systemPrompt,
                proModel: this.conv.proModel,
                seed
            });
            Store.saveMessages(copy.id, kept);
            this.open(Store.conversation(copy.id));
            this.toast(t('Branched. The new chat carries what was said up to that point.'));
        },

        async handleCommand(text) {
            const m = /^\?(\w+|8ball)\s*(.*)$/s.exec(text);
            if (!m) return false;
            const cmd = m[1].toLowerCase();
            const arg = m[2].trim();
            if (!Commands.isLocal(cmd)) return false;

            switch (cmd) {
                case 'help':
                case 'commands':
                    this.note(Commands.helpText());
                    return true;
                case 'balance':
                    await this.refreshBalance(true);
                    return true;
                case 'buy':
                    if (/^\d+$/.test(arg)) $('creditAmount').value = arg;
                    this.openCredits();
                    return true;
                case 'model':
                    if (/^off$/i.test(arg)) {
                        this.setModel(null);
                        this.note(t('Back to standard auto-routing.'));
                        return true;
                    }
                    await this.openModels(arg);
                    return true;
                case 'compare':
                    await this.openCompare(arg || undefined);
                    return true;
                case 'schedule':
                    this.openSchedules();
                    if (arg) $('schedulePrompt').value = arg;
                    return true;
                case 'ghost':
                    await this.toggleGhost();
                    return true;
                case 'bot':
                    if (/^off$/i.test(arg)) {
                        this.useBot(null);
                        return true;
                    }
                    if (arg) {
                        const hit = Bots.all()
                            .find(b => (b.name || '').toLowerCase().includes(arg.toLowerCase()));
                        if (hit) {
                            this.useBot(hit.id);
                            return true;
                        }
                        this.note(t('No bot by that name.'));
                    }
                    await this.openBots();
                    return true;
                case 'workspace':
                    if (/^off$/i.test(arg)) {
                        this.useWorkspace(null);
                        return true;
                    }
                    if (arg) {
                        const found = Store.workspaces()
                            .find(w => (w.name || '').toLowerCase().includes(arg.toLowerCase()));
                        if (found) {
                            this.useWorkspace(found.id);
                            return true;
                        }
                        this.note(t('No workspace by that name.'));
                    }
                    this.openWorkspaces();
                    return true;
                case 'git':
                case 'repo':
                    return this.gitCommand(cmd, arg);
                case 'anon':
                    this.openAnon();
                    return true;
                case 'persona':
                    if (/^off$/i.test(arg)) {
                        this.conv = Store.updateConversation(this.conv.id, { personaId: null });
                        this.refreshToolbar();
                        this.note(t('Persona cleared.'));
                        return true;
                    }
                    if (arg) {
                        const hit = Store.personas().find(p => p.name.toLowerCase().includes(arg.toLowerCase()));
                        if (hit) {
                            this.conv = Store.updateConversation(this.conv.id, { personaId: hit.id });
                            this.refreshToolbar();
                            this.note(t('Persona set to {name}.', { name: hit.name }));
                            return true;
                        }
                    }
                    this.openPersonas();
                    return true;
                case 'system':
                    if (arg) {
                        this.conv = Store.updateConversation(this.conv.id, { systemPrompt: arg });
                        this.refreshToolbar();
                        this.note(t('Custom instructions saved for this chat.'));
                        return true;
                    }
                    this.openSystem();
                    return true;
                case 'prompt':
                    this.openPrompts(arg);
                    return true;
                case 'save': {
                    const body = $('input').value.trim() || arg;
                    if (!body) { this.note(t('There is nothing in the composer to save.')); return true; }
                    Store.savePrompt({ title: arg || Chat.titleFor(body), body });
                    this.note(t('Saved to the prompt library.'));
                    return true;
                }
                case 'search':
                    this.openSearch(arg);
                    return true;
                case 'pin': {
                    const pinned = !this.conv.pinned;
                    this.conv = Store.updateConversation(this.conv.id, { pinned });
                    this.renderList();
                    this.note(pinned ? t('Pinned.') : t('Unpinned.'));
                    return true;
                }
                case 'archive':
                    this.archiveChat();
                    return true;
                case 'tag':
                    if (arg) {
                        const tags = Array.from(new Set([...(this.conv.tags || []), ...arg.split(',').map(x => x.trim()).filter(Boolean)]));
                        this.conv = Store.updateConversation(this.conv.id, { tags });
                        this.renderList();
                        this.note(t('Tagged.'));
                        return true;
                    }
                    this.openTags();
                    return true;
                case 'folder':
                    this.openTags();
                    return true;
                case 'rename':
                    if (arg) {
                        this.conv = Store.updateConversation(this.conv.id, { title: arg });
                        $('chatTitle').textContent = arg;
                        this.renderList();
                        return true;
                    }
                    this.renameChat();
                    return true;
                case 'fork': {
                    const msgs = Store.messages(this.conv.id);
                    if (!msgs.length) { this.note(t('There is nothing to branch yet.')); return true; }
                    this.forkAt(msgs[msgs.length - 1]);
                    return true;
                }
                case 'export':
                    Exporter.conversation(this.conv, /^(json|txt)$/i.test(arg) ? arg.toLowerCase() : 'md');
                    this.note(t('Downloaded.'));
                    return true;
                case 'stats':
                    this.openStats();
                    return true;
                case 'theme': {
                    const want = /^(dark|light|system|terminal|midnight)$/i.test(arg) ? arg.toLowerCase() : null;
                    if (want) {
                        this.saveSettings({ theme: want });
                        this.note(t('Theme set to {name}.', { name: want }));
                    } else {
                        this.openAppearance();
                    }
                    return true;
                }
                case 'settings':
                    this.openAppearance();
                    return true;
                case 'guide':
                    this.openHelp(arg);
                    return true;
                case 'shortcuts':
                    this.openShortcuts();
                    return true;
                case 'voice':
                    if (!Speech.canListen()) { this.note(t('This browser cannot listen.')); return true; }
                    Speech.toggleListening();
                    return true;
                case 'retry': {
                    const msgs = Store.messages(this.conv.id);
                    for (let i = msgs.length - 1; i >= 0; i--) {
                        if (msgs[i].role === 'self') {
                            await this.send(msgs[i].content);
                            return true;
                        }
                    }
                    this.note(t('There is nothing to ask again.'));
                    return true;
                }
                case 'clear':
                    await this.clearChat();
                    return true;
                default:
                    return false;
            }
        },

        gitCommand(cmd, arg) {
            const repos = Store.repos();
            if (/^list$/i.test(arg) || (cmd === 'git' && /^status$/i.test(arg))) {
                if (!repos.length) { this.note(t('No repositories connected yet.')); return true; }
                const on = new Set(this.conv.repoIds || []);
                this.note(repos.map(r =>
                    `${on.has(r.id) ? '[x]' : '[ ]'} ${r.repo}${r.branch ? '@' + r.branch : ''}${r.allowWrites ? ' (writes)' : ''}`
                ).join('\n'));
                return true;
            }
            const writes = /^writes\s+(on|off)$/i.exec(arg);
            if (writes) {
                const on = /on$/i.test(writes[1]);
                for (const id of this.conv.repoIds || []) Store.updateRepo(id, { allowWrites: on });
                this.refreshToolbar();
                this.note(on ? t('Repository writes on.') : t('Repository writes off.'));
                return true;
            }
            if (/^disconnect|^none$/i.test(arg)) {
                this.conv = Store.updateConversation(this.conv.id, { repoIds: [] });
                this.refreshToolbar();
                this.note(t('No repository is in scope for this chat.'));
                return true;
            }
            if (/^all$/i.test(arg)) {
                this.conv = Store.updateConversation(this.conv.id, { repoIds: repos.map(r => r.id) });
                this.refreshToolbar();
                this.note(t('Every connected repository is in scope for this chat.'));
                return true;
            }
            const useMatch = /^(?:use\s+)?(.+)$/i.exec(arg);
            if (arg && useMatch) {
                const needle = useMatch[1].toLowerCase();
                const hit = repos.find(r =>
                    r.repo.toLowerCase().includes(needle) || (r.label || '').toLowerCase().includes(needle));
                if (hit) {
                    const on = new Set(this.conv.repoIds || []);
                    if (on.has(hit.id)) on.delete(hit.id); else on.add(hit.id);
                    this.conv = Store.updateConversation(this.conv.id, { repoIds: Array.from(on) });
                    this.refreshToolbar();
                    this.note(on.has(hit.id)
                        ? t('{repo} is now in scope for this chat.', { repo: hit.repo })
                        : t('{repo} is no longer in scope for this chat.', { repo: hit.repo }));
                    return true;
                }
            }
            this.openRepos();
            return true;
        },

        updateSuggest() {
            const value = $('input').value;
            const m = /^\?(\w*)$/.exec(value);
            if (!m) { this.hideSuggest(); return; }
            const rows = Commands.match(m[1], 8);
            if (!rows.length) { this.hideSuggest(); return; }
            this.suggestRows = rows;
            this.suggestAt = 0;
            const box = $('suggest');
            box.innerHTML = '';
            rows.forEach((entry, i) => {
                const b = el('button', 'suggest-row' + (i === 0 ? ' is-active' : ''));
                b.type = 'button';
                b.appendChild(el('span', 'suggest-name', '?' + entry.name));
                if (entry.args) b.appendChild(el('span', 'suggest-args', entry.args));
                b.appendChild(el('span', 'suggest-hint', entry.hint()));
                b.addEventListener('click', () => this.pickSuggest(i));
                box.appendChild(b);
            });
            box.hidden = false;
        },

        hideSuggest() {
            $('suggest').hidden = true;
            this.suggestRows = [];
        },

        moveSuggest(delta) {
            if (!this.suggestRows.length) return false;
            this.suggestAt = (this.suggestAt + delta + this.suggestRows.length) % this.suggestRows.length;
            const rows = $('suggest').querySelectorAll('.suggest-row');
            rows.forEach((r, i) => r.classList.toggle('is-active', i === this.suggestAt));
            return true;
        },

        pickSuggest(index) {
            const entry = this.suggestRows[index == null ? this.suggestAt : index];
            if (!entry) return false;
            const input = $('input');
            input.value = '?' + entry.name + (entry.args ? ' ' : '');
            this.hideSuggest();
            this.autoGrow();
            this.updateHints();
            input.focus();
            return true;
        },

        updateHints() {
            const input = $('input');
            const text = input.value;
            const hint = $('costHint');
            if (this.settings.showTokenEstimate && text.trim() && !/^\?/.test(text.trim())) {
                const est = Chat.estimateCredits(text, this.settings, this.conv);
                hint.textContent = est.tier === 'pro'
                    ? (est.low === est.high
                        ? t('About {n} Pro credits', { n: est.low })
                        : t('About {low}–{high} Pro credits', { low: est.low, high: est.high }))
                    : t('1 standard credit');
            } else {
                hint.textContent = '';
            }
            const len = $('lenHint');
            len.textContent = text.length > 600 ? t('{n} characters', { n: text.length }) : '';
        },

        async addFiles(files) {
            for (const file of files) {
                try {
                    const built = await Attach.fromFile(file);
                    if (built) this.attachments.push(built);
                } catch (e) {
                    this.toast(e.message || t('That file could not be attached.'));
                }
            }
            this.renderAttachments();
        },

        renderAttachments() {
            const tray = $('attachTray');
            tray.innerHTML = '';
            if (!this.attachments.length) { tray.hidden = true; return; }
            for (const a of this.attachments) {
                const item = el('span', 'attach-item');
                if (a.kind === 'image') {
                    const img = document.createElement('img');
                    img.src = a.dataUrl;
                    img.alt = '';
                    item.appendChild(img);
                }
                item.appendChild(el('span', null, `${a.name} · ${Attach.humanSize(a.size)}`));
                const x = el('button', null, '×');
                x.type = 'button';
                x.title = t('Remove');
                x.addEventListener('click', () => {
                    this.attachments = this.attachments.filter(y => y.id !== a.id);
                    this.renderAttachments();
                });
                item.appendChild(x);
                tray.appendChild(item);
            }
            tray.hidden = false;
        },

        renderQuote() {
            const strip = $('replyStrip');
            if (!this.quote) { strip.hidden = true; return; }
            $('replyStripText').textContent = this.quote;
            strip.hidden = false;
        },

        // --- balances --------------------------------------------------------

        async refreshBalance(announce) {
            const opts = this.conv && this.conv.anon && Anon.ready() ? { signer: Anon.signer() } : {};
            const { data } = await Api.balance(opts);
            if (!data || data.error) {
                if (announce) this.note(t('Could not reach Nymbot to check your balance.'));
                return;
            }
            this.balance = { standard: data.balance || 0, pro: data.proBalance || 0 };
            this.renderBalance();
            if (announce) {
                const anon = this.conv && this.conv.anon;
                this.note((anon
                    ? t('This chat\'s anonymous balance: {standard} standard, {pro} Pro.',
                        { standard: this.balance.standard, pro: this.balance.pro })
                        + ' ' + t('Tap Anon to move more across from your nym.')
                    : t('Your balance: {standard} standard, {pro} Pro.',
                        { standard: this.balance.standard, pro: this.balance.pro })));
            }
        },

        renderBalance() {
            const model = (this.conv && this.conv.proModel) || this.settings.proModel;
            const tier = model ? 'pro' : 'standard';
            const value = this.balance[tier];
            $('chipBuyLabel').textContent = value == null ? t('Buy') : String(value);
            $('whoBalance').textContent = this.balance.standard == null ? ''
                : t('{standard} standard · {pro} Pro',
                    { standard: this.balance.standard, pro: this.balance.pro });
        },

        renderIdentity() {
            const pk = Identity.pubkey || '';
            const who = $('whoNym');
            who.innerHTML = '';
            if (!pk) return;
            const me = Profile.for(pk);
            const img = $('whoAvatar');
            img.src = me.avatar;
            img.hidden = false;
            who.appendChild(document.createTextNode(me.name));
            if (!me.hasProfile) who.appendChild(el('span', 'nym-suffix', '#' + me.suffix));
            else if (me.nip05) {
                const tick = el('span', 'who-nip05');
                tick.title = me.nip05;
                tick.appendChild(Icons.node('verified', { size: 11 }));
                who.appendChild(tick);
            }
        },

        // --- toolbar ----------------------------------------------------------

        refreshToolbar() {
            const conv = this.conv || {};
            const model = conv.proModel || this.settings.proModel;
            const pro = !!model;
            $('toolbar').classList.toggle('is-pro', pro);
            for (const b of document.querySelectorAll('#toolbar .tier-btn')) {
                b.classList.toggle('is-active', (b.dataset.tier === 'pro') === pro);
            }
            const modelChip = $('chipModel');
            modelChip.classList.toggle('is-active', pro);
            modelChip.querySelector('.chip-label').textContent = pro ? model.label : t('Auto-routed');

            const repos = Chat.reposFor(conv);
            const gitChip = $('chipGit');
            gitChip.classList.toggle('is-active', repos.length > 0);
            gitChip.querySelector('.chip-label').textContent = repos.length === 0
                ? t('Git')
                : repos.length === 1
                    ? (repos[0].label || repos[0].repo)
                    : t('{n} repos', { n: repos.length });

            const persona = conv.personaId ? Store.persona(conv.personaId) : null;
            const personaChip = $('chipPersona');
            const hasSystem = !!(conv.systemPrompt || '').trim();
            personaChip.classList.toggle('is-active', !!persona || hasSystem);
            personaChip.querySelector('.chip-label').textContent = persona
                ? persona.name
                : hasSystem ? t('Custom') : t('Persona');
            const badge = $('chatPersona');
            badge.hidden = !persona;
            if (persona) {
                badge.innerHTML = '';
                badge.appendChild(Icons.node(persona.icon || 'robot', { size: 11 }));
                badge.appendChild(el('span', null, persona.name));
            }

            const due = Store.schedules().filter(s => s.enabled).length;
            const schedChip = $('chipSchedules');
            schedChip.classList.toggle('is-active', due > 0);
            schedChip.querySelector('.chip-label').textContent = due
                ? t('{n} scheduled', { n: due })
                : t('Scheduled');

            const ghostChip = $('chipGhost');
            ghostChip.classList.toggle('is-active', !!conv.ephemeral);
            ghostChip.querySelector('.chip-label').textContent = conv.ephemeral
                ? t('Ghost on')
                : t('Ghost');

            const bot = Chat.botFor(conv);
            const botChip = $('chipBot');
            botChip.classList.toggle('is-active', !!bot);
            botChip.querySelector('.chip-label').textContent = bot ? bot.name : t('Bot');

            const space = Chat.workspaceFor(conv);
            const spaceChip = $('chipWorkspace');
            spaceChip.classList.toggle('is-active', !!space);
            spaceChip.querySelector('.chip-label').textContent = space
                ? space.name
                : t('Workspace');

            const webChip = $('chipWeb');
            webChip.classList.toggle('is-active', !!this.settings.webSearch);

            const anonChip = $('chipAnon');
            const anonOn = Anon.enabled();
            anonChip.classList.toggle('is-active', anonOn);
            anonChip.querySelector('.chip-label').textContent = anonOn ? t('Anon on') : t('Anon');

            $('menuPin').textContent = conv.pinned ? t('Unpin') : t('Pin');
            $('menuArchive').textContent = conv.archived ? t('Unarchive') : t('Archive');

            this.renderContextBar(repos, persona, hasSystem, space);
            this.renderBalance();
            this.updateHints();
        },

        renderContextBar(repos, persona, hasSystem, space) {
            const bar = $('contextBar');
            bar.innerHTML = '';
            const chips = [];
            for (const r of repos) {
                const chip = el('button', 'context-chip is-repo');
                chip.type = 'button';
                chip.title = t('Remove from this chat');
                chip.appendChild(document.createTextNode(
                    (r.label || r.repo) + (r.branch ? '@' + r.branch : '')));
                if (r.allowWrites) {
                    const w = el('span', 'chip-writes');
                    w.title = t('Writes are on');
                    w.appendChild(Icons.node('pencil', { size: 10 }));
                    chip.appendChild(w);
                }
                // A repository the workspace carries is not this chat's to drop:
                // it goes when the workspace does.
                const own = (this.conv.repoIds || []).includes(r.id);
                if (own) {
                    chip.appendChild(Icons.node('close', { size: 11, cls: 'x' }));
                    chip.addEventListener('click', () => {
                        this.conv = Store.updateConversation(this.conv.id, {
                            repoIds: (this.conv.repoIds || []).filter(id => id !== r.id)
                        });
                        this.refreshToolbar();
                    });
                } else {
                    chip.title = t('From the workspace');
                }
                chips.push(chip);
            }
            if (persona) {
                const chip = el('button', 'context-chip is-persona');
                chip.type = 'button';
                chip.appendChild(Icons.node(persona.icon || 'robot', { size: 11 }));
                chip.appendChild(document.createTextNode(persona.name));
                chip.appendChild(Icons.node('close', { size: 11, cls: 'x' }));
                chip.addEventListener('click', () => {
                    this.conv = Store.updateConversation(this.conv.id, { personaId: null });
                    this.refreshToolbar();
                });
                chips.push(chip);
            }
            if (space) {
                const chip = el('button', 'context-chip');
                chip.type = 'button';
                chip.appendChild(document.createTextNode(space.name));
                chip.appendChild(Icons.node('close', { size: 11, cls: 'x' }));
                chip.addEventListener('click', () => this.useWorkspace(null));
                chips.push(chip);
            }
            if (hasSystem) {
                const chip = el('button', 'context-chip');
                chip.type = 'button';
                chip.textContent = t('Custom instructions');
                chip.addEventListener('click', () => this.openSystem());
                chips.push(chip);
            }
            if (this.settings.webSearch) {
                const chip = el('button', 'context-chip');
                chip.type = 'button';
                chip.appendChild(document.createTextNode(t('Web search')));
                chip.appendChild(Icons.node('close', { size: 11, cls: 'x' }));
                chip.addEventListener('click', () => {
                    this.saveSettings({ webSearch: false });
                    this.refreshToolbar();
                });
                chips.push(chip);
            }
            for (const c of chips) bar.appendChild(c);
            bar.hidden = chips.length === 0;
        },

        setModel(model, forChat) {
            if (forChat) {
                this.conv = Store.updateConversation(this.conv.id, { proModel: model });
            } else {
                this.saveSettings({ proModel: model, tier: model ? 'pro' : 'standard' });
                if (this.conv && this.conv.proModel) {
                    this.conv = Store.updateConversation(this.conv.id, { proModel: null });
                }
            }
            this.refreshToolbar();
        },

        // --- models -----------------------------------------------------------

        async openModels(filter) {
            this.openModal('modalModels');
            const list = $('modelList');
            if (!this.models) {
                list.textContent = t('Loading the catalog…');
                this.models = await Api.models();
            }
            if (!this.models || !this.models.models) {
                list.textContent = t('The model catalog is unavailable right now.');
                return;
            }
            if (filter) $('modelSearch').value = filter;
            this.renderModels();
        },

        modelMatchesFilter(m) {
            const text = `${m.key} ${m.label} ${m.description || ''}`.toLowerCase();
            switch (this.modelFilter) {
                case 'cheap': return (m.credits || 0) <= 2;
                case 'reasoning': return /reason|think|o\d|r1|deep/.test(text);
                case 'vision': return /vision|image|multimodal|omni|4o|gemini|claude|gpt-4/.test(text);
                case 'code': return /code|coder|dev|engineer|sonnet|opus|qwen|kimi/.test(text);
                case 'favourites': return this.favourites.includes(m.key);
                default: return true;
            }
        },

        renderModels() {
            const term = ($('modelSearch').value || '').toLowerCase().trim();
            const list = $('modelList');
            list.innerHTML = '';
            const current = (this.conv && this.conv.proModel) || this.settings.proModel;
            const forChat = $('modelForChat').checked;
            const byKey = new Map(this.models.models.map(m => [m.key, m]));
            for (const group of this.models.groups || []) {
                const rows = group.keys
                    .map(k => byKey.get(k))
                    .filter(m => m
                        && (!term || m.key.toLowerCase().includes(term) || m.label.toLowerCase().includes(term))
                        && this.modelMatchesFilter(m));
                if (!rows.length) continue;
                list.appendChild(el('div', 'model-group', group.author));
                for (const m of rows) {
                    const row = el('button', 'model-row'
                        + (current && current.key === m.key ? ' is-active' : ''));
                    row.type = 'button';
                    const on = this.favourites.includes(m.key);
                    const star = el('span', 'model-star' + (on ? ' is-on' : ''));
                    star.appendChild(Icons.node('star', { size: 13, filled: on }));
                    star.title = t('Star this model');
                    star.addEventListener('click', (e) => {
                        e.stopPropagation();
                        this.favourites = this.favourites.includes(m.key)
                            ? this.favourites.filter(k => k !== m.key)
                            : this.favourites.concat(m.key);
                        Store.write('favouriteModels', this.favourites);
                        this.renderModels();
                    });
                    row.appendChild(star);
                    const name = el('span', 'model-name');
                    name.appendChild(document.createTextNode(m.label));
                    if (m.description) name.appendChild(el('span', 'model-desc', m.description));
                    row.appendChild(name);
                    row.appendChild(el('span', 'model-cost',
                        m.max && m.max !== m.credits ? `${m.credits}–${m.max}` : String(m.credits)));
                    row.addEventListener('click', () => {
                        this.setModel({ key: m.key, label: m.label, credits: m.credits, max: m.max }, forChat);
                        this.closeModals();
                        this.toast(forChat
                            ? t('{name} pinned to this chat.', { name: m.label })
                            : t('{name} pinned.', { name: m.label }));
                    });
                    list.appendChild(row);
                }
            }
            if (!list.children.length) list.textContent = t('Nothing matches that.');
        },

        openRepos() {
            this.repoEditing = null;
            this.resetRepoForm();
            this.renderRepos();
            this.openModal('modalRepos');
        },

        renderRepos() {
            const list = $('repoList');
            list.innerHTML = '';
            const repos = Store.repos();
            const on = new Set((this.conv && this.conv.repoIds) || []);
            if (!repos.length) {
                list.appendChild(el('p', 'hint', t('No repositories yet. Add one below and it becomes available to every chat.')));
            }
            for (const r of repos) {
                const row = el('div', 'repo-row' + (on.has(r.id) ? ' is-on' : ''));
                const check = document.createElement('input');
                check.type = 'checkbox';
                check.className = 'repo-check';
                check.checked = on.has(r.id);
                check.addEventListener('change', () => {
                    const next = new Set((this.conv.repoIds || []));
                    if (check.checked) next.add(r.id); else next.delete(r.id);
                    this.conv = Store.updateConversation(this.conv.id, { repoIds: Array.from(next) });
                    this.refreshToolbar();
                    this.renderRepos();
                    this.renderList();
                });
                row.appendChild(check);

                const main = el('div', 'repo-main');
                main.appendChild(el('span', 'repo-name', r.label ? `${r.label} — ${r.repo}` : r.repo));
                const bits = [r.provider || 'github'];
                if (r.host) bits.push(r.host);
                if (r.branch) bits.push(r.branch);
                if (r.paths) bits.push(r.paths);
                main.appendChild(el('span', 'repo-sub', bits.join(' · ')));
                row.appendChild(main);

                if (r.allowWrites) row.appendChild(el('span', 'repo-writes', t('writes')));

                const actions = el('div', 'row-actions');
                const edit = el('button', 'row-btn', t('Edit'));
                edit.type = 'button';
                edit.addEventListener('click', () => this.editRepo(r));
                actions.appendChild(edit);
                const del = el('button', 'row-btn danger', t('Remove'));
                del.type = 'button';
                del.addEventListener('click', async () => {
                    const ok = await this.ask({
                        title: t('Remove this repository'),
                        body: t('Remove {repo}? Its token is deleted from this device.', { repo: r.repo }),
                        confirm: t('Remove'),
                        danger: true
                    });
                    if (!ok) return;
                    Store.deleteRepo(r.id);
                    this.conv = Store.conversation(this.conv.id);
                    this.renderRepos();
                    this.refreshToolbar();
                    this.renderList();
                });
                actions.appendChild(del);
                row.appendChild(actions);
                list.appendChild(row);
            }
        },

        editRepo(repo) {
            this.repoEditing = repo.id;
            $('gitProvider').value = repo.provider || 'github';
            $('gitHost').value = repo.host || '';
            $('gitToken').value = repo.token || '';
            $('gitRepo').value = repo.repo || '';
            $('gitBranch').value = repo.branch || '';
            $('gitPaths').value = repo.paths || '';
            $('gitLabel').value = repo.label || '';
            $('gitWrites').checked = !!repo.allowWrites;
            $('repoFormTitle').textContent = t('Edit repository');
            $('repoSaveBtn').textContent = t('Save changes');
            $('repoResetBtn').hidden = false;
            this.modalStatus('gitStatus', '');
        },

        resetRepoForm() {
            this.repoEditing = null;
            $('gitProvider').value = 'github';
            $('gitHost').value = '';
            $('gitToken').value = '';
            $('gitRepo').value = '';
            $('gitBranch').value = '';
            $('gitPaths').value = '';
            $('gitLabel').value = '';
            $('gitWrites').checked = false;
            $('repoFormTitle').textContent = t('Add a repository');
            $('repoSaveBtn').textContent = t('Add repository');
            $('repoResetBtn').hidden = true;
            this.modalStatus('gitStatus', '');
        },

        saveRepo() {
            const cfg = {
                provider: $('gitProvider').value,
                host: $('gitHost').value.trim(),
                token: $('gitToken').value.trim(),
                repo: $('gitRepo').value.trim(),
                branch: $('gitBranch').value.trim(),
                paths: $('gitPaths').value.trim(),
                label: $('gitLabel').value.trim(),
                allowWrites: $('gitWrites').checked
            };
            if (!cfg.token || !cfg.repo) {
                this.modalStatus('gitStatus', t('A token and a repository are both needed.'), 'warn');
                return;
            }
            let entry;
            if (this.repoEditing) {
                entry = Store.updateRepo(this.repoEditing, cfg);
            } else {
                entry = Store.addRepo(cfg);
                const next = new Set((this.conv.repoIds || []));
                next.add(entry.id);
                this.conv = Store.updateConversation(this.conv.id, { repoIds: Array.from(next) });
            }
            this.resetRepoForm();
            this.renderRepos();
            this.refreshToolbar();
            this.renderList();
            this.modalStatus('gitStatus', t('Saved. Pin a Pro model to put it to work.'), 'ok');
        },

        openPersonas() {
            this.personaEditing = null;
            this.resetPersonaForm();
            this.renderPersonas();
            this.openModal('modalPersonas');
        },

        renderPersonas() {
            const list = $('personaList');
            list.innerHTML = '';
            const active = this.conv ? this.conv.personaId : null;
            for (const p of Store.personas()) {
                const row = el('div', 'persona-row' + (p.id === active ? ' is-on' : ''));
                const mark = el('span', 'persona-emoji');
                mark.appendChild(Icons.node(p.icon || 'robot', { size: 17 }));
                row.appendChild(mark);
                const main = el('div', 'persona-main');
                main.appendChild(el('span', 'persona-name', p.name));
                main.appendChild(el('span', 'persona-sub', (p.instructions || '').slice(0, 110)));
                main.style.cursor = 'pointer';
                main.addEventListener('click', () => {
                    this.conv = Store.updateConversation(this.conv.id, { personaId: p.id });
                    this.refreshToolbar();
                    this.renderPersonas();
                    this.toast(t('Persona set to {name}.', { name: p.name }));
                });
                row.appendChild(main);
                const actions = el('div', 'row-actions');
                const use = el('button', 'row-btn', p.id === active ? t('In use') : t('Use'));
                use.type = 'button';
                use.addEventListener('click', () => {
                    this.conv = Store.updateConversation(this.conv.id, {
                        personaId: p.id === active ? null : p.id
                    });
                    this.refreshToolbar();
                    this.renderPersonas();
                });
                actions.appendChild(use);
                const dup = el('button', 'row-btn', t('Copy'));
                dup.type = 'button';
                dup.addEventListener('click', () => {
                    this.personaEditing = null;
                    this.personaIcon = p.icon || 'robot';
                    this.renderPersonaIcons();
                    $('personaName').value = p.name + ' ' + t('(copy)');
                    $('personaBody').value = p.instructions || '';
                    $('personaFormTitle').textContent = t('New persona');
                    $('personaSaveBtn').textContent = t('Save persona');
                    $('personaResetBtn').hidden = false;
                });
                actions.appendChild(dup);
                if (!p.builtin) {
                    const edit = el('button', 'row-btn', t('Edit'));
                    edit.type = 'button';
                    edit.addEventListener('click', () => {
                        this.personaEditing = p.id;
                        this.personaIcon = p.icon || 'robot';
                        this.renderPersonaIcons();
                        $('personaName').value = p.name;
                        $('personaBody').value = p.instructions || '';
                        $('personaFormTitle').textContent = t('Edit persona');
                        $('personaSaveBtn').textContent = t('Save changes');
                        $('personaResetBtn').hidden = false;
                    });
                    actions.appendChild(edit);
                    const del = el('button', 'row-btn danger', t('Delete'));
                    del.type = 'button';
                    del.addEventListener('click', () => {
                        Store.deletePersona(p.id);
                        this.conv = Store.conversation(this.conv.id);
                        this.renderPersonas();
                        this.refreshToolbar();
                    });
                    actions.appendChild(del);
                }
                row.appendChild(actions);
                list.appendChild(row);
            }
        },

        renderPersonaIcons() {
            const box = $('personaIcons');
            box.innerHTML = '';
            for (const name of Icons.PERSONA_ICONS) {
                const b = el('button', 'icon-choice' + (name === this.personaIcon ? ' is-active' : ''));
                b.type = 'button';
                b.title = name;
                b.setAttribute('role', 'radio');
                b.setAttribute('aria-checked', String(name === this.personaIcon));
                b.appendChild(Icons.node(name, { size: 17 }));
                b.addEventListener('click', () => {
                    this.personaIcon = name;
                    this.renderPersonaIcons();
                });
                box.appendChild(b);
            }
        },

        resetPersonaForm() {
            this.personaEditing = null;
            this.personaIcon = 'robot';
            this.renderPersonaIcons();
            $('personaName').value = '';
            $('personaBody').value = '';
            $('personaFormTitle').textContent = t('New persona');
            $('personaSaveBtn').textContent = t('Save persona');
            $('personaResetBtn').hidden = true;
            this.modalStatus('personaStatus', '');
        },

        savePersona() {
            const name = $('personaName').value.trim();
            const instructions = $('personaBody').value.trim();
            if (!name || !instructions) {
                this.modalStatus('personaStatus', t('A name and some instructions are both needed.'), 'warn');
                return;
            }
            Store.savePersona({
                id: this.personaEditing || undefined,
                icon: this.personaIcon || 'robot',
                name,
                instructions
            });
            this.resetPersonaForm();
            this.renderPersonas();
            this.modalStatus('personaStatus', t('Saved.'), 'ok');
        },

        openSystem() {
            $('systemBody').value = (this.conv && this.conv.systemPrompt) || '';
            this.modalStatus('systemStatus', '');
            this.openModal('modalSystem');
        },

        saveSystem() {
            this.conv = Store.updateConversation(this.conv.id, { systemPrompt: $('systemBody').value.trim() });
            this.refreshToolbar();
            this.closeModals();
            this.toast(t('Custom instructions saved for this chat.'));
        },

        openPrompts(filter) {
            this.promptEditing = null;
            this.resetPromptForm();
            if (filter) $('promptSearch').value = filter;
            this.renderPrompts();
            this.openModal('modalPrompts');
        },

        renderPrompts() {
            const term = ($('promptSearch').value || '').toLowerCase().trim();
            const list = $('promptList');
            list.innerHTML = '';
            for (const p of Store.prompts()) {
                if (term && !(`${p.title} ${p.body}`.toLowerCase().includes(term))) continue;
                const row = el('div', 'prompt-row');
                const main = el('div', 'prompt-main');
                main.appendChild(el('span', 'prompt-name', p.title));
                main.appendChild(el('span', 'prompt-sub', p.body.replace(/\s+/g, ' ').slice(0, 120)));
                main.style.cursor = 'pointer';
                main.addEventListener('click', () => this.insertPrompt(p));
                row.appendChild(main);
                const actions = el('div', 'row-actions');
                const use = el('button', 'row-btn', t('Insert'));
                use.type = 'button';
                use.addEventListener('click', () => this.insertPrompt(p));
                actions.appendChild(use);
                const edit = el('button', 'row-btn', t('Edit'));
                edit.type = 'button';
                edit.addEventListener('click', () => {
                    this.promptEditing = p.id;
                    $('promptTitle').value = p.title;
                    $('promptBody').value = p.body;
                    $('promptFormTitle').textContent = t('Edit prompt');
                    $('promptSaveBtn').textContent = t('Save changes');
                    $('promptResetBtn').hidden = false;
                });
                actions.appendChild(edit);
                const del = el('button', 'row-btn danger', t('Delete'));
                del.type = 'button';
                del.addEventListener('click', () => {
                    Store.deletePrompt(p.id);
                    this.renderPrompts();
                });
                actions.appendChild(del);
                row.appendChild(actions);
                list.appendChild(row);
            }
            if (!list.children.length) list.appendChild(el('p', 'hint', t('Nothing matches that.')));
        },

        async insertPrompt(prompt) {
            let body = prompt.body;
            const blanks = Array.from(new Set((body.match(/\{\{(\w+)\}\}/g) || [])
                .map(x => x.replace(/[{}]/g, ''))));
            this.closeModals();
            for (const blank of blanks) {
                const value = await this.ask({
                    title: prompt.title,
                    label: blank,
                    area: blank === 'code' || blank === 'diff' || blank === 'text',
                    prompt: !(blank === 'code' || blank === 'diff' || blank === 'text'),
                    confirm: t('Next')
                });
                if (value == null) return;
                body = body.split('{{' + blank + '}}').join(value);
            }
            const input = $('input');
            input.value = body;
            this.autoGrow();
            this.updateHints();
            input.focus();
        },

        resetPromptForm() {
            this.promptEditing = null;
            $('promptTitle').value = '';
            $('promptBody').value = '';
            $('promptFormTitle').textContent = t('New prompt');
            $('promptSaveBtn').textContent = t('Save prompt');
            $('promptResetBtn').hidden = true;
            this.modalStatus('promptStatus', '');
        },

        savePrompt() {
            const title = $('promptTitle').value.trim();
            const body = $('promptBody').value.trim();
            if (!title || !body) {
                this.modalStatus('promptStatus', t('A title and a body are both needed.'), 'warn');
                return;
            }
            Store.savePrompt({ id: this.promptEditing || undefined, title, body });
            this.resetPromptForm();
            this.renderPrompts();
            this.modalStatus('promptStatus', t('Saved.'), 'ok');
        },

        openPinned() {
            const list = $('pinnedList');
            list.innerHTML = '';
            const rows = Store.pinnedMessages();
            if (!rows.length) {
                list.appendChild(el('p', 'hint', t('Nothing saved yet. Use the star under any message.')));
            }
            for (const { conv, message } of rows) {
                const row = el('div', 'pinned-row');
                const main = el('div', 'pinned-main');
                main.appendChild(el('span', 'search-name', conv.title || t('New chat')));
                main.appendChild(el('span', 'search-sub', MD.plain(message.content).slice(0, 180)));
                main.style.cursor = 'pointer';
                main.addEventListener('click', () => {
                    this.closeModals();
                    this.open(Store.conversation(conv.id));
                    setTimeout(() => this.jumpToMessage(message.id), 60);
                });
                row.appendChild(main);
                const actions = el('div', 'row-actions');
                const copy = el('button', 'row-btn', t('Copy'));
                copy.type = 'button';
                copy.addEventListener('click', () => this.writeClipboard(message.content));
                actions.appendChild(copy);
                const un = el('button', 'row-btn danger', t('Remove'));
                un.type = 'button';
                un.addEventListener('click', () => {
                    Store.patchMessage(conv.id, message.id, { pinned: false });
                    this.openPinned();
                    if (this.conv.id === conv.id) this.renderMessages();
                });
                actions.appendChild(un);
                row.appendChild(actions);
                list.appendChild(row);
            }
            this.openModal('modalPinned');
        },

        openSearch(term) {
            if (term != null) $('globalSearch').value = term;
            this.renderSearch();
            this.openModal('modalSearch');
            setTimeout(() => $('globalSearch').focus(), 20);
        },

        renderSearch() {
            const term = $('globalSearch').value;
            const list = $('searchList');
            list.innerHTML = '';
            if (!term.trim()) {
                list.appendChild(el('p', 'hint', t('Type to search every message on this device.')));
                return;
            }
            const rows = Store.searchAll(term, { includeArchived: $('searchArchived').checked });
            if (!rows.length) {
                list.appendChild(el('p', 'hint', t('Nothing matches that.')));
                return;
            }
            for (const hit of rows.slice(0, 120)) {
                const row = el('button', 'search-row');
                row.type = 'button';
                const main = el('div', 'search-main');
                main.appendChild(el('span', 'search-name', hit.conv.title || t('New chat')));
                main.appendChild(el('span', 'search-sub', hit.excerpt));
                row.appendChild(main);
                row.addEventListener('click', () => {
                    this.closeModals();
                    this.open(Store.conversation(hit.conv.id));
                    if (hit.message) setTimeout(() => this.jumpToMessage(hit.message.id), 60);
                });
                list.appendChild(row);
            }
        },

        jumpToMessage(id) {
            const node = $('messages').querySelector(`.chat-message[data-id="${id}"]`);
            if (!node) return;
            node.scrollIntoView({ block: 'center' });
            node.classList.add('is-hit');
            setTimeout(() => node.classList.remove('is-hit'), 2200);
        },

        openFind() {
            $('findBar').hidden = false;
            $('findInput').focus();
            $('findInput').select();
        },

        closeFind() {
            $('findBar').hidden = true;
            $('findInput').value = '';
            $('findCount').textContent = '';
            this.findMatches = [];
            for (const n of $('messages').querySelectorAll('.is-hit')) n.classList.remove('is-hit');
        },

        runFind() {
            const term = $('findInput').value.toLowerCase().trim();
            for (const n of $('messages').querySelectorAll('.is-hit')) n.classList.remove('is-hit');
            if (!term) { this.findMatches = []; $('findCount').textContent = ''; return; }
            this.findMatches = Store.messages(this.conv.id)
                .filter(m => (m.content || '').toLowerCase().includes(term))
                .map(m => m.id);
            this.findAt = 0;
            $('findCount').textContent = this.findMatches.length
                ? t('{n} of {total}', { n: 1, total: this.findMatches.length })
                : t('none');
            if (this.findMatches.length) this.jumpToMessage(this.findMatches[0]);
        },

        stepFind(delta) {
            if (!this.findMatches.length) return;
            this.findAt = (this.findAt + delta + this.findMatches.length) % this.findMatches.length;
            $('findCount').textContent = t('{n} of {total}',
                { n: this.findAt + 1, total: this.findMatches.length });
            this.jumpToMessage(this.findMatches[this.findAt]);
        },

        openTags() {
            $('tagInput').value = (this.conv.tags || []).join(', ');
            const select = $('folderSelect');
            select.innerHTML = '';
            const none = document.createElement('option');
            none.value = '';
            none.textContent = t('No folder');
            select.appendChild(none);
            for (const folder of Store.folders()) {
                const option = document.createElement('option');
                option.value = folder.id;
                option.textContent = folder.name;
                option.selected = folder.id === this.conv.folderId;
                select.appendChild(option);
            }
            $('newFolder').value = '';
            this.modalStatus('tagStatus', '');
            this.openModal('modalTags');
        },

        saveTags() {
            const tags = $('tagInput').value.split(',').map(x => x.trim()).filter(Boolean);
            this.conv = Store.updateConversation(this.conv.id, {
                tags,
                folderId: $('folderSelect').value || null
            });
            this.renderList();
            this.closeModals();
            this.toast(t('Saved.'));
        },

        createFolder() {
            const name = $('newFolder').value.trim();
            if (!name) return;
            const folder = Store.saveFolder({ name });
            $('newFolder').value = '';
            this.openTags();
            $('folderSelect').value = folder.id;
            this.modalStatus('tagStatus', t('Folder created.'), 'ok');
        },

        openStats() {
            const msgs = Store.messages(this.conv.id);
            const grid = $('statGrid');
            grid.innerHTML = '';
            const mine = msgs.filter(m => m.role === 'self').length;
            const theirs = msgs.filter(m => m.role === 'bot').length;
            const credits = msgs.reduce((n, m) => n + (m.cost || 0), 0);
            const words = msgs.reduce((n, m) => n + MD.plain(m.content).split(/\s+/).filter(Boolean).length, 0);
            const usage = Store.usage();
            const cells = [
                [String(mine), t('Messages sent')],
                [String(theirs), t('Replies')],
                [String(credits), t('Credits spent here')],
                [String(words), t('Words exchanged')],
                [String(usage.credits), t('Credits spent overall')],
                [String(usage.replies), t('Replies overall')]
            ];
            for (const [value, label] of cells) {
                const cell = el('div', 'stat-cell');
                cell.appendChild(el('strong', null, value));
                cell.appendChild(el('span', null, label));
                grid.appendChild(cell);
            }
            this.openModal('modalStats');
        },

        openAppearance() {
            const s = this.settings;
            $('setTheme').value = s.theme || 'system';
            $('setDensity').value = s.density || 'comfortable';
            $('setFont').value = String(s.fontScale || 1);
            $('setGrouping').value = s.sidebarGrouping || 'date';
            $('setBubbles').checked = s.bubbles !== false;
            $('setAvatars').checked = s.avatars !== false;
            $('setTimestamps').checked = s.timestamps !== false;
            $('setTypewriter').checked = !!s.typewriter;
            $('setReasoning').checked = !!s.showReasoningByDefault;
            $('setMono').checked = !!s.monospaceReplies;
            $('setLineNumbers').checked = !!s.lineNumbers;
            $('setCodeWrap').checked = !!s.codeWrap;
            $('setMotion').checked = !!s.reduceMotion;
            $('setEnter').checked = s.sendOnEnter !== false;
            $('setEstimate').checked = s.showTokenEstimate !== false;
            $('setSound').checked = !!s.soundOnReply;
            $('setHaptic').checked = !!s.hapticOnReply;
            $('setAutoSpeak').checked = !!s.autoSpeak;
            $('setRate').value = String(s.speechRate || 1);
            $('setAutoDelete').value = String(s.autoDeleteDays || 0);
            $('setAutoContinue').value = String(s.autoContinue || 0);
            $('setProgress').checked = s.showProgress !== false;
            this.renderVoices();
            $('voiceFields').hidden = !Speech.canSpeak();
            this.modalStatus('appearanceStatus', '');
            this.openModal('modalAppearance');
        },

        renderVoices() {
            const select = $('setVoice');
            select.innerHTML = '';
            const voices = Speech.voices();
            const none = document.createElement('option');
            none.value = '';
            none.textContent = t('Default voice');
            select.appendChild(none);
            for (const v of voices) {
                const option = document.createElement('option');
                option.value = v.voiceURI;
                option.textContent = `${v.name} (${v.lang})`;
                option.selected = v.voiceURI === this.settings.voiceUri;
                select.appendChild(option);
            }
        },

        readAppearance() {
            this.saveSettings({
                theme: $('setTheme').value,
                density: $('setDensity').value,
                fontScale: Number($('setFont').value) || 1,
                sidebarGrouping: $('setGrouping').value,
                bubbles: $('setBubbles').checked,
                avatars: $('setAvatars').checked,
                timestamps: $('setTimestamps').checked,
                typewriter: $('setTypewriter').checked,
                showReasoningByDefault: $('setReasoning').checked,
                monospaceReplies: $('setMono').checked,
                lineNumbers: $('setLineNumbers').checked,
                codeWrap: $('setCodeWrap').checked,
                reduceMotion: $('setMotion').checked,
                sendOnEnter: $('setEnter').checked,
                showTokenEstimate: $('setEstimate').checked,
                soundOnReply: $('setSound').checked,
                hapticOnReply: $('setHaptic').checked,
                autoSpeak: $('setAutoSpeak').checked,
                voiceUri: $('setVoice').value || null,
                speechRate: Number($('setRate').value) || 1,
                autoDeleteDays: Number($('setAutoDelete').value) || 0,
                autoContinue: Number($('setAutoContinue').value) || 0,
                showProgress: $('setProgress').checked
            });
            this.renderList();
            this.renderMessages();
            this.refreshToolbar();
        },

        openShortcuts() {
            const list = $('shortcutList');
            list.innerHTML = '';
            for (const s of shortcuts()) {
                const row = el('div', 'shortcut-row');
                const keys = el('span', 'shortcut-keys');
                for (const k of s.keys) keys.appendChild(el('kbd', null, k));
                row.appendChild(keys);
                row.appendChild(el('span', null, s.what));
                list.appendChild(row);
            }
            this.openModal('modalShortcuts');
        },

        openArtifact(id) {
            const entry = Artifacts.get(this.conv.id, id);
            if (!entry) return;
            this.artifact = entry;
            $('artifactTitle').value = entry.title;
            $('artifactLang').textContent = entry.lang || 'text';
            $('artifactBody').value = entry.body;
            $('artifactSave').hidden = true;
            this.modalStatus('artifactStatus', '');
            $('artifactPanel').hidden = false;
            document.querySelector('.shell').classList.add('has-artifact');
            this.setArtifactTab(Artifacts.previewable(entry.lang) ? 'preview' : 'source');
            this.renderArtifactStrip();
        },

        closeArtifact() {
            this.artifact = null;
            $('artifactPanel').hidden = true;
            $('artifactFrame').srcdoc = '';
            document.querySelector('.shell').classList.remove('has-artifact');
            this.renderArtifactStrip();
        },

        setArtifactTab(tab) {
            const entry = this.artifact;
            if (!entry) return;
            const canPreview = Artifacts.previewable(entry.lang);
            this.artifactTab = (tab === 'preview' && !canPreview) ? 'source' : tab;
            for (const b of document.querySelectorAll('.artifact-tabs .pill')) {
                b.classList.toggle('is-active', b.dataset.tab === this.artifactTab);
                b.hidden = b.dataset.tab === 'preview' && !canPreview;
            }
            $('artifactPreview').hidden = this.artifactTab !== 'preview';
            $('artifactSource').hidden = this.artifactTab !== 'source';
            $('artifactVersions').hidden = this.artifactTab !== 'versions';
            if (this.artifactTab === 'preview') this.renderArtifactPreview();
            if (this.artifactTab === 'versions') this.renderArtifactVersions();
        },

        renderArtifactPreview() {
            const entry = this.artifact;
            if (!entry) return;
            const lang = (entry.lang || '').toLowerCase();
            const frame = $('artifactFrame');
            const reader = $('artifactReader');
            if (lang === 'markdown' || lang === 'md') {
                frame.hidden = true;
                reader.hidden = false;
                reader.innerHTML = MD.render(entry.body, {
                    wrap: this.settings.codeWrap,
                    lineNumbers: this.settings.lineNumbers
                });
                return;
            }
            reader.hidden = true;
            frame.hidden = false;
            frame.srcdoc = lang === 'svg'
                ? `<body style="margin:0;display:grid;place-items:center;min-height:100vh;background:#fff">${entry.body}</body>`
                : entry.body;
        },

        renderArtifactVersions() {
            const entry = this.artifact;
            if (!entry) return;
            const list = $('versionList');
            list.innerHTML = '';
            const versions = (entry.versions || []).slice().reverse();
            versions.forEach((v, i) => {
                const at = versions.length - i;
                const row = el('div', 'version-row' + (i === 0 ? ' is-current' : ''));
                const main = el('div', 'version-main');
                main.appendChild(el('span', 'version-name', t('Version {n}', { n: at })));
                main.appendChild(el('span', 'version-sub',
                    `${this.dayLabel(v.at)} ${this.timeLabel(v.at)} · `
                    + t('{n} lines', { n: String(v.body || '').split('\n').length })));
                row.appendChild(main);
                if (i !== 0) {
                    const back = el('button', 'row-btn', t('Restore'));
                    back.type = 'button';
                    back.addEventListener('click', () => {
                        const index = (entry.versions || []).length - 1 - i;
                        const updated = Artifacts.revert(this.conv.id, entry.id, index);
                        if (updated) {
                            this.artifact = updated;
                            $('artifactBody').value = updated.body;
                            this.renderArtifactVersions();
                            this.toast(t('Restored.'));
                        }
                    });
                    row.appendChild(back);
                }
                list.appendChild(row);
            });
            if (!versions.length) list.appendChild(el('p', 'hint', t('No versions yet.')));
        },

        saveArtifact() {
            const entry = this.artifact;
            if (!entry) return;
            const updated = Artifacts.update(this.conv.id, entry.id, $('artifactBody').value);
            if (!updated) return;
            this.artifact = updated;
            $('artifactSave').hidden = true;
            this.modalStatus('artifactStatus',
                t('Saved as version {n}.', { n: (updated.versions || []).length }), 'ok');
            this.renderMessages();
            if (this.artifactTab === 'preview') this.renderArtifactPreview();
        },

        renderArtifactStrip() {
            const made = Artifacts.all(this.conv.id);
            const chip = $('chipArtifacts');
            chip.hidden = made.length === 0;
            chip.classList.toggle('is-active', !!this.artifact);
            chip.querySelector('.chip-label').textContent = made.length === 1
                ? t('1 artifact')
                : t('{n} artifacts', { n: made.length });
        },

        openArtifactList() {
            const made = Artifacts.all(this.conv.id).slice().reverse();
            const list = $('artifactList');
            list.innerHTML = '';
            if (!made.length) {
                list.appendChild(el('p', 'hint',
                    t('Nothing yet. A reply with a whole file in it lands here.')));
            }
            for (const a of made) {
                const row = el('div', 'repo-row');
                const main = el('div', 'repo-main');
                main.appendChild(el('span', 'repo-name', a.title));
                main.appendChild(el('span', 'repo-sub', [
                    a.lang || 'text',
                    t('{n} lines', { n: a.body.split('\n').length }),
                    t('v{n}', { n: (a.versions || []).length })
                ].join(' · ')));
                main.style.cursor = 'pointer';
                main.addEventListener('click', () => {
                    this.closeModals();
                    this.openArtifact(a.id);
                });
                row.appendChild(main);
                const actions = el('div', 'row-actions');
                const open = el('button', 'row-btn', t('Open'));
                open.type = 'button';
                open.addEventListener('click', () => {
                    this.closeModals();
                    this.openArtifact(a.id);
                });
                actions.appendChild(open);
                const del = el('button', 'row-btn danger', t('Delete'));
                del.type = 'button';
                del.addEventListener('click', () => {
                    Artifacts.remove(this.conv.id, a.id);
                    if (this.artifact && this.artifact.id === a.id) this.closeArtifact();
                    this.openArtifactList();
                    this.renderArtifactStrip();
                    this.renderMessages();
                });
                actions.appendChild(del);
                row.appendChild(actions);
                list.appendChild(row);
            }
            this.openModal('modalArtifacts');
        },

        /// A chip only ever showed a title. A card shows where it came from
        /// and what it said, which is what makes a citation checkable rather
        /// than decorative. The mark is a letter, never a fetched favicon, so
        /// a citation cannot become a tracking pixel.
        citationCards(sources) {
            const wrap = el('div', 'citations');
            const cards = sources.slice(0, 8);
            wrap.appendChild(el('p', 'citations-head', cards.length === 1
                ? t('1 source')
                : t('{n} sources', { n: cards.length })));
            cards.forEach((s, i) => {
                const url = typeof s.url === 'string' ? s.url : '';
                let host = '';
                try {
                    host = url ? new URL(url).hostname.replace(/^www\./, '') : '';
                } catch (_) { }
                const title = s.title || s.name || host || t('source');
                const card = el(url ? 'a' : 'div', 'citation');
                if (url) {
                    card.href = url;
                    card.target = '_blank';
                    card.rel = 'noopener noreferrer';
                }
                const mark = el('span', 'citation-mark',
                    (host || title).slice(0, 1).toUpperCase());
                card.appendChild(mark);
                const main = el('span', 'citation-main');
                main.appendChild(el('strong', null, `${i + 1}. ${title}`));
                if (host) main.appendChild(el('span', 'citation-host', host));
                const snippet = s.snippet || s.description || s.excerpt || '';
                if (snippet) main.appendChild(el('span', 'citation-snippet', snippet));
                card.appendChild(main);
                if (url) card.appendChild(Icons.node('link', { size: 12 }));
                wrap.appendChild(card);
            });
            return wrap;
        },

        // --- what a reply cost -------------------------------------------------

        /// Everything the device actually knows about one reply's price. It is
        /// deliberately not an estimate re-run after the fact: what is shown is
        /// what the worker charged and what it said it did to earn it.
        costRows(m) {
            const pro = !!m.model;
            const sats = m.cost * C.satsPerCredit[pro ? 'pro' : 'standard'];
            const rows = [
                [t('Charged'), t('{n} credits', { n: m.cost })],
                [t('Tier'), pro ? t('Pro') : t('Standard')],
                [t('Model'), m.model || t('Auto-routed')],
                [t('At today\'s price'), t('{n} sats', { n: sats })]
            ];
            if (m.calls && m.calls > 1) {
                rows.push([t('Model calls'), String(m.calls)]);
            }
            if (m.task) rows.push([t('Routed as'), m.task]);
            if (m.repos && m.repos.length) {
                rows.push([t('Repositories read'), m.repos.join(', ')]);
            }
            if (m.sources && m.sources.length) {
                rows.push([t('Sources read'), String(m.sources.length)]);
            }
            rows.push([t('When'), `${this.dayLabel(m.ts)} ${this.timeLabel(m.ts)}`]);
            return rows;
        },

        openCost(m) {
            const box = $('costRows');
            box.innerHTML = '';
            for (const [label, value] of this.costRows(m)) {
                const row = el('div', 'cost-row');
                row.appendChild(el('span', 'cost-label', label));
                row.appendChild(el('span', 'cost-value', value));
                box.appendChild(row);
            }
            $('costNote').textContent = m.model
                ? t('A Pro reply costs the model\'s base and then scales with the length of the answer, up to that model\'s cap. The cap is held when you send and only the real cost is taken.')
                : t('A standard reply is one credit, whichever model the router picked for it.');
            this.openModal('modalCost');
        },

        // --- help --------------------------------------------------------------

        helpTopics() {
            return [
                {
                    title: t('Asking, and what it costs'),
                    body: t('Every reply is paid for a message at a time, in credits you buy over Lightning. Standard replies are auto-routed; Pro pins a model you choose. The toolbar says which is answering and roughly what the next reply will cost. Type ? in the composer for the full list of commands.')
                },
                {
                    title: t('Artifacts'),
                    body: t('A reply that contains a whole page, script or document opens beside the chat instead of scrolling away. Edit it there and every save is kept as a version you can restore. Rewriting the same file in a later reply updates the artifact rather than making a second copy.')
                },
                {
                    title: t('Comparing two models'),
                    body: t('Compare sends one prompt to two models at once, each on its own thread, so neither sees the other\'s answer. Keep the one you prefer and the chat carries on from it. Two replies means two charges.')
                },
                {
                    title: t('Workspaces'),
                    body: t('A workspace is standing context a run of chats shares: instructions, reference files and repositories. Every chat in one starts with that context, and a new chat opened from it inherits the workspace. The files stay on this device.')
                },
                {
                    title: t('Bots'),
                    body: t('A bot is a way of answering: a name, standing instructions, a model and a few openers. Share one as a link or publish it under your npub. A shared bot carries none of your repositories, tokens or files — only how it answers.')
                },
                {
                    title: t('Repositories'),
                    body: t('Connect as many repositories as you like and tick the ones a chat can see. Pro replies read their code and, with writes on, commit, branch and open pull requests. Access tokens are stored only on this device and sent per request — never stored server-side or published to relays.')
                },
                {
                    title: t('Ghost chats and auto-delete'),
                    body: t('A ghost chat is never written to this device and publishes no archive copy: it is gone when you close the app. Auto-delete sweeps chats older than the window you choose when the app opens, and never touches a pinned one.')
                },
                {
                    title: t('Long tasks, and carrying them on'),
                    body: t('A repo task runs the model in a loop — reading, searching, writing — and that loop has an allowance. When it runs out with work left, Nymbot stops and says so. Set a continuation budget in Appearance and it buys another allowance instead, one leg at a time, each leg saying what it cost, until the budget is spent or the task is done. Stop cancels the rest.')
                },
                {
                    title: t('Watching it work'),
                    body: t('While a reply is generating, Nymbot reports what it is doing under the spinner: what it routed to, what it searched for, which files it is reading, which model call it is on, and the model\'s own reasoning as each call returns. It is scoped to the key that asked — in anonymous mode that is the throwaway key, so watching reveals nothing the message did not.')
                },
                {
                    title: t('Scheduled prompts'),
                    body: t('A prompt Nymbot sends for you: once, hourly, daily or weekly. There is no server doing it — a run happens while the app is open, and a run that came due while it was shut fires once when you come back.')
                },
                {
                    title: t('Anonymous mode'),
                    body: t('Anonymous mode routes a chat through a throwaway key funded by blind vouchers, so the credits cannot be matched to your nym. Turn on the automatic transfer and the key tops itself up rather than being funded by hand.')
                },
                {
                    title: t('Your keys and your data'),
                    body: t('Your private key lives on this device. Your public key — npub or hex — is how somebody addresses you and is safe to share. The post-quantum recovery code is what lets a second device hold the same encryption key. Export everything from Appearance; there is no account on a server to recover from.')
                },
                {
                    title: t('Voice, attachments and export'),
                    body: t('Dictate a message with the microphone and have replies read aloud from Appearance. Attach text, code and images to a message. Any conversation exports as Markdown, plain text or JSON.')
                },
                {
                    title: t('Keyboard'),
                    body: t('Command palette with Ctrl/Cmd+K, new chat with Ctrl/Cmd+N, find in chat with Ctrl/Cmd+F, search everything with Ctrl/Cmd+Shift+F. The full list is under Keyboard shortcuts in Appearance.')
                }
            ];
        },

        openHelp(term) {
            $('helpSearch').value = term || '';
            this.renderHelp();
            this.openModal('modalHelp');
        },

        renderHelp() {
            const needle = ($('helpSearch').value || '').toLowerCase().trim();
            const box = $('helpBody');
            box.innerHTML = '';
            const topics = this.helpTopics().filter(x => !needle
                || x.title.toLowerCase().includes(needle)
                || x.body.toLowerCase().includes(needle));
            if (!topics.length) {
                box.appendChild(el('p', 'hint',
                    t('Nothing in the guide matches that. The knowledge base is fuller, or email us.')));
                return;
            }
            for (const topic of topics) {
                const item = el('details', 'help-topic');
                if (needle) item.open = true;
                const head = el('summary', null, topic.title);
                item.appendChild(head);
                item.appendChild(el('p', null, topic.body));
                box.appendChild(item);
            }
        },

        /// Paints a scrollbar only while something is being scrolled. Capture,
        /// because a scroll event does not bubble, and passive so it can never
        /// hold up the scroll it is watching.
        watchScrolling() {
            const fades = new WeakMap();
            document.addEventListener('scroll', (e) => {
                const node = e.target === document || e.target === window
                    ? document.documentElement
                    : e.target;
                if (!node || !node.classList) return;
                node.classList.add('is-scrolling');
                clearTimeout(fades.get(node));
                fades.set(node, setTimeout(() => node.classList.remove('is-scrolling'), 900));
            }, { capture: true, passive: true });
        },

        // --- scheduled prompts -------------------------------------------------

        openSchedules() {
            if (!this.scheduleEditing) this.resetScheduleForm();
            this.renderSchedules();
            this.openModal('modalSchedules');
        },

        localInputValue(ts) {
            const d = new Date(ts);
            const pad = (n) => String(n).padStart(2, '0');
            return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
                + `T${pad(d.getHours())}:${pad(d.getMinutes())}`;
        },

        resetScheduleForm() {
            this.scheduleEditing = null;
            $('scheduleTitle').value = '';
            $('schedulePrompt').value = '';
            $('scheduleRepeat').value = 'daily';
            $('scheduleWhen').value = this.localInputValue(Date.now() + 3600000);
            $('scheduleHere').checked = false;
            $('scheduleFormTitle').textContent = t('New scheduled prompt');
            this.modalStatus('scheduleStatus', '');
        },

        editSchedule(id) {
            const entry = Store.schedule(id);
            if (!entry) return;
            this.scheduleEditing = id;
            $('scheduleTitle').value = entry.title || '';
            $('schedulePrompt').value = entry.prompt || '';
            $('scheduleRepeat').value = entry.repeat || 'once';
            $('scheduleWhen').value = this.localInputValue(entry.nextAt || Date.now());
            $('scheduleHere').checked = !!entry.convId;
            $('scheduleFormTitle').textContent = t('Edit scheduled prompt');
            this.modalStatus('scheduleStatus', '');
        },

        repeatLabel(repeat) {
            switch (repeat) {
                case 'hourly': return t('Every hour');
                case 'daily': return t('Every day');
                case 'weekly': return t('Every week');
                default: return t('Once');
            }
        },

        renderSchedules() {
            const list = $('scheduleList');
            list.innerHTML = '';
            const all = Store.schedules();
            if (!all.length) {
                list.appendChild(el('p', 'hint',
                    t('Nothing scheduled. A standing question — a digest, a check on a repository — goes here.')));
            }
            for (const entry of all) {
                const row = el('div', 'repo-row' + (entry.enabled ? ' is-on' : ''));
                const main = el('div', 'repo-main');
                main.appendChild(el('span', 'repo-name', entry.title || t('Untitled')));
                const when = entry.enabled
                    ? `${this.dayLabel(entry.nextAt)} ${this.timeLabel(entry.nextAt)}`
                    : t('Paused');
                main.appendChild(el('span', 'repo-sub', [
                    this.repeatLabel(entry.repeat),
                    when,
                    entry.runs ? t('{n} runs', { n: entry.runs }) : t('never run')
                ].join(' · ')));
                row.appendChild(main);
                const actions = el('div', 'row-actions');
                const toggle = el('button', 'row-btn', entry.enabled ? t('Pause') : t('Resume'));
                toggle.type = 'button';
                toggle.addEventListener('click', () => {
                    Store.saveSchedule(Object.assign({}, entry, { enabled: !entry.enabled }));
                    this.renderSchedules();
                    this.refreshToolbar();
                });
                actions.appendChild(toggle);
                const now = el('button', 'row-btn', t('Run now'));
                now.type = 'button';
                now.addEventListener('click', () => this.runSchedule(entry.id));
                actions.appendChild(now);
                const edit = el('button', 'row-btn', t('Edit'));
                edit.type = 'button';
                edit.addEventListener('click', () => this.editSchedule(entry.id));
                actions.appendChild(edit);
                const del = el('button', 'row-btn danger', t('Delete'));
                del.type = 'button';
                del.addEventListener('click', () => {
                    Store.deleteSchedule(entry.id);
                    if (this.scheduleEditing === entry.id) this.resetScheduleForm();
                    this.renderSchedules();
                    this.refreshToolbar();
                });
                actions.appendChild(del);
                row.appendChild(actions);
                list.appendChild(row);
            }
        },

        saveScheduleForm() {
            const prompt = ($('schedulePrompt').value || '').trim();
            if (!prompt) {
                this.modalStatus('scheduleStatus', t('Give it something to ask.'), 'warn');
                return;
            }
            const when = $('scheduleWhen').value
                ? new Date($('scheduleWhen').value).getTime()
                : Date.now();
            if (!Number.isFinite(when)) {
                this.modalStatus('scheduleStatus', t('That is not a time.'), 'warn');
                return;
            }
            const prior = this.scheduleEditing ? Store.schedule(this.scheduleEditing) : null;
            Store.saveSchedule(Object.assign({}, prior || {}, {
                id: this.scheduleEditing || undefined,
                title: ($('scheduleTitle').value || '').trim() || Chat.titleFor(prompt),
                prompt,
                repeat: $('scheduleRepeat').value,
                nextAt: when,
                convId: $('scheduleHere').checked && this.conv ? this.conv.id : null,
                enabled: true
            }));
            this.resetScheduleForm();
            this.renderSchedules();
            this.refreshToolbar();
            this.modalStatus('scheduleStatus', t('Saved.'), 'ok');
        },

        advance(entry) {
            const step = { hourly: 3600000, daily: 86400000, weekly: 604800000 }[entry.repeat];
            if (!step) return Object.assign({}, entry, { enabled: false, runs: (entry.runs || 0) + 1 });
            // Forward to the next slot after now, so a run missed while the app
            // was shut does not queue up every slot it went past.
            let next = entry.nextAt + step;
            while (next <= Date.now()) next += step;
            return Object.assign({}, entry, {
                nextAt: next, runs: (entry.runs || 0) + 1, lastRunAt: Date.now()
            });
        },

        /// Nothing runs on a server, so a run happens here, in the open tab,
        /// and only when the app is not already waiting on a reply.
        async runSchedule(id) {
            const entry = Store.schedule(id);
            if (!entry || this.sending) return;
            const target = entry.convId ? Store.conversation(entry.convId) : null;
            const conv = target || this.newConversation({ title: entry.title });
            if (!this.conv || this.conv.id !== conv.id) this.open(conv);
            this.closeModals();
            Store.saveSchedule(this.advance(entry));
            this.renderSchedules();
            this.refreshToolbar();
            this.note(t('Running “{name}”.', { name: entry.title || t('Untitled') }));
            await this.send(entry.prompt);
        },

        dueSchedules() {
            const now = Date.now();
            return Store.schedules().filter(s => s.enabled && (s.nextAt || 0) <= now);
        },

        async runDueSchedules() {
            if (this.sending) return;
            const due = this.dueSchedules();
            if (!due.length) return;
            await this.runSchedule(due[0].id);
        },

        startScheduler() {
            if (this._schedulerTimer) clearInterval(this._schedulerTimer);
            this._schedulerTimer = setInterval(() => {
                this.runDueSchedules().catch(() => { });
            }, 60000);
        },

        // --- ghost mode --------------------------------------------------------

        /// Turning it on moves what has already been said off the disk, and
        /// turning it off writes back what is on screen — so the switch never
        /// silently loses a conversation either way.
        async toggleGhost() {
            if (!this.conv) return;
            const on = !this.conv.ephemeral;
            if (on) {
                const go = await this.ask({
                    title: t('Make this a ghost chat?'),
                    body: t('Nothing it says will be written to this device, and no archive copy will be published. It is gone when you close the app.'),
                    confirm: t('Make it a ghost')
                });
                if (!go) return;
                Store.makeGhost(this.conv.id);
                this.conv = Store.updateConversation(this.conv.id, { ephemeral: true });
            } else {
                this.conv = Store.updateConversation(this.conv.id, { ephemeral: false });
                Store.unmakeGhost(this.conv.id);
            }
            this.refreshToolbar();
            this.renderList();
            this.toast(on
                ? t('Ghost chat. Nothing here is being kept.')
                : t('This chat is being kept again.'));
        },

        // --- bots --------------------------------------------------------------

        async openBots() {
            this.renderBotIcons();
            await this.fillBotModels();
            this.renderBots();
            this.openModal('modalBots');
        },

        async fillBotModels() {
            const sel = $('botModel');
            if (sel.dataset.filled === '1') return;
            if (!this.models) {
                try { this.models = await Api.models(); } catch (_) { }
            }
            sel.innerHTML = '';
            const auto = document.createElement('option');
            auto.value = '';
            auto.textContent = t('Auto-routed (standard)');
            sel.appendChild(auto);
            for (const m of (this.models && this.models.models) || []) {
                const opt = document.createElement('option');
                opt.value = m.key;
                opt.textContent = `${m.label} · ${m.credits || 1}`;
                sel.appendChild(opt);
            }
            sel.dataset.filled = '1';
        },

        renderBotIcons() {
            const box = $('botIcons');
            box.innerHTML = '';
            for (const name of Icons.PERSONA_ICONS) {
                const b = el('button', 'icon-choice' + (name === this.botIcon ? ' is-active' : ''));
                b.type = 'button';
                b.title = name;
                b.appendChild(Icons.node(name, { size: 17 }));
                b.addEventListener('click', () => {
                    this.botIcon = name;
                    this.renderBotIcons();
                });
                box.appendChild(b);
            }
        },

        resetBotForm() {
            this.botEditing = null;
            this.botIcon = 'robot';
            $('botName').value = '';
            $('botTagline').value = '';
            $('botInstructions').value = '';
            $('botStarters').value = '';
            $('botModel').value = '';
            $('botFormTitle').textContent = t('New bot');
            this.modalStatus('botStatus', '');
            this.renderBotIcons();
        },

        editBot(id) {
            const bot = Bots.get(id);
            if (!bot) return;
            this.botEditing = id;
            this.botIcon = bot.icon || 'robot';
            $('botName').value = bot.name || '';
            $('botTagline').value = bot.tagline || '';
            $('botInstructions').value = bot.instructions || '';
            $('botStarters').value = (bot.starters || []).join('\n');
            $('botModel').value = bot.modelKey || '';
            $('botFormTitle').textContent = t('Edit bot');
            this.modalStatus('botStatus', '');
            this.renderBotIcons();
        },

        renderBots() {
            const list = $('botList');
            list.innerHTML = '';
            const bots = Bots.all();
            const active = this.conv && this.conv.botId;
            if (!bots.length) {
                list.appendChild(el('p', 'hint',
                    t('No bots yet. Make one, or add a link somebody sent you.')));
            }
            for (const bot of bots) {
                const row = el('div', 'repo-row' + (bot.id === active ? ' is-on' : ''));
                const mark = el('span', 'persona-emoji');
                mark.appendChild(Icons.node(bot.icon || 'robot', { size: 15 }));
                row.appendChild(mark);
                const main = el('div', 'repo-main');
                main.appendChild(el('span', 'repo-name', bot.name || t('Untitled')));
                main.appendChild(el('span', 'repo-sub',
                    bot.tagline || bot.modelLabel || t('Auto-routed')));
                main.style.cursor = 'pointer';
                main.addEventListener('click', () => this.useBot(
                    bot.id === active ? null : bot.id));
                row.appendChild(main);
                const actions = el('div', 'row-actions');
                const use = el('button', 'row-btn',
                    bot.id === active ? t('In this chat') : t('Use here'));
                use.type = 'button';
                use.addEventListener('click', () => this.useBot(
                    bot.id === active ? null : bot.id));
                actions.appendChild(use);
                const share = el('button', 'row-btn', t('Share'));
                share.type = 'button';
                share.addEventListener('click', () => this.shareBot(bot.id));
                actions.appendChild(share);
                const edit = el('button', 'row-btn', t('Edit'));
                edit.type = 'button';
                edit.addEventListener('click', () => this.editBot(bot.id));
                actions.appendChild(edit);
                const del = el('button', 'row-btn danger', t('Delete'));
                del.type = 'button';
                del.addEventListener('click', () => {
                    Bots.remove(bot.id);
                    if (this.conv && this.conv.botId === bot.id) this.useBot(null);
                    if (this.botEditing === bot.id) this.resetBotForm();
                    this.renderBots();
                });
                actions.appendChild(del);
                row.appendChild(actions);
                list.appendChild(row);
            }
            const add = el('button', 'btn', t('Add a shared bot'));
            add.type = 'button';
            add.addEventListener('click', () => this.openAddBot());
            list.appendChild(add);
        },

        saveBot() {
            const name = ($('botName').value || '').trim();
            if (!name) {
                this.modalStatus('botStatus', t('Give the bot a name.'), 'warn');
                return;
            }
            const key = $('botModel').value || null;
            const found = key && this.models
                ? (this.models.models || []).find(m => m.key === key)
                : null;
            const saved = Bots.save({
                id: this.botEditing || undefined,
                name,
                tagline: ($('botTagline').value || '').trim(),
                icon: this.botIcon,
                instructions: ($('botInstructions').value || '').trim(),
                modelKey: key,
                modelLabel: found ? found.label : null,
                starters: ($('botStarters').value || '').split('\n')
                    .map(x => x.trim()).filter(Boolean)
            });
            this.resetBotForm();
            this.renderBots();
            this.refreshToolbar();
            this.modalStatus('botStatus', t('Saved {name}.', { name: saved.name }), 'ok');
        },

        useBot(id) {
            if (!this.conv) return;
            const bot = id ? Bots.get(id) : null;
            const patch = { botId: id };
            if (bot && bot.modelKey) {
                const full = this.models
                    ? (this.models.models || []).find(m => m.key === bot.modelKey)
                    : null;
                patch.proModel = full || { key: bot.modelKey, label: bot.modelLabel || bot.modelKey };
            } else if (!id) {
                patch.proModel = null;
            }
            this.conv = Store.updateConversation(this.conv.id, patch);
            this.renderBots();
            this.refreshToolbar();
            this.renderMessages();
            this.toast(bot
                ? t('{name} is answering this chat.', { name: bot.name })
                : t('Back to plain Nymbot.'));
        },

        shareBot(id) {
            const bot = Bots.get(id);
            if (!bot) return;
            this.sharingBot = id;
            const link = Bots.link(bot);
            $('shareBotTitle').textContent = bot.name || t('Share this bot');
            $('shareBotLink').value = link;
            $('shareBotAddr').hidden = !bot.naddr;
            $('shareBotNaddr').value = bot.naddr || '';
            this.modalStatus('shareBotStatus', '');
            this.openModal('modalShareBot');
            try {
                QR.draw($('shareBotQr'), link, { width: 240 });
            } catch (_) {
                this.modalStatus('shareBotStatus',
                    t('That bot is too big for a QR code — send the link instead.'));
            }
        },

        /// Publishing is a claim of authorship, so it is always signed by the
        /// account and never by a throwaway key, whatever mode the chat is in.
        async publishBot() {
            const bot = Bots.get(this.sharingBot);
            if (!bot) return;
            this.modalStatus('shareBotStatus', t('Publishing…'));
            try {
                const signed = await Identity.signEvent(Bots.event(bot, Identity.pubkey));
                const accepted = await Relays.publish(signed, 5000);
                if (!accepted) {
                    this.modalStatus('shareBotStatus',
                        t('No relay accepted it. Check your connection and try again.'), 'warn');
                    return;
                }
                const naddr = Bots.naddr(bot, Identity.pubkey);
                Bots.save(Object.assign({}, bot, { naddr, author: Identity.pubkey }));
                $('shareBotAddr').hidden = !naddr;
                $('shareBotNaddr').value = naddr;
                this.renderBots();
                this.modalStatus('shareBotStatus',
                    t('Published to {n} relays. Republishing replaces it rather than making a second copy.',
                        { n: accepted }), 'ok');
            } catch (e) {
                this.modalStatus('shareBotStatus', (e && e.message) || t('The request failed.'), 'warn');
            }
        },

        openAddBot() {
            this.pendingBot = null;
            $('addBotInput').value = '';
            $('addBotPreview').hidden = true;
            $('addBotAccept').hidden = true;
            this.modalStatus('addBotStatus', '');
            this.openModal('modalAddBot');
        },

        async fetchBot() {
            const text = ($('addBotInput').value || '').trim();
            if (!text) {
                this.modalStatus('addBotStatus', t('Paste a link or an address first.'), 'warn');
                return;
            }
            let bot = Bots.fromLink(text);
            if (!bot) {
                const pointer = Bots.pointerFor(text.replace(/^nostr:/i, ''));
                if (!pointer) {
                    this.modalStatus('addBotStatus', t('That is not a bot link or address.'), 'warn');
                    return;
                }
                this.modalStatus('addBotStatus', t('Looking it up on the relays…'));
                let events = [];
                try {
                    events = await Relays.fetch(Bots.filterFor(pointer), 5000);
                } catch (_) { }
                const newest = events
                    .filter(e => e && e.pubkey === pointer.pubkey)
                    .sort((a, b) => (b.created_at || 0) - (a.created_at || 0))[0];
                bot = newest ? Bots.fromEvent(newest) : null;
                if (!bot) {
                    this.modalStatus('addBotStatus',
                        t('No relay had that bot. It may have been unpublished.'), 'warn');
                    return;
                }
            }
            this.pendingBot = bot;
            this.showBotPreview(bot);
        },

        showBotPreview(bot) {
            const box = $('addBotPreview');
            box.innerHTML = '';
            box.hidden = false;
            const head = el('div', 'bot-preview-head');
            head.appendChild(Icons.node(bot.icon || 'robot', { size: 16 }));
            head.appendChild(el('strong', null, bot.name));
            box.appendChild(head);
            if (bot.tagline) box.appendChild(el('p', 'bot-preview-line', bot.tagline));
            box.appendChild(el('p', 'bot-preview-line',
                bot.modelLabel ? t('Model: {name}', { name: bot.modelLabel }) : t('Auto-routed')));
            if (bot.instructions) {
                box.appendChild(el('pre', 'bot-preview-body', bot.instructions.slice(0, 800)));
            }
            box.appendChild(el('p', 'hint',
                t('Instructions from a stranger are still instructions. Read them before you use it.')));
            $('addBotAccept').hidden = false;
            this.modalStatus('addBotStatus', '');
        },

        acceptBot() {
            if (!this.pendingBot) return;
            const saved = Bots.save(this.pendingBot);
            this.pendingBot = null;
            this.closeModals();
            this.renderBots();
            this.toast(t('Added {name}.', { name: saved.name }));
            this.openBots();
        },

        /// A link opened in the browser lands here. The fragment is dropped
        /// straight away so a reload does not re-offer the same bot.
        offerBotFromUrl() {
            const hash = location.hash || '';
            if (!/(^|[#&])bot=/.test(hash)) return;
            const bot = Bots.fromLink(hash);
            history.replaceState(null, '', location.pathname + location.search);
            if (!bot) return;
            this.pendingBot = bot;
            this.openModal('modalAddBot');
            $('addBotInput').value = '';
            this.showBotPreview(bot);
        },

        // --- workspaces --------------------------------------------------------

        openWorkspaces() {
            if (!this.workspaceDraft) this.resetWorkspaceForm();
            this.renderWorkspaces();
            this.openModal('modalWorkspaces');
        },

        resetWorkspaceForm() {
            this.workspaceEditing = null;
            this.workspaceDraft = { instructions: '', files: [], repoIds: [] };
            $('workspaceName').value = '';
            $('workspaceInstructions').value = '';
            $('workspaceFormTitle').textContent = t('New workspace');
            this.modalStatus('workspaceStatus', '');
            this.renderWorkspaceForm();
        },

        editWorkspace(id) {
            const space = Store.workspace(id);
            if (!space) return;
            this.workspaceEditing = id;
            this.workspaceDraft = {
                instructions: space.instructions || '',
                files: (space.files || []).map(f => Object.assign({}, f)),
                repoIds: (space.repoIds || []).slice()
            };
            $('workspaceName').value = space.name || '';
            $('workspaceInstructions').value = space.instructions || '';
            $('workspaceFormTitle').textContent = t('Edit workspace');
            this.modalStatus('workspaceStatus', '');
            this.renderWorkspaceForm();
        },

        renderWorkspaces() {
            const list = $('workspaceList');
            list.innerHTML = '';
            const spaces = Store.workspaces();
            const active = this.conv && this.conv.workspaceId;
            if (!spaces.length) {
                list.appendChild(el('p', 'hint',
                    t('No workspaces yet. One holds the instructions, files and repositories a run of chats shares.')));
            }
            for (const space of spaces) {
                const row = el('div', 'repo-row' + (space.id === active ? ' is-on' : ''));
                const main = el('div', 'repo-main');
                main.appendChild(el('span', 'repo-name', space.name || t('Untitled')));
                main.appendChild(el('span', 'repo-sub', [
                    t('{n} files', { n: (space.files || []).length }),
                    t('{n} repos', { n: (space.repoIds || []).length })
                ].join(' · ')));
                main.style.cursor = 'pointer';
                main.addEventListener('click', () => this.useWorkspace(
                    space.id === active ? null : space.id));
                row.appendChild(main);
                const actions = el('div', 'row-actions');
                const use = el('button', 'row-btn',
                    space.id === active ? t('In this chat') : t('Use here'));
                use.type = 'button';
                use.addEventListener('click', () => this.useWorkspace(
                    space.id === active ? null : space.id));
                actions.appendChild(use);
                const edit = el('button', 'row-btn', t('Edit'));
                edit.type = 'button';
                edit.addEventListener('click', () => this.editWorkspace(space.id));
                actions.appendChild(edit);
                const del = el('button', 'row-btn danger', t('Delete'));
                del.type = 'button';
                del.addEventListener('click', async () => {
                    const go = await this.ask({
                        title: t('Delete this workspace?'),
                        body: t('Chats that used it keep everything already said, but stop starting with its context.'),
                        confirm: t('Delete')
                    });
                    if (!go) return;
                    Store.deleteWorkspace(space.id);
                    if (this.conv && this.conv.workspaceId === space.id) {
                        this.conv = Store.conversation(this.conv.id);
                    }
                    if (this.workspaceEditing === space.id) this.resetWorkspaceForm();
                    this.renderWorkspaces();
                    this.refreshToolbar();
                });
                actions.appendChild(del);
                row.appendChild(actions);
                list.appendChild(row);
            }
        },

        renderWorkspaceForm() {
            const draft = this.workspaceDraft;
            const picks = $('workspaceRepos');
            picks.innerHTML = '';
            const repos = Store.repos();
            if (!repos.length) {
                picks.appendChild(el('p', 'hint',
                    t('Connect a repository first and it can be attached here.')));
            }
            for (const repo of repos) {
                const on = draft.repoIds.includes(repo.id);
                const pick = el('button', 'repo-pick' + (on ? ' is-on' : ''),
                    repo.label || repo.repo);
                pick.type = 'button';
                pick.addEventListener('click', () => {
                    draft.repoIds = on
                        ? draft.repoIds.filter(x => x !== repo.id)
                        : draft.repoIds.concat([repo.id]);
                    this.renderWorkspaceForm();
                });
                picks.appendChild(pick);
            }

            const files = $('workspaceFiles');
            files.innerHTML = '';
            if (!draft.files.length) {
                files.appendChild(el('p', 'hint',
                    t('No files yet. Text and code go in whole; nothing is uploaded anywhere.')));
            }
            draft.files.forEach((file, i) => {
                const row = el('div', 'file-row');
                row.appendChild(Icons.node('copy', { size: 14 }));
                const main = el('div', 'file-main');
                main.appendChild(el('span', 'file-name', file.name));
                main.appendChild(el('span', 'file-sub',
                    Attach.humanSize(file.body.length)));
                row.appendChild(main);
                const del = el('button', 'row-btn danger', t('Remove'));
                del.type = 'button';
                del.addEventListener('click', () => {
                    draft.files.splice(i, 1);
                    this.renderWorkspaceForm();
                });
                row.appendChild(del);
                files.appendChild(row);
            });
        },

        async addWorkspaceFiles(fileList) {
            const draft = this.workspaceDraft;
            let added = 0;
            for (const file of Array.from(fileList || [])) {
                try {
                    const built = await Attach.fromFile(file);
                    if (!built || built.kind !== 'text') {
                        this.modalStatus('workspaceStatus',
                            t('Only text and code can be project knowledge.'), 'warn');
                        continue;
                    }
                    draft.files.push({
                        id: Store.uid(),
                        name: built.name,
                        mime: built.mime,
                        body: built.text
                    });
                    added++;
                } catch (e) {
                    this.modalStatus('workspaceStatus', (e && e.message) || t('That file could not be read.'), 'warn');
                }
            }
            if (added) this.modalStatus('workspaceStatus', '');
            this.renderWorkspaceForm();
        },

        saveWorkspace() {
            const name = ($('workspaceName').value || '').trim();
            if (!name) {
                this.modalStatus('workspaceStatus', t('Give the workspace a name.'), 'warn');
                return;
            }
            const draft = this.workspaceDraft;
            const saved = Store.saveWorkspace({
                id: this.workspaceEditing || undefined,
                name,
                instructions: ($('workspaceInstructions').value || '').trim(),
                files: draft.files,
                repoIds: draft.repoIds
            });
            this.resetWorkspaceForm();
            this.renderWorkspaces();
            this.refreshToolbar();
            this.modalStatus('workspaceStatus', t('Saved {name}.', { name: saved.name }), 'ok');
        },

        useWorkspace(id) {
            if (!this.conv) return;
            this.conv = Store.updateConversation(this.conv.id, { workspaceId: id });
            this.renderWorkspaces();
            this.refreshToolbar();
            this.toast(id
                ? t('This chat starts with that workspace.')
                : t('This chat is on its own again.'));
        },

        // --- comparing two models ---------------------------------------------

        async openCompare(prefill) {
            this.openModal('modalCompare');
            $('compareGrid').hidden = true;
            $('compareGrid').innerHTML = '';
            this.compare = null;
            this.modalStatus('compareStatus', '');
            const text = prefill != null ? prefill : ($('input').value || '').trim();
            if (text) $('comparePrompt').value = text;

            const a = $('compareA'), b = $('compareB');
            if (!this.models) {
                a.innerHTML = '';
                b.innerHTML = '';
                this.modalStatus('compareStatus', t('Loading the catalog…'));
                this.models = await Api.models();
                this.modalStatus('compareStatus', '');
            }
            if (!this.models || !this.models.models) {
                this.modalStatus('compareStatus',
                    t('The model catalog is unavailable right now.'), 'warn');
                return;
            }
            const rows = this.models.models.slice().sort((x, y) => {
                const fx = this.favourites.includes(x.key) ? 0 : 1;
                const fy = this.favourites.includes(y.key) ? 0 : 1;
                return fx - fy || x.label.localeCompare(y.label);
            });
            const fill = (sel, chosen) => {
                sel.innerHTML = '';
                for (const m of rows) {
                    const opt = document.createElement('option');
                    opt.value = m.key;
                    opt.textContent = `${m.label} · ${m.credits || 1}`;
                    if (m.key === chosen) opt.selected = true;
                    sel.appendChild(opt);
                }
            };
            const current = (this.conv && this.conv.proModel) || this.settings.proModel;
            const first = current ? current.key : (rows[0] && rows[0].key);
            const second = (rows.find(m => m.key !== first) || {}).key;
            fill(a, first);
            fill(b, second);
        },

        compareSeed(limit) {
            return Store.messages(this.conv.id)
                .filter(x => x.role === 'self' || x.role === 'bot')
                .slice(-(limit || 8))
                .map(x => `${x.role === 'self' ? 'User' : 'Assistant'}: ${MD.plain(x.content).slice(0, 700)}`)
                .join('\n\n');
        },

        async runCompare() {
            if (this.sending) return;
            const text = ($('comparePrompt').value || '').trim();
            if (!text) {
                this.modalStatus('compareStatus', t('Type a prompt for both of them first.'), 'warn');
                return;
            }
            const byKey = new Map((this.models.models || []).map(m => [m.key, m]));
            const a = byKey.get($('compareA').value);
            const b = byKey.get($('compareB').value);
            if (!a || !b || a.key === b.key) {
                this.modalStatus('compareStatus', t('Pick two different models.'), 'warn');
                return;
            }

            const go = await this.ask({
                title: t('Ask both?'),
                body: t('{a} and {b} each answer once, so this costs two replies — about {n} credits.',
                    { a: a.label, b: b.label, n: (a.credits || 1) + (b.credits || 1) }),
                confirm: t('Ask both')
            });
            if (!go) return;

            this.setSending(true);
            this.modalStatus('compareStatus', t('Waiting on both…'));
            $('compareGrid').hidden = false;
            $('compareGrid').innerHTML = '';
            let out;
            try {
                out = await Chat.compare(this.conv, text, this.settings, [a, b], {
                    seed: this.compareSeed()
                });
            } catch (e) {
                this.setSending(false);
                this.modalStatus('compareStatus', (e && e.message) || t('The request failed.'), 'warn');
                return;
            }
            this.setSending(false);
            this.compare = { prompt: text, runs: out };
            const spent = out.reduce((n, r) => n + ((r.result && r.result.cost) || 0), 0);
            Store.recordUsage(spent);
            this.bumpStats(spent);
            const balance = out.map(r => r.result).filter(r => r && r.balance != null).pop();
            if (balance) {
                this.balance[balance.pro ? 'pro' : 'standard'] = balance.balance;
                this.renderBalance();
            }
            this.modalStatus('compareStatus', out.every(r => r.ok)
                ? t('Both answered. Keep the one you want to carry on from.')
                : t('One of them did not answer.'), out.every(r => r.ok) ? 'ok' : 'warn');
            this.renderCompare();
        },

        renderCompare() {
            const grid = $('compareGrid');
            grid.innerHTML = '';
            if (!this.compare) { grid.hidden = true; return; }
            grid.hidden = false;
            this.compare.runs.forEach((run, i) => {
                const col = el('div', 'compare-col');
                const head = el('div', 'compare-head');
                head.appendChild(Icons.node('model', { size: 13 }));
                head.appendChild(el('span', 'compare-name', run.model.label));
                if (run.ok) {
                    head.appendChild(el('span', 'compare-cost',
                        t('{n} credits', { n: (run.result.cost || 0) })));
                }
                col.appendChild(head);
                const body = el('div', 'compare-body' + (run.ok ? '' : ' is-error'));
                if (run.ok) {
                    body.innerHTML = MD.render(run.result.reply, {
                        wrap: this.settings.codeWrap,
                        lineNumbers: this.settings.lineNumbers
                    });
                } else {
                    body.textContent = run.error;
                }
                col.appendChild(body);
                const foot = el('div', 'compare-foot');
                if (run.ok) {
                    const keep = el('button', 'btn primary', t('Keep this one'));
                    keep.type = 'button';
                    keep.addEventListener('click', () => this.keepCompare(i));
                    foot.appendChild(keep);
                    const copy = el('button', 'btn', t('Copy'));
                    copy.type = 'button';
                    copy.addEventListener('click', () => this.writeClipboard(run.result.reply));
                    foot.appendChild(copy);
                }
                col.appendChild(foot);
                grid.appendChild(col);
            });
        },

        /// Folds the winning answer into the chat. Neither reply was on this
        /// chat's thread, so the worker has never seen this turn: the chat
        /// takes a fresh thread and carries the transcript forward as its seed,
        /// exactly as a branch does.
        keepCompare(index) {
            const run = this.compare && this.compare.runs[index];
            if (!run || !run.ok) return;

            const mine = {
                id: Store.uid(), role: 'self', content: this.compare.prompt, ts: Date.now()
            };
            const reply = {
                id: Store.uid(),
                role: 'bot',
                content: run.result.reply,
                thinking: run.result.thinking || null,
                cost: run.result.cost || 0,
                model: run.model.label,
                sources: run.result.sources || null,
                calls: run.result.modelCalls || 1,
                task: run.result.taskType || null,
                ts: Date.now()
            };
            Store.addMessage(this.conv.id, mine);
            Store.addMessage(this.conv.id, reply);
            Artifacts.harvest(this.conv.id, reply);

            this.conv = Store.updateConversation(this.conv.id, {
                rootId: window.NymbotHex.hex(crypto.getRandomValues(new Uint8Array(32))),
                seed: this.compareSeed()
            });
            Store.dropThread(this.conv.id);
            if (!this.conv.title) {
                this.conv = Store.updateConversation(this.conv.id,
                    { title: Chat.titleFor(this.compare.prompt) });
                $('chatTitle').textContent = this.conv.title;
            }

            this.compare = null;
            this.closeModals();
            $('input').value = '';
            Store.setDraft(this.conv.id, '');
            this.autoGrow();
            this.renderMessages();
            this.renderArtifactStrip();
            this.renderList();
            this.toast(t('Kept {model}.', { model: run.model.label }));
        },

        codeAction(act, id, node) {
            const block = document.querySelector(`.code-block[data-code-id="${id}"]`)
                || (node && node.closest('.code-block'));
            if (!block) return;
            const source = block.querySelector('.code-source');
            const body = source ? source.value : '';
            if (act === 'code-copy') {
                this.writeClipboard(body);
            } else if (act === 'code-wrap') {
                block.classList.toggle('is-wrapped');
            } else if (act === 'code-download') {
                const lang = (node && node.dataset.lang) || 'txt';
                const ext = { js: 'js', ts: 'ts', dart: 'dart', py: 'py', json: 'json', html: 'html', css: 'css', sh: 'sh', sql: 'sql', md: 'md' }[lang] || 'txt';
                Exporter.download('snippet.' + ext, 'text/plain', body);
            } else if (act === 'code-preview') {
                const frame = $('previewFrame');
                frame.srcdoc = body;
                this.openModal('modalPreview');
            }
        },

        async importBackup(file) {
            try {
                const payload = await Exporter.readFile(file);
                const mode = await this.ask({
                    title: t('Import a backup'),
                    body: t('Add these conversations to the ones already here, or replace everything?'),
                    confirm: t('Add'),
                    cancel: t('Replace everything')
                });
                const count = Store.importAll(payload, mode ? 'merge' : 'replace');
                this.settings = Store.settings();
                this.applyAppearance();
                this.renderList();
                const list = Store.conversations();
                this.open(list.length ? list[0] : this.newConversation());
                this.modalStatus('appearanceStatus',
                    t('Imported {n} conversations.', { n: count }), 'ok');
            } catch (e) {
                this.modalStatus('appearanceStatus', t('That file could not be read.'), 'warn');
            }
        },

        // --- anonymous mode ------------------------------------------------------

        openAnon() {
            const s = this.settings;
            $('anonToggle').checked = Anon.enabled();
            $('anonAutoTop').checked = !!s.anonAutoTop;
            $('anonAutoFloor').value = String(s.anonAutoTopFloor ?? 10);
            $('anonAutoAmount').value = String(s.anonAutoTopAmount ?? 25);
            $('anonAutoTier').value = s.anonAutoTopTier || 'both';
            $('anonAutoFields').hidden = !s.anonAutoTop;
            $('anonAutoTier').hidden = !s.anonAutoTop;
            $('anonStatus').textContent = '';
            $('anonBalances').textContent = t('Checking balances…');
            this.openModal('modalAnon');
            Anon.balances().then((b) => {
                const box = $('anonBalances');
                box.innerHTML = '';
                box.appendChild(el('div', null, t('Your nym: {standard} standard · {pro} Pro',
                    { standard: b.identity ?? '–', pro: b.identityPro ?? '–' })));
                box.appendChild(el('div', null, t('Throwaway key: {standard} standard · {pro} Pro',
                    { standard: b.anon ?? '–', pro: b.anonPro ?? '–' })));
            }).catch(() => { $('anonBalances').textContent = t('Could not read the balances.'); });
        },

        /// Tops the throwaway key up when it is running low, so anonymous mode
        /// does not mean funding a key by hand before every chat.
        async runAutoTopUp(options) {
            const opts = options || {};
            if (!this.settings.anonAutoTop || !Anon.enabled()) return null;
            const moved = await Anon.autoTopUp(opts).catch(() => null);
            if (!moved) return null;
            const parts = [];
            if (moved.standard) parts.push(t('{n} standard', { n: moved.standard }));
            if (moved.pro) parts.push(t('{n} Pro', { n: moved.pro }));
            const text = t('Moved {what} onto the throwaway key.', { what: parts.join(', ') });
            if (opts.announce) this.toast(text);
            else if (this.conv) this.note(text);
            this.refreshBalance();
            if (!$('modalAnon').hidden) this.openAnon();
            return moved;
        },

        async moveCredits() {
            const amount = parseInt($('anonAmount').value, 10);
            const tier = $('anonTier').value === 'pro' ? 'pro' : 'standard';
            if (!Anon.enabled()) {
                this.modalStatus('anonStatus', t('Turn anonymous mode on first.'), 'warn');
                return;
            }
            this.modalStatus('anonStatus', t('Moving credits…'));
            try {
                const credited = await Anon.moveCredits(amount, tier);
                this.modalStatus('anonStatus', tier === 'pro'
                    ? t('Moved {n} Pro credits onto the throwaway key.', { n: credited })
                    : t('Moved {n} credits onto the throwaway key.', { n: credited }), 'ok');
                $('anonAmount').value = '';
                this.openAnon();
            } catch (e) {
                this.modalStatus('anonStatus', e.message || t('Could not move credits.'), 'warn');
            }
        },

        // --- credits --------------------------------------------------------------

        openCredits() {
            const live = this.invoice;
            const model = (this.conv && this.conv.proModel) || this.settings.proModel;
            this.creditTier = live ? live.tier : (model ? 'pro' : 'standard');
            for (const b of document.querySelectorAll('#creditTier .tier-btn')) {
                b.classList.toggle('is-active', b.dataset.tier === this.creditTier);
            }
            const grid = $('amountGrid');
            grid.innerHTML = '';
            for (const n of [10, 25, 50, 100, 250, 500]) {
                const b = el('button', null, String(n));
                b.type = 'button';
                b.addEventListener('click', () => { $('creditAmount').value = n; this.creditSats(); });
                grid.appendChild(b);
            }
            if (live) {
                $('creditAmount').value = live.credits;
                this.showInvoice(live);
                this.modalStatus('creditStatus', live.paid
                    ? t('Your payment arrived. Tap Add my credits to finish.')
                    : t('Pay {sats} sats. This updates the moment it settles.', { sats: live.sats }));
            } else {
                this.resetInvoice();
                $('creditStatus').textContent = '';
            }
            this.creditSats();
            this.openModal('modalCredits');
        },

        showInvoice(invoice) {
            $('invoiceText').value = invoice.pr;
            $('invoiceOpen').href = 'lightning:' + invoice.pr;
            try { QR.draw($('invoiceQr'), invoice.pr.toUpperCase(), { width: 240 }); } catch (_) { }
            $('invoiceBox').hidden = false;
            $('creditBuy').textContent = invoice.paid ? t('Add my credits') : t('New invoice');
        },

        resetInvoice() {
            this.invoice = null;
            $('invoiceBox').hidden = true;
            $('invoiceText').value = '';
            $('invoiceOpen').href = '#';
            const canvas = $('invoiceQr');
            const ctx = canvas.getContext ? canvas.getContext('2d') : null;
            if (ctx) ctx.clearRect(0, 0, canvas.width, canvas.height);
            $('creditBuy').textContent = t('Create invoice');
        },

        creditSats() {
            const credits = Math.max(0, parseInt($('creditAmount').value, 10) || 0);
            const sats = credits * C.satsPerCredit[this.creditTier];
            const live = this.invoice;
            if (live && !live.paid && (live.credits !== credits || live.tier !== this.creditTier)) {
                this.resetInvoice();
                this.modalStatus('creditStatus',
                    t('That invoice was for a different amount. Create a new one.'), 'warn');
            }
            if (!credits) { $('creditSats').textContent = ''; return; }
            $('creditSats').textContent = this.creditTier === 'pro'
                ? t('{credits} Pro credits = {sats} sats', { credits, sats })
                : t('{credits} credits = {sats} sats', { credits, sats });
        },

        async buyCredits() {
            if (this.creditBusy) return;
            if (this.invoice && this.invoice.paid) { await this.claimInvoice(this.invoice); return; }

            const credits = Math.max(0, parseInt($('creditAmount').value, 10) || 0);
            if (!credits) { this.modalStatus('creditStatus', t('Enter how many credits to buy.'), 'warn'); return; }
            const sats = credits * C.satsPerCredit[this.creditTier];
            const tier = this.creditTier;

            this.resetInvoice();
            this.creditBusy = true;
            $('creditBuy').disabled = true;
            this.modalStatus('creditStatus', t('Creating an invoice…'));

            const opts = this.conv && this.conv.anon && Anon.ready() ? { signer: Anon.signer() } : {};
            let data;
            try {
                ({ data } = await Api.createInvoice(sats, tier, null, opts));
            } finally {
                this.creditBusy = false;
                $('creditBuy').disabled = false;
            }
            if (!data || data.error || !data.pr) {
                this.modalStatus('creditStatus', (data && data.error) || t('Could not create an invoice.'), 'warn');
                return;
            }
            const invoice = { id: data.invoiceId, pr: data.pr, tier, credits, sats, opts, paid: false };
            this.invoice = invoice;
            this.showInvoice(invoice);
            this.creditSats();
            if (this.invoice !== invoice) return;
            this.modalStatus('creditStatus', t('Pay {sats} sats. This updates the moment it settles.', { sats }));
            this.pollInvoice(invoice);
        },

        async claimInvoice(invoice) {
            if (this.creditBusy) return false;
            this.creditBusy = true;
            $('creditBuy').disabled = true;
            this.modalStatus('creditStatus', t('Adding your credits…'));
            let data;
            try {
                ({ data } = await Api.claimCredits(invoice.id, invoice.opts));
            } finally {
                this.creditBusy = false;
                $('creditBuy').disabled = false;
            }
            if (this.invoice !== invoice) return true;

            if (data && !data.error) {
                this.balance[invoice.tier] = data.balance;
                this.renderBalance();
                this.resetInvoice();
                this.modalStatus('creditStatus',
                    t('Credited. Balance: {balance}. Create a new invoice to buy more.',
                        { balance: data.balance }), 'ok');
                return true;
            }
            if (data && /already claimed/i.test(data.error || '')) {
                this.resetInvoice();
                this.modalStatus('creditStatus',
                    t('That payment was already credited. Create a new invoice to buy more.'), 'ok');
                return true;
            }
            this.markPaid(invoice);
            this.modalStatus('creditStatus',
                (data && data.error) || t('Your payment could not be credited yet.'), 'warn');
            return false;
        },

        markPaid(invoice) {
            invoice.paid = true;
            if (this.invoice === invoice) $('creditBuy').textContent = t('Add my credits');
        },

        async pollInvoice(invoice) {
            for (let i = 0; i < 90; i++) {
                await new Promise(r => setTimeout(r, 2000));
                if (this.invoice !== invoice) return;
                if (this.creditBusy) continue;
                const { data } = await Api.checkInvoice(invoice.id, invoice.opts);
                if (this.invoice !== invoice) return;
                if (!data || !data.paid) continue;
                this.markPaid(invoice);
                if (await this.claimInvoice(invoice)) return;
                if (this.invoice !== invoice) return;
            }
            if (this.invoice !== invoice) return;
            if (invoice.paid) {
                this.modalStatus('creditStatus',
                    t('Your payment arrived but the credits are not added yet. Tap Add my credits to try again.'), 'warn');
                return;
            }
            this.resetInvoice();
            this.modalStatus('creditStatus',
                t('This invoice expired before it was paid. Create a new one.'), 'warn');
        },

        // --- identity ---------------------------------------------------------------

        openSettings() {
            $('settingsWho').textContent = Identity.method === 'nip07'
                ? t('Signed in with a browser extension, which holds your key.')
                : t('Your key lives on this device and nowhere else.');
            $('setNpub').value = Identity.pubkey
                ? NT().nip19.npubEncode(Identity.pubkey)
                : '';
            $('setHex').value = Identity.pubkey || '';
            const nsecRow = $('setNsec').closest('.reveal-row');
            if (Identity.isLocal) {
                nsecRow.hidden = false;
                $('setNsec').value = NT().nip19.nsecEncode(Identity._sk);
                $('setNsec').type = 'password';
            } else {
                nsecRow.hidden = true;
            }
            $('setRoot').value = Identity.rootCode() || '';
            $('rootHint').textContent = Identity.rootLocked
                ? t('This account already advertises another device\'s key. Paste that device\'s code below to link this one; until then replies come back without the post-quantum layer.')
                : t('Paste this into another device — or into Nymchat — so both hold the same post-quantum key.');
            this.renderLanguages();
            const usage = Store.usage();
            $('usageLine').textContent = t('{replies} replies, {credits} credits spent on this device.',
                { replies: usage.replies, credits: usage.credits });
            $('settingsStatus').textContent = '';
            this.openModal('modalSettings');
        },

        /// The languages with a published pack, plus English. A build that
        /// shipped none leaves one option, which is the honest thing to show.
        renderLanguages() {
            const select = $('langSelect');
            const I18n = window.NymbotI18n;
            const languages = [{ code: 'en', name: 'English' }, ...(I18n.available || [])];
            select.innerHTML = '';
            for (const lang of languages) {
                const option = document.createElement('option');
                option.value = lang.code;
                // The endonym, so a reader who cannot read the current language
                // can still find their own in the list.
                option.textContent = lang.native || lang.name || lang.code;
                option.selected = lang.code === I18n.lang;
                select.appendChild(option);
            }
            select.disabled = languages.length < 2;
        },

        async linkRoot() {
            const code = $('linkRoot').value.trim();
            if (!code) return;
            try {
                Identity.adoptRootCode(code);
                await PQ.announce();
                this.openSettings();
                this.modalStatus('settingsStatus', t('Linked. This device now derives the same post-quantum key.'), 'ok');
            } catch (e) {
                this.modalStatus('settingsStatus', t('That does not look like a recovery code.'), 'warn');
            }
        },

        async transfer() {
            const target = await this.ask({
                title: t('Move your whole balance'),
                body: t('Every credit on this key moves to the key you name. There is no undo.'),
                prompt: true,
                label: t('Move your whole balance to which public key? (hex, 64 characters)'),
                confirm: t('Move')
            });
            if (!target) return;
            const { data } = await Api.transferCredits(target.trim().toLowerCase());
            if (!data || data.error) {
                this.modalStatus('settingsStatus', (data && data.error) || t('The transfer failed.'), 'warn');
                return;
            }
            this.modalStatus('settingsStatus', t('Moved.'), 'ok');
            this.refreshBalance();
        },

        async wipe() {
            const ok = await this.ask({
                title: t('Wipe this device'),
                body: t('Wipe everything on this device — your key, every conversation, and any credits on a throwaway key?\n\nThis cannot be undone.'),
                confirm: t('Wipe'),
                danger: true
            });
            if (!ok) return;
            Store.wipe();
            Identity.forget();
            location.reload();
        },

        // --- chat menu ------------------------------------------------------------

        async clearChat() {
            // A fresh root id is what actually resets the model's context: the
            // worker scopes history to the marker, so a new one is a new thread.
            const rootId = window.NymbotHex.hex(crypto.getRandomValues(new Uint8Array(32)));
            Store.saveMessages(this.conv.id, []);
            Store.setThread(this.conv.id, []);
            this.conv = Store.updateConversation(this.conv.id, { rootId, stats: { messages: 0, credits: 0 } });
            this.renderMessages();
            this.toast(t('Cleared.'));
        },

        async renameChat() {
            const title = await this.ask({
                title: t('Name this chat'),
                prompt: true,
                label: t('Chat name'),
                value: this.conv.title || '',
                confirm: t('Rename')
            });
            if (title == null) return;
            this.conv = Store.updateConversation(this.conv.id, { title: title.trim() || t('New chat') });
            $('chatTitle').textContent = this.conv.title;
            this.renderList();
        },

        pinChat() {
            this.conv = Store.updateConversation(this.conv.id, { pinned: !this.conv.pinned });
            this.refreshToolbar();
            this.renderList();
            this.toast(this.conv.pinned ? t('Pinned.') : t('Unpinned.'));
        },

        archiveChat() {
            const archived = !this.conv.archived;
            this.conv = Store.updateConversation(this.conv.id, { archived });
            this.renderList();
            this.toast(archived ? t('Archived.') : t('Unarchived.'));
            if (archived) {
                const list = Store.conversations().filter(c => !c.archived);
                this.open(list.length ? list[0] : this.newConversation());
            }
        },

        async deleteChat() {
            const ok = await this.ask({
                title: t('Delete this chat'),
                body: t('Delete this chat? Its messages are encrypted to your key and cannot be recovered.'),
                confirm: t('Delete'),
                danger: true
            });
            if (!ok) return;
            Store.deleteConversation(this.conv.id);
            const list = Store.conversations().filter(c => !c.archived);
            this.open(list.length ? list[0] : this.newConversation());
        },

        openPalette() {
            $('paletteInput').value = '';
            this.renderPalette();
            this.closeModals();
            $('scrim').hidden = false;
            $('palette').hidden = false;
            setTimeout(() => $('paletteInput').focus(), 20);
        },

        closePalette() {
            $('palette').hidden = true;
            if (!document.querySelector('.modal:not([hidden])')) $('scrim').hidden = true;
        },

        paletteEntries(term) {
            const needle = term.toLowerCase().trim();
            const rows = [];
            const actions = [
                { label: t('New chat'), hint: MODIFIER + '+N', run: () => this.open(this.newConversation()) },
                { label: t('Search every chat'), hint: MODIFIER + '+Shift+F', run: () => this.openSearch('') },
                { label: t('Pick a model'), hint: MODIFIER + '+Shift+M', run: () => this.openModels() },
                { label: t('Repositories'), hint: MODIFIER + '+Shift+G', run: () => this.openRepos() },
                { label: t('Personas'), hint: '', run: () => this.openPersonas() },
                { label: t('Custom instructions'), hint: '', run: () => this.openSystem() },
                { label: t('Prompt library'), hint: MODIFIER + '+Shift+P', run: () => this.openPrompts() },
                { label: t('Saved messages'), hint: '', run: () => this.openPinned() },
                { label: t('Appearance'), hint: '', run: () => this.openAppearance() },
                { label: t('Keyboard shortcuts'), hint: '', run: () => this.openShortcuts() },
                { label: t('Buy credits'), hint: '', run: () => this.openCredits() },
                { label: t('Anonymous chat'), hint: '', run: () => this.openAnon() },
                { label: t('Identity'), hint: '', run: () => this.openSettings() },
                { label: t('Chat statistics'), hint: '', run: () => this.openStats() },
                { label: t('Export this chat as Markdown'), hint: '', run: () => Exporter.conversation(this.conv, 'md') },
                { label: t('Tags and folder'), hint: '', run: () => this.openTags() },
                { label: t('Clear this chat'), hint: '', run: () => this.clearChat() }
            ];
            for (const a of actions) {
                if (!needle || a.label.toLowerCase().includes(needle)) {
                    rows.push({ group: t('Actions'), name: a.label, hint: a.hint, run: a.run });
                }
            }
            for (const entry of Commands.match(needle, needle ? 8 : 6)) {
                rows.push({
                    group: t('Commands'),
                    name: '?' + entry.name,
                    mono: true,
                    hint: entry.hint(),
                    run: () => {
                        const input = $('input');
                        input.value = '?' + entry.name + (entry.args ? ' ' : '');
                        input.focus();
                        this.autoGrow();
                        if (!entry.args) this.send();
                    }
                });
            }
            if (needle) {
                for (const conv of Store.conversations()) {
                    if (!(conv.title || '').toLowerCase().includes(needle)) continue;
                    rows.push({
                        group: t('Chats'),
                        name: conv.title || t('New chat'),
                        hint: conv.archived ? t('archived') : '',
                        run: () => this.open(Store.conversation(conv.id))
                    });
                    if (rows.length > 40) break;
                }
                for (const hit of Store.searchAll(needle).slice(0, 8)) {
                    if (!hit.message) continue;
                    rows.push({
                        group: t('Messages'),
                        name: hit.excerpt.slice(0, 70),
                        hint: hit.conv.title || t('New chat'),
                        run: () => {
                            this.open(Store.conversation(hit.conv.id));
                            setTimeout(() => this.jumpToMessage(hit.message.id), 60);
                        }
                    });
                }
            }
            return rows.slice(0, 40);
        },

        renderPalette() {
            const rows = this.paletteEntries($('paletteInput').value);
            this.paletteRows = rows;
            this.paletteAt = 0;
            const list = $('paletteList');
            list.innerHTML = '';
            let group = null;
            rows.forEach((row, i) => {
                if (row.group !== group) {
                    group = row.group;
                    list.appendChild(el('div', 'palette-group', group));
                }
                const b = el('button', 'palette-row' + (i === 0 ? ' is-active' : ''));
                b.type = 'button';
                b.dataset.index = String(i);
                const name = el('span', 'palette-name');
                if (row.mono) {
                    const mono = el('span', 'mono', row.name);
                    name.appendChild(mono);
                } else {
                    name.textContent = row.name;
                }
                b.appendChild(name);
                b.appendChild(el('span', 'palette-hint', row.hint || ''));
                b.addEventListener('click', () => this.runPalette(i));
                list.appendChild(b);
            });
            if (!rows.length) list.appendChild(el('div', 'palette-group', t('Nothing matches that.')));
        },

        movePalette(delta) {
            if (!this.paletteRows.length) return;
            this.paletteAt = (this.paletteAt + delta + this.paletteRows.length) % this.paletteRows.length;
            const rows = $('paletteList').querySelectorAll('.palette-row');
            rows.forEach((r) => r.classList.toggle('is-active', Number(r.dataset.index) === this.paletteAt));
            const active = $('paletteList').querySelector('.palette-row.is-active');
            if (active) active.scrollIntoView({ block: 'nearest' });
        },

        runPalette(index) {
            const row = this.paletteRows[index == null ? this.paletteAt : index];
            if (!row) return;
            this.closePalette();
            row.run();
        },

        // --- chrome ----------------------------------------------------------------

        /// The drawer covers the button that opened it on a phone, so it gets the
        /// scrim as its way out — otherwise the only exit is picking a chat.
        toggleSidebar(force) {
            const open = force === undefined
                ? !$('sidebar').classList.contains('is-open')
                : force;
            $('sidebar').classList.toggle('is-open', open);
            if (open) $('scrim').hidden = false;
            else if (!document.querySelector('.modal:not([hidden])') && $('palette').hidden) $('scrim').hidden = true;
        },

        openModal(id) {
            this.closeModals();
            $('scrim').hidden = false;
            $(id).hidden = false;
        },

        closeModals() {
            $('sidebar').classList.remove('is-open');
            $('scrim').hidden = true;
            $('palette').hidden = true;
            for (const m of document.querySelectorAll('.modal')) m.hidden = true;
            $('chatMenu').hidden = true;
            const frame = $('previewFrame');
            if (frame) frame.srcdoc = '';
        },

        ask(options) {
            const o = options || {};
            this.settleDialog(false);
            $('dialogTitle').textContent = o.title || '';
            const body = $('dialogBody');
            body.textContent = o.body || '';
            body.hidden = !o.body;
            const field = $('dialogField');
            const input = $('dialogInput');
            const areaBox = $('dialogArea');
            const area = $('dialogTextarea');
            const isArea = !!o.area;
            const isPrompt = !!o.prompt || isArea;
            field.hidden = !o.prompt || isArea;
            areaBox.hidden = !isArea;
            input.value = (o.prompt && !isArea) ? (o.value || '') : '';
            area.value = isArea ? (o.value || '') : '';
            input.placeholder = o.placeholder || '';
            $('dialogLabel').textContent = o.label || '';
            $('dialogAreaLabel').textContent = o.label || '';
            const confirm = $('dialogConfirm');
            confirm.textContent = o.confirm || t('OK');
            confirm.classList.toggle('btn-danger', !!o.danger);
            confirm.classList.toggle('btn-primary', !o.danger);
            $('dialogCancel').textContent = o.cancel || t('Cancel');
            $('dialogScrim').hidden = false;
            $('dialog').hidden = false;
            this._dialogPrompt = isPrompt;
            this._dialogArea = isArea;
            if (isArea) { area.focus(); area.select(); }
            else if (o.prompt) { input.focus(); input.select(); }
            else { confirm.focus(); }
            return new Promise((resolve) => { this._dialogResolve = resolve; });
        },

        settleDialog(ok) {
            const resolve = this._dialogResolve;
            if (!resolve) return;
            const value = this._dialogArea ? $('dialogTextarea').value : $('dialogInput').value;
            this._dialogResolve = null;
            $('dialog').hidden = true;
            $('dialogScrim').hidden = true;
            resolve(this._dialogPrompt ? (ok ? value : null) : !!ok);
        },

        dialogOpen() { return !$('dialog').hidden; },

        modalStatus(id, text, kind) {
            const node = $(id);
            node.textContent = text || '';
            node.className = 'modal-status' + (kind ? ' is-' + kind : '');
        },

        status(text) {
            const node = $('composerStatus');
            node.textContent = text || '';
            node.hidden = !text;
        },

        toast(text) {
            const node = $('toast');
            node.textContent = text;
            node.hidden = false;
            clearTimeout(this._toastTimer);
            this._toastTimer = setTimeout(() => { node.hidden = true; }, 4000);
        },

        autoGrow() {
            const input = $('input');
            input.style.height = 'auto';
            input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.4) + 'px';
        },

        writeClipboard(text) {
            try {
                navigator.clipboard.writeText(text);
                this.toast(t('Copied.'));
            } catch (_) {
                const field = document.createElement('textarea');
                field.value = text;
                document.body.appendChild(field);
                field.select();
                try { document.execCommand('copy'); this.toast(t('Copied.')); } catch (__) { }
                field.remove();
            }
        },

        // --- wiring ------------------------------------------------------------------

        handlers() {
            return {
                'gate-generate': () => this.gateGenerate(),
                'gate-show-import': () => { $('gateImport').hidden = false; $('gateNsec').focus(); },
                'gate-cancel-import': () => { $('gateImport').hidden = true; },
                'gate-import': () => this.gateImport(),
                'gate-extension': () => this.gateExtension(),
                'reveal-done': () => { $('reveal').hidden = true; this.enter(); },
                'copy': (target) => this.copy(target.dataset.target),
                'new-chat': () => this.open(this.newConversation()),
                'toggle-sidebar': () => this.toggleSidebar(),
                'close-sidebar': () => this.toggleSidebar(false),
                'open-settings': () => this.openSettings(),
                'open-palette': () => this.openPalette(),
                'chat-menu': () => { $('chatMenu').hidden = !$('chatMenu').hidden; },
                'rename-chat': () => { $('chatMenu').hidden = true; this.renameChat(); },
                'pin-chat': () => { $('chatMenu').hidden = true; this.pinChat(); },
                'archive-chat': () => { $('chatMenu').hidden = true; this.archiveChat(); },
                'fork-chat': () => {
                    $('chatMenu').hidden = true;
                    const copy = Store.duplicateConversation(this.conv.id, (this.conv.title || t('New chat')) + ' ' + t('(copy)'));
                    if (copy) this.open(Store.conversation(copy.id));
                },
                'open-system': () => { $('chatMenu').hidden = true; this.openSystem(); },
                'open-tags': () => { $('chatMenu').hidden = true; this.openTags(); },
                'open-stats': () => { $('chatMenu').hidden = true; this.openStats(); },
                'export-md': () => { $('chatMenu').hidden = true; Exporter.conversation(this.conv, 'md'); },
                'export-json': () => { $('chatMenu').hidden = true; Exporter.conversation(this.conv, 'json'); },
                'copy-transcript': () => {
                    $('chatMenu').hidden = true;
                    this.writeClipboard(Exporter.clipboardMarkdown(this.conv));
                },
                'clear-chat': () => { $('chatMenu').hidden = true; this.clearChat(); },
                'delete-chat': () => { $('chatMenu').hidden = true; this.deleteChat(); },
                'conv-filter': (target) => {
                    this.convFilter = target.dataset.filter;
                    for (const b of document.querySelectorAll('#sidebarFilters .pill')) {
                        b.classList.toggle('is-active', b === target);
                    }
                    this.renderList();
                },
                'model-filter': (target) => {
                    this.modelFilter = target.dataset.filter;
                    for (const b of document.querySelectorAll('#modelFilters .pill')) {
                        b.classList.toggle('is-active', b === target);
                    }
                    this.renderModels();
                },
                'tier': (target) => {
                    if (target.dataset.tier === 'pro') this.openModels();
                    else this.setModel(null);
                },
                'open-models': () => this.openModels(),
                'open-help': () => this.openHelp(),
                'open-schedules': () => this.openSchedules(),
                'schedule-save': () => this.saveScheduleForm(),
                'schedule-reset': () => this.resetScheduleForm(),
                'toggle-ghost': () => this.toggleGhost(),
                'open-bots': () => this.openBots(),
                'bot-save': () => this.saveBot(),
                'bot-reset': () => this.resetBotForm(),
                'bot-copy-link': () => this.writeClipboard($('shareBotLink').value),
                'bot-publish': () => this.publishBot(),
                'bot-fetch': () => this.fetchBot(),
                'bot-accept': () => this.acceptBot(),
                'open-workspaces': () => this.openWorkspaces(),
                'workspace-save': () => this.saveWorkspace(),
                'workspace-reset': () => this.resetWorkspaceForm(),
                'workspace-add-file': () => $('workspaceFileInput').click(),
                'open-compare': () => this.openCompare(),
                'compare-run': () => this.runCompare(),
                'open-artifacts': () => this.openArtifactList(),
                'artifact-open': (target) => this.openArtifact(target.dataset.artifact),
                'artifact-close': () => this.closeArtifact(),
                'artifact-tab': (target) => this.setArtifactTab(target.dataset.tab),
                'artifact-save': () => this.saveArtifact(),
                'artifact-copy': () => {
                    if (this.artifact) this.writeClipboard($('artifactBody').value);
                },
                'artifact-download': () => {
                    const a = this.artifact;
                    if (!a) return;
                    const name = a.title.replace(/[^\w.-]+/g, '-').toLowerCase()
                        + '.' + Artifacts.extensionFor(a.lang);
                    Exporter.download(name, 'text/plain', $('artifactBody').value);
                },
                'open-repos': () => this.openRepos(),
                'open-personas': () => this.openPersonas(),
                'open-prompts': () => this.openPrompts(),
                'open-pinned': () => this.openPinned(),
                'open-appearance': () => this.openAppearance(),
                'open-shortcuts': () => this.openShortcuts(),
                'open-anon': () => this.openAnon(),
                'open-credits': () => this.openCredits(),
                'toggle-web': () => {
                    this.saveSettings({ webSearch: !this.settings.webSearch });
                    this.refreshToolbar();
                },
                'close-modal': () => this.closeModals(),
                'model-off': () => { this.setModel(null); this.closeModals(); },
                'repo-save': () => this.saveRepo(),
                'repo-reset': () => this.resetRepoForm(),
                'repo-none': () => {
                    this.conv = Store.updateConversation(this.conv.id, { repoIds: [] });
                    this.renderRepos();
                    this.refreshToolbar();
                    this.renderList();
                },
                'repo-all': () => {
                    this.conv = Store.updateConversation(this.conv.id, { repoIds: Store.repos().map(r => r.id) });
                    this.renderRepos();
                    this.refreshToolbar();
                    this.renderList();
                },
                'persona-save': () => this.savePersona(),
                'persona-reset': () => this.resetPersonaForm(),
                'persona-off': () => {
                    this.conv = Store.updateConversation(this.conv.id, { personaId: null });
                    this.refreshToolbar();
                    this.renderPersonas();
                },
                'system-save': () => this.saveSystem(),
                'system-clear': () => { $('systemBody').value = ''; this.saveSystem(); },
                'prompt-save': () => this.savePrompt(),
                'prompt-reset': () => this.resetPromptForm(),
                'tags-save': () => this.saveTags(),
                'folder-create': () => this.createFolder(),
                'export-all': () => Exporter.everything(),
                'import-open': () => $('importPicker').click(),
                'reset-appearance': () => {
                    this.settings = Store.resetSettings();
                    this.applyAppearance();
                    this.openAppearance();
                    this.renderMessages();
                    this.refreshToolbar();
                },
                'anon-move': () => this.moveCredits(),
                'anon-rotate': async () => {
                    const ok = await this.ask({
                        title: t('Rotate the throwaway key'),
                        body: t('Rotate the throwaway key? Its balance moves across, which shows Nymbot one anonymous key paying another.'),
                        confirm: t('Rotate'),
                        danger: true
                    });
                    if (!ok) return;
                    await Anon.rotate(true);
                    this.openAnon();
                },
                'credit-tier': (target) => {
                    this.creditTier = target.dataset.tier;
                    for (const b of document.querySelectorAll('#creditTier .tier-btn')) {
                        b.classList.toggle('is-active', b === target);
                    }
                    this.creditSats();
                },
                'credit-buy': () => this.buyCredits(),
                'toggle-nsec': (target) => {
                    const f = $('setNsec');
                    f.type = f.type === 'password' ? 'text' : 'password';
                    target.textContent = f.type === 'password' ? t('Show') : t('Hide');
                },
                'dialog-confirm': () => this.settleDialog(true),
                'dialog-cancel': () => this.settleDialog(false),
                'link-root': () => this.linkRoot(),
                'transfer': () => this.transfer(),
                'wipe': () => this.wipe(),
                'send': () => this.send(),
                'stop': () => this.stop(),
                'attach': () => $('filePicker').click(),
                'mic': () => Speech.toggleListening(),
                'cancel-quote': () => { this.quote = null; this.renderQuote(); },
                'scroll-bottom': () => this.scrollToBottom(),
                'find-in-chat': () => this.openFind(),
                'find-close': () => this.closeFind(),
                'find-next': () => this.stepFind(1),
                'find-prev': () => this.stepFind(-1)
            };
        },

        bind() {
            const handlers = this.handlers();

            document.addEventListener('click', (e) => {
                const target = e.target.closest('[data-act]');
                if (!target) {
                    if (!e.target.closest('#chatMenu')) $('chatMenu').hidden = true;
                    return;
                }
                if (this.dialogOpen() && !e.target.closest('#dialog')) return;
                const act = target.dataset.act;
                if (act.startsWith('msg-')) {
                    e.preventDefault();
                    this.messageAction(act, target.dataset.id);
                    return;
                }
                if (act.startsWith('code-')) {
                    e.preventDefault();
                    this.codeAction(act, target.dataset.codeId, target);
                    return;
                }
                if (handlers[act]) { e.preventDefault(); handlers[act](target); }
            });

            $('scrim').addEventListener('click', () => { this.closePalette(); this.closeModals(); });
            $('dialogScrim').addEventListener('click', () => this.settleDialog(false));

            document.addEventListener('keydown', (e) => {
                const mod = e.metaKey || e.ctrlKey;
                const inField = /^(INPUT|TEXTAREA|SELECT)$/.test((e.target.tagName || ''));

                if (e.key === 'Escape') {
                    if (e.shiftKey && this.sending) { this.stop(); return; }
                    if (this.dialogOpen()) this.settleDialog(false);
                    else if (this.artifact && !document.querySelector('.modal:not([hidden])')
                        && $('palette').hidden) this.closeArtifact();
                    else if (!$('palette').hidden) this.closePalette();
                    else if (!$('findBar').hidden && document.activeElement === $('findInput')) this.closeFind();
                    else if ($('suggest').hidden === false) this.hideSuggest();
                    else this.closeModals();
                    return;
                }

                if (mod && e.key.toLowerCase() === 'k') { e.preventDefault(); this.openPalette(); return; }
                if (mod && e.shiftKey && e.key.toLowerCase() === 'f') { e.preventDefault(); this.openSearch(''); return; }
                if (mod && !e.shiftKey && e.key.toLowerCase() === 'f') { e.preventDefault(); this.openFind(); return; }
                if (mod && e.key.toLowerCase() === 'n') { e.preventDefault(); this.open(this.newConversation()); return; }
                if (mod && e.key.toLowerCase() === 'b') { e.preventDefault(); this.toggleSidebar(); return; }
                if (mod && e.shiftKey && e.key.toLowerCase() === 'm') { e.preventDefault(); this.openModels(); return; }
                if (mod && e.shiftKey && e.key.toLowerCase() === 'g') { e.preventDefault(); this.openRepos(); return; }
                if (mod && e.shiftKey && e.key.toLowerCase() === 'p') { e.preventDefault(); this.openPrompts(); return; }
                // Not R: Ctrl/Cmd+Shift+R is the browser's hard refresh, and
                // taking it away leaves no way to reload a stale shell.
                if (mod && e.shiftKey && e.key.toLowerCase() === 's') {
                    e.preventDefault();
                    this.handleCommand('?retry');
                    return;
                }
                if (mod && e.shiftKey && e.key.toLowerCase() === 'c') {
                    e.preventDefault();
                    const msgs = Store.messages(this.conv.id).filter(m => m.role === 'bot');
                    if (msgs.length) this.writeClipboard(msgs[msgs.length - 1].content);
                    return;
                }
                if (!inField && e.key === '/') {
                    e.preventDefault();
                    $('input').focus();
                    return;
                }
            });

            $('paletteInput').addEventListener('input', () => this.renderPalette());
            $('paletteInput').addEventListener('keydown', (e) => {
                if (e.key === 'ArrowDown') { e.preventDefault(); this.movePalette(1); }
                else if (e.key === 'ArrowUp') { e.preventDefault(); this.movePalette(-1); }
                else if (e.key === 'Enter') { e.preventDefault(); this.runPalette(); }
            });

            $('dialogInput').addEventListener('keydown', (e) => {
                if (e.key === 'Enter') { e.preventDefault(); this.settleDialog(true); }
            });
            $('dialogTextarea').addEventListener('keydown', (e) => {
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); this.settleDialog(true); }
            });

            const input = $('input');
            input.addEventListener('input', () => {
                this.autoGrow();
                this.updateSuggest();
                this.updateHints();
                if (this.conv) Store.setDraft(this.conv.id, input.value);
            });
            input.addEventListener('keydown', (e) => {
                if (!$('suggest').hidden) {
                    if (e.key === 'ArrowDown') { e.preventDefault(); this.moveSuggest(1); return; }
                    if (e.key === 'ArrowUp') { e.preventDefault(); this.moveSuggest(-1); return; }
                    if (e.key === 'Tab') { e.preventDefault(); this.pickSuggest(); return; }
                    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); this.pickSuggest(); return; }
                }
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                    e.preventDefault();
                    this.send();
                    return;
                }
                if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && this.settings.sendOnEnter !== false) {
                    e.preventDefault();
                    this.send();
                    return;
                }
                if (e.key === 'ArrowUp' && !input.value.trim()) {
                    const msgs = Store.messages(this.conv.id).filter(m => m.role === 'self');
                    if (msgs.length) {
                        e.preventDefault();
                        input.value = msgs[msgs.length - 1].content;
                        this.autoGrow();
                        this.updateHints();
                    }
                }
            });
            input.addEventListener('paste', async (e) => {
                const items = e.clipboardData && e.clipboardData.items;
                if (!items) return;
                const files = Array.from(items).filter(i => i.kind === 'file');
                if (!files.length) return;
                e.preventDefault();
                const built = await Attach.fromClipboard(items);
                this.attachments = this.attachments.concat(built);
                this.renderAttachments();
            });

            const drop = document.querySelector('.main');
            if (drop) {
                drop.addEventListener('dragover', (e) => { e.preventDefault(); });
                drop.addEventListener('drop', (e) => {
                    e.preventDefault();
                    if (e.dataTransfer && e.dataTransfer.files.length) {
                        this.addFiles(Array.from(e.dataTransfer.files));
                    }
                });
            }

            $('filePicker').addEventListener('change', (e) => {
                this.addFiles(Array.from(e.target.files || []));
                e.target.value = '';
            });
            $('helpSearch').addEventListener('input', () => this.renderHelp());
            $('workspaceFileInput').addEventListener('change', (e) => {
                this.addWorkspaceFiles(e.target.files);
                e.target.value = '';
            });
            $('importPicker').addEventListener('change', (e) => {
                const file = (e.target.files || [])[0];
                if (file) this.importBackup(file);
                e.target.value = '';
            });

            $('messages').addEventListener('scroll', () => {
                $('jumpBtn').hidden = this.nearBottom();
            });

            $('artifactBody').addEventListener('input', () => {
                if (!this.artifact) return;
                $('artifactSave').hidden = $('artifactBody').value === this.artifact.body;
            });
            $('artifactTitle').addEventListener('change', () => {
                if (!this.artifact) return;
                const updated = Artifacts.rename(this.conv.id, this.artifact.id,
                    $('artifactTitle').value.trim() || this.artifact.title);
                if (updated) {
                    this.artifact = updated;
                    this.renderMessages();
                }
            });

            $('convSearch').addEventListener('input', () => this.renderList());
            $('modelSearch').addEventListener('input', () => this.renderModels());
            $('promptSearch').addEventListener('input', () => this.renderPrompts());
            $('globalSearch').addEventListener('input', () => this.renderSearch());
            $('searchArchived').addEventListener('change', () => this.renderSearch());
            $('findInput').addEventListener('input', () => this.runFind());
            $('findInput').addEventListener('keydown', (e) => {
                if (e.key === 'Enter') { e.preventDefault(); this.stepFind(e.shiftKey ? -1 : 1); }
            });
            $('creditAmount').addEventListener('input', () => this.creditSats());
            $('modelForChat').addEventListener('change', () => this.renderModels());
            $('anonToggle').addEventListener('change', (e) => {
                Anon.setEnabled(e.target.checked);
                this.refreshToolbar();
                if (e.target.checked) this.runAutoTopUp({ announce: true });
            });
            $('anonAutoTop').addEventListener('change', (e) => {
                this.saveSettings({ anonAutoTop: e.target.checked });
                $('anonAutoFields').hidden = !e.target.checked;
                $('anonAutoTier').hidden = !e.target.checked;
                if (e.target.checked) this.runAutoTopUp({ announce: true });
            });
            for (const [id, key] of [['anonAutoFloor', 'anonAutoTopFloor'],
                ['anonAutoAmount', 'anonAutoTopAmount']]) {
                $(id).addEventListener('change', (e) => {
                    const n = Math.max(key === 'anonAutoTopAmount' ? 1 : 0,
                        parseInt(e.target.value, 10) || 0);
                    e.target.value = String(n);
                    this.saveSettings({ [key]: n });
                });
            }
            $('anonAutoTier').addEventListener('change', (e) => {
                this.saveSettings({ anonAutoTopTier: e.target.value });
            });
            $('gateNsec').addEventListener('keydown', (e) => {
                if (e.key === 'Enter') this.gateImport();
            });
            $('langSelect').addEventListener('change', (e) => {
                window.NymbotI18n.setLang(e.target.value);
            });

            for (const id of ['setTheme', 'setDensity', 'setFont', 'setGrouping', 'setBubbles',
                'setAvatars', 'setTimestamps', 'setTypewriter', 'setReasoning', 'setMono',
                'setLineNumbers', 'setCodeWrap', 'setMotion', 'setEnter', 'setEstimate',
                'setSound', 'setHaptic', 'setAutoSpeak', 'setVoice', 'setRate']) {
                const node = $(id);
                if (node) node.addEventListener('change', () => this.readAppearance());
            }

            if (Speech.canSpeak() && window.speechSynthesis) {
                window.speechSynthesis.onvoiceschanged = () => {
                    if (!$('modalAppearance').hidden) this.renderVoices();
                };
            }

            window.addEventListener('beforeunload', () => {
                if (this.conv) Store.setDraft(this.conv.id, $('input').value);
            });
        },

        gateError(message) {
            const node = $('gateError');
            node.textContent = message || '';
            node.hidden = !message;
        },

        gateGenerate() {
            try {
                Identity.generate();
                $('revealNsec').value = NT().nip19.nsecEncode(Identity._sk);
                $('revealRoot').value = Identity.rootCode() || '';
                $('gate').hidden = true;
                $('reveal').hidden = false;
            } catch (e) {
                this.gateError(e.message || t('Could not create a key.'));
            }
        },

        gateImport() {
            try {
                Identity.importSecret($('gateNsec').value);
                $('gateNsec').value = '';
                this.enter();
            } catch (e) {
                this.gateError(e.message || t('That key could not be read.'));
            }
        },

        async gateExtension() {
            try {
                await Identity.useExtension();
                this.enter();
            } catch (e) {
                this.gateError(e.message || t('The extension refused.'));
            }
        },

        copy(id) {
            const field = $(id);
            if (!field) return;
            const wasHidden = field.type === 'password';
            if (wasHidden) field.type = 'text';
            field.select();
            try {
                navigator.clipboard.writeText(field.value);
                this.toast(t('Copied.'));
            } catch (_) {
                document.execCommand('copy');
            }
            if (wasHidden) field.type = 'password';
        }
    };

    window.NymbotUI = UI;
    UI.start();
})();
