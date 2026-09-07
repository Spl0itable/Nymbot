# The Nymbot web app

A standalone PWA: many separate conversations with Nymbot, end-to-end
encrypted, paid for in credits. Served at `nymbot.ai/app`.

It has no build step. Every file here is what the browser loads, which is also
what makes it auditable — you can read exactly what happens to your key.

## Where it points

`js/config.js` holds the whole answer: the worker is Nymchat's, on
`web.nymchat.app`, and the relay list is the one that worker itself fetches
from. That is deliberate. Credits, conversation threads and the anonymous-mode
throwaway key are all keyed to your public key, so signing in to either service
with the same key gives you the same account.

Publishing anywhere other than those relays would produce a wrap the worker can
never fetch and open, so the list is not a preference.

## The pieces

| File | What it does |
| --- | --- |
| `js/vendor/` | `nostr-tools`, `ml-kem` and `nym-crypto`, copied verbatim from the Nymchat client so both apps agree on the wire format byte for byte. |
| `js/identity.js` | The key. A local nsec, or a NIP-07 extension. Also the post-quantum root the ML-KEM keypair is derived from. |
| `js/relays.js` | Publish, one-shot fetch, and a standing subscription. |
| `js/pq.js` | Capability announcements: resolving Nymbot's ML-KEM key, and publishing our own. |
| `js/wire.js` | Building and opening NIP-59 gift wraps, for both logins. |
| `js/api.js` | The worker client, and the per-action auth events. |
| `js/anon.js` | Anonymous mode: the throwaway key and the blind vouchers. |
| `js/chat.js` | One turn, end to end. Also where a conversation's title comes from, and where the preamble that carries a persona, several repositories and a branch's transcript is built. |
| `js/avatar.js` | The identicon and the `adjective_noun#suffix` handle, generated the same way here, in the Flutter app and on the landing page, so one key reads as one person everywhere. |
| `js/profile.js` | The account's published kind-0 profile, when it has one: the name and picture it already tells the world, cached on the device. |
| `js/icons.js` | Every icon the app draws, including the app's own mark. No emoji anywhere in the chrome. |
| `js/highlight.js` | A small tokeniser for the languages a reply actually comes back in. |
| `js/markdown.js` | Reply rendering: tables, task lists, callouts, code blocks with copy/wrap/save/preview, and images. |
| `js/attach.js` | Files off the device: text and code inlined into the wire body, images shrunk and carried beside it. |
| `js/speech.js` | Dictation into the composer, and a reply read back out. |
| `js/commands.js` | Every `?` command, and the matcher the composer and the palette share. |
| `js/export.js` | A conversation as Markdown, plain text or JSON, and the backup that restores all of them. |
| `js/qr.js` | A byte-mode QR encoder, so an invoice is rendered here rather than sent somewhere to be drawn. |
| `js/ui.js` | The shell. |

## What the app can do

The chat surface, beyond sending a message:

- **Messages** carry an avatar, a nym, the model that answered, the reasoning
  behind it, what it cost and when it landed — the same shape the phone mockup
  on the landing page shows. Each one can be copied, quoted, rated, saved,
  read aloud, deleted, edited and resent, asked again, or branched into a new
  chat that carries the transcript up to that point.
- **Several repositories at once.** Repositories are connected once and ticked
  per chat; a chat with more than one gets a preamble naming them, so a reply
  can say which one it means. `?git list`, `?repo <name>`, `?git writes on`.
- **Personas and custom instructions** are sent with the first message of a
  chat and never repeated. Six are built in; your own are stored on the device.
- **A prompt library** with `{{blanks}}` the app asks you to fill in.
- **Attachments**: text and code go into the message as a fenced block, images
  are shrunk and travel beside it. Drag, paste or pick them.
- **Voice** in both directions, where the browser has it: dictation into the
  composer, and any reply read back out.
- **Your Nostr profile**, when the key you signed in with has published one:
  the kind-0 name, picture and nip-05 replace the generated nym in the sidebar
  and on your own messages. An anonymous chat never shows it — the throwaway
  key keeps its own generated identity, which is the whole point of the mode.
