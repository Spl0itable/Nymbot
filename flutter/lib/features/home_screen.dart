import 'package:flutter/material.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import '../models/conversation.dart';
import '../state/app_controller.dart';
import 'markdown_body.dart';
import 'sheets/anon_sheet.dart';
import 'sheets/credits_sheet.dart';
import 'sheets/git_sheet.dart';
import 'sheets/identity_sheet.dart';
import 'sheets/models_sheet.dart';
import 'toolbar.dart';
import 'i18n/i18n.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// Commands handled here, free of charge, never sent anywhere.
  Future<bool> _localCommand(String text) async {
    final app = AppScope.read(context);
    final m = RegExp(r'^\?(\w+)\s*(.*)$', dotAll: true).firstMatch(text);
    if (m == null) return false;
    final cmd = m.group(1)!.toLowerCase();
    final arg = m.group(2)!.trim();

    switch (cmd) {
      case 'help':
      case 'commands':
        await app.note(
          'Free, on this device: ?help ?balance ?buy ?model ?git ?anon ?clear\n'
          'Charged: ?ask ?image ?speak ?translate ?define ?news ?math ?units ?time ?btc\n'
          'Games: ?trivia ?joke ?riddle ?wordplay ?flip ?8ball ?pick\n'
          "Start a message with ! to send it without this chat's history.",
        );
        return true;
      case 'balance':
        await app.refreshBalance(announce: true);
        return true;
      case 'buy':
        await showCreditsSheet(context);
        return true;
      case 'model':
        if (RegExp(r'^off$', caseSensitive: false).hasMatch(arg)) {
          await app.setProModel(null);
          await app.note('Back to standard auto-routing.');
          return true;
        }
        await showModelsSheet(context, filter: arg);
        return true;
      case 'git':
        if (RegExp(r'^writes\s+(on|off)$', caseSensitive: false).hasMatch(arg)) {
          final on = arg.toLowerCase().endsWith('on');
          await app.setGit({...?app.git, 'allowWrites': on});
          await app.note(
              on ? t('Repository writes on.') : t('Repository writes off.'));
          return true;
        }
        if (RegExp(r'^disconnect$', caseSensitive: false).hasMatch(arg)) {
          await app.setGit(null);
          await app.note('Repository disconnected.');
          return true;
        }
        await showGitSheet(context);
        return true;
      case 'anon':
        await showAnonSheet(context);
        return true;
      case 'clear':
        await app.clearCurrent();
        return true;
      default:
        return false;
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // Resolved before the awaits below, so nothing reaches for the context
    // after the widget may have gone.
    final app = AppScope.read(context);
    _input.clear();
    if (await _localCommand(text)) {
      _toBottom();
      return;
    }
    _toBottom();
    await app.send(text);
    _toBottom();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final conv = app.current;

    return Scaffold(
      drawer: const _ChatDrawer(),
      appBar: AppBar(
        title: Text(
          conv == null || conv.title.isEmpty ? 'New chat' : conv.title,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (conv?.anon ?? false)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Chip(
                label: const Text('anon', style: TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: Theme.of(context).colorScheme.secondary),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'rename':
                  await _rename();
                case 'clear':
                  await app.clearCurrent();
                case 'delete':
                  await _confirmDelete();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(t('Rename'))),
              PopupMenuItem(value: 'clear', child: Text(t('Clear this chat'))),
              PopupMenuItem(value: 'delete', child: Text(t('Delete'))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const NymbotToolbar(),
          Expanded(
            child: app.messages.isEmpty
                ? _empty(context)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                    itemCount: app.messages.length + (app.sending ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= app.messages.length) {
                        return _Thinking(label: app.status ?? 'thinking');
                      }
                      return _MessageTile(app.messages[i]);
                    },
                  ),
          ),
          _composer(context, app),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t('Ask Nymbot anything'),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                t('End-to-end encrypted, paid a reply at a time. Type ? for '
                'commands, or start with one of these.'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final tip in const [
                    '?help',
                    '?balance',
                    'Explain ML-KEM in three sentences',
                    '?image a lighthouse at dusk',
                  ])
                    ActionChip(
                      label: Text(tip),
                      onPressed: () => setState(() => _input.text = tip),
                    ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _composer(BuildContext context, AppController app) => SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: t('Message Nymbot, or ? for commands'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: app.sending ? null : _send,
                icon: const Icon(Icons.send, size: 20),
              ),
            ],
          ),
        ),
      );

  Future<void> _rename() async {
    final app = AppScope.read(context);
    final controller = TextEditingController(text: app.current?.title ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Name this chat')),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(t('Save')),
          ),
        ],
      ),
    );
    if (value != null) await app.renameCurrent(value);
  }

  Future<void> _confirmDelete() async {
    final app = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Delete this chat?')),
        content: Text(
          t('Its messages are encrypted to your key and cannot be recovered.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Delete')),
          ),
        ],
      ),
    );
    if (ok == true) await app.deleteCurrent();
  }
}

