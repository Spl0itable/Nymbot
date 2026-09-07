import { readFile, writeFile } from 'node:fs/promises';
import { head, FOOTER } from './mkpage.mjs';

const ART = (await readFile('/tmp/claude-0/-home-user/262cbd1c-9989-581e-9c88-400fe088560b/scratchpad/hero.txt', 'utf8')).replace(/\n$/, '');

// The mobile builds are in this repository but not yet in any store, so the
// hero does not carry badges that would 404 or, worse, resolve to the wrong
// app. /docs/apps/ says where they are instead.

const icon = (paths) => `                <div class="feature-icon">
                    <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
${paths}
                    </svg>
                </div>`;

const feature = (paths, title, desc) => `            <div class="feature-card">
${icon(paths)}
                <h3 class="feature-title">${title}</h3>
                <p class="feature-desc">${desc}</p>
            </div>`;

const FEATURES = [
  feature(`                        <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
                        <path d="M7 11V7a5 5 0 0 1 10 0v4" />
                        <circle cx="12" cy="16" r="1" />`,
    'End-to-End Encrypted',
    'Every question and every answer travels as a <a href="/docs/encryption/#gift-wraps">gift-wrapped</a> Nostr event, sealed to keys only the two ends hold. Relays carry ciphertext and a single-use sender key &mdash; nothing they can correlate.'),
  feature(`                        <path d="M12 2 4 6v6c0 5 3.4 9.4 8 10 4.6-.6 8-5 8-10V6l-8-4z" />
                        <path d="m9 12 2 2 4-4" />`,
    'Quantum-Resistant',
    'ML-KEM key encapsulation is combined with the classical exchange rather than replacing it, so an attacker has to break both. Traffic captured today does not become readable later. <a href="/docs/encryption/#post-quantum">How the hybrid works</a>.'),
  feature(`                        <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z" />
                        <line x1="3" y1="21" x2="21" y2="3" />`,
    'Anonymous Mode',
    'Move the whole conversation onto a throwaway key and your credits across as blind vouchers Nymbot signs without seeing. It bills a message it cannot attribute to you. <a href="/docs/anonymous/">The full mechanism</a>.'),
  feature(`                        <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" />`,
    'Paid in Bitcoin',
    'No subscription, no card, no invoice with your name on it. Buy credits over Lightning and spend them a reply at a time &mdash; 10 sats for a standard reply, 100 for a frontier model. <a href="/docs/credits/">Pricing in full</a>.'),
  feature(`                        <path d="m12 3-1.9 5.8a2 2 0 0 1-1.3 1.3L3 12l5.8 1.9a2 2 0 0 1 1.3 1.3L12 21l1.9-5.8a2 2 0 0 1 1.3-1.3L21 12l-5.8-1.9a2 2 0 0 1-1.3-1.3Z" />`,
    'Every Frontier Model',
    'Claude, GPT, Gemini, Grok, Kimi, Qwen and MiniMax, pinned per conversation &mdash; or let Nymbot route each message to whichever model suits the task. <a href="/docs/models/">Models and routing</a>.'),
  feature(`                        <line x1="6" y1="3" x2="6" y2="15" />
                        <circle cx="18" cy="6" r="3" />
                        <circle cx="6" cy="18" r="3" />
                        <path d="M18 9a9 9 0 0 1-9 9" />`,
    'Works In Your Repo',
    'Connect GitHub, GitLab or Gitea and Pro replies read your actual files, search the tree and answer from what is there. Turn writes on and it commits, branches and opens pull requests. <a href="/docs/git/">Repository mode</a>.'),
  feature(`                        <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
                        <circle cx="8.5" cy="8.5" r="1.5" />
                        <polyline points="21 15 16 10 5 21" />`,
    'Images and Speech',
    'Generate a picture with <code>?image</code> or a voice clip with <code>?speak</code>, choosing from nine frontier generators. Send it a photograph and it will tell you what is in it. <a href="/docs/media/">Making things</a>.'),
  feature(`                        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />`,
    'Many Conversations',
    'Keep as many separate chats as you like. Each is its own thread with its own context, named after the first thing you asked &mdash; and the title is written on your device, never sent. <a href="/docs/chats/">How chats work</a>.'),
  feature(`                        <circle cx="12" cy="12" r="10" />
                        <path d="M12 6v6l4 2" />`,
    'No Account, Ever',
    'No email, no phone number, no password. A key generated on your device is your identity, your history and your balance. Bring one you already have from any Nostr app. <a href="/docs/identity/">Identity and login</a>.'),
];

