import { docsPage } from './mkpage.mjs';

const NOTE = `            <p class="legal-note" data-i18n-translated-only>This page is machine-translated for convenience. The English original is the version that applies.</p>`;

await docsPage({
  file: 'pages/docs.html',
  slug: 'docs',
  title: 'Nymbot Knowledge Base',
  description: 'How Nymbot works: an anonymous AI chat with no account \u2014 conversations, credits, models, the git integration, anonymous mode and the encryption underneath.',
  body: `            <h1>Nymbot knowledge base</h1>
            <p class="docs-lede">Nymbot is a private AI assistant. Every message is end-to-end encrypted,
                every reply is paid for in Bitcoin, and there is no account to make &mdash; a key on your
                device is the whole of it.</p>
${NOTE}

            <h2 id="what-nymbot-is">What Nymbot is</h2>
            <p>An assistant you talk to the way you would talk to a person in a messenger. You open a
                conversation, you type, it answers. What is different is underneath.</p>
            <ul>
                <li><strong>There is no sign-up.</strong> A keypair is generated on your device, or you
                    bring one you already have. That key is your identity, your history and your balance.</li>
                <li><strong>Messages are end-to-end encrypted.</strong> Your question and its answer travel
                    as <a href="/docs/encryption/#gift-wraps">gift-wrapped</a> Nostr events, sealed to keys
                    only the two ends hold, with a
                    <a href="/docs/encryption/#post-quantum">post-quantum</a> layer over the classical one.</li>
                <li><strong>Replies are paid for in sats.</strong> No subscription, no card, no invoice with
                    your name on it. You buy <a href="/docs/credits/">credits</a> over Lightning and spend
                    them a reply at a time.</li>
                <li><strong>It can stop knowing who you are.</strong>
                    <a href="/docs/anonymous/">Anonymous mode</a> moves the whole conversation onto a
                    throwaway key and moves your credits across as blind vouchers, so the server bills a
                    message it cannot attribute.</li>
            </ul>
            <p>Under the hood it is the same assistant that lives inside
                <a href="https://nymchat.app">Nymchat</a>, running on the same infrastructure and the same
                key. Buy credits in one, spend them in the other.</p>

            <h2 id="how-to-read-this">How to read this</h2>
            <p>The nav on the left is the whole knowledge base, and the search box at the top filters it by
                heading, so you can jump straight at a term you half remember.</p>
            <p>If you have not used Nymbot yet, <a href="/docs/getting-started/">Getting started</a> is five
                minutes and covers everything you need to send a first message. If you have, the pages you
                are most likely to want are <a href="/docs/credits/">Credits and pricing</a>,
                <a href="/docs/models/">Models and routing</a> and the
                <a href="/docs/commands/">command reference</a>.</p>
            <p>Every page also exists as markdown &mdash; add <code>.md</code> to its address &mdash; and the
                whole site is summarised for agents at <a href="/llms.txt">/llms.txt</a>.</p>

            <h2 id="the-short-version">The short version</h2>
            <div class="docs-table-wrap">
                <table>
                    <thead>
                        <tr><th>You want to</th><th>Do this</th></tr>
                    </thead>
                    <tbody>
                        <tr><td>Start talking</td><td>Open <a href="https://nymbot.ai/app">the app</a> and type. A key is made for you.</td></tr>
                        <tr><td>Start a fresh subject</td><td>New chat. Each one is its own thread with its own <a href="/docs/chats/#titles">title</a>.</td></tr>
                        <tr><td>Top up</td><td><code>?buy</code>, or the <strong>Buy</strong> button in the toolbar.</td></tr>
                        <tr><td>Use a specific frontier model</td><td><code>?model</code>, or the model chip in the toolbar.</td></tr>
                        <tr><td>Work in your code</td><td><code>?git</code> &mdash; see <a href="/docs/git/">the repository page</a>.</td></tr>
                        <tr><td>Make a picture</td><td><code>?image a lighthouse at dusk</code></td></tr>
                        <tr><td>Hide your nym from the server</td><td><code>?anon</code> &mdash; see <a href="/docs/anonymous/">anonymous mode</a>.</td></tr>
                        <tr><td>Check what you have left</td><td><code>?balance</code></td></tr>
                    </tbody>
                </table>
            </div>`,
});

