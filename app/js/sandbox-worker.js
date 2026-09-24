(function () {
    'use strict';

    const PYODIDE_PATH = '/pyodide/v0.27.7/full/';
    let base = '';
    const OUT_MAX = 64 * 1024;
    const REPR_MAX = 20000;
    const IMAGES_MAX = 8;
    const IMAGE_MAX = 2 * 1024 * 1024;
    const FILES_MAX = 8;
    const FILE_MAX = 1024 * 1024;
    const MOUNT_MAX = 24 * 1024 * 1024;

    const HARNESS = [
        'import sys, io, os, json, base64',
        'from pyodide.code import eval_code_async',
        '_nym_ns = {"__name__": "__main__"}',
        'def _nym_listing():',
        '    out = {}',
        '    for name in os.listdir("."):',
        '        if os.path.isfile(name):',
        '            st = os.stat(name)',
        '            out[name] = [st.st_size, st.st_mtime]',
        '    return json.dumps(out)',
        'def _nym_collect(value):',
        '    out = {"repr": None, "table": None, "images": []}',
        '    if value is not None:',
        '        pd = sys.modules.get("pandas")',
        '        if pd is not None and isinstance(value, pd.Series):',
        '            value = value.to_frame()',
        '        if pd is not None and isinstance(value, pd.DataFrame):',
        '            head = value.iloc[:50, :20]',
        '            out["table"] = {',
        '                "columns": [str(c) for c in head.columns],',
        '                "index": [str(i) for i in head.index],',
        '                "rows": [[str(x) for x in r] for r in head.itertuples(index=False, name=None)],',
        '                "total": [int(value.shape[0]), int(value.shape[1])]',
        '            }',
        '        else:',
        '            out["repr"] = repr(value)[:' + REPR_MAX + ']',
        '    plt = sys.modules.get("matplotlib.pyplot")',
        '    if plt is not None:',
        '        for n in plt.get_fignums()[:' + IMAGES_MAX + ']:',
        '            buf = io.BytesIO()',
        '            plt.figure(n).savefig(buf, format="png", dpi=100, bbox_inches="tight")',
        '            out["images"].append(base64.b64encode(buf.getvalue()).decode("ascii"))',
        '        plt.close("all")',
        '    return json.dumps(out)',
        'async def _nym_run(src):',
        '    value = await eval_code_async(src, globals=_nym_ns)',
        '    return _nym_collect(value)'
    ].join('\n');

    let pyodide = null;
    let loading = null;
    let busy = false;

    const realImport = self.importScripts.bind(self);
    const realFetch = self.fetch.bind(self);
    const realOpen = self.XMLHttpRequest ? self.XMLHttpRequest.prototype.open : null;

    function allowed(u) {
        try {
            const url = new URL(String(u), base || self.location.href);
            const home = new URL(PYODIDE_PATH, base || self.location.href);
            return url.origin === home.origin && url.pathname.startsWith(PYODIDE_PATH) &&
                !/%|\.\./.test(url.pathname) && !url.search && !url.username && !url.password;
        } catch (_) {
            return false;
        }
    }

    function blocked() {
        return new TypeError('Network access is blocked in the sandbox');
    }

    function lock(name, value) {
        let o = self;
        while (o) {
            if (Object.prototype.hasOwnProperty.call(o, name)) {
                try {
                    Object.defineProperty(o, name, { value, writable: false, configurable: false, enumerable: false });
                } catch (_) {
                    try { delete o[name]; } catch (_) { }
                }
            }
            o = Object.getPrototypeOf(o);
        }
        try {
            Object.defineProperty(self, name, { value, writable: false, configurable: false, enumerable: false });
        } catch (_) { }
    }

    function lockdown() {
        lock('fetch', function fetch(input, init) {
            let req;
            try {
                req = new Request(input, init);
            } catch (e) {
                return Promise.reject(e);
            }
            if (!allowed(req.url)) return Promise.reject(blocked());
            return realFetch(new Request(req, { credentials: 'omit', redirect: 'error' }));
        });
        lock('importScripts', function importScripts(...urls) {
            const plain = urls.map(u => String(u));
            for (const u of plain) if (!allowed(u)) throw blocked();
            return realImport(...plain);
        });
        if (realOpen) {
            const open = function open(method, url, ...rest) {
                const plain = String(url);
                if (!allowed(plain)) throw blocked();
                return realOpen.call(this, method, plain, ...rest);
            };
            try {
                Object.defineProperty(self.XMLHttpRequest.prototype, 'open', { value: open, writable: false, configurable: false });
            } catch (_) { }
        }
        for (const name of ['WebSocket', 'WebSocketStream', 'EventSource', 'WebTransport', 'Worker', 'SharedWorker',
            'BroadcastChannel', 'caches', 'CacheStorage', 'Cache', 'fetchLater']) {
            if (name in self) lock(name, undefined);
        }
    }

    lockdown();

    function post(msg) {
        self.postMessage(msg);
    }

    function capped(max) {
        let text = '';
        let cut = false;
        return {
            add(s) {
                if (cut) return;
                text += String(s);
                if (text.length > max) {
                    text = text.slice(0, max);
                    cut = true;
                }
            },
            get value() { return text; },
            get cut() { return cut; }
        };
    }

    function toBase64(bytes) {
        let binary = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return btoa(binary);
    }

    function fromBase64(b64) {
        const binary = atob(String(b64 || ''));
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes;
    }

    function safeName(name) {
        const base = String(name || 'file').split(/[\\/]/).pop();
        const clean = base.replace(/[\u0000-\u001f:*?"<>|]/g, '_').replace(/^\.+/, '_').slice(0, 120);
        return clean || 'file';
    }

    function inputFiles(list) {
        const out = [];
        let total = 0;
        for (const f of Array.isArray(list) ? list : []) {
            if (!f || typeof f !== 'object') continue;
            let data;
            if (typeof f.text === 'string') data = new TextEncoder().encode(f.text);
            else if (typeof f.data === 'string') data = fromBase64(f.data);
            else continue;
            total += data.length;
            if (total > MOUNT_MAX) break;
            out.push({ name: safeName(f.name), data });
        }
        return out;
    }

    function pyodideUrl() {
        return new URL(PYODIDE_PATH, base).href;
    }

    async function python() {
        if (pyodide) return pyodide;
        if (!loading) {
            loading = (async () => {
                realImport(pyodideUrl() + 'pyodide.js');
                const py = await self.loadPyodide({ indexURL: pyodideUrl(), fullStdLib: false });
                py.runPython('import os\nos.environ["MPLBACKEND"] = "AGG"');
                py.runPython(HARNESS);
                return py;
            })();
        }
        try {
            pyodide = await loading;
        } catch (e) {
            loading = null;
            throw e;
        }
        return pyodide;
    }

    function tidyTraceback(message) {
        const text = String(message || '');
        const at = text.indexOf('File "<exec>"');
        const kept = at >= 0 ? 'Traceback (most recent call last):\n  ' + text.slice(at) : text;
        return kept.length > 4000 ? kept.slice(-4000) : kept;
    }

    async function runPython(msg, out, err) {
        const py = await python();
        const files = inputFiles(msg.files);
        py.setStdout({ batched: (s) => out.add(s + '\n') });
        py.setStderr({ batched: (s) => err.add(s + '\n') });
        for (const f of files) py.FS.writeFile(f.name, f.data);
        const before = JSON.parse(py.globals.get('_nym_listing')());
        await py.loadPackagesFromImports(msg.code, {
            messageCallback: () => { },
            errorCallback: (m) => err.add(String(m) + '\n')
        });
        post({ type: 'status', id: msg.id, phase: 'running' });
        const started = performance.now();
        const run = py.globals.get('_nym_run');
        let collected;
        try {
            collected = JSON.parse(await run(msg.code));
        } finally {
            if (run.destroy) run.destroy();
        }
        const ms = Math.round(performance.now() - started);
        const after = JSON.parse(py.globals.get('_nym_listing')());
        const made = [];
        for (const name of Object.keys(after)) {
            const was = before[name];
            const now = after[name];
            if (was && was[0] === now[0] && was[1] === now[1]) continue;
            if (made.length >= FILES_MAX) break;
            if (now[0] > FILE_MAX) {
                made.push({ name, size: now[0], skipped: true });
                continue;
            }
            made.push({ name, size: now[0], data: toBase64(py.FS.readFile(name)) });
        }
        const images = (collected.images || [])
            .filter(b64 => b64.length <= IMAGE_MAX * 1.4)
            .map(b64 => 'data:image/png;base64,' + b64);
        return { value: collected.repr, table: collected.table, images, files: made, ms };
    }

    function show(value) {
        if (typeof value === 'string') return value;
        if (value === undefined) return 'undefined';
        try {
            const json = JSON.stringify(value, null, 2);
            if (json !== undefined) return json;
        } catch (_) { }
        return String(value);
    }

    async function runJs(msg, out, err) {
        const files = new Map(inputFiles(msg.files).map(f => [f.name, f.data]));
        const made = new Map();
        const decoder = new TextDecoder();
        const line = (sink) => (...args) => sink.add(args.map(show).join(' ') + '\n');
        const held = {};
        for (const k of ['log', 'info', 'debug', 'warn', 'error', 'table']) held[k] = console[k];
        console.log = console.info = console.debug = console.table = line(out);
        console.warn = console.error = line(err);
        self.readFile = (name) => {
            const data = files.get(safeName(name)) || made.get(safeName(name));
            if (!data) throw new Error('No such file: ' + name);
            return decoder.decode(data);
        };
        self.writeFile = (name, text) => {
            if (made.size >= FILES_MAX) throw new Error('Too many files');
            made.set(safeName(name), new TextEncoder().encode(String(text)));
        };
        self.listFiles = () => Array.from(files.keys());
        let fn = null;
        self.__nymbotJs = (f) => { fn = f; };
        const source = 'self.__nymbotJs(async function () {\n' + String(msg.code || '') + '\n});\n';
        const url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
        try {
            try {
                realImport(url);
            } finally {
                URL.revokeObjectURL(url);
            }
            if (!fn) throw new Error('The code did not start');
            post({ type: 'status', id: msg.id, phase: 'running' });
            const started = performance.now();
            const value = await fn();
            const outFiles = [];
            for (const [name, data] of made) {
                if (data.length > FILE_MAX) outFiles.push({ name, size: data.length, skipped: true });
                else outFiles.push({ name, size: data.length, data: toBase64(data) });
            }
            return {
                value: value === undefined ? null : show(value).slice(0, REPR_MAX),
                table: null,
                images: [],
                files: outFiles,
                ms: Math.round(performance.now() - started)
            };
        } finally {
            for (const k of Object.keys(held)) console[k] = held[k];
            self.__nymbotJs = null;
        }
    }

    async function run(msg) {
        if (busy) {
            post({ type: 'result', id: msg.id, error: 'busy', stdout: '', stderr: '', images: [], files: [], ms: 0 });
            return;
        }
        busy = true;
        const out = capped(OUT_MAX);
        const err = capped(OUT_MAX);
        const language = msg.language === 'javascript' ? 'javascript' : 'python';
        post({ type: 'status', id: msg.id, phase: 'loading' });
        let result = null;
        let error = null;
        try {
            result = language === 'python' ? await runPython(msg, out, err) : await runJs(msg, out, err);
        } catch (e) {
            error = language === 'python' ? tidyTraceback(e && e.message) : String((e && e.message) || e);
        } finally {
            busy = false;
        }
        post({
            type: 'result',
            id: msg.id,
            stdout: out.value,
            stderr: err.value,
            truncated: out.cut || err.cut,
            value: result ? result.value : null,
            table: result ? result.table : null,
            images: result ? result.images : [],
            files: result ? result.files : [],
            error,
            ms: result ? result.ms : 0
        });
    }

    self.addEventListener('message', (e) => {
        if (!e.isTrusted) return;
        const msg = e.data;
        if (!msg || typeof msg !== 'object') return;
        if (msg.type === 'init' && typeof msg.base === 'string' && !base) base = msg.base;
        else if (msg.type === 'run' && typeof msg.code === 'string') run(msg);
    });
})();
