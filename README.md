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

- Web app you can install, plus Android and iOS ([apps](https://nymbot.ai/docs/apps/)).
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