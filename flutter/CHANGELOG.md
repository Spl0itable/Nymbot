# Changelog

All notable changes to the Nymbot mobile app. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); `zsp publish` pulls
the section whose heading matches the version read out of the APK, so every
release needs a block here and a matching `version:` in `pubspec.yaml`.

## [1.0.7] - 2026-09-24

Added
- PDFs, Word documents and large CSV, HTML, JSON and Markdown files are read
  on the device. A document too long to send whole is searched instead, and
  only the passages that answer the question go with it; the message says
  which pages were used.
- Python and JavaScript in a reply can be run on the device, with output,
  tables and charts shown under the code and a way to send the output back.
- Share a chat as an end-to-end encrypted link, and stop sharing it later.
- Deep research: a Research chip or ?research runs several rounds of searching
  and reading and writes a report with sources, priced before it is sent.
- Edit a picture you send with ?image and a Pro generator that can edit.
- Start a message with @ and a model's name to ask that model just once.
- Connectors to outside tools over MCP, with a confirmation before anything
  that changes data.
- Spending caps per chat and per bot.
- Suggested replies under a reply that offers next steps, notices from
  Nymbot pinned above the chat, and more than two sources folded into a row.
- Repository runs can hold their changes for review before committing, show
  CI results, and resume by themselves after the gateway was busy.

Changed
- A long reply now opens at its first line instead of its last.
- The Pro model picker lists every model, with a Speech filter, a sort by
  price or name, and search over descriptions.

## [1.0.6] - 2026-09-15

Fixed
- The Menu section in the drawer forgot whether it was folded: reopening the
  app found it expanded again. It is remembered now.
- The credit chip in the toolbar rounded the balance to a whole number. It
  shows decimals the way the web app does.
- The jump-to-newest button sat on top of the send button. It is placed over
  the transcript now, clear of the composer.
- An anonymous chat could flip its credit chip back to the nym's full balance,
  which read as the credits you had just moved having come back. The throwaway
  key's balance now belongs to the key rather than to whichever chat is open,
  and a reply that reports no balance at all no longer puts the nym's figure
  back in its place.

Changed
- The drawer's collapsible section is called Menu.
- A chip that is on says what it is rather than that it is on: "Anon", not
  "Anon on". Being lit is what says it is on.

## [1.0.5] - 2026-09-15

Changed
- A message no longer waits on a relay. The sealed wrap travels in the request
  to the worker itself, so nothing has to be published, propagate and be read
  back before a reply can start. The relay copy still goes out as the public
  record and as the fallback, but it no longer sits on the critical path, and a
  message sent with no relay connected at all now goes.
- "Reading this conversation back off the relays" appears only when a turn
  genuinely has to reach for something it was not handed.

## [1.0.4] - 2026-09-15

Added
- A menu button on the toolbar opens every chip as a list, grouped into what is
  on for this chat and what is available. The rail was close to unscrollable on
  a narrow phone.
- The drawer's library section folds away behind a caret. It opens by default.

Changed
- Nymbot now talks to its own worker on nymbot.ai rather than Nymchat's.
- The composer reads "Ask something, or type ? for commands", smaller and
  dimmer than the text you type.

Fixed
- Stop is red while a reply is being written, as it is on the web.
- A message typed mid-reply can be sent from the phone. The send button was
  replaced by Stop, so with enter-to-send off there was no way to queue one.
- Moving credits to the anonymous throwaway key no longer looks like your own
  credits disappearing: the two balances are kept apart, and the chip says
  which one it is counting.

## [1.0.3] - 2026-09-15

Added
- Your chats now follow you between devices. Conversations, messages and the
  library — personas, prompts, workspaces, folders, schedules, memories, bots
  and favourite models — are sealed to your own key and kept in the account
  store every device you sign in on can read back. It is the same store, in
  the same format, the web app has always used, so a chat started in a browser
  opens on the phone and a chat started on the phone opens in the browser.
  Turn it off under Settings › Your data; ghost chats are never included and a
  repository's access token never leaves the device it was typed into.

## [1.0.2] - 2026-09-12

Fixed
- The Buy sheet rendered as a heap — the heading and the amount field on top
  of each other, and no tier switch, preset amounts or invoice below the two
  balance cards. Everything on it is reachable again.

Changed
- The store listing images no longer all carry the same green wash.

## [1.0.1] - 2026-09-12

Fixed
- The Pro model picker and the Buy sheet came up empty. The catalog request
  was the one call that did not identify the app, so the server refused it.
- Sheets opened underneath the status bar and the notch, with no way to close
  them. They now sit below the inset and carry a handle to pull them shut.
- "Nymbot is thinking" was a pale slab against the left edge; it is now a
  centered tint that follows the theme.
- Code blocks were drawn on a background too light to read the syntax
  coloring against, in both themes.
- Generated pictures showed a gap and then appeared. They now hold a
  progress wheel until they have loaded.
- Profile pictures showed an empty circle while loading rather than the
  identicon.

Added
- Swipe in from the left edge to open the sidebar, and drag any list to put
  the keyboard away.
- Cited sources show the site's icon, fetched through the Nymbot worker so
  the site never sees who is reading.

Changed
- A model is quoted as a range for a reply — short answer to long — instead
  of a single figure for "a turn", which read as a flat price per message.
  What the model has to read moves the real cost, and the picker now says so.

## [1.0.0] - 2026-09-11

First release.

- Many separate conversations with Nymbot, end-to-end encrypted over Nostr
  (NIP-17 gift wraps with a post-quantum ML-KEM layer), paid for in credits.
- Frontier models picked per conversation, each reply saying which model wrote
  it and what it cost.
- Git repositories: read files, search the tree, and with writes on, commit and
  open pull requests. Several repositories per conversation; the access token
  stays on the device.
- Personas and custom instructions, a prompt library, attachments, replies read
  aloud, search, folders and tags, branching, and export.
- Anonymous mode with a throwaway key that can top itself up.
- Settings, library and conversations synced across devices, sealed to your key.
- The interface in more than a hundred languages.
