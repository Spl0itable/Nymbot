import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../models/workspace.dart';
import '../../services/attachments.dart';
import '../i18n/i18n.dart';

Future<void> showWorkspacesSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _WorkspacesSheet(),
    );

class _WorkspacesSheet extends StatefulWidget {
  const _WorkspacesSheet();

  @override
  State<_WorkspacesSheet> createState() => _WorkspacesSheetState();
}

class _WorkspacesSheetState extends State<_WorkspacesSheet> {
  final _name = TextEditingController();
  final _body = TextEditingController();
  String? _editingId;
  String _error = '';
  List<KnowledgeFile> _files = [];
  List<String> _repoIds = [];

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
        _editingId = null;
        _error = '';
        _files = [];
        _repoIds = [];
        _name.clear();
        _body.clear();
      });

  void _edit(Workspace space) => setState(() {
        _editingId = space.id;
        _error = '';
        _files = [...space.files];
        _repoIds = [...space.repoIds];
        _name.text = space.name;
        _body.text = space.instructions;
      });

  Future<void> _addFiles() async {
    final picked = await Attachments.pick();
    if (!mounted) return;
    final added = <KnowledgeFile>[];
    for (final f in picked.files) {
      final text = f.text;
      if (f.kind != AttachmentKind.text || text == null) continue;
      added.add(KnowledgeFile(
        id: bytesToHex(randomBytes(8)),
        name: f.name,
        mime: f.mime,
        body: text,
      ));
    }
    setState(() {
      _files = [..._files, ...added];
      _error = added.length < picked.files.length || picked.problems.isNotEmpty
          ? t('Only text and code can be project knowledge.')
          : '';
    });
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = t('Give the workspace a name.'));
      return;
    }
    final existing = app.workspaces.where((w) => w.id == _editingId);
    final space = existing.isEmpty
        ? Workspace(id: bytesToHex(randomBytes(8)))
        : existing.first;
    space.name = name;
    space.instructions = _body.text.trim();
    space.files = _files;
    space.repoIds = _repoIds;
    await app.saveWorkspace(space);
    if (!mounted) return;
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final active = app.current?.workspaceId;

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
            Text(t('Workspaces'), style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('A workspace is standing context: instructions, reference files and '
                  'repositories that every chat in it starts with. The files stay on '
                  'this device and travel only inside the first message of a chat '
                  'that uses them.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (app.workspaces.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  t('No workspaces yet. One holds the instructions, files and repositories a run of chats shares.'),
                  style:
                      TextStyle(fontSize: 12, color: theme.hintColor),
                ),
              ),
            for (final space in app.workspaces)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                color: space.id == active
                    ? theme.colorScheme.primary.withValues(alpha: 0.10)
                    : null,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text(space.name.isEmpty ? t('Untitled') : space.name),
                  subtitle: Text(
                    [
                      t('{n} files', {'n': space.files.length}),
                      t('{n} repos', {'n': space.repoIds.length}),
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () =>
                      app.setWorkspace(space.id == active ? null : space.id),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        tooltip: t('Edit'),
                        onPressed: () => _edit(space),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 17),
                        tooltip: t('Delete'),
                        onPressed: () => app.deleteWorkspace(space.id),
                      ),
                    ],
                  ),
                ),
              ),
            if (active != null)
              TextButton(
                onPressed: () => app.setWorkspace(null),
                child: Text(t('No workspace in this chat')),
              ),
            const Divider(height: 24),
            Text(
              _editingId == null ? t('New workspace') : t('Edit workspace'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: t('Name')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              maxLines: 4,
              minLines: 2,
              decoration: InputDecoration(
                labelText: t('Standing instructions'),
                hintText: t('What every chat in here should know'),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(t('Repositories'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ),
            const SizedBox(height: 6),
            if (app.repos.isEmpty)
              Text(t('Connect a repository first and it can be attached here.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor))
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final repo in app.repos)
                    FilterChip(
                      label: Text(repo.display,
                          style: const TextStyle(fontSize: 12)),
                      selected: _repoIds.contains(repo.id),
                      visualDensity: VisualDensity.compact,
                      onSelected: (on) => setState(() {
                        _repoIds = on
                            ? [..._repoIds, repo.id]
                            : _repoIds.where((x) => x != repo.id).toList();
                      }),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(t('Knowledge files'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ),
            const SizedBox(height: 6),
            if (_files.isEmpty)
              Text(
                  t('No files yet. Text and code go in whole; nothing is uploaded anywhere.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor))
            else
              for (final file in _files)
                Card(
                  margin: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.description_outlined, size: 18),
                    title:
                        Text(file.name, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${file.size} ${t('characters')}',
                        style: const TextStyle(fontSize: 11)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 17),
                      tooltip: t('Remove'),
                      onPressed: () => setState(() {
                        _files = _files.where((f) => f.id != file.id).toList();
                      }),
                    ),
                  ),
                ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _addFiles,
              icon: const Icon(Icons.attach_file, size: 18),
              label: Text(t('Add a file')),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_error,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _save,
                    child: Text(t('Save workspace')),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _reset,
                  child: Text(t('Clear the form')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
