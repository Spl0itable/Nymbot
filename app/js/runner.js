(function () {
    'use strict';

    const SRC = '/app/sandbox.html';
    const RUN_TIMEOUT_MS = 30000;
    const LOAD_TIMEOUT_MS = 180000;
    const TEXT_MAX = 64 * 1024;
    const SEND_MAX = 12000;
    const LANGS = {
        python: 'python', py: 'python', python3: 'python', py3: 'python',
        javascript: 'javascript', js: 'javascript', mjs: 'javascript', node: 'javascript'
    };
    const PY_STDLIB = new Set('abc aifc antigravity argparse array ast asyncio atexit audioop base64 bdb binascii bisect builtins bz2 cProfile calendar cgi cgitb chunk cmath cmd code codecs codeop collections colorsys compileall concurrent configparser contextlib contextvars copy copyreg crypt csv ctypes curses dataclasses datetime dbm decimal difflib dis doctest email encodings ensurepip enum errno faulthandler fcntl filecmp fileinput fnmatch fractions ftplib functools gc genericpath getopt getpass gettext glob graphlib grp gzip hashlib heapq hmac html http idlelib imaplib imghdr importlib inspect io ipaddress itertools json keyword lib2to3 linecache locale logging lzma mailbox mailcap marshal math mimetypes mmap modulefinder msilib msvcrt multiprocessing netrc nis nntplib nt ntpath nturl2path numbers opcode operator optparse os ossaudiodev pathlib pdb pickle pickletools pipes pkgutil platform plistlib poplib posix posixpath pprint profile pstats pty pwd py_compile pyclbr pydoc pydoc_data pyexpat queue quopri random re readline reprlib resource rlcompleter runpy sched secrets select selectors shelve shlex shutil signal site smtplib sndhdr socket socketserver spwd sqlite3 sre_compile sre_constants sre_parse ssl stat statistics string stringprep struct subprocess sunau symtable sys sysconfig syslog tabnanny tarfile telnetlib tempfile termios textwrap this threading time timeit tkinter token tokenize tomllib trace traceback tracemalloc tty turtle turtledemo types typing unicodedata unittest urllib uu uuid venv warnings wave weakref webbrowser winreg winsound wsgiref xdrlib xml xmlrpc zipapp zipfile zipimport zlib zoneinfo'.split(' '));
    const PY_BUNDLED = new Set('bs4 contourpy cycler decorator fontTools joblib kiwisolver matplotlib matplotlib_pyodide mpmath networkx numpy packaging pandas patsy PIL pyparsing dateutil pytz yaml regex sklearn scipy setuptools pkg_resources six soupsieve sqlite3 statsmodels sympy threadpoolctl xlrd pyodide js'.split(' '));
    const PY_SERVER_ONLY = new Set(['socket', 'ssl', 'subprocess', 'multiprocessing', 'threading', 'tkinter', 'turtle', 'curses',
        'readline', 'webbrowser', 'ftplib', 'smtplib', 'poplib', 'imaplib', 'socketserver', 'telnetlib', 'xmlrpc', 'selectors', 'select',
        'urllib.request', 'http.client', 'http.server', 'http.cookiejar']);
    const JS_SERVER_ONLY = /\brequire\s*\(|^\s*import\s[^(]|^\s*export\s[^\n]*\sfrom\s|\bimport\s*\(|\bprocess\.(?:argv|env|exit|stdin|stdout|cwd)\b|\b__dirname\b|\b__filename\b|\bBuffer\.|\bfetch\s*\(|\bXMLHttpRequest\b|\bWebSocket\b|\bEventSource\b/m;
    const PNG = /^data:image\/png;base64,[A-Za-z0-9+/=]+$/;
    const RISKY = new Set([
        'exe', 'bat', 'cmd', 'com', 'scr', 'msi', 'ps1', 'vbs', 'vbe', 'js', 'jse', 'mjs', 'jar', 'apk', 'app',
        'dmg', 'pkg', 'sh', 'command', 'html', 'htm', 'xhtml', 'shtml', 'svg', 'hta', 'lnk', 'pif', 'reg', 'wsf', 'cpl', 'msc'
    ]);

    let frame = null;
    let ready = null;
    let readyResolve = null;
    let current = null;
    let loadedOnce = false;
    let lastConv;
    const queue = [];
    let seq = 0;

    function languageOf(block) {
        const pre = block && block.querySelector('pre.code');
        const lang = pre ? String(pre.dataset.lang || '').toLowerCase() : '';
        return LANGS[lang] || null;
    }

    function pythonImports(code) {
        const out = [];
        for (const line of String(code || '').split('\n')) {
            const plain = /^\s*import\s+([\w.,\s]+?)(?:\s+as\s+\w+)?\s*(?:#.*)?$/.exec(line);
            if (plain) {
                for (const part of plain[1].split(',')) {
                    const name = part.trim().split(/\s+as\s+/)[0].trim();
                    if (name) out.push(name);
                }
                continue;
            }
            const from = /^\s*from\s+([\w.]+)\s+import\b/.exec(line);
            if (from) out.push(from[1]);
        }
        return out;
    }

    function localOk(language, code) {
        if (language === 'python') {
            for (const full of pythonImports(code)) {
                const top = full.split('.')[0];
                if (PY_SERVER_ONLY.has(top) || PY_SERVER_ONLY.has(full.split('.').slice(0, 2).join('.'))) return false;
                if (!PY_STDLIB.has(top) && !PY_BUNDLED.has(top)) return false;
            }
            return true;
        }
        if (language === 'javascript') return !JS_SERVER_ONLY.test(String(code || ''));
        return false;
    }

    function codeOf(block) {
        const source = block && block.querySelector('.code-source');
        return source ? source.value : '';
    }

    function serverCanRun(block) {
        const S = window.NymbotServerRun;
        return !!(S && typeof S.canRun === 'function' && S.canRun(block));
    }

    function el(tag, cls, text) {
        const n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = text;
        return n;
    }

    function kill() {
        if (frame) frame.remove();
        frame = null;
        ready = null;
        readyResolve = null;
    }

    function ensureFrame() {
        if (frame && ready) return ready;
        frame = document.createElement('iframe');
        frame.setAttribute('sandbox', 'allow-scripts');
        frame.setAttribute('aria-hidden', 'true');
        frame.setAttribute('referrerpolicy', 'no-referrer');
        frame.tabIndex = -1;
        frame.title = 'sandbox';
        frame.className = 'sandbox-frame';
        frame.src = SRC;
        ready = new Promise((resolve) => { readyResolve = resolve; });
        document.body.appendChild(frame);
        return ready;
    }

    function safeName(raw) {
        let name = String(raw || '')
            .replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, '')
            .split(/[\\/]/).pop()
            .replace(/[:*?"<>|]/g, '_')
            .replace(/^[.\s]+/, '')
            .replace(/[.\s]+$/, '')
            .slice(0, 120);
        if (!name) name = 'file';
        const ext = /\.([^.]+)$/.exec(name);
        if (ext && RISKY.has(ext[1].toLowerCase())) name += '.txt';
        return name;
    }

    function clip(value) {
        const s = typeof value === 'string' ? value : '';
        return s.length > TEXT_MAX ? s.slice(0, TEXT_MAX) : s;
    }

    function clean(msg) {
        const table = msg.table && Array.isArray(msg.table.columns) && Array.isArray(msg.table.rows)
            ? {
                columns: msg.table.columns.slice(0, 20).map(String),
                index: Array.isArray(msg.table.index) ? msg.table.index.slice(0, 50).map(String) : [],
                rows: msg.table.rows.slice(0, 50).map(r => (Array.isArray(r) ? r : []).slice(0, 20).map(String)),
                total: Array.isArray(msg.table.total) ? msg.table.total.map(Number) : null
            }
            : null;
        return {
            stdout: clip(msg.stdout),
            stderr: clip(msg.stderr),
            value: typeof msg.value === 'string' ? clip(msg.value) : null,
            table,
            images: (Array.isArray(msg.images) ? msg.images : []).filter(u => typeof u === 'string' && PNG.test(u)).slice(0, 8),
            files: (Array.isArray(msg.files) ? msg.files : []).slice(0, 8).map(f => ({
                name: safeName(f && f.name),
                size: Number(f && f.size) || 0,
                data: f && typeof f.data === 'string' && /^[A-Za-z0-9+/=]*$/.test(f.data) ? f.data : null
            })),
            error: msg.error == null ? null : clip(String(msg.error)),
            truncated: !!msg.truncated,
            ms: Number(msg.ms) || 0
        };
    }

    window.addEventListener('message', (e) => {
        if (!frame || e.source !== frame.contentWindow) return;
        const msg = e.data;
        if (!msg || typeof msg !== 'object') return;
        if (msg.type === 'ready') {
            if (readyResolve) readyResolve();
            return;
        }
        if (!current || msg.id !== current.id) return;
        if (msg.type === 'status' && msg.phase === 'running') current.running();
        else if (msg.type === 'result') current.finish(clean(msg));
    });

    function pump() {
        if (current || !queue.length) return;
        const job = queue.shift();
        current = job;
        let timer = null;
        const done = (result) => {
            if (timer) clearTimeout(timer);
            if (current === job) current = null;
            job.resolve(result);
            pump();
        };
        const fail = (error) => done({
            stdout: '', stderr: '', value: null, table: null, images: [], files: [], error, truncated: false, ms: 0, killed: true
        });
        job.running = () => {
            loadedOnce = true;
            if (job.onRunning) job.onRunning();
            if (timer) clearTimeout(timer);
            timer = setTimeout(() => {
                kill();
                fail(t('Stopped after {n} seconds. Code that runs on your device is given {n} seconds.', { n: Math.round(job.timeout / 1000) }));
            }, job.timeout);
        };
        job.finish = done;
        timer = setTimeout(() => {
            kill();
            fail(t('The sandbox did not load. Check your connection and try again.'));
        }, job.loadTimeout);
        if (frame && job.conv !== lastConv) kill();
        lastConv = job.conv;
        ensureFrame().then(() => {
            if (current !== job || !frame) return;
            frame.contentWindow.postMessage({
                type: 'run', id: job.id, code: job.code, language: job.language, files: job.files
            }, '*');
        });
    }

    function run(code, language, options) {
        const opts = options || {};
        return new Promise((resolve) => {
            queue.push({
                id: 'run-' + (++seq) + '-' + Math.random().toString(36).slice(2, 8),
                code: String(code || ''),
                language: language === 'javascript' ? 'javascript' : 'python',
                files: Array.isArray(opts.files) ? opts.files : [],
                conv: opts.conv == null ? null : String(opts.conv),
                timeout: opts.timeout || RUN_TIMEOUT_MS,
                loadTimeout: opts.loadTimeout || LOAD_TIMEOUT_MS,
                onRunning: opts.onRunning || null,
                resolve
            });
            pump();
        });
    }

    function base64Bytes(b64) {
        const binary = atob(b64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes;
    }

    function tableNode(table) {
        const wrap = el('div', 'run-table');
        const tbl = el('table');
        const head = el('tr');
        head.appendChild(el('th', null, ''));
        for (const c of table.columns) head.appendChild(el('th', null, c));
        const thead = el('thead');
        thead.appendChild(head);
        tbl.appendChild(thead);
        const tbody = el('tbody');
        table.rows.forEach((r, i) => {
            const tr = el('tr');
            tr.appendChild(el('th', null, table.index[i] != null ? table.index[i] : String(i)));
            for (const cell of r) tr.appendChild(el('td', null, cell));
            tbody.appendChild(tr);
        });
        tbl.appendChild(tbody);
        wrap.appendChild(tbl);
        if (table.total && (table.total[0] > table.rows.length || table.total[1] > table.columns.length)) {
            wrap.appendChild(el('div', 'run-note', t('Showing {rows} of {total} rows.', { rows: table.rows.length, total: table.total[0] })));
        }
        return wrap;
    }

    function tableText(table) {
        const lines = [[''].concat(table.columns).join('\t')];
        table.rows.forEach((r, i) => lines.push([table.index[i] || String(i)].concat(r).join('\t')));
        return lines.join('\n');
    }

    function outputText(result) {
        const parts = [];
        if (result.stdout) parts.push(result.stdout.trimEnd());
        if (result.value) parts.push(result.value);
        if (result.table) parts.push(tableText(result.table));
        if (result.stderr) parts.push(result.stderr.trimEnd());
        if (result.error) parts.push(result.error);
        if (result.images.length) parts.push(t('Charts drawn: {n}', { n: result.images.length }));
        if (result.files.length) parts.push(t('Files written: {names}', { names: result.files.map(f => f.name).join(', ') }));
        let body = parts.join('\n\n');
        if (body.length > SEND_MAX) body = body.slice(0, SEND_MAX) + '\n…';
        return body;
    }

    function sendToComposer(result) {
        const input = document.getElementById('input');
        if (!input) return;
        const body = outputText(result);
        const text = t('Here is the output of that code, run on my device:') + '\n```text\n' + body + '\n```';
        const prev = String(input.value || '').trim();
        input.value = prev ? prev + '\n\n' + text : text;
        const U = window.NymbotUI;
        if (U) {
            if (typeof U.autoGrow === 'function') U.autoGrow();
            if (typeof U.updateHints === 'function') U.updateHints();
        }
        if (typeof input.focus === 'function') input.focus();
    }

    function render(box, result) {
        box.innerHTML = '';
        box.classList.toggle('is-error', !!result.error);
        const head = el('div', 'run-head');
        head.appendChild(el('span', 'run-title', result.error
            ? t('Ran on your device — failed')
            : t('Ran on your device in {ms} ms', { ms: result.ms })));
        const actions = el('span', 'run-actions');
        if (document.getElementById('input')) {
            const send = el('button', 'code-btn run-send', t('Send output to Nymbot'));
            send.type = 'button';
            send.addEventListener('click', () => sendToComposer(result));
            actions.appendChild(send);
        }
        const close = el('button', 'code-btn run-close', t('Clear'));
        close.type = 'button';
        close.addEventListener('click', () => box.remove());
        actions.appendChild(close);
        head.appendChild(actions);
        box.appendChild(head);
        if (result.stdout) box.appendChild(el('pre', 'run-stdout', result.stdout));
        if (result.value) box.appendChild(el('pre', 'run-value', result.value));
        if (result.table) box.appendChild(tableNode(result.table));
        for (const src of result.images) {
            const img = document.createElement('img');
            img.className = 'run-image';
            img.alt = t('Chart');
            img.src = src;
            box.appendChild(img);
        }
        if (result.files.length) {
            const list = el('div', 'run-files');
            for (const f of result.files) {
                if (!f.data) {
                    list.appendChild(el('span', 'run-note', t('{name} is too large to hand back.', { name: f.name })));
                    continue;
                }
                const b = el('button', 'code-btn run-file', t('Save {name}', { name: f.name }));
                b.type = 'button';
                b.addEventListener('click', () => {
                    const blob = new Blob([base64Bytes(f.data)], { type: 'application/octet-stream' });
                    const Ex = window.NymbotExport;
                    if (Ex && typeof Ex.saveBlob === 'function') Ex.saveBlob(f.name, blob);
                });
                list.appendChild(b);
            }
            box.appendChild(list);
        }
        if (result.stderr) box.appendChild(el('pre', 'run-stderr', result.stderr));
        if (result.error) box.appendChild(el('pre', 'run-error', result.error));
        if (result.truncated) box.appendChild(el('div', 'run-note', t('The output was cut short.')));
        if (!result.stdout && !result.value && !result.table && !result.images.length && !result.files.length
            && !result.stderr && !result.error) {
            box.appendChild(el('div', 'run-note', t('It ran, and printed nothing.')));
        }
        box.appendChild(el('div', 'run-note', t('Runs on your device in a sandbox with no access to your keys, your chats or the network.')));
    }

    function convId() {
        const U = window.NymbotUI;
        return U && U.conv ? U.conv.id : null;
    }

    async function onRun(block, button) {
        if (block.dataset.running === '1') return;
        const language = languageOf(block);
        if (!language) return;
        const source = block.querySelector('.code-source');
        const code = source ? source.value : '';
        let box = block.nextElementSibling;
        if (!box || !box.classList.contains('run-output')) {
            box = el('div', 'run-output');
            block.after(box);
        }
        block.dataset.running = '1';
        button.disabled = true;
        button.textContent = t('Running…');
        box.innerHTML = '';
        box.classList.remove('is-error');
        const status = el('div', 'run-note run-status', language === 'python' && !loadedOnce
            ? t('Loading Python on your device — about 14 MB the first time, plus any libraries the code imports. Nothing runs on a server.')
            : t('Starting…'));
        box.appendChild(status);
        const Docs = window.NymbotDocs;
        const id = convId();
        let files = [];
        if (Docs && id) {
            try {
                await Docs.load(id);
                files = Docs.files(id);
            } catch (_) { files = []; }
        }
        const result = await run(code, language, {
            files,
            conv: id,
            onRunning: () => { status.textContent = t('Running on your device…'); }
        });
        block.dataset.running = '';
        button.disabled = false;
        button.textContent = t('Run');
        if (box.isConnected) render(box, result);
    }

    function decorate(root) {
        if (!root || !root.querySelectorAll) return;
        for (const block of root.querySelectorAll('.code-block')) {
            const language = languageOf(block);
            if (!language) continue;
            if (!localOk(language, codeOf(block)) && serverCanRun(block)) continue;
            const actions = block.querySelector('.code-actions');
            if (!actions || actions.querySelector('.code-run')) continue;
            const b = el('button', 'code-btn code-run', t('Run'));
            b.type = 'button';
            b.title = t('Run this on your device');
            b.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                onRun(block, b);
            });
            actions.insertBefore(b, actions.firstChild);
        }
        if (window.NymbotServerRun) window.NymbotServerRun.decorate(root);
    }

    window.NymbotRunner = {
        decorate, run, kill, outputText, safeName, localOk, pythonImports,
        RUN_TIMEOUT_MS,
        get frame() { return frame; }
    };
})();
