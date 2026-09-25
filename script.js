// Landing page behavior: the FAQ accordion, and the Nymbot conversation that
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
    return { name: `${adj}_${noun}` };
}

// Demo copy, localized at build time. build.mjs injects window.NYM_I18N for the
// page's language; the English source is the fallback.
function t(text) {
    const map = typeof window !== 'undefined' && window.NYM_I18N;
    return (map && map[text]) || text;
}

const messagesContainer = document.getElementById('phoneMessages');
const toolbar = document.getElementById('phoneToolbar');
const titleEl = document.getElementById('phoneTitle');
const modelChip = document.getElementById('phoneModelChip');
const gitChip = document.getElementById('phoneGitChip');
const placeholderEl = document.getElementById('phonePlaceholder');
const draftEl = document.getElementById('phoneDraft');
const sendEl = document.getElementById('phoneSend');

const BOT_AVATAR = '/images/nymbot-icon.png';
const USER_COLORS = [0, 1, 4, 5, 6, 7];
const SEND_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg>';

let selfNym = null;
let selfColor = 'user-color-1';
let tier = 'standard';
let conversationIndex = 0;
let runId = 0;
let timer = null;

function formatTime() {
    const now = new Date();
    return now.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true });
}

function para(html) {
    return `<p>${html}</p>`;
}

function list(items) {
    return `<ul>${items.map((item) => `<li>${item}</li>`).join('')}</ul>`;
}

function conversations() {
    return [
        {
            title: t('Post-quantum wraps'),
            seed: [
                {
                    user: t('Do I need an account for this?'),
                    bot: para(t('No. A key generated on your device is your identity, your history and your balance. There is no email, phone number or password.')),
                },
                {
                    user: t('How are my messages to Nymbot encrypted?'),
                    bot: para(t('Every message is <strong>gift-wrapped</strong>: sealed to keys only the two ends hold, so relays see nothing useful.'))
                        + list([t('relays carry only ciphertext'), t('each wrap uses a single-use sender key'), t('nothing ties two messages together')]),
                },
            ],
            steps: [
                { say: t('what does hybrid post-quantum actually buy me here?') },
                {
                    reply: para(t('Protection against harvest-now-decrypt-later. Your wrap is sealed with <strong>both</strong> X25519 and ML-KEM-768, and the shared secret is derived from the two together &mdash; so an attacker who stores this traffic today needs to break the lattice <em>and</em> the curve to read it.')),
                    followUps: [t('What is ML-KEM-768?'), t('Does it slow replies down?')],
                },
                { say: '?model opus-5' },
                { tier: 'pro', model: 'Claude Opus 5' },
                { note: para(t('Pinned to <strong>Claude Opus 5</strong>. Replies now come out of your Pro balance.')) },
            ],
        },
        {
            title: t('Voucher retry bug'),
            seed: [
                {
                    user: t('Which model answers on Standard?'),
                    bot: para(t('<strong>Auto-routed</strong> picks one for each message. Switch to Pro to use a frontier model, or pin one yourself.')),
                },
                {
                    user: t('Can you look at the voucher code in my repo?'),
                    bot: para(t('Yes. Connect the repository with <code>?git</code> and I can read it:'))
                        + list([t('reads stay scoped to the repo you pick'), t('writes are off until you turn them on'), t('the token is sealed to your key')]),
                },
            ],
            steps: [
                { say: '?git' },
                { git: 'nymbot/app' },
                { note: para(t('Connected to <code>nymbot/app</code> on <code>main</code>. Writes are off.')) },
                { tier: 'pro' },
                { say: t('why does the voucher retry give up early?') },
                {
                    label: t('Nymbot is reading your repo'),
                    model: 'Claude Opus 5',
                    reply: para(t('Found it in <code>js/modules/anon-bot.js</code>. The loop breaks on any non-2xx, but an insufficient balance deletes the claim and returns <code>409</code> &mdash; which is retryable after a top-up. Want a branch that treats 409 separately?')),
                    followUps: [t('Open a branch with the fix'), t('Show me the 409 path')],
                },
            ],
        },
    ];
}

