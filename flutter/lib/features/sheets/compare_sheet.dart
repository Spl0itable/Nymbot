import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/compare.dart';
import '../i18n/i18n.dart';
import '../markdown_body.dart';

Future<void> showCompareSheet(BuildContext context, {String prefill = ''}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CompareSheet(prefill: prefill),
    );

class _CompareSheet extends StatefulWidget {
  const _CompareSheet({this.prefill = ''});

  final String prefill;

  @override
  State<_CompareSheet> createState() => _CompareSheetState();
}

class _CompareSheetState extends State<_CompareSheet> {
  final _prompt = TextEditingController();
  Map<String, dynamic>? _catalog;
  bool _loading = true;
  String? _a;
  String? _b;
  String _status = '';
  bool _busy = false;
  List<CompareRun> _runs = const [];

  @override
  void initState() {
    super.initState();
    _prompt.text = widget.prefill;
    _load();
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final catalog = await app.api.models();
    if (!mounted) return;
    final rows =
        (catalog?['models'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final current = app.activeModel?['key'] as String?;
    setState(() {
      _catalog = catalog;
      _loading = false;
      _a = current ?? (rows.isNotEmpty ? rows.first['key'] as String : null);
      _b = rows
          .map((m) => m['key'] as String)
          .where((k) => k != _a)
          .cast<String?>()
          .firstWhere((k) => true, orElse: () => null);
    });
  }

  List<Map<String, dynamic>> get _models =>
      (_catalog?['models'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

  Map<String, dynamic>? _byKey(String? key) {
    for (final m in _models) {
      if (m['key'] == key) return m;
    }
    return null;
  }

  Future<void> _run() async {
    final app = AppScope.read(context);
    final a = _byKey(_a);
    final b = _byKey(_b);
    if (a == null || b == null || a['key'] == b['key']) {
      setState(() => _status = t('Pick two different models.'));
      return;
    }
    final text = _prompt.text.trim();
    if (text.isEmpty) {
      setState(() => _status = t('Type a prompt for both of them first.'));
      return;
    }

    final price = ((a['credits'] as num?)?.toInt() ?? 1) +
        ((b['credits'] as num?)?.toInt() ?? 1);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Ask both?')),
        content: Text(t(
            '{a} and {b} each answer once, so this costs two replies — about {n} credits.',
            {'a': a['label'], 'b': b['label'], 'n': price})),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t('Cancel'))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t('Ask both'))),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() {
      _busy = true;
      _status = t('Waiting on both…');
      _runs = const [];
    });
    final out = await app.compare(text, [a, b]);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _runs = out;
      _status = out.every((r) => r.ok)
          ? t('Both answered. Keep the one you want to carry on from.')
          : t('One of them did not answer.');
    });
  }

  Future<void> _keep(CompareRun run) async {
    final app = AppScope.read(context);
    final navigator = Navigator.of(context);
    await app.keepCompare(_prompt.text.trim(), run);
    if (!mounted) return;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
            Text(t('Ask two models at once'),
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              t('The same prompt goes to two models on separate threads, so neither '
                  'sees the other\'s answer. Keep the one you prefer and the chat '
                  'carries on from it. Two replies means two charges.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(t('Loading the catalog…'),
                    style: const TextStyle(fontSize: 12)),
              )
            else if (_models.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(t('The model catalog is unavailable right now.'),
                    style: const TextStyle(fontSize: 12)),
              )
            else ...[
              _picker(t('First model'), _a, (v) => setState(() => _a = v)),
              const SizedBox(height: 10),
              _picker(t('Second model'), _b, (v) => setState(() => _b = v)),
              const SizedBox(height: 12),
              TextField(
                controller: _prompt,
                maxLines: 4,
                minLines: 2,
                decoration: InputDecoration(
                  labelText: t('Prompt'),
                  hintText: t('What should both of them answer?'),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _run,
                child: Text(_busy ? t('Waiting on both…') : t('Ask both')),
              ),
            ],
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_status,
                  style: TextStyle(fontSize: 12, color: theme.hintColor)),
            ],
            for (final run in _runs) ...[
              const SizedBox(height: 10),
              _Result(run: run, onKeep: () => _keep(run)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _picker(String label, String? value, ValueChanged<String?> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final m in _models)
          DropdownMenuItem(
            value: m['key'] as String,
            child: Text(
              '${m['label']} · ${(m['credits'] as num?)?.toInt() ?? 1}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.run, required this.onKeep});

  final CompareRun run;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(run.label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                if (run.ok)
                  Text(t('{n} credits', {'n': run.cost}),
                      style:
                          TextStyle(fontSize: 11, color: theme.hintColor)),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: run.ok
                  ? MarkdownBody(run.reply)
                  : Text(run.error ?? '',
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.error)),
            ),
          ),
          if (run.ok)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: FilledButton(
                onPressed: onKeep,
                child: Text(t('Keep this one')),
              ),
            ),
        ],
      ),
    );
  }
}
