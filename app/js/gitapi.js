(function () {
    'use strict';

    /// Asking a forge what a token can see, from the device that holds the
    /// token. Every provider below answers CORS, so the token never travels
    /// anywhere it does not already go: not to the Nymbot worker, and not to a
    /// relay. A host that refuses CORS simply fails, and the form still takes
    /// a repository typed in by hand.

    const PROVIDERS = {
        github: {
            base: (host) => {
                const h = (host || 'github.com').replace(/^https?:\/\//, '').replace(/\/+$/, '');
                return h === 'github.com' ? 'https://api.github.com' : `https://${h}/api/v3`;
            },
            path: '/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member',
            headers: (token) => ({
                Authorization: 'Bearer ' + token,
                Accept: 'application/vnd.github+json'
            }),
            read: (body) => (Array.isArray(body) ? body : []).map((r) => ({
                repo: r.full_name,
                branch: r.default_branch || '',
                private: !!r.private,
                description: r.description || ''
            }))
        },
        gitlab: {
            base: (host) => `https://${(host || 'gitlab.com').replace(/^https?:\/\//, '').replace(/\/+$/, '')}/api/v4`,
            path: '/projects?membership=true&per_page=100&order_by=last_activity_at',
            headers: (token) => ({ 'PRIVATE-TOKEN': token }),
            read: (body) => (Array.isArray(body) ? body : []).map((r) => ({
                repo: r.path_with_namespace,
                branch: r.default_branch || '',
                private: r.visibility !== 'public',
                description: r.description || ''
            }))
        },
        gitea: {
            base: (host) => `https://${(host || '').replace(/^https?:\/\//, '').replace(/\/+$/, '')}/api/v1`,
            path: '/user/repos?limit=100',
            headers: (token) => ({ Authorization: 'token ' + token }),
            read: (body) => (Array.isArray(body) ? body : []).map((r) => ({
                repo: r.full_name,
                branch: r.default_branch || '',
                private: !!r.private,
                description: r.description || ''
            }))
        },
        bitbucket: {
            base: () => 'https://api.bitbucket.org/2.0',
            path: '/repositories?role=member&pagelen=100&sort=-updated_on',
            headers: (token) => ({ Authorization: 'Bearer ' + token }),
            read: (body) => ((body && body.values) || []).map((r) => ({
                repo: r.full_name,
                branch: (r.mainbranch && r.mainbranch.name) || '',
                private: !!r.is_private,
                description: r.description || ''
            }))
        }
    };

    // Codeberg is Forgejo, which is Gitea's API.
    PROVIDERS.codeberg = Object.assign({}, PROVIDERS.gitea, {
        base: (host) => `https://${(host || 'codeberg.org').replace(/^https?:\/\//, '').replace(/\/+$/, '')}/api/v1`
    });

    /// The host a provider needs before it can be asked anything. Only a
    /// self-hosted forge has no default worth guessing.
    function needsHost(provider) {
        return provider === 'gitea';
    }

    function supports(provider) {
        return Object.prototype.hasOwnProperty.call(PROVIDERS, provider || 'github');
    }

    async function listRepos(cfg) {
        const provider = PROVIDERS[cfg.provider || 'github'];
        if (!provider) throw new Error('unsupported');
        if (!cfg.token) throw new Error('token');
        if (needsHost(cfg.provider) && !cfg.host) throw new Error('host');
        const url = provider.base(cfg.host) + provider.path;
        let res;
        try {
            res = await fetch(url, { headers: provider.headers(cfg.token) });
        } catch (e) {
            // A network error and a CORS refusal are indistinguishable from
            // here, so the message says what a reader can actually do.
            throw new Error('unreachable');
        }
        if (res.status === 401 || res.status === 403) throw new Error('denied');
        if (!res.ok) throw new Error('failed:' + res.status);
        const body = await res.json();
        const rows = provider.read(body).filter((r) => r.repo);
        rows.sort((a, b) => a.repo.localeCompare(b.repo));
        return rows;
    }

    const TREE_PAGE_MAX = 10;
    const TREE_PAGE_SIZE = 100;

    const TREES = {
        github: {
            async defaultBranch(cfg, ask) {
                const body = await ask(`/repos/${cfg.repo}`);
                return (body && body.default_branch) || '';
            },
            async files(cfg, ask, branch) {
                const body = await ask(
                    `/repos/${cfg.repo}/git/trees/${encodeURIComponent(branch)}?recursive=1`);
                const rows = (body && body.tree) || [];
                return {
                    paths: rows.filter(r => r && r.type === 'blob' && r.path).map(r => r.path),
                    partial: !!(body && body.truncated)
                };
            }
        },
        gitlab: {
            async defaultBranch(cfg, ask) {
                const body = await ask(`/projects/${encodeURIComponent(cfg.repo)}`);
                return (body && body.default_branch) || '';
            },
            async files(cfg, ask, branch) {
                const project = encodeURIComponent(cfg.repo);
                const paths = [];
                let partial = false;
                for (let page = 1; page <= TREE_PAGE_MAX; page++) {
                    const body = await ask(`/projects/${project}/repository/tree`
                        + `?recursive=true&per_page=${TREE_PAGE_SIZE}&page=${page}`
                        + (branch ? `&ref=${encodeURIComponent(branch)}` : ''));
                    const rows = Array.isArray(body) ? body : [];
                    for (const r of rows) {
                        if (r && r.type === 'blob' && r.path) paths.push(r.path);
                    }
                    if (rows.length < TREE_PAGE_SIZE) return { paths, partial };
                    partial = page === TREE_PAGE_MAX;
                }
                return { paths, partial };
            }
        },
        gitea: {
            async defaultBranch(cfg, ask) {
                const body = await ask(`/repos/${cfg.repo}`);
                return (body && body.default_branch) || '';
            },
            async files(cfg, ask, branch) {
                let ref = branch;
                try {
                    const head = await ask(`/repos/${cfg.repo}/branches/${encodeURIComponent(branch)}`);
                    if (head && head.commit && head.commit.id) ref = head.commit.id;
                } catch (_) { }
                const body = await ask(`/repos/${cfg.repo}/git/trees/${encodeURIComponent(ref)}`
                    + '?recursive=true&per_page=1000');
                const rows = (body && body.tree) || [];
                return {
                    paths: rows.filter(r => r && r.type === 'blob' && r.path).map(r => r.path),
                    partial: !!(body && body.truncated)
                };
            }
        },
        bitbucket: {
            async defaultBranch(cfg, ask) {
                const body = await ask(`/repositories/${cfg.repo}`);
                return (body && body.mainbranch && body.mainbranch.name) || '';
            },
            async files(cfg, ask, branch) {
                const paths = [];
                let next = `/repositories/${cfg.repo}/src/${encodeURIComponent(branch)}/`
                    + '?max_depth=100&pagelen=100&fields=values.path,values.type,next';
                for (let page = 1; page <= TREE_PAGE_MAX; page++) {
                    const body = await ask(next);
                    for (const r of (body && body.values) || []) {
                        if (r && r.type === 'commit_file' && r.path) paths.push(r.path);
                    }
                    next = (body && body.next) || '';
                    if (!next) return { paths, partial: false };
                }
                return { paths, partial: true };
            }
        }
    };

    TREES.codeberg = TREES.gitea;

    async function tree(cfg) {
        const name = cfg.provider || 'github';
        const provider = PROVIDERS[name];
        const reader = TREES[name];
        if (!provider || !reader) throw new Error('unsupported');
        if (!cfg.token) throw new Error('token');
        if (!cfg.repo) throw new Error('repo');
        if (needsHost(name) && !cfg.host) throw new Error('host');

        const base = provider.base(cfg.host);
        const headers = provider.headers(cfg.token);
        const ask = async (path) => {
            const url = /^https?:\/\//i.test(path) ? path : base + path;
            let res;
            try {
                res = await fetch(url, { headers });
            } catch (_) {
                throw new Error('unreachable');
            }
            if (res.status === 401 || res.status === 403) throw new Error('denied');
            if (res.status === 404) throw new Error('missing');
            if (!res.ok) throw new Error('failed:' + res.status);
            return res.json();
        };

        const branch = cfg.branch || await reader.defaultBranch(cfg, ask);
        if (!branch) throw new Error('branch');
        const read = await reader.files(cfg, ask, branch);
        return { branch, paths: read.paths, partial: read.partial };
    }

    window.NymbotGitApi = {
        listRepos, tree, supports, needsHost, providers: Object.keys(PROVIDERS)
    };
})();