class _ChatDrawer extends StatefulWidget {
  const _ChatDrawer();

  @override
  State<_ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<_ChatDrawer> {
  String _term = '';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final term = _term.toLowerCase().trim();
    final list = app.conversations.where((c) {
      if (term.isEmpty) return true;
      if (c.title.toLowerCase().contains(term)) return true;
      return app.store
          .messages(c.id)
          .any((m) => m.content.toLowerCase().contains(term));
    }).toList();

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: const Text('nymbot',
                  style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              trailing: IconButton(
                icon: const Icon(Icons.add),
                tooltip: t('New chat'),
                onPressed: () async {
                  await app.newConversation();
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                decoration: InputDecoration(hintText: t('Search chats')),
                onChanged: (v) => setState(() => _term = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final conv = list[i];
                  return ListTile(
                    selected: conv.id == app.current?.id,
                    title: Text(
                      conv.title.isEmpty ? 'New chat' : conv.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: conv.anon
                        ? const Text('anon', style: TextStyle(fontSize: 11))
                        : null,
                    onTap: () async {
                      await app.open(conv);
                      if (context.mounted) Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.circle,
                size: 10,
                color: app.relaysUp > 0
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).disabledColor,
              ),
              title: Text(
                'nym#${app.identity.pubkey.isEmpty ? '' : app.identity.pubkey.substring(app.identity.pubkey.length - 4)}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              subtitle: Text(
                app.standardBalance == null
                    ? t('{n} relays', {'n': app.relaysUp})
                    : t('{standard} standard · {pro} Pro', {
                        'standard': app.standardBalance,
                        'pro': app.proBalance,
                      }),
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => showIdentitySheet(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile(this.message);

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final self = message.role == ChatRole.self;
    final note = message.role == ChatRole.note;
    final error = message.role == ChatRole.error;

    final background = self
        ? theme.colorScheme.primary.withValues(alpha: 0.10)
        : note || error
            ? Colors.transparent
            : theme.dividerColor;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!note && !error)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                self ? 'you' : 'nymbot',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: self ? theme.colorScheme.primary : theme.colorScheme.secondary,
                ),
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
              border: note || error
                  ? Border.all(
                      color: error ? NymbotColors.danger : theme.dividerColor,
                    )
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.thinking != null)
                  Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
                      title: Text(t('💭 Reasoning'), style: TextStyle(fontSize: 12)),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(message.thinking!,
                              style: const TextStyle(fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                if (message.role == ChatRole.bot)
                  MarkdownBody(message.content)
                else
                  SelectableText(
                    message.content,
                    style: error ? const TextStyle(color: NymbotColors.danger) : null,
                  ),
              ],
            ),
          ),
          if (message.cost > 0 || message.model != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (message.model != null)
                    Text(message.model!, style: const TextStyle(fontSize: 11)),
                  if (message.model != null) const SizedBox(width: 8),
                  if (message.cost > 0)
                    Text('⚡ ${message.cost}',
                        style: const TextStyle(
                            fontSize: 11, color: NymbotColors.lightning)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}
