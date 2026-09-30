# Nymbot

A private AI assistant. No account, end-to-end encrypted messages, every
frontier model, and replies paid for in Bitcoin over Lightning.

Nymbot shares one identity and one credit balance with
[Nymchat](https://nymchat.app), the messenger it is also built into: sign in to
either with the same key and your credits and Nymbot conversation follow you.

**[nymbot.ai](https://nymbot.ai)** · [Web app](https://nymbot.ai/app) · [Docs](https://nymbot.ai/docs/)

## Features

### Privacy

- No account. Your identity is a Nostr key made on your device, or one you already have ([identity](https://nymbot.ai/docs/identity/)).
- Every message is end-to-end encrypted as a gift-wrapped Nostr event ([encryption](https://nymbot.ai/docs/encryption/)).
- Post-quantum key exchange: ML-KEM alongside the classical exchange, not instead of it.
- Anonymous mode moves a chat to a throwaway key, paid with blind-signed vouchers ([anonymous mode](https://nymbot.ai/docs/anonymous/)).
- Encrypted share links for read-only copies of a chat. The key lives in the link fragment.

### Paying

- Bitcoin over Lightning, a reply at a time. 10 sats standard, 100 sats frontier, no subscription ([credits](https://nymbot.ai/docs/credits/)).
- A few free standard replies every day.
- Gift credits by link, or move your balance to another key.

### Models and tools

- Claude, GPT, Gemini, Grok, Kimi, Qwen and MiniMax. Pin one per chat or let it route ([models](https://nymbot.ai/docs/models/)).
- Ask two models the same question side by side.
- GitHub, GitLab and Gitea repos. With writes on it can commit, branch and open PRs, and it asks first ([git](https://nymbot.ai/docs/git/)).
- Run Python and JavaScript on your device for free, or on a server for bigger jobs ([sandbox](https://nymbot.ai/docs/sandbox/), [server runs](https://nymbot.ai/docs/server-runs/)).
- Sandboxed preview for HTML and other code in a reply ([artifacts](https://nymbot.ai/docs/artifacts/)).
- `?image` and `?video` with 20+ generators, plus photo edits and questions about images ([media](https://nymbot.ai/docs/media/)).
- `?web` search and `?research` with sources ([research](https://nymbot.ai/docs/research/)).
- Big PDFs are searched rather than pasted whole, and replies cite the pages ([documents](https://nymbot.ai/docs/documents/)).
- Team mode splits a large task across 2 to 4 parallel workers ([team mode](https://nymbot.ai/docs/team-mode/)).
- MCP connectors ([connectors](https://nymbot.ai/docs/connectors/)).

### Chats

- As many as you want, with folders, tags, pins, search, forks and export ([chats](https://nymbot.ai/docs/chats/)).
- Memory you can read and wipe.
- Personas, custom bots and workspaces ([workspaces](https://nymbot.ai/docs/workspaces/)).
- Scheduled prompts, with notifications.
- Dictation and read-aloud.
- Type `?` in the composer for every command ([commands](https://nymbot.ai/docs/commands/)).

### Everywhere

- Web app you can install, plus Android and iOS ([apps](https://nymbot.ai/docs/apps/)). The Android APK can be downloaded directly from [download.nostrservices.com](https://download.nostrservices.com/apk/nymbot/app-release.apk).
- Settings and chats sync across devices, encrypted to your key.
- Same key and same balance in [Nymchat](https://nymchat.app).
- Back up your key with a passkey, or with a PIN through Apple or Google.

## How a message travels

1. The app seals your message to Nymbot's key and publishes it to Nostr relays as a gift wrap.
2. The worker fetches it, opens it, and sends the text to the model.
3. It charges the reply to whichever key sent it, then wraps the answer back to that key the same way.

Relays only ever carry ciphertext. [The protocol page](https://nymbot.ai/docs/protocol/) has the details.

## What is in here

| Path | What it is |
| --- | --- |
| `/` | The site and knowledge base at `nymbot.ai`. |
| `/app` | The web app, served at `nymbot.ai/app`. |
| `/flutter` | The Android and iOS app. |
| `/functions` | The backend: the bot and its API, on Cloudflare Pages Functions. |
| `/pages` | The docs, legal and press pages. |
| `/i18n` | Translations for every supported language. |

## Verify build

The web app has no build step of its own: every file under [`app/`](app/) is what the browser runs. So anyone can confirm that what `nymbot.ai/app` serves is exactly what is published here.

How it works:

- `npm run build` writes `dist/app/build-manifest.json`, holding the source `commit`, a `sha256-` hash of every file the app shell loads (the page, the service worker, and every script and stylesheet the page or the service worker's offline list names), and one `bundleHash` over that set. `dist/app/bundle-hash.txt` holds just the `bundleHash`, and `dist/app/version.json` the app version. The output depends only on source content (`builtAt` is the commit time), so rebuilding a commit gives the same hashes.
- The [Build provenance](../../actions/workflows/build-provenance.yml) action rebuilds each commit on `main`, prints the `bundleHash` to the run summary, and signs build-provenance attestations for `bundle-hash.txt` and the manifest.
- The app's **About** sheet re-fetches each file, hashes it in the browser with the Web Crypto API, and compares it with the manifest. It then recomputes the `bundleHash` from those local hashes, not from the manifest's claims, and looks it up in this repository's signed attestations through the GitHub API, so a deployment cannot vouch for itself with a manifest of its own. It reads **Verified** only when every file matches, the recomputed hash is attested here, and the page is served from `nymbot.ai`. A byte-identical copy on another domain reads **Verified build, not the official app**; modified files read **Mismatch** (naming an unrecognized inline script if one was injected); a self-made manifest reads **Unofficial build**; and **Provenance unreachable** means the GitHub API could not be reached.

To verify a running build yourself:

```sh
git clone https://github.com/Spl0itable/Nymbot
cd Nymbot
git checkout <commit shown in the About sheet>
npm ci
npm run build
cat dist/app/bundle-hash.txt
```

The hash should match the one in the About sheet and in that commit's Build provenance run. You can also check the attestation with the GitHub CLI:

```sh
gh attestation verify dist/app/build-manifest.json --repo Spl0itable/Nymbot
```

### Android

The Android app hashes the APK it is running from and compares it with the NIP-82 kind 3063 asset events published for `ai.nymbot` on `wss://relay.zapstore.dev`, keeping only events signed by the pinned developer key. Google Play installs are re-signed and split by Google, so they cannot be checked this way and say so.

### iOS

App Store binaries are encrypted and re-signed per install, so a hash taken on the device matches nothing that could be published. The About sheet says so rather than implying a check it never ran. Use the web app to check Nymbot's code on Apple hardware.

## Warrant canary

A warrant canary is a statement, refreshed on a fixed schedule, that 21 Million LLC has *not* received any secret government request for Nymbot user data (such as a National Security Letter or FISA order). The developer can be compelled to stay silent about such a request but not to lie, so a canary that goes stale or disappears is itself the signal.

The canary is [`canary.json`](canary.json) at the root of this repository, fetched straight from GitHub so its history is auditable apart from the deployed site. It is a Nostr event of kind 30078 with the d tag `nymbot-warrant-canary`, signed by the developer key `d49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df` (the same key signs Nymchat's canary under a different d tag, so neither can stand in for the other). The About sheet verifies the signature, the key and the d tag, and shows:

- **All clear** (green): signed by the developer key, current, and all clear.
- **Not signed yet**, **Update overdue** or **Not all clear** (amber or red): the canary is unsigned, was not refreshed by its `nextUpdateBy` date, or no longer says all clear. A silenced request cannot be ruled out.
- **Signature invalid** or **Canary removed** (red): the signature does not match the developer key, or the file is gone. Treat this as a serious warning.

Each signed canary embeds the latest Bitcoin block height and hash at signing time. That hash could not be known before the block existed, so it proves the canary was signed after that point and not pre-signed in bulk.

## Changelog

See the [releases page](https://github.com/Spl0itable/Nymbot/releases) for each update's changes.

## Legal

If you choose to use Nymbot on 21 Million LLC operated infrastructure and domain (nymbot.ai), your use is subject to the below Terms of Service and Privacy Policy.

- [Terms of Service](https://nymbot.ai/terms/)
- [Privacy Policy](https://nymbot.ai/privacy/)

## Contact

Created and operated by [21 Million LLC](https://nostrservices.com). Lead developer: [@Luxas#a8df](https://nostr.band/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv)

## License

Copyright © 21 Million LLC

Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See the [LICENSE](LICENSE) file for details. https://www.gnu.org/licenses/agpl-3.0.html