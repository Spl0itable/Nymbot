# Changelog

All notable changes to the Nymbot mobile app. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); `zsp publish` pulls
the section whose heading matches the version read out of the APK, so every
release needs a block here and a matching `version:` in `pubspec.yaml`.

## [1.0.9] - 2026-10-28

Added
- A message too long for one sync row (over about 440 KB) now reaches your other
  devices whole: it syncs as linked rows beside the shortened copy older versions
  read, and that copy no longer cuts an emoji in half.
- The check before sending long text to a model now counts attached text files
  and the quoted message too, as the web app does.
- Text of any length, pasted or typed, reaches Nymbot whole: it travels as linked
  parts and shows as one message with Show more. When it is longer than the
  chosen model can read, Nymbot says so before anything is sent or charged and
  offers a longer-context model or sending it in parts.
- iPhone Duo: on the outer display the header actions and the whole chip row
  (tier, chips, model, Web, Git, Schedule, balance) move into a slim rail
  under the system status strip, and the open drawer puts New chat, Info,
  Menu and the balance there; in inner landscape the chip row and header
  stay clear of the status cluster.

Changed
- Coming back to the app now fetches only the support replies that arrived since the last check, and checks the connection of the chat on screen first; the connection of your other chats (anonymous or under your nym) is checked a few minutes later.
- When you come back to the app with several chats open, the connections of the chats not on screen are checked one at a time, each a few minutes apart from the others and from the run list of the chat you are viewing; a second return while one waits moves it further on instead of acting at the same moment.
- A support reply that reached the server at nearly the same moment as another one, while the app was checking for replies, now still shows up on the next check instead of being skipped; replies already shown are not added again.
- Such a support reply also shows up when many other messages reached the server in the same minute; the check reads through them a page at a time.
- Adding instructions to a request that is already writing its answer now says so and offers to send them as a new message, and that request's answer still arrives; before, the app said they were passed on and the answer could fail to arrive.
- Each message to Nymbot travels over a connection whose keys are made for
  that one turn, and the reply is sealed with a key made for that turn too.
  Your device sends the recent chat with each message and keeps a running
  summary of older messages with the chat, so other devices pick it up.
- On a window wider than 720 points, such as the iPhone and iPad app on a
  Mac, an iPad with a trackpad, a docked or desktop-mode Android or a resized
  window, the chat list stays docked beside the chat and Tasks opens beside
  it, as in the web app. Escape closes Tasks. Phones keep the slide-out list.
- With a mouse or trackpad, pointing at a message shows its actions with
  tooltips in a row under it, as in the web app, at any window width; once a
  mouse or trackpad has been used the space for the row stays, so messages
  never shift when the pointer hides or comes back; a touch tap still opens
  the labeled row.
- We no longer store or log the text of your Nymbot messages: live drafts,
  progress steps, plans, questions, follow-ups and sources stay in server
  memory only, logs keep just the error type, Cloudflare AI Gateway is asked
  not to log requests, and iPhone notifications never show a scheduled
  task's name. Our server still reads each message while answering it, and
  the AI provider sees it. A reply picked up after a server restart still
  arrives, though its question form, follow-ups or sources may be missing.
- Each chat keeps its own model. Picking a model or a generator, from the
  picker or with ?model or ?image, sets it for the chat you are in and for new
  chats; other chats keep theirs. Opening a chat shows its model at once with a
  short note when it differs, an older chat picks up the model of its latest
  reply, and a running task keeps the model it started with, including when
  you allow a tool, answer a question or decide on a plan after picking
  another model.
- A chat whose model is gone, or needs Pro credits you do not have, falls back
  to your current pick or Standard and says so before anything is sent.
- Your current model pick syncs across devices like the web app.
- An anonymous chat's header no longer shows an Anon pill, so the chat title
  gets that room. The toolbar's Anon control and the Anon label on your
  messages still show that the chat is anonymous, and screen readers hear it
  with the title.
- A line a language pack lacks is machine-translated on the device in every
  place it shows, including notices at the bottom of the screen, status lines,
  notification words and UnifiedPush texts; the translation replaces the English
  in place when it arrives, and is fetched once per language and app version.
- While an anonymous chat is shown, the nym's background tasks are not
  followed and a message under the nym waiting for a free run slot reads no
  run list; both carry on once a chat under the nym is shown.

