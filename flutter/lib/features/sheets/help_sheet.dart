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
            'reference files and repositories. Every chat in one starts with '
            'that context, and a new chat opened from it inherits the '
            'workspace. The files stay on this device.'),
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
        t('Connect as many repositories as you like and tick the ones a chat '
            'can see. Pro replies read their code and, with writes on, commit, '
            'branch and open pull requests. Access tokens are stored only on '
            'this device and sent per request — never stored server-side or '
            'published to relays.'),
      ),
      HelpTopic(
        t('Ghost chats and auto-delete'),
        t('A ghost chat is never written to this device and publishes no '
            'archive copy: it is gone when you close the app. Auto-delete '
            'sweeps chats older than the window you choose when the app opens, '
            'and never touches a pinned one.'),
      ),
      HelpTopic(
        t('Long tasks, and carrying them on'),
        t('A repo task runs the model in a loop — reading, searching, writing — '
            'and that loop has an allowance. When it runs out with work left, '
            'Nymbot stops and says so. Set a continuation budget in Appearance '
            'and it buys another allowance instead, one leg at a time, each leg '
            'saying what it cost, until the budget is spent or the task is done. '
            'Stop cancels the rest.'),
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
            'same encryption key. Export everything from Appearance; there is no '
            'account on a server to recover from.'),
      ),
      HelpTopic(
        t('Voice, attachments and export'),
        t('Dictate a message with the microphone and have replies read aloud '
            'from Appearance. Attach text, code and images to a message. Any '
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
