import { docsPage } from './mkpage.mjs';

const NOTE = `            <p class="legal-note" data-i18n-translated-only>This page is machine-translated for convenience. The English original is the version that applies.</p>`;

await docsPage({
  file: 'pages/docs/documents.html',
  slug: 'docs/documents',
  title: 'PDFs and long documents - Nymbot Knowledge Base',
  description: 'Attaching PDFs, Word documents and large files: read on your device, searched per question, with the pages used shown under each message.',
  body: `            <h1>PDFs and long documents</h1>
            <p class="docs-lede">Attach a PDF, a Word document or a large file and ask about it. It is read on
                your device, and each question sends only the parts that answer it.</p>
${NOTE}

            <h2 id="attaching">What you can attach</h2>
            <p>The attach button in the composer takes PDFs, Word documents (<code>.docx</code>), plain
                text, code, CSV and TSV, JSON, Markdown and HTML, as well as pictures. A PDF's text is
                pulled out on your device; nothing is uploaded to be converted.</p>
            <p>A short file goes into the message whole, fenced as a block, the same way a long paste does.
                A long one is handled differently, and that is what the rest of this page is about.</p>

            <h2 id="searched">Long documents are searched, not sent whole</h2>
            <p>A document too long to fit in a message is split on your device into passages of about
                1,500 characters, following its pages and paragraphs. The passages are kept on the device
                with the chat.</p>
            <p>Each time you ask something, the app ranks those passages against your question and sends
                the ones that match best, along with an outline of the document and a note telling the model
                that it searched the document rather than read all of it. So the model knows when an answer
                might be somewhere it was not shown.</p>
            <p>Later questions in the same chat are ranked again against the same passages, so you can keep
                asking about different parts of the document without attaching it again. It stays until you
                remove it.</p>
            <div class="docs-note">
                <span class="docs-note-label">Why not send it all</span>
                <p>A model can only hold so much at once, and a long document sent whole would crowd out the
                    conversation and cost more on every reply. Sending the passages that bear on the question
                    keeps the answer focused and the price close to an ordinary reply.</p>
            </div>

            <h2 id="pages-used">Seeing which pages were used</h2>
            <p>Every message that drew on a long document says so underneath: which document was searched
                and which of its pages (or, for a file without pages, which parts) were sent. If the answer
                seems to be missing something, that line tells you what the model actually saw. Ask about a
                specific page or section and the next question sends that part.</p>
            <p>The chat also lists every document it is searching, each with a
                <strong>Remove from this chat</strong> button.</p>

            <h2 id="limits">Limits</h2>
            <ul>
                <li>A file can be up to 50 MB, and up to 8 MB once its text is pulled out.</li>
                <li>A chat can hold up to 20 documents.</li>
                <li>A scanned PDF with no text in it cannot be read, and neither can a password-protected
                    one. The app says which it is.</li>
                <li>Pictures are separate: see <a href="/docs/chats/#attachments">sending pictures</a>.</li>
            </ul>
            <p>For files that a whole run of chats should share, put them in a
                <a href="/docs/workspaces/#knowledge-files">workspace</a> instead. They are searched the same
                way, on your device, for every chat in it.</p>`,
});

