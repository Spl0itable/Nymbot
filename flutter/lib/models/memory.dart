import 'dart:convert';

/// One standing fact about the user, kept on device; only relevant entries travel with a message.
class Memory {
  Memory({
    required this.id,
    required this.text,
    this.topic = '',
    this.scope,
    this.source = 'you',
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  static const textCap = 400;
  static const maxKept = 200;

  final String id;
  String text;
  String topic;

  /// Workspace this belongs to, or null for everywhere.
  String? scope;

  /// 'you' when written or asked for, 'chat' when noticed.
  String source;

  DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'topic': topic,
        'scope': scope,
        'source': source,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static Memory fromJson(Map<String, dynamic> j) => Memory(
        id: j['id'] as String? ?? '',
        text: j['text'] as String? ?? '',
        topic: j['topic'] as String? ?? '',
        scope: j['scope'] as String?,
        source: j['source'] as String? ?? 'you',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch),
      );

  static List<Memory> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(Memory.fromJson)
          .where((m) => m.text.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<Memory> list) =>
      jsonEncode(list.map((m) => m.toJson()).toList());
}
