// Landing page behaviour: the FAQ accordion, and the Nymbot conversation that
// plays inside the phone mockup.

// FAQ accordion. Delegated rather than an inline onclick so the page stays
// within `script-src 'self'` (see _headers).
document.addEventListener('click', (e) => {
    const question = e.target.closest('.faq-question');
    if (!question) return;
    const item = question.parentElement;
    const wasActive = item.classList.contains('active');
    document.querySelectorAll('.faq-item').forEach((i) => i.classList.remove('active'));
    if (!wasActive) item.classList.add('active');
});

// Fancy style: adjective_noun name generation (matching the app)
const adjectives = [
    'quantum', 'neon', 'cyber', 'shadow', 'plasma',
    'echo', 'nexus', 'void', 'flux', 'ghost',
    'phantom', 'stealth', 'cryptic', 'dark', 'neural',
    'binary', 'matrix', 'digital', 'virtual', 'zero',
    'null', 'anon', 'masked', 'hidden', 'cipher',
    'enigma', 'spectral', 'rogue', 'omega', 'alpha',
    'delta', 'sigma', 'vortex', 'turbo', 'razor',
    'blade', 'frost', 'storm', 'glitch', 'pixel',
    'hyper', 'proto', 'nano', 'micro', 'ultra',
    'silent', 'feral', 'lucid', 'primal', 'astral',
    'cobalt', 'onyx', 'crimson', 'obsidian', 'iron',
    'solar', 'lunar', 'stellar', 'cosmic', 'atomic',
    'toxic', 'rapid', 'swift', 'fierce'
];

const nouns = [
    'ghost', 'nomad', 'drift', 'pulse', 'wave',
    'spark', 'node', 'byte', 'mesh', 'link',
    'runner', 'hacker', 'coder', 'agent', 'proxy',
    'daemon', 'virus', 'worm', 'bot', 'droid',
    'reaper', 'shadow', 'wraith', 'specter', 'shade',
    'entity', 'unit', 'core', 'nexus', 'cypher',
    'breach', 'exploit', 'overflow', 'inject', 'root',
    'kernel', 'shell', 'terminal', 'console', 'script',
    'raven', 'wolf', 'viper', 'hawk', 'lynx',
    'phantom', 'signal', 'cipher', 'vector', 'forge',
    'circuit', 'photon', 'glider', 'shard', 'vault',
    'beacon', 'torrent', 'crypt', 'grid', 'orbit'
];

function generateNym() {
    const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
    const noun = nouns[Math.floor(Math.random() * nouns.length)];
    const suffix = Math.random().toString(16).substring(2, 6);
    return { name: `${adj}_${noun}`, suffix };
}

// Demo copy, localized at build time. build.mjs injects window.NYM_I18N for the
// page's language; the English source is the fallback.
function t(text) {
    const map = typeof window !== 'undefined' && window.NYM_I18N;
    return (map && map[text]) || text;
}

const messagesContainer = document.getElementById('phoneMessages');
const toolbar = document.getElementById('phoneToolbar');
const creditsEl = document.getElementById('phoneCredits');
const modelChip = document.getElementById('phoneModelChip');
const gitChip = document.getElementById('phoneGitChip');
const anonChip = document.getElementById('phoneAnonChip');

let selfNym = generateNym();
let lastGroupEl = null;
let lastGroupKey = null;
let credits = 240;

const BOT = { name: 'nymbot', suffix: 'cf54' };

function formatTime() {
    const now = new Date();
    return now.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true });
}

// Deterministic SVG identicon generator matching the app (js/modules/users.js)
function generateAvatarSvg(seed) {
    const key = String(seed == null ? '' : seed);
    let h = 2166136261 >>> 0;
    for (let i = 0; i < key.length; i++) {
        h ^= key.charCodeAt(i);
        h = Math.imul(h, 16777619) >>> 0;
    }
    let s = h || 1;
    const rand = () => {
        s = (s + 0x6D2B79F5) >>> 0;
        let x = Math.imul(s ^ (s >>> 15), 1 | s);
        x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
        return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
    };

    const hue = Math.floor(rand() * 360);
    const sat = 60 + Math.floor(rand() * 25);
    const light = 50 + Math.floor(rand() * 15);
    const fg = `hsl(${hue},${sat}%,${light}%)`;
    const bgHue = (hue + 180) % 360;
    const bg = `hsl(${bgHue},25%,18%)`;

    const cell = 16;
    const cols = 5;
    const rows = 5;
    const half = Math.ceil(cols / 2);
    let rects = '';
    for (let y = 0; y < rows; y++) {
        for (let x = 0; x < half; x++) {
            if (rand() < 0.5) {
                rects += `<rect x="${x * cell}" y="${y * cell}" width="${cell}" height="${cell}"/>`;
                const mirror = cols - 1 - x;
                if (mirror !== x) {
                    rects += `<rect x="${mirror * cell}" y="${y * cell}" width="${cell}" height="${cell}"/>`;
                }
            }
        }
    }

    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 80" width="80" height="80" shape-rendering="crispEdges"><rect width="80" height="80" fill="${bg}"/><g fill="${fg}">${rects}</g></svg>`;
    return 'data:image/svg+xml;base64,' + btoa(svg);
}