await docsPage({
  file: 'pages/docs/research.html',
  slug: 'docs/research',
  title: 'Deep research - Nymbot Knowledge Base',
  description: 'Deep research in Nymbot: a Pro model plans questions, searches the web in rounds, reads the best pages and writes a report with numbered sources.',
  body: `            <h1>Deep research</h1>
            <p class="docs-lede">One message becomes a research task: Nymbot plans the questions to answer,
                searches and reads the web in several rounds, and writes a long report with sources you can
                open.</p>
${NOTE}

            <h2 id="starting">Starting a research task</h2>
            <p>Turn on the <strong>Research</strong> chip in the toolbar and send your question, or start the
                message with <code>?research</code>. The chip turns itself off after one message, so the next
                thing you send is an ordinary reply again.</p>
            <p>Research needs a <a href="/docs/models/#pro">Pro model</a> pinned, because it makes many
                searches and model calls. Without one, the app says so and sends nothing. Before you send, the
                composer shows which model will do the work, what it will probably cost and the most it can
                cost.</p>

            <h2 id="what-it-does">What it does</h2>
            <ol>
                <li><strong>Plans.</strong> The model breaks your question into the smaller questions a
                    good answer has to cover.</li>
                <li><strong>Searches.</strong> It searches the web for them in up to four rounds, with
                    different phrasings each time, including news searches for anything recent.</li>
                <li><strong>Reads.</strong> It opens the most promising pages, up to twenty in all, and notes
                    what each one says against the question it answers.</li>
                <li><strong>Writes.</strong> It turns those notes into a structured report.</li>
            </ol>
            <p>While it works, the reply shows each step as it happens: the questions it planned, what it
                searched for, which site it is reading and how many findings it has noted.</p>
            <p>A long task can pause partway and carry on in a second step. The app picks it back up by
                itself, within the same maximum price.</p>

            <h2 id="the-report">The report</h2>
            <p>The report cites its sources with numbers, and the numbers match the sources list under it in
                order, so <em>[3]</em> is the third source. When there are more than two sources the list is
                folded into one row of site icons; tap it to open the numbered cards.</p>
            <p>A report is only as good as what it found. Open the sources behind any claim that matters to
                you.</p>

            <h2 id="cost">What it costs</h2>
            <p>Research is paid from your Pro balance and metered on the tokens it actually uses, across every
                step, like any other <a href="/docs/credits/#what-a-reply-costs">Pro reply</a>. It never costs
                more than the maximum the composer showed.</p>
            <ul>
                <li>If your Pro balance cannot cover that maximum, it is refused before anything runs.</li>
                <li>A research task that fails is not charged.</li>
                <li>A chat's <a href="/docs/credits/#caps">spending cap</a> applies to it the same way it
                    applies to any reply.</li>
            </ul>
            <p>For bigger questions there is also <a href="/docs/team-mode/">Team mode</a>, which splits the
                research between several models working at once.</p>

            <h2 id="tasks-pane">The Tasks pane</h2>
            <p>The checklist button at the top of the chat opens its <strong>Tasks</strong> pane, which lists
                the chat's research as an outline, newest first: the questions it planned to answer, each
                search, the sources it read with their site icons, and the report it wrote, with the step it
                is on marked while it runs. Tap a step to jump to its place in the chat. The outline stays
                with the chat after the research finishes.</p>`,
});

