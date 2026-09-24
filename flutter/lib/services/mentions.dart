class MentionHead {
  const MentionHead(this.name, this.rest, this.fresh);

  final String name;
  final String rest;
  final bool fresh;
}

class MentionQuery {
  const MentionQuery(this.query, this.fresh);

  final String query;
  final bool fresh;
}

class MentionResult {
  const MentionResult({this.model, this.text = '', this.fresh = false, this.unknown});

  final Map<String, dynamic>? model;
  final String text;
  final bool fresh;
  final String? unknown;

  bool get resolved => model != null;
}

class Mentions {
  static final RegExp _head = RegExp(
      r'^(\s*)(!?)\s*@([A-Za-z0-9][A-Za-z0-9._:/+-]*)(?=\s|$)([\s\S]*)$');
  static final RegExp _typing = RegExp(r'^\s*(!?)@([A-Za-z0-9._:/+-]*)$');
  static final RegExp _trailing = RegExp(r'[.,:;!?]+$');
  static final RegExp _squash = RegExp(r'[^a-z0-9.]+');
  static final RegExp _digits = RegExp(r'\d+(?:\.\d+)?');
  static const int limit = 8;

  static MentionHead? parse(String text) {
    final m = _head.firstMatch(text);
    if (m == null) return null;
    final name = m.group(3)!.replaceAll(_trailing, '');
    if (name.isEmpty) return null;
    final rest = m.group(4)!.trim();
    final fresh = m.group(2) == '!' || rest.startsWith('!');
    final body = rest.replaceFirst(RegExp(r'^!\s*'), '');
    return MentionHead(name, body, fresh);
  }

  static List<Map<String, dynamic>> chatModels(Map<String, dynamic>? catalog) {
    final list = (catalog?['models'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .where((m) =>
            m['key'] is String &&
            (m['kind'] == null || m['kind'] == 'chat') &&
            m['command'] == null)
        .toList();
  }

  static String _flat(Object? s) => (s ?? '').toString().toLowerCase().replaceAll(_squash, '');

  static List<String> _words(Object? s) => (s ?? '')
      .toString()
      .toLowerCase()
      .split(_squash)
      .where((w) => w.isNotEmpty)
      .toList();

  static List<double> _version(String key) =>
      _digits.allMatches(key).map((m) => double.parse(m.group(0)!)).toList();

  static bool _newer(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ka = a['key'] as String;
    final kb = b['key'] as String;
    final va = _version(ka);
    final vb = _version(kb);
    for (var i = 0; i < (va.length > vb.length ? va.length : vb.length); i++) {
      final x = i < va.length ? va[i] : 0;
      final y = i < vb.length ? vb[i] : 0;
      if (x != y) return x > y;
    }
    return ka.length < kb.length;
  }

  static Map<String, dynamic>? resolve(String name, Map<String, dynamic>? catalog) {
    final n = name.trim().toLowerCase().replaceFirst('@', '').replaceAll(_trailing, '');
    if (n.isEmpty) return null;
    final models = chatModels(catalog);
    if (models.isEmpty) return null;
    final byKey = {for (final m in models) (m['key'] as String).toLowerCase(): m};
    if (byKey.containsKey(n)) return byKey[n];
    final aliases = (catalog?['aliases'] as Map?) ?? const {};
    final target = aliases[n]?.toString().toLowerCase();
    if (target != null && byKey.containsKey(target)) return byKey[target];
    final flat = _flat(n);
    if (flat.isEmpty) return null;
    for (final m in models) {
      if (_flat(m['label']) == flat || _flat(m['key']) == flat) return m;
    }
    Map<String, dynamic>? best;
    var bestRank = 9;
    for (final m in models) {
      final k = _flat(m['key']);
      final l = _flat(m['label']);
      final rank = k.startsWith(flat)
          ? 0
          : l.startsWith(flat)
              ? 1
              : (k.contains(flat) || l.contains(flat))
                  ? 2
                  : 9;
      if (rank == 9) continue;
      if (best == null || rank < bestRank || (rank == bestRank && _newer(m, best))) {
        best = m;
        bestRank = rank;
      }
    }
    return best;
  }

  static MentionQuery? typing(String text) {
    final m = _typing.firstMatch(text);
    return m == null ? null : MentionQuery(m.group(2)!, m.group(1) == '!');
  }

  static List<Map<String, dynamic>> suggest(String query, Map<String, dynamic>? catalog,
      {int max = limit}) {
    final q = _flat(query);
    final aliases = (catalog?['aliases'] as Map?) ?? const {};
    final aliased = <String>{
      for (final e in aliases.entries)
        if (q.isNotEmpty && e.key.toString().toLowerCase().startsWith(q))
          e.value.toString().toLowerCase(),
    };
    final scored = <(Map<String, dynamic>, int)>[];
    for (final m in chatModels(catalog)) {
      final k = _flat(m['key']);
      final l = _flat(m['label']);
      final a = _flat(m['author'] ?? m['authorSlug']);
      int rank;
      if (q.isEmpty) {
        rank = 5;
      } else if (k.startsWith(q)) {
        rank = 0;
      } else if (l.startsWith(q)) {
        rank = 1;
      } else if (aliased.contains((m['key'] as String).toLowerCase()) ||
          [..._words(m['key']), ..._words(m['label'])].any((w) => w.startsWith(q))) {
        rank = 2;
      } else if (k.contains(q) || l.contains(q)) {
        rank = 3;
      } else if (a.startsWith(q)) {
        rank = 4;
      } else {
        continue;
      }
      scored.add((m, rank));
    }
    scored.sort((x, y) {
      if (x.$2 != y.$2) return x.$2 - y.$2;
      if (_newer(x.$1, y.$1)) return -1;
      if (_newer(y.$1, x.$1)) return 1;
      return 0;
    });
    return scored.take(max).map((s) => s.$1).toList();
  }

  static String completion(Map<String, dynamic> model, {bool fresh = false}) =>
      '${fresh ? '!' : ''}@${model['key']} ';

  static MentionResult? apply(String text, Map<String, dynamic>? catalog) {
    final head = parse(text);
    if (head == null) return null;
    final model = resolve(head.name, catalog);
    if (model == null) return MentionResult(unknown: head.name, text: text);
    return MentionResult(
      model: model,
      fresh: head.fresh,
      text: head.rest.isEmpty ? '' : '${head.fresh ? '!' : ''}${head.rest}',
    );
  }

  static Map<String, dynamic> pinned(Map<String, dynamic> model) => {
        'key': model['key'],
        'label': model['label'],
        'credits': model['credits'],
        'max': model['max'],
        'slug': model['authorSlug'],
      };
}