await docsPage({
  file: 'pages/docs/getting-started.html',
  slug: 'docs/getting-started',
  title: 'Getting started - Nymbot Knowledge Base',
  description: 'Open Nymbot, understand what your key is, send a first message and buy your first credits.',
  body: `            <h1>Getting started</h1>
            <p class="docs-lede">From nothing to a first answer. There is no form to fill in, so most of
                this is explaining what just happened.</p>
${NOTE}

            <h2 id="open-it">Open Nymbot</h2>
            <p>The web app is at <a href="https://nymbot.ai/app">nymbot.ai/app</a>. It installs like a
                native app if you want it to &mdash; "Add to Home Screen" on a phone, the install icon in the
                address bar on a desktop &mdash; and works the same either way. There are also
                <a href="/docs/apps/">Android and iOS builds</a>, though not yet in any store.</p>
            <p>The first time it opens it generates a keypair and asks you to pick a nym: a display name,
                not a username. Nobody checks it and nobody reserves it, because it is not what identifies
                you. Your public key is.</p>

            <h2 id="your-key">Your key is your account</h2>
            <p>Nymbot has no user table. The private key sitting in your browser's storage is the whole
                account:</p>
            <ul>
                <li>It signs the messages you send, which is how the server knows a request is really
                    yours.</li>
                <li>Your credit balance is filed under its public half.</li>
                <li>Your conversation history is encrypted to it, so only that key can read it back.</li>
            </ul>
            <p>Which means two things worth taking seriously. <strong>Back it up.</strong> Settings &rarr;
                Identity shows your <code>nsec</code> &mdash; write it down somewhere offline, because
                nobody can reissue it. And <strong>protect it on the device</strong>: turn on
                <a href="/docs/identity/#encryption-at-rest">identity encryption</a> so the key is unreadable
                in storage without your passphrase, biometric or hardware key.</p>
            <p>If you already use <a href="https://nymchat.app">Nymchat</a> or any other Nostr app, sign in
                with that <code>nsec</code> or a browser extension instead, and your existing credits and
                Nymbot history come with you.</p>
            <div class="docs-note">
                <span class="docs-note-label">Note</span>
                <p>Nymbot and Nymchat share one balance and one identity. Buying credits in either tops up
                    the same account, and you can move between the two apps freely.</p>
            </div>

            <h2 id="first-conversation">Your first conversation</h2>
            <p>Press <strong>New chat</strong> and type. The first thing you say names the conversation
                &mdash; see <a href="/docs/chats/#titles">where the titles come from</a> &mdash; and
                everything after it is one continuous thread the model can see.</p>
            <p>Above the composer is the toolbar:</p>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Control</th><th>What it does</th></tr></thead>
                    <tbody>
                        <tr><td><strong>Standard / Pro</strong></td><td>Which <a href="/docs/credits/#two-balances">balance</a> this conversation spends.</td></tr>
                        <tr><td><strong>Model</strong></td><td>Auto-routed, or one frontier model you pin. See <a href="/docs/models/">models</a>.</td></tr>
                        <tr><td><strong>Git</strong></td><td>Connects a <a href="/docs/git/">repository</a> Pro replies can read and edit.</td></tr>
                        <tr><td><strong>Anon</strong></td><td>Moves the chat onto a <a href="/docs/anonymous/">throwaway key</a>.</td></tr>
                        <tr><td><strong>Buy</strong></td><td>Tops up over Lightning.</td></tr>
                    </tbody>
                </table>
            </div>
            <p>Anything starting with <code>?</code> is a command rather than a question &mdash;
                <code>?help</code> is free and handled on your own device. The full list is in the
                <a href="/docs/commands/">command reference</a>.</p>

            <h2 id="buying-credits">Buying credits</h2>
            <p>Replies cost credits, and you start with none. <code>?buy</code>, or the <strong>Buy</strong>
                button, opens a Lightning invoice; pay it from any Lightning wallet and the balance lands in
                a few seconds.</p>
            <p>Standard credits are 10 sats each and buy auto-routed replies. Pro credits are 100 sats each
                and buy replies from a specific frontier model. They are separate balances and neither
                converts into the other. <a href="/docs/credits/">Credits and pricing</a> has the detail,
                including what an individual reply actually costs.</p>`,
});