await docsPage({
  file: 'pages/docs/connectors.html',
  slug: 'docs/connectors',
  title: 'Connectors (MCP) - Nymbot Knowledge Base',
  description: 'Connect outside tools to Nymbot over MCP: adding a connector, approving each tool call, Always allow, and how connector tokens are kept.',
  body: `            <h1>Connectors (MCP)</h1>
            <p class="docs-lede">A connector gives a Pro model tools from another service, over the Model
                Context Protocol. Nothing runs without your say-so unless you choose otherwise.</p>
${NOTE}

            <h2 id="what-they-are">What is a connector</h2>
            <p>Many services now publish an MCP server: an address that lists tools a model can call, such
                as searching an issue tracker, reading a calendar or querying a database. Add one to Nymbot and
                a <a href="/docs/models/#pro">Pro</a> reply can use those tools while it answers.</p>
            <p>The Nymbot worker is what talks to the server, so the server sees the worker rather than your
                device. What a tool returns is passed to the model marked as outside data, and the model is
                told never to follow instructions inside it.</p>
            <p>Connectors need a Pro model pinned. Standard and free replies do not use them.</p>

            <h2 id="adding">Adding one</h2>
            <p>Open <strong>Connectors</strong> from the menu or the toolbar chip and add one with a name and
                the server's address. The address has to be <code>https</code> and publicly reachable; a
                local or private address is refused, because the worker could not reach it. For sign-in,
                choose no authentication, a bearer token, or a custom header. Keep credentials in those
                fields rather than in the address.</p>
            <p>Nymbot connects to the server and lists the tools it offers. Uncheck any tool you do not want
                Nymbot to have. Each tool also shows what the server says about it: that it only reads, or
                that it can delete things.</p>
            <p>A connector you add is available to every chat. Pick which ones a chat uses from the chip, up
                to three at a time.</p>

            <h2 id="approving">Approving a tool call</h2>
            <p>When the model wants to use a tool, the reply pauses and shows a card: which connector,
                which tool, and exactly what it would send. You choose:</p>
            <ul>
                <li><strong>Allow once</strong> runs that one call, and the reply carries on from where it
                    stopped.</li>
                <li><strong>Always allow this tool</strong> runs it and stops asking about that tool on
                    that connector from now on.</li>
                <li><strong>Deny</strong> runs nothing. The reply carries on without it.</li>
            </ul>
            <p>A card left too long expires. Ask again and Nymbot starts fresh. If carrying on could go past
                the chat's <a href="/docs/credits/#caps">spending cap</a>, it stops instead.</p>

            <h2 id="always-allow">Letting a tool run without asking</h2>
            <p>In the connector's settings, each tool has an <strong>Always allow</strong> switch, and
                <strong>Always allow all tools</strong> covers the whole connector. Tools you allow this way
                run without a card.</p>
            <div class="docs-note is-warning">
                <span class="docs-note-label">Always asks</span>
                <p>A tool the server marks as able to change or delete things always asks, whatever you have
                    allowed. It cannot be allowed ahead of time, and its card says why.</p>
            </div>

            <h2 id="secrets">Where the secrets live</h2>
            <p>A connector's token, header value and address are kept on your devices. They sync between
                your devices inside your end-to-end encrypted settings, sealed with your key, so the server
                stores only a copy it cannot read. That also means a chat that uses a connector works on every
                device you sign in on, without setting it up again.</p>
            <p>The secret travels to the worker with each request that uses the connector, because the worker
                is what calls the server. It is not stored there. With
                <a href="/docs/identity/#encryption-at-rest">identity encryption</a> on, it is encrypted on
                the device too. Removing a connector removes it, and its secrets, from your other devices as
                well.</p>`,
});

