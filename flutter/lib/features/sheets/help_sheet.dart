import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/i18n.dart';

const supportEmail = 'support@nymbot.ai';

class HelpTopic {
  const HelpTopic(this.title, this.body);

  final String title;
  final String body;

  bool matches(String needle) =>
      needle.isEmpty ||
      title.toLowerCase().contains(needle) ||
      body.toLowerCase().contains(needle);
}

/// The same guide the web app carries, so an answer found on one device is the
/// answer on the other.
List<HelpTopic> helpTopics() => [
      HelpTopic(
        t('Asking, and what it costs'),
        t('Every reply is paid for a message at a time, in credits you buy over '
            'Lightning. Standard replies are auto-routed; Pro pins a model you '
            'choose. The toolbar says which is answering and roughly what the '
            'next reply will cost. Type ? in the composer for the full list of '
            'commands.'),
      ),
      HelpTopic(
        t('Artifacts'),
        t('A reply that contains a whole page, script or document opens on its '
            'own screen instead of scrolling away. Edit it there and every save '
            'is kept as a version you can restore. Rewriting the same file in a '
            'later reply updates the artifact rather than making a second copy.'),
      ),
      HelpTopic(
        t('Comparing two models'),
        t('Compare sends one prompt to two models at once, each on its own '
            'thread, so neither sees the other\'s answer. Keep the one you '
            'prefer and the chat carries on from it. Two replies means two '
            'charges.'),
      ),
      HelpTopic(
        t('Workspaces'),
        t('A workspace is standing context a run of chats shares: instructions, '
            'reference files and repositories. Every message in one carries '
            'that context, not just the first, so it still applies deep into a '
            'long chat. The files stay on this device: they are searched here '
            'against what you asked, and only the passages that bear on it '
            'travel with the message.'),
      ),
      HelpTopic(
        t('Bots'),
        t('A bot is a way of answering: a name, standing instructions, a model '
            'and a few openers. Share one as a link or publish it under your '
            'npub. A shared bot carries none of your repositories, tokens or '
            'files — only how it answers.'),
      ),
      HelpTopic(
        t('Repositories'),
        t('Paste a token and Nymbot lists what it can reach, so you tick the '
            'repositories you want rather than typing each name exactly right. '
            'Pro replies read their code and, with writes on, commit, branch '
            'and open pull requests. The list is asked for by this device, '
            'straight from the forge; access tokens are stored only here and '
            'sent per request — never stored server-side or published to '
            'relays.'),
      ),
      HelpTopic(
        t('Memory'),
        t('Standing facts Nymbot carries between chats: what to call you, what '
            'you work on, how you want answers written. Kept one entry at a '
            'time so you can read the list, correct the line that is wrong and '
            'throw away the one you never meant to save — a rolling summary '
            'cannot be argued with. Facts you mention in passing are noticed '
            'and always said out loud, with one tap to take them back; turn '
            'the noticing off and ?remember still works. They live on this '
            'device, and the few that bear on a question travel inside that '
            'message. A ghost chat neither reads them nor adds to them.'),
      ),
      HelpTopic(
        t('What a long chat remembers'),
        t('A reply is given the most recent stretch of the conversation, '
            'decided by a budget rather than a fixed number of messages — so a '
            'few long turns get the room they need instead of each being '
            'clipped to the same short length. Your instructions, the '
            'repositories in scope and the part of a workspace that bears on '
            'the question ride every message, so they still apply on turn '
            'fifty. Anything the window cannot hold is listed for the model as '
            'a line each, and a Pro reply can read those turns back in full '
            'when the answer depends on them. Looking back is one more model '
            'call, so it costs one more base credit — and only when it '
            'happens.'),
      ),
      HelpTopic(
        t('Keeping the chat list in order'),
        t('Every row in the chat list carries the same menu the chat header '
            'does, behind the … button: rename, pin, archive, duplicate, '
            'tag, export or delete. It acts on that row\'s chat, so tidying '
            'the list never moves you off the one you are reading.'),
      ),
      HelpTopic(
        t('Ghost chats and auto-delete'),
        t('A ghost chat is never written to this device and publishes no '
            'archive copy: it is gone when you close the app. Auto-delete '
            'sweeps chats older than the window you choose when the app opens, '
            'and never touches a pinned one.'),
      ),
      HelpTopic(
        t('Undoing what a repo run changed'),
        t('A reply that wrote to a repository says what it touched: the '
            'repository, the branch, and every file. Undo puts them back — '
            'each path is read at the commit the branch stood on before the '
            'run and committed as it was. That is a revert, not a rewrite: '
            'what Nymbot did stays in the history, it is simply no longer the '
            'state of the branch. It costs nothing, because it touches no '
            'model. Files only: a branch or pull request it opened is left '
            'where it is, because closing somebody\'s pull request on their '
            'behalf is not an undo.'),
      ),
      HelpTopic(
        t('Long tasks, and carrying them on'),
        t('A repo task runs the model in a loop — reading, searching, writing — '
            'and that loop has an allowance. When it runs out with work left, '
            'Nymbot stops and says so. Set a continuation budget in Settings '
            'and it buys another allowance instead, one leg at a time, each leg '
            'saying what it cost, until the budget is spent or the task is done. '
            'Stop cancels the rest.'),
      ),
      HelpTopic(
        t('Asking a question differently'),
        t('Under any message you sent, "Ask this differently" reopens it. By '
            'default the chat you had stays exactly as it is and the new '
            'answer arrives on a branch carrying everything said before that '
            'question — along with the repositories, persona, workspace, model '
            'and effort it was set to, and the files those messages produced. '
            'Untick the box and it rewrites in place instead, throwing away '
            'everything after it. That used to be the only behaviour; it is no '
            'longer the default, because nothing about it could be undone.'),
      ),
      HelpTopic(
        t('Asking it to think harder'),
        t('The Effort chip on a Pro chat says how much work each reply is '
            'worth. Normal is one pass. Careful plans the answer before '
            'writing it, and Deep also reads its answer back against the '
            'question and corrects it before you see it. Each step is another '
            'model call, so a careful reply costs about twice a normal one and '
            'a deep reply about three times — the toolbar says the range '
            'before you send. A repo task ignores it: it already loops on a '
            'budget of its own.'),
      ),
      HelpTopic(
        t('Typing while it is still writing'),
        t('You do not have to wait for a reply to land before saying the next '
            'thing. Anything typed mid-reply waits its turn, shown above the '
            'composer in the order it was typed, and goes as soon as the '
            'current one is done. Take one back out while it waits, or press '
            'Stop and nothing behind it is sent either. Commands are the '
            'exception: they are free and instant, so they run straight away '
            'rather than queueing.'),
      ),
      HelpTopic(
        t('Watching it work'),
        t('While a reply is generating, Nymbot reports what it is doing under '
            'the spinner: what it routed to, what it searched for, which files '
            'it is reading, which model call it is on, and the model\'s own '
            'reasoning as each call returns. It is scoped to the key that '
            'asked — in anonymous mode that is the throwaway key, so watching '
            'reveals nothing the message did not.'),
      ),
      HelpTopic(
        t('Scheduled prompts'),
        t('A prompt Nymbot sends for you: once, hourly, daily or weekly. There '
            'is no server doing it — a run happens while the app is open, and a '
            'run that came due while it was shut fires once when you come back.'),
      ),
      HelpTopic(
        t('Anonymous mode'),
        t('Anonymous mode routes a chat through a throwaway key funded by blind '
            'vouchers, so the credits cannot be matched to your nym. Turn on the '
            'automatic transfer and the key tops itself up rather than being '
            'funded by hand.'),
      ),
      HelpTopic(
        t('Your keys and your data'),
        t('Your private key lives on this device. Your public key — npub or hex '
            '— is how somebody addresses you and is safe to share. The '
            'post-quantum recovery code is what lets a second device hold the '
            'same encryption key. Export everything from Settings; there is no '
            'account on a server to recover from.'),
      ),
      HelpTopic(
        t('Writing, pasting, dictating and exporting'),
        t('Write in markdown: fenced blocks, inline code and the rest render '
            'in your own messages the same way they do in the replies. Paste '
            'something long and it goes in as an attachment rather than '
            'filling the composer. Dictate with the microphone and have '
            'replies read aloud from Settings; if dictation stops it says why '
            'rather than going quiet. Attach text, code and images. Any '
            'conversation exports as Markdown, plain text or JSON.'),
      ),
    ];

