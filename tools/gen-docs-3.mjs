import { docsPage } from './mkpage.mjs';

const NOTE = `            <p class="legal-note" data-i18n-translated-only>This page is machine-translated for convenience. The English original is the version that applies.</p>`;

await docsPage({
  file: 'pages/docs/credits.html',
  slug: 'docs/credits',
  title: 'Credits and pricing - Nymbot Knowledge Base',
  description: 'How Nymbot credits work: the free daily allowance, two balances, buying over Lightning, what a reply costs, gifting and refunds.',
  body: `            <h1>Credits and pricing</h1>
            <p class="docs-lede">You buy credits with Bitcoin and spend them a reply at a time. No
                subscription, no card, no minimum, and nothing that has to know your name.</p>
${NOTE}

            <h2 id="free">The free daily allowance</h2>
            <p>You do not have to buy anything to start. With an empty balance you get
                <strong>20 replies a day</strong>, on the same model the public Nymbot runs on, and they
                cost nothing. The count is in the toolbar where the balance normally sits, and it resets
                at midnight UTC.</p>
            <p>What the allowance does not cover is anything with a bill of its own: the frontier
                <a href="/docs/models/#pro">Pro models</a>, <a href="/docs/git/">repositories</a>,
                <a href="/docs/media/">pictures, video and speech</a>, and live web search. Those are what
                credits are for.</p>
            <p>It is counted per key <em>and</em> per network. Making a new key is a single tap in the app's
                own gate, so a per-key count on its own would reset every time somebody cleared their site
                data &mdash; the allowance would not be daily, it would be per-wipe. A network gets several
                times what one key does, so a household, an office or a phone network sharing one address
                is not turned away.</p>
            <p>Nothing about that count is stored against you. The address a request arrives from is hashed
                with a server secret and today's date and immediately forgotten; only the hash is written
                down, on a row that has no public key on it and cannot have one. All it can say is how many
                free replies came from one network today, and it forgets that at midnight. It cannot say
                whose they were, and it cannot tell one of your keys from another &mdash; which is the whole
                reason the count works this way rather than the easy way.</p>

            <h2 id="two-balances">Two balances</h2>
            <div class="docs-table-wrap">
                <table>
                    <thead>
                        <tr><th>Balance</th><th>Price</th><th>Spent on</th></tr>
                    </thead>
                    <tbody>
                        <tr><td>Standard credits</td><td>10 sats each</td><td>Auto-routed replies &mdash; the model is chosen per task</td></tr>
                        <tr><td>Pro credits</td><td>100 sats each</td><td>Replies from a specific frontier model you have pinned</td></tr>
                    </tbody>
                </table>
            </div>
            <p>They are separate and neither converts into the other. The <strong>Standard / Pro</strong>
                switch in the toolbar decides which one the conversation is spending;
                <code>?balance</code> shows both, and so does the chat header.</p>

            <h2 id="buying">Buying over Lightning</h2>
            <p><code>?buy</code>, or the <strong>Buy</strong> button, opens a Lightning invoice with a
                Standard/Pro switch. Pay it from any Lightning wallet &mdash; scan the QR, or copy the
                invoice &mdash; and the balance updates within seconds of the payment settling.</p>
            <p>The invoice is not addressed to you in any meaningful sense: it is a payment request, it
                carries no identity, and the credit it produces is attached to your public key by the
                ledger. Nothing about the purchase has to be true about you.</p>
            <p>If the app closes between paying and crediting, the claim is idempotent &mdash; reopen it and
                the credit lands once, not twice.</p>

            <h2 id="what-a-reply-costs">What a reply costs</h2>
            <p><strong>Standard replies</strong> cost one credit for an ordinary answer, and more for a task
                that genuinely needs more work &mdash; a long reasoning route or a search-backed answer. The
                app tells you when a reply cost more than one.</p>
            <p><strong>Pro replies</strong> cost a per-model base of one or two credits, and then scale with
                the length of the reply up to that model's maximum. The maximum is <em>reserved</em> when you
                send the message and only the real cost is charged, so a short answer from an expensive
                model costs the base even though the budget allowed for more.</p>
            <p><code>?model</code> lists every model with its base and its maximum before you commit to
                one. Image and speech generation are charged
                <a href="/docs/media/#pricing">per generation</a> instead.</p>
            <p>A <a href="/docs/git/#cost">repository task</a> can use up to six model calls for one message,
                each billed at the pinned model's price. Only the calls actually made are charged.</p>

            <h2 id="gifting">Gifting and transferring</h2>
            <ul>
                <li><code>?gift @nym#abcd</code> buys credits and puts them straight onto someone else's
                    nym.</li>
                <li><code>?transfer @nym#abcd</code> moves <em>your whole balance</em>, standard and Pro, to
                    another nym. Useful when you rotate keys; irreversible once it lands.</li>
            </ul>
            <p>Both stay on your real nym, because both are about a named account. Moving credits onto a
                <a href="/docs/anonymous/">throwaway key</a> works differently and deliberately &mdash; as
                blind vouchers, so the move cannot be used to link the two.</p>

            <h2 id="refunds">When nothing is charged</h2>
            <p>You are charged for an answer, not an attempt.</p>
            <ul>
                <li>A generation that fails costs nothing.</li>
                <li>A reply that never reaches you costs nothing &mdash; ask again and the turn is
                    replayed, not regenerated. Resending the same message never buys a second answer.</li>
                <li>Local commands &mdash; <code>?help</code>, <code>?balance</code>, <code>?buy</code>,
                    <code>?model</code>, <code>?git</code>, <code>?anon</code>, <code>?clear</code>,
                    <code>?image models</code> &mdash; are free.</li>
                <li>Running out mid-conversation stops the reply before it is generated and tells you, so a
                    low balance never produces a half answer you paid for.</li>
            </ul>`,
});

