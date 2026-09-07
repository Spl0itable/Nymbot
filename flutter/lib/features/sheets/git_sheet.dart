import 'package:flutter/material.dart';

import '../../app.dart';
import '../i18n/i18n.dart';

Future<void> showGitSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _GitSheet(),
    );

class _GitSheet extends StatefulWidget {
  const _GitSheet();

  @override
  State<_GitSheet> createState() => _GitSheetState();
}

class _GitSheetState extends State<_GitSheet> {
  late final Map<String, dynamic> _cfg;
  late final TextEditingController _host;
  late final TextEditingController _token;
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  String _provider = 'github';
  bool _writes = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cfg = Map<String, dynamic>.from(
        AppScope.read(context).git ?? const <String, dynamic>{});
    _provider = _cfg['provider'] as String? ?? 'github';
    _writes = _cfg['allowWrites'] == true;
    _host = TextEditingController(text: _cfg['host'] as String? ?? '');
    _token = TextEditingController(text: _cfg['token'] as String? ?? '');
    _repo = TextEditingController(text: _cfg['repo'] as String? ?? '');
    _branch = TextEditingController(text: _cfg['branch'] as String? ?? '');
  }

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    _repo.dispose();
    _branch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
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
            Text(t('Connect a repository'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('Pro replies can read your code and, with writes on, commit, branch '
              'and open pull requests. Your access token is stored only on this '
              'device and sent to the Nymbot worker per request — never stored '
              'server-side or published to relays.'),
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              // `value` over `initialValue`: the latter does not exist on the
              // build toolchain's Flutter, and `value` works on both.
              // ignore: deprecated_member_use
              value: _provider,
              decoration: InputDecoration(labelText: t('Provider')),
              items: [
                DropdownMenuItem(value: 'github', child: Text('GitHub')),
                DropdownMenuItem(value: 'gitlab', child: Text('GitLab')),
                DropdownMenuItem(value: 'gitea', child: Text(t('Gitea / Forgejo'))),
              ],
              onChanged: (v) => setState(() => _provider = v ?? 'github'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _host,
              decoration: InputDecoration(labelText: t('Host'), hintText: 'github.com'),
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
              decoration: InputDecoration(labelText: t('Repository'), hintText: 'owner/repo'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _branch,
              decoration: InputDecoration(labelText: t('Branch'), hintText: 'main'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _writes,
              title: Text(t('Allow commits, branches and pull requests'),
                  style: TextStyle(fontSize: 13)),
              onChanged: (v) => setState(() => _writes = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                if (_token.text.trim().isEmpty || _repo.text.trim().isEmpty) {
                  setState(() => _error = t('A token and a repository are both needed.'));
                  return;
                }
                await app.setGit({
                  'provider': _provider,
                  'host': _host.text.trim(),
                  'token': _token.text.trim(),
                  'repo': _repo.text.trim(),
                  'branch': _branch.text.trim(),
                  'allowWrites': _writes,
                });
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(t('Connect')),
            ),
            TextButton(
              onPressed: () async {
                await app.setGit(null);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(t('Disconnect')),
            ),
          ],
        ),
      ),
    );
  }
}
