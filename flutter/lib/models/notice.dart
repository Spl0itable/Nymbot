class Notice {
  const Notice({
    required this.id,
    this.kind = 'announcement',
    this.level = 'info',
    this.title = '',
    this.body = '',
    this.url,
    this.linkLabel,
    this.model,
    this.at = 0,
    this.endsAt = 0,
  });

  static const dismissedKept = 200;

  static final RegExp _web = RegExp(r'^https?://', caseSensitive: false);

  final int id;
  final String kind;
  final String level;
  final String title;
  final String body;
  final String? url;
  final String? linkLabel;
  final String? model;
  final int at;
  final int endsAt;

  static Notice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! num) return null;
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final link = text(raw['url']);
    final title = text(raw['title']) ?? '';
    final body = text(raw['body']) ?? '';
    if (title.isEmpty && body.isEmpty) return null;
    return Notice(
      id: id.toInt(),
      kind: raw['kind'] == 'model' ? 'model' : 'announcement',
      level: switch (raw['level']) {
        'success' => 'success',
        'warning' => 'warning',
        _ => 'info',
      },
      title: title,
      body: body,
      url: link != null && _web.hasMatch(link) ? link : null,
      linkLabel: text(raw['linkLabel']),
      model: text(raw['model']),
      at: (raw['at'] as num?)?.toInt() ?? 0,
      endsAt: (raw['endsAt'] as num?)?.toInt() ?? 0,
    );
  }

  static Notice? newest(List<Notice> notices, Iterable<int> dismissed) {
    final gone = dismissed.toSet();
    Notice? best;
    for (final n in notices) {
      if (gone.contains(n.id)) continue;
      if (best == null || n.at > best.at || (n.at == best.at && n.id > best.id)) {
        best = n;
      }
    }
    return best;
  }

  static List<int> dismiss(List<int> dismissed, int id) {
    final next = [...dismissed.where((d) => d != id), id];
    return next.length > dismissedKept
        ? next.sublist(next.length - dismissedKept)
        : next;
  }
}