await docsPage({
  file: 'pages/docs/models.html',
  slug: 'docs/models',
  title: 'Models and routing - Nymbot Knowledge Base',
  description: 'Standard auto-routing, pinning a Pro model, the live model catalog, and reasoning and vision support.',
  body: `            <h1>Models and routing</h1>
            <p class="docs-lede">Two ways to get an answer: let Nymbot choose the model, or choose it
                yourself.</p>
${NOTE}

            <h2 id="standard">Standard: auto-routed</h2>
            <p>On the standard tier your message is classified first &mdash; is this a question, a
                translation, something creative, something that needs current information &mdash; and routed
                to a model suited to it. A quick factual answer does not pay for a reasoning model, and a
                hard one is not answered by a fast one.</p>
            <p>Questions that depend on current information trigger a web search before the answer is
                written, and the sources are listed underneath it.</p>
            <p>This is the cheap, sensible default. Most conversations never need anything else.</p>

            <h2 id="pro">Pro: pin a model</h2>
            <p><code>?model &lt;name&gt;</code>, or the model chip in the toolbar, pins every reply in the
                conversation to one specific frontier model. <code>?model off</code> returns you to standard
                routing.</p>
            <p>Pin one when you want a particular model's judgement, when you are working in a
                <a href="/docs/git/">repository</a> &mdash; which needs Pro &mdash; or when you want the same
                model's voice across a long piece of work.</p>
            <p>Currently available: Claude Fable 5, Claude Opus 5, Claude Sonnet 5, Claude Haiku 4.5,
                GPT-5.6 Sol, GPT-5.4 mini, Gemini 3.1 Pro, Gemini 3.6 Flash, Grok 4.6, Kimi K3, Qwen 3.5 and
                MiniMax M3.</p>

            <h2 id="catalog">The model catalog</h2>
            <p>The picker is generated from a live catalog rather than hard-coded, so the list you see is
                exactly what the server will accept and charge for. Each entry carries its base price, its
                maximum, its context window, and whether it can see images, reason visibly or call tools.</p>
            <p>Models badged as hosted are run on the same infrastructure as the rest of the service and do
                not depend on an upstream provider being reachable. The others are proxied.</p>
            <p>The catalog moves as models are released and retired. A model you pinned that has since gone
                away falls back to standard routing rather than failing, and tells you.</p>

            <h2 id="effort">Asking it to think harder</h2>
            <p>The <strong>Effort</strong> chip on a Pro chat says how much work each reply is worth, and
                <code>?effort</code> sets it by name.</p>
            <ul>
                <li><strong>Normal</strong> &mdash; one pass. The default.</li>
                <li><strong>Careful</strong> &mdash; the model plans the answer before writing it: what is
                    actually being asked, what it depends on, what would make an obvious answer wrong. You
                    never see the plan; you see what it produced.</li>
                <li><strong>Deep</strong> &mdash; it also reads its own answer back against the question and
                    corrects it before you see it.</li>
            </ul>
            <p>Each step is another model call, so a careful reply costs roughly twice a normal one and a
                deep reply roughly three times. The toolbar shows the range before you send, and the
                reservation covers every pass the level could take &mdash; only what was actually used is
                charged.</p>
            <p>A <a href="/docs/git/">repo task</a> ignores the setting. It already runs the model in a loop
                on a budget of its own, and stacking a second budget on top of it would only make the price
                harder to predict.</p>

            <h2 id="reasoning">Reasoning and vision</h2>
            <p>When a model shows its chain of thought &mdash; the standard tier's reasoning route, or a Pro
                model that exposes it &mdash; the reply carries a collapsed
                <strong>&#128173; Reasoning</strong> section above the answer. Tap to read it; it is not
                charged separately from the reply it belongs to.</p>
            <p>Every Claude, GPT, Gemini, Grok and Kimi Pro model can see images, as can the creative and
                translation routes on standard. Put a picture's link in your message and ask about it
                &mdash; see <a href="/docs/chats/#attachments">sending pictures</a>.</p>`,
});

