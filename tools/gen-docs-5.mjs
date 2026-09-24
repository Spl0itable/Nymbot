import { docsPage } from './mkpage.mjs';

const NOTE = `            <p class="legal-note" data-i18n-translated-only>This page is machine-translated for convenience. The English original is the version that applies.</p>`;

await docsPage({
  file: 'pages/docs/protocol.html',
  slug: 'docs/protocol',
  title: 'Protocol and events - Nymbot Knowledge Base',
  description: 'The Nostr events a Nymbot turn is made of, how a request is authenticated, and how the credit ledger stays honest.',
  body: `            <h1>Protocol and events</h1>
            <p class="docs-lede">What is actually on the wire. Useful if you are auditing the client,
                writing another one, or just want to know that the description above is the truth.</p>
${NOTE}

            <h2 id="nostr">Nostr underneath</h2>
            <p>Nymbot is built on Nostr. Messages are events, identities are keypairs, and delivery is a set
                of relays rather than a server you have to trust. That is why an identity from any other
                Nostr app works here unchanged.</p>
            <p>The events involved:</p>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Kind</th><th>What it is</th></tr></thead>
                    <tbody>
                        <tr><td>1059</td><td>The gift wrap carrying a message, in either direction.</td></tr>
                        <tr><td>14</td><td>The rumor inside it &mdash; unsigned, so it is deniable.</td></tr>
                        <tr><td>13</td><td>The seal, signed by the sender, encrypted to the recipient.</td></tr>
                        <tr><td>30078</td><td>The post-quantum capability announcement carrying a KEM key.</td></tr>
                        <tr><td>27235</td><td>The short-lived auth event that proves a request is yours.</td></tr>
                    </tbody>
                </table>
            </div>

            <h2 id="the-turn">One turn, end to end</h2>
            <ol>
                <li>Your app seals the message to Nymbot's announced keys &mdash; classical and ML-KEM
                    &mdash; wraps it under a single-use key and publishes the wrap to the relays. A copy
                    wrapped to your own key goes out too, so the conversation restores on any device.</li>
                <li>It calls the worker with the wrap's event id and a fresh auth event signed for that one
                    action and endpoint, so a captured signature cannot be replayed against a different
                    request. The message itself never travels as plaintext.</li>
                <li>The worker claims the turn before it fetches, generates or charges anything. Resending
                    the same message replays the first attempt's answer rather than buying a second one
                    &mdash; and two wraps of one rumor count as one question.</li>
                <li>It fetches the wrap from the relays, opens it, checks the seal's signer matches the
                    authenticated key, reconstructs the thread from the previous wraps, and generates.</li>
                <li>The reply is sealed back to your announced keys, published, and handed to your app in
                    the response so it appears without waiting on relay propagation.</li>
            </ol>
            <p>The classification, routing, search and tool calls all happen inside step 4, on the server.
                What comes back is one message.</p>

            <h2 id="ledger">The credit ledger</h2>
            <p>Balances live in a single-writer ledger rather than in ordinary rows, so concurrent spends
                from two devices cannot both succeed against the same credit. Every money operation is
                idempotent and keyed: a claim for a paid invoice credits once no matter how many times it is
                retried, and a voucher redemption resumed after a crash credits once too.</p>
            <p>A spend is authorized by a fresh signature bound to that action, and the amount is reserved
                before generation and settled after, which is how a Pro reply can budget for its maximum and
                charge you only what it used.</p>
            <p>The <a href="/docs/anonymous/#vouchers">voucher tables</a> record issuance and spending
                without recording who, which is the whole point of them.</p>`,
});

