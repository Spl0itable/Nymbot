import 'conversation.dart';

class ModelMaker {
  const ModelMaker({this.key, required this.slug, required this.name});

  final String? key;
  final String slug;
  final String name;

  static List<Map<String, dynamic>> _list(Object? raw) =>
      raw is List ? raw.whereType<Map<String, dynamic>>().toList() : const [];

  static String? _text(Object? raw) => raw is String && raw.isNotEmpty ? raw : null;

  static ModelMaker? of(Map<String, dynamic>? pick, Map<String, dynamic>? catalog) {
    if (pick == null) return null;
    final key = _text(pick['key']);
    Map<String, dynamic> full = const {};
    Map<String, dynamic> group = const {};
    if (key != null) {
      for (final c in _list(catalog?['models'])) {
        if (c['key'] == key) {
          full = c;
          break;
        }
      }
      for (final g in _list(catalog?['groups'])) {
        final keys = g['keys'];
        if (keys is List && keys.contains(key)) {
          group = g;
          break;
        }
      }
    }
    final slug = _text(full['authorSlug']) ??
        _text(pick['authorSlug']) ??
        _text(pick['slug']) ??
        _text(group['authorSlug']);
    if (slug == null) return null;
    final name = _text(full['author']) ?? _text(pick['author']) ?? _text(group['author']) ?? slug;
    return ModelMaker(key: key, slug: slug, name: name);
  }

  static ModelMaker? byLabel(String? label, Map<String, dynamic>? catalog) {
    if (label == null || label.isEmpty) return null;
    for (final c in _list(catalog?['models'])) {
      if (c['label'] == label) return of(c, catalog);
    }
    return null;
  }

  static ModelMaker? ofMessage(ChatMessage m, Map<String, dynamic>? catalog) {
    if (m.role != ChatRole.bot || m.model == null || !(m.pro ?? true)) return null;
    final slug = m.modelMaker;
    if (slug != null && slug.isNotEmpty) {
      final known = m.modelKey == null ? null : of({'key': m.modelKey}, catalog);
      final name = known != null && known.slug == slug ? known.name : null;
      return ModelMaker(
        key: m.modelKey,
        slug: slug,
        name: name ?? m.modelMakerName ?? slug,
      );
    }
    if (m.modelKey != null) {
      final known = of({'key': m.modelKey}, catalog);
      if (known != null) return known;
    }
    return byLabel(m.model, catalog);
  }
}
