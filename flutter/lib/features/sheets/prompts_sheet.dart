import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/crypto/keys.dart';
import '../../models/workspace.dart';
import '../i18n/i18n.dart';

Future<String?> showPromptsSheet(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _PromptsSheet(),
    );

class _PromptsSheet extends StatefulWidget {
  const _PromptsSheet();

  @override
  State<_PromptsSheet> createState() => _PromptsSheetState();
}

class _PromptsSheetState extends State<_PromptsSheet> {
  final _search = TextEditingController();
  final _title = TextEditingController();
  final _body = TextEditingController();
  String? _editingId;
  String? _error;
  String _term = '';

  @override
  void dispose() {
    _search.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _reset() => setState(() {
        _editingId = null;
        _error = null;
        _title.clear();
        _body.clear();
      });

  Future<void> _use(SavedPrompt prompt) async {
    var body = prompt.body;
    for (final blank in prompt.blanks) {
      final value = await _askBlank(context, prompt.title, blank);
      if (value == null) return;
      body = body.replaceAll('{{$blank}}', value);
    }
    if (!mounted) return;
    Navigator.pop(context, body);
  }

  Future<String?> _askBlank(BuildContext context, String title, String blank) {
    final controller = TextEditingController();
    final long = blank == 'code' || blank == 'diff' || blank == 'text';
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: long ? 4 : 1,
          maxLines: long ? 10 : 1,
          decoration: InputDecoration(labelText: blank),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(t('Next')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final needle = _term.toLowerCase().trim();
    final list = app.prompts
        .where((p) =>
            needle.isEmpty ||
            '${p.title} ${p.body}'.toLowerCase().contains(needle))
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
            Text(t('Prompt library'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            TextField(
              controller: _search,
              decoration: InputDecoration(hintText: t('Search prompts')),
              onChanged: (v) => setState(() => _term = v),
            ),
            const SizedBox(height: 10),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(t('Nothing matches that.'),
                    style: TextStyle(color: Theme.of(context).hintColor)),
              ),
            for (final p in list)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  title: Text(p.title),
                  subtitle: Text(
                    p.body.replaceAll(RegExp(r'\s+'), ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => _use(p),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        tooltip: t('Edit'),
                        onPressed: () => setState(() {
                          _editingId = p.id;
                          _title.text = p.title;
                          _body.text = p.body;
                        }),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 17),
                        tooltip: t('Delete'),
                        onPressed: () => app.deletePrompt(p.id),
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 24),
            Text(
              _editingId == null ? t('New prompt') : t('Edit prompt'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _title,
              decoration:
                  InputDecoration(labelText: t('Title'), hintText: 'Review a diff'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: t('Body'),
                hintText: t('Use {{name}} for a blank to fill in when you insert it.'),
              ),
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
                if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) {
                  setState(
                      () => _error = t('A title and a body are both needed.'));
                  return;
                }
                await app.savePrompt(SavedPrompt(
                  id: _editingId ?? bytesToHex(randomBytes(8)),
                  title: _title.text.trim(),
                  body: _body.text.trim(),
                ));
                _reset();
              },
              child: Text(_editingId == null ? t('Save prompt') : t('Save changes')),
            ),
            if (_editingId != null)
              TextButton(onPressed: _reset, child: Text(t('Cancel'))),
          ],
        ),
      ),
    );
  }
}
