import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../models/workspace.dart';
import '../i18n/i18n.dart';

Future<void> showReposSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ReposSheet(),
    );

class _ReposSheet extends StatefulWidget {
  const _ReposSheet();

  @override
  State<_ReposSheet> createState() => _ReposSheetState();
}

class _ReposSheetState extends State<_ReposSheet> {
  final _host = TextEditingController();
  final _token = TextEditingController();
  final _repo = TextEditingController();
  final _branch = TextEditingController();
  final _paths = TextEditingController();
  final _label = TextEditingController();
  String _provider = 'github';
  bool _writes = false;
  String? _editingId;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    _repo.dispose();
    _branch.dispose();
    _paths.dispose();
    _label.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _editingId = null;
      _provider = 'github';
      _writes = false;
      _error = null;
      _host.clear();
      _token.clear();
      _repo.clear();
      _branch.clear();
      _paths.clear();
      _label.clear();
    });
  }

  void _edit(GitRepo r) {
    setState(() {
      _editingId = r.id;
      _provider = r.provider;
      _writes = r.allowWrites;
      _error = null;
      _host.text = r.host;
      _token.text = r.token;
      _repo.text = r.repo;
      _branch.text = r.branch;
      _paths.text = r.paths;
      _label.text = r.label;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final scoped = app.current?.repoIds ?? const <String>[];

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
            Text(t('Repositories'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('Connect as many repositories as you like and tick the ones this chat '
                  'can see. Pro replies read their code and, with writes on, commit, '
                  'branch and open pull requests. Access tokens are stored only on this '
                  'device and sent to the Nymbot worker per request — never stored '
                  'server-side or published to relays.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (app.repos.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  t('No repositories yet. Add one below and it becomes available to '
                      'every chat.'),
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ),
            for (final r in app.repos)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: Checkbox(
                    value: scoped.contains(r.id),
                    onChanged: (_) => app.toggleRepoHere(r.id),
                  ),
                  title: Text(r.display, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    r.allowWrites ? '${r.subtitle} · ${t('writes')}' : r.subtitle,
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: t('Edit'),
                        onPressed: () => _edit(r),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: t('Remove'),
                        onPressed: () => app.deleteRepo(r.id),
                      ),
                    ],
                  ),
                ),
              ),
            if (app.repos.isNotEmpty)
              Row(
                children: [
                  TextButton(
                    onPressed: () => app.setReposHere(const []),
                    child: Text(t('Use none here')),
                  ),
                  TextButton(
                    onPressed: () =>
                        app.setReposHere(app.repos.map((r) => r.id).toList()),
                    child: Text(t('Use all here')),
                  ),
                ],
              ),
            const Divider(height: 24),
            Text(
              _editingId == null ? t('Add a repository') : t('Edit repository'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: _provider,
              decoration: InputDecoration(labelText: t('Provider')),
              items: [
                const DropdownMenuItem(value: 'github', child: Text('GitHub')),
                const DropdownMenuItem(value: 'gitlab', child: Text('GitLab')),
                DropdownMenuItem(value: 'gitea', child: Text(t('Gitea / Forgejo'))),
                const DropdownMenuItem(value: 'bitbucket', child: Text('Bitbucket')),
                const DropdownMenuItem(value: 'codeberg', child: Text('Codeberg')),
              ],
              onChanged: (v) => setState(() => _provider = v ?? 'github'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _host,
              decoration:
                  InputDecoration(labelText: t('Host'), hintText: 'github.com'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _token,
              obscureText: true,
              decoration: InputDecoration(labelText: t('Access token')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _repo,
              decoration:
                  InputDecoration(labelText: t('Repository'), hintText: 'owner/repo'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _branch,
              decoration: InputDecoration(labelText: t('Branch'), hintText: 'main'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _paths,
              decoration: InputDecoration(
                labelText: t('Only these paths (optional)'),
                hintText: 'src/, docs/README.md',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _label,
              decoration: InputDecoration(
                  labelText: t('Label (optional)'), hintText: 'Frontend'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _writes,
              title: Text(t('Allow commits, branches and pull requests'),
                  style: const TextStyle(fontSize: 13)),
              onChanged: (v) => setState(() => _writes = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: () async {
                if (_token.text.trim().isEmpty || _repo.text.trim().isEmpty) {
                  setState(() =>
                      _error = t('A token and a repository are both needed.'));
                  return;
                }
                await app.saveRepo(
                  GitRepo(
                    id: _editingId ?? bytesToHex(randomBytes(8)),
                    repo: _repo.text.trim(),
                    token: _token.text.trim(),
                    provider: _provider,
                    host: _host.text.trim(),
                    branch: _branch.text.trim(),
                    paths: _paths.text.trim(),
                    label: _label.text.trim(),
                    allowWrites: _writes,
                  ),
                  useHere: _editingId == null,
                );
                _reset();
              },
              child: Text(_editingId == null ? t('Add repository') : t('Save changes')),
            ),
            if (_editingId != null)
              TextButton(onPressed: _reset, child: Text(t('Cancel'))),
          ],
        ),
      ),
    );
  }
}
