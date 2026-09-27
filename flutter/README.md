# The Nymbot mobile app

The standalone Android and iOS app: many separate conversations with Nymbot,
end-to-end encrypted, paid for in credits.

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

## Where it points

`lib/config.dart` holds the whole answer: the worker is Nymchat's, on
`web.nymchat.app`, and the relay list is the one that worker itself fetches
from. Credits, conversation threads and the anonymous-mode throwaway key are all
keyed to your public key, so signing in to either service with the same key
gives you the same account.

Publishing anywhere other than those relays would produce a wrap the worker can
never fetch and open, so the list is not a preference.

## What came from where

`lib/core/crypto/`, `lib/models/nostr_event.dart` and the signer are copied from
the Nymchat client unchanged. That is deliberate: the gift wraps, the ML-KEM
hybrid and the blind vouchers are a wire format shared with the web app and the
worker, and a reimplementation would be a second thing to keep in step. What is
new here is everything above them.

| Path | What it does |
| --- | --- |
| `lib/services/relay_pool.dart` | Publish, one-shot fetch, and a standing subscription. |
| `lib/services/pq_announce.dart` | Capability announcements: resolving Nymbot's ML-KEM key, and publishing our own. |
| `lib/services/nymbot_api.dart` | The worker client, and the per-action auth events. |
| `lib/services/anon.dart` | Anonymous mode: the throwaway key and the blind vouchers. |
| `lib/services/chat_engine.dart` | One turn, end to end. Also where a conversation's title comes from, and where the preamble that carries a persona, several repositories and a branch's transcript is built. |
| `lib/services/attachments.dart` | Files off the device: text and code inlined into the wire body, images carried beside it. |
| `lib/services/voice.dart` | A reply read back out, through the platform's own text-to-speech engine. |
| `lib/services/transcript.dart` | A conversation as Markdown or plain text, for sharing and for the clipboard. |
| `lib/models/workspace.dart` | Repositories, personas, saved prompts, folders, attachments and the appearance settings. |
| `lib/features/message_bubble.dart` | One message, drawn the way the landing page's phone mockup draws it. |
| `lib/features/nym_avatar.dart` | The identicon and the `adjective_noun#suffix` handle, generated the same way here, in the web app and on the landing page. |
| `lib/features/nym_icons.dart` | The persona icon set and the app's own mark, drawn rather than shipped as a bitmap. |
| `lib/services/profiles.dart` | The account's published kind-0 profile, when it has one, cached on the device. |
| `lib/features/code_highlight.dart` | A small tokeniser for the languages a reply actually comes back in. |
| `lib/state/` | The identity, the on-device store, and the one controller the UI listens to. |
| `lib/features/` | The gate, the chat, the AI toolbar and the sheets. |

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
  One branch connected twice is sent once, so it is not explored twice.
- **Personas and custom instructions** are sent with the first message of a
  chat and never repeated. Six are built in; your own are stored on the device.
- **A prompt library** with `{{blanks}}` the app asks you to fill in.
- **Attachments**: text and code go into the message as a fenced block, images
  travel beside it.
- **Read aloud**: any reply spoken back through the platform's own
  text-to-speech engine.
- **Your Nostr profile**, when the key you signed in with has published one:
  the kind-0 name, picture and nip-05 replace the generated nym in the drawer
  and on your own messages. An anonymous chat never shows it — the throwaway
  key keeps its own generated identity, which is the whole point of the mode.
- **A throwaway key that funds itself.** Anonymous mode can move credits across
  on its own when the key runs low, at a floor and an amount you set.
- **Search** across every message on the device, find within a chat, and saved
  messages pinned out of any conversation.
- **Conversation management**: pin, archive, tag, file in folders, duplicate,
  branch, rename, share the transcript, and export a full backup.
- **Appearance**: five themes, three densities, four text sizes, bubbles or
  blocks, avatars, timestamps, monospace replies, and reduced motion.

## Permissions

One, optional and only asked for when the feature is used:

- `NSPhotoLibraryUsageDescription` for attaching a picture, which is encrypted
  with the rest of the message before it leaves the device.

The Android manifest also declares a `<queries>` entry for the text-to-speech
service. Without it Android 11 and later hides the engine from the app even when
it is installed, and it reports itself unavailable rather than missing.

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
device (Identity → Link). Until then replies come back classical rather than
wrong.

## Languages

`lib/features/i18n/i18n.dart` loads `assets/i18n/<lang>.json` — a
`{ english: translated }` table the site's build writes from the cache all three
surfaces share — and `t('…')` looks the string up. There is no ARB, no codegen
and no generated key: the English sentence IS the key, which is what lets a line
this app and the web app both say be translated once.

New copy is made translatable by wrapping it: `Text(t('Sign in'))`. A whole
sentence at a time, with `{name}` placeholders for the values —

```dart
t('{n} relays', {'n': app.relaysUp})
```

— because a translator handed fragments to join cannot reorder them, and word
order is most of what changes. A `t()` call the extractor cannot read fails the
build rather than shipping English inside a translated screen, so an
interpolated literal is not an option.