await docsPage({
  file: 'pages/docs/team-mode.html',
  slug: 'docs/team-mode',
  title: 'Team mode - Nymbot Knowledge Base',
  description: 'Team mode in Nymbot: your pinned Pro model oversees two to four worker models on deep research and repository tasks, billed as one metered total.',
  body: `            <h1>Team mode</h1>
            <p class="docs-lede">For a big research question or a large change to a repository, Nymbot can
                split the work between several models at once, with your own model in charge.</p>
${NOTE}

            <h2 id="what-it-is">What is Team mode</h2>
            <p>In Team mode, your pinned <a href="/docs/models/#pro">Pro model</a> becomes the
                <em>overseer</em>. It splits the task, hands the parts to two to four <em>workers</em>, and
                puts their work together. The workers all run on one model that you choose, which can be a
                cheaper one than the overseer.</p>
            <p>Team mode is for two kinds of work only: <a href="/docs/research/">deep research</a> and
                tasks in a <a href="/docs/git/">connected repository</a>. A message that is neither is not
                sent; turn Research on or connect a repository, or send it without Team mode.</p>
            <p>Without a Pro model pinned to act as the overseer, Team mode is refused and nothing is
                sent.</p>

            <p>Team mode is set per chat. With a Pro model pinned, a <strong>Team</strong> chip appears in
                the chat's toolbar whenever the next message would be deep research (the
                <strong>Research</strong> chip is on) or a repository task (a repository is connected to the
                chat). It is off until you set it up. Tap it to open the <strong>Team mode</strong> sheet:</p>
            <ul>
                <li><strong>Number of workers</strong>: 2, 3 or 4. The default is 3.</li>
                <li><strong>Worker model</strong>: the model every worker runs on. The app suggests a cheaper,
                    faster one, the lowest-priced metered model from the same maker as your pinned model when
                    there is one. Tap <strong>Change</strong> to pick another from the model list.</li>
                <li>A price line that updates as you change either one: <strong>Up to N Pro credits ·
                    usually about M</strong>. The first number is the most the message can cost, and the
                    second is what a team like this usually costs.</li>
            </ul>
            <p>Tap <strong>Save</strong> and the chip lights up and reads <strong>Team of 3</strong> (or
                however many workers you chose). From then on, research messages and repository tasks in
                that chat are sent to a team. Open the sheet again and tap <strong>Turn off</strong> to go
                back to a single model. If the chat has connectors or server runs on, the sheet says the
                overseer can use them and that each call waits for you to allow it.</p>

            <h2 id="research">A team on deep research</h2>
            <p>The overseer breaks the question into sub-questions and gives each worker its own share. The
                workers research them in parallel, each running a few searches of its own and reading what
                they find.</p>
            <p>The overseer then reconciles what they found and checks where they contradict each other. If
                one sub-question came back weak, it can send that one back to be researched again, once.
                Then it writes the report itself, with sources, as in an ordinary
                <a href="/docs/research/#the-report">research report</a>.</p>

            <h2 id="repositories">A team in a repository</h2>
            <p>The overseer first looks around the repository, reading without changing anything. It then
                splits the change into parts, each with its own files, so no two workers touch the same file.
                A worker can only list, read and search the repository and edit or write its own files; it
                cannot commit, open branches or pull requests, or use anything else.</p>
            <p>When the workers are done, the overseer reviews the combined change. If one part is not right,
                it can send that part back to be redone, once. A worker that fails has its edits rolled
                back.</p>
            <p>From there it is the same as any repository task: the overseer commits the usual way, or the
                changes are held for you to review first if the repository
                <a href="/docs/git/#writes">asks before committing</a>.</p>

            <h2 id="approvals">Connectors and server runs</h2>
            <p>The overseer can use the chat's <a href="/docs/connectors/">connectors</a> and, in a
                repository task with <a href="/docs/server-runs/">server runs</a> on, run commands on a Nymbot
                server. It can do this while it plans, while it reviews the workers' change, and before it
                splits a research question. Workers never get connectors or server runs.</p>
            <p>Every connector call and every server run the overseer wants stops the team and shows the
                usual approval card in the reply, marked as coming from the team lead. This happens every
                time, even for a connector tool you set to <strong>Always allow</strong> in other chats, so
                that card has no <strong>Always allow this tool</strong> button. Allow it and the team
                carries on from exactly where it stopped; deny or decline it and the overseer is told and
                carries on without it. Either way, the workers' finished work is kept, nothing is run twice,
                and you are not charged again for what already ran.</p>
            <p>A server run is charged on its own, for the time it actually runs, on top of the team's
                cost. When a chat has a spending cap, a run is only offered if it fits in what the cap leaves
                after the team's maximum.</p>
            <p>Letting the overseer use tools adds a few of its steps to the maximum shown on the Team mode
                sheet.</p>

            <h2 id="cost">What it costs</h2>
            <p>A team costs the metered total of every model involved: the overseer plus every worker, each
                metered at its own model's <a href="/docs/credits/#what-a-reply-costs">Pro price</a>. Before you send, the
                app shows the most the task can cost: the overseer's budget plus each worker's. That maximum
                is held from your Pro balance, you are charged only for what was actually used, and the rest
                is released.</p>
            <ul>
                <li>If your Pro balance cannot cover the maximum, nothing is sent.</li>
                <li>If the maximum is more than a chat's <a href="/docs/credits/#caps">spending cap</a>
                    allows for one reply, nothing is sent and nothing is charged.</li>
                <li>Each worker has its own budget. One that reaches it stops and hands back what it has so
                    far.</li>
                <li>A worker that fails is not charged, and a team task that fails is not charged at
                    all.</li>
                <li>A long task can pause and carry on in another step, within the same maximum.</li>
            </ul>
            <p>If a chat has a spending cap, the app checks the team's maximum against it before sending, and
                asks first if it could go over, just as it does for any other message. When a team is
                refused, the chat says <strong>Team mode did not start</strong> and why, gives your message
                back, and nothing is charged.</p>

            <h2 id="progress">Watching the team work</h2>
            <p>While a team works, the reply shows a lane for the overseer, labeled <strong>Lead</strong>, and
                one for each worker, labeled <strong>Worker 1</strong>, <strong>Worker 2</strong> and so on,
                so you can follow what each of them is doing: searching, reading, editing, finished, stopped
                at its own budget, or failed.</p>
            <p>If the model provider starts limiting how fast the team can go, the remaining workers run one
                at a time instead of all at once, which takes longer.</p>
            <p>Under the finished reply, a short <strong>Team</strong> summary lists the Lead and each worker,
                with the model it ran on, the Pro credits it used, and whether it was <strong>done</strong>,
                <strong>stopped</strong> or <strong>failed</strong>. It also says when the workers had to run
                one at a time. The price on the reply is the total for the whole team; tap it to see the
                breakdown, with a <strong>Team lead</strong> row and one row for each worker.</p>

            <h2 id="tasks-pane">The Tasks pane</h2>
            <p>The checklist button at the top of the chat opens its <strong>Tasks</strong> pane: beside the
                chat on a wide screen, as a sheet on a phone. While a team works, the button shows it is
                running, and the pane lays the work out as an outline, newest turn first: the Lead's plan,
                each worker's part with the model it runs on, its cost and whether it is done, stopped or
                failed, then the Lead's review and final steps. A connector call or server run the Lead
                asks for is listed with its approval, and you can allow or decline it right there, exactly
                as on the card in the chat. <strong>Stop</strong> stops the running reply. Tap any step to
                jump to its place in the chat. The outline is kept with the chat's messages, so it is still
                there after the work finishes and on your other devices.</p>`,
});

