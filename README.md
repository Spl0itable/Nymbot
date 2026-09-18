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
| `/functions` | Cloudflare Pages worker functions that handle the backend. |

## Error pages

`404.html` is the one error this site serves itself. Everything else — a 5xx
from the Pages functions, a DNS fault, a firewall block, a rate limit, a
challenge — is Cloudflare's, and those pages are built from `errors/` into
`dist/errors/` in the 404's style:

| Built to | Cloudflare setting | Token |
| --- | --- | --- |
| `/errors/500s.html` | Error Pages → 500 class errors | `::CLOUDFLARE_ERROR_500S_BOX::` |
| `/errors/1000s.html` | Error Pages → 1000 class errors | `::CLOUDFLARE_ERROR_1000S_BOX::` |
| `/errors/waf-block.html` | Error Pages → WAF block | `::CLOUDFLARE_ERROR_1000S_BOX::` |
| `/errors/rate-limit.html` | Error Pages → 429 errors | `::CLOUDFLARE_ERROR_1000S_BOX::` |
| `/errors/ip-block.html` | Error Pages → IP/Country block | `::CLOUDFLARE_ERROR_1000S_BOX::` |
| `/errors/challenge.html` | Error Pages → Managed / Interactive / Basic / Country challenge | `::CAPTCHA_BOX::` |
| `/errors/under-attack.html` | Error Pages → I'm Under Attack Mode | `::IM_UNDER_ATTACK_BOX::` |
| `/errors/server-error.html` | Custom Error Rules | none |

Each is configured by URL — `https://nymbot.ai/errors/500s.html` — under
**Rules → Custom Errors** on the `nymbot.ai` zone. Cloudflare fetches the page
once and serves its own stored copy from then on, so **a deploy does not update
what visitors see**: re-fetch it in the dashboard after changing one. Custom
Errors is a paid-plan feature.

The last row is the odd one, and on this site the most useful. Error Pages
deliberately do not apply to status `500`, `501`, `503` or `505` — which is what
the backend under `/functions` returns when it fails — and a custom error rule
does not substitute tokens, so `server-error.html` carries none and is the page
a rule points at.

An error page is shown in the moments when `nymbot.ai` cannot be reached, so
these reference **nothing**: styling inlined, favicon as a data URI, no script,
and absolute links rather than paths. `errors/style.mjs` pulls the blocks they
need out of `styles.css` so the look has one source — renaming `.nf-title` fails
the build rather than publishing a bare page — and `errors/art.mjs` generates the
chat window, padded to the column, with the status codes baked in as figlet
output (**Slant Relief**, the 404's font) so the build stays offline. The set is
the twin of nym-web's and is kept in step with it by hand.

## License

AGPL-3.0.