`assets/i18n/index.json` is written by `npm run build` at the repository root; a
language appears in the picker only when its pack covers every string. Changing
the language reloads the pack and notifies the controller — no restart.

## What is stored where

Secrets — the identity key, the post-quantum root, the anonymous-mode state —
go to the platform keystore through `flutter_secure_storage`. Conversations and
preferences go to shared preferences: they are already encrypted to the key on
the relays, and keeping them out of the keystore keeps its surface to the things
that must not be readable at rest. Android backups are off entirely.

## Release signing

The release APK is signed with a keystore this repository deliberately does not
contain. `./scripts/generate-keystore.sh` creates it once —
`android/app/nymbot-release-key.jks`, plus the `android/key.properties` that
points Gradle at it and holds its passwords in the clear. Both are gitignored
and must stay that way: the private key in that file *is* Nymbot's identity on
Android, and anyone holding it with its password can sign a build every existing
install will accept as a genuine update.

Losing it is the same problem from the other side, and it is the one that cannot
be undone. Android refuses an update signed by a different key, so a lost
keystore strands every install that already exists: the only route forward is
uninstall and reinstall, which takes the on-device conversation store with it.
There is no reissue and no recovery — not from Google, not from Zapstore. The
key has to outlive the machine it was generated on, which is what the backup is
for.

So, once, immediately after generating it, put all four of these somewhere that
is neither this checkout nor this machine — a password manager entry, or an
encrypted volume kept offline:

- `android/app/nymbot-release-key.jks` itself, as a file attachment. It is a
  couple of kilobytes.
- The **store password** and the **key password**, read out of
  `android/key.properties`. They may be the same string.
- The alias, `nymbot-release`, which `keytool` needs to find the key inside the
  store.
- The SHA-256 fingerprint, which is what `assetlinks.json` pins for App Links
  and what lets you confirm later that a build was signed with the right key:

```sh
keytool -list -v -keystore android/app/nymbot-release-key.jks -alias nymbot-release
```

Restoring on a new machine is the reverse and needs no script: drop the `.jks`
back into `android/app/`, then write `android/key.properties` by hand with the
four `storePassword` / `keyPassword` / `keyAlias` / `storeFile` lines. The
generate script refuses to run when a keystore is already present, precisely so
a restore is never mistaken for a regeneration.

CI signs from the same key without ever committing it — the keystore goes in
base64 and the passwords go in beside it, as encrypted repository secrets:

```sh
base64 -i android/app/nymbot-release-key.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_PASSWORD
gh secret set ANDROID_KEY_ALIAS --body nymbot-release
```

A missing `key.properties` cannot slip through unnoticed: `signingConfigs`
reads it unconditionally (`android/app/build.gradle:32`), so an absent file
leaves `storeFile` null and the build fails outright. What verification catches
is the subtler case — a restore from backup, or a CI run, that signed with the
wrong key:

```sh
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

The certificate it prints should carry the same SHA-256 as the keystore above.

## Not hammering the gateway

A repo task is an agentic loop on the worker, and every tool call in it is
another model call through one shared AI gateway — which limits requests rather
than tokens. Two things this app can do about that, neither of which is reading
the repository itself: the worker builds the file tree it puts in the model's
prompt, and it does that well enough that a second copy from here would only
disagree with it.

- **One turn at a time.** A turn is a whole loop behind a single request, so two
  of them at once is two bursts arriving together. Turns queue; a progress poll,
  which is not a model call, never waits behind one. Comparing two models runs
  its two turns back to back rather than as one double burst.
- **A busy gateway is waited out, not re-asked.** "Rate limit", "too many
  requests", "overloaded", a 429 or a 503 are read as the far end asking for a
  slower rate: the same turn is collected again after 4, then 9, then 16
  seconds, under the same event id the worker de-duplicates on, so nothing is
  paid for twice and the loop does not start over. The waits are interruptible,
  so Stop still stops.

Asking again is the most expensive possible response to a rate limit — the whole
loop runs from the start — which is why the wait is here rather than a message
telling you to retry.

The other half of the cost is the loop's length. One turn is capped at six model
calls, which a task spanning several repositories will use up before it is
finished; the worker then parks its whole conversation and hands back a
continuation token rather than throwing the work away. Spending that token is a
setting, because each leg costs credits: **When a repo task runs out of room**
under Settings → Long tasks. On "Stop and tell me" — the default — a big task
stops part-way with a partial answer and says so; set it to carry on and the
remaining legs run by themselves, each resuming from exactly what the last one
had read. A leg the gateway refuses outright is parked the same way, so a rate
limit costs a pause rather than the whole task.

## Tests

`flutter test` covers the parts worth pinning without a network:

- the gift-wrap round trip, hybrid and classical, and that a stranger's key
  opens neither;
- the blind-voucher math end to end, with a locally-run mint, including that a
  proof from the wrong key is refused;
- conversation titles and the reasoning split;
- the gate, key import, and that a reply renders as markdown rather than source.

The translation pipeline itself is tested at the repository root (`npm test`),
which is where the extractor lives.
