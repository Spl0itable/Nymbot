import { docsPage } from './mkpage.mjs';

const NOTE = `            <p class="legal-note" data-i18n-translated-only>This page is machine-translated for convenience. The English original is the version that applies.</p>`;

await docsPage({
  file: 'pages/docs/chats.html',
  slug: 'docs/chats',
  title: 'Conversations - Nymbot Knowledge Base',
  description: 'How separate Nymbot conversations work: titles, what the model remembers, attachments, clearing history, ghost chats and auto-delete.',
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
                the conversation became about. The same menu is on every row in the sidebar, behind the
                &hellip; button, and it acts on that row's chat: renaming, pinning, archiving, exporting or
                deleting one from the list leaves you reading the one you were already reading.</p>

            <h2 id="context">What Nymbot remembers</h2>
            <p>Inside one conversation, the model sees the turns that came before it, so follow-up questions
                work without repeating yourself. The thread is reconstructed from the encrypted messages
                themselves each turn; there is no plaintext transcript sitting anywhere.</p>
            <p>Older turns fall out of context as the conversation grows &mdash; the model is given the most
                recent stretch of it, not the whole history. What decides how much is a budget rather than a
                fixed number of messages, so a handful of long turns get the room they need instead of each
                being clipped to the same short length. A turn that had to be trimmed says so, rather than
                arriving as a fragment that reads like the whole thing. If an answer starts drifting from
                something you established near the top, restate it or start a fresh chat.</p>
            <p>What does not fall out is your standing context: custom instructions, the repositories in
                scope, and the parts of a <a href="/docs/workspaces/#knowledge-files">workspace</a> that bear
                on what you just asked. Those ride every message, so they still apply on turn fifty.</p>

            <h2 id="branching">Asking a question differently</h2>
            <p><strong>Ask this differently</strong> under any message you sent reopens it for editing.
                What happens next is your choice, and the box is ticked by default: the chat you had stays
                exactly as it is and the new answer arrives on a branch.</p>
            <p>The branch carries everything said before the question you changed, along with the whole
                standing setup &mdash; repositories, persona, workspace, bot, model, effort &mdash; and the
                artifacts those earlier messages produced. It runs on a thread of its own, so the two
                conversations do not see each other.</p>
            <p>Untick the box and it rewrites in place instead, which throws away everything said after
                that message. That was the only behaviour once, and it is still there when you want it
                &mdash; but it is no longer what happens by default, because nothing about it could be
                undone.</p>
            <p><strong>Branch from here</strong> under a reply does the same thing without changing
                anything: a copy of the chat up to that point, to take somewhere else.</p>

            <h2 id="queue">Typing while it is still writing</h2>
            <p>You do not have to wait. Anything typed while a reply is being written waits its turn: it is
                shown above the composer in the order it was typed, and goes as soon as the current one is
                done. Take one back out while it waits, or press <strong>Stop</strong> and nothing behind it
                is sent either.</p>
            <p>Commands are the exception. They cost nothing and happen instantly, so <code>?balance</code>
                or <code>?model</code> run straight away rather than queueing behind a repo task that has
                another eight minutes to go.</p>

            <h2 id="memory">What carries between chats</h2>
            <p>Inside one chat, the model sees the chat. Between chats, what carries is memory: standing
                facts about how you work &mdash; what to call you, what you build, how you want answers
                written.</p>
            <p>They are kept one entry at a time rather than as a rolling summary, because a summary cannot
                be argued with. Open <strong>Memory</strong> in the sidebar and you get a list you can read
                line by line: correct the one that is wrong, throw away the one you never meant to save, and
                write in the ones you would rather not wait to be noticed.</p>
            <p>Facts you mention in passing are noticed as you chat, from a deliberately narrow set of
                patterns that only fire on sentences explicitly about you and explicitly in the present
                &mdash; a question is never one. Anything saved this way says so at the time, with one tap
                to take it back. Turn the noticing off in that panel and <code>?remember</code> still works.</p>
            <p>A memory saved while you are in a <a href="/docs/workspaces/">workspace</a> belongs to that
                workspace, so a fact about one project does not follow you into another. A memory saved
                outside one holds everywhere.</p>
            <p>They live on this device and are searched here, the same way knowledge files are: the few
                that bear on a question travel inside that message. Your name and anything you asked about
                how to answer ride every message, since those apply whatever you are asking about.</p>
            <div class="docs-note is-warning">
                <span class="docs-note-label">Ghost chats</span>
                <p>A <a href="/docs/chats/#ghost-mode">ghost chat</a> neither reads memory nor adds to it. It
                    is not part of a record, and memory is a record.</p>
            </div>

            <h2 id="recall">Reading back what fell out</h2>
            <p>Turns the window could not hold are still listed for the model, one line each, so it knows
                what it is missing rather than answering from the half of the conversation it happens to
                have. A <a href="/docs/models/#pro">Pro</a> reply can then read any of them back in full
                before it answers.</p>
            <p>Those turns are decrypted for the request anyway and were being discarded, so reading one
                back costs no second trip to the relays and nothing is stored to make it possible. What it
                does cost is one more model call, and therefore one more base credit &mdash; on the replies
                that actually look something up, and not on the ones that do not.</p>
            <div class="docs-note">
                <span class="docs-note-label">Why not simply send everything</span>
                <p>A long conversation sent whole would cost more on every single reply, for ever, and the
                    price would rise the longer the chat stayed useful. That is the pricing that makes people
                    start a new chat to save money and throw away the context they were paying for. What a
                    reply costs here tracks what the question needed, not how long you have been talking.</p>
            </div>
            <p>Begin a message with <code>!</code> to send it with no history at all: a one-off question
                inside an existing conversation, without the thread's context colouring the answer or
                inflating the prompt. It stays out of the thread afterwards too, so the tangent you asked to
                keep out does not colour the next answer either. It remains in the chat where you can read
                it &mdash; what changes is only what the model is shown next time.</p>

            <h2 id="writing">Writing your message</h2>
            <p>What you send is markdown, the same as what comes back. A fenced block renders as a block, a
                backticked word as code, a list as a list &mdash; so pasting a snippet into a question reads
                as a snippet rather than as a wall of backticks.</p>
            <p>With the composer focused, <code>Ctrl/Cmd+B</code>, <code>Ctrl/Cmd+I</code> and
                <code>Ctrl/Cmd+E</code> wrap what you have selected in bold, italic or code, and
                <code>Ctrl/Cmd+Shift+E</code> opens a fenced block on its own lines. Pressing the same one
                again on text that already carries the marks takes them off.</p>
            <p>Paste something long &mdash; a log, a file, a stack trace &mdash; and it goes in as an
                attachment instead of filling the composer, measured in lines rather than bytes. The
                question you are asking about it stays readable, and it reaches the model fenced as a block.
                A short paste is left where you put it.</p>

            <h2 id="attachments">Sending pictures</h2>
            <p>Put an image link in your message and ask about it. The worker pulls any picture URLs
                out of what you send and hands them to the model alongside the question, so
                "what is wrong with this diagram? https://…" works as one message.</p>
            <p>Every Claude, GPT, Gemini, Grok and Kimi <a href="/docs/models/#pro">Pro model</a> can see
                images, as can the creative and translation routes on the standard tier. A vision reply
                costs what that model's reply would have cost &mdash; there is no separate charge for
                looking.</p>
            <div class="docs-note">
                <span class="docs-note-label">Note</span>
                <p>Uploading a picture from the device is not in the standalone apps yet; a link is.
                    <a href="https://nymchat.app">Nymchat</a> has the upload, and shares this
                    conversation.</p>
            </div>

            <h2 id="watching">Watching a reply as it is written</h2>
            <p>While a reply is generating, Nymbot reports what it is doing underneath the spinner:
                which model it routed to, what it searched the web for, which files it is reading in
                a <a href="/docs/git/">connected repository</a>, which model call it is on, and the
                model's own reasoning as each call returns.</p>
            <p>That report is scoped to the key that asked for the reply and to that one message. In
                <a href="/docs/anonymous/">anonymous mode</a> the key that asked is the throwaway one,
                so watching a reply reveals nothing the message had not already revealed &mdash; the
                account behind it is no more involved than it was before. Turn it off in Settings and
                you get the plain spinner.</p>

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
            </div>

            <h2 id="ghost-mode">Ghost chats and auto-delete</h2>
            <p>A ghost chat is one that is never written down. Its messages, and any
                <a href="/docs/artifacts/">artifacts</a> it produced, are held in memory and nowhere else,
                and no archived copy is published for it &mdash; so there is nothing to restore on another
                device, and nothing left when you close the app. The message itself still goes to Nymbot,
                encrypted as always; what a ghost chat refuses is the copy that exists to bring a
                conversation back later.</p>
            <p>Turning ghost mode on part-way through moves what has already been said off the device;
                turning it off writes back what is on screen. Neither direction quietly loses anything.</p>
            <p>Separately, <strong>auto-delete</strong> can sweep old conversations for you. Choose a
                window &mdash; a day, a week, a month &mdash; and chats untouched for longer are deleted
                when the app opens. It is off unless you turn it on, and it never takes a pinned chat.</p>`,
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
                        <tr><td><code>?video &lt;description&gt;</code></td><td>Generates a short clip. Needs a Pro model selected.</td></tr>
                        <tr><td><code>?video models</code></td><td>Lists the video generators and their prices. Free.</td></tr>
                        <tr><td><code>?video --model &lt;name&gt; &lt;description&gt;</code></td><td>Picks the video generator.</td></tr>
                        <tr><td><code>?speak &lt;text&gt;</code></td><td>Returns a spoken clip, up to 800 characters.</td></tr>
                    </tbody>
                </table>
            </div>
            <p>See <a href="/docs/media/">images, video and speech</a> for what each generator is good at.</p>

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
  title: 'Images, video and speech - Nymbot Knowledge Base',
  description: 'Generating pictures, video clips and voice with Nymbot, choosing a generator, and what each costs.',
  body: `            <h1>Images, video and speech</h1>
            <p class="docs-lede">Three commands that produce a file rather than a paragraph. All are charged
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

            <h2 id="video">Video</h2>
            <p><code>?video a lighthouse beam sweeping across a storm</code> returns a short clip. It is a
                <a href="/docs/models/#pro">Pro</a> command: every video model available is
                provider-hosted, so unlike <code>?image</code> there is no standard-tier generator to fall
                back on. Select a Pro model first.</p>
            <p><code>?video models</code> lists the generators with their prices and costs nothing.
                <code>?video --model &lt;name&gt; &lt;description&gt;</code> picks one: Veo 3.1, Seedance 2.5,
                Hailuo 2.3, Wan 3.0, Grok Imagine Video, Pixverse v6, LTX-2.5, Vidu Q3, FLUX 3 Video and
                Runway Gen-4.5, among others.</p>
            <p>Send a picture in the same message and the generators that take a reference frame will
                animate it rather than starting from nothing. A clip takes longer than a picture &mdash; a
                render still going after a couple of minutes is given up on, and nothing is charged.</p>

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
                        <tr><td><code>?video</code></td><td>Not available</td><td>10&ndash;30 Pro credits, depending on the generator</td></tr>
                        <tr><td><code>?speak</code></td><td>3 standard credits</td><td>1 Pro credit</td></tr>
                        <tr><td><code>?image models</code>, <code>?video models</code></td><td colspan="2">Free</td></tr>
                    </tbody>
                </table>
            </div>
            <p>Because these are flat per-generation charges, the length of your description does not change
                the price. See <a href="/docs/credits/">credits and pricing</a> for how the two balances
                work.</p>`,
});

console.log('docs batch 2 written');
