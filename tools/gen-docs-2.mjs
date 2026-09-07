import { docsPage } from './mkpage.mjs';

const NOTE = `            <p class="legal-note" data-i18n-translated-only>This page is machine-translated for convenience. The English original is the version that applies.</p>`;

await docsPage({
  file: 'pages/docs/chats.html',
  slug: 'docs/chats',
  title: 'Conversations - Nymbot Knowledge Base',
  description: 'How separate Nymbot conversations work: titles, what the model remembers, attachments, and clearing history.',
  body: `            <h1>Conversations</h1>
            <p class="docs-lede">You can keep as many separate chats with Nymbot as you like. Each one is
                its own thread, its own context and its own title.</p>
${NOTE}

            <h2 id="separate-chats">Each chat is its own thread</h2>
            <p>Press <strong>New chat</strong> and you get an empty conversation. Nothing said in one chat is
                visible to the model in another &mdash; a debugging session and a recipe do not bleed into
                each other, and the older one costs you nothing while it sits there.</p>
            <p>Every chat is a private message thread in its own right: the messages are
                <a href="/docs/encryption/">gift-wrapped</a> individually, published to relays, and
                reassembled on whichever device you sign in from. Sign in on a second device and the whole
                list is there.</p>
            <p>The list is sorted by most recent activity. Search filters it by title and by the text of the
                messages inside, which is possible only because the decryption happens on your device
                &mdash; the search never leaves it.</p>

            <h2 id="titles">Where the titles come from</h2>
            <p>A new chat is called <em>New chat</em> until you say something. The first message you send
                becomes its name: the app takes that message, trims it to a short phrase, and puts it in the
                header and in the sidebar.</p>
            <p>Two things follow from that. A conversation that starts "why does this regex backtrack" is
                findable a week later, and the title is chosen entirely on your device &mdash; the server is
                not asked to summarise anything, and never sees the title at all.</p>
            <p>Rename any chat from its header menu if the first thing you asked turned out not to be what
                the conversation became about.</p>

            <h2 id="context">What Nymbot remembers</h2>
            <p>Inside one conversation, the model sees the turns that came before it, so follow-up questions
                work without repeating yourself. The thread is reconstructed from the encrypted messages
                themselves each turn; there is no plaintext transcript sitting anywhere.</p>
            <p>Older turns fall out of context as the conversation grows &mdash; the model is given the most
                recent stretch of it, not the whole history. If an answer starts drifting from something you
                established near the top, restate it or start a fresh chat.</p>
            <p>Begin a message with <code>!</code> to send it with no history at all: a one-off question
                inside an existing conversation, without the thread's context colouring the answer or
                inflating the prompt.</p>

            <h2 id="attachments">Sending pictures</h2>
            <p>Attach an image and ask about it. Every Claude, GPT, Gemini, Grok and Kimi
                <a href="/docs/models/#pro">Pro model</a> can see images, as can the creative and translation
                routes on the standard tier.</p>
            <p>The picture is uploaded and the model is given its address, so a vision reply costs whatever
                that model's reply would have cost &mdash; there is no separate charge for looking.</p>

            <h2 id="clearing">Clearing and deleting</h2>
            <ul>
                <li><strong>Delete a chat</strong> removes it from this device, wipes its archived copies,
                    and tells the server to drop the thread it keeps for context.</li>
                <li><code>?clear</code> empties the current conversation without deleting it: same chat,
                    blank slate, model context reset.</li>
                <li>A <a href="/docs/identity/#panic">panic wipe</a> takes everything at once &mdash; every
                    conversation, your key, and any credits sitting on a
                    <a href="/docs/anonymous/">throwaway key</a>.</li>
            </ul>
            <div class="docs-note is-warning">
                <span class="docs-note-label">Careful</span>
                <p>Deleting is not recoverable. Your history is encrypted to your key and nobody &mdash;
                    including us &mdash; holds a copy that could be handed back.</p>
            </div>`,
});