const COMMANDS = [
  ['?buy', 'Top up over Lightning'],
  ['?balance', 'Standard and Pro credits'],
  ['?model', 'Pin a frontier model'],
  ['?git', 'Connect a repository'],
  ['?anon', 'Chat from a throwaway key'],
  ['?image', 'Generate a picture'],
  ['?speak', 'Generate a voice clip'],
  ['?translate', 'Translate anything'],
  ['?define', 'Definition and usage'],
  ['?news', 'Breaking headlines'],
  ['?clear', 'Reset this conversation'],
  ['?help', 'Everything, free'],
].map(([name, desc]) => `            <div class="command-item">
                <div class="command-name">${name}</div>
                <div>${desc}</div>
            </div>`).join('\n');

const FAQ = [
  ['What is Nymbot?',
   `<p>A private AI assistant. You talk to it the way you would talk to anyone in a messenger, and it answers using whichever frontier model suits the question.</p>
                    <p>What is different is underneath: there is no account to make, the messages are end-to-end encrypted, and replies are paid for in Bitcoin a reply at a time rather than by subscription. It can also be told to stop knowing who you are.</p>`],
  ['Is it really private, if the AI reads my messages?',
   `<p>Being precise about this is worth more than being reassuring about it. Your messages are end-to-end encrypted, which means nobody in between &mdash; relays, networks, anyone holding the traffic &mdash; can read them. The Nymbot service does open them, because it has to in order to answer.</p>
                    <p>So the honest claim is: nobody else can read your conversation, and with <a href="/docs/anonymous/">anonymous mode</a> on, the service that answers it cannot tell whose conversation it is. Your conversation titles are generated on your device and never sent at all. <a href="/docs/encryption/#what-the-server-sees">The full table of what the server sees</a> is in the knowledge base.</p>`],
  ['How does anonymous mode work?',
   `<p>The chat is encrypted, but normally the service still knows which public key is talking to it &mdash; that key is what the credit balance and the conversation thread hang off. Encryption was never the gap. Attribution was.</p>
                    <p>Anonymous mode generates a throwaway keypair on your device and moves the entire conversation onto it. Your credits move across as <strong>blind vouchers</strong>: your app blinds a random secret, the service debits your balance and signs something it cannot read, and the throwaway key later presents the unblinded token with nothing to match it against. The tables record that a voucher was issued and that one was spent, and neither records who.</p>
                    <p>It does not hide everything, and <a href="/docs/anonymous/#limits">we say exactly what it does not hide</a>.</p>`],
  ['What does it cost?',
   `<p>Credits, bought over the Lightning Network. Standard credits are 10 sats each and buy an auto-routed reply; Pro credits are 100 sats each and buy a reply from a specific frontier model you have pinned.</p>
                    <p>An ordinary standard reply is one credit. A Pro reply costs a per-model base and then scales with the length of the answer, up to a per-model cap &mdash; the cap is reserved when you send and only the real cost is taken. Nothing is charged for a failed generation, and resending a message replays the answer you already bought rather than buying another. <a href="/docs/credits/">Pricing in detail</a>.</p>`],
  ['Do I need an account?',
   `<p>No. Open it and a keypair is generated on your device. That key is the account: it signs your messages, your balance is filed under its public half, and your history is encrypted to it.</p>
                    <p>Which is why the one thing worth doing on day one is backing up your <code>nsec</code>. Nobody can reissue it &mdash; not even us. You can also bring a key you already use in any other Nostr app.</p>`],
  ['Can I use it with Nymchat?',
   `<p>Yes, and it is the same account. <a href="https://nymchat.app">Nymchat</a> is a full messenger with Nymbot built into it; this is Nymbot on its own. Sign in to either with the same key and you get the same credits, the same history and the same throwaway key.</p>
                    <p>Buy credits in one, spend them in the other. Nothing needs migrating, because there is nothing per-service to migrate. <a href="/docs/apps/#nymchat">How the two relate</a>.</p>`],
  ['Which models can I use?',
   `<p>Claude Fable 5, Claude Opus 5, Claude Sonnet 5, Claude Haiku 4.5, GPT-5.6 Sol, GPT-5.4 mini, Gemini 3.1 Pro, Gemini 3.6 Flash, Grok 4.6, Kimi K3, Qwen 3.5 and MiniMax M3 &mdash; pinned per conversation with <code>?model</code>.</p>
                    <p>Or pin nothing: on the standard tier each message is classified and routed to a model suited to it, so a quick factual answer does not pay for a reasoning model. The picker is generated from a live catalog, so what you see is exactly what the service will charge for. <a href="/docs/models/">Models and routing</a>.</p>`],
  ['Can it work on my code?',
   `<p>Yes. <code>?git</code> connects GitHub, GitLab or Gitea/Forgejo with a scoped access token, a repository and a branch. After that, Pro replies run as a small agent: listing directories, reading files and searching the tree, then answering from what is actually there.</p>
                    <p>With <code>?git writes on</code> it can also commit, create branches and open pull or merge requests. The token is stored only on your device, passed with each request, never stored server-side and wiped by a panic wipe. <a href="/docs/git/">Repository mode</a>.</p>`],
  ['What happens if I lose my key?',
   `<p>You lose the account. Your history is encrypted to that key and your balance is filed under it, and there is no recovery path because there is no user table to recover you from &mdash; that is the same property that means nobody can hand your conversations to anyone else either.</p>
                    <p>Back up your <code>nsec</code> the first day you use it, and turn on <a href="/docs/identity/#encryption-at-rest">identity encryption</a> so the copy on your device is unreadable without unlocking.</p>`],
  ['Is it open source?',
   `<p>Yes &mdash; the web app, the mobile apps and this site are all in the <a href="https://github.com/Spl0itable/nymbot">public repository</a>. Read what the client does with your key rather than taking our word for it.</p>
                    <p>The hosted model routing is the part you cannot run yourself, which is why the client is written so that everything it can verify locally, it does: signatures, the voucher proofs, and the keys it seals to.</p>`],
].map(([q, a]) => `            <div class="faq-item">
                <div class="faq-question">
                    <div class="faq-question-text">${q}</div>
                    <div class="faq-icon">+</div>
                </div>
                <div class="faq-answer">
                    ${a.trim()}
                </div>
            </div>`).join('\n\n');

