import 'dart:convert';

/// One chat. [rootId] is the `nymthread` marker every rumor in it carries: the
/// worker scopes a reply's context to the messages sharing it, which is what
/// keeps two conversations from seeing each other's turns.
class Conversation {
  Conversation({
    required this.id,
    required this.rootId,
    this.title = '',
    this.anon = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String rootId;
  String title;
  bool anon;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'rootId': rootId,
        'title': title,
        'anon': anon,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static Conversation fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        rootId: j['rootId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        anon: j['anon'] as bool? ?? false,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num?)?.toInt() ?? 0),
      );

  static String encodeList(List<Conversation> list) =>
      jsonEncode(list.map((c) => c.toJson()).toList());

  static List<Conversation> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

enum ChatRole { self, bot, note, error }

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.thinking,
    this.cost = 0,
    this.model,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String id;
  final ChatRole role;
  final String content;
  final String? thinking;
  final int cost;
  final String? model;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'content': content,
        'thinking': thinking,
        'cost': cost,
        'model': model,
        'at': at.millisecondsSinceEpoch,
      };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        role: ChatRole.values.firstWhere(
          (r) => r.name == j['role'],
          orElse: () => ChatRole.note,
        ),
        content: j['content'] as String? ?? '',
        thinking: j['thinking'] as String?,
        cost: (j['cost'] as num?)?.toInt() ?? 0,
        model: j['model'] as String?,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
      );

  static String encodeList(List<ChatMessage> list) =>
      jsonEncode(list.map((m) => m.toJson()).toList());

  static List<ChatMessage> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