await docsPage({
  file: 'pages/docs/troubleshooting.html',
  slug: 'docs/troubleshooting',
  title: 'Troubleshooting - Nymbot Knowledge Base',
  description: 'What to do when a reply does not arrive, a balance looks wrong, a conversation is missing, a repository or connector will not connect, or a server run does not start.',
  body: `            <h1>Troubleshooting</h1>
            <p class="docs-lede">The handful of things that actually go wrong, and what each one usually
                means.</p>
${NOTE}

            <h2 id="no-reply">The reply never arrives</h2>
            <p><strong>"Nymbot is still working on that message."</strong> A long Pro reply, or a
                <a href="/docs/git/">repository task</a>, can outlast the request that asked for it. The
                answer is being generated and is held for you; send the same message again and you collect
                it rather than paying for a second one.</p>
            <p><strong>"Could not fetch your encrypted message from the relays yet."</strong> Your wrap had
                not propagated when the worker went looking. Try again &mdash; nothing was charged.</p>
            <p><strong>Nothing at all.</strong> Check the connection indicator. If the app cannot reach the
                relays it cannot publish your message, and a network that blocks WebSockets &mdash; some
                corporate and hotel networks &mdash; will stop it dead.</p>

            <h2 id="credits-wrong">The balance looks wrong</h2>
            <p><code>?balance</code> asks the server rather than reading a cached number, so start
                there.</p>
            <p>A payment that settled but did not credit is usually a claim interrupted between the two.
                Reopen the purchase and it completes; the claim is idempotent, so you cannot be credited
                twice by retrying.</p>
            <p>If you are in <a href="/docs/anonymous/">anonymous mode</a>, remember the throwaway key has
                its own balance. <code>?balance</code> shows that one while the mode is on, and your nym's
                balance is untouched behind it.</p>
            <p>A reply that cost more than you expected was probably a long Pro reply &mdash; those
                <a href="/docs/credits/#what-a-reply-costs">scale with length</a> &mdash; or a repo task
                that used several model calls. The app reports both.</p>
            <p>A <a href="/docs/server-runs/">server run</a> is charged separately from the reply that asked
                for it, and <a href="/docs/research/">deep research</a> and
                <a href="/docs/team-mode/">Team mode</a> are metered across many model calls. Each shows what
                it cost. While one is going, its maximum is held, so your free Pro balance looks lower until
                it settles.</p>

            <h2 id="history-missing">A conversation is missing</h2>
            <p>On a new device, history is restored from the relays, which takes a moment and depends on the
                relays still holding those wraps. Give it time before concluding it is gone.</p>
            <p>If you are signed in with a different key than the one that had the conversation, you will
                not see it and cannot &mdash; it is encrypted to the other key. Check the nym in the
                header.</p>
            <p>A <a href="/docs/chats/#clearing">cleared</a> conversation or a
                <a href="/docs/identity/#panic">device wipe</a> is not recoverable by anyone.</p>

            <h2 id="git-errors">The repository will not connect</h2>
            <ul>
                <li><strong>"That does not look like a valid token."</strong> The token format did not match
                    the provider you chose. GitHub, GitLab and Gitea all issue different shapes.</li>
                <li><strong>The repository list is empty.</strong> The token is valid but not scoped to any
                    repository, or scoped to an organization that has not approved it.</li>
                <li><strong>It connects but cannot write.</strong> Writes are off by default &mdash;
                    <code>?git writes on</code> &mdash; and the token also needs write scope at the
                    provider.</li>
                <li><strong>It works on one device and not another.</strong> Tokens
                    <a href="/docs/git/#token-safety">sync between your devices</a>, so give a new device a
                    moment after signing in. A repository marked as having no token was disconnected on one of
                    your devices, or was connected from an older version of the app that kept tokens on one
                    device. Add the token again and it syncs from there.</li>
            </ul>

            <h2 id="server-run-errors">A server run did not start</h2>
            <ul>
                <li><strong>"The price went up since this was shown."</strong> The price of a
                    <a href="/docs/server-runs/#price">server run</a> follows the Bitcoin price, and it moved
                    between showing you the price and starting the run. Nothing ran and nothing was charged.
                    Check the new price and run again.</li>
                <li><strong>Not enough Pro credits.</strong> The whole maximum has to be free in your Pro
                    balance before a run starts. The app opens the Pro top-up.</li>
                <li><strong>"Another server run of yours is still going."</strong> One run at a time for each
                    key. Wait for it to finish, or press <strong>Stop</strong> on it.</li>
                <li><strong>"Slow down &mdash; too many requests."</strong> Try again in a minute.</li>
                <li><strong>"Server runs are not available right now."</strong> They are switched off, or the
                    servers could not be reached. Nothing was charged.</li>
                <li><strong>"Stopped at the time limit."</strong> The run used its whole time limit. Choose a
                    longer one, or ask for code that does less at once.</li>
                <li><strong>The connection dropped.</strong> What arrived is shown. The run is settled on the
                    server even if the app lost the connection, and your balance shows the charge.</li>
                <li><strong>In a repository, "That request has expired."</strong> An approval card was left
                    too long. Ask again and Nymbot starts fresh. A repository over 60 MB, packed, is too large
                    for a server run.</li>
            </ul>

            <h2 id="connector-errors">A connector will not connect</h2>
            <ul>
                <li><strong>"Connectors must use https."</strong> or <strong>"That address is local or
                    private."</strong> The worker can reach only public <code>https</code> addresses, so a
                    server on your own machine or network cannot be used.</li>
                <li><strong>"Put credentials in the token or header fields, not in the URL."</strong> Move the
                    token out of the address and into the connector's authentication.</li>
                <li><strong>"The connector could not be reached."</strong> Check the address and the token.
                    The server has to speak MCP over HTTP.</li>
                <li><strong>"Its secret is on another device."</strong> The connector's token has not reached
                    this device, usually because it was added from an older version of the app that kept
                    secrets on one device. Edit it and add the secret here.</li>
                <li><strong>A reply never uses it.</strong> <a href="/docs/connectors/">Connectors</a> need a
                    Pro model pinned, a chat can have at most three turned on, and a tool you unchecked is
                    never offered to the model.</li>
            </ul>

            <h2 id="locked-out">Locked out of an encrypted identity</h2>
            <p><a href="/docs/identity/#encryption-at-rest">Identity encryption</a> has no recovery path.
                That is what makes it worth having, and it means a forgotten passphrase, a lost passkey or
                biometrics that no longer work on the device end that copy of the identity.</p>
            <p><strong>Forgot your passphrase?</strong> or <strong>Lost your passkey?</strong> on the
                unlock screen offers, after a warning, to delete the key and everything else Nymbot keeps on
                the device, and start over.</p>
            <p>If you backed up your <code>nsec</code>, reinstall and sign in with it. If you did not, the
                identity is gone &mdash; which is the moment everyone learns why the backup is the first
                thing this knowledge base tells you to do.</p>`,
});

console.log('docs batch 5 written');
