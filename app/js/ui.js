// The shell: conversations, the composer, the toolbar and the modals.
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
    const NT = () => window.NostrTools;

    const $ = (id) => document.getElementById(id);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };

    const UI = {
        conv: null,
        settings: Store.settings(),
        models: null,
        balance: { standard: null, pro: null },
        sending: false,
        invoice: null,

        // --- boot -----------------------------------------------------------

        async start() {
            // The pack decides what every string below reads as, so nothing is
            // rendered until it has landed (or failed, which is English).
            await window.NymbotI18n.ready;
            this.bind();
            Anon.load();
            Anon.onKeysetChange = (oldId, newId) => Promise.resolve(window.confirm(
                t('Nymbot\'s voucher signing keys changed since you last moved credits.\n\nThat happens on a legitimate key rotation, but it is also what a server would do to tag your vouchers. Continue anyway?')));

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

            const list = Store.conversations();
            this.open(list.length ? list[0] : this.newConversation());
            this.renderList();
            this.renderIdentity();
            this.refreshToolbar();

            // The announcement and the bot's key are what make a reply
            // post-quantum; neither blocks the first message.
            setTimeout(async () => {
                try { await PQ.resolveBot(); } catch (_) { }
                try { await PQ.announce(); } catch (_) { }
                if (Identity.rootLocked) this.toast(t('This account already uses another device\'s post-quantum key. Open Identity to link this one.'));
                this.refreshBalance();
                Anon.flush().catch(() => { });
            }, 300);

            Chat.onStatus = (text) => this.status(text);
        },

        // --- conversations ---------------------------------------------------

        newConversation() {
            const conv = Store.createConversation();
            conv.rootId = window.NymbotHex.hex(crypto.getRandomValues(new Uint8Array(32)));
            conv.anon = Anon.enabled();
            Store.updateConversation(conv.id, { rootId: conv.rootId, anon: conv.anon });
            return conv;
        },

        open(conv) {
            this.conv = conv;
            $('chatTitle').textContent = conv.title || t('New chat');
            $('chatAnon').hidden = !conv.anon;
            this.toggleSidebar(false);
            this.renderMessages();
            this.renderList();
            $('input').focus();
        },

        renderList() {
            const term = ($('convSearch').value || '').toLowerCase().trim();
            const list = $('convList');
            list.innerHTML = '';
            for (const conv of Store.conversations()) {
                if (term) {
                    const inTitle = (conv.title || '').toLowerCase().includes(term);
                    const inBody = !inTitle && Store.messages(conv.id)
                        .some(m => (m.content || '').toLowerCase().includes(term));
                    if (!inTitle && !inBody) continue;
                }
                const li = el('li');
                const btn = el('button', 'conv-item' + (this.conv && conv.id === this.conv.id ? ' is-active' : ''));
                btn.type = 'button';
                btn.appendChild(el('span', 'conv-title', conv.title || t('New chat')));
                if (conv.anon) btn.appendChild(el('span', 'conv-badge', 'anon'));
                btn.addEventListener('click', () => this.open(Store.conversation(conv.id)));
                li.appendChild(btn);
                list.appendChild(li);
            }
        },

        renderMessages() {
            const box = $('messages');
            box.innerHTML = '';
            const msgs = Store.messages(this.conv.id);
            if (!msgs.length) {
                box.appendChild(this.emptyState());
                return;
            }
            for (const m of msgs) box.appendChild(this.messageNode(m));
            box.scrollTop = box.scrollHeight;
        },

        emptyState() {
            const wrap = el('div', 'empty');
            wrap.appendChild(el('h2', null, t('Ask Nymbot anything')));
            wrap.appendChild(el('p', null,
                t('End-to-end encrypted, paid a reply at a time. Type ? for commands, or start with one of these.')));
            const tips = el('div', 'empty-tips');
            // The commands are literal; only the prose example is translated.
            for (const tip of ['?help', '?balance', t('Explain ML-KEM in three sentences'), '?image a lighthouse at dusk']) {
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

        messageNode(m) {
            const node = el('div', 'msg is-' + m.role);
            node.dataset.id = m.id;
            const who = m.role === 'self' ? 'you' : (m.role === 'bot' ? C.botName.toLowerCase() : '');
            if (who) node.appendChild(el('div', 'msg-role', who));
            const body = el('div', 'msg-body');

            if (m.thinking) {
                const det = el('details', 'reasoning');
                det.appendChild(el('summary', null, '💭 ' + t('Reasoning')));
                det.appendChild(el('div', 'reasoning-body', m.thinking));
                body.appendChild(det);
            }

            if (m.role === 'bot') {
                const html = el('div');
                html.innerHTML = MD.render(m.content);
                body.appendChild(html);
            } else {
                const p = el('div');
                p.style.whiteSpace = 'pre-wrap';
                p.textContent = m.content;
                body.appendChild(p);
            }
            node.appendChild(body);

            if (m.cost || m.model) {
                const meta = el('div', 'msg-meta');
                if (m.model) meta.appendChild(el('span', null, m.model));
                if (m.cost) meta.appendChild(el('span', 'msg-cost', `⚡ ${m.cost}`));
                node.appendChild(meta);
            }
            return node;
        },

        appendMessage(m) {
            const box = $('messages');
            if (box.querySelector('.empty')) box.innerHTML = '';
            box.appendChild(this.messageNode(m));
            box.scrollTop = box.scrollHeight;
        },

        thinkingNode(label) {
            const node = el('div', 'msg is-bot');
            node.id = 'thinkingNode';
            node.appendChild(el('div', 'msg-role', C.botName.toLowerCase()));
            const body = el('div', 'msg-body');
            const row = el('div', 'thinking');
            row.appendChild(el('span', null, label || 'thinking'));
            row.appendChild(el('span', 'dot'));
            row.appendChild(el('span', 'dot'));
            row.appendChild(el('span', 'dot'));
            body.appendChild(row);
            node.appendChild(body);
            return node;
        },

        // --- sending ----------------------------------------------------------

        async send() {
            const input = $('input');
            const text = input.value.trim();
            if (!text || this.sending) return;

            if (await this.handleCommand(text)) {
                input.value = '';
                this.autoGrow();
                return;
            }

            input.value = '';
            this.autoGrow();

            const mine = { id: Store.uid(), role: 'self', content: text, ts: Date.now() };
            Store.addMessage(this.conv.id, mine);
            this.appendMessage(mine);

            if (!this.conv.title) {
                const title = Chat.titleFor(text);
                this.conv = Store.updateConversation(this.conv.id, { title });
                $('chatTitle').textContent = title;
                this.renderList();
            }

            this.sending = true;
            $('sendBtn').disabled = true;
            const box = $('messages');
            const pending = this.thinkingNode(this.settings.git && this.settings.proModel
                ? t('reading your repo') : t('thinking'));
            box.appendChild(pending);
            box.scrollTop = box.scrollHeight;

            try {
                const res = await Chat.send(this.conv, text, this.settings);
                pending.remove();
                const reply = {
                    id: Store.uid(),
                    role: 'bot',
                    content: res.reply,
                    thinking: res.thinking || null,
                    cost: res.cost || 0,
                    model: res.pro && this.settings.proModel ? this.settings.proModel.label : null,
                    ts: Date.now()
                };
                Store.addMessage(this.conv.id, reply);
                this.appendMessage(reply);
                Store.updateConversation(this.conv.id, {});
                this.renderList();

                if (res.balance != null) {
                    this.balance[res.pro ? 'pro' : 'standard'] = res.balance;
                    this.renderBalance();
                }
                if (res.lowBalance) {
                    this.note(res.pro
                        ? t('Pro credits running low: {balance} left. Tap Buy to top up.', { balance: res.balance })
                        : t('Credits running low: {balance} left. Tap Buy to top up.', { balance: res.balance }));
                }
            } catch (e) {
                pending.remove();
                if (e.noCredits) {
                    this.balance[e.pro ? 'pro' : 'standard'] = e.balance;
                    this.renderBalance();
                    this.note(e.message);
                    this.openModal(this.conv.anon ? 'modalAnon' : 'modalCredits');
                } else {
                    const err = { id: Store.uid(), role: 'error', content: e.message || t('Something went wrong.'), ts: Date.now() };
                    Store.addMessage(this.conv.id, err);
                    this.appendMessage(err);
                }
            } finally {
                this.sending = false;
                $('sendBtn').disabled = false;
                this.status(null);
            }
        },

        note(text) {
            const m = { id: Store.uid(), role: 'note', content: text, ts: Date.now() };
            Store.addMessage(this.conv.id, m);
            this.appendMessage(m);
        },

        /// Commands handled here, free of charge, never sent anywhere.
        async handleCommand(text) {
            const m = /^\?(\w+)\s*(.*)$/s.exec(text);
            if (!m) return false;
            const cmd = m[1].toLowerCase();
            const arg = m[2].trim();

            switch (cmd) {
                case 'help':
                case 'commands':
                    this.note([
                        t('Free, on this device: ?help ?balance ?buy ?model ?git ?anon ?clear'),
                        'Charged: ?ask ?image ?speak ?translate ?define ?news ?math ?units ?time ?btc',
                        'Games: ?trivia ?joke ?riddle ?wordplay ?flip ?8ball ?pick',
                        t('Start a message with ! to send it without this chat\'s history.')
                    ].join('\n'));
                    return true;
                case 'balance':
                    await this.refreshBalance(true);
                    return true;
                case 'buy':
                    this.openModal('modalCredits');
                    return true;
                case 'model':
                    if (/^off$/i.test(arg)) {
                        this.setModel(null);
                        this.note(t('Back to standard auto-routing.'));
                        return true;
                    }
                    await this.openModels(arg);
                    return true;
                case 'git':
                    if (/^writes\s+(on|off)$/i.test(arg)) {
                        const on = /on$/i.test(arg);
                        this.settings = Store.setSettings({ git: Object.assign({}, this.settings.git, { allowWrites: on }) });
                        this.note(`Repository writes ${on ? 'on' : 'off'}.`);
                        this.refreshToolbar();
                        return true;
                    }
                    if (/^disconnect$/i.test(arg)) {
                        this.settings = Store.setSettings({ git: null });
                        this.refreshToolbar();
                        this.note(t('Repository disconnected.'));
                        return true;
                    }
                    this.openGit();
                    return true;
                case 'anon':
                    this.openAnon();
                    return true;
                case 'clear':
                    await this.clearChat();
                    return true;
                default:
                    return false;
            }
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
            const tier = this.settings.proModel ? 'pro' : 'standard';
            const value = this.balance[tier];
            $('chipBuyLabel').textContent = value == null ? t('Buy') : String(value);
            $('whoBalance').textContent = this.balance.standard == null ? ''
                : t('{standard} standard · {pro} Pro',
                    { standard: this.balance.standard, pro: this.balance.pro });
        },

        renderIdentity() {
            const pk = Identity.pubkey || '';
            $('whoNym').textContent = pk ? 'nym#' + pk.slice(-4) : '';
        },

        // --- toolbar ----------------------------------------------------------

        refreshToolbar() {
            const pro = !!this.settings.proModel;
            $('toolbar').classList.toggle('is-pro', pro);
            for (const b of document.querySelectorAll('#toolbar .tier-btn')) {
                b.classList.toggle('is-active', (b.dataset.tier === 'pro') === pro);
            }
            const model = $('chipModel');
            model.classList.toggle('is-active', pro);
            model.querySelector('.chip-label').textContent = pro ? this.settings.proModel.label : t('Auto-routed');

            const git = this.settings.git;
            const gitChip = $('chipGit');
            gitChip.classList.toggle('is-active', !!(git && git.repo));
            gitChip.querySelector('.chip-label').textContent = git && git.repo ? git.repo : t('Git');

            const anonChip = $('chipAnon');
            const anonOn = Anon.enabled();
            anonChip.classList.toggle('is-active', anonOn);
            anonChip.querySelector('.chip-label').textContent = anonOn ? t('Anon on') : t('Anon');

            this.renderBalance();
        },

        setModel(model) {
            this.settings = Store.setSettings({ proModel: model, tier: model ? 'pro' : 'standard' });
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

        renderModels() {
            const term = ($('modelSearch').value || '').toLowerCase().trim();
            const list = $('modelList');
            list.innerHTML = '';
            const byKey = new Map(this.models.models.map(m => [m.key, m]));
            for (const group of this.models.groups || []) {
                const rows = group.keys
                    .map(k => byKey.get(k))
                    .filter(m => m && (!term || m.key.toLowerCase().includes(term) || m.label.toLowerCase().includes(term)));
                if (!rows.length) continue;
                list.appendChild(el('div', 'model-group', group.author));
                for (const m of rows) {
                    const row = el('button', 'model-row'
                        + (this.settings.proModel && this.settings.proModel.key === m.key ? ' is-active' : ''));
                    row.type = 'button';
                    const name = el('span', 'model-name');
                    name.appendChild(document.createTextNode(m.label));
                    if (m.description) name.appendChild(el('span', 'model-desc', m.description));
                    row.appendChild(name);
                    row.appendChild(el('span', 'model-cost',
                        m.max && m.max !== m.credits ? `${m.credits}–${m.max}` : String(m.credits)));
                    row.addEventListener('click', () => {
                        this.setModel({ key: m.key, label: m.label, credits: m.credits });
                        this.closeModals();
                    });
                    list.appendChild(row);
                }
            }
            if (!list.children.length) list.textContent = t('Nothing matches that.');
        },

        // --- git ---------------------------------------------------------------

        openGit() {
            const cfg = this.settings.git || {};
            $('gitProvider').value = cfg.provider || 'github';
            $('gitHost').value = cfg.host || '';
            $('gitToken').value = cfg.token || '';
            $('gitRepo').value = cfg.repo || '';
            $('gitBranch').value = cfg.branch || '';
            $('gitWrites').checked = !!cfg.allowWrites;
            $('gitStatus').textContent = '';
            this.openModal('modalGit');
        },

        connectGit() {
            const cfg = {
                provider: $('gitProvider').value,
                host: $('gitHost').value.trim(),
                token: $('gitToken').value.trim(),
                repo: $('gitRepo').value.trim(),
                branch: $('gitBranch').value.trim(),
                allowWrites: $('gitWrites').checked
            };
            if (!cfg.token || !cfg.repo) {
                this.modalStatus('gitStatus', t('A token and a repository are both needed.'), 'warn');
                return;
            }
            this.settings = Store.setSettings({ git: cfg });
            this.refreshToolbar();
            this.closeModals();
            this.toast(t('Connected to {repo}. Pin a Pro model to use it.', { repo: cfg.repo }));
        },

        // --- anonymous mode ------------------------------------------------------

        openAnon() {
            $('anonToggle').checked = Anon.enabled();
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
            this.creditTier = this.settings.proModel ? 'pro' : 'standard';
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
            $('invoiceBox').hidden = true;
            $('creditStatus').textContent = '';
            this.creditSats();
            this.openModal('modalCredits');
        },

        creditSats() {
            const credits = Math.max(0, parseInt($('creditAmount').value, 10) || 0);
            const sats = credits * C.satsPerCredit[this.creditTier];
            if (!credits) { $('creditSats').textContent = ''; return; }
            $('creditSats').textContent = this.creditTier === 'pro'
                ? t('{credits} Pro credits = {sats} sats', { credits, sats })
                : t('{credits} credits = {sats} sats', { credits, sats });
        },

        async buyCredits() {
            const credits = Math.max(0, parseInt($('creditAmount').value, 10) || 0);
            if (!credits) { this.modalStatus('creditStatus', t('Enter how many credits to buy.'), 'warn'); return; }
            const sats = credits * C.satsPerCredit[this.creditTier];
            this.modalStatus('creditStatus', t('Creating an invoice…'));

            const opts = this.conv && this.conv.anon && Anon.ready() ? { signer: Anon.signer() } : {};
            const { data } = await Api.createInvoice(sats, this.creditTier, null, opts);
            if (!data || data.error || !data.pr) {
                this.modalStatus('creditStatus', (data && data.error) || t('Could not create an invoice.'), 'warn');
                return;
            }
            this.invoice = { id: data.invoiceId, pr: data.pr, tier: this.creditTier, opts };
            $('invoiceText').value = data.pr;
            $('invoiceOpen').href = 'lightning:' + data.pr;
            try { QR.draw($('invoiceQr'), data.pr.toUpperCase(), { width: 240 }); } catch (_) { }
            $('invoiceBox').hidden = false;
            this.modalStatus('creditStatus', t('Pay {sats} sats. This updates the moment it settles.', { sats }));
            this.pollInvoice();
        },

        async pollInvoice() {
            const invoice = this.invoice;
            for (let i = 0; i < 90 && this.invoice === invoice; i++) {
                await new Promise(r => setTimeout(r, 2000));
                const { data } = await Api.checkInvoice(invoice.id, invoice.opts);
                if (!data || !data.paid) continue;
                const claim = await Api.claimCredits(invoice.id, invoice.opts);
                if (claim.data && !claim.data.error) {
                    this.modalStatus('creditStatus',
                        t('Credited. Balance: {balance}.', { balance: claim.data.balance }), 'ok');
                    this.balance[invoice.tier] = claim.data.balance;
                    this.renderBalance();
                    this.invoice = null;
                    return;
                }
                if (claim.data && /already claimed/i.test(claim.data.error || '')) {
                    this.modalStatus('creditStatus', t('That payment was already credited.'), 'ok');
                    this.invoice = null;
                    return;
                }
            }
        },

        // --- identity ---------------------------------------------------------------

        openSettings() {
            $('settingsWho').textContent = Identity.method === 'nip07'
                ? t('Signed in with a browser extension, which holds your key.')
                : t('Your key lives on this device and nowhere else.');
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
            const target = window.prompt(t('Move your whole balance to which public key? (hex, 64 characters)'));
            if (!target) return;
            const { data } = await Api.transferCredits(target.trim().toLowerCase());
            if (!data || data.error) {
                this.modalStatus('settingsStatus', (data && data.error) || t('The transfer failed.'), 'warn');
                return;
            }
            this.modalStatus('settingsStatus', t('Moved.'), 'ok');
            this.refreshBalance();
        },

        wipe() {
            if (!window.confirm(t('Wipe everything on this device — your key, every conversation, and any credits on a throwaway key?\n\nThis cannot be undone.'))) return;
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
            this.conv = Store.updateConversation(this.conv.id, { rootId });
            this.renderMessages();
            this.toast(t('Cleared.'));
        },

        renameChat() {
            const title = window.prompt(t('Name this chat'), this.conv.title || '');
            if (title == null) return;
            this.conv = Store.updateConversation(this.conv.id, { title: title.trim() || t('New chat') });
            $('chatTitle').textContent = this.conv.title;
            this.renderList();
        },

        deleteChat() {
            if (!window.confirm(t('Delete this chat? Its messages are encrypted to your key and cannot be recovered.'))) return;
            Store.deleteConversation(this.conv.id);
            const list = Store.conversations();
            this.open(list.length ? list[0] : this.newConversation());
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
            else if (!document.querySelector('.modal:not([hidden])')) $('scrim').hidden = true;
        },

        openModal(id) {
            this.closeModals();
            $('scrim').hidden = false;
            $(id).hidden = false;
        },

        closeModals() {
            $('sidebar').classList.remove('is-open');
            $('scrim').hidden = true;
            for (const m of document.querySelectorAll('.modal')) m.hidden = true;
            $('chatMenu').hidden = true;
        },

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

        // --- wiring ------------------------------------------------------------------

        bind() {
            document.addEventListener('click', (e) => {
                const target = e.target.closest('[data-act]');
                if (!target) {
                    if (!e.target.closest('#chatMenu')) $('chatMenu').hidden = true;
                    return;
                }
                const act = target.dataset.act;
                const handlers = {
                    'gate-generate': () => this.gateGenerate(),
                    'gate-show-import': () => { $('gateImport').hidden = false; $('gateNsec').focus(); },
                    'gate-cancel-import': () => { $('gateImport').hidden = true; },
                    'gate-import': () => this.gateImport(),
                    'gate-extension': () => this.gateExtension(),
                    'reveal-done': () => { $('reveal').hidden = true; this.enter(); },
                    'copy': () => this.copy(target.dataset.target),
                    'new-chat': () => this.open(this.newConversation()),
                    'toggle-sidebar': () => this.toggleSidebar(),
                    'close-sidebar': () => this.toggleSidebar(false),
                    'open-settings': () => this.openSettings(),
                    'chat-menu': () => { $('chatMenu').hidden = !$('chatMenu').hidden; },
                    'rename-chat': () => { $('chatMenu').hidden = true; this.renameChat(); },
                    'clear-chat': () => { $('chatMenu').hidden = true; this.clearChat(); },
                    'delete-chat': () => { $('chatMenu').hidden = true; this.deleteChat(); },
                    'tier': () => {
                        if (target.dataset.tier === 'pro') this.openModels();
                        else this.setModel(null);
                    },
                    'open-models': () => this.openModels(),
                    'open-git': () => this.openGit(),
                    'open-anon': () => this.openAnon(),
                    'open-credits': () => this.openCredits(),
                    'close-modal': () => this.closeModals(),
                    'model-off': () => { this.setModel(null); this.closeModals(); },
                    'git-connect': () => this.connectGit(),
                    'git-disconnect': () => {
                        this.settings = Store.setSettings({ git: null });
                        this.refreshToolbar();
                        this.closeModals();
                    },
                    'anon-move': () => this.moveCredits(),
                    'anon-rotate': async () => {
                        if (!window.confirm(t('Rotate the throwaway key? Its balance moves across, which shows Nymbot one anonymous key paying another.'))) return;
                        await Anon.rotate(true);
                        this.openAnon();
                    },
                    'credit-tier': () => {
                        this.creditTier = target.dataset.tier;
                        for (const b of document.querySelectorAll('#creditTier .tier-btn')) {
                            b.classList.toggle('is-active', b === target);
                        }
                        this.creditSats();
                    },
                    'credit-buy': () => this.buyCredits(),
                    'toggle-nsec': () => {
                        const f = $('setNsec');
                        f.type = f.type === 'password' ? 'text' : 'password';
                        target.textContent = f.type === 'password' ? t('Show') : t('Hide');
                    },
                    'link-root': () => this.linkRoot(),
                    'transfer': () => this.transfer(),
                    'wipe': () => this.wipe(),
                    'send': () => this.send()
                };
                if (handlers[act]) { e.preventDefault(); handlers[act](); }
            });

            $('scrim').addEventListener('click', () => this.closeModals());
            document.addEventListener('keydown', (e) => {
                if (e.key === 'Escape') this.closeModals();
            });

            const input = $('input');
            input.addEventListener('input', () => this.autoGrow());
            input.addEventListener('keydown', (e) => {
                if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
                    e.preventDefault();
                    this.send();
                }
            });

            $('convSearch').addEventListener('input', () => this.renderList());
            $('modelSearch').addEventListener('input', () => this.renderModels());
            $('creditAmount').addEventListener('input', () => this.creditSats());
            $('anonToggle').addEventListener('change', (e) => {
                Anon.setEnabled(e.target.checked);
                this.refreshToolbar();
            });
            $('gateNsec').addEventListener('keydown', (e) => {
                if (e.key === 'Enter') this.gateImport();
            });
            $('langSelect').addEventListener('change', (e) => {
                window.NymbotI18n.setLang(e.target.value);
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