Fixed
- Offline right after the app opens, an image kept on the device for more than
  a week still shows: tidying the image cache no longer deletes an image while
  it is being loaded.
- iPhone Duo: the Close a sheet puts in the outer display's right rail draws
  the same close icon as the rest of the app.
- A parked request that was resumed no longer brings its old question back on another device or after reconnecting, and a request you stopped is not picked up again as running after you restart the app.
- iPhone Duo: on the outer display the right rail and the sheet Close start
  below the status strip even while a Live Activity makes it taller, and on
  iOS 27.1 and later they follow the reserved regions the system reports. The
  balance stays pinned at the bottom of the rail while the rest scrolls.
- On the iPhone Duo outer display every sheet (about, credits, appearance,
  tasks, models, schedules and the rest) puts its Close in the right rail,
  below the system status strip and above the dimmed backdrop, so the rail is
  no longer covered and empty while a sheet is open. Tab reaches it from the
  sheet and comes back.
- On a second device, Running now shows the label and progress of a request
  started on another device, Add instructions reaches it, and a request you
  stopped is no longer picked up and stopped a second time.
- On a second device, a request that carries on after you answered its
  question, and a background task, are listed as running again instead of
  dropped as finished, and Add instructions reaches them.
- Stopping a repository job that runs over the per-turn channel now records the branch it committed to, so Clean up can find and delete it.
- A long message of yours folded under Show more now shows when an emoji sits right at the fold, instead of failing to lay out.
- Machine translations kept on the device now reset when the app's interface strings change, instead of being kept for the whole 1.0.8 version.
- After your account is deleted on another device, this device no longer
  syncs your settings while its check for the deletion is still waiting on the
  server; it waits for that answer and wipes instead.
- Deleting a long message, or its chat, now deletes the linked sync rows that
  carried it to your other devices, so they no longer pile up on the server.
- The first message after returning to the app no longer waits on a
  connection that went quiet while you were away: an idle connection is
  closed on return and the message opens a fresh one.
- Keyboard: Tab no longer stops on an invisible spot that covers the whole
  screen; every keyboard shortcut still works, with or without the iPhone Duo
  rail.
- iPhone Duo: the chip row stays clear of the status cluster when something
  above it appears or goes away, not only after a resize.
- iPhone Duo: on the outer display every button in the right rail, the
  balance included, fits above the home indicator without scrolling, at every
  text size the app offers.
- Pointing at a Nymbot reply shows its actions under that reply again, at
  its start edge, and your own message's under it at its end edge, instead of
  in a bordered bar at the far opposite side of the chat.
- With message bubbles turned off, your own message's actions end at the far
  end of the line again, as they did before October 3 and as in the web app.
- A reply that was still streaming when you left the app no longer stalls on
  return: a connection that went silent in the background is found within
  about 3 seconds and the reply continues on a fresh one.
- Going from your nym to an anonymous chat soon after the anonymous chat's last
  update no longer leaves that chat's running tasks, logs and steer status
  waiting for minutes.
- If a task fails while your plan decision is still on its way, the task now
  ends with its error instead of waiting.
- A narrow window with a trackpad, such as an iPad in Split View, shows a
  message's actions when you point at it again, and tablets used only by
  touch no longer keep an empty row under every message.
- An anonymous chat reads its running tasks only with its own key, on its
  own schedule, minutes apart from the account's own list; a steer there is
  followed up only with that key.
- A plan decision for a background task this device holds goes over its
  channel, with the old request only as a fallback.
- A plan decision sent over the channel counts as sent only once Nymbot
  confirms it; if Nymbot refuses it, the app sends it the old way.
- An anonymous chat's task logs, its wait for a free run slot and its task
  list are read on a randomized schedule of their own, never right next to
  the account's own reads, and a task ending in another chat no longer
  starts an anonymous chat's waiting message.
- Support replies sent while the app was closed, in the background or
  offline load when it comes back, from Nymbot's stored copy when the
  relays did not keep them.
- Auto-delete keeps a Support chat that is still waiting for a reply.
- After the app was in the background, sending to Nymbot no longer keeps
  timing out on a connection that died while away; a fresh one opens.
- An anonymous chat only checks and tops up its own throwaway key: opening it,
  its replies and a low balance never ask for your nym's balance or move
  credits from it. With auto top-up on, vouchers are bought ahead and the chat
  redeems them when it needs credits.
- A reply that finished while every device was away is fetched before your
  next message, so Nymbot sees it in the conversation.
