(function () {
    'use strict';

    const LANGS = {
        python: 'python', py: 'python', python3: 'python', py3: 'python',
        javascript: 'javascript', js: 'javascript', mjs: 'javascript', node: 'javascript', nodejs: 'javascript',
        typescript: 'typescript', ts: 'typescript',
        bash: 'bash', shell: 'bash', sh: 'sh',
        go: 'go', golang: 'go',
        rust: 'rust', rs: 'rust',
        java: 'java',
        dart: 'dart'
    };
    const IMAGE_FOR = {
        python: 'python', javascript: 'node', typescript: 'node',
        bash: 'polyglot', sh: 'polyglot', go: 'polyglot', rust: 'polyglot', java: 'polyglot',
        dart: 'flutter'
    };
    const TIMES = [60, 300, 900];
    const SUMMARY_COMMAND = 80;
    const COMMAND_KEPT = 8000;
    const FILES_MAX = 200;

    let info = null;
    let loading = null;
    let sheet = null;

    const $ = (id) => document.getElementById(id);
    const credits = (v) => window.amount(v, 3);

    function el(tag, cls, text) {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    }

    function ui() {
        return window.NymbotUI || null;
    }

    function available() {
        return !!(info && info.available === true && Array.isArray(info.images) && info.images.length);
    }

    function imageNamed(name) {
        if (!available()) return null;
        return info.images.find(i => i && i.name === name) || null;
    }

    function languageOf(block) {
        const pre = block && block.querySelector('pre.code');
        const lang = pre ? String(pre.dataset.lang || '').toLowerCase() : '';
        return LANGS[lang] || null;
    }

    function imageFor(language) {
        return language ? imageNamed(IMAGE_FOR[language]) : null;
    }

    function load(force) {
        if (loading) return loading;
        if (info && !force) return Promise.resolve(info);
        const Api = window.NymbotApi;
        if (!Api || typeof Api.runnerInfo !== 'function') return Promise.resolve(info);
        loading = Api.runnerInfo().then((data) => {
            loading = null;
            if (data && typeof data === 'object') {
                info = data.available === true && Array.isArray(data.images) ? data : { available: false };
            } else if (!info) {
                info = { available: false };
            }
            refresh();
            return info;
        }, () => {
            loading = null;
            if (!info) info = { available: false };
            refresh();
            return info;
        });
        return loading;
    }

    function refresh() {
        if (!available()) {
            for (const b of document.querySelectorAll('.code-server-run')) b.remove();
        } else {
            for (const text of document.querySelectorAll('.chat-message[data-role="bot"] .msg-text')) decorate(text);
        }
        const U = ui();
        if (U && U.conv) refreshChip(U);
    }

    function decorate(root) {
        if (!root || !root.querySelectorAll || !available()) return;
        for (const block of root.querySelectorAll('.code-block')) {
            const language = languageOf(block);
            if (!imageFor(language)) continue;
            const actions = block.querySelector('.code-actions');
            if (!actions || actions.querySelector('.code-server-run')) continue;
            const b = el('button', 'code-btn code-server-run', t('Run on server'));
            b.type = 'button';
            b.title = t('Run this on a Nymbot server, paid in Pro credits');
            b.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                const U = ui();
                if (U) open(U, block);
            });
            const local = actions.querySelector('.code-run');
            actions.insertBefore(b, local ? local.nextSibling : actions.firstChild);
        }
    }

    function timesFor(image) {
        const max = Math.max(5, Math.floor(Number(image && image.maxTimeoutSec) || 900));
        const out = [];
        for (const s of TIMES) {
            const v = Math.min(s, max);
            if (!out.includes(v)) out.push(v);
        }
        return out;
    }

    function timeLabel(sec) {
        const s = Math.max(0, Math.round(Number(sec) || 0));
        return s % 60 === 0
            ? t('{n} min', { n: s / 60 })
            : t('{n} s', { n: s });
    }

    function priceFor(image, timeoutSec) {
        const perMinute = Number(image && image.creditsPerMinute) || 0;
        const minutes = Math.ceil(Math.max(1, Number(timeoutSec) || 0) / 10) * 10 / 60;
        const milli = Math.ceil(perMinute * 1000 * minutes + 0.5 * minutes - 1e-9);
        return Math.max(1, milli) / 1000;
    }

    function priceOf(state, timeoutSec) {
        const base = priceFor(state.image, timeoutSec);
        const held = Number(state.overrides[timeoutSec]) || 0;
        return Math.max(base, Math.ceil(held * 1000 - 1e-9) / 1000);
    }

    function b64(text) {
        const bytes = new TextEncoder().encode(String(text || ''));
        let out = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
            out += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return btoa(out);
    }

    function base64Bytes(data) {
        const binary = atob(data);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes;
    }

    function inputName(raw) {
        let name = String(raw || '')
            .replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩﻿]/g, '')
            .split(/[\\/]/).pop()
            .replace(/[:*?"<>|]/g, '_')
            .replace(/^[.\s]+/, '')
            .replace(/\s+$/, '')
            .slice(0, 120);
        if (!name) name = 'file.txt';
        if (/^main\.[a-z]+$/i.test(name)) name = 'file-' + name;
        return name;
    }

    async function chatFiles(convId) {
        const Docs = window.NymbotDocs;
        if (!Docs || !convId) return [];
        try {
            await Docs.load(convId);
            return Docs.files(convId) || [];
        } catch (_) { return []; }
    }

    async function inputFiles(convId) {
        const seen = new Set();
        const out = [];
        for (const f of (await chatFiles(convId)).slice(0, FILES_MAX)) {
            let name = inputName(f.name);
            let n = 1;
            while (seen.has(name)) name = (n++) + '-' + inputName(f.name);
            seen.add(name);
            out.push({ path: name, data: b64(f.text) });
        }
        return out;
    }

    async function open(U, block, keep) {
        const conv = U.conv;
        if (!conv || !block || !block.isConnected) return;
        const language = languageOf(block);
        if (!language) return;
        const source = block.querySelector('.code-source');
        const prior = keep || (sheet && sheet.block === block ? sheet : null);
        const state = {
            ui: U,
            block,
            convId: conv.id,
            anon: !!conv.anon,
            language,
            code: source ? source.value : '',
            overrides: prior ? prior.overrides : {},
            timeoutSec: prior ? prior.timeoutSec : null,
            withFiles: prior ? !!prior.withFiles : false,
            image: null
        };
        sheet = state;
        await load(true);
        if (sheet !== state) return;
        const image = imageFor(language);
        if (!image) {
            U.toast(t('Server runs are not available right now.'));
            return;
        }
        state.image = image;
        const files = state.anon ? [] : await chatFiles(conv.id);
        if (sheet !== state) return;
        $('serverRunImage').textContent = t('Image: {label}', { label: image.label || image.name });
        const select = $('serverRunTime');
        select.innerHTML = '';
        const times = timesFor(image);
        const chosen = times.includes(state.timeoutSec) ? state.timeoutSec : times[0];
        for (const s of times) {
            const o = el('option', null, timeLabel(s));
            o.value = String(s);
            if (s === chosen) o.selected = true;
            select.appendChild(o);
        }
        select.value = String(chosen);
        $('serverRunFilesRow').hidden = state.anon || !files.length;
        $('serverRunFiles').checked = !state.anon && !!files.length && state.withFiles;
        showPrice();
        U.modalStatus('serverRunStatus', keep && keep.changed
            ? t('The price went up since this was shown. Check it and run again.')
            : '', keep && keep.changed ? 'warn' : undefined);
        U.openModal('modalServerRun');
    }

    function showPrice() {
        if (!sheet || !sheet.image) return;
        const timeoutSec = Number($('serverRunTime').value) || timesFor(sheet.image)[0];
        const price = priceOf(sheet, timeoutSec);
        $('serverRunPrice').textContent = t('Up to {credits} Pro credits', { credits: credits(price) });
        $('serverRunPrice').dataset.credits = String(price);
    }

    async function go() {
        const state = sheet;
        if (!state || !state.image) return;
        const U = state.ui;
        const timeoutSec = Number($('serverRunTime').value) || timesFor(state.image)[0];
        const maxCost = priceOf(state, timeoutSec);
        const withFiles = !$('serverRunFilesRow').hidden && $('serverRunFiles').checked;
        state.timeoutSec = timeoutSec;
        state.withFiles = withFiles;
        U.closeModals();
        const Store = window.NymbotStore;
        const conv = Store.conversation(state.convId) || (U.conv && U.conv.id === state.convId ? U.conv : null);
        if (!conv) return;
        const Caps = window.NymbotCaps;
        if (Caps && Caps.any(conv)) {
            const gate = await Caps.gate(U, conv, { tier: 'pro', low: maxCost, high: maxCost });
            if (!gate.go) return;
        }
        await execute(state, conv, timeoutSec, maxCost, withFiles);
    }

    function outputBox(block) {
        let box = block.nextElementSibling;
        if (!box || !box.classList.contains('run-output')) {
            box = el('div', 'run-output');
            block.after(box);
        }
        box.innerHTML = '';
        box.classList.remove('is-error');
        box.classList.add('server-run-output');
        return box;
    }

    function signerFor(conv) {
        const Anon = window.NymbotAnon;
        return conv.anon && Anon && Anon.ready() ? Anon.signer() : null;
    }

    function spend(U, convId, amount) {
        const Store = window.NymbotStore;
        const Caps = window.NymbotCaps;
        const conv = Store.conversation(convId);
        if (!conv || !(amount > 0)) return;
        const stats = Object.assign({ messages: 0, credits: 0 }, conv.stats || {});
        if (Caps) stats[Caps.SPENT] = Caps.nextSpent(conv, amount, true, U.models);
        stats.credits = Math.round(((stats.credits || 0) + amount) * 1000) / 1000;
        U.patchChat(conv, { stats });
        if (Caps) Caps.renderBadge(U);
        Store.recordUsage(amount, true);
    }

    function outOfPro(U, conv, data) {
        U.creditBalance(true, data.balanceCredits != null ? data.balanceCredits : data.balance);
        if (!(U.conv && U.conv.id === conv.id)) return;
        if (conv.anon) {
            U.openAnon();
            return;
        }
        U.openCredits();
        if (U.invoice) return;
        U.creditTier = 'pro';
        for (const b of document.querySelectorAll('#creditTier .tier-btn')) {
            b.classList.toggle('is-active', b.dataset.tier === 'pro');
        }
        if (typeof U.creditSats === 'function') U.creditSats();
        if (typeof U.renderCreditBalances === 'function') U.renderCreditBalances();
    }

    function saveButton(f) {
        const name = window.NymbotRunner ? window.NymbotRunner.safeName(f.path) : inputName(f.path);
        if (typeof f.data !== 'string' || !/^[A-Za-z0-9+/=]*$/.test(f.data)) {
            return el('span', 'run-note', t('{name} is too large to hand back.', { name }));
        }
        const b = el('button', 'code-btn run-file', t('Save {name}', { name }));
        b.type = 'button';
        b.addEventListener('click', () => {
            const blob = new Blob([base64Bytes(f.data)], { type: 'application/octet-stream' });
            const Ex = window.NymbotExport;
            if (Ex && typeof Ex.saveBlob === 'function') Ex.saveBlob(name, blob);
        });
        return b;
    }

    async function execute(state, conv, timeoutSec, maxCost, withFiles) {
        const U = state.ui;
        const block = state.block;
        if (!block.isConnected || block.dataset.serverRunning === '1') return;
        block.dataset.serverRunning = '1';
        const button = block.querySelector('.code-server-run');
        if (button) {
            button.disabled = true;
            button.textContent = t('Running…');
        }
        const box = outputBox(block);
        const head = el('div', 'run-head');
        const title = el('span', 'run-title', t('Starting a Nymbot server…'));
        head.appendChild(title);
        const actions = el('span', 'run-actions');
        const stop = el('button', 'code-btn server-run-stop', t('Stop'));
        stop.type = 'button';
        stop.title = t('Stop the run. The server is shut down straight away, and you pay only for the time it ran.');
        actions.appendChild(stop);
        head.appendChild(actions);
        box.appendChild(head);
        const log = el('div', 'server-run-log');
        box.appendChild(log);
        const tail = el('div', 'server-run-tail');
        box.appendChild(tail);

        const controller = new AbortController();
        stop.addEventListener('click', () => controller.abort());

        const finish = () => {
            block.dataset.serverRunning = '';
            if (button) {
                button.disabled = false;
                button.textContent = t('Run on server');
            }
            stop.remove();
            const clear = el('button', 'code-btn run-close', t('Clear'));
            clear.type = 'button';
            clear.addEventListener('click', () => box.remove());
            actions.appendChild(clear);
        };
        const line = (cls, text) => {
            const n = el(cls === 'run-error' ? 'pre' : 'div', cls, text);
            tail.appendChild(n);
            return n;
        };

        const body = { code: state.code, language: state.language, timeoutSec, maxCost };
        if (withFiles) {
            const files = await inputFiles(conv.id);
            if (files.length) body.files = files;
        }
        const Api = window.NymbotApi;
        const res = await Api.stream('runner-run', body, { signer: signerFor(conv), signal: controller.signal });

        if (!res.response) {
            const data = res.data || {};
            finish();
            box.classList.add('is-error');
            if (res.aborted) {
                title.textContent = t('Stopped');
                line('run-note', t('Stopped before the server started. Nothing was charged.'));
                return;
            }
            if (res.status === 402 && data.error === 'price-changed') {
                box.remove();
                const next = Number(data.maxCredits) || 0;
                if (next > 0) state.overrides[timeoutSec] = next;
                state.changed = true;
                await open(U, block, state);
                return;
            }
            title.textContent = t('The server run did not start');
            if (res.status === 402 && data.noCredits) {
                line('run-error', data.error || t('You are out of Pro credits.'));
                outOfPro(U, conv, data);
                return;
            }
            if (res.status === 409) {
                line('run-error', t('A server run is already going. Wait for it to finish.'));
                return;
            }
            if (res.status === 429) {
                line('run-error', data.error || t('Too many server runs just now. Try again in a minute.'));
                return;
            }
            if (res.status === 503) {
                line('run-error', data.error || t('Server runs are not available right now.'));
                if (data.available === false) {
                    info = { available: false };
                    refresh();
                }
                return;
            }
            line('run-error', data.error || t('The request failed.'));
            return;
        }

        title.textContent = t('Running on a Nymbot server…');
        let charged = null;
        let ended = null;
        let aborted = false;
        const put = (stream, data) => {
            const last = log.lastElementChild;
            if (last && last.dataset.stream === stream) {
                last.textContent += data;
            } else {
                const pre = el('pre', stream === 'stderr' ? 'run-stderr' : 'run-stdout', data);
                pre.dataset.stream = stream;
                log.appendChild(pre);
            }
        };
        const handle = (ev) => {
            if (!ev || typeof ev !== 'object') return;
            switch (ev.type) {
                case 'start':
                    title.textContent = t('Running on a Nymbot server…');
                    break;
                case 'out':
                    put(ev.stream === 'stderr' ? 'stderr' : 'stdout', String(ev.data || ''));
                    break;
                case 'note':
                    log.appendChild(el('div', 'run-note', String(ev.text || '')));
                    break;
                case 'exit': {
                    ended = ev;
                    const code = ev.code == null ? '?' : String(ev.code);
                    title.textContent = t('Ran on a Nymbot server');
                    box.classList.toggle('is-error', ev.code !== 0);
                    line('run-note server-run-exit', t('Exit code {code} · {ms} ms', {
                        code, ms: window.NymbotI18n.count(ev.runMs)
                    }));
                    if (ev.timedOut) line('run-note', t('Stopped at the time limit.'));
                    else if (ev.signal) line('run-note', t('Ended by signal {signal}.', { signal: String(ev.signal) }));
                    const files = Array.isArray(ev.files) ? ev.files : [];
                    if (files.length) {
                        const list = el('div', 'run-files');
                        for (const f of files) list.appendChild(saveButton(f || {}));
                        tail.appendChild(list);
                    }
                    if (ev.filesTruncated) line('run-note', t('Some files were left out: there were too many, or they were too large.'));
                    if (!log.childElementCount && !files.length) line('run-note', t('It ran, and printed nothing.'));
                    line('run-note server-run-where', t('Ran on a Nymbot server'));
                    break;
                }
                case 'error':
                    ended = ev;
                    title.textContent = t('The server run failed');
                    box.classList.add('is-error');
                    line('run-error', String(ev.message || t('The server run failed')));
                    break;
                case 'charged': {
                    charged = ev;
                    const amount = Number(ev.credits) || 0;
                    line('run-note server-run-charged', t('Charged {credits} Pro credits', { credits: credits(amount) }));
                    const balance = ev.balanceCredits != null ? ev.balanceCredits : ev.balance;
                    if (balance != null) U.creditBalance(true, balance);
                    spend(U, conv.id, amount);
                    break;
                }
                default:
                    break;
            }
        };
        try {
            const reader = res.response.body.getReader();
            const decoder = new TextDecoder();
            let buffered = '';
            for (;;) {
                const { value, done } = await reader.read();
                if (done) break;
                buffered += decoder.decode(value, { stream: true });
                let at;
                while ((at = buffered.indexOf('\n')) >= 0) {
                    const raw = buffered.slice(0, at).trim();
                    buffered = buffered.slice(at + 1);
                    if (!raw) continue;
                    let ev = null;
                    try { ev = JSON.parse(raw); } catch (_) { ev = null; }
                    handle(ev);
                }
            }
            buffered += decoder.decode();
            if (buffered.trim()) {
                try { handle(JSON.parse(buffered.trim())); } catch (_) { }
            }
        } catch (e) {
            aborted = !!(e && e.name === 'AbortError') || controller.signal.aborted;
        }
        if (controller.signal.aborted) aborted = true;
        finish();
        if (!charged) {
            box.classList.add('is-error');
            if (aborted) {
                title.textContent = t('Stopped');
                line('run-note server-run-stopped', t('Stopped. The server was shut down, and only the time it ran is charged.'));
            } else {
                line('run-error server-run-cut', ended
                    ? t('The connection dropped before the charge was confirmed. Your balance will show it.')
                    : t('The connection dropped before the run finished. What arrived is shown above.'));
            }
            if (typeof U.refreshBalance === 'function') U.refreshBalance().catch(() => { });
        }
    }

    function refreshChip(U) {
        const chip = $('chipServerRuns');
        if (!chip) return;
        const Chat = window.NymbotChat;
        const conv = U.conv || {};
        const repos = Chat ? Chat.reposFor(conv) : [];
        chip.hidden = !available() || !repos.length;
        chip.classList.toggle('is-active', !chip.hidden && !!conv.serverRuns);
        chip.querySelector('.chip-label').textContent = t('Server runs');
    }

    function toggle(U) {
        if (!U.conv) return;
        const on = !U.conv.serverRuns;
        U.conv = U.patchChat(U.conv, { serverRuns: on }) || U.conv;
        U.refreshToolbar();
        U.toast(on
            ? t('Nymbot may ask to run commands on a Nymbot server in this chat. Each run waits for you to allow it.')
            : t('Server runs are off for this chat.'));
    }

    function pendingFrom(p, token) {
        return {
            kind: 'server-run',
            id: String(p.id || ''),
            image: String(p.image || ''),
            command: String(p.command || '').slice(0, COMMAND_KEPT),
            timeoutSec: Math.max(0, Math.floor(Number(p.timeoutSec) || 0)),
            maxCredits: Math.max(0, Number(p.maxCredits) || 0),
            repo: p.repo ? String(p.repo).slice(0, 200) : '',
            team: !!p.team,
            token,
            state: 'waiting'
        };
    }

    function pendingCard(U, m) {
        const p = m.pendingTool;
        const card = el('div', 'pending-tool server-run-card' + (p.state && p.state !== 'waiting' ? ' is-settled' : ''));
        card.dataset.id = m.id;
        card.appendChild(el('div', 'pending-tool-head', p.team
            ? t('The team lead wants to run a command on a Nymbot server')
            : t('Nymbot wants to run a command on a Nymbot server')));
        const image = imageNamed(p.image);
        card.appendChild(el('div', 'server-run-meta', t('Image: {label}', { label: image && image.label ? image.label : p.image })));
        if (p.repo) card.appendChild(el('div', 'server-run-meta', t('Repository: {repo}', { repo: p.repo })));
        card.appendChild(el('pre', 'pending-tool-args server-run-command', p.command));
        card.appendChild(el('div', 'server-run-meta', t('Time limit: {time}', { time: timeLabel(p.timeoutSec) })));
        card.appendChild(el('div', 'server-run-price', t('Up to {credits} Pro credits', { credits: credits(p.maxCredits) })));
        if (p.state === 'allowed') {
            card.appendChild(el('div', 'pending-tool-note', t('Allowed once.')));
            return card;
        }
        if (p.state === 'denied') {
            card.appendChild(el('div', 'pending-tool-note', t('Declined. Nothing was run.')));
            return card;
        }
        const row = el('div', 'pending-tool-actions');
        const allow = el('button', 'btn btn-small btn-primary', t('Allow once'));
        allow.type = 'button';
        allow.dataset.role = 'allow';
        allow.addEventListener('click', () => resume(U, m, true));
        const deny = el('button', 'btn btn-small btn-ghost', t('Decline'));
        deny.type = 'button';
        deny.dataset.role = 'decline';
        deny.addEventListener('click', () => resume(U, m, false));
        row.appendChild(allow);
        row.appendChild(deny);
        card.appendChild(row);
        return card;
    }

    async function resume(U, m, approve) {
        const Chat = window.NymbotChat;
        const Store = window.NymbotStore;
        const Caps = window.NymbotCaps;
        const K = window.NymbotConnectors;
        if (!U.conv) return;
        const conv = U.conv;
        if (U.sendingIn(conv.id)) return;
        const p = m.pendingTool;
        if (!p || !p.token) {
            K.settle(U, conv.id, m, 'denied');
            U.note(t('That request has expired. Ask again and Nymbot will start it fresh.'), conv.id);
            return;
        }
        const capStop = U.capStopsLeg(conv);
        if (capStop) {
            U.note(capStop, conv.id);
            return;
        }
        const leg = Caps ? Caps.maxCost(conv, true, U.models) : null;
        const maxCost = approve && leg != null
            ? Math.ceil((leg + (Number(p.maxCredits) || 0)) * 1000) / 1000
            : leg;
        K.settle(U, conv.id, m, approve ? 'allowed' : 'denied');
        const turn = U.beginTurn(conv, approve
            ? t('Running the command on a Nymbot server')
            : t('Carrying on without the server run'));
        if (p.team) {
            turn.team = {};
            U.renderProgress(turn);
        }
        try {
            const opts = {
                resume: p.token,
                serverRuns: true,
                maxCost,
                controller: turn.controller,
                onStatus: (text) => U.turnStatus(turn, text),
                onTurn: (eventId, signer) => U.watchTurn(turn, eventId, signer)
            };
            if (approve) opts.runApprove = p.id;
            else opts.runDecline = p.id;
            const res = await Chat.send(conv, t('Continue.'), U.settings, opts);
            U.stopWatchingTurn(turn);
            const reply = K.replyFrom(conv, U.settings, res);
            Store.addMessage(conv.id, reply);
            if (window.NymbotArtifacts) window.NymbotArtifacts.harvest(conv.id, reply);
            U.showMessage(conv.id, reply);
            const total = totalCost(reply);
            Store.recordUsage(total, true);
            U.bumpStats(conv, total, true);
            U.creditBalance(res.pro, res.balanceCredits != null ? res.balanceCredits : res.balance);
            if (res.truncated) await U.continueRun(turn, res);
        } catch (e) {
            U.stopWatchingTurn(turn);
            if (e && e.capExceeded) {
                K.settle(U, conv.id, m, 'waiting');
                U.note(t('Stopped: carrying on could go past this chat\'s spending cap.'), conv.id);
            } else if (e && e.noCredits) {
                K.settle(U, conv.id, m, 'waiting');
                U.note(e.message, conv.id);
                outOfPro(U, conv, { balance: e.balance, balanceCredits: e.balanceCredits });
            } else {
                U.note((e && e.message) || t('Could not carry on from there.'), conv.id);
            }
        } finally {
            U.endTurn(turn);
        }
    }

    function totalCost(m) {
        const extra = Number(m && m.serverRunCredits) || 0;
        const base = Number(m && m.cost) || 0;
        return extra > 0 ? Math.round((base + extra) * 1000) / 1000 : base;
    }

    function shorten(text, max) {
        const s = String(text || '').replace(/\s+/g, ' ').trim();
        return s.length > max ? s.slice(0, max - 1) + '…' : s;
    }

    function summaryNode(m) {
        const runs = Array.isArray(m && m.serverRuns) ? m.serverRuns : [];
        if (!runs.length) return null;
        const box = el('div', 'server-run-summary');
        for (const r of runs.slice(0, 20)) {
            const row = el('div', 'server-run-summary-row');
            row.appendChild(el('span', 'server-run-summary-image', String(r.image || '')));
            row.appendChild(el('code', 'server-run-summary-command', shorten(r.command, SUMMARY_COMMAND)));
            row.appendChild(el('span', 'server-run-summary-exit', r.code == null
                ? t('did not finish')
                : t('exit {code}', { code: String(r.code) })));
            row.appendChild(el('span', 'server-run-summary-credits', t('{credits} Pro credits', {
                credits: credits((Number(r.milli) || 0) / 1000)
            })));
            box.appendChild(row);
        }
        return box;
    }

    function carry(res) {
        return {
            serverRuns: res && Array.isArray(res.serverRuns) && res.serverRuns.length ? res.serverRuns : null,
            serverRunCredits: res && Number(res.serverRunCredits) > 0 ? Number(res.serverRunCredits) : 0
        };
    }

    function handlers(U) {
        return {
            'server-run-go': () => go(),
            'toggle-server-runs': () => toggle(U)
        };
    }

    function bind() {
        const select = $('serverRunTime');
        if (select) select.addEventListener('change', showPrice);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', bind);
    } else {
        bind();
    }

    window.NymbotServerRun = {
        LANGS, IMAGE_FOR,
        load, available, decorate, refresh, open, go,
        priceFor, timesFor, refreshChip, handlers,
        pendingFrom, pendingCard, resume, summaryNode, totalCost, carry,
        get info() { return info; },
        set info(v) { info = v; }
    };
})();
