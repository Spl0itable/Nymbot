(function () {
    'use strict';

    const Share = window.NymbotShare;
    const $ = (id) => document.getElementById(id);

    function applyTheme() {
        try {
            const raw = localStorage.getItem(window.NymbotConfig.storagePrefix + 'settings');
            const theme = raw ? JSON.parse(raw).theme : null;
            if (theme && theme !== 'system') document.documentElement.setAttribute('data-theme', theme);
        } catch (_) { }
    }

    function note(title, lines) {
        const main = $('shareMain');
        main.innerHTML = '';
        const box = document.createElement('section');
        box.className = 'share-note';
        box.setAttribute('role', 'alert');
        const h = document.createElement('h2');
        h.textContent = title;
        box.appendChild(h);
        for (const line of lines) {
            const p = document.createElement('p');
            p.textContent = line;
            box.appendChild(p);
        }
        main.appendChild(box);
        document.body.dataset.state = 'error';
    }

    function stamp(ms) {
        try {
            return new Date(ms).toLocaleString(undefined, { dateStyle: 'long', timeStyle: 'short' });
        } catch (_) { return new Date(ms).toISOString(); }
    }

    function show(transcript) {
        const main = $('shareMain');
        main.innerHTML = '';
        const title = document.createElement('h1');
        title.className = 'share-title';
        title.textContent = transcript.title || t('Shared chat');
        main.appendChild(title);
        document.title = (transcript.title || t('Shared chat')) + ' - Nymbot';
        const list = document.createElement('div');
        list.className = 'share-transcript';
        Share.render(list, transcript);
        main.appendChild(list);
        const foot = document.createElement('p');
        foot.className = 'share-foot';
        foot.textContent = t('Read-only copy. It was encrypted on the sender’s device, and the key never left this link.');
        main.appendChild(foot);
        if (transcript.sharedAt) $('shareDate').textContent = t('Shared {date}', { date: stamp(transcript.sharedAt) });
        document.body.dataset.state = 'ready';
    }

    async function load() {
        let ref;
        try {
            ref = Share.parse(location.hash);
        } catch (_) {
            note(t('This link is incomplete'), [
                t('The part after the # is missing or damaged. Ask whoever sent it for the whole link, copied in one piece.')
            ]);
            return;
        }
        $('shareMain').textContent = t('Opening the shared chat…');
        let bytes;
        try {
            bytes = await Share.fetchBlob(ref);
        } catch (e) {
            if (e && e.gone) {
                note(t('This chat is no longer shared'), [
                    t('Whoever shared it stopped sharing, or the host let it expire.')
                ]);
            } else {
                note(t('The shared chat could not be loaded'), [
                    t('Check your connection and reload the page.')
                ]);
            }
            return;
        }
        let transcript;
        try {
            transcript = await Share.open(bytes, ref.key);
        } catch (_) {
            note(t('This link does not open this chat'), [
                t('The key in the link does not match what is stored. Ask whoever sent it for the whole link.')
            ]);
            return;
        }
        show(transcript);
    }

    async function start() {
        applyTheme();
        try { await window.NymbotI18n.ready; } catch (_) { }
        $('shareFrom').textContent = t('Shared from Nymbot');
        $('shareOpenApp').textContent = t('Open Nymbot');
        document.addEventListener('click', (e) => {
            const btn = e.target.closest('[data-act="code-copy"], [data-act="code-wrap"]');
            if (!btn) return;
            const block = btn.closest('.code-block, .diff-block');
            if (!block) return;
            if (btn.dataset.act === 'code-wrap') { block.classList.toggle('is-wrapped'); return; }
            const source = block.querySelector('.code-source');
            try { navigator.clipboard.writeText(source ? source.value : ''); } catch (_) { }
        });
        window.addEventListener('hashchange', () => load());
        await load();
    }

    window.NymbotShareView = { load, ready: start() };
})();