function syncAvatarOffset(groupEl) {
    const avatarBox = groupEl.querySelector(':scope > .message-group-avatar');
    const stack = groupEl.querySelector(':scope > .message-group-stack');
    if (!avatarBox || !stack) return;
    const lastMsg = stack.lastElementChild;
    if (!lastMsg) {
        avatarBox.style.marginBottom = '';
        return;
    }
    const contentEl = lastMsg.querySelector(':scope > .message-content');
    if (!contentEl) {
        avatarBox.style.marginBottom = '';
        return;
    }
    const below = lastMsg.offsetHeight - (contentEl.offsetTop + contentEl.offsetHeight);
    avatarBox.style.marginBottom = below > 0 ? below + 'px' : '';
}

function addMessage(msg) {
    const isOwn = !!msg.self;
    const groupKey = `${msg.author}#${msg.suffix}`;
    const isGrouped = lastGroupEl && lastGroupKey === groupKey;

    let groupEl;
    if (isGrouped) {
        groupEl = lastGroupEl;
    } else {
        groupEl = document.createElement('div');
        groupEl.className = `message-group${isOwn ? ' group-self' : ''}`;

        const avatarBox = document.createElement('div');
        avatarBox.className = 'message-group-avatar';
        const avatarSrc = msg.bot ? '/images/nymbot-icon.png' : generateAvatarSvg(groupKey);
        avatarBox.innerHTML = `<img src="${avatarSrc}" class="avatar-bubble" alt="" loading="lazy">`;

        const stack = document.createElement('div');
        stack.className = 'message-group-stack';

        groupEl.appendChild(avatarBox);
        groupEl.appendChild(stack);
        messagesContainer.appendChild(groupEl);

        lastGroupEl = groupEl;
        lastGroupKey = groupKey;
    }

    const messageEl = document.createElement('div');
    messageEl.className = `chat-message${isOwn ? ' self' : ''}${isGrouped ? ' bubble-grouped' : ''}`;
    messageEl.style.animationDelay = '0s';

    const authorHtml = msg.bot
        ? `<span class="message-author bot-author">${msg.author}<span class="nym-suffix">#${msg.suffix}</span><span class="verified-tick" title="Verified">&#10003;</span></span>`
        : `<span class="message-author ${msg.colorClass}">${msg.author}<span class="nym-suffix">#${msg.suffix}</span></span>`;

    const reasoningHtml = msg.reasoning
        ? `<span class="reasoning-chip">&#128173; ${t('Reasoning')}</span>`
        : '';

    const costHtml = msg.cost
        ? `<span class="cost-chip">&#9889; ${msg.cost}</span>`
        : '';

    messageEl.innerHTML = `
        ${authorHtml}
        <span class="message-content">${reasoningHtml}${msg.content}${costHtml}<span class="bubble-time-inner">${formatTime()}</span></span>
    `;

    groupEl.querySelector('.message-group-stack').appendChild(messageEl);
    syncAvatarOffset(groupEl);

    messagesContainer.scrollTop = messagesContainer.scrollHeight;
}

function showThinking(label) {
    const indicator = document.createElement('div');
    indicator.className = 'bot-thinking';
    indicator.id = 'phoneThinking';
    indicator.innerHTML = `
        <img src="/images/nymbot-icon.png" class="avatar-bubble" alt="" loading="lazy">
        <span class="bot-thinking-label">${label || t('Nymbot is thinking')}</span>
        <span class="typing-dot"></span>
        <span class="typing-dot"></span>
        <span class="typing-dot"></span>
    `;
    messagesContainer.appendChild(indicator);
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
}

function hideThinking() {
    const indicator = document.getElementById('phoneThinking');
    if (indicator) indicator.remove();
}

function setChip(el, label, active) {
    if (!el) return;
    const labelEl = el.querySelector('.bot-ctrl-label');
    if (labelEl && label != null) labelEl.textContent = label;
    el.classList.toggle('is-active', !!active);
}

function setTier(tier) {
    if (!toolbar) return;
    toolbar.querySelectorAll('.bot-tier-btn').forEach((b) => {
        b.classList.toggle('is-active', b.dataset.tier === tier);
    });
    toolbar.classList.toggle('is-pro', tier === 'pro');
}

function spend(n) {
    credits = Math.max(0, credits - n);
    if (creditsEl) creditsEl.textContent = String(credits);
}

