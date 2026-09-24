import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../services/chat_engine.dart';
import '../../state/app_controller.dart';
import '../brand_tile.dart';
import '../i18n/i18n.dart';
import 'sheet.dart';

Future<void> showModelsSheet(BuildContext context, {String filter = ''}) =>
    showNymSheet<void>(
      context,
      (_) => _ModelsSheet(initialFilter: filter),
    );

class ModelPicker {
  static final RegExp _reasoning = RegExp(r'reason|think|o\d|r1|deep');
  static final RegExp _vision =
      RegExp(r'vision|image|multimodal|omni|4o|gemini|claude|gpt-4');
  static final RegExp _code =
      RegExp(r'code|coder|dev|engineer|sonnet|opus|qwen|kimi');
  static final RegExp _space = RegExp(r'\s+');

  static String kindOf(Map<String, dynamic> m) =>
      (m['kind'] as String?) ?? 'chat';

  static bool matches(
      Map<String, dynamic> m, String filter, List<String> favourites) {
    final kind = kindOf(m);
    final text =
        '${m['key']} ${m['label']} ${m['description'] ?? ''}'.toLowerCase();
    switch (filter) {
      case 'image':
      case 'video':
      case 'speech':
        return kind == filter;
      case 'reasoning':
        return kind == 'chat' &&
            (m['reasoning'] == true || _reasoning.hasMatch(text));
      case 'vision':
        return kind == 'chat' && (m['vision'] == true || _vision.hasMatch(text));
      case 'code':
        return kind == 'chat' && _code.hasMatch(text);
      case 'favourites':
        return favourites.contains(m['key']);
      default:
        return true;
    }
  }

  static bool matchesTerm(Map<String, dynamic> m, String term) {
    final words =
        term.toLowerCase().split(_space).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return true;
    final haystack = '${m['key']} ${m['label']} ${m['description'] ?? ''} '
            '${m['author'] ?? ''} ${kindOf(m)}'
        .toLowerCase();
    return words.every(haystack.contains);
  }

  static double price(Map<String, dynamic> m, Map<String, dynamic>? catalog) =>
      ChatEngine.nominalTurnRange(m, catalog)?.$1 ??
      ((m['credits'] as num?)?.toDouble() ?? 0);

  static double _ceiling(Map<String, dynamic> m) =>
      ((m['max'] ?? m['credits']) as num?)?.toDouble() ?? 0;

  static String _name(Map<String, dynamic> m) =>
      '${m['label'] ?? m['key'] ?? ''}'.toLowerCase();

