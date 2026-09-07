import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../models/memory.dart';
import '../../state/app_controller.dart';
import '../i18n/i18n.dart';

Future<void> showMemorySheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _MemorySheet(),
    );

class _MemorySheet extends StatefulWidget {
  const _MemorySheet();

  @override
  State<_MemorySheet> createState() => _MemorySheetState();
}

class _MemorySheetState extends State<_MemorySheet> {
  final _search = TextEditingController();
  final _text = TextEditingController();
  final _topic = TextEditingController();
  String? _scope;
  String? _editingId;
  bool _scopeSet = false;

  @override
  void dispose() {
    _search.dispose();
    _text.dispose();
    _topic.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _editingId = null;
      _text.clear();
      _topic.clear();
    });
  }

  Future<void> _save(AppController app) async {
    if (_text.text.trim().isEmpty) return;
    await app.saveMemory(Memory(
      id: _editingId ?? bytesToHex(randomBytes(8)),
      text: _text.text,
      topic: _topic.text.trim(),
      scope: _scope,
      source: 'you',
    ));
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    if (!_scopeSet) {
      _scope = app.current?.workspaceId;
      _scopeSet = true;
    }
    final needle = _search.text.trim().toLowerCase();
    final rows = app.memories
        .where((m) =>
            needle.isEmpty ||
            m.text.toLowerCase().contains(needle) ||
            m.topic.toLowerCase().contains(needle))
        .toList();

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
            Text(t('Memory'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              t('Standing facts Nymbot carries between chats, kept one at a '
                  'time so each can be read, corrected or thrown away on its '
                  'own. They live on this device; the few that bear on a '
                  'question travel inside that message, encrypted like '
                  'everything else you send. A ghost chat neither reads them '
                  'nor adds to them.'),
              style: TextStyle(fontSize: 12, color: theme.hintColor),
            ),
            const SizedBox(height: 10),
            if (app.memories.length > 4)
              TextField(
                controller: _search,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: t('Search what is remembered'),
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
                onChanged: (_) => setState(() {}),
              ),
            const SizedBox(height: 6),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  needle.isEmpty
                      ? t('Nothing remembered yet. Tell Nymbot something about '
                          'how you work, or write one in below.')
                      : t('Nothing remembered matches that.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            for (final entry in rows) _row(app, theme, entry),
            const Divider(height: 24),
            Text(t('Remember something'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: t('I prefer answers that show the code first.'),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _topic,
                    decoration: InputDecoration(
                        isDense: true, labelText: t('Topic')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    // ignore: deprecated_member_use
                    value: _scope,
                    isExpanded: true,
                    decoration: InputDecoration(
                        isDense: true, labelText: t('Applies to')),
                    items: [
                      DropdownMenuItem(value: null, child: Text(t('Every chat'))),
                      for (final space in app.workspaces)
                        DropdownMenuItem(
                          value: space.id,
                          child: Text(
                            space.name.isEmpty ? t('Untitled') : space.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _scope = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(
                  onPressed: () => _save(app),
                  child: Text(
                      _editingId == null ? t('Remember it') : t('Save changes')),
                ),
                if (_editingId != null) ...[
                  const SizedBox(width: 8),
                  TextButton(onPressed: _reset, child: Text(t('Cancel'))),
                ],
              ],
            ),
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: app.settings.memoryCapture,
              title: Text(t('Notice things worth remembering as I chat'),
                  style: const TextStyle(fontSize: 13)),
              onChanged: (v) {
                final s = app.settings;
                s.memoryCapture = v;
                app.saveSettings(s);
              },
            ),
            TextButton(
              onPressed: app.memories.isEmpty
                  ? null
                  : () async {
                      final go = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(t('Forget everything')),
                          content: Text(t('Throw away everything Nymbot '
                              'remembers about you? This cannot be undone.')),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: Text(t('Cancel'))),
                            FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: Text(t('Forget it all'))),
                          ],
                        ),
                      );
                      if (go == true) await app.clearMemories();
                    },
              child: Text(t('Forget everything')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(AppController app, ThemeData theme, Memory entry) {
    String? spaceName;
    for (final space in app.workspaces) {
      if (space.id == entry.scope) {
        spaceName = space.name.isEmpty ? t('Untitled') : space.name;
        break;
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      entry.topic.isEmpty ? t('Note') : entry.topic.toUpperCase(),
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 0.8,
                          color: theme.hintColor),
                    ),
                    if (spaceName != null) ...[
                      const SizedBox(width: 6),
                      _tag(theme, spaceName),
                    ],
                    if (entry.source == 'chat') ...[
                      const SizedBox(width: 6),
                      _tag(theme, t('noticed')),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(entry.text, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16),
            tooltip: t('Edit'),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() {
              _editingId = entry.id;
              _text.text = entry.text;
              _topic.text = entry.topic;
              _scope = entry.scope;
            }),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16),
            tooltip: t('Forget'),
            visualDensity: VisualDensity.compact,
            onPressed: () => app.deleteMemory(entry.id),
          ),
        ],
      ),
    );
  }

  Widget _tag(ThemeData theme, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 9.5, color: theme.hintColor)),
      );
}