// The conversation the mockup plays. `wait` is the pause BEFORE the step.
function script() {
    return [
        { wait: 600, run: () => addMessage({ author: selfNym.name, suffix: selfNym.suffix, colorClass: 'user-color-1', self: true, content: t('what does hybrid post-quantum actually buy me here?') }) },
        { wait: 700, run: () => showThinking() },
        {
            wait: 2200, run: () => {
                hideThinking();
                addMessage({
                    author: BOT.name, suffix: BOT.suffix, bot: true, reasoning: true, cost: '1',
                    content: t('Protection against harvest-now-decrypt-later. Your wrap is sealed with <strong>both</strong> X25519 and ML-KEM-768, and the shared secret is derived from the two together &mdash; so an attacker who stores this traffic today needs to break the lattice <em>and</em> the curve to read it.')
                });
                spend(1);
            }
        },
        { wait: 1600, run: () => addMessage({ author: selfNym.name, suffix: selfNym.suffix, colorClass: 'user-color-1', self: true, content: '?model opus-5' }) },
        {
            wait: 700, run: () => {
                setTier('pro');
                setChip(modelChip, 'Claude Opus 5', true);
                addMessage({ author: BOT.name, suffix: BOT.suffix, bot: true, content: t('Pinned to <strong>Claude Opus 5</strong>. Replies now come out of your Pro balance.') });
            }
        },
        { wait: 1500, run: () => addMessage({ author: selfNym.name, suffix: selfNym.suffix, colorClass: 'user-color-1', self: true, content: '?git' }) },
        {
            wait: 800, run: () => {
                setChip(gitChip, 'nymbot/app', true);
                addMessage({ author: BOT.name, suffix: BOT.suffix, bot: true, content: t('Connected to <code>nymbot/app</code> on <code>main</code>. Writes are off.') });
            }
        },
        { wait: 1500, run: () => addMessage({ author: selfNym.name, suffix: selfNym.suffix, colorClass: 'user-color-1', self: true, content: t('why does the voucher retry give up early?') }) },
        { wait: 700, run: () => showThinking(t('Nymbot is reading your repo')) },
        {
            wait: 2600, run: () => {
                hideThinking();
                addMessage({
                    author: BOT.name, suffix: BOT.suffix, bot: true, reasoning: true, cost: '4',
                    content: t('Found it in <code>js/modules/anon-bot.js</code>. The loop breaks on any non-2xx, but an insufficient balance deletes the claim and returns <code>409</code> &mdash; which is retryable after a top-up. Want a branch that treats 409 separately?')
                });
                spend(4);
            }
        },
        { wait: 1700, run: () => addMessage({ author: selfNym.name, suffix: selfNym.suffix, colorClass: 'user-color-1', self: true, content: '?anon' }) },
        {
            wait: 800, run: () => {
                setChip(anonChip, 'Anon on', true);
                addMessage({ author: BOT.name, suffix: BOT.suffix, bot: true, content: t('You are on a throwaway key now. I am billing it, not your nym &mdash; and I cannot tell the two apart.') });
            }
        },
    ];
}

let steps = script();
let stepIndex = 0;
let timer = null;

function reset() {
    hideThinking();
    messagesContainer.innerHTML = '';
    lastGroupEl = null;
    lastGroupKey = null;
    selfNym = generateNym();
    credits = 240;
    if (creditsEl) creditsEl.textContent = String(credits);
    setTier('standard');
    setChip(modelChip, 'Auto-routed', false);
    setChip(gitChip, 'Git', false);
    setChip(anonChip, 'Anon', false);
    steps = script();
    stepIndex = 0;
}

function tick() {
    if (stepIndex >= steps.length) {
        timer = setTimeout(() => { reset(); tick(); }, 5000);
        return;
    }
    const step = steps[stepIndex++];
    timer = setTimeout(() => {
        step.run();
        tick();
    }, step.wait);
}

if (messagesContainer) {
    window.addEventListener('load', () => {
        reset();
        setTimeout(tick, 800);
    });
    // A tab in the background should not pile up timers, and coming back to a
    // conversation halfway through reads as broken. Restart it instead.
    document.addEventListener('visibilitychange', () => {
        if (document.hidden) {
            clearTimeout(timer);
        } else {
            clearTimeout(timer);
            reset();
            tick();
        }
    });
}

// Add subtle interactivity
document.querySelectorAll('.feature-card').forEach((card) => {
    card.addEventListener('mouseenter', function () {
        this.style.borderColor = 'rgba(0, 255, 0, 0.2)';
    });
    card.addEventListener('mouseleave', function () {
        this.style.borderColor = '';
    });
});

// Smooth scroll for anchor links
document.querySelectorAll('a[href^="#"]').forEach((anchor) => {
    anchor.addEventListener('click', function (e) {
        e.preventDefault();
        const target = document.querySelector(this.getAttribute('href'));
        if (target) target.scrollIntoView({ behavior: 'smooth' });
    });
});
