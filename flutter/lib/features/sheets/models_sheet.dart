import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/theme/theme.dart';
import '../../services/chat_engine.dart';
import '../../state/app_controller.dart';
import '../brand_tile.dart';
import '../../models/model_maker.dart';
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

  static const List<String> chatFilters = [
    'all',
    'reasoning',
    'vision',
    'code',
    'favourites',
  ];

  static const List<String> popularMakers = [
    'anthropic',
    'openai',
    'google',
    'xai',
    'deepseek',
    'meta',
    'mistralai',
    'qwen',
    'moonshotai',
  ];

  static List<Map<String, dynamic>> modelsOf(Map<String, dynamic>? catalog) =>
      (catalog?['models'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

  static bool isChat(Map<String, dynamic> m) =>
      kindOf(m) == 'chat' && m['command'] == null;

  static int credits(Map<String, dynamic> m) =>
      (m['credits'] as num?)?.toInt() ?? 0;

  static int ceiling(Map<String, dynamic> m) =>
      (m['max'] as num?)?.toInt() ?? credits(m);

  static String slugOf(Map<String, dynamic> m, Map<String, dynamic> group) =>
      (m['authorSlug'] as String?) ?? (group['authorSlug'] as String? ?? '');

  static (double, double) turnRange(
          Map<String, dynamic> m, Map<String, dynamic>? catalog) =>
      ChatEngine.nominalTurnRange(m, catalog) ??
      (credits(m).toDouble(), ceiling(m).toDouble());

  static String creditsLabel(int credits, int max) {
    final span = max > credits;
    final n = span ? '${figure(credits)}–${figure(max)}' : figure(credits);
    return (!span && credits == 1)
        ? t('{n} credit', {'n': n})
        : t('{n} credits', {'n': n});
  }

  static String turnLabel(
      Map<String, dynamic> m, Map<String, dynamic>? catalog) {
    final span = ChatEngine.nominalTurnRange(m, catalog);
    if (span == null) return creditsLabel(credits(m), ceiling(m));
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

  static String pairLabel(Map<String, dynamic> a, Map<String, dynamic> b,
      Map<String, dynamic>? catalog) {
    final (aLow, aHigh) = turnRange(a, catalog);
    final (bLow, bHigh) = turnRange(b, catalog);
    final lo = creditFigure(aLow + bLow);
    final hi = creditFigure(aHigh + bHigh);
    return lo == hi
        ? t('Both replies together: ~{n} credits', {'n': lo})
        : t('Both replies together: ~{low}–{high} credits',
            {'low': lo, 'high': hi});
  }

  static String? rates(Map<String, dynamic> m, Map<String, dynamic>? catalog) {
    if (ChatEngine.nominalTurnCredits(m, catalog) == null) return null;
    final pin = m['inUsdPerMTok'];
    final pout = m['outUsdPerMTok'];
    final cached = (m['cacheReadUsdPerMTok'] as num?)?.toDouble() ?? 0;
    return cached > 0
        ? t('{in}/M in · {out}/M out · {cached}/M cached',
            {'in': '\$$pin', 'out': '\$$pout', 'cached': '\$$cached'})
        : t('{in}/M in · {out}/M out', {'in': '\$$pin', 'out': '\$$pout'});
  }

  static (String?, String?) compareDefaults(Map<String, dynamic>? catalog,
      {String? pinned, List<String> favourites = const []}) {
    final chats = [
      for (final m in modelsOf(catalog))
        if (isChat(m) && m['key'] is String) m,
    ];
    if (chats.isEmpty) return (null, null);
    String maker(Map<String, dynamic> m) => BrandMarks.canonical(
        ModelMaker.of(m, catalog)?.slug ?? '${m['author'] ?? ''}');
    int rank(Map<String, dynamic> m) {
      final starred = favourites.contains(m['key']) ? 0 : 1;
      final at = popularMakers.indexOf(maker(m));
      return starred * 100 + (at < 0 ? popularMakers.length : at);
    }

    final order = {for (var i = 0; i < chats.length; i++) chats[i]['key']: i};
    final ranked = [...chats]..sort((x, y) {
        final c = rank(x).compareTo(rank(y));
        return c != 0 ? c : order[x['key']]!.compareTo(order[y['key']]!);
      });
    final a = chats.firstWhere((m) => m['key'] == pinned,
        orElse: () => ranked.first);
    final others = ranked.where((m) => m['key'] != a['key']);
    final b = others.where((m) => maker(m) != maker(a)).firstOrNull ??
        others.firstOrNull;
    return (a['key'] as String, b?['key'] as String?);
  }
}

class ModelList extends StatefulWidget {
  const ModelList({
    super.key,
    required this.catalog,
    required this.loading,
    required this.onPick,
    this.filters = ModelList.everyFilter,
    this.chatOnly = false,
    this.initialTerm = '',
    this.selectedKeys = const {},
    this.unavailable = const {},
    this.scrollController,
  });

  static const List<String> everyFilter = [
    'all',
    'reasoning',
    'vision',
    'code',
    'image',
    'video',
    'speech',
    'favourites',
  ];

  final Map<String, dynamic>? catalog;
  final bool loading;
  final void Function(Map<String, dynamic> model, Map<String, dynamic> group)
      onPick;
  final List<String> filters;
  final bool chatOnly;
  final String initialTerm;
  final Set<String> selectedKeys;
  final Map<String, String> unavailable;
  final ScrollController? scrollController;

  @override
  State<ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<ModelList> {
  late String _term = widget.initialTerm;
  String _filter = 'all';
  String _sort = 'provider';
  late final _search = TextEditingController(text: widget.initialTerm);

  List<(String, String)> get _filters => [
        ('all', t('All')),
        ('reasoning', t('Reasoning')),
        ('vision', t('Vision')),
        ('code', t('Code')),
        ('image', t('Image')),
        ('video', t('Video')),
        ('speech', t('Speech')),
        ('favourites', t('Starred')),
      ].where((f) => widget.filters.contains(f.$1)).toList();

  List<(String, String)> get _sorts => [
        ('provider', t('Provider')),
        ('price-low', t('Price: low to high')),
        ('price-high', t('Price: high to low')),
        ('name', t('Name')),
      ];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<(Map<String, dynamic>, Map<String, dynamic>)> _entries(
      AppController app) {
    final models = ModelPicker.modelsOf(widget.catalog);
    final groups = (widget.catalog?['groups'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        const [];
    final byKey = {for (final m in models) m['key'] as String: m};
    final flat = _sort != 'provider';
    final out = <(Map<String, dynamic>, Map<String, dynamic>)>[];
    final seen = <String>{};
    for (final group in groups) {
      final keys = (group['keys'] as List).cast<String>();
      for (final key in keys) {
        final m = byKey[key];
        if (m == null) continue;
        if (widget.chatOnly && !ModelPicker.isChat(m)) continue;
        if (!ModelPicker.matchesTerm(m, _term) ||
            !ModelPicker.matches(m, _filter, app.favouriteModels)) {
          continue;
        }
        if (flat && !seen.add(key)) continue;
        out.add((m, group));
      }
    }
    if (!flat) return out;
    final groupOf = {for (final (m, g) in out) m['key'] as String: g};
    return [
      for (final m in ModelPicker.sorted(
          out.map((e) => e.$1), _sort, widget.catalog))
        (m, groupOf[m['key']]!),
    ];
  }

  void _submit(AppController app) {
    if (_term.trim().isEmpty) return;
    for (final (m, group) in _entries(app)) {
      if (widget.unavailable.containsKey(m['key'])) continue;
      widget.onPick(m, group);
      return;
    }
  }

  Widget _tile(
      AppController app, Map<String, dynamic> m, Map<String, dynamic> group) {
    final key = m['key'] as String;
    final starred = app.favouriteModels.contains(key);
    final desc = m['description'] as String?;
    final rates = ModelPicker.rates(m, widget.catalog);
    final blocked = widget.unavailable[key];
    return ListTile(
      key: ValueKey('model-$key'),
      dense: true,
      enabled: blocked == null,
      selected: widget.selectedKeys.contains(key),
      isThreeLine: true,
      leading: Opacity(
        opacity: blocked == null ? 1 : 0.4,
        child: BrandTile(slug: ModelPicker.slugOf(m, group)),
      ),
      title: Text(m['label'] as String),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (blocked != null)
            Text(blocked,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600)),
          if (desc != null && desc.isNotEmpty)
            Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis),
          Text(ModelPicker.turnLabel(m, widget.catalog),
              style: const TextStyle(
                  fontSize: 12, color: NymbotColors.lightning)),
          if (rates != null)
            Text(rates, style: const TextStyle(fontSize: 11)),
          if (m['edit'] == true)
            Text(
                m['needsImage'] == true
                    ? t('Edits a picture you send')
                    : t('Can also edit a picture you send'),
                style: const TextStyle(fontSize: 11)),
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
      onTap: () => widget.onPick(m, group),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final flat = _sort != 'provider';
    final rows = <Widget>[];
    Map<String, dynamic>? heading;
    for (final (m, group) in _entries(app)) {
      if (!flat && !identical(group, heading)) {
        heading = group;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
          child: Text(
            (group['author'] as String? ?? '').toUpperCase(),
            style: const TextStyle(fontSize: 11, letterSpacing: 1),
          ),
        ));
      }
      rows.add(_tile(app, m, group));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: t('Search names and descriptions'),
                  suffixIcon: _term.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: t('Clear search'),
                          onPressed: () => setState(() {
                            _search.clear();
                            _term = '';
                          }),
                        ),
                ),
                onChanged: (v) => setState(() => _term = v),
                onSubmitted: (_) => _submit(app),
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
                        color: flat ? theme.colorScheme.primary : null),
                    const SizedBox(width: 4),
                    Text(t('Sort'),
                        style: TextStyle(
                            fontSize: 13,
                            color: flat ? theme.colorScheme.primary : null)),
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
          child: widget.loading
              ? const Center(child: CircularProgressIndicator())
              : widget.catalog == null
                  ? Center(
                      child: Text(
                          t('The model catalog is unavailable right now.')))
                  : rows.isEmpty
                      ? Center(child: Text(t('Nothing matches that.')))
                      : ListView(
                          controller: widget.scrollController,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          children: rows,
                        ),
        ),
      ],
    );
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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

  String? _cheapestChatKey() {
    final groups =
        (_catalog?['groups'] as List?)?.cast<Map<String, dynamic>>() ??
            const [];
    final byKey = {
      for (final m in ModelPicker.modelsOf(_catalog)) m['key'] as String: m
    };
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

  Future<void> _pick(AppController app, Map<String, dynamic> m,
      Map<String, dynamic> group) async {
    final credits = ModelPicker.credits(m);
    final max = ModelPicker.ceiling(m);
    final key = m['key'] as String;
    final command = m['command'] as String?;
    final slug = ModelPicker.slugOf(m, group);
    final standing = command != null ? app.activeMediaModel : app.activeModel;
    final pinned = standing != null && standing['key'] == key;
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
        media!['proKey'] = _cheapestChatKey();
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
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final pinned = {
      for (final m in [app.activeModel, app.activeMediaModel])
        if (m?['key'] is String) m!['key'] as String,
    };

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
            Expanded(
              child: ModelList(
                catalog: _catalog,
                loading: _loading,
                initialTerm: widget.initialFilter,
                selectedKeys: pinned,
                scrollController: controller,
                onPick: (m, group) => _pick(app, m, group),
              ),
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