const html = `${head({
  title: 'Nymbot - Anonymous AI Chat, No Account, Paid in Bitcoin',
  description: 'Anonymous AI chat with no account and no subscription. End-to-end encrypted, every frontier model, and replies paid for in Bitcoin over Lightning.',
  slug: '',
})}
<body>
    <div class="grid-bg"></div>
    <section class="hero">
        <div class="hero-content">
            <div class="hero-text">
                <h1 class="glitch ascii-art"><span class="visually-hidden">Nymbot - anonymous AI chat, no account, paid in Bitcoin</span><span aria-hidden="true" data-i18n-skip>
${ART}
</span></h1>
                <p class="tagline">Private. Paid in sats. Yours alone.</p>
                <div class="terminal-text">
                    Anonymous AI chat. No account, no email, no subscription.<br/><br/>A key on your device is the whole of it. Ask anything, pin any frontier model, put it to work in your repository &mdash; and when you would rather it did not know who is asking, turn on anonymous mode and it will bill a message it cannot attribute to you.
                </div>
                <div class="cta-buttons">
                    <a href="/app" class="btn">Open Nymbot</a>
                    <a href="/docs/" class="btn btn-docs">Knowledge Base</a>
                    <a href="/docs/apps/" class="btn btn-secondary">Android &amp; iOS</a>
                </div>
            </div>
            <div class="phone-mockup">
                <div class="phone-frame">
                    <div class="phone-screen">
                        <div class="screen-header">
                            <pre class="screen-header-ascii">
${ART}
</pre>
                        </div>
                        <div class="bot-control-bar" id="phoneToolbar" aria-hidden="true">
                            <div class="bot-tier-switch">
                                <span class="bot-tier-btn is-active" data-tier="standard">Standard</span>
                                <span class="bot-tier-btn" data-tier="pro">Pro</span>
                            </div>
                            <span class="bot-ctrl-btn" id="phoneModelChip">
                                <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m12 3-1.9 5.8a2 2 0 0 1-1.3 1.3L3 12l5.8 1.9a2 2 0 0 1 1.3 1.3L12 21l1.9-5.8a2 2 0 0 1 1.3-1.3L21 12l-5.8-1.9a2 2 0 0 1-1.3-1.3Z"></path></svg>
                                <span class="bot-ctrl-label">Auto-routed</span>
                            </span>
                            <span class="bot-ctrl-btn" id="phoneGitChip">
                                <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="6" y1="3" x2="6" y2="15"></line><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle><path d="M18 9a9 9 0 0 1-9 9"></path></svg>
                                <span class="bot-ctrl-label">Git</span>
                            </span>
                            <span class="bot-ctrl-btn" id="phoneAnonChip">
                                <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"></path><line x1="3" y1="21" x2="21" y2="3"></line></svg>
                                <span class="bot-ctrl-label">Anon</span>
                            </span>
                            <span class="bot-ctrl-btn bot-ctrl-buy">
                                <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon></svg>
                                <span class="bot-ctrl-label" id="phoneCredits">240</span>
                            </span>
                        </div>
                        <div class="screen-messages" id="phoneMessages">
                            <!-- Messages are added by script.js -->
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </section>

    <section class="features">
        <h2 class="section-title glitch">Features</h2>
        <p class="section-subtitle">An assistant that answers to you and to nobody else</p>
        <div class="features-grid">
${FEATURES.join('\n')}
        </div>
    </section>

    <section class="protocol">
        <h2 class="section-title glitch">How A Turn Actually Works</h2>
        <p class="section-subtitle">Five steps, and none of them involve an account</p>
        <div class="protocol-content">
            <div class="protocol-box">
                <p style="color: var(--primary); margin-bottom: 1rem;">Nymbot is built on <a href="https://nostr.com" target="_blank" rel="noopener" style="color: var(--secondary)">Nostr</a>. Messages are events, identities are keypairs, and delivery is a set of relays rather than a server you have to trust &mdash; which is why an identity from any other Nostr app works here unchanged.</p>

                <div class="protocol-item">
                    <div class="protocol-label">1 &mdash; Sealed on your device</div>
                    <p style="color: rgb(16 222 145 / 80%);">
                        <strong>Kinds 14, 13 and 1059:</strong> an unsigned rumor, a seal signed to the recipient, and a wrap under a single-use key.<br>
                        A relay sees an event from a key that exists for one message only, addressed to a key it cannot connect to anything else.
                    </p>
                </div>

                <div class="protocol-item">
                    <div class="protocol-label">2 &mdash; Authenticated, not identified</div>
                    <p style="color: rgb(16 222 145 / 80%);">
                        <strong>Kind 27235:</strong> a short-lived auth event, signed for one action and one endpoint.<br>
                        A captured signature cannot be replayed against a different request. Your message never travels as plaintext.
                    </p>
                </div>

                <div class="protocol-item">
                    <div class="protocol-label">3 &mdash; The turn is claimed before it is charged</div>
                    <p style="color: rgb(16 222 145 / 80%);">
                        Nothing is fetched, generated or billed until the turn is claimed.<br>
                        Resend the same message and you collect the answer you already bought, rather than paying for a second one.
                    </p>
                </div>

                <div class="protocol-item">
                    <div class="protocol-label">4 &mdash; Opened, threaded, answered</div>
                    <p style="color: rgb(16 222 145 / 80%);">
                        The wrap is opened, the seal's signer is checked against the authenticated key, and the thread is rebuilt from the previous wraps.<br>
                        Classification, routing, web search and repository tool calls all happen here.
                    </p>
                </div>

                <div class="protocol-item">
                    <div class="protocol-label">5 &mdash; Sealed back to you</div>
                    <p style="color: rgb(16 222 145 / 80%);">
                        <strong>Kind 30078:</strong> the post-quantum announcement carrying each side's ML-KEM key.<br>
                        The reply is sealed hybrid &mdash; classical and lattice &mdash; so capturing it today buys nothing later.
                    </p>
                </div>

            </div>

            <div style="text-align: center; margin-top: 3rem;">
                <p style="color: var(--secondary); font-size: 1.1rem;">
                    No user table. No password to leak. No transcript anyone can be compelled to hand over.<br>
                    <a href="/docs/protocol/" style="color: var(--secondary)">The whole protocol, written down</a>.
                </p>
            </div>
        </div>
    </section>

    <section class="commands">
        <h2 class="section-title glitch">Available Commands</h2>
        <p class="section-subtitle">Anything beginning with <code>?</code> is a command</p>
        <div class="commands-grid">
${COMMANDS}
        </div>
        <div style="text-align: center; margin-top: 3rem;">
            <p style="color: var(--secondary); font-size: 1.1rem;">
                Games, unit conversion, maths, the Bitcoin price and more &mdash;
                <a href="/docs/commands/" style="color: var(--secondary)">the full reference</a>.
            </p>
        </div>
    </section>

    <section class="faq">
        <h2 class="section-title glitch">Frequently Asked Questions</h2>
        <p class="section-subtitle">Everything you need to know about Nymbot</p>
        <div class="faq-content">

${FAQ}

        </div>
    </section>

    <section class="protocol" style="padding: 4rem 2rem;">
        <div style="max-width: 800px; margin: 0 auto; text-align: center;">
            <h2 class="section-title glitch">Start Talking</h2>
            <p style="color: var(--secondary); font-size: 1.2rem; margin: 2rem 0;">
                No registration. No subscription. No name on the bill.<br>
                A key on your device, and an assistant that answers to it.
            </p>
            <div class="cta-buttons" style="justify-content: center;">
                <a href="/app" class="btn">Open Nymbot</a>
                <a href="https://github.com/Spl0itable/nymbot" class="btn btn-secondary" target="_blank"
                    rel="noopener">View on GitHub</a>
                <a href="/docs/" class="btn btn-docs">Knowledge Base</a>
            </div>
        </div>
    </section>

${FOOTER}

    <script src="script.js"></script>
</body>

</html>
`;

await writeFile('index.html', html);
console.log('index.html written');
