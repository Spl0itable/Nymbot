# Nymbot

A private AI assistant. No account, end-to-end encrypted messages, every
frontier model, and replies paid for in Bitcoin over Lightning.

Nymbot shares one identity and one credit balance with
[Nymchat](https://nymchat.app), the messenger it is also built into: sign in to
either with the same key and your credits, history and throwaway key follow you.

## What is in here

| Path | What it is |
| --- | --- |
| `/` | The marketing site and knowledge base at `nymbot.ai`, built by `build.mjs` into `dist/`. |
| `/app` | The standalone web app (a PWA), served at `nymbot.ai/app`. |
| `/flutter` | The Android and iOS app. |
| `/tools` | Generators for the pages and the social card. Not part of the runtime. |

There is no worker in this repository. The apps call the Nymbot service on
`web.nymchat.app`, which is what makes one identity work across both products.

## License

AGPL-3.0.