await docsPage({
  file: 'pages/docs/sandbox.html',
  slug: 'docs/sandbox',
  title: 'Running code on your device - Nymbot Knowledge Base',
  description: 'The Run button on Python and JavaScript code blocks: code runs in a sandbox on your device, with no network, and nothing leaves unless you send it.',
  body: `            <h1>Running code on your device</h1>
            <p class="docs-lede">Python and JavaScript in a reply can be run right where they are, in a
                sandbox on your own device. It is free, and nothing leaves the device.</p>
${NOTE}

            <h2 id="run-button">The Run button</h2>
            <p>Python and JavaScript code blocks in Nymbot's replies have a <strong>Run</strong> button.
                Press it and the code runs in a sandbox inside the app: a locked-down frame that cannot see
                your keys, your chats or the rest of the app, running in the background so a runaway loop
                never freezes anything.</p>
            <p>JavaScript starts at once. Python is loaded onto your device from Nymbot's own site the
                first time you run something, about 14 MB plus any libraries the code imports, and starts
                faster after that.</p>
            <p>For other languages, or for code that needs the internet or more time, use
                <a href="/docs/server-runs/">Run on server</a> instead.</p>

            <h2 id="what-comes-back">What comes back</h2>
            <p>The results appear under the code block: what it printed, any errors, and the value of the
                last line. Tables are shown as tables, charts are drawn as pictures, and files the code wrote
                get a <strong>Save</strong> button.</p>
            <p><strong>Send output to Nymbot</strong> puts the output in the composer, so you can ask about
                it. It is not sent until you send it.</p>

            <h2 id="files">Using attached files</h2>
            <p>The text of the documents attached to the chat is available to the code as files, by name,
                so you can attach a CSV and ask for code that reads it. The files are handed to the sandbox on
                your device and are not uploaded anywhere.</p>

            <h2 id="limits">What it cannot do</h2>
            <ul>
                <li><strong>No network.</strong> The code cannot fetch web pages, call APIs or install
                    packages from the internet. Python can import only the libraries Nymbot serves for
                    it.</li>
                <li><strong>30 seconds.</strong> A run that takes longer is stopped and its sandbox thrown
                    away.</li>
                <li><strong>A fresh sandbox per chat.</strong> Moving to another chat throws the old sandbox
                    away, so nothing from one chat's runs is left for another's.</li>
                <li><strong>Only what the device can do.</strong> It runs in the app on your device, so heavy
                    work is limited by your device's speed and memory.</li>
            </ul>
            <p>What the code works on, and what it produces, stays on your device.</p>`,
});