await docsPage({
  file: 'pages/docs/git.html',
  slug: 'docs/git',
  title: 'Working in a git repository - Nymbot Knowledge Base',
  description: 'Connect GitHub, GitLab or Gitea to Nymbot so Pro replies can read your code, and optionally commit and open pull requests.',
  body: `            <h1>Working in a git repository</h1>
            <p class="docs-lede">Pro can work inside one of your repositories the way a coding agent does
                &mdash; reading your actual files, and with writes on, changing them.</p>
${NOTE}

            <h2 id="connecting">Connecting a repository</h2>
            <p><code>?git</code>, or the <strong>Git</strong> chip in the toolbar, connects a provider:
                GitHub, GitLab, or Gitea/Forgejo &mdash; which covers Codeberg and self-hosted instances. It
                takes a scoped personal access token, a repository and a branch. A repository that
                <a href="#ngit">announces itself on Nostr</a> can be pasted in as its address instead.</p>
            <p>You do not have to type the repository's name. Paste the token and choose
                <strong>List what this token can reach</strong>: Nymbot asks the forge what that token can
                see and shows the answer as a list you tick. Ticking connects each one with its default
                branch already filled in, and puts them all in this chat. Anything already connected is
                shown as such rather than offered a second time. That request goes from your device
                straight to the forge &mdash; not through the Nymbot worker &mdash; so the token does not
                travel anywhere it does not already go. A self-hosted forge that refuses cross-origin
                requests simply cannot be listed; type the repository in by hand and everything else
                works the same.</p>
            <p>Once connected, the chip shows the repository name, and messages sent with a
                <a href="/docs/models/#pro">Pro model</a> selected run in that repository's context.
                <code>?git disconnect</code> removes it.</p>

            <h2 id="ngit">Repositories announced on Nostr</h2>
            <p>Some repositories announce themselves on Nostr rather than only on a forge, using
                <a href="https://github.com/nostr-protocol/nips/blob/master/34.md">NIP-34</a> &mdash; the
                protocol behind <a href="https://ngit.dev">ngit</a> and gitworkshop. The announcement is a
                Nostr event carrying the project&rsquo;s name, its maintainers, the relays that collect its
                patches and issues, and the URLs it can be cloned from. A second event says where each
                branch currently points.</p>
            <p>Paste an <code>naddr</code> or a <code>nostr://</code> address into the repository form and
                press <strong>Look it up</strong>. Nymbot reads the announcement off the relays and fills the
                form in: the git host it is cloned from, the repository there, and the branch the project
                itself says is current. You still add a token for that host, because Nostr carries the
                announcement and the git server carries the code.</p>
            <p>Which means the rule is simply where it is cloned from. A repository whose clone URL is on
                GitHub, GitLab, Gitea or Forgejo &mdash; self-hosted included &mdash; is one Nymbot can read.
                One cloned only over <code>git://</code> or ssh has no HTTP API to read files through, and
                Nymbot says so rather than half-connecting. Where the host is self-hosted the provider is a
                guess from its name, and you can correct it before saving.</p>
            <p>A repository added this way is badged <strong>ngit</strong> in the list, and replies call it
                by the name it announces rather than by its path on the mirror.</p>

            <h2 id="what-it-can-do">What it can do</h2>
            <p>A message in repo context runs as a small agent rather than a single completion. The model
                can list directories, read files and search the tree, then answer using what it actually
                found &mdash; so "why does the retry loop give up early" is answered from your code, not
                from a guess about code that looks like yours.</p>
            <p>It sees the branch you connected, at its current head.</p>

            <h2 id="writes">Turning writes on</h2>
            <p><code>?git writes on</code> adds the ability to commit files, create branches and open pull
                or merge requests. Off by default, and worth leaving off until you want it.</p>
            <p>With writes on, ask for a change and you get a branch and a pull request to review rather
                than a patch pasted into chat. Nothing is pushed to your default branch unless that is the
                branch you connected and you asked for it.</p>

            <h2 id="undo">Undoing what a run changed</h2>
            <p>A reply that wrote to your repository says what it touched: the repository, the branch, and
                every file. <strong>Undo these changes</strong> puts them back &mdash; each of those paths is
                read at the commit the branch stood on before the run and committed as it was.</p>
            <p>That is a revert, not a rewrite. Nothing is erased and no history is rewritten: what Nymbot
                did stays in the log, it is simply no longer the state of the branch. Anyone who pulled in
                between keeps a checkout that still works.</p>
            <p>It costs nothing. Undoing touches no model, so it spends no credits &mdash; the access token
                travels with that one request the way it does with every other, and nothing about the
                checkpoint is stored anywhere but your own device.</p>
            <div class="docs-note">
                <span class="docs-note-label">Files only</span>
                <p>A branch or pull request the run opened is listed and left where it is. Closing somebody's
                    pull request on their behalf is not an undo, and deleting a branch other people may have
                    fetched is not either &mdash; do those yourself if you want them gone.</p>
            </div>

            <h2 id="cost">What a repo task costs</h2>
            <p>A repo task uses up to six model calls per message &mdash; look, read, search, answer &mdash;
                each billed at the pinned model's <a href="/docs/credits/#what-a-reply-costs">Pro price</a>.
                Only the calls actually used are charged, so a question answered from one file costs about
                what an ordinary reply costs.</p>
            <p>The app reports the total and the number of calls after each repo task.</p>

            <h2 id="carrying-on">When a task runs out of room</h2>
            <p>A repository task is a loop, not a single answer: the model lists a directory, reads a
                file, searches the tree, reads another, and only then writes. That loop has an
                allowance &mdash; a number of model calls the reply reserved credits for &mdash; because
                an unbounded agent is an unbounded bill.</p>
            <p>When a task uses its allowance with work still to do, Nymbot stops, gives you what it
                has, and says so. Nothing further is charged.</p>
            <p>You can also let it carry on. Set a continuation budget in Settings and Nymbot buys
                another allowance from the same balance when a task runs out, picking up exactly where
                it stopped rather than re-reading the repository from the beginning. It goes one leg at
                a time, each leg saying what it cost, and stops the moment the budget is spent, the task
                is finished, or you press Stop. Choosing &ldquo;until my balance runs out&rdquo; is still
                a ceiling &mdash; it is your balance rather than a number you typed.</p>
            <div class="docs-note">
                <span class="docs-note-label">Note</span>
                <p>The default is to stop and tell you. Nothing continues, and nothing is spent beyond
                    the reply you asked for, unless you have set a budget.</p>
            </div>

            <h2 id="token-safety">About that token</h2>
            <div class="docs-note is-warning">
                <span class="docs-note-label">About that token</span>
                <p>The access token is stored only on your device and is wiped by a
                    <a href="/docs/identity/#panic">panic wipe</a>. It travels to the Nymbot worker with each
                    request, and is never stored server-side or published to relays. Scope it to the one
                    repository you mean to use, and revoke it at your provider when you are done.</p>
            </div>
            <p>Because it is device-local, it does not sync: connect the repository again on a second
                device, with a token scoped for that device if you would rather be able to revoke them
                separately.</p>`,
});

console.log('docs batch 3 written');