await docsPage({
  file: 'pages/docs/commands.html',
  slug: 'docs/commands',
  title: 'Command reference - Nymbot Knowledge Base',
  description: 'Every Nymbot command: credits, model routing, image and speech generation, the git integration, knowledge lookups and games.',
  body: `            <h1>Command reference</h1>
            <p class="docs-lede">Anything beginning with <code>?</code> is a command. <code>?help</code>
                lists them in the app, free of charge.</p>
${NOTE}

            <h2 id="how-commands-work">How commands work</h2>
            <p>Type a command as an ordinary message. Some are handled entirely on your device and cost
                nothing &mdash; <code>?help</code>, <code>?balance</code>, <code>?buy</code>,
                <code>?model</code>, <code>?git</code>, <code>?anon</code>, <code>?clear</code>. The rest go
                to the server and are charged like any other reply.</p>
            <p>Commands work in your own language: if the app is running in Spanish, the Spanish form of a
                command is recognised and folded back to its canonical name before it is sent.</p>
            <p>Anything that is <em>not</em> a command is simply a question, answered by whichever
                <a href="/docs/models/">model</a> the conversation is set to.</p>

            <h2 id="account">Account and credits</h2>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Command</th><th>Does</th></tr></thead>
                    <tbody>
                        <tr><td><code>?help</code></td><td>A free, local guide to tiers, pricing and setup.</td></tr>
                        <tr><td><code>?balance</code></td><td>Your standard and Pro balances.</td></tr>
                        <tr><td><code>?buy</code></td><td>Buys credits over Lightning, with a Standard/Pro switch.</td></tr>
                        <tr><td><code>?gift @nym</code></td><td>Gifts credits to another nym.</td></tr>
                        <tr><td><code>?transfer @nym</code></td><td>Moves your whole balance, standard and Pro, to another nym.</td></tr>
                        <tr><td><code>?anon</code></td><td><a href="/docs/anonymous/">Anonymous mode</a>: chat from a throwaway key.</td></tr>
                        <tr><td><code>?clear</code></td><td>Empties the current conversation and resets its context.</td></tr>
                    </tbody>
                </table>
            </div>

            <h2 id="routing">Routing and tools</h2>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Command</th><th>Does</th></tr></thead>
                    <tbody>
                        <tr><td><code>?model</code></td><td>Lists the Pro models with their prices.</td></tr>
                        <tr><td><code>?model &lt;name&gt;</code></td><td>Pins every reply in this chat to that model.</td></tr>
                        <tr><td><code>?model off</code></td><td>Back to standard auto-routing.</td></tr>
                        <tr><td><code>?git</code></td><td>Connects a <a href="/docs/git/">repository</a>.</td></tr>
                        <tr><td><code>?git writes on</code></td><td>Lets it commit, branch and open pull requests.</td></tr>
                        <tr><td><code>!question</code></td><td>Not a command &mdash; a leading <code>!</code> sends this message with no history.</td></tr>
                    </tbody>
                </table>
            </div>

            <h2 id="making-things">Making things</h2>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Command</th><th>Does</th></tr></thead>
                    <tbody>
                        <tr><td><code>?image &lt;description&gt;</code></td><td>Generates a picture.</td></tr>
                        <tr><td><code>?image models</code></td><td>Lists the generators and their prices. Free.</td></tr>
                        <tr><td><code>?image --model &lt;name&gt; &lt;description&gt;</code></td><td>Picks the generator. Needs a Pro model selected.</td></tr>
                        <tr><td><code>?speak &lt;text&gt;</code></td><td>Returns a spoken clip, up to 800 characters.</td></tr>
                    </tbody>
                </table>
            </div>
            <p>See <a href="/docs/media/">images and speech</a> for what each generator is good at.</p>

            <h2 id="knowledge">Knowledge and utility</h2>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Command</th><th>Does</th></tr></thead>
                    <tbody>
                        <tr><td><code>?ask &lt;question&gt;</code></td><td>Asks the AI. Plain text does the same.</td></tr>
                        <tr><td><code>?define &lt;word&gt;</code></td><td>Definition, part of speech and example usage.</td></tr>
                        <tr><td><code>?translate &lt;text&gt;</code></td><td>Translates, detecting the source language.</td></tr>
                        <tr><td><code>?news</code></td><td>Breaking news headlines.</td></tr>
                        <tr><td><code>?math &lt;expression&gt;</code></td><td>Calculates it.</td></tr>
                        <tr><td><code>?units 10 km to mi</code></td><td>Converts units.</td></tr>
                        <tr><td><code>?time</code></td><td>UTC time and the Unix timestamp.</td></tr>
                        <tr><td><code>?btc</code></td><td>The Bitcoin price.</td></tr>
                    </tbody>
                </table>
            </div>
            <p>Questions that need current information trigger a web search automatically; the sources are
                listed under the answer.</p>

            <h2 id="games">Games</h2>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Command</th><th>Does</th></tr></thead>
                    <tbody>
                        <tr><td><code>?trivia [category]</code></td><td>general, history, science, crypto or nostr.</td></tr>
                        <tr><td><code>?joke</code></td><td>A fresh joke.</td></tr>
                        <tr><td><code>?riddle</code></td><td>A riddle &mdash; reply to answer.</td></tr>
                        <tr><td><code>?wordplay [mode]</code></td><td>wordle, anagram or scramble &mdash; reply to guess.</td></tr>
                        <tr><td><code>?flip</code></td><td>Flips a coin.</td></tr>
                        <tr><td><code>?8ball &lt;question&gt;</code></td><td>Magic 8-ball.</td></tr>
                        <tr><td><code>?pick a b c</code></td><td>Picks one at random.</td></tr>
                    </tbody>
                </table>
            </div>`,
});

