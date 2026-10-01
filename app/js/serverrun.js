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
    const STAGED_KEPT = 40;
    const STAGED_SHOWN = 8;

    let info = null;
    let site = null;
    let loading = null;
    let sheet = null;
    let siteSheet = null;

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

    const SHELL_WORD = '(?:^|[\\s;&|(`!])';
    const SHELL_POLYGLOT = new RegExp(SHELL_WORD + '(?:go|cargo|rustc|rustup|javac|java|mvn|gradle)(?=[\\s;&|)`]|$)', 'm');
    const SHELL_PYTHON = new RegExp(SHELL_WORD + '(?:pip3?|python3?|pytest|poetry|uv|pipx)(?=[\\s;&|)`]|$)', 'm');
    const SHELL_NODE = new RegExp(SHELL_WORD + '(?:npm|npx|node|yarn|pnpm|tsx|corepack)(?=[\\s;&|)`]|$)', 'm');

    function shellImage(code) {
        const text = String(code || '').replace(/^\s*#.*$/gm, '');
        if (SHELL_POLYGLOT.test(text)) return 'polyglot';
        const py = SHELL_PYTHON.test(text);
        const js = SHELL_NODE.test(text);
        if (py && !js) return 'python';
        if (js && !py) return 'node';
        return 'polyglot';
    }

    const BROWSER_IMPORT = /(?:\bfrom\s*|\bimport\s*\(\s*|\brequire\s*\(\s*|\bimport\s+)["'](?:playwright(?:-core|-chromium)?|@playwright\/test|puppeteer(?:-core)?|selenium-webdriver|cypress)(?:\/[^"'\n]*)?["']/;
    const BROWSER_COMMAND = /(?:^|[\s;&|(`!/])(?:playwright|puppeteer|cypress)(?=[\s;&|)`.\-]|$)/m;

    function needsBrowser(language, code) {
        const lang = LANGS[String(language || '').toLowerCase()] || null;
        if (lang === 'javascript' || lang === 'typescript') return BROWSER_IMPORT.test(String(code || ''));
        if (lang === 'bash' || lang === 'sh') return BROWSER_COMMAND.test(String(code || '').replace(/^\s*#.*$/gm, ''));
        return false;
    }

    function imageFor(language, code) {
        if (!language) return null;
        if (code != null && needsBrowser(language, code) && imageNamed('browser')) return imageNamed('browser');
        const name = (language === 'bash' || language === 'sh') && code != null ? shellImage(code) : IMAGE_FOR[language];
        return imageNamed(name);
    }

    function surchargeOf(image) {
        const n = Number(image && image.surcharge);
        return Number.isFinite(n) && n > 1 ? n : 0;
    }

    function surchargeNodes(perMinute) {
        return [
            el('div', 'server-run-meta server-run-surcharge', t('Includes a browser surcharge')),
            el('div', 'server-run-meta server-run-per-minute', t('{credits} Pro credits a minute', { credits: credits(perMinute) }))
        ];
    }

    function load(force) {
        if (loading) return loading;
        if (info && !force) return Promise.resolve(info);
        const Api = window.NymbotApi;
        if (!Api || typeof Api.runnerInfo !== 'function') return Promise.resolve(info);
        loading = Api.runnerInfo().then((data) => {
            loading = null;
            if (data && typeof data === 'object') {
                site = data.siteCheck && data.siteCheck.available === true ? data.siteCheck : null;
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
            const R = window.NymbotRunner;
            const source = block.querySelector('.code-source');
            if (local && R && typeof R.localOk === 'function' && !R.localOk(localLanguage(block), source ? source.value : '')) {
                local.remove();
                actions.insertBefore(b, actions.firstChild);
            } else {
                actions.insertBefore(b, local ? local.nextSibling : actions.firstChild);
            }
        }
    }

    function localLanguage(block) {
        const language = languageOf(block);
        return language === 'typescript' ? null : language;
    }

    function canRun(block) {
        const language = languageOf(block);
        if (!language) return false;
        const source = block.querySelector('.code-source');
        return !!imageFor(language, source ? source.value : null);
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

    function billedSec(image, timeoutSec) {
        const setup = Math.max(0, Math.ceil(Number(image && image.setupSec) || 0));
        return Math.max(10, Math.ceil((Math.max(1, Number(timeoutSec) || 0) + setup) / 10) * 10);
    }

    function priceFor(image, timeoutSec) {
        const perMinute = Number(image && image.creditsPerMinute) || 0;
        const minutes = billedSec(image, timeoutSec) / 60;
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
        const image = imageFor(language, state.code);
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
        const extra = $('serverRunSurcharge');
        if (extra) {
            extra.innerHTML = '';
            const on = surchargeOf(sheet.image) > 0;
            extra.hidden = !on;
            if (on) for (const n of surchargeNodes(Number(sheet.image.creditsPerMinute) || 0)) extra.appendChild(n);
        }
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
        return conv.anon && Anon ? Anon.signer(Anon.forConv(conv)) : null;
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

    function artifactsNode(list, truncated) {
        const box = el('div', 'server-run-artifacts');
        for (const a of Array.isArray(list) ? list : []) {
            if (!a || typeof a !== 'object') continue;
            const name = window.NymbotRunner ? window.NymbotRunner.safeName(String(a.name || 'file')) : inputName(a.name);
            const type = String(a.type || '');
            const url = typeof a.url === 'string' && /^https:\/\//.test(a.url) ? a.url : '';
            const data = typeof a.data === 'string' && /^[A-Za-z0-9+/=]*$/.test(a.data) ? a.data : '';
            if (!url && !data) continue;
            if (/^image\/(png|jpeg|webp|gif)$/.test(type)) {
                const fig = el('figure', 'server-run-shot');
                const img = el('img', 'run-image');
                img.alt = name;
                img.loading = 'lazy';
                img.referrerPolicy = 'no-referrer';
                img.src = url || 'data:' + type + ';base64,' + data;
                fig.appendChild(img);
                fig.appendChild(el('figcaption', 'run-note', name));
                box.appendChild(fig);
            } else if (url) {
                const link = el('a', 'code-btn run-file server-run-artifact', t('Save {name}', { name }));
                link.href = url;
                link.target = '_blank';
                link.rel = 'noopener noreferrer';
                link.setAttribute('download', name);
                box.appendChild(link);
            } else {
                box.appendChild(saveButton({ path: name, data }));
            }
        }
        if (truncated) box.appendChild(el('div', 'run-note', t('Some screenshots or reports were left out: there were too many, or they were too large.')));
        return box.childElementCount ? box : null;
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
                    if (ev.timedOut) {
                        line('run-note', t('Stopped at the time limit.'));
                        const longer = state.image ? timesFor(state.image).find(s => s > timeoutSec) : null;
                        if (longer && block.isConnected) {
                            const again = el('button', 'code-btn server-run-again', t('Run again with more time'));
                            again.type = 'button';
                            again.addEventListener('click', () => {
                                open(U, block, Object.assign({}, state, { timeoutSec: longer, changed: false }));
                            });
                            tail.appendChild(again);
                        }
                    } else if (ev.signal) line('run-note', t('Ended by signal {signal}.', { signal: String(ev.signal) }));
                    const files = Array.isArray(ev.files) ? ev.files : [];
                    if (files.length) {
                        const list = el('div', 'run-files');
                        for (const f of files) list.appendChild(saveButton(f || {}));
                        tail.appendChild(list);
                    }
                    if (ev.filesTruncated) line('run-note', t('Some files were left out: there were too many, or they were too large.'));
                    const shots = artifactsNode(ev.artifacts, ev.artifactsTruncated);
                    if (shots) tail.appendChild(shots);
                    if (!log.childElementCount && !files.length && !shots) line('run-note', t('It ran, and printed nothing.'));
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
        const siteChip = $('chipSiteCheck');
        if (siteChip) {
            siteChip.hidden = !site;
            siteChip.querySelector('.chip-label').textContent = t('Check a site');
        }
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

    function stagedFrom(p) {
        const list = Array.isArray(p.stagedFiles) ? p.stagedFiles : [];
        const files = [];
        for (const f of list) {
            const path = typeof f === 'string' ? f : String((f && f.path) || '');
            if (!path) continue;
            if (files.length >= STAGED_KEPT) break;
            const item = { path: path.slice(0, 400) };
            if (f && typeof f === 'object') {
                if (Number(f.added) > 0) item.added = Math.floor(Number(f.added));
                if (Number(f.removed) > 0) item.removed = Math.floor(Number(f.removed));
                if (f.deleted === true) item.deleted = true;
            }
            files.push(item);
        }
        if (!files.length) return null;
        const extra = Math.max(0, list.length - files.length);
        const more = p.stagedMore === true ? Math.max(1, extra) : Math.max(0, Math.floor(Number(p.stagedMore) || 0)) + extra;
        return {
            branch: p.stagedBranch ? String(p.stagedBranch).slice(0, 200) : '',
            files,
            more,
            unreviewed: p.unreviewedStaged === true
        };
    }

    function stagedNode(staged) {
        const box = el('div', 'server-run-staged');
        box.appendChild(el('div', 'server-run-meta', staged.branch
            ? t('Staged changes on {branch}:', { branch: staged.branch })
            : t('Staged changes:')));
        const list = el('ul', 'server-run-staged-files');
        for (const f of staged.files.slice(0, STAGED_SHOWN)) {
            const row = el('li', 'server-run-staged-file');
            row.appendChild(el('span', 'server-run-staged-path', f.path));
            const bits = f.deleted
                ? t('deleted')
                : [f.added ? '+' + f.added : '', f.removed ? '\u2212' + f.removed : ''].filter(Boolean).join(' ');
            if (bits) row.appendChild(el('span', 'server-run-staged-diff', bits));
            list.appendChild(row);
        }
        box.appendChild(list);
        const more = staged.more + Math.max(0, staged.files.length - STAGED_SHOWN);
        if (more > 0) box.appendChild(el('div', 'server-run-meta server-run-staged-more', t('+{n} more', { n: more })));
        if (staged.unreviewed) {
            box.appendChild(el('div', 'pending-tool-warn server-run-staged-warn',
                t("You haven't reviewed these staged changes. If you allow this run, they go to the server with it.")));
        }
        return box;
    }

    function stepsFrom(p) {
        const out = [];
        for (const s of Array.isArray(p.steps) ? p.steps.slice(0, 20) : []) {
            if (!s || typeof s !== 'object') continue;
            const parts = [String(s.action || '')];
            for (const k of ['selector', 'key', 'url']) if (s[k]) parts.push(String(s[k]).slice(0, 120));
            if (s.text) parts.push('"' + String(s.text).slice(0, 80) + '"');
            if (s.ms != null) parts.push(t('{n} ms', { n: Math.max(0, Math.floor(Number(s.ms) || 0)) }));
            out.push(parts.join(' '));
        }
        return out;
    }

    function pendingFrom(p, token) {
        const staged = stagedFrom(p);
        if (p.check === true) {
            return {
                kind: 'server-run',
                check: true,
                id: String(p.id || ''),
                image: 'sitecheck',
                url: String(p.url || p.command || '').slice(0, 2000),
                command: String(p.url || p.command || '').slice(0, 2000),
                steps: stepsFrom(p),
                timeoutSec: Math.max(0, Math.floor(Number(p.timeoutSec) || 0)),
                maxCredits: Math.max(0, Number(p.maxCredits) || 0),
                surcharge: Number(p.surcharge) > 1 ? Number(p.surcharge) : 0,
                creditsPerMinute: Math.max(0, Number(p.creditsPerMinute) || 0),
                team: false,
                staged: null,
                token,
                state: 'waiting'
            };
        }
        return {
            kind: 'server-run',
            id: String(p.id || ''),
            image: String(p.image || ''),
            command: String(p.command || '').slice(0, COMMAND_KEPT),
            timeoutSec: Math.max(0, Math.floor(Number(p.timeoutSec) || 0)),
            maxCredits: Math.max(0, Number(p.maxCredits) || 0),
            surcharge: Number(p.surcharge) > 1 ? Number(p.surcharge) : 0,
            creditsPerMinute: Math.max(0, Number(p.creditsPerMinute) || 0),
            repo: p.repo ? String(p.repo).slice(0, 200) : '',
            team: !!p.team,
            staged,
            token,
            state: 'waiting'
        };
    }

    function pendingCard(U, m) {
        const p = m.pendingTool;
        const card = el('div', 'pending-tool server-run-card' + (p.state && p.state !== 'waiting' ? ' is-settled' : ''));
        card.dataset.id = m.id;
        if (p.check) {
            card.classList.add('site-check-card');
            card.appendChild(el('div', 'pending-tool-head', t('Nymbot wants to check a website in a headless browser')));
            card.appendChild(el('pre', 'pending-tool-args server-run-command site-check-url', p.url || p.command));
            const steps = Array.isArray(p.steps) ? p.steps : [];
            if (steps.length) {
                const list = el('ol', 'site-check-steps');
                for (const s of steps) list.appendChild(el('li', null, String(s)));
                card.appendChild(list);
            }
            card.appendChild(el('div', 'server-run-meta', t('Time limit: {time}', { time: timeLabel(p.timeoutSec) })));
            if (Number(p.surcharge) > 1) for (const n of surchargeNodes(Number(p.creditsPerMinute) || 0)) card.appendChild(n);
            card.appendChild(el('div', 'server-run-price', t('Up to {credits} Pro credits', { credits: credits(p.maxCredits) })));
            return settleRow(U, m, p, card);
        }
        card.appendChild(el('div', 'pending-tool-head', p.team
            ? t('The team lead wants to run a command on a Nymbot server')
            : t('Nymbot wants to run a command on a Nymbot server')));
        const image = imageNamed(p.image);
        card.appendChild(el('div', 'server-run-meta', t('Image: {label}', { label: image && image.label ? image.label : p.image })));
        if (p.repo) card.appendChild(el('div', 'server-run-meta', t('Repository: {repo}', { repo: p.repo })));
        card.appendChild(el('pre', 'pending-tool-args server-run-command', p.command));
        card.appendChild(el('div', 'server-run-meta', t('Time limit: {time}', { time: timeLabel(p.timeoutSec) })));
        if (Number(p.surcharge) > 1) for (const n of surchargeNodes(Number(p.creditsPerMinute) || 0)) card.appendChild(n);
        card.appendChild(el('div', 'server-run-price', t('Up to {credits} Pro credits', { credits: credits(p.maxCredits) })));
        if (p.staged && Array.isArray(p.staged.files) && p.staged.files.length) card.appendChild(stagedNode(p.staged));
        return settleRow(U, m, p, card);
    }

    function settleRow(U, m, p, card) {
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
        if (U.turnsIn(conv.id).some(x => x.approving === m.id)) return;
        const p = m.pendingTool;
        const link = { convId: conv.id, asked: m.askedBy || null, runId: m.replyTo || null };
        if (!p || !p.token) {
            K.settle(U, conv.id, m, 'denied');
            U.runNote(link, t('That request has expired. Ask again and Nymbot will start it fresh.'));
            return;
        }
        const capStop = U.capStopsLeg(conv);
        if (capStop) {
            U.runNote(link, capStop);
            return;
        }
        const leg = Caps ? Caps.maxCost(conv, true, U.models) : null;
        const maxCost = approve && leg != null
            ? Math.ceil((leg + (Number(p.maxCredits) || 0)) * 1000) / 1000
            : leg;
        K.settle(U, conv.id, m, approve ? 'allowed' : 'denied');
        const turn = U.beginTurn(conv, approve
            ? (p.check ? t('Checking the website in a headless browser') : t('Running the command on a Nymbot server'))
            : (p.check ? t('Carrying on without the site check') : t('Carrying on without the server run')), { asked: m.askedBy || null, runId: m.replyTo || null, resumed: true });
        turn.approving = m.id;
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
                onSlot: (waiting) => U.turnState(turn, { slot: waiting }),
                onClaiming: (on) => U.turnState(turn, { claiming: on }),
                onTurn: (eventId, signer, info) => {
                    U.bindRun(turn, conv.id, null, eventId, signer, info);
                    U.watchTurn(turn, eventId, signer);
                }
            };
            if (approve) opts.runApprove = p.id;
            else opts.runDecline = p.id;
            const res = await Chat.send(conv, t('Continue.'), U.settings, opts);
            U.stopWatchingTurn(turn);
            if (turn.stopped) return;
            if (res.stopped) {
                U.runNote(turn, t('Stopped.'));
                return;
            }
            const reply = K.replyFrom(conv, U.settings, res);
            reply.replyTo = res.replyTo || turn.runId || null;
            reply.askedBy = turn.asked || null;
            U.placeMessage(conv.id, reply, turn);
            turn.lastReplyId = reply.id;
            if (window.NymbotArtifacts) window.NymbotArtifacts.harvest(conv.id, reply);
            const total = totalCost(reply);
            Store.recordUsage(total, true);
            U.bumpStats(conv, total, true);
            U.creditBalance(res.pro, res.balanceCredits != null ? res.balanceCredits : res.balance);
            if (res.truncated) await U.continueRun(turn, res);
        } catch (e) {
            U.stopWatchingTurn(turn);
            if (turn.stopped) return;
            if (e && e.stopped) {
                U.runNote(turn, t('Stopped.'));
            } else if (e && e.capExceeded) {
                K.settle(U, conv.id, m, 'waiting');
                U.runNote(turn, t('Stopped: carrying on could go past this chat\'s spending cap.'));
            } else if (e && e.noCredits) {
                K.settle(U, conv.id, m, 'waiting');
                U.runNote(turn, e.message);
                outOfPro(U, conv, { balance: e.balance, balanceCredits: e.balanceCredits });
            } else {
                U.runNote(turn, (e && e.message) || t('Could not carry on from there.'));
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
            row.appendChild(el('span', 'server-run-summary-exit', r.check
                ? (r.ok ? t('site check finished') : t('did not finish'))
                : r.code == null
                    ? t('did not finish')
                    : t('exit {code}', { code: String(r.code) })));
            row.appendChild(el('span', 'server-run-summary-credits', t('{credits} Pro credits', {
                credits: credits((Number(r.milli) || 0) / 1000)
            })));
            box.appendChild(row);
            const shots = Array.isArray(r.artifacts) ? artifactsNode(r.artifacts.filter(a => a && typeof a.url === 'string'), false) : null;
            if (shots) box.appendChild(shots);
        }
        return box;
    }

    function carry(res) {
        return {
            serverRuns: res && Array.isArray(res.serverRuns) && res.serverRuns.length ? res.serverRuns : null,
            serverRunCredits: res && Number(res.serverRunCredits) > 0 ? Number(res.serverRunCredits) : 0
        };
    }

    function md(text) {
        return '`' + String(text == null ? '' : text).replace(/[`\r\n]+/g, ' ').slice(0, 300) + '`';
    }

    function reportMarkdown(url, out, creditsCharged) {
        const r = (out && out.report) || {};
        const lines = ['**' + t('Site check of {url}', { url: String(url || r.url || '').replace(/[*`]/g, '') }) + '**', ''];
        if (r.timedOut) lines.push(t('The check stopped at its time limit.'));
        else if (out && out.ok) lines.push(t('Loaded with status {status}: {title}', { status: r.status == null ? '?' : String(r.status), title: md(r.title || '') }));
        else lines.push(t('The check did not finish: {error}', { error: md(r.error || t('unknown error')) }));
        lines.push('');
        const tm = r.timings;
        if (tm) {
            lines.push('- ' + t('Timings: first byte {ttfb} ms, content loaded {dcl} ms, fully loaded {load} ms', {
                ttfb: String(Math.round(Number(tm.ttfbMs) || 0)), dcl: String(Math.round(Number(tm.domContentLoadedMs) || 0)), load: String(Math.round(Number(tm.loadMs) || 0))
            }));
        }
        const list = (label, items, count, fmt) => {
            const all = Array.isArray(items) ? items : [];
            lines.push('- ' + label(String(Math.max(Number(count) || 0, all.length))));
            for (const it of all.slice(0, 5)) lines.push('  - ' + fmt(it));
        };
        list(n => t('Console errors: {n}', { n }), (r.console || []).concat((r.pageErrors || []).map(e => ({ text: e }))), r.consoleErrorCount, it => md(it.text));
        list(n => t('Failed requests: {n}', { n }), r.failedRequests, r.failedCount, it => md(it.url) + ' (' + (it.status != null ? String(it.status) : String(it.error || '')) + ')');
        list(n => t('Blocked requests: {n}', { n }), r.blocked, r.blockedCount, it => md(it.url) + ' \u2014 ' + String(it.reason || ''));
        const pwa = r.pwa;
        if (pwa) {
            const m = pwa.manifest || {};
            lines.push('- ' + t('Web app manifest: {state}', { state: m.ok ? t('valid') : (m.found ? t('has problems') : t('missing')) }));
            lines.push('- ' + t('Service worker: {state}', { state: pwa.serviceWorker && pwa.serviceWorker.registered ? t('registered') : t('not registered') }));
            lines.push('- ' + t('Reloads offline: {state}', { state: !pwa.offline || !pwa.offline.tested ? t('not tested') : (pwa.offline.ok ? t('yes') : t('no')) }));
            lines.push('- ' + t('Installable: {state}', { state: pwa.installable && pwa.installable.ready ? t('yes') : t('no') }));
        }
        const a = r.a11y;
        if (a) {
            lines.push('- ' + t('Accessibility: {images} images without alt text, {fields} unlabeled fields, {buttons} unnamed buttons, {links} unnamed links', {
                images: String(a.imagesWithoutAlt || 0), fields: String(a.inputsWithoutLabel || 0), buttons: String(a.buttonsWithoutName || 0), links: String(a.linksWithoutName || 0)
            }));
            if (!a.lang) lines.push('- ' + t('The page has no lang attribute.'));
        }
        for (const s of Array.isArray(r.steps) ? r.steps : []) {
            lines.push('- ' + t('Step {n}: {action}', { n: String(s.i), action: String(s.action || '') }) + ' ' + (s.ok ? '\u2713' : '\u2717' + (s.error ? ' ' + md(s.error) : (s.skipped ? ' ' + t('skipped') : ''))));
        }
        for (const shot of Array.isArray(out && out.screenshots) ? out.screenshots : []) {
            if (shot && typeof shot.url === 'string' && /^https:\/\//.test(shot.url)) lines.push('', shot.url);
        }
        lines.push('', t('Charged {credits} Pro credits', { credits: credits(Number(creditsCharged) || 0) }));
        return lines.join('\n');
    }

    function siteMax() {
        const base = Number(site && site.maxCredits) || 0;
        const held = siteSheet ? Number(siteSheet.override) || 0 : 0;
        return Math.max(base, held);
    }

    function showSitePrice() {
        const box = $('siteCheckSurcharge');
        if (box) {
            box.innerHTML = '';
            const on = Number(site && site.surcharge) > 1;
            box.hidden = !on;
            if (on) for (const n of surchargeNodes(Number(site.creditsPerMinute) || 0)) box.appendChild(n);
        }
        $('siteCheckPrice').textContent = t('Up to {credits} Pro credits', { credits: credits(siteMax()) });
        $('siteCheckPrice').dataset.credits = String(siteMax());
    }

    async function openSite(U, keep) {
        if (!U.conv) return;
        await load(true);
        if (!site) {
            U.toast(t('Site checks are not available right now.'));
            return;
        }
        siteSheet = keep || { ui: U, convId: U.conv.id, override: 0, busy: false };
        if (!keep) $('siteCheckUrl').value = '';
        showSitePrice();
        $('siteCheckGo').disabled = false;
        U.modalStatus('siteCheckStatus', keep && keep.changed ? t('The price went up since this was shown. Check it and run again.') : '', keep && keep.changed ? 'warn' : undefined);
        U.openModal('modalSiteCheck');
    }

    async function goSite() {
        const state = siteSheet;
        if (!state || state.busy) return;
        const U = state.ui;
        const url = String($('siteCheckUrl').value || '').trim();
        if (!/^https?:\/\/\S+$/i.test(url)) {
            U.modalStatus('siteCheckStatus', t('Enter a full http or https address.'), 'warn');
            return;
        }
        const Store = window.NymbotStore;
        const conv = Store.conversation(state.convId) || (U.conv && U.conv.id === state.convId ? U.conv : null);
        if (!conv) return;
        const maxCost = siteMax();
        const Caps = window.NymbotCaps;
        if (Caps && Caps.any(conv)) {
            const gate = await Caps.gate(U, conv, { tier: 'pro', low: maxCost, high: maxCost });
            if (!gate.go) return;
        }
        state.busy = true;
        $('siteCheckGo').disabled = true;
        U.modalStatus('siteCheckStatus', t('Checking {url} in a headless browser…', { url }));
        const Api = window.NymbotApi;
        let res;
        try {
            res = await Api.call('site-check', { url, maxCost }, { signer: signerFor(conv), timeout: 150000 });
        } catch (e) {
            res = { status: 0, data: { error: (e && e.message) || t('The request failed.') } };
        }
        state.busy = false;
        $('siteCheckGo').disabled = false;
        const data = (res && res.data) || {};
        if (res.status === 402 && data.error === 'price-changed') {
            state.override = Number(data.maxCredits) || 0;
            state.changed = true;
            await openSite(U, state);
            return;
        }
        if (res.status === 402 && data.noCredits) {
            U.modalStatus('siteCheckStatus', data.error || t('You are out of Pro credits.'), 'warn');
            outOfPro(U, conv, data);
            return;
        }
        if (res.status !== 200) {
            U.modalStatus('siteCheckStatus', data.error || t('The site check could not start.'), 'warn');
            if (res.status === 503 && data.available === false) {
                site = null;
                refreshChip(U);
            }
            return;
        }
        U.closeModals();
        const amount = Number(data.credits) || 0;
        const msg = {
            id: Store.uid(), role: 'bot', content: reportMarkdown(data.url || url, data, amount), ts: Date.now(),
            cost: 0, pro: true, siteCheck: true, serverRunCredits: amount
        };
        U.placeMessage(conv.id, msg);
        const balance = data.balanceCredits != null ? data.balanceCredits : data.balance;
        if (balance != null) U.creditBalance(true, balance);
        spend(U, conv.id, amount);
    }

    function handlers(U) {
        return {
            'server-run-go': () => go(),
            'toggle-server-runs': () => toggle(U),
            'open-site-check': () => openSite(U),
            'site-check-go': () => goSite()
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
        LANGS, IMAGE_FOR, shellImage, needsBrowser, canRun, artifactsNode,
        load, available, decorate, refresh, open, go,
        priceFor, billedSec, timesFor, refreshChip, handlers, reportMarkdown, openSite,
        get site() { return site; },
        set site(v) { site = v; },
        pendingFrom, pendingCard, resume, summaryNode, totalCost, carry,
        get info() { return info; },
        set info(v) { info = v; }
    };
})();
