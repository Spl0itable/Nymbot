import 'dart:convert';

import 'workspace.dart';

/// One chat. [rootId] is the `nymthread` marker every rumor in it carries: the
/// worker scopes a reply's context to the messages sharing it, which is what
/// keeps two conversations from seeing each other's turns.
class Conversation {
  Conversation({
    required this.id,
    required this.rootId,
    this.title = '',
    this.anon = false,
    this.ephemeral = false,
    this.effort = 'normal',
    this.pinned = false,
    this.archived = false,
    this.folderId,
    List<String>? tags,
    List<String>? repoIds,
    this.personaId,
    this.workspaceId,
    this.botId,
    this.systemPrompt = '',
    this.proModel,
    this.seed,
    this.messageCount = 0,
    this.creditsSpent = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : tags = tags ?? [],
        repoIds = repoIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String rootId;
  String title;
  bool anon;

  /// A ghost chat: nothing it says is written to this device, and no archive
  /// copy is published for it. It exists for as long as the app is open.
  bool ephemeral;

  /// How hard each reply in this chat is asked to think: 'normal', 'careful'
  /// or 'deep'. Each step is another model call the reply takes and the
  /// balance pays for.
  String effort;

  bool pinned;
  bool archived;
  String? folderId;
  List<String> tags;
  List<String> repoIds;
  String? personaId;
  String? workspaceId;
  String? botId;
  String systemPrompt;
  Map<String, dynamic>? proModel;
  String? seed;
  int messageCount;
  int creditsSpent;
  DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'rootId': rootId,
        'title': title,
        'anon': anon,
        'ephemeral': ephemeral,
        'effort': effort,
        'pinned': pinned,
        'archived': archived,
        'folderId': folderId,
        'tags': tags,
        'repoIds': repoIds,
        'personaId': personaId,
        'workspaceId': workspaceId,
        'botId': botId,
        'systemPrompt': systemPrompt,
        'proModel': proModel,
        'seed': seed,
        'messageCount': messageCount,
        'creditsSpent': creditsSpent,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static Conversation fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        rootId: j['rootId'] as String? ?? '',
        title: j['title'] as String? ?? '',
        anon: j['anon'] as bool? ?? false,
        ephemeral: j['ephemeral'] as bool? ?? false,
        effort: j['effort'] as String? ?? 'normal',
        pinned: j['pinned'] as bool? ?? false,
        archived: j['archived'] as bool? ?? false,
        folderId: j['folderId'] as String?,
        tags: (j['tags'] as List?)?.map((e) => '$e').toList(),
        repoIds: (j['repoIds'] as List?)?.map((e) => '$e').toList(),
        personaId: j['personaId'] as String?,
        workspaceId: j['workspaceId'] as String?,
        botId: j['botId'] as String?,
        systemPrompt: j['systemPrompt'] as String? ?? '',
        proModel: j['proModel'] as Map<String, dynamic>?,
        seed: j['seed'] as String?,
        messageCount: (j['messageCount'] as num?)?.toInt() ?? 0,
        creditsSpent: (j['creditsSpent'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
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
    this.calls = 1,
    this.task,
    this.checkpoint,
    this.rating = 0,
    this.pinned = false,
    this.edited = false,
    this.retry,
    this.quote,
    List<Attachment>? attachments,
    List<String>? repos,
    List<Map<String, dynamic>>? sources,
    DateTime? at,
  })  : attachments = attachments ?? const [],
        repos = repos ?? const [],
        sources = sources ?? const [],
        at = at ?? DateTime.now();

  final String id;
  final ChatRole role;
  final String content;
  final String? thinking;
  final int cost;
  final String? model;

  /// What the worker said it did to earn the charge, kept so the cost
  /// breakdown reports it rather than re-deriving a guess after the fact.
  final int calls;
  final String? task;

  /// What this reply changed in a repository, and where the branch stood
  /// before it did, so the run can be put back.
  final Map<String, dynamic>? checkpoint;
  int rating;
  bool pinned;
  final bool edited;
  final String? retry;
  final String? quote;
  final List<Attachment> attachments;
  final List<String> repos;
  final List<Map<String, dynamic>> sources;
  final DateTime at;

  ChatMessage copyWith(
          {int? rating, bool? pinned, Map<String, dynamic>? checkpoint}) =>
      ChatMessage(
        id: id,
        role: role,
        content: content,
        thinking: thinking,
        cost: cost,
        model: model,
        calls: calls,
        task: task,
        checkpoint: checkpoint ?? this.checkpoint,
        rating: rating ?? this.rating,
        pinned: pinned ?? this.pinned,
        edited: edited,
        retry: retry,
        quote: quote,
        attachments: attachments,
        repos: repos,
        sources: sources,
        at: at,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'content': content,
        'thinking': thinking,
        'cost': cost,
        'model': model,
        'calls': calls,
        if (checkpoint != null) 'checkpoint': checkpoint,
        'task': task,
        'rating': rating,
        'pinned': pinned,
        'edited': edited,
        'retry': retry,
        'quote': quote,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'repos': repos,
        'sources': sources,
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
        calls: (j['calls'] as num?)?.toInt() ?? 1,
        checkpoint: j['checkpoint'] as Map<String, dynamic>?,
        task: j['task'] as String?,
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        pinned: j['pinned'] == true,
        edited: j['edited'] == true,
        retry: j['retry'] as String?,
        quote: j['quote'] as String?,
        attachments: (j['attachments'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(Attachment.fromJson)
            .toList(),
        repos: (j['repos'] as List?)?.map((e) => '$e').toList(),
        sources: (j['sources'] as List?)?.whereType<Map<String, dynamic>>().toList(),
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
