import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../models/conversation.dart';
import '../markdown_body.dart';
import '../i18n/i18n.dart';
import '../../core/theme/theme.dart';

typedef MessageJump = ({String conversationId, String? messageId});

Future<MessageJump?> showSearchSheet(BuildContext context, {String term = ''}) =>
    showModalBottomSheet<MessageJump>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SearchSheet(term: term),
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

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.45),
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
    showModalBottomSheet<MessageJump>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _SavedSheet(),
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
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55),
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

Future<void> showTagsSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _TagsSheet(),
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
    );
  }
}

Future<void> showStatsSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _StatsSheet(),
    );

class _StatsSheet extends StatelessWidget {
  const _StatsSheet();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final stats = app.currentStats();
    final usage = app.store.usage();

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

    return Padding(
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
            cell('${stats.credits}', t('Credits spent here')),
            cell('${stats.words}', t('Words exchanged')),
          ]),
          Row(children: [
            cell('${usage.credits}', t('Credits spent overall')),
            cell('${usage.replies}', t('Replies overall')),
          ]),
        ],
      ),
    );
  }
}

Future<void> showShortcutsSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ShortcutsSheet(),
    );

class _ShortcutsSheet extends StatelessWidget {
  const _ShortcutsSheet();

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('?', t('Commands, typed at the start of a message')),
      ('!', t('Send a message without this chat\'s history')),
      (t('Long press a message'), t('Copy, quote, branch, rate or save it')),
      (t('Swipe from the left'), t('Open the chat list')),
      (t('Pull the composer'), t('Attach a file')),
    ];
    return Padding(
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
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).dividerColor),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(row.$1,
                        style: const TextStyle(fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback, fontSize: 11)),
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
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
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
                ('share', Icons.ios_share, t('Share the transcript')),
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
