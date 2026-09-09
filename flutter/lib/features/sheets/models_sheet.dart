import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../brand_tile.dart';
import '../i18n/i18n.dart';

/// Resolves with a command (`?image flux`) when a generator was picked, so the
/// caller can write it into the composer; null for a chat model or a dismissal.
Future<String?> showModelsSheet(BuildContext context, {String filter = ''}) =>
    showModalBottomSheet<String>(
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
  String _filter = 'all';
  bool _loading = true;

  // Literal t() calls: the extractor reads the source, so a label passed
  // through a variable would ship untranslated.
  List<(String, String)> get _filters => [
        ('all', t('All')),
        ('cheap', t('Cheapest')),
        ('reasoning', t('Reasoning')),
        ('vision', t('Vision')),
        ('image', t('Image')),
        ('video', t('Video')),
        ('code', t('Code')),
        ('favourites', t('Starred')),
      ];

  /// The generators answer only to their own two filters: they are commands,
  /// not chat models, so offering them anywhere else would pin a model that
  /// only draws.
  bool _matches(Map<String, dynamic> m, List<String> favourites) {
    final kind = (m['kind'] as String?) ?? 'chat';
    if (_filter == 'image') return kind == 'image';
    if (_filter == 'video') return kind == 'video';
    if (kind != 'chat') return false;
    final text = '${m['key']} ${m['label']} ${m['description'] ?? ''}'.toLowerCase();
    switch (_filter) {
      case 'cheap':
        return ((m['credits'] as num?)?.toInt() ?? 0) <= 2;
      case 'reasoning':
        return RegExp(r'reason|think|o\d|r1|deep').hasMatch(text);
      case 'vision':
        return RegExp(r'vision|image|multimodal|omni|4o|gemini|claude|gpt-4')
            .hasMatch(text);
      case 'code':
        return RegExp(r'code|coder|dev|engineer|sonnet|opus|qwen|kimi')
            .hasMatch(text);
      case 'favourites':
        return favourites.contains(m['key']);
      default:
        return true;
    }
  }

  /// "3 credits", or "1–4 credits" where the reply's length moves it. A bare
  /// number said nothing about what it counted.
  String _price(int credits, int max) {
    final span = max > credits;
    final n = span ? '$credits–$max' : '$credits';
    return (!span && credits == 1)
        ? t('{n} credit', {'n': n})
        : t('{n} credits', {'n': n});
  }

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
              (term.isEmpty ||
                  (m['key'] as String).toLowerCase().contains(term) ||
                  (m['label'] as String).toLowerCase().contains(term)) &&
              _matches(m, app.favouriteModels))
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
        final key = m['key'] as String;
        final starred = app.favouriteModels.contains(key);
        final command = m['command'] as String?;
        rows.add(ListTile(
          dense: true,
          selected: app.proModel?['key'] == key,
          // Who makes it, on the left, so the list scans by maker.
          leading: BrandTile(
              slug: (m['authorSlug'] as String?) ??
                  (group['authorSlug'] as String? ?? '')),
          title: Text(m['label'] as String),
          subtitle: (m['description'] as String?)?.isNotEmpty == true
              ? Text(m['description'] as String,
                  maxLines: 2, overflow: TextOverflow.ellipsis)
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_price(credits, max)),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: Icon(starred ? Icons.star : Icons.star_border,
                    color: starred ? NymbotColors.lightning : null),
                tooltip: t('Star this model'),
                onPressed: () async {
                  await app.toggleFavouriteModel(key);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          onTap: () async {
            // A generator is a command, not a chat model.
            if (command != null) {
              if (context.mounted) Navigator.pop(context, command);
              return;
            }
            await app.setProModel({
              'key': key,
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
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (key, label) in _filters)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(label),
                        selected: _filter == key,
                        onSelected: (_) => setState(() => _filter = key),
                      ),
                    ),
                ],
              ),
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
