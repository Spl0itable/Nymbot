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

    window.NymbotGitApi = { listRepos, supports, needsHost, providers: Object.keys(PROVIDERS) };
})();
