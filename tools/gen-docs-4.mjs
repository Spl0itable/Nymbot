import { docsPage } from './mkpage.mjs';

const NOTE = `            <p class="legal-note" data-i18n-translated-only>This page is machine-translated for convenience. The English original is the version that applies.</p>`;

await docsPage({
  file: 'pages/docs/encryption.html',
  slug: 'docs/encryption',
  title: 'Encryption - Nymbot Knowledge Base',
  description: 'How Nymbot messages are encrypted: gift wraps, the post-quantum hybrid layer, and exactly what the server can see.',
  body: `            <h1>Encryption</h1>
            <p class="docs-lede">Your questions and its answers are end-to-end encrypted, with a
                post-quantum layer over the classical one. This page is about what that actually
                protects.</p>
${NOTE}

            <h2 id="end-to-end">End-to-end by default</h2>
            <p>There is no setting to turn on. Every message in every conversation is encrypted on your
                device before it goes anywhere, and decrypted on the other end. The relays that carry it
                cannot read it, and neither can anything in between.</p>
            <p>"The other end" here is the Nymbot service, which has to read your question in order to
                answer it. End-to-end means nobody <em>else</em> can &mdash; it does not and cannot mean the
                assistant answers something it never saw. <a href="/docs/anonymous/">Anonymous mode</a> is
                the answer to the different question of whether it should know <em>who</em> asked.</p>

            <h2 id="gift-wraps">Gift wraps</h2>
            <p>Messages travel as Nostr gift wraps. Each one is three layers:</p>
            <ul>
                <li>a <strong>rumor</strong> &mdash; the message itself, unsigned, so it can never be proved
                    to a third party;</li>
                <li>a <strong>seal</strong>, encrypted to the recipient and signed by the sender, which is
                    how the recipient knows who sent it;</li>
                <li>a <strong>wrap</strong>, encrypted and signed by a single-use throwaway key, which is
                    all a relay ever sees.</li>
            </ul>
            <p>So a relay holding your traffic sees an event from a key that exists only for that message,
                addressed to a key it cannot connect to anything else, with a random timestamp. Metadata
                analysis over the wraps gets very little.</p>
            <p>A copy of each message is also wrapped to your own key, which is how your history restores on
                a new device from the relays rather than from any server-side transcript.</p>

            <h2 id="post-quantum">Post-quantum hybrid</h2>
            <p>The classical layer is elliptic-curve. A large enough quantum computer breaks that
                retroactively &mdash; traffic captured today, decrypted years later. So the encryption is
                <em>hybrid</em>: an ML-KEM key encapsulation is combined with the classical exchange, and an
                attacker has to break both to read anything.</p>
            <p>ML-KEM is the NIST-standardised lattice KEM. Combining rather than replacing is deliberate:
                if the lattice assumption turns out to be wrong, you still have the elliptic curve, and the
                other way round.</p>
            <p>Nymbot publishes a signed capability announcement carrying its KEM key, so your app can seal
                to it without a lookup race that would quietly leave a message classical-only. Your app
                publishes one too, which is how replies come back hybrid.</p>

            <h2 id="what-the-server-sees">What the server sees</h2>
            <p>Being precise about this matters more than being reassuring about it.</p>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Thing</th><th>Normally</th><th>In <a href="/docs/anonymous/">anonymous mode</a></th></tr></thead>
                    <tbody>
                        <tr><td>Your message text</td><td>Read, to answer it</td><td>Read, to answer it</td></tr>
                        <tr><td>Which key asked</td><td>Your nym's public key</td><td>A throwaway key</td></tr>
                        <tr><td>Which key is charged</td><td>Your nym</td><td>The throwaway key</td></tr>
                        <tr><td>Your conversation title</td><td>Never sent</td><td>Never sent</td></tr>
                        <tr><td>Your private key</td><td>Never leaves the device</td><td>Never leaves the device</td></tr>
                        <tr><td>Your <a href="/docs/git/#token-safety">git token</a></td><td>Passed per request, never stored</td><td>Same</td></tr>
                        <tr><td>Your IP address</td><td>Seen by relays and the worker</td><td>Same &mdash; use Tor or a VPN if that matters</td></tr>
                    </tbody>
                </table>
            </div>
            <p>Conversation titles are generated on your device, which is why they are one of the few things
                about your usage that never crosses the wire at all.</p>`,
});

