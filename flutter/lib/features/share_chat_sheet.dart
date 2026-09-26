import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/theme/theme.dart';
import '../models/conversation.dart';
import '../services/chat_share.dart';
import '../state/app_controller.dart';
import 'i18n/i18n.dart';
import 'markdown_body.dart';
import 'sheets/sheet.dart';
import 'nym_glyph.dart';

ChatShareService chatShareFor(AppController app) => ChatShareService(
      blossom: app.blossom,
      readRecords: () => app.store.secret('chat_shares'),
      writeRecords: (json) => app.store.setSecret('chat_shares', json),
    );

Future<void> showShareChatSheet(BuildContext context, AppController app,
        Conversation conv, List<ChatMessage> messages) =>
    showNymSheet<void>(
      context,
      (_) => _ShareChatSheet(app: app, conv: conv, messages: messages),
    );

class _ShareChatSheet extends StatefulWidget {
  const _ShareChatSheet(
      {required this.app, required this.conv, required this.messages});

  final AppController app;
  final Conversation conv;
  final List<ChatMessage> messages;

  @override
  State<_ShareChatSheet> createState() => _ShareChatSheetState();
}

class _ShareChatSheetState extends State<_ShareChatSheet> {
  late final ChatShareService _service = chatShareFor(widget.app);
  ShareOptions _options = const ShareOptions();
  List<ShareRecord> _records = const [];
  ShareRecord? _current;
  String _status = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRecords());
  }

  Future<void> _loadRecords() async {
    final list = await _service.records(widget.conv.id);
    if (mounted) setState(() => _records = list);
  }

  Map<String, dynamic> get _transcript =>
      ChatShare.build(widget.conv, widget.messages, _options);

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _status = t('Encrypting and uploading…');
    });
    try {
      final record =
          await _service.create(widget.conv, widget.messages, _options);
      if (!mounted) return;
      setState(() {
        _current = record;
        _busy = false;
        _status = t(
            'Anyone with this link can read what you included. Nymbot only holds ciphertext; the key is in the link.');
      });
      await _loadRecords();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = e.toString();
      });
    }
  }

  Future<void> _copy(String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          content: Text(t('Copied.')), duration: const Duration(seconds: 3)));
  }

  Future<void> _stop(ShareRecord record) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Stop sharing')),
        content: Text(t(
            'This deletes the encrypted copy from Nymbot and forgets the link on this device. Anyone who already opened it may have kept a copy, and that cannot be taken back.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Stop sharing')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _status = t('Deleting…'));
    final deleted = await _service.stop(widget.conv.id, record);
    if (!mounted) return;
    setState(() {
      if (_current?.id == record.id) _current = null;
      _status = deleted
          ? t('Deleted. The link no longer opens. Anyone who already opened it may have kept a copy.')
          : t('Nymbot did not confirm the delete, so the encrypted copy may still be stored. The link is forgotten on this device. Anyone who already opened it may have kept a copy.');
    });
    await _loadRecords();
  }

  Future<void> _post() async {
    final record = _current;
    if (record == null || widget.conv.anon) return;
    final comment = TextEditingController();
    var understood = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(t('Post to Nostr')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t(
                    'This publishes a public note, signed by your key, that anyone can read and that cannot be reliably deleted. It contains the link, so anyone who sees the note can open this chat.')),
                const SizedBox(height: 10),
                TextField(
                  controller: comment,
                  maxLines: 4,
                  minLines: 2,
                  decoration:
                      InputDecoration(labelText: t('Comment (optional)')),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: understood,
                  onChanged: (v) => setLocal(() => understood = v ?? false),
                  title: Text(
                      t('I understand this note is public and signed by my key'),
                      style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(t('Cancel'))),
            FilledButton(
              onPressed:
                  understood ? () => Navigator.pop(context, true) : null,
              child: Text(t('Post publicly')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _status = t('Publishing…'));
    try {
      final app = widget.app;
      final accepted = await _service.postNote(widget.conv, record,
          comment.text, app.identity.signer, (e) => app.relays.publish(e));
      if (!mounted) return;
      setState(() => _status = accepted > 0
          ? t('Posted to {n} relays.', {'n': accepted})
          : t('No relay accepted it. Check your connection and try again.'));
    } catch (e) {
      if (mounted) setState(() => _status = e.toString());
    }
  }

  String _snippet(String text) {
    final flat = text.replaceAll('\n', ' ');
    return flat.length > 60 ? flat.substring(0, 60) : flat;
  }

  String _stamp(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _message(Map<String, dynamic> m, ThemeData theme) {
    final self = m['role'] == 'user';
    final sources = (m['sources'] as List?)?.cast<Map>() ?? const [];
    final files = (m['attachments'] as List?)?.cast<Map>() ?? const [];
    final reasoning = m['reasoning'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: self
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : theme.colorScheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              self ? t('User') : 'Nymbot',
              if (m['model'] is String) m['model'] as String,
            ].join(' · '),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: self ? null : theme.colorScheme.primary),
          ),
          const SizedBox(height: 4),
          for (final f in files)
            if (f['kind'] == 'image' && f['data'] is String)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Image.memory(
                  base64Decode((f['data'] as String).split(',').last),
                  height: 90,
                  errorBuilder: (_, __, ___) => Text('${f['name']}'),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${f['name']}${f['text'] is String ? '\n${f['text']}' : ''}',
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          if (reasoning != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('${t('Reasoning')}: $reasoning',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: theme.hintColor)),
            ),
          MarkdownBody(m['content'] as String),
          if (sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                sources.map((s) => '${s['title'] ?? s['url']}').join(' · '),
                style: TextStyle(fontSize: 11, color: theme.hintColor),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transcript = _transcript;
    final shown = (transcript['messages'] as List).cast<Map<String, dynamic>>();
    final choices = ChatShare.shareable(widget.messages);
    final current = _current;

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
            Text(t('Share a link to this chat'),
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('The chat is encrypted on this device before it leaves. The key travels only in the link, so Nymbot stores something it cannot read. Anyone you give the link to can read what you include.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: InputDecoration(labelText: t('Messages')),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  key: const ValueKey('share-upto'),
                  value: _options.upTo,
                  isExpanded: true,
                  isDense: true,
                  items: [
                    DropdownMenuItem(
                        value: null, child: Text(t('The whole chat'))),
                    for (var i = 0; i < choices.length - 1; i++)
                      DropdownMenuItem(
                        value: choices[i].id,
                        child: Text(
                          t('Up to {n}. {who}: {text}', {
                            'n': i + 1,
                            'who': choices[i].role == ChatRole.self
                                ? t('You')
                                : 'Nymbot',
                            'text': _snippet(choices[i].content),
                          }),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _options =
                      _options.copyWith(upTo: v, clearUpTo: v == null)),
                ),
              ),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _options.sources,
              title: Text(t('Sources')),
              onChanged: (v) => setState(
                  () => _options = _options.copyWith(sources: v ?? false)),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _options.reasoning,
              title: Text(t('Reasoning')),
              onChanged: (v) => setState(
                  () => _options = _options.copyWith(reasoning: v ?? false)),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _options.files,
              title: Text(t('Text of attached files')),
              onChanged: (v) => setState(
                  () => _options = _options.copyWith(files: v ?? false)),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _options.images,
              title: Text(t('Images')),
              onChanged: (v) => setState(
                  () => _options = _options.copyWith(images: v ?? false)),
            ),
            Text(ChatShare.summary(transcript),
                style: TextStyle(fontSize: 12, color: theme.hintColor)),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 280),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final m in shown) _message(m, theme)],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (current != null) ...[
              SelectableText(current.link,
                  style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _copy(current.link),
                    icon: const NymGlyph('copy', size: 16),
                    label: Text(t('Copy the link')),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Share.share(current.link,
                        subject: widget.conv.title.isEmpty
                            ? t('Shared chat')
                            : widget.conv.title),
                    icon: const Icon(Icons.ios_share, size: 16),
                    label: Text(t('Share…')),
                  ),
                  if (!widget.conv.anon)
                    OutlinedButton.icon(
                      onPressed: _post,
                      icon: const NymGlyph('globe', size: 16),
                      label: Text(t('Also post to Nostr…')),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_status, style: const TextStyle(fontSize: 12)),
              ),
            FilledButton(
              onPressed: _busy || shown.isEmpty ? null : _create,
              child: Text(t('Create the link')),
            ),
            if (_records.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(t('Links to this chat'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              for (final r in _records.reversed)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    title: Text(_stamp(r.createdAt)),
                    subtitle: Text(ChatShare.includedText(r.included)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const NymGlyph('copy', size: 17),
                          tooltip: t('Copy'),
                          onPressed: () => _copy(r.link),
                        ),
                        IconButton(
                          icon: const NymGlyph('close',
                              size: 17, color: NymbotColors.danger),
                          tooltip: t('Stop sharing'),
                          onPressed: () => _stop(r),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
