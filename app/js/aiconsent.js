// Kept on this device only, under a hash of the identity, so it can never link two keys.
(function () {
    'use strict';

    const PREFIX = 'nymbot_ai_consent.';

    const ACTIONS = new Set([
        'pm', 'pm-steer', 'pm-answer', 'pm-revert', 'transcribe', 'site-check', 'runner-run',
        'mcp-probe', 'git-apply', 'git-branch', 'schedule-put', 'pr-watch-put', 'pr-watch-peek', 'pr-watch-fix'
    ]);

    const STRINGS = {
        stepTitle: 'Nymbot uses AI services',
        stepIntro: 'Before you start, here is what Nymbot sends to answer you and who receives it.',
        what: 'What is sent: your messages and the earlier messages of that chat, the files, images and voice recordings you add, and the persona, instructions, memories and workspace files you use with it. When you connect a repository or a connector, Nymbot also receives its access token, and the files and tool results it reads go to the AI model.',
        who: 'Who receives it: the Nymbot service run by 21 Million LLC, which processes it on our servers. If you pick a Pro model or an image or video generator, it also goes to that model\'s maker, such as OpenAI, Anthropic, Google, xAI, Moonshot AI, Alibaba or MiniMax. Repositories and connectors you add are contacted on your behalf.',
        later: 'You can turn this off at any time in Settings → Privacy & Security.',
        privacyLink: 'Privacy Policy',
        accept: 'Allow and continue',
        decline: 'Don\'t allow',
        declinedTitle: 'Nymbot needs AI processing',
        declinedBody: 'Nymbot answers by sending your messages to AI services, so it cannot work until you allow that. Nothing has been sent. You can allow it whenever you are ready.',
        offNotice: 'Nothing was sent. Nymbot needs Nymbot AI processing to answer. Turn it on in Settings → Privacy & Security.',
        section: 'Privacy & Security',
        settingSwitch: 'Allow Nymbot AI processing'
    };

    const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

    function key() {
        const id = window.NymbotIdentity;
        const pk = id && id.pubkey;
        const NT = window.NostrTools;
        if (!pk || !NT || typeof NT._sha256 !== 'function') return null;
        const digest = NT._sha256(new TextEncoder().encode('nymbot-ai-consent|' + pk));
        return PREFIX + hex(digest).slice(0, 32);
    }

    const AiConsent = {
        STRINGS,
        ACTIONS,
        listeners: new Set(),

        decision() {
            if (window.__nymbotAiConsentAssume === true) return 'allowed';
            const k = key();
            if (!k) return '';
            try { return localStorage.getItem(k) || ''; } catch (_) { return ''; }
        },

        allowed() { return this.decision() === 'allowed'; },

        set(allow) {
            const k = key();
            if (!k) return;
            try { localStorage.setItem(k, allow ? 'allowed' : 'declined'); } catch (_) { }
            for (const fn of this.listeners) {
                try { fn(this.decision()); } catch (_) { }
            }
        },

        guards(action) { return ACTIONS.has(action); },

        blocked() {
            const t = typeof window.t === 'function' ? window.t : (s) => s;
            return { status: 403, data: { error: t('Nothing was sent. Nymbot needs Nymbot AI processing to answer. Turn it on in Settings → Privacy & Security.'), consent: false } };
        }
    };

    window.NymbotAiConsent = AiConsent;
})();