function wait(ms, id) {
    return new Promise((resolve, reject) => {
        timer = setTimeout(() => (id === runId ? resolve() : reject(new Error('stale'))), ms);
    });
}

function scrollToEnd() {
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
}

function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
}

function avatar() {
    const img = el('img', 'phone-avatar');
    img.src = BOT_AVATAR;
    img.alt = '';
    return img;
}

function bubble(html) {
    const body = el('span', 'phone-bubble');
    const text = el('div', 'phone-text');
    text.innerHTML = html;
    body.appendChild(text);
    return body;
}

function addTime(body) {
    body.appendChild(el('span', 'phone-time', formatTime()));
}

function clearFollowUps() {
    messagesContainer.querySelectorAll('.phone-followups').forEach((row) => row.remove());
}

function addUserMessage(text) {
    clearFollowUps();
    const group = el('div', 'phone-group is-self');
    const stack = el('div', 'phone-stack');
    const msg = el('div', 'phone-msg is-self');
    msg.appendChild(el('span', `phone-author ${selfColor}`, selfNym));
    const body = bubble('');
    body.firstChild.textContent = text;
    addTime(body);
    msg.appendChild(body);
    stack.appendChild(msg);
    group.appendChild(stack);
    messagesContainer.appendChild(group);
    scrollToEnd();
}

function botShell(before) {
    const group = el('div', 'phone-group');
    const stack = el('div', 'phone-stack');
    const msg = el('div', 'phone-msg');
    const author = el('span', 'phone-author phone-bot-author', 'Nymbot');
    msg.appendChild(author);
    stack.appendChild(msg);
    group.appendChild(avatar());
    group.appendChild(stack);
    messagesContainer.insertBefore(group, before || null);
    return { msg, author };
}

function signAuthor(author, model) {
    const pro = tier === 'pro';
    author.appendChild(el('span', `phone-tier-badge${pro ? ' is-pro' : ''}`, pro ? t('PRO') : t('STD')));
    if (pro && model) author.appendChild(el('span', 'phone-model', model));
}

function addFollowUps(msg, items) {
    if (!items || !items.length) return;
    const row = el('div', 'phone-followups');
    items.forEach((text) => {
        const chip = el('span', 'phone-followup');
        chip.innerHTML = SEND_ICON;
        chip.appendChild(el('span', '', text));
        row.appendChild(chip);
    });
    msg.appendChild(row);
}

function addBotMessage(html, model, followUps) {
    const { msg, author } = botShell();
    signAuthor(author, model);
    const body = bubble(html);
    addTime(body);
    msg.appendChild(body);
    addFollowUps(msg, followUps);
    scrollToEnd();
}

function showThinking(label) {
    const node = el('div', 'phone-thinking');
    node.appendChild(avatar());
    node.appendChild(el('span', 'phone-thinking-label', label || t('Nymbot is thinking')));
    for (let i = 0; i < 3; i++) node.appendChild(el('span', 'phone-dot'));
    messagesContainer.appendChild(node);
    scrollToEnd();
    return node;
}