await docsPage({
  file: 'pages/docs/media.html',
  slug: 'docs/media',
  title: 'Images and speech - Nymbot Knowledge Base',
  description: 'Generating pictures and voice clips with Nymbot, choosing a generator, and what each costs.',
  body: `            <h1>Images and speech</h1>
            <p class="docs-lede">Two commands that produce a file rather than a paragraph. Both are charged
                per generation rather than by length, and a failed generation costs nothing.</p>
${NOTE}

            <h2 id="images">Generating images</h2>
            <p><code>?image a lighthouse at dusk, long exposure</code> returns a picture. It arrives in the
                conversation like any other message, encrypted the same way, and you can save it from
                there.</p>
            <p>On the standard tier this uses the built-in generator. With a
                <a href="/docs/models/#pro">Pro model</a> selected you get the frontier generators
                instead.</p>

            <h2 id="generators">Choosing a generator</h2>
            <p><code>?image models</code> lists what is available with prices, and costs nothing. With a Pro
                model selected, <code>?image --model &lt;name&gt; &lt;description&gt;</code> picks one:
                Nano Banana Pro, Nano Banana 2, Imagen 4, FLUX 2 Max, FLUX 2 Pro, Seedream 5 Pro,
                GPT Image 2, Grok Imagine and Recraft v4 Pro.</p>
            <p>They differ in what they are good at rather than in quality &mdash; text rendered inside the
                image, photographic realism, illustration, and how literally each takes a long prompt. If
                one misreads a description, another usually will not.</p>

            <h2 id="speech">Speech</h2>
            <p><code>?speak &lt;text&gt;</code> returns a spoken clip of up to 800 characters. Longer text is
                refused rather than truncated, so you never pay for half a sentence.</p>

            <h2 id="pricing">What they cost</h2>
            <div class="docs-table-wrap">
                <table>
                    <thead>
                        <tr><th>Command</th><th>Standard</th><th>With a Pro model selected</th></tr>
                    </thead>
                    <tbody>
                        <tr><td><code>?image</code></td><td>5 standard credits</td><td>2&ndash;3 Pro credits, depending on the generator</td></tr>
                        <tr><td><code>?speak</code></td><td>3 standard credits</td><td>1 Pro credit</td></tr>
                        <tr><td><code>?image models</code></td><td colspan="2">Free</td></tr>
                    </tbody>
                </table>
            </div>
            <p>Because these are flat per-generation charges, the length of your description does not change
                the price. See <a href="/docs/credits/">credits and pricing</a> for how the two balances
                work.</p>`,
});

console.log('docs batch 2 written');
