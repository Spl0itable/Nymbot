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
| `lib/services/chat_engine.dart` | One turn, end to end. Also where a conversation's title comes from. |
| `lib/state/` | The identity, the on-device store, and the one controller the UI listens to. |
| `lib/features/` | The gate, the chat, the AI toolbar and the sheets. |

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
