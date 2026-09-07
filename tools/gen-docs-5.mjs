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
            <p>A spend is authorised by a fresh signature bound to that action, and the amount is reserved
                before generation and settled after, which is how a Pro reply can budget for its maximum and
                charge you only what it used.</p>
            <p>The <a href="/docs/anonymous/#vouchers">voucher tables</a> record issuance and spending
                without recording who, which is the whole point of them.</p>`,
});

await docsPage({
  file: 'pages/docs/troubleshooting.html',
  slug: 'docs/troubleshooting',
  title: 'Troubleshooting - Nymbot Knowledge Base',
  description: 'What to do when a reply does not arrive, a balance looks wrong, a conversation is missing, or a repository will not connect.',
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

            <h2 id="history-missing">A conversation is missing</h2>
            <p>On a new device, history is restored from the relays, which takes a moment and depends on the
                relays still holding those wraps. Give it time before concluding it is gone.</p>
            <p>If you are signed in with a different key than the one that had the conversation, you will
                not see it and cannot &mdash; it is encrypted to the other key. Check the nym in the
                header.</p>
            <p>A <a href="/docs/chats/#clearing">cleared</a> conversation or a
                <a href="/docs/identity/#panic">panic wipe</a> is not recoverable by anyone.</p>

            <h2 id="git-errors">The repository will not connect</h2>
            <ul>
                <li><strong>"That does not look like a valid token."</strong> The token format did not match
                    the provider you chose. GitHub, GitLab and Gitea all issue different shapes.</li>
                <li><strong>The repository list is empty.</strong> The token is valid but not scoped to any
                    repository, or scoped to an organisation that has not approved it.</li>
                <li><strong>It connects but cannot write.</strong> Writes are off by default &mdash;
                    <code>?git writes on</code> &mdash; and the token also needs write scope at the
                    provider.</li>
                <li><strong>It works on one device and not another.</strong> The token is
                    <a href="/docs/git/#token-safety">device-local by design</a>. Connect again there.</li>
            </ul>

            <h2 id="locked-out">Locked out of an encrypted identity</h2>
            <p><a href="/docs/identity/#encryption-at-rest">Identity encryption</a> has no recovery path.
                That is what makes it worth having, and it means a forgotten passphrase, a wiped biometric
                enrolment or a lost hardware key ends that copy of the identity.</p>
            <p>If you backed up your <code>nsec</code>, reinstall and sign in with it. If you did not, the
                identity is gone &mdash; which is the moment everyone learns why the backup is the first
                thing this knowledge base tells you to do.</p>`,
});

console.log('docs batch 5 written');