- A chat opened while Nymbot is still answering in it, even an answer started
  on another device, picks up that answer when it finishes, so a message sent
  right after sees it.
- In an anonymous chat, approving, rejecting or revising a plan and answering
  a question are sent with that chat's throwaway key, and a rejected or
  revised plan reaches Nymbot as you decided it.
- Standalone chats over the per-turn channel: answers to questions and approvals
  from before the update continue where they stopped, long messages and
  attached text files send in parts again, the running summary syncs with the
  chat between the app and the web app, deleting, editing or rewinding a
  message no longer sends the removed turns, any device can steer a run, and
  schedules and pull request watches saved earlier are saved again for the
  channel.
- Sending, receiving a reply or binding a key in an anonymous chat no longer
  starts the account sync, which your identity signs, so nothing ties its
  timing to the anonymous chat; the chat still reaches your other devices with
  the next sync.
- In standalone chats, sending from a follow-up chip, an answer, an approval or
  a retry rarely waits for the latest synced state, revising a plan steers the
  running task over the per-turn channel like the web app, and an older running
  summary kept on a chat no longer replaces a newer one.
- Mouse wheel and trackpad scrolling no longer stop working on a wide window
  after Settings or another sheet opened from the chat list closes, and a
  wheel turn right after opening a chat is no longer undone.
- Switching to another chat while Apply, Undo, Close PR, a branch action or a
  PR-watch fix is still working no longer wipes or changes the first chat's
  messages, and a send that stops after you switch no longer puts its
  attachments into the other chat's composer.
- Revising a plan, then switching chats, now sends the revision for the
  plan's own chat and keeps working there, and Apply reaches every repository
  of its chat even if the chat you switch to has fewer.
- When a spending cap or team refusal hands a message back, its text, files
  and quote now join whatever you added since instead of replacing it, and
  land in the draft of the chat it was sent from if you have moved on.
- Comparing two models keeps the asking chat's history, repositories and
  persona even if you switch chats while it starts.
- A message that stops before it is sent, for any reason, goes back to the
  chat it was typed in, merged with anything typed or attached since. Another
  chat is never touched, and "Send once anyway" refused again also gives the
  text and files back.
- Pressing send again while the same message is still being prepared keeps
  its text and files, and a support message that fails to send goes back to
  the support chat, never to a chat opened while it was sending.
- Each chat keeps its own unsent text and files when you switch chats, and
  dictation or a file that finishes loading after a switch lands in the chat
  where it started.
- A chat's first send no longer pins it to a fallback model while Pro credits
  are empty; it keeps the model it already had.
- Opening the chat that is already on screen, from the chat list, a
  notification, a link or search, keeps its unsent text, files and quote.

## [1.0.8] - 2026-10-20

Added
- Paste an image from the clipboard into the composer and it attaches and
  uploads like a picked image.
- Plan first, then approve: Nymbot can show its plan before a task runs, and
  you approve, edit, reject or ask for a revision.
- Nymbot can ask you a question mid-task and waits for the answer even with
  the app closed. Skills get their own puzzle-piece icon.
- Pull requests a task opens are watched: CI, reviews, comments, merge state
  and optional fix runs.
- Undo across every repo a reply changed, close a task's pull request, or open
  a revert for merged changes.
- A transcript of every Nymbot task, kept with the chat, and Rewind to here.
- Per-event notification settings and clearer push text for each task state.
- Delete account data and wipe the device from Settings > Account; other
  devices signed in to a deleted key wipe too.

Changed
- The on-screen keyboard's Enter key starts a new line. Enter sends only from
  a hardware keyboard, as in Nymchat.
- Announcements page with back and forward buttons (for example 2 of 5), and
  closing the banner dismisses them all.
- Nymbot asks before anything is sent to its AI services, as a first-run step
  on every platform.
- The Apple key backup moves to CloudKit; older iCloud Keychain backups still
  restore.

Fixed
- Links in replies render cleanly, including [title](url), bracketed and
  angle-bracket links and trailing punctuation; payment links inside a link
  stay plain text.
- Translations that came out garbled show in English until they are redone.
- nymbot:// and nymbot.ai/app links open in the app on Android, and tapping a
  notification that cold-launches the app on iOS opens its chat.
- The app launches on iOS 27 (UIScene lifecycle).
- The newest messages stay above the composer when the keyboard opens.

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
