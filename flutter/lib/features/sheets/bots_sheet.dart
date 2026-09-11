import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../models/bot.dart';
import '../i18n/i18n.dart';
import '../../core/theme/theme.dart';
import '../nym_glyph.dart';
import '../nym_glyphs.dart';

Future<void> showBotsSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _BotsSheet(),
    );

class _BotsSheet extends StatefulWidget {
  const _BotsSheet();

  @override
  State<_BotsSheet> createState() => _BotsSheetState();
}

class _BotsSheetState extends State<_BotsSheet> {
  final _name = TextEditingController();
  final _tagline = TextEditingController();
  final _body = TextEditingController();
  final _starters = TextEditingController();
  String? _editingId;
  String _icon = 'robot';
  String _status = '';
  String? _modelKey;
  Map<String, dynamic>? _catalog;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _tagline.dispose();
    _body.dispose();
    _starters.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final catalog = await AppScope.read(context).api.models();
    if (mounted) AppScope.read(context).notePricing(catalog);
    if (!mounted) return;
    setState(() => _catalog = catalog);
  }

  List<Map<String, dynamic>> get _models =>
      (_catalog?['models'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

  void _reset() => setState(() {
        _editingId = null;
        _icon = 'robot';
        _status = '';
        _modelKey = null;
        _name.clear();
        _tagline.clear();
        _body.clear();
        _starters.clear();
      });

  void _edit(Bot bot) => setState(() {
        _editingId = bot.id;
        _icon = bot.icon;
        _status = '';
        _modelKey = bot.modelKey;
        _name.text = bot.name;
        _tagline.text = bot.tagline;
        _body.text = bot.instructions;
        _starters.text = bot.starters.join('\n');
      });

  Future<void> _save() async {
    final app = AppScope.read(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _status = t('Give the bot a name.'));
      return;
    }
    final existing = app.bots.where((b) => b.id == _editingId);
    final bot = existing.isEmpty
        ? Bot(id: bytesToHex(randomBytes(8)))
        : existing.first;
    Map<String, dynamic>? model;
    for (final m in _models) {
      if (m['key'] == _modelKey) model = m;
    }
    bot.name = name;
    bot.tagline = _tagline.text.trim();
    bot.icon = _icon;
    bot.instructions = _body.text.trim();
    bot.modelKey = _modelKey;
    bot.modelLabel = model?['label'] as String?;
    bot.starters = _starters.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    await app.saveBot(bot);
    if (!mounted) return;
    _reset();
  }

  Future<void> _use(Bot? bot) async {
    final app = AppScope.read(context);
    Map<String, dynamic>? model;
    if (bot?.modelKey != null) {
      for (final m in _models) {
        if (m['key'] == bot!.modelKey) model = m;
      }
      model ??= {'key': bot!.modelKey, 'label': bot.modelLabel ?? bot.modelKey};
    }
    await app.setBot(bot?.id, model: model);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final active = app.current?.botId;

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
            Text(t('Bots'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('A bot is a way of answering: a name, standing instructions, a model '
                  'and a few openers. Share one as a link or publish it under your '
                  'npub. A shared bot carries none of your repositories, tokens or '
                  'files — only how it answers.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (app.bots.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  t('No bots yet. Make one, or add a link somebody sent you.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            for (final bot in app.bots)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                color: bot.id == active
                    ? theme.colorScheme.primary.withValues(alpha: 0.10)
                    : null,
                child: ListTile(
                  dense: true,
                  leading: NymGlyph(bot.icon, size: 20),
                  title: Text(bot.name.isEmpty ? t('Untitled') : bot.name),
                  subtitle: Text(
                    bot.tagline.isNotEmpty
                        ? bot.tagline
                        : bot.modelLabel ?? t('Auto-routed'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => _use(bot.id == active ? null : bot),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.ios_share, size: 17),
                        tooltip: t('Share'),
                        onPressed: () => showShareBot(context, bot),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        tooltip: t('Edit'),
                        onPressed: () => _edit(bot),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 17),
                        tooltip: t('Delete'),
                        onPressed: () => app.deleteBot(bot.id),
                      ),
                    ],
                  ),
                ),
              ),
            if (active != null)
              TextButton(
                onPressed: () => _use(null),
                child: Text(t('Back to plain Nymbot')),
              ),
            OutlinedButton.icon(
              onPressed: () => showAddBot(context),
              icon: const Icon(Icons.add, size: 18),
              label: Text(t('Add a shared bot')),
            ),
            const Divider(height: 24),
            Text(_editingId == null ? t('New bot') : t('Edit bot'),
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: t('Name')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tagline,
              decoration: InputDecoration(labelText: t('One line about it')),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(t('Icon'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final name in kNymPersonaGlyphs)
                  ChoiceChip(
                    label: NymGlyph(name, size: 17),
                    selected: _icon == name,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _icon = name),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              maxLines: 5,
              minLines: 3,
              decoration: InputDecoration(
                labelText: t('Standing instructions'),
                hintText: t('How it should answer, every time'),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _modelKey,
              isExpanded: true,
              decoration: InputDecoration(labelText: t('Model')),
              items: [
                DropdownMenuItem(
                    value: null, child: Text(t('Auto-routed (standard)'))),
                for (final m in _models)
                  DropdownMenuItem(
                    value: m['key'] as String,
                    child: Text(
                      '${m['label']} · ${figure((m['credits'] as num?)?.toInt() ?? 1)}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _modelKey = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _starters,
              maxLines: 4,
              minLines: 2,
              decoration: InputDecoration(
                labelText: t('Openers, one per line'),
              ),
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    child: Text(t('Save bot')),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                    onPressed: _reset, child: Text(t('Clear the form'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showShareBot(BuildContext context, Bot bot) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ShareBot(bot: bot),
    );

class _ShareBot extends StatefulWidget {
  const _ShareBot({required this.bot});

  final Bot bot;

  @override
  State<_ShareBot> createState() => _ShareBotState();
}

class _ShareBotState extends State<_ShareBot> {
  String _status = '';
  bool _busy = false;

  Future<void> _publish() async {
    final app = AppScope.read(context);
    setState(() {
      _busy = true;
      _status = t('Publishing…');
    });
    try {
      final accepted = await app.publishBot(widget.bot);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = accepted > 0
            ? t('Published to {n} relays. Republishing replaces it rather than making a second copy.',
                {'n': accepted})
            : t('No relay accepted it. Check your connection and try again.');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = widget.bot.link();

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
            Text(widget.bot.name, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('Anyone with this link gets the bot, not your account. It carries '
                  'the name, the instructions, the model and the openers — nothing '
                  'else.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 14),
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.white,
                child: QrImageView(
                  data: link,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(link,
                style: const TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 11)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(t('Copy the link')),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: link)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.ios_share, size: 16),
                    label: Text(t('Share')),
                    onPressed: () =>
                        Share.share(link, subject: widget.bot.name),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _publish,
              child: Text(t('Publish under my npub')),
            ),
            if (widget.bot.naddr.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(t('Address'),
                    style: TextStyle(fontSize: 12, color: theme.hintColor)),
              ),
              SelectableText(widget.bot.naddr,
                  style:
                      const TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 11)),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status,
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> showAddBot(BuildContext context, {String prefill = ''}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddBot(prefill: prefill),
    );

class _AddBot extends StatefulWidget {
  const _AddBot({this.prefill = ''});

  final String prefill;

  @override
  State<_AddBot> createState() => _AddBotState();
}

class _AddBotState extends State<_AddBot> {
  final _input = TextEditingController();
  String _status = '';
  bool _busy = false;
  Bot? _found;

  @override
  void initState() {
    super.initState();
    _input.text = widget.prefill;
    if (widget.prefill.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookUp());
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _lookUp() async {
    final app = AppScope.read(context);
    final text = _input.text.trim();
    if (text.isEmpty) {
      setState(() => _status = t('Paste a link or an address first.'));
      return;
    }
    final fromLink = Bot.fromLink(text, id: bytesToHex(randomBytes(8)));
    if (fromLink != null) {
      setState(() {
        _found = fromLink;
        _status = '';
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = t('Looking it up on the relays…');
    });
    final fetched = await app.fetchBot(text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _found = fetched;
      _status = fetched == null
          ? t('No relay had that bot. It may have been unpublished.')
          : '';
    });
  }

  Future<void> _accept() async {
    final app = AppScope.read(context);
    final navigator = Navigator.of(context);
    await app.saveBot(_found!);
    if (!mounted) return;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bot = _found;

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
            Text(t('Add a bot'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(t('Paste a bot link or an address published on Nostr.'),
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              maxLines: 3,
              minLines: 2,
              decoration: InputDecoration(
                labelText: t('Link or address'),
                hintText: 'naddr1…',
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _busy ? null : _lookUp,
              child: Text(t('Look it up')),
            ),
            if (bot != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        NymGlyph(bot.icon, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(bot.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    if (bot.tagline.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(bot.tagline, style: const TextStyle(fontSize: 12)),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      bot.modelLabel != null
                          ? t('Model: {name}', {'name': bot.modelLabel})
                          : t('Auto-routed'),
                      style:
                          TextStyle(fontSize: 12, color: theme.hintColor),
                    ),
                    if (bot.instructions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: SingleChildScrollView(
                          child: Text(bot.instructions,
                              style: const TextStyle(
                                  fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 11)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      t('Instructions from a stranger are still instructions. Read them before you use it.'),
                      style:
                          TextStyle(fontSize: 11, color: theme.hintColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(onPressed: _accept, child: Text(t('Add it'))),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status,
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ],
          ],
        ),
      ),
    );
  }
}