await docsPage({
  file: 'pages/docs/apps.html',
  slug: 'docs/apps',
  title: 'Apps and platforms - Nymbot Knowledge Base',
  description: 'Nymbot on the web, on Android and on iOS, and how it relates to the assistant inside Nymchat.',
  body: `            <h1>Apps and platforms</h1>
            <p class="docs-lede">The same assistant, the same key and the same balance, wherever you open
                it.</p>
${NOTE}

            <h2 id="web">The web app</h2>
            <p><a href="https://nymbot.ai/app">nymbot.ai/app</a> is a progressive web app: it runs in any
                modern browser and installs to the home screen or dock without a store. Offline it will show
                you everything you have already said &mdash; your history is stored locally, encrypted to
                your key &mdash; but a reply needs the network, since the model is not on your device.</p>
            <p>It is the reference implementation. Every feature described in this knowledge base is there
                first.</p>

            <h2 id="mobile">Android and iOS</h2>
            <p>The mobile app is the same product built natively, so the keystore, the share sheet and the
                system theme behave the way the platform expects. It talks to exactly the same service, and a
                conversation started on a phone is readable on the web and the other way round.</p>
            <div class="docs-note">
                <span class="docs-note-label">Not in the stores yet</span>
                <p>The Android and iOS app is in the
                    <a href="https://github.com/Spl0itable/nymbot">repository</a> and builds from source
                    today; there is no App Store, Play or Zapstore listing to install it from. Until there
                    is, the <a href="https://nymbot.ai/app">web app</a> installs to a home screen and is
                    the same thing.</p>
            </div>
            <p>Where the platform is more restrictive, the app is too: Android's background limits mean a
                long Pro reply finishes when you come back to the app rather than while it is buried.</p>

            <h2 id="one-account">One account everywhere</h2>
            <p>There is nothing to sync, because there is nothing per-device to sync. Your key is the
                account; point a second device at the same <code>nsec</code> and it is the same account,
                with the same balance and the same conversations restored from the relays.</p>
            <p>What does not travel is anything deliberately device-local: the
                <a href="/docs/git/#token-safety">git access token</a>, and whatever unlock factor you chose
                for <a href="/docs/identity/#encryption-at-rest">identity encryption</a>. Both are set up per
                device on purpose.</p>

            <h2 id="nymchat">Nymbot inside Nymchat</h2>
            <p><a href="https://nymchat.app">Nymchat</a> is a full messenger &mdash; public channels, group
                chats, private messages, calls, a Bluetooth mesh &mdash; and Nymbot lives inside it as one
                more conversation, plus a set of <code>?</code> commands that work in any channel.</p>
            <p>This app is that conversation on its own: no channels, no contacts, no mesh. If all you want
                is the assistant, this is the smaller thing. If you want the messenger too, install Nymchat
                and sign in with the same key &mdash; your credits and your Nymbot history are already
                there.</p>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th></th><th>Nymbot</th><th>Nymchat</th></tr></thead>
                    <tbody>
                        <tr><td>Private AI chat</td><td>Yes</td><td>Yes</td></tr>
                        <tr><td>Many separate conversations</td><td>Yes</td><td>One thread</td></tr>
                        <tr><td>AI in public channels</td><td>&mdash;</td><td>Yes, free</td></tr>
                        <tr><td>Messaging people</td><td>&mdash;</td><td>Yes</td></tr>
                        <tr><td>Shared credits</td><td colspan="2">One balance across both</td></tr>
                    </tbody>
                </table>
            </div>`,
});

console.log('docs batch 1 written');