Future<void> showHelpSheet(BuildContext context, {String prefill = ''}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _HelpSheet(prefill: prefill),
    );

class _HelpSheet extends StatefulWidget {
  const _HelpSheet({this.prefill = ''});

  final String prefill;

  @override
  State<_HelpSheet> createState() => _HelpSheetState();
}

class _HelpSheetState extends State<_HelpSheet> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _search.text = widget.prefill;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needle = _search.text.toLowerCase().trim();
    final topics = helpTopics().where((x) => x.matches(needle)).toList();

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Help'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            TextField(
              controller: _search,
              decoration: InputDecoration(
                labelText: t('Search this guide'),
                prefixIcon: const Icon(Icons.search, size: 18),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            if (topics.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  t('Nothing in the guide matches that. The knowledge base is fuller, or email us.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            for (final topic in topics)
              Card(
                margin: const EdgeInsets.only(bottom: 4),
                child: ExpansionTile(
                  initiallyExpanded: needle.isNotEmpty,
                  tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                  title: Text(topic.title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Text(topic.body,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
            const Divider(height: 24),
            Text(t('Still stuck?'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              t('Email us and say what you were doing when it went wrong. We '
                  'cannot read your chats — they are encrypted to keys we do not '
                  'hold — so the more you can tell us, the more we can help.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              icon: const Icon(Icons.mail_outline, size: 18),
              label: Text(t('Email {address}', {'address': supportEmail})),
              onPressed: () => launchUrl(Uri.parse('mailto:$supportEmail')),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: Text(t('Full knowledge base')),
              onPressed: () => launchUrl(
                Uri.parse('https://nymbot.ai/docs/'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