  static List<Map<String, dynamic>> sorted(Iterable<Map<String, dynamic>> models,
      String sort, Map<String, dynamic>? catalog) {
    final out = [...models];
    int byName(Map<String, dynamic> a, Map<String, dynamic> b) =>
        _name(a).compareTo(_name(b));
    switch (sort) {
      case 'name':
        out.sort(byName);
      case 'price-low':
      case 'price-high':
        final sign = sort == 'price-high' ? -1 : 1;
        out.sort((a, b) {
          var c = price(a, catalog).compareTo(price(b, catalog));
          if (c == 0) c = _ceiling(a).compareTo(_ceiling(b));
          return c != 0 ? sign * c : byName(a, b);
        });
    }
    return out;
  }
}

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
  String _sort = 'provider';
  bool _loading = true;
  late final _search = TextEditingController(text: widget.initialFilter);

  // Literal t() calls: the extractor reads the source, so a label passed
  // through a variable would ship untranslated.
  List<(String, String)> get _filters => [
        ('all', t('All')),
        ('reasoning', t('Reasoning')),
        ('vision', t('Vision')),
        ('code', t('Code')),
        ('image', t('Image')),
        ('video', t('Video')),
        ('speech', t('Speech')),
        ('favourites', t('Starred')),
      ];

  List<(String, String)> get _sorts => [
        ('provider', t('Provider')),
        ('price-low', t('Price: low to high')),
        ('price-high', t('Price: high to low')),
        ('name', t('Name')),
      ];

  /// "3 credits", or "1–4 credits" where the reply's length moves it. A bare
  /// number said nothing about what it counted.
  String _price(int credits, int max) {
    final span = max > credits;
    // Each side of a range is its own figure; the range is not one number to
    // format.
    final n = span ? '${figure(credits)}–${figure(max)}' : figure(credits);
    return (!span && credits == 1)
        ? t('{n} credit', {'n': n})
        : t('{n} credits', {'n': n});
  }

  double? _turnCredits(Map<String, dynamic> m) =>
      ChatEngine.nominalTurnCredits(m, _catalog);

  String _turnLabel(Map<String, dynamic> m, int credits, int max) {
    final span = ChatEngine.nominalTurnRange(m, _catalog);
    if (span == null) return _price(credits, max);
    final (low, high) = span;
    final lo = creditFigure(low);
    final hi = creditFigure(high);
    if (lo == hi) {
      return lo == '1'
          ? t('~{n} credit a reply', {'n': lo})
          : t('~{n} credits a reply', {'n': lo});
    }
    return t('~{low}–{high} credits a reply', {'low': lo, 'high': hi});
  }

  String? _rates(Map<String, dynamic> m) {
    if (_turnCredits(m) == null) return null;
    final pin = m['inUsdPerMTok'];
    final pout = m['outUsdPerMTok'];
    final cached = (m['cacheReadUsdPerMTok'] as num?)?.toDouble() ?? 0;
    return cached > 0
        ? t('{in}/M in · {out}/M out · {cached}/M cached',
            {'in': '\$$pin', 'out': '\$$pout', 'cached': '\$$cached'})
        : t('{in}/M in · {out}/M out', {'in': '\$$pin', 'out': '\$$pout'});
  }

  @override
  void initState() {
    super.initState();
    _term = widget.initialFilter;
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final catalog = await AppScope.read(context).api.models();
    if (mounted) AppScope.read(context).notePricing(catalog);
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _loading = false;
    });
  }

  String? _cheapestChatKey(
      List<Map<String, dynamic>> groups, Map<String, Map<String, dynamic>> byKey) {
    String? best;
    var cheapest = 1 << 30;
    var ceiling = 1 << 30;
    for (final group in groups) {
      for (final key in (group['keys'] as List).cast<String>()) {
        final m = byKey[key];
        if (m == null) continue;
        final kind = m['kind'] as String?;
        if ((kind != null && kind != 'chat') || m['command'] != null) continue;
        final credits = (m['credits'] as num?)?.toInt() ?? 0;
        final max = (m['max'] as num?)?.toInt() ?? credits;
        if (credits > cheapest || (credits == cheapest && max >= ceiling)) continue;
        cheapest = credits;
        ceiling = max;
        best = m['key'] as String?;
      }
    }
    return best;
  }

  Widget _tile(
    AppController app,
    Map<String, dynamic> m,
    Map<String, dynamic> group,
    List<Map<String, dynamic>> groups,
    Map<String, Map<String, dynamic>> byKey,
  ) {
    final credits = (m['credits'] as num?)?.toInt() ?? 0;
    final max = (m['max'] as num?)?.toInt() ?? credits;
    final key = m['key'] as String;
    final starred = app.favouriteModels.contains(key);
    final command = m['command'] as String?;
    final slug = (m['authorSlug'] as String?) ??
        (group['authorSlug'] as String? ?? '');
    final standing = command != null ? app.activeMediaModel : app.activeModel;
    final pinned = standing != null && standing['key'] == key;
    final desc = m['description'] as String?;
    final rates = _rates(m);
    return ListTile(
      dense: true,
      selected: pinned,
      isThreeLine: true,
      // Who makes it, on the left, so the list scans by maker.
      leading: BrandTile(slug: slug),
      title: Text(m['label'] as String),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (desc != null && desc.isNotEmpty)
            Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis),
          Text(_turnLabel(m, credits, max),
              style: const TextStyle(
                  fontSize: 12, color: NymbotColors.lightning)),
          if (rates != null)
            Text(rates, style: const TextStyle(fontSize: 11)),
        ],
      ),
      trailing: IconButton(
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
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        if (command != null) {
          final media = pinned
              ? null
              : {
                  'key': key,
                  'label': m['label'],
                  'kind': m['kind'] ?? 'image',
                  'credits': credits,
                  'max': max,
                  'command': AppController.generatorCommand(command),
                  'slug': slug,
                };
          if (AppController.mediaNeedsPro(media)) {
            media!['proKey'] = _cheapestChatKey(groups, byKey);
          }
          await app.setMediaModel(media);
          messenger.showSnackBar(SnackBar(
            content: Text(pinned
                ? t('Back to answering in words.')
                : switch (m['kind']) {
                    'video' => t('{name} pinned. Every message now makes a video.',
                        {'name': m['label']}),
                    'speech' => t('{name} pinned. Every message now comes back as a voice clip.',
                        {'name': m['label']}),
                    _ => t('{name} pinned. Every message now makes a picture.',
                        {'name': m['label']}),
                  }),
          ));
          if (mounted) Navigator.pop(context);
          return;
        }
        await app.setProModel({
          'key': key,
          'label': m['label'],
          'credits': credits,
          'slug': slug,
        });
        if (mounted) Navigator.pop(context);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final models = (_catalog?['models'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final groups = (_catalog?['groups'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final byKey = {for (final m in models) m['key'] as String: m};
    final flat = _sort != 'provider';

    final rows = <Widget>[];
    final listed = <Map<String, dynamic>>[];
    final groupOf = <String, Map<String, dynamic>>{};
    for (final group in groups) {
      final keys = (group['keys'] as List).cast<String>();
      final matched = keys
          .map((k) => byKey[k])
          .whereType<Map<String, dynamic>>()
          .where((m) =>
              ModelPicker.matchesTerm(m, _term) &&
              ModelPicker.matches(m, _filter, app.favouriteModels))
          .toList();
      if (matched.isEmpty) continue;
      if (flat) {
        for (final m in matched) {
          if (groupOf.containsKey(m['key'])) continue;
          groupOf[m['key'] as String] = group;
          listed.add(m);
        }
        continue;
      }
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
        child: Text(
          (group['author'] as String? ?? '').toUpperCase(),
          style: const TextStyle(fontSize: 11, letterSpacing: 1),
        ),
      ));
      for (final m in matched) {
        rows.add(_tile(app, m, group, groups, byKey));
      }
    }
    for (final m in ModelPicker.sorted(listed, _sort, _catalog)) {
      rows.add(_tile(app, m, groupOf[m['key']]!, groups, byKey));
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
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                        hintText: t('Search names and descriptions')),
                    onChanged: (v) => setState(() => _term = v),
                  ),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: t('Sort'),
                  initialValue: _sort,
                  onSelected: (v) => setState(() => _sort = v),
                  itemBuilder: (_) => [
                    for (final (key, label) in _sorts)
                      CheckedPopupMenuItem(
                        value: key,
                        checked: _sort == key,
                        child: Text(label),
                      ),
                  ],
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sort,
                            size: 18,
                            color: flat
                                ? Theme.of(context).colorScheme.primary
                                : null),
                        const SizedBox(width: 4),
                        Text(t('Sort'),
                            style: TextStyle(
                                fontSize: 13,
                                color: flat
                                    ? Theme.of(context).colorScheme.primary
                                    : null)),
                      ],
                    ),
                  ),
                ),
              ],
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
            Text(
              t('An estimate for one reply at these rates: the low end is a '
                  'short answer, the high end a long one. Whatever the model '
                  'has to read pushes it up — web results, repository files, '
                  'attachments, and a long chat behind you — and a task that '
                  'takes several passes costs more again. You pay for the '
                  'tokens actually used, never a flat price per message.'),
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                await app.dropProMedia();
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