- **A throwaway key that funds itself.** Anonymous mode can move credits across
  on its own when the key runs low, at a floor and an amount you set, so the
  mode does not mean topping a key up by hand before every chat.
- **A command palette** on `⌘K`, search across every message on `⌘⇧F`, find
  within a chat on `⌘F`, and a shortcut for everything else — `?shortcuts`.
- **Conversation management**: pin, archive, tag, file in folders, duplicate,
  branch, rename, export as Markdown / JSON / text, and import a backup.
- **Appearance**: five themes, three densities, four text sizes, bubbles or
  blocks, avatars, timestamps, monospace replies, line numbers, code wrapping,
  reduced motion, and a typewriter reveal.

## How separate conversations work

The worker keeps one thread per pubkey, but scopes a reply's context to the
messages carrying the same `nymthread` marker. So a conversation here is a
random 32-byte root id, set on every rumor it contains; the worker's history
filter does the rest, and two chats never see each other's turns.

Clearing a chat mints a new root id, which is what actually resets the context.

## Post-quantum keys across two apps

The ML-KEM keypair comes from a root generated independently of the signing key,
and the capability announcement (kind 30078, `d=nym-pq`) is *replaceable* — one
per pubkey. So if you use both this app and Nymchat, both must derive the same
root, or each would publish over the other's key and strand messages sealed to
it.

The app therefore reads the account's existing announcement before publishing:
if it advertises a key this device cannot derive, it does **not** publish, marks
the identity locked, and asks you to paste the `nympq1…` code from the other
device (Identity → link). Until then replies come back classical rather than
wrong.

## Languages

`js/i18n.js` fetches `/app/i18n/<lang>.json` — a `{ english: translated }` table
the site's build writes from the shared cache — and applies it to the DOM at
boot. There is no per-language build: the app is one page, and the pack is the
only thing that changes.

New copy in the markup is picked up automatically; copy this app writes at
runtime is marked at the call site with `t('…')`, which is the same marker the
extractor reads, so the two cannot drift. An element whose text is a value
rather than prose (`placeholder="owner/repo"`) carries `data-i18n-skip`.

A language appears in the picker only when its pack covers every string, and a
missing or unreadable pack leaves the app in English rather than half-translated.
Run `npm run i18n` at the repository root to fill the cache; see the root README.

## Testing

There is no test runner here; the crypto it depends on is tested in
nym-staging. What is worth checking by hand after a change:

- the gate: create a key, reload, the shell comes back;
- two chats do not share context (`Store.conversations()[n].rootId` differ);
- `?help`, `?balance`, `?buy`, `?model`, `?git`, `?anon`, `?clear` never reach
  the network;
- an invoice QR scans.

`npm run test:browser` at the repository root drives the translation path in a
real Chromium against a synthetic pack, which is the part that cannot be checked
without a DOM. `npm run test:mobile` walks every screen here — the gate, the
shell, the drawer, each sheet — at 320 and 390 px.

## On a phone

The layout is one breakpoint at 720px: below it the conversation list becomes a
drawer over the chat, above it a column beside it. Three things are less obvious
and are pinned by `npm run test:mobile`:

- The ASCII wordmark on the gate is 61 monospace columns wide. Its font size
  scales with the viewport below ~480px so the whole logo stays on screen —
  without that the card it sits in is sized by the `<pre>` and pushes its own
  buttons off the right of a phone.
- Form fields are 16px on a touch screen. Anything smaller makes iOS Safari
  zoom the page in when the field takes focus, and it does not zoom back.
- The drawer covers the hamburger that opened it, so it carries its own close
  button, and is capped at 82vw so the strip of scrim beside it stays wide
  enough to tap. Escape and picking a chat close it too. Without a visible
  control the only way out is picking a chat, which is not a way out at all if
  you opened the drawer to look rather than to choose.

The toolbar scrolls sideways by design — there are more chips than a phone is
wide — and the Buy chip is last, so the test checks it can actually be reached.
