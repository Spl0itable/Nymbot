import 'package:flutter/material.dart';

import 'i18n/i18n.dart';

class BotCommand {
  const BotCommand({
    required this.name,
    required this.args,
    required this.group,
    required this.hint,
  });

  final String name;
  final String args;
  final String group;
  final String Function() hint;
}

class BotCommands {
  const BotCommands._();

  static List<BotCommand> local() => [
        BotCommand(name: 'help', args: '', group: 'local', hint: () => t('List every command')),
        BotCommand(name: 'balance', args: '', group: 'local', hint: () => t('Check your credit balance')),
        BotCommand(name: 'buy', args: '[credits]', group: 'local', hint: () => t('Buy credits over Lightning')),
        BotCommand(name: 'model', args: '[name|off]', group: 'local', hint: () => t('Pin a Pro model, or go back to auto-routing')),
        BotCommand(name: 'compare', args: '', group: 'local', hint: () => t('Ask two models the same thing')),
        BotCommand(name: 'git', args: '[list|use|writes on|off|none|all]', group: 'local', hint: () => t('Manage the repositories this chat can read')),
        BotCommand(name: 'repo', args: '[name]', group: 'local', hint: () => t('Toggle a repository for this chat')),
        BotCommand(name: 'anon', args: '', group: 'local', hint: () => t('Chat from a throwaway key')),
        BotCommand(name: 'persona', args: '[name|off]', group: 'local', hint: () => t('Apply custom instructions to this chat')),
        BotCommand(name: 'workspace', args: '[name|off]', group: 'local', hint: () => t('Start this chat from a workspace')),
        BotCommand(name: 'bot', args: '[name|off]', group: 'local', hint: () => t('Answer this chat as one of your bots')),
        BotCommand(name: 'ghost', args: '', group: 'local', hint: () => t('Keep this chat off this device entirely')),
        BotCommand(name: 'schedule', args: '[prompt]', group: 'local', hint: () => t('Have Nymbot ask something on a schedule')),
        BotCommand(name: 'system', args: '[text]', group: 'local', hint: () => t("Set this chat's custom instructions")),
        BotCommand(name: 'prompt', args: '[title]', group: 'local', hint: () => t('Insert a saved prompt')),
        BotCommand(name: 'save', args: '[title]', group: 'local', hint: () => t('Save the composer text as a prompt')),
        BotCommand(name: 'search', args: '[text]', group: 'local', hint: () => t('Search every conversation')),
        BotCommand(name: 'pin', args: '', group: 'local', hint: () => t('Pin this conversation')),
        BotCommand(name: 'archive', args: '', group: 'local', hint: () => t('Archive this conversation')),
        BotCommand(name: 'tag', args: '[name]', group: 'local', hint: () => t('Tag this conversation')),
        BotCommand(name: 'rename', args: '[title]', group: 'local', hint: () => t('Rename this conversation')),
        BotCommand(name: 'fork', args: '', group: 'local', hint: () => t('Branch a copy of this conversation')),
        BotCommand(name: 'export', args: '', group: 'local', hint: () => t('Share this conversation')),
        BotCommand(name: 'stats', args: '', group: 'local', hint: () => t('What this chat has cost so far')),
        BotCommand(name: 'theme', args: '[dark|light|system]', group: 'local', hint: () => t('Switch the theme')),
        BotCommand(name: 'settings', args: '', group: 'local', hint: () => t('Open appearance and behaviour')),
        BotCommand(name: 'guide', args: '[topic]', group: 'local', hint: () => t('Open the help guide')),
        BotCommand(name: 'voice', args: '', group: 'local', hint: () => t('Dictate a message')),
        BotCommand(name: 'retry', args: '', group: 'local', hint: () => t('Ask the last question again')),
        BotCommand(name: 'clear', args: '', group: 'local', hint: () => t('Clear this chat and reset the context')),
      ];