await docsPage({
  file: 'pages/docs/anonymous.html',
  slug: 'docs/anonymous',
  title: 'Anonymous mode - Nymbot Knowledge Base',
  description: 'Chat with Nymbot from a throwaway key, and move credits across as blind vouchers the server signs without seeing.',
  body: `            <h1>Anonymous mode</h1>
            <p class="docs-lede">Encryption was never the gap. Attribution was. Anonymous mode makes the
                server able to charge a message without being able to learn whose credits it is
                charging.</p>
${NOTE}

            <h2 id="the-gap">The gap it closes</h2>
            <p>The chat is <a href="/docs/encryption/">end-to-end encrypted</a>, but the service still knows
                which public key is talking to it. The seal inside each gift wrap is signed by your identity
                key; your credit row, your conversation thread and the turn de-duplication all hang off that
                key; and the archived copy of each reply is addressed to it.</p>
            <p>So anyone holding the bot's private key could enumerate who used the paid chat, and anyone
                with the database could do it without the key. Nothing there is a decryption failure. It is
                simply that your name is on the bill.</p>

            <h2 id="throwaway-key">The throwaway key</h2>
            <p>The <strong>Anon</strong> chip, or <code>?anon</code>, generates a keypair on your device and
                moves the whole conversation onto it. From then on the rumor, the seal and the request
                signature are all that key &mdash; your identity key signs nothing in this conversation at
                all.</p>
            <p>Replies stay <a href="/docs/encryption/#post-quantum">hybrid post-quantum</a>: the throwaway
                key carries its own KEM key, derived from a root generated independently of the signing key,
                so publishing one does not weaken the other.</p>
            <p>While it is on, read receipts, typing indicators, reactions and edits to Nymbot are held
                back. Each of those would otherwise carry your real signature into the same conversation and
                undo the whole thing. If your app cannot honour that &mdash; a locked vault, state not yet
                restored &mdash; it refuses to send rather than quietly falling back to your identity
                key.</p>
            <p>The throwaway key is stored under <a href="/docs/identity/#encryption-at-rest">identity
                encryption</a> and syncs to your other devices, so the conversation and its balance follow
                you. Rotating it keeps the previous keys around for a while so their history stays readable
                and their balance stays sweepable.</p>

            <h2 id="vouchers">Blind credit vouchers</h2>
            <p>Simply transferring credits to the throwaway key would hand the server the link the mode
                exists to break. So credits move as <strong>blind vouchers</strong>, in the Chaumian style a
                Cashu mint uses.</p>
            <ol>
                <li>Your app picks a random secret and blinds it with a random factor.</li>
                <li>Authenticated as your nym, it asks the server to sign the blinded value. The server
                    debits your balance and signs something it cannot read.</li>
                <li>Each signature comes with a proof that the published signing key was the one used. Your
                    app verifies it, and refuses the whole move if it does not check out &mdash; an
                    unprovable signature is a tagging vector, not a cosmetic problem.</li>
                <li>Your app unblinds. The result is a valid token that looks like nothing the server has
                    seen.</li>
                <li>Later, authenticated as the throwaway key, it presents the token. The server verifies
                    it, checks it has not been spent, and credits the key &mdash; with nothing to match it
                    against.</li>
            </ol>
            <p>The tables record that a voucher was issued and that a voucher was spent. Neither records
                who. That link is what the blinding destroys, and storing it would put it straight back.</p>
            <p>The keyset is published, and your app pins it and warns you if it changes &mdash; a
                per-user keyset is exactly how a mint would tag its users. You can also skip the move
                entirely and buy credits straight onto the throwaway key with <code>?buy</code>.</p>

            <h2 id="limits">What it does not hide</h2>
            <p>Being honest about the edges is the only way the rest of it is worth anything.</p>
            <ul>
                <li><strong>The relays see one connection publishing both identities' events.</strong> If
                    that is in your threat model, use Tor or a VPN.</li>
                <li><strong>Rotating the key and carrying the balance over</strong> shows the server one
                    anonymous key paying another.</li>
                <li><strong>A conversation is a conversation.</strong> Every message under one throwaway key
                    is linked to the others by construction &mdash; the assistant needs the thread as
                    context.</li>
                <li><strong>What you write can identify you.</strong> No amount of key hygiene helps if the
                    question names your employer.</li>
                <li><code>?gift</code> and <code>?transfer</code> stay on your real nym, because both are
                    about a named account.</li>
            </ul>
            <div class="docs-note is-warning">
                <span class="docs-note-label">Careful</span>
                <p>Credits on a throwaway key live and die with that key. A
                    <a href="/docs/identity/#panic">panic wipe</a> takes it and anything left on it.</p>
            </div>`,
});

