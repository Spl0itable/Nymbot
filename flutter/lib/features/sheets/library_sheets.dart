import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../models/conversation.dart';
import '../command_palette.dart';
import '../markdown_body.dart';
import '../i18n/i18n.dart';
import '../../core/theme/theme.dart';
import 'sheet.dart';

typedef MessageJump = ({String conversationId, String? messageId});

Future<MessageJump?> showSearchSheet(BuildContext context, {String term = ''}) =>
    showNymSheet<MessageJump>(
      context,
      (_) => _SearchSheet(term: term),
    );

class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.term});

  final String term;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  late final TextEditingController _field =
      TextEditingController(text: widget.term);
  late String _term = widget.term;
  bool _archived = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final hits = app.store.searchAll(_term, includeArchived: _archived);
    final media = MediaQuery.of(context);
    final tight = media.size.height - media.viewInsets.bottom < 520 ||
        media.textScaler.scale(1) > 1.3;
    final head = [
      Text(t('Search everything'),
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      TextField(
        controller: _field,
        autofocus: true,
        decoration: InputDecoration(hintText: t('Search every message')),
        onChanged: (v) => setState(() => _term = v),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: _archived,
        title: Text(t('Include archived chats'),
            style: const TextStyle(fontSize: 13)),
        onChanged: (v) => setState(() => _archived = v),
      ),
    ];

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: media.viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tight)
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight:
                      (media.size.height - media.viewInsets.bottom) * 0.4),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: head,
                ),
              ),
            )
          else
            ...head,
          Flexible(
            child: _term.trim().isEmpty
                ? Center(
                    child: Text(
                      t('Type to search every message on this device.'),
                      style: TextStyle(color: Theme.of(context).hintColor),
                    ),
                  )
                : hits.isEmpty
                    ? Center(
                        child: Text(t('Nothing matches that.'),
                            style: TextStyle(color: Theme.of(context).hintColor)),
                      )
                    : ListView.builder(
                        key: const ValueKey('search-results'),
                        shrinkWrap: true,
                        itemCount: hits.length > 120 ? 120 : hits.length,
                        itemBuilder: (context, i) {
                          final hit = hits[i];
                          return ListTile(
                            dense: true,
                            title: Text(
                              hit.conv.title.isEmpty ? t('New chat') : hit.conv.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              hit.excerpt,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: () => Navigator.pop(context, (
                              conversationId: hit.conv.id,
                              messageId: hit.message?.id,
                            )),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

Future<MessageJump?> showSavedMessagesSheet(BuildContext context) =>
    showNymSheet<MessageJump>(
      context,
      (_) => const _SavedSheet(),
    );

class _SavedSheet extends StatefulWidget {
  const _SavedSheet();

  @override
  State<_SavedSheet> createState() => _SavedSheetState();
}

class _SavedSheetState extends State<_SavedSheet> {
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final rows = app.store.pinnedMessages();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('Saved messages'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                t('Nothing saved yet. Use the star under any message.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                return ListTile(
                  dense: true,
                  title: Text(
                    row.conv.title.isEmpty ? t('New chat') : row.conv.title,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    MarkdownBody.plain(row.message.content),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => Navigator.pop(context, (
                    conversationId: row.conv.id,
                    messageId: row.message.id,
                  )),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy_all_outlined, size: 17),
                    tooltip: t('Copy'),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: row.message.content)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showTagsSheet(BuildContext context) => showNymSheet<void>(
      context,
      (_) => const _TagsSheet(),
    );

class _TagsSheet extends StatefulWidget {
  const _TagsSheet();

  @override
  State<_TagsSheet> createState() => _TagsSheetState();
}

class _TagsSheetState extends State<_TagsSheet> {
  late final TextEditingController _tags = TextEditingController(
      text: (AppScope.read(context).current?.tags ?? const []).join(', '));
  final _folder = TextEditingController();
  String? _folderId;

  @override
  void initState() {
    super.initState();
    _folderId = AppScope.read(context).current?.folderId;
  }

  @override
  void dispose() {
    _tags.dispose();
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final folders = app.folders;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('Tags and folder'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _tags,
              decoration: InputDecoration(
                labelText: t('Tags'),
                hintText: 'work, crypto, draft',
                helperText: t('Comma separated. Tags show in the chat list and are searchable.'),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              isExpanded: true,
              // ignore: deprecated_member_use
              value: folders.any((f) => f.id == _folderId) ? _folderId : null,
              decoration: InputDecoration(labelText: t('Folder')),
              items: [
                DropdownMenuItem<String?>(value: null, child: Text(t('No folder'))),
                for (final f in folders)
                  DropdownMenuItem<String?>(value: f.id, child: Text(f.name)),
              ],
              onChanged: (v) => setState(() => _folderId = v),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _folder,
                    decoration: InputDecoration(
                        labelText: t('Or create one'), hintText: 'Projects'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    if (_folder.text.trim().isEmpty) return;
                    final created = await app.createFolder(_folder.text.trim());
                    _folder.clear();
                    setState(() => _folderId = created.id);
                  },
                  child: Text(t('Create')),
                ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () async {
                await app.setTagsAndFolder(
                  _tags.text.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList(),
                  _folderId,
                );
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(t('Save')),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showStatsSheet(BuildContext context) => showNymSheet<void>(
      context,
      (_) => const _StatsSheet(),
    );

class _StatsSheet extends StatelessWidget {
  const _StatsSheet();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final stats = app.currentStats();
    final device = app.deviceStats();

    Widget cell(String value, String label) => Expanded(
          child: Container(
            margin: const EdgeInsets.all(4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: Theme.of(context).textTheme.titleLarge),
                Text(label,
                    style:
                        TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
              ],
            ),
          ),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('Chat statistics'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(children: [
            cell('${stats.sent}', t('Messages sent')),
            cell('${stats.replies}', t('Replies')),
          ]),
          Row(children: [
            cell(creditFigure(stats.standard), t('Standard credits spent here')),
            cell(creditFigure(stats.pro), t('Pro credits spent here')),
          ]),
          Row(children: [
            cell('${stats.words}', t('Words exchanged')),
          ]),
          Row(children: [
            cell(creditFigure(device.standard),
                t('Standard credits spent in chats on this device')),
            cell(creditFigure(device.pro),
                t('Pro credits spent in chats on this device')),
          ]),
          Row(children: [
            cell('${device.replies}', t('Replies in chats on this device')),
          ]),
          Text(
            t('Standard and Pro are separate balances, so they are counted '
                'apart. Chats deleted from this device are not counted.'),
            style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
          ),
          if (app.current != null && app.capUsedLineOf(app.current!).isNotEmpty)
            Row(children: [
              cell(app.capUsedLineOf(app.current!), t('Spending cap')),
            ]),
        ],
      ),
    );
  }
}

Future<void> showShortcutsSheet(BuildContext context) => showNymSheet<void>(
      context,
      (_) => const _ShortcutsSheet(),
    );

class _ShortcutsSheet extends StatelessWidget {
  const _ShortcutsSheet();

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('?', t('Commands, typed at the start of a message')),
      ('!', t('Send a message without this chat\'s history')),
      (t('Tap a message'), t('Copy, quote, branch, rate or save it')),
      (t('Press and hold text'), t('Select part of a message to copy it')),
      (t('Swipe from the left'), t('Open the chat list')),
      (t('The paperclip'), t('Attach a file or a picture')),
      (shortcutLabel('K'), t('Open the command palette')),
      (shortcutLabel('B / I / E'), t('Bold, italic or code in the composer')),
      (shortcutLabel('Shift+E'), t('A fenced code block in the composer')),
      (shortcutLabel('Enter'), t('Send')),
      (t('Shift+Enter'), t('A new line, when Enter sends')),
      (shortcutLabel('F'), t('Find in this chat')),
      (shortcutLabel('Shift+F'), t('Search every chat')),
      (shortcutLabel('N'), t('New chat')),
      (t('Esc'), t('Close a sheet or the find bar')),
      (t('Shift+Esc'), t('Stop the reply being written')),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('Getting around'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        border:
                            Border.all(color: Theme.of(context).dividerColor),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(row.$1,
                          style: const TextStyle(
                              fontFamily: kMonoFamily,
                              fontFamilyFallback: kMonoFallback,
                              fontSize: 11)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(row.$2, style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Future<String?> showChatMenu(BuildContext context, Conversation conv) =>
    showNymSheet<String>(
      context,
      (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in <(String, IconData, String)>[
                ('find', Icons.search, t('Find in this chat')),
                ('rename', Icons.edit_outlined, t('Rename')),
                ('pin', conv.pinned ? Icons.star : Icons.star_border,
                    conv.pinned ? t('Unpin') : t('Pin')),
                ('archive', Icons.archive_outlined,
                    conv.archived ? t('Unarchive') : t('Archive')),
                ('duplicate', Icons.copy_all_outlined, t('Duplicate')),
                ('system', Icons.tune, t('Custom instructions')),
                ('tags', Icons.sell_outlined, t('Tags and folder')),
                ('stats', Icons.insights_outlined, t('Chat statistics')),
                ('caps', Icons.savings_outlined, t('Spending caps')),
                ('share-link', Icons.link, t('Share a link')),
                ('share', Icons.ios_share, t('Share the transcript')),
                ('export-md', Icons.description_outlined, t('Export as Markdown')),
                ('export-txt', Icons.notes, t('Export as plain text')),
                ('export-json', Icons.data_object, t('Export as JSON')),
                ('copy', Icons.copy_all_outlined, t('Copy the transcript')),
                ('clear', Icons.cleaning_services_outlined, t('Clear this chat')),
                ('delete', Icons.delete_outline, t('Delete')),
              ])
                ListTile(
                  dense: true,
                  leading: Icon(item.$2, size: 19),
                  title: Text(item.$3),
                  onTap: () => Navigator.pop(context, item.$1),
                ),
            ],
          ),
        ),
      ),
    );