  static List<BotCommand> remote() => [
        BotCommand(name: 'ask', args: '<question>', group: 'charged', hint: () => t('One question, no history')),
        BotCommand(name: 'image', args: '<prompt>', group: 'charged', hint: () => t('Generate an image')),
        BotCommand(name: 'speak', args: '<text>', group: 'charged', hint: () => t('Read something aloud')),
        BotCommand(name: 'translate', args: '<text>', group: 'charged', hint: () => t('Translate')),
        BotCommand(name: 'define', args: '<word>', group: 'charged', hint: () => t('Define a word')),
        BotCommand(name: 'news', args: '[topic]', group: 'charged', hint: () => t('Headlines')),
        BotCommand(name: 'math', args: '<expression>', group: 'charged', hint: () => t('Work out a sum')),
        BotCommand(name: 'units', args: '<value>', group: 'charged', hint: () => t('Convert units')),
        BotCommand(name: 'time', args: '[place]', group: 'charged', hint: () => t('The time somewhere')),
        BotCommand(name: 'btc', args: '', group: 'charged', hint: () => t('The Bitcoin price')),
        BotCommand(name: 'web', args: '<query>', group: 'charged', hint: () => t('Search the web')),
        BotCommand(name: 'code', args: '<task>', group: 'charged', hint: () => t('Write code')),
        BotCommand(name: 'review', args: '', group: 'charged', hint: () => t('Review the connected repositories')),
        BotCommand(name: 'trivia', args: '', group: 'games', hint: () => t('A trivia question')),
        BotCommand(name: 'joke', args: '', group: 'games', hint: () => t('A joke')),
        BotCommand(name: 'riddle', args: '', group: 'games', hint: () => t('A riddle')),
        BotCommand(name: 'wordplay', args: '', group: 'games', hint: () => t('Wordplay')),
        BotCommand(name: 'flip', args: '', group: 'games', hint: () => t('Flip a coin')),
        BotCommand(name: '8ball', args: '<question>', group: 'games', hint: () => t('Ask the magic 8-ball')),
        BotCommand(name: 'pick', args: '<a, b, c>', group: 'games', hint: () => t('Pick one')),
      ];

  static List<BotCommand> all() => [...local(), ...remote()];

  static bool isLocal(String name) =>
      local().any((c) => c.name == name.toLowerCase());

  static List<BotCommand> match(String term, {int limit = 8}) {
    final needle =
        term.toLowerCase().replaceFirst('?', '').trim().split(RegExp(r'\s+')).first;
    final scored = <(BotCommand, int)>[];
    for (final c in all()) {
      var score = 0;
      if (needle.isEmpty) {
        score = 1;
      } else if (c.name == needle) {
        score = 1000;
      } else if (c.name.startsWith(needle)) {
        score = 500 - c.name.length;
      } else if (c.name.contains(needle)) {
        score = 200 - c.name.length;
      } else if (c.hint().toLowerCase().contains(needle)) {
        score = 50;
      }
      if (score > 0) scored.add((c, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(limit).map((x) => x.$1).toList();
  }

  static String helpText() {
    String names(List<BotCommand> list) => list.map((c) => '?${c.name}').join(' ');
    return [
      '${t('Free, on this device:')} ${names(local())}',
      '${t('Charged:')} ${names(remote().where((c) => c.group == 'charged').toList())}',
      '${t('Games:')} ${names(remote().where((c) => c.group == 'games').toList())}',
      t("Start a message with ! to send it without this chat's history."),
    ].join('\n');
  }
}

class CommandSuggestions extends StatelessWidget {
  const CommandSuggestions({
    super.key,
    required this.term,
    required this.onPick,
  });

  final String term;
  final void Function(BotCommand command) onPick;

  @override
  Widget build(BuildContext context) {
    final rows = BotCommands.match(term);
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 210),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final c = rows[i];
          return InkWell(
            onTap: () => onPick(c),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  Text(
                    '?${c.name}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  if (c.args.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(c.args,
                        style: TextStyle(fontSize: 11, color: theme.hintColor)),
                  ],
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      c.hint(),
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: theme.hintColor),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