await docsPage({
  file: 'pages/docs/identity.html',
  slug: 'docs/identity',
  title: 'Identity and login - Nymbot Knowledge Base',
  description: 'Keys instead of accounts, ways to sign in, encrypting your identity at rest, and the panic wipe.',
  body: `            <h1>Identity and login</h1>
            <p class="docs-lede">There is no account, no email and no password. There is a key, and
                everything else follows from how well you look after it.</p>
${NOTE}

            <h2 id="nsec">Keys, not accounts</h2>
            <p>Your identity is a Nostr keypair. The public half (an <code>npub</code>) is what the service
                knows you by; the private half (an <code>nsec</code>) stays on your device and signs on your
                behalf.</p>
            <p>Your nym &mdash; the display name you picked &mdash; is decoration. The four characters after
                it are derived from your public key, and they are the part that actually distinguishes one
                <code>alice</code> from another.</p>
            <div class="docs-note is-warning">
                <span class="docs-note-label">Back it up</span>
                <p>Nobody can reissue your key. Lose it and you lose your history and any credits on it.
                    Copy the <code>nsec</code> somewhere offline the first day you use the app.</p>
            </div>

            <h2 id="signing-in">Ways to sign in</h2>
            <ul>
                <li><strong>Generate one.</strong> The default on a fresh install.</li>
                <li><strong>Paste an <code>nsec</code>.</strong> Brings an existing identity &mdash; from
                    <a href="https://nymchat.app">Nymchat</a> or any other Nostr app &mdash; with its
                    credits and its Nymbot history.</li>
                <li><strong>A browser extension</strong> (NIP-07). The key stays in the extension and never
                    reaches the page; the app asks it to sign.</li>
                <li><strong>A remote signer</strong> (NIP-46), if you keep your key on another device.</li>
            </ul>
            <p>Signing in with the same key on a second device gives you the same account. Nothing has to be
                migrated, because nothing lives anywhere but the key.</p>

            <h2 id="encryption-at-rest">Identity encryption</h2>
            <p>Optional protection for the stored key, so it cannot be read out of local storage without
                unlocking. You pick the factor per device: a passphrase, a biometric, or a hardware security
                key.</p>
            <p>No password, salt or credential is ever synced. Only an on/off preference travels, so you can
                choose to set encryption up on a new device rather than have it assumed.</p>
            <p>It also covers the <a href="/docs/anonymous/">anonymous mode</a> throwaway key and its
                vouchers. Your <a href="/docs/git/#token-safety">git access token</a> is device-local too,
                for the same reason.</p>

            <h2 id="panic">Panic wipe</h2>
            <p>Press and hold the panic control and everything local is destroyed immediately: your key,
                every conversation, the git token, the throwaway key and any credits left on it.</p>
            <p>It is not a logout and there is no confirmation dialog to talk yourself out of. If you have
                backed up your <code>nsec</code> you can come back to the same account later; if you have
                not, that identity is gone.</p>`,
});

console.log('docs batch 4 written');
