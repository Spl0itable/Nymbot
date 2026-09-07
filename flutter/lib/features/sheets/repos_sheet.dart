import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../models/workspace.dart';
import '../../services/git_forge.dart';
import '../../state/app_controller.dart';
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
  List<ForgeRepo>? _found;
  final _picked = <String>{};
  final _filter = TextEditingController();
  bool _asking = false;

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    _repo.dispose();
    _branch.dispose();
    _paths.dispose();
    _label.dispose();
    _filter.dispose();
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
      _found = null;
      _picked.clear();
      _filter.clear();
    });
  }

  /// Asks the forge what the token in the form can reach, so a chat is wired
  /// to a repository by ticking it rather than by typing its name exactly
  /// right. The request goes from this device straight to the forge.
  Future<void> _browse(AppController app) async {
    final token = _token.text.trim();
    if (token.isEmpty) {
      setState(() => _error =
          t('Paste a token first, and this will list what it can reach.'));
      return;
    }
    setState(() {
      _asking = true;
      _error = null;
    });
    try {
      final found = await GitForge.listRepos(
        provider: _provider,
        token: token,
        host: _host.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _found = found;
        _picked.clear();
        _filter.clear();
        _error = found.isEmpty ? t('That token reaches no repositories.') : null;
      });
    } on ForgeException catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.reason) {
            ForgeFailure.denied => t(
                'That token was refused. Check it has read access to repositories.'),
            ForgeFailure.noHost =>
              t('A self-hosted forge needs its host before it can be asked.'),
            ForgeFailure.unsupported => t(
                'This provider has no list to ask for. Type the repository in below.'),
            ForgeFailure.unreachable => t(
                'Could not reach that host from this device. Type the repository in below instead.'),
            _ => t('The forge answered with an error. Type the repository in below instead.'),
          });
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// Connects every ticked repository, carrying the token, provider, host and
  /// writes flag from the form, and puts them all in this chat.
  Future<void> _link(AppController app) async {
    final found = _found;
    if (found == null) return;
    final picked = found.where((r) => _picked.contains(r.repo)).toList();
    if (picked.isEmpty) {
      setState(() => _error = t('Tick at least one.'));
      return;
    }
    for (final r in picked) {
      await app.saveRepo(
        GitRepo(
          id: bytesToHex(randomBytes(8)),
          repo: r.repo,
          token: _token.text.trim(),
          provider: _provider,
          host: _host.text.trim(),
          branch: r.branch,
          allowWrites: _writes,
        ),
        useHere: true,
      );
    }
    _reset();
  }

  Widget _browseList(AppController app, ThemeData theme) {
    final found = _found;
    if (found == null) return const SizedBox.shrink();
    final known = app.repos.map((r) => r.repo.toLowerCase()).toSet();
    final needle = _filter.text.trim().toLowerCase();
    final rows = found
        .where((r) =>
            needle.isEmpty ||
            r.repo.toLowerCase().contains(needle) ||
            r.description.toLowerCase().contains(needle))
        .toList();

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _filter,
            decoration: InputDecoration(
              isDense: true,
              labelText: t('Filter'),
              prefixIcon: const Icon(Icons.search, size: 18),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(t('Nothing matches that.'),
                        style: TextStyle(fontSize: 12, color: theme.hintColor)),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final r in rows)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _picked.contains(r.repo),
                          // Connecting one already connected would make a
                          // duplicate, so it is shown as connected instead.
                          onChanged: known.contains(r.repo.toLowerCase())
                              ? null
                              : (on) => setState(() {
                                    if (on == true) {
                                      _picked.add(r.repo);
                                    } else {
                                      _picked.remove(r.repo);
                                    }
                                  }),
                          title: Text(r.repo,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13)),
                          subtitle: Text(
                            [
                              if (r.branch.isNotEmpty) r.branch,
                              r.private ? t('private') : t('public'),
                              if (known.contains(r.repo.toLowerCase()))
                                t('already connected'),
                              if (r.description.isNotEmpty) r.description,
                            ].join(' · '),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: theme.hintColor),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilledButton(
                onPressed: () => _link(app),
                child: Text(t('Link the ticked ones')),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() {
                  _found = null;
                  _picked.clear();
                }),
                child: Text(t('Close the list')),
              ),
            ],
          ),
        ],
      ),
    );
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
            const SizedBox(height: 6),
            OutlinedButton.icon(
              icon: _asking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.playlist_add_check, size: 18),
              label: Text(t('List what this token can reach')),
              onPressed: _asking ? null : () => _browse(app),
            ),
            _browseList(app, Theme.of(context)),
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
