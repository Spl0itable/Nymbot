(function () {
    'use strict';

    const Store = window.NymbotStore;
    const Api = window.NymbotApi;

    const MAX_CONNECTORS = 40;
    const MAX_PER_CHAT = 3;
    const SECRET_FIELDS = ['token', 'headerValue'];
    const SECRET_BUNDLE = ['url', 'token', 'headerValue'];
    const ARGS_SHOWN = 2000;
    const ARGS_KEPT = 20000;

    const $ = (id) => document.getElementById(id);
    const num = (v) => window.NymbotI18n.count(v);
    const el = (tag, cls, text) => {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    };

    function publicUrl(url) {
        try {
            const u = new URL(url);
            return u.origin + u.pathname;
        } catch (_) { return ''; }
    }

    function checkUrl(raw) {
        const s = String(raw || '').trim();
        let u;
        try { u = new URL(s); } catch (_) { return t('That is not a valid URL.'); }
        if (u.protocol !== 'https:') return t('Connectors must use https.');
        if (u.username || u.password) return t('Put credentials in the token or header fields, not in the URL.');
        const host = u.hostname.toLowerCase();
        if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.indexOf('.') === -1
            || /^(10|127|0)\./.test(host) || /^192\.168\./.test(host) || /^169\.254\./.test(host)
            || /^172\.(1[6-9]|2\d|3[01])\./.test(host) || host.startsWith('[')) {
            return t('That address is local or private, and the worker cannot reach it.');
        }
        return '';
    }

    const Connectors = {
        MAX_PER_CHAT,

        list() {
            const list = Store.read('connectors', []);
            return Array.isArray(list) ? list : [];
        },

        save(list) {
            Store.write('connectors', list.slice(0, MAX_CONNECTORS));
            return list;
        },

        get(id) { return this.list().find(c => c.id === id) || null; },

        add(cfg) {
            const list = this.list();
            const now = Date.now();
            const entry = Object.assign({ id: Store.uid(), enabled: true, addedAt: now, updatedAt: now, secretAt: now }, cfg);
            list.push(entry);
            this.save(list);
            return entry;
        },

        update(id, patch) {
            const list = this.list();
            const i = list.findIndex(c => c.id === id);
            if (i === -1) return null;
            const now = Date.now();
            const moved = SECRET_BUNDLE.some(f => patch && f in patch && (patch[f] || '') !== (list[i][f] || ''));
            list[i] = Object.assign(list[i], patch, moved ? { updatedAt: now, secretAt: now } : { updatedAt: now });
            this.save(list);
            return list[i];
        },

        remove(id) {
            Store.bury(id);
            this.save(this.list().filter(c => c.id !== id));
            for (const conv of Store.conversations()) {
                if (Array.isArray(conv.connectorIds) && conv.connectorIds.includes(id)) {
                    Store.updateConversation(conv.id, { connectorIds: conv.connectorIds.filter(x => x !== id), silent: true });
                }
            }
        },

        usable(c) {
            if (!c || c.enabled === false || !c.url || c.secretElsewhere) return false;
            if (c.auth === 'bearer' && !c.token) return false;
            if (c.auth === 'header' && (!c.headerName || !c.headerValue)) return false;
            return true;
        },

        forConv(conv) {
            const ids = conv && Array.isArray(conv.connectorIds) ? conv.connectorIds : [];
            const out = [];
            for (const id of ids) {
                const c = this.get(id);
                if (this.usable(c) && !out.includes(c)) out.push(c);
                if (out.length >= MAX_PER_CHAT) break;
            }
            return out;
        },

        payload(c) {
            const out = { id: c.id, name: c.name || t('Connector'), url: c.url };
            if (c.auth === 'bearer' && c.token) out.token = c.token;
            if (c.auth === 'header' && c.headerName && c.headerValue) out.headers = { [c.headerName]: c.headerValue };
            if (Array.isArray(c.tools) && c.tools.length && c.tools.some(tool => tool.enabled === false)) {
                out.tools = c.tools.filter(tool => tool.enabled !== false).map(tool => tool.name);
            }
            if (c.autoAllow === true) out.autoAllow = true;
            else if (Array.isArray(c.autoAllow) && c.autoAllow.length) out.autoAllow = c.autoAllow.slice(0, 500);
            return out;
        },

        payloadFor(conv) {
            return this.forConv(conv).map(c => this.payload(c));
        },

        syncCopy() {
            return this.list().map(c => {
                const copy = Object.assign({}, c);
                for (const f of SECRET_FIELDS) copy[f] = c[f] || '';
                copy.secretAt = Number(c.secretAt) || 0;
                copy.tokenElsewhere = !!(c.token || c.headerValue);
                return copy;
            });
        },

        syncMerge(merged, theirs) {
            const pick = window.NymbotSync.pickSecret;
            const byId = new Map(this.list().map(c => [c.id, c]));
            const came = new Map((Array.isArray(theirs) ? theirs : []).filter(c => c && c.id).map(c => [c.id, c]));
            this.save(merged.map(c => {
                const held = byId.get(c.id);
                const mine = held && held.secretElsewhere ? Object.assign({}, held, { url: '' }) : held;
                const kept = pick(mine, came.get(c.id), SECRET_BUNDLE, 'secretAt', SECRET_FIELDS);
                const from = kept.from === 'theirs' ? came.get(c.id) : held;
                const copy = Object.assign({}, c);
                for (const f of SECRET_FIELDS) {
                    if (kept[f]) copy[f] = kept[f];
                    else delete copy[f];
                }
                if (kept.secretAt) copy.secretAt = kept.secretAt;
                else delete copy.secretAt;
                if (from && from.url) {
                    copy.url = from.url;
                    if (from.secretElsewhere) copy.secretElsewhere = true;
                    else delete copy.secretElsewhere;
                }
                if (copy.token || copy.headerValue) copy.tokenElsewhere = false;
                return copy;
            }));
        },

        async probe(cfg) {
            const { status, data } = await Api.call('mcp-probe', { server: this.payload(Object.assign({ tools: null }, cfg)) }, { timeout: 45000 });
            if (status >= 400 || !data || data.error || !data.ok) {
                throw new Error((data && data.error) || t('The connector could not be reached.'));
            }
            return data;
        },

        progressLine(step) {
            if (step.kind === 'connector') {
                return t('Connecting to {connector}', { connector: step.connector || '' });
            }
            return step.target
                ? t('{connector}: {tool} — {target}', { connector: step.connector, tool: step.tool || '', target: step.target })
                : t('{connector}: {tool}', { connector: step.connector, tool: step.tool || '' });
        },

        refreshChip(ui) {
            const chip = $('chipConnectors');
            const on = this.forConv(ui.conv || {});
            if (chip) {
                chip.classList.toggle('is-active', on.length > 0);
                chip.querySelector('.chip-label').textContent = on.length === 0
                    ? t('Connectors')
                    : on.length === 1 ? on[0].name : t('{n} connectors', { n: on.length });
            }
            const count = $('connectorCount');
            const all = this.list().length;
            if (count) count.textContent = all ? String(all) : '';
        },

        handlers(ui) {
            return {
                'open-connectors': () => this.open(ui),
                'connector-save': () => this.saveForm(ui),
                'connector-reset': () => this.resetForm(),
                'connector-test': () => this.testForm(ui),
                'connector-none': () => this.setAll(ui, false),
                'connector-all': () => this.setAll(ui, true)
            };
        },

        open(ui) {
            if (!this.wired && $('connectorAuth')) {
                this.wired = true;
                $('connectorAuth').addEventListener('change', () => this.syncAuthFields());
            }
            this.resetForm();
            this.render(ui);
            ui.openModal('modalConnectors');
        },

        setAll(ui, on) {
            if (!ui.conv) return;
            const ids = on ? this.list().filter(c => this.usable(c)).slice(0, MAX_PER_CHAT).map(c => c.id) : [];
            ui.conv = Store.updateConversation(ui.conv.id, { connectorIds: ids });
            this.render(ui);
            ui.refreshToolbar();
        },

        render(ui) {
            const list = $('connectorList');
            if (!list) return;
            list.innerHTML = '';
            const all = this.list();
            const on = new Set((ui.conv && ui.conv.connectorIds) || []);
            if (!all.length) {
                list.appendChild(el('p', 'hint', t('No connectors yet. Add one below and it becomes available to every chat.')));
            }
            for (const c of all) {
                const row = el('div', 'repo-row connector-row' + (on.has(c.id) ? ' is-on' : ''));
                row.dataset.id = c.id;
                const check = document.createElement('input');
                check.type = 'checkbox';
                check.className = 'repo-check';
                check.checked = on.has(c.id);
                check.disabled = !this.usable(c) && !check.checked;
                check.addEventListener('change', () => {
                    const next = new Set((ui.conv.connectorIds || []));
                    if (check.checked) next.add(c.id); else next.delete(c.id);
                    if (next.size > MAX_PER_CHAT) {
                        check.checked = false;
                        ui.modalStatus('connectorStatus', t('At most {n} connectors can be on in one chat.', { n: MAX_PER_CHAT }), 'warn');
                        return;
                    }
                    ui.conv = Store.updateConversation(ui.conv.id, { connectorIds: Array.from(next) });
                    ui.refreshToolbar();
                    this.render(ui);
                });
                row.appendChild(check);

                const main = el('div', 'repo-main');
                main.appendChild(el('span', 'repo-name', c.name || t('Connector')));
                const bits = [publicUrl(c.url) || c.url];
                if (c.auth === 'bearer') bits.push(t('bearer token'));
                if (c.auth === 'header') bits.push(t('header {name}', { name: c.headerName || '' }));
                if (Array.isArray(c.tools) && c.tools.length) {
                    const enabled = c.tools.filter(tool => tool.enabled !== false).length;
                    bits.push(t('{n} of {total} tools', { n: enabled, total: c.tools.length }));
                }
                main.appendChild(el('span', 'repo-sub', bits.join(' · ')));
                if (!this.usable(c)) {
                    main.appendChild(el('span', 'repo-sub connector-missing', t('Its secret is on another device. Edit it to add it here.')));
                }
                row.appendChild(main);

                const actions = el('div', 'row-actions');
                const edit = el('button', 'row-btn', t('Edit'));
                edit.type = 'button';
                edit.addEventListener('click', () => this.edit(ui, c));
                actions.appendChild(edit);
                const del = el('button', 'row-btn danger', t('Remove'));
                del.type = 'button';
                del.addEventListener('click', async () => {
                    const ok = await ui.ask({
                        title: t('Remove this connector'),
                        body: t('Remove {name} and its secrets? With sync on, your other devices drop it too.', { name: c.name || c.url }),
                        confirm: t('Remove'),
                        danger: true
                    });
                    if (!ok) return;
                    this.remove(c.id);
                    ui.conv = Store.conversation(ui.conv.id);
                    this.render(ui);
                    ui.refreshToolbar();
                });
                actions.appendChild(del);
                row.appendChild(actions);
                list.appendChild(row);
            }
        },

        syncAuthFields() {
            const kind = $('connectorAuth').value;
            $('connectorTokenRow').hidden = kind !== 'bearer';
            $('connectorHeaderRow').hidden = kind !== 'header';
        },

        resetForm() {
            this.editing = null;
            this.tested = null;
            this.autoAll = false;
            this.autoTools = new Set();
            if (!$('connectorForm')) return;
            $('connectorName').value = '';
            $('connectorUrl').value = '';
            $('connectorAuth').value = 'none';
            $('connectorToken').value = '';
            $('connectorHeaderName').value = '';
            $('connectorHeaderValue').value = '';
            $('connectorFormTitle').textContent = t('Add a connector');
            $('connectorSaveBtn').textContent = t('Add connector');
            $('connectorResetBtn').hidden = true;
            this.syncAuthFields();
            this.renderTools(null);
            const status = $('connectorStatus');
            if (status) { status.textContent = ''; status.className = 'modal-status'; }
        },

        edit(ui, c) {
            this.editing = c.id;
            this.tested = Array.isArray(c.tools) ? c.tools.map(tool => Object.assign({}, tool)) : null;
            this.autoAll = c.autoAllow === true;
            this.autoTools = new Set(Array.isArray(c.autoAllow) ? c.autoAllow : []);
            $('connectorName').value = c.name || '';
            $('connectorUrl').value = c.url || '';
            $('connectorAuth').value = c.auth || 'none';
            $('connectorToken').value = c.token || '';
            $('connectorHeaderName').value = c.headerName || '';
            $('connectorHeaderValue').value = c.headerValue || '';
            $('connectorFormTitle').textContent = t('Edit connector');
            $('connectorSaveBtn').textContent = t('Save changes');
            $('connectorResetBtn').hidden = false;
            this.syncAuthFields();
            this.renderTools(this.tested);
            ui.modalStatus('connectorStatus', '');
        },

        readForm() {
            const auth = $('connectorAuth').value;
            return {
                name: $('connectorName').value.trim(),
                url: $('connectorUrl').value.trim(),
                auth,
                token: auth === 'bearer' ? $('connectorToken').value.trim() : '',
                headerName: auth === 'header' ? $('connectorHeaderName').value.trim() : '',
                headerValue: auth === 'header' ? $('connectorHeaderValue').value.trim() : ''
            };
        },

        formProblem(cfg) {
            if (!cfg.name) return t('Give the connector a name.');
            const bad = checkUrl(cfg.url);
            if (bad) return bad;
            if (cfg.auth === 'bearer' && !cfg.token) return t('Paste the token, or pick no authentication.');
            if (cfg.auth === 'header' && (!/^[A-Za-z0-9-]{1,64}$/.test(cfg.headerName) || !cfg.headerValue)) {
                return t('A header needs a name (letters, digits and dashes) and a value.');
            }
            return '';
        },

        renderTools(tools) {
            const box = $('connectorTools');
            if (!box) return;
            box.innerHTML = '';
            box.hidden = !tools;
            if (!tools) return;
            if (!tools.length) {
                box.appendChild(el('p', 'hint', t('This server offers no tools.')));
                return;
            }
            box.appendChild(el('p', 'hint', t('Untick a tool to keep it from Nymbot. Every tool asks you before it runs unless you let it run without asking. Tools the server marks as able to delete always ask.')));
            const all = el('label', 'check connector-auto-all');
            const allBox = document.createElement('input');
            allBox.type = 'checkbox';
            allBox.dataset.role = 'auto-all';
            allBox.checked = !!this.autoAll;
            allBox.addEventListener('change', () => {
                this.autoAll = allBox.checked;
                this.renderTools(this.tested);
            });
            all.appendChild(allBox);
            all.appendChild(el('span', null, t('Always allow all tools')));
            box.appendChild(all);
            for (const tool of tools) {
                const row = el('div', 'connector-tool');
                const pick = el('label', 'check connector-tool-pick');
                const box2 = document.createElement('input');
                box2.type = 'checkbox';
                box2.dataset.role = 'tool-on';
                box2.checked = tool.enabled !== false;
                box2.addEventListener('change', () => { tool.enabled = box2.checked; });
                pick.appendChild(box2);
                const text = el('span', 'connector-tool-text');
                text.appendChild(el('strong', 'connector-tool-name', tool.name));
                if (tool.destructive) text.appendChild(el('span', 'connector-tool-flag', t('always asks · the server says it can delete')));
                else if (tool.readOnly) text.appendChild(el('span', 'connector-tool-hint', t('the server says it only reads')));
                if (tool.description) text.appendChild(el('span', 'connector-tool-desc', tool.description));
                pick.appendChild(text);
                row.appendChild(pick);
                const auto = el('label', 'check connector-tool-auto');
                const autoBox = document.createElement('input');
                autoBox.type = 'checkbox';
                autoBox.dataset.role = 'auto-tool';
                autoBox.checked = !tool.destructive && (this.autoAll || this.autoTools.has(tool.name));
                autoBox.disabled = !!tool.destructive || !!this.autoAll;
                autoBox.addEventListener('change', () => {
                    if (autoBox.checked) this.autoTools.add(tool.name);
                    else this.autoTools.delete(tool.name);
                });
                auto.appendChild(autoBox);
                auto.appendChild(el('span', null, t('Always allow')));
                row.appendChild(auto);
                box.appendChild(row);
            }
        },

        async testForm(ui) {
            const cfg = this.readForm();
            const problem = this.formProblem(cfg);
            if (problem) { ui.modalStatus('connectorStatus', problem, 'warn'); return; }
            ui.modalStatus('connectorStatus', t('Connecting…'));
            const button = $('connectorTestBtn');
            if (button) button.disabled = true;
            try {
                const res = await this.probe(cfg);
                const before = new Map((this.tested || []).map(tool => [tool.name, tool.enabled]));
                this.tested = (res.tools || []).map(tool => ({
                    name: tool.name,
                    description: tool.description || '',
                    confirm: !!tool.confirm,
                    readOnly: !!tool.readOnly,
                    destructive: !!tool.destructive,
                    enabled: before.has(tool.name) ? before.get(tool.name) !== false : true
                }));
                this.renderTools(this.tested);
                const who = res.server && res.server.name ? res.server.name : cfg.name;
                ui.modalStatus('connectorStatus', t('Connected to {name}: {n} tools.', { name: who, n: this.tested.length }), 'ok');
            } catch (e) {
                ui.modalStatus('connectorStatus', (e && e.message) || t('The connector could not be reached.'), 'warn');
            } finally {
                if (button) button.disabled = false;
            }
        },

        saveForm(ui) {
            const cfg = this.readForm();
            const problem = this.formProblem(cfg);
            if (problem) { ui.modalStatus('connectorStatus', problem, 'warn'); return; }
            cfg.tools = this.tested ? this.tested.map(tool => Object.assign({}, tool)) : null;
            cfg.autoAllow = this.autoAll ? true : Array.from(this.autoTools || []);
            cfg.secretElsewhere = false;
            cfg.tokenElsewhere = false;
            if (this.editing) {
                this.update(this.editing, cfg);
            } else {
                const entry = this.add(cfg);
                if (ui.conv && !ui.conv.anon) {
                    const next = new Set(ui.conv.connectorIds || []);
                    if (next.size < MAX_PER_CHAT) {
                        next.add(entry.id);
                        ui.conv = Store.updateConversation(ui.conv.id, { connectorIds: Array.from(next) });
                    }
                }
            }
            this.resetForm();
            this.render(ui);
            ui.refreshToolbar();
            ui.modalStatus('connectorStatus', t('Saved. Connectors work with a Pro model pinned.'), 'ok');
        },

        pendingCard(ui, m) {
            const p = m.pendingTool;
            if (p && p.kind === 'server-run' && window.NymbotServerRun) return window.NymbotServerRun.pendingCard(ui, m);
            const card = el('div', 'pending-tool' + (p.state && p.state !== 'waiting' ? ' is-settled' : ''));
            card.dataset.id = m.id;
            card.appendChild(el('div', 'pending-tool-head', p.team
                ? t('The team lead wants to run a tool on {connector}', { connector: p.connector })
                : t('Nymbot wants to run a tool on {connector}', { connector: p.connector })));
            card.appendChild(el('code', 'pending-tool-name',
                t('{connector}: {tool}', { connector: p.connector, tool: p.tool })));
            const full = String(p.args || '{}');
            const total = Math.max(full.length, Number(p.argsLength) || 0);
            const shown = full.slice(0, ARGS_SHOWN);
            const args = el('pre', 'pending-tool-args', shown);
            card.appendChild(args);
            if (total > shown.length) {
                const more = el('div', 'pending-tool-more');
                const count = el('span', 'pending-tool-more-count');
                const hidden = (text) => {
                    const n = total - text.length;
                    count.textContent = n > 0
                        ? t('… {n} more characters not shown. The connector gets all {total}.', { n: num(n), total: num(total) })
                        : '';
                };
                hidden(shown);
                more.appendChild(count);
                if (full.length > shown.length) {
                    const toggle = el('button', 'btn btn-small btn-ghost', t('Show all'));
                    toggle.type = 'button';
                    toggle.dataset.role = 'show-args';
                    toggle.addEventListener('click', () => {
                        const open = !args.classList.contains('is-full');
                        args.classList.toggle('is-full', open);
                        args.textContent = open ? full : shown;
                        toggle.textContent = open ? t('Show less') : t('Show all');
                        hidden(open ? full : shown);
                    });
                    more.appendChild(toggle);
                }
                card.appendChild(more);
            }
            if (p.destructive) {
                card.appendChild(el('div', 'pending-tool-warn', t('The connector marks this tool as able to change or delete things.')));
            }
            if (p.state === 'allowed') {
                card.appendChild(el('div', 'pending-tool-note', t('Allowed once.')));
                return card;
            }
            if (p.state === 'denied') {
                card.appendChild(el('div', 'pending-tool-note', t('Denied. Nothing was run.')));
                return card;
            }
            const row = el('div', 'pending-tool-actions');
            const allow = el('button', 'btn btn-small btn-primary', t('Allow once'));
            allow.type = 'button';
            allow.dataset.role = 'allow';
            allow.addEventListener('click', () => this.allow(ui, m));
            const deny = el('button', 'btn btn-small btn-ghost', t('Deny'));
            deny.type = 'button';
            deny.dataset.role = 'deny';
            deny.addEventListener('click', () => this.deny(ui, m));
            row.appendChild(allow);
            if (!p.destructive && !p.team && this.connectorFor(p)) {
                const always = el('button', 'btn btn-small', t('Always allow this tool'));
                always.type = 'button';
                always.dataset.role = 'always';
                always.addEventListener('click', () => this.allowAlways(ui, m));
                row.appendChild(always);
            }
            row.appendChild(deny);
            card.appendChild(row);
            return card;
        },

        connectorFor(p) {
            if (!p) return null;
            if (p.connectorId) {
                const byId = this.get(p.connectorId);
                if (byId) return byId;
            }
            if (!p.connector) return null;
            const named = this.list().filter(c => (c.name || '') === p.connector);
            return named.length === 1 ? named[0] : null;
        },

        trust(c, tool) {
            if (!c || !tool || c.autoAllow === true) return c;
            const list = Array.isArray(c.autoAllow) ? c.autoAllow.slice() : [];
            if (!list.includes(tool)) list.push(tool);
            return this.update(c.id, { autoAllow: list });
        },

        allowAlways(ui, m) {
            const p = m.pendingTool;
            if (p && !p.destructive) this.trust(this.connectorFor(p), p.tool);
            return this.allow(ui, m);
        },

        settle(ui, convId, m, state) {
            const next = Object.assign({}, m.pendingTool, { state });
            Store.patchMessage(convId, m.id, { pendingTool: next });
            const fresh = Store.messages(convId).find(x => x.id === m.id);
            if (fresh && ui.conv && ui.conv.id === convId) ui.replaceMessage(fresh);
        },

        deny(ui, m) {
            if (!ui.conv) return;
            const p = m.pendingTool;
            if (p && p.team && p.token) return this.allow(ui, m, false);
            this.settle(ui, ui.conv.id, m, 'denied');
        },

        async allow(ui, m, approve = true) {
            const Chat = window.NymbotChat;
            if (!ui.conv) return;
            const conv = ui.conv;
            if (ui.sendingIn(conv.id)) return;
            const p = m.pendingTool;
            if (!p || !p.token) {
                this.settle(ui, conv.id, m, 'denied');
                ui.note(t('That request has expired. Ask again and Nymbot will start it fresh.'), conv.id);
                return;
            }
            const Caps = window.NymbotCaps;
            const capStop = ui.capStopsLeg(conv);
            if (capStop) {
                ui.note(capStop, conv.id);
                return;
            }
            this.settle(ui, conv.id, m, approve ? 'allowed' : 'denied');
            const turn = ui.beginTurn(conv, approve
                ? t('Running {tool} on {connector}', { tool: p.tool, connector: p.connector })
                : t('Carrying on without {tool}', { tool: p.tool }));
            if (p.team) {
                turn.team = {};
                ui.renderProgress(turn);
            }
            try {
                const opts = {
                    resume: p.token,
                    maxCost: Caps ? Caps.maxCost(conv, true, ui.models) : null,
                    controller: turn.controller,
                    onStatus: (text) => ui.turnStatus(turn, text),
                    onTurn: (eventId, signer) => ui.watchTurn(turn, eventId, signer)
                };
                if (approve) opts.mcpApprove = p.id;
                else opts.mcpDecline = p.id;
                const res = await Chat.send(conv, t('Continue.'), ui.settings, opts);
                ui.stopWatchingTurn(turn);
                const reply = this.replyFrom(conv, ui.settings, res);
                Store.addMessage(conv.id, reply);
                if (window.NymbotArtifacts) window.NymbotArtifacts.harvest(conv.id, reply);
                ui.showMessage(conv.id, reply);
                const spent = window.NymbotServerRun ? window.NymbotServerRun.totalCost(reply) : reply.cost;
                Store.recordUsage(spent, !!res.pro);
                ui.bumpStats(conv, spent);
                ui.creditBalance(res.pro, res.balanceCredits != null ? res.balanceCredits : res.balance);
                if (res.truncated) await ui.continueRun(turn, res);
            } catch (e) {
                ui.stopWatchingTurn(turn);
                if (e && e.capExceeded) {
                    this.settle(ui, conv.id, m, 'waiting');
                    ui.note(t('Stopped: carrying on could go past this chat\'s spending cap.'), conv.id);
                } else {
                    ui.note((e && e.message) || t('Could not carry on from there.'), conv.id);
                }
            } finally {
                ui.endTurn(turn);
            }
        },

        replyFrom(conv, settings, res) {
            return {
                id: Store.uid(),
                role: 'bot',
                content: res.reply,
                thinking: res.thinking || null,
                cost: res.cost || 0,
                pro: !!res.pro,
                model: res.modelLabel
                    || (res.pro ? ((conv.proModel || settings.proModel || {}).label || null) : null),
                ...(window.NymbotUI ? window.NymbotUI.modelStamp(res.modelLabel
                    || (res.pro ? ((conv.proModel || settings.proModel || {}).label || null) : null),
                [{ key: res.modelKey }, conv.mediaModel, conv.proModel, settings.proModel]) : {}),
                sources: res.sources || null,
                team: window.NymbotTeam ? window.NymbotTeam.carry(res) : null,
                followUps: res.followUps || null,
                serverRuns: res.serverRuns || null,
                serverRunCredits: res.serverRunCredits || 0,
                calls: res.modelCalls || 1,
                task: res.taskType || null,
                checkpoint: res.checkpoint || null,
                pendingTool: this.pendingFrom(res),
                ts: Date.now()
            };
        },

        pendingFrom(res) {
            const p = res && res.pendingTool;
            if (!p || typeof p !== 'object' || !res.resumeToken) return null;
            if (p.kind === 'server-run') {
                return window.NymbotServerRun ? window.NymbotServerRun.pendingFrom(p, res.resumeToken) : null;
            }
            return {
                id: String(p.id || ''),
                tool: String(p.tool || ''),
                connector: String(p.connector || ''),
                connectorId: String(p.connectorId || ''),
                args: String(p.args || '{}').slice(0, ARGS_KEPT),
                argsLength: Math.max(0, Math.floor(Number(p.argsLength) || 0)) || String(p.args || '{}').length,
                destructive: !!p.destructive,
                team: !!p.team,
                token: res.resumeToken,
                state: 'waiting'
            };
        }
    };

    window.NymbotConnectors = Connectors;
})();