function tokenize(html) {
    return html.match(/<[^>]+>|&[#a-z0-9]+;|[\s\S]/gi) || [];
}

function visibleLength(tokens) {
    return tokens.filter((tok) => tok[0] !== '<').length;
}

function partialHtml(tokens, count) {
    let out = '';
    let shown = 0;
    for (const tok of tokens) {
        if (tok[0] === '<') {
            out += tok;
            continue;
        }
        if (shown >= count) break;
        out += tok;
        shown++;
    }
    return out;
}

function placeCaret(text) {
    let node = text;
    while (node.lastChild && node.lastChild.nodeType === 1) node = node.lastChild;
    node.appendChild(el('span', 'phone-caret'));
}

async function streamReply(step, id) {
    const thinking = showThinking(step.label);
    await wait(1400, id);
    if (step.model) setChip(modelChip, step.model, true);
    const { msg, author } = botShell(thinking);
    const body = bubble('');
    msg.appendChild(body);
    const text = body.firstChild;
    const tokens = tokenize(step.reply);
    const total = visibleLength(tokens);
    for (let shown = 0; shown < total; shown += 4) {
        text.innerHTML = partialHtml(tokens, shown);
        placeCaret(text);
        scrollToEnd();
        await wait(45, id);
    }
    await wait(250, id);
    thinking.remove();
    text.innerHTML = step.reply;
    signAuthor(author, step.model || modelLabel());
    addTime(body);
    addFollowUps(msg, step.followUps);
    scrollToEnd();
}

function modelLabel() {
    const label = modelChip && modelChip.classList.contains('is-active')
        ? modelChip.querySelector('.phone-chip-label').textContent
        : '';
    return label || 'Claude Opus 5';
}

async function typeAndSend(text, id) {
    placeholderEl.hidden = true;
    for (let i = 1; i <= text.length; i++) {
        draftEl.textContent = text.slice(0, i);
        await wait(38, id);
    }
    await wait(350, id);
    sendEl.classList.add('is-pressed');
    draftEl.textContent = '';
    placeholderEl.hidden = false;
    addUserMessage(text);
    await wait(200, id);
    sendEl.classList.remove('is-pressed');
}

function setChip(chip, label, active) {
    if (!chip) return;
    const labelEl = chip.querySelector('.phone-chip-label');
    if (labelEl) {
        labelEl.textContent = label || '';
        labelEl.hidden = !label;
    }
    chip.classList.toggle('is-active', !!active);
}

function setTier(next) {
    tier = next;
    if (!toolbar) return;
    toolbar.querySelectorAll('.phone-tier-btn').forEach((b) => {
        b.classList.toggle('is-active', b.dataset.tier === next);
    });
    toolbar.classList.toggle('is-pro', next === 'pro');
}

function reset(conv) {
    messagesContainer.innerHTML = '';
    draftEl.textContent = '';
    placeholderEl.hidden = false;
    sendEl.classList.remove('is-pressed');
    selfNym = generateNym().name;
    selfColor = `user-color-${USER_COLORS[Math.floor(Math.random() * USER_COLORS.length)]}`;
    setTier('standard');
    setChip(modelChip, t('Auto-routed'), false);
    setChip(gitChip, '', false);
    if (titleEl) titleEl.textContent = conv.title;
    conv.seed.forEach((pair) => {
        addUserMessage(pair.user);
        addBotMessage(pair.bot);
    });
}

async function play(id) {
    const all = conversations();
    const conv = all[conversationIndex % all.length];
    reset(conv);
    for (const step of conv.steps) {
        if (step.say) {
            await wait(1200, id);
            await typeAndSend(step.say, id);
        } else if (step.reply) {
            await wait(600, id);
            await streamReply(step, id);
        } else if (step.note) {
            await wait(700, id);
            addBotMessage(step.note, modelLabel());
        } else {
            await wait(700, id);
            if (step.tier) setTier(step.tier);
            if (step.model) setChip(modelChip, step.model, true);
            if (step.git) setChip(gitChip, step.git, true);
        }
    }
    await wait(5000, id);
    conversationIndex++;
}

async function loop(id) {
    try {
        for (;;) await play(id);
    } catch (e) {
        if (id === runId) throw e;
    }
}

function start() {
    clearTimeout(timer);
    runId++;
    loop(runId);
}

if (messagesContainer && draftEl && placeholderEl && sendEl) {
    window.addEventListener('load', start);
    document.addEventListener('visibilitychange', () => {
        clearTimeout(timer);
        runId++;
        if (!document.hidden) start();
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
