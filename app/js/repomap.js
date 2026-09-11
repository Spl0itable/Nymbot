(function () {
    'use strict';

    const Store = window.NymbotStore;
    const GitApi = window.NymbotGitApi;

    const CACHE_KEY = 'map_repos';
    const FRESH_MS = 2 * 3600 * 1000;
    const RETRY_MS = 5 * 60 * 1000;
    const KEEP_MAPS = 12;
    const FILES_PER_REPO = 500;
    const DIR_NAMES_MAX = 24;
    const BLOCK_MAX = 12000;
    const READY_MS = 2500;

    const SKIP_DIRS = new Set([
        'node_modules', '.git', 'dist', 'build', 'out', 'target', '.next',
        '.nuxt', '.svelte-kit', '.cache', '.parcel-cache', 'coverage',
        '__pycache__', '.venv', 'venv', 'Pods', '.dart_tool', '.gradle',
        '.idea', '.vscode', 'bower_components', '.terraform', 'DerivedData',
        '.pub-cache', '.mypy_cache', '.pytest_cache', '.tox', '.expo', '.angular'
    ]);

    const SKIP_FILES = new Set([
        'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'npm-shrinkwrap.json',
        'pubspec.lock', 'Cargo.lock', 'composer.lock', 'Gemfile.lock',
        'poetry.lock', 'go.sum', 'Podfile.lock', 'mix.lock', 'flake.lock',
        '.DS_Store'
    ]);

    const STOP_TERMS = new Set(('a an and are as at be but by can could did do does '
        + 'file files for from had has have how i if in is it its me my not of on or '
        + 'our so than that the their them then there these they this to was we were '
        + 'what when where which who why will with would you your please').split(' '));

    function keyFor(repo) {
        return [
            repo.provider || 'github',
            repo.host || '',
            repo.repo || '',
            repo.branch || '',
            repo.paths || ''
        ].join('|');
    }

    let memo = null;

    function held() {
        if (memo) return memo;
        const all = Store.read(CACHE_KEY, {});
        memo = all && typeof all === 'object' ? all : {};
        return memo;
    }

    function store(all) {
        memo = all;
        Store.write(CACHE_KEY, all);
    }

    function keep(all) {
        const keys = Object.keys(all)
            .sort((a, b) => (all[b].usedAt || all[b].at || 0) - (all[a].usedAt || all[a].at || 0))
            .slice(0, KEEP_MAPS);
        const out = {};
        for (const k of keys) out[k] = all[k];
        store(out);
        return out;
    }

    function scopes(repo) {
        return String(repo.paths || '').split(/[,\s]+/).filter(Boolean)
            .map(p => p.replace(/^\/+/, ''));
    }

    function inScope(path, only) {
        if (!only.length) return true;
        for (const p of only) {
            if (path === p) return true;
            if (path.indexOf(p.endsWith('/') ? p : p + '/') === 0) return true;
        }
        return false;
    }

    function ignorable(path) {
        const parts = path.split('/');
        if (SKIP_FILES.has(parts[parts.length - 1])) return true;
        for (let i = 0; i < parts.length - 1; i++) {
            if (SKIP_DIRS.has(parts[i])) return true;
        }
        return false;
    }

    function depthOf(path) {
        let n = 0;
        for (let i = 0; i < path.length; i++) if (path[i] === '/') n++;
        return n;
    }

    function usable(paths, repo) {
        const only = scopes(repo || {});
        const rows = [];
        for (const raw of paths || []) {
            const path = typeof raw === 'string' ? raw : '';
            if (!path || path.endsWith('/')) continue;
            if (ignorable(path)) continue;
            if (!inScope(path, only)) continue;
            rows.push(path);
        }
        rows.sort((a, b) => depthOf(a) - depthOf(b) || a.localeCompare(b));
        const kept = rows.slice(0, FILES_PER_REPO);
        kept.sort((a, b) => a.localeCompare(b));
        return { paths: kept, dropped: rows.length - kept.length, total: rows.length };
    }

    function termsOf(query) {
        return new Set(String(query || '').toLowerCase().split(/[^a-z0-9]+/)
            .filter(w => w.length > 2 && !STOP_TERMS.has(w)));
    }

    function wanted(name, terms) {
        if (!terms.size) return false;
        const plain = name.toLowerCase();
        for (const term of terms) {
            if (plain.indexOf(term) !== -1) return true;
        }
        return false;
    }

    function group(paths) {
        const dirs = new Map();
        for (const path of paths) {
            const at = path.lastIndexOf('/');
            const dir = at === -1 ? '' : path.slice(0, at + 1);
            const name = at === -1 ? path : path.slice(at + 1);
            if (!dirs.has(dir)) dirs.set(dir, []);
            dirs.get(dir).push(name);
        }
        return dirs;
    }

    function heading(repo, entry) {
        const branch = entry.branch ? '@' + entry.branch : '';
        const scope = repo.paths ? ', paths ' + repo.paths : '';
        const plural = entry.total === 1 ? ' file' : ' files';
        return `--- ${repo.repo}${branch} (${entry.total}${plural}${scope}) ---`;
    }

    function render(repo, entry, budget, terms) {
        const lines = [heading(repo, entry)];
        let spent = lines[0].length;
        const dirs = group(entry.paths || []);
        const names = Array.from(dirs.keys()).sort();
        let skippedFiles = 0;

        for (const dir of names) {
            const all = dirs.get(dir).sort();
            if (spent >= budget) {
                skippedFiles += all.length;
                continue;
            }
            const first = all.filter(n => wanted(n, terms));
            const rest = all.filter(n => !wanted(n, terms));
            const ordered = first.concat(rest);
            const shown = ordered.slice(0, DIR_NAMES_MAX);
            const over = ordered.length - shown.length;
            const line = (dir || '(root)') + ': ' + shown.join(', ')
                + (over > 0 ? `, and ${over} more here` : '');
            spent += line.length + 1;
            lines.push(line);
        }

        const unlisted = (entry.dropped || 0) + skippedFiles;
        if (unlisted) {
            lines.push(`${unlisted} further files are not named above — list a directory to see them.`);
        }
        if (entry.partial) {
            lines.push('The forge cut this listing short, so it is not every file.');
        }
        return lines.join('\n');
    }

    const pending = new Map();

    let lastBlock = { sig: '', text: '' };

    const RepoMap = {
        keyFor,

        entry(repo) {
            const all = held();
            const hit = all[keyFor(repo)];
            return hit && Array.isArray(hit.paths) ? hit : null;
        },

        stale(repo) {
            const hit = this.entry(repo);
            if (!hit) return true;
            const age = Date.now() - (hit.at || 0);
            return age > (hit.failed ? RETRY_MS : FRESH_MS);
        },

        forget(repo) {
            const all = held();
            delete all[keyFor(repo)];
            store(all);
        },

        forgetAll() {
            store({});
        },

        async refresh(repo) {
            if (!repo || !repo.token || !repo.repo || !GitApi || !GitApi.tree) return null;
            const key = keyFor(repo);
            if (pending.has(key)) return pending.get(key);
            const run = (async () => {
                try {
                    const read = await GitApi.tree(repo);
                    const kept = usable(read.paths, repo);
                    const all = held();
                    all[key] = {
                        at: Date.now(),
                        usedAt: Date.now(),
                        branch: read.branch || repo.branch || '',
                        paths: kept.paths,
                        dropped: kept.dropped,
                        total: kept.total,
                        partial: !!read.partial
                    };
                    keep(all);
                    return all[key];
                } catch (_) {
                    const all = held();
                    const before = all[key];
                    if (!before || !before.paths.length) {
                        all[key] = {
                            at: Date.now(),
                            usedAt: Date.now(),
                            branch: repo.branch || '',
                            paths: [],
                            dropped: 0,
                            total: 0,
                            partial: false,
                            failed: true
                        };
                        keep(all);
                    }
                    return null;
                } finally {
                    pending.delete(key);
                }
            })();
            pending.set(key, run);
            return run;
        },

        warm(repos) {
            for (const repo of repos || []) {
                if (this.stale(repo)) this.refresh(repo);
            }
        },

        touch(repos) {
            const all = held();
            const now = Date.now();
            let changed = false;
            for (const repo of repos || []) {
                const hit = all[keyFor(repo)];
                if (!hit) continue;
                if (now - (hit.usedAt || 0) < 60000) continue;
                hit.usedAt = now;
                changed = true;
            }
            if (changed) store(all);
        },

        async ready(repos, ms) {
            const list = (repos || []).filter(r => r && r.repo && r.token);
            this.touch(list);
            const missing = list.filter(r => {
                const hit = this.entry(r);
                return !hit || (!hit.paths.length && !hit.failed);
            });
            this.warm(list);
            if (!missing.length) return;
            const waits = missing.map(r => pending.get(keyFor(r))).filter(Boolean);
            if (!waits.length) return;
            await Promise.race([
                Promise.all(waits),
                new Promise(r => setTimeout(r, ms == null ? READY_MS : ms))
            ]);
        },

        block(repos, query) {
            const list = (repos || []).filter(r => r && r.repo);
            if (!list.length) return '';
            const terms = termsOf(query);
            const all = held();
            const sig = list.map(r => {
                const key = keyFor(r);
                const hit = all[key];
                return key + ':' + (hit ? hit.at + ':' + hit.paths.length : '0');
            }).join('|') + '|' + Array.from(terms).sort().join(',');
            if (sig === lastBlock.sig) return lastBlock.text;
            const parts = [];
            const budget = Math.floor(BLOCK_MAX / list.length);
            for (const repo of list) {
                const hit = all[keyFor(repo)];
                if (!hit || !Array.isArray(hit.paths) || !hit.paths.length) continue;
                parts.push(render(repo, hit, budget, terms));
            }
            const text = parts.length ? headed(parts) : '';
            lastBlock = { sig, text };
            return text;
        },

        usable,
        render,
        ignorable,
        group,
        BLOCK_MAX,
        FILES_PER_REPO,
        FRESH_MS
    };

    function headed(parts) {
        return '[repository files]\n'
                + 'What each repository in scope holds, on the branch named, read from the '
                + 'forge by this device just now. Each line is a directory, then the files '
                + 'in it — pictures, video and other assets included, since what a '
                + 'repository holds is part of the answer even when the file cannot be read '
                + 'as text. Go straight to the file you want rather than listing '
                + 'directories to find it. Only dependencies, build output and lockfiles '
                + 'are left out; a count stands in wherever names are not listed, and the '
                + 'listing can be a little behind the branch — so a file you expect and do '
                + 'not see here may still be there. Where a shorter or truncated file list '
                + 'appears elsewhere in your instructions, prefer this one.\n'
                + parts.join('\n');
    }

    window.NymbotRepoMap = RepoMap;
})();
