import 'dart:convert';

/// One standing fact about the person using the app, carried between chats.
///
/// Kept as separate entries rather than one rolling summary, because a summary
/// cannot be argued with: the list can be read line by line, the wrong one
/// corrected and the unwanted one thrown away. Nothing here is uploaded — the
/// entries that bear on a question travel inside that message, and the rest
/// never leave the device.
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

  /// A memory is one fact, not a transcript: short enough that a handful cost
  /// a paragraph of context.
  static const textCap = 400;
  static const maxKept = 200;

  final String id;
  String text;
  String topic;

  /// The workspace this belongs to, or null when it holds everywhere. A fact
  /// about one project should not follow you into another.
  String? scope;

  /// 'you' when it was written or asked for, 'chat' when it was noticed.
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
