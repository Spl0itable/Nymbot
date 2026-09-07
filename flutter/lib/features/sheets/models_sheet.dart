import 'package:flutter/material.dart';

import '../../app.dart';
import '../i18n/i18n.dart';

Future<void> showModelsSheet(BuildContext context, {String filter = ''}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ModelsSheet(initialFilter: filter),
    );

/// The picker is generated from the worker's live catalog, so what it offers is
/// exactly what the worker will accept and charge for.
class _ModelsSheet extends StatefulWidget {
  const _ModelsSheet({required this.initialFilter});

  final String initialFilter;

  @override
  State<_ModelsSheet> createState() => _ModelsSheetState();
}

class _ModelsSheetState extends State<_ModelsSheet> {
  Map<String, dynamic>? _catalog;
  String _term = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _term = widget.initialFilter;
    _load();
  }

  Future<void> _load() async {
    final catalog = await AppScope.read(context).api.models();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final models = (_catalog?['models'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final groups = (_catalog?['groups'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final byKey = {for (final m in models) m['key'] as String: m};
    final term = _term.toLowerCase().trim();

    final rows = <Widget>[];
    for (final group in groups) {
      final keys = (group['keys'] as List).cast<String>();
      final matched = keys
          .map((k) => byKey[k])
          .whereType<Map<String, dynamic>>()
          .where((m) =>
              term.isEmpty ||
              (m['key'] as String).toLowerCase().contains(term) ||
              (m['label'] as String).toLowerCase().contains(term))
          .toList();
      if (matched.isEmpty) continue;
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
        child: Text(
          (group['author'] as String? ?? '').toUpperCase(),
          style: const TextStyle(fontSize: 11, letterSpacing: 1),
        ),
      ));
      for (final m in matched) {
        final credits = (m['credits'] as num?)?.toInt() ?? 0;
        final max = (m['max'] as num?)?.toInt() ?? credits;
        rows.add(ListTile(
          dense: true,
          selected: app.proModel?['key'] == m['key'],
          title: Text(m['label'] as String),
          subtitle: (m['description'] as String?)?.isNotEmpty == true
              ? Text(m['description'] as String,
                  maxLines: 2, overflow: TextOverflow.ellipsis)
              : null,
          trailing: Text(max > credits ? '$credits–$max' : '$credits'),
          onTap: () async {
            await app.setProModel({
              'key': m['key'],
              'label': m['label'],
              'credits': credits,
            });
            if (context.mounted) Navigator.pop(context);
          },
        ));
      }
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => Padding(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('Nymbot Pro model'),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            TextField(
              decoration: InputDecoration(hintText: t('Search models')),
              onChanged: (v) => setState(() => _term = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _catalog == null
                      ? Center(
                          child: Text(t('The model catalog is unavailable right now.')))
                      : rows.isEmpty
                          ? Center(child: Text(t('Nothing matches that.')))
                          : ListView(controller: controller, children: rows),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                await app.setProModel(null);
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(t('Auto-routed (standard)')),
            ),
          ],
        ),
      ),
    );
  }
}