await docsPage({
  file: 'pages/docs/server-runs.html',
  slug: 'docs/server-runs',
  title: 'Running code on a server - Nymbot Knowledge Base',
  description: 'Server runs in Nymbot: run a code block or a repository command in a fresh, isolated container, priced up front and billed per 10 seconds in Pro credits.',
  body: `            <h1>Running code on a server</h1>
            <p class="docs-lede">When code needs more than your device can give it &mdash; another
                language, packages from the internet, more time &mdash; Nymbot can run it on a server of its
                own, in a container made for that one run.</p>
${NOTE}

            <h2 id="what-it-is">What is a server run</h2>
            <p>A server run starts a fresh container, puts your code in it, runs it, sends back what it
                printed and destroys the container. You see the most it can cost before it starts, and you
                pay from your <a href="/docs/credits/#two-balances">Pro balance</a> for the time it actually
                ran.</p>
            <p>There are two ways in: <strong>Run on server</strong> on a code block, and server runs that
                Nymbot asks for while it works in a
                <a href="#in-a-repository">repository</a>.</p>
            <p>For quick Python or JavaScript that needs nothing from the internet, the free
                <a href="/docs/sandbox/">sandbox on your device</a> is usually enough.</p>

            <h2 id="code-blocks">Running a code block</h2>
            <p>Python, JavaScript, TypeScript, shell, Go, Rust, Java and Dart code blocks in a reply have a
                <strong>Run on server</strong> button, whenever server runs are available. It opens a sheet
                showing:</p>
            <ul>
                <li>the <a href="#images">image</a> the code will run on,</li>
                <li>a time limit to choose: 1, 5 or 15 minutes,</li>
                <li>the most the run can cost, in Pro credits, for that time limit,</li>
                <li>and, if the chat has files attached, a box to include them. They go only if you check
                    it.</li>
            </ul>
            <p>Press <strong>Run</strong> and the output streams in under the code block as it arrives:
                what it printed, the exit code, how long it ran, any files it wrote (each with a
                <strong>Save</strong> button), and what it was charged.</p>
            <p><strong>Stop</strong> ends the run at any point. The server is shut down right away and you
                pay only for the time it ran. Stopped before the server started, it costs nothing.</p>
            <p>In an <a href="/docs/anonymous/">Anonymous Mode</a> chat the run is paid from the throwaway
                key's Pro credits, and attached files are never included.</p>

            <h2 id="images">Languages and images</h2>
            <p>Each language runs on an image, a ready-made system with the tools that language needs.
                Bigger images run on bigger servers and cost more per minute.</p>
            <div class="docs-table-wrap">
                <table>
                    <thead><tr><th>Image</th><th>Used for</th><th>What it contains</th><th>Server</th></tr></thead>
                    <tbody>
                        <tr><td>Python</td><td>Python</td><td>Python 3.12 with pip, venv, build tools and git; numpy, pandas and pytest already installed</td><td>0.5 CPU, 4 GB memory</td></tr>
                        <tr><td>Node.js</td><td>JavaScript, TypeScript</td><td>Node.js 22 with npm, pnpm and yarn, plus Python 3, make and a C++ compiler</td><td>0.5 CPU, 4 GB memory</td></tr>
                        <tr><td>Polyglot</td><td>Shell, Go, Rust, Java</td><td>bash, C and C++ build tools, Python 3, Node.js, Go, Rust with cargo, and Java 17</td><td>1 CPU, 6 GB memory</td></tr>
                        <tr><td>Flutter</td><td>Dart</td><td>Flutter 3.32 and Dart</td><td>2 CPUs, 8 GB memory</td></tr>
                    </tbody>
                </table>
            </div>

            <h2 id="price">What it costs</h2>
            <p>Server time is billed in steps of 10 seconds, from asking for the server to shutting it down,
                with 10 seconds as the least a run can cost. The rate is what the server of that size costs
                Nymbot, plus a margin, converted to Pro credits at the current Bitcoin price.</p>
            <ul>
                <li><strong>The price is shown up front, as a maximum.</strong> It is the whole time limit at
                    that rate. You are never charged more, and a run that finishes early costs less.</li>
                <li><strong>The maximum is held while the run is going.</strong> When it ends, the actual
                    charge is taken and the rest is released.</li>
                <li><strong>A run that fails to start is free.</strong></li>
                <li><strong>Spending caps apply.</strong> A run that could go past a chat's
                    <a href="/docs/credits/#caps">spending cap</a> asks first, the same way a reply does.</li>
            </ul>
            <p>Because the price follows the Bitcoin price, it can move between the moment you see it and the
                moment you press Run. If it went up, nothing runs: the sheet opens again with the new price
                for you to check.</p>

            <h2 id="in-a-repository">Server runs in a repository</h2>
            <p>In a chat with a <a href="/docs/git/">repository</a> connected, the <strong>Server
                runs</strong> chip lets Nymbot ask to run commands against your code, such as installing
                the dependencies and running the tests after a change. It is off until you turn it on, per
                chat.</p>
            <p>Each time the model wants to run something, the reply pauses and shows a card with the image,
                the full command, the time limit and the most it can cost, plus which repository when the
                chat has several. Nothing runs until you answer:</p>
            <ul>
                <li><strong>Allow once</strong> runs that one command. It runs against the repository with the
                    edits the reply has made so far, and the model gets back the exit code, the end of the
                    output and the list of files the command changed. Then the reply carries on.</li>
                <li><strong>Decline</strong> runs nothing and costs nothing. The reply carries on without
                    it.</li>
            </ul>
            <p>Every run asks. Each one is charged separately from the reply, and the reply lists the runs it
                made and what each cost. If a run could go past the chat's
                <a href="/docs/credits/#caps">spending cap</a>, it is refused before you are asked.</p>
            <p>Files a command changes on the server stay there and are thrown away with the container. They
                are not written to your repository. Changes to the repository come only from the reply's own
                edits.</p>

            <h2 id="isolation">What is isolated</h2>
            <ul>
                <li><strong>A fresh container for every run.</strong> Nothing is shared with another run or
                    another person, and the container is destroyed when the run ends, whether it succeeded or
                    failed.</li>
                <li><strong>No internet except package registries.</strong> The container can download from
                    the places packages come from: PyPI, npm and yarn, pub.dev and Google's storage for
                    Flutter and Dart, the Go module proxy, crates.io, Maven Central, and GitHub for git
                    dependencies and release downloads. It can only download. It cannot send anything to them
                    or reach any other address.</li>
                <li><strong>Only what you chose goes in.</strong> The code, the files you included, or the
                    repository's files. Your keys, your git token and your chats never enter the
                    container.</li>
                <li><strong>Output is treated as untrusted.</strong> In a repository, what a run prints is
                    shown to the model marked as outside data, and it is told never to follow instructions
                    inside it.</li>
            </ul>

            <h2 id="limits">Limits</h2>
            <ul>
                <li>One server run at a time for each key. Starting a second one while the first is still
                    going is refused.</li>
                <li>Time limits of 1, 5 or 15 minutes for a code block. A repository run can ask for up to
                    15 minutes, or 20 on the Flutter image.</li>
                <li>Up to 1 MB of code, and up to 200 attached files totaling 20 MB.</li>
                <li>A repository of up to 60 MB, packed.</li>
                <li>Up to 256 KB of output. Anything past that is dropped, and the run says so.</li>
                <li>Up to 200 files, 8 MB in all, handed back to save.</li>
            </ul>
            <p>Server runs can be switched off for maintenance, as a whole or one image at a time. When they
                are off, the <strong>Run on server</strong> button and the chip are not shown.</p>

            <h2 id="tasks-pane">The Tasks pane</h2>
            <p>In a repository chat, the checklist button at the top of the chat opens its
                <strong>Tasks</strong> pane. It lists what each turn did, newest first: the files it read and
                edited, commits, changes staged for your review, and every server run with its command,
                image, time, cost and exit status. A server run waiting for your approval can be allowed or
                declined from the pane, the same as from its card, and a running reply can be stopped there.
                The outline stays with the chat after the work finishes.</p>`,
});

console.log('docs batch 6 written');
