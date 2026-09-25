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
    List<String>? connectorIds,
    this.personaId,
    this.workspaceId,
    this.botId,
    this.systemPrompt = '',
    this.proModel,
    this.mediaModel,
    this.seed,
    this.messageCount = 0,
    this.creditsSpent = 0,
    this.capSats,
    this.askAboveSats,
    this.satsSpent,
    this.serverRuns = false,
    this.team,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : tags = tags ?? [],
        repoIds = repoIds ?? [],
        connectorIds = connectorIds ?? [],
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
  List<String> connectorIds;
  String? personaId;
  String? workspaceId;
  String? botId;
  String systemPrompt;
  Map<String, dynamic>? proModel;
  Map<String, dynamic>? mediaModel;
  String? seed;
  int messageCount;
  double creditsSpent;
  int? capSats;
  int? askAboveSats;
  double? satsSpent;
  bool serverRuns;
  Map<String, dynamic>? team;
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
        if (connectorIds.isNotEmpty) 'connectorIds': connectorIds,
        'personaId': personaId,
        'workspaceId': workspaceId,
        'botId': botId,
        'systemPrompt': systemPrompt,
        'proModel': proModel,
        'mediaModel': mediaModel,
        'seed': seed,
        'messageCount': messageCount,
        'creditsSpent': creditsSpent,
        'capSats': capSats,
        'askAboveSats': askAboveSats,
        if (satsSpent != null) 'satsSpent': satsSpent,
        if (serverRuns) 'serverRuns': true,
        'team': team,
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
        connectorIds: (j['connectorIds'] as List?)?.map((e) => '$e').toList(),
        personaId: j['personaId'] as String?,
        workspaceId: j['workspaceId'] as String?,
        botId: j['botId'] as String?,
        systemPrompt: j['systemPrompt'] as String? ?? '',
        proModel: j['proModel'] as Map<String, dynamic>?,
        mediaModel: j['mediaModel'] as Map<String, dynamic>?,
        seed: j['seed'] as String?,
        messageCount: (j['messageCount'] as num?)?.toInt() ?? 0,
        creditsSpent: (j['creditsSpent'] as num?)?.toDouble() ?? 0,
        capSats: _sats(j['capSats']),
        askAboveSats: _sats(j['askAboveSats']),
        satsSpent: (j['satsSpent'] as num?)?.toDouble(),
        serverRuns: j['serverRuns'] == true,
        team: j['team'] is Map ? (j['team'] as Map).cast<String, dynamic>() : null,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num?)?.toInt() ?? 0),
      );

  static int? _sats(Object? v) =>
      v is num && v > 0 ? v.floor() : null;

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
    this.modelKey,
    this.modelMaker,
    this.modelMakerName,
    this.pro,
    this.calls = 1,
    this.task,
    this.checkpoint,
    this.pendingTool,
    this.staged,
    this.rating = 0,
    this.pinned = false,
    this.edited = false,
    this.retry,
    this.quote,
    List<Attachment>? attachments,
    List<String>? repos,
    List<Map<String, dynamic>>? sources,
    List<String>? followUps,
    this.serverRunCredits = 0,
    List<Map<String, dynamic>>? serverRuns,
    this.team,
    this.tasks,
    this.updatedAt,
    DateTime? at,
  })  : attachments = attachments ?? const [],
        serverRuns = serverRuns ?? const [],
        repos = repos ?? const [],
        sources = sources ?? const [],
        followUps = followUps ?? const [],
        at = at ?? DateTime.now();

  final String id;
  final ChatRole role;
  final String content;
  final String? thinking;
  final double cost;
  final String? model;
  final String? modelKey;
  final String? modelMaker;
  final String? modelMakerName;

  /// Which tier answered.
  final bool? pro;

  /// What the worker said it did to earn the charge, kept so the cost
  /// breakdown reports it rather than re-deriving a guess after the fact.
  final int calls;
  final String? task;

  /// What this reply changed in a repository, and where the branch stood
  /// before it did, so the run can be put back.
  final Map<String, dynamic>? checkpoint;
  final Map<String, dynamic>? pendingTool;
  final Map<String, dynamic>? staged;
  int rating;
  bool pinned;
  final bool edited;
  final String? retry;
  final String? quote;
  final List<Attachment> attachments;
  final List<String> repos;
  final List<Map<String, dynamic>> sources;
  final List<String> followUps;
  final double serverRunCredits;
  final List<Map<String, dynamic>> serverRuns;
  final Map<String, dynamic>? team;
  final Map<String, dynamic>? tasks;
  final DateTime? updatedAt;
  final DateTime at;

  ChatMessage copyWith(
          {int? rating,
          bool? pinned,
          Map<String, dynamic>? checkpoint,
          Map<String, dynamic>? pendingTool,
          Map<String, dynamic>? staged,
          Map<String, dynamic>? tasks,
          DateTime? updatedAt}) =>
      ChatMessage(
        id: id,
        role: role,
        content: content,
        thinking: thinking,
        cost: cost,
        model: model,
        modelKey: modelKey,
        modelMaker: modelMaker,
        modelMakerName: modelMakerName,
        pro: pro,
        calls: calls,
        task: task,
        checkpoint: checkpoint ?? this.checkpoint,
        pendingTool: pendingTool ?? this.pendingTool,
        staged: staged ?? this.staged,
        rating: rating ?? this.rating,
        pinned: pinned ?? this.pinned,
        edited: edited,
        retry: retry,
        quote: quote,
        attachments: attachments,
        repos: repos,
        sources: sources,
        followUps: followUps,
        serverRunCredits: serverRunCredits,
        serverRuns: serverRuns,
        team: team,
        tasks: tasks ?? this.tasks,
        updatedAt: updatedAt ?? DateTime.now(),
        at: at,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'content': content,
        'thinking': thinking,
        'cost': cost,
        'model': model,
        if (modelKey != null) 'modelKey': modelKey,
        if (modelMaker != null) 'modelMaker': modelMaker,
        if (modelMakerName != null) 'modelMakerName': modelMakerName,
        if (pro != null) 'pro': pro,
        'calls': calls,
        if (checkpoint != null) 'checkpoint': checkpoint,
        if (pendingTool != null) 'pendingTool': pendingTool,
        if (staged != null) 'staged': staged,
        'task': task,
        'rating': rating,
        'pinned': pinned,
        'edited': edited,
        'retry': retry,
        'quote': quote,
        'attachments': attachments.map((a) => a.toJson()).toList(),
        'repos': repos,
        'sources': sources,
        if (followUps.isNotEmpty) 'followUps': followUps,
        if (serverRunCredits > 0) 'serverRunCredits': serverRunCredits,
        if (serverRuns.isNotEmpty) 'serverRuns': serverRuns,
        if (team != null) 'team': team,
        if (tasks != null) 'tasks': tasks,
        if (updatedAt != null) 'updatedAt': updatedAt!.millisecondsSinceEpoch,
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
        cost: (j['cost'] as num?)?.toDouble() ?? 0,
        model: j['model'] as String?,
        modelKey: j['modelKey'] as String?,
        modelMaker: j['modelMaker'] as String?,
        modelMakerName: j['modelMakerName'] as String?,
        pro: j['pro'] as bool?,
        calls: (j['calls'] as num?)?.toInt() ?? 1,
        checkpoint: j['checkpoint'] as Map<String, dynamic>?,
        pendingTool: j['pendingTool'] as Map<String, dynamic>?,
        staged: j['staged'] as Map<String, dynamic>?,
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
        followUps: followUpsOf(j['followUps']),
        serverRunCredits: (j['serverRunCredits'] as num?)?.toDouble() ?? 0,
        serverRuns: (j['serverRuns'] as List?)?.whereType<Map<String, dynamic>>().toList(),
        team: j['team'] is Map ? (j['team'] as Map).cast<String, dynamic>() : null,
        tasks: j['tasks'] is Map ? (j['tasks'] as Map).cast<String, dynamic>() : null,
        updatedAt: j['updatedAt'] is num
            ? DateTime.fromMillisecondsSinceEpoch((j['updatedAt'] as num).toInt())
            : null,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
      );

  static List<String> followUpsOf(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! String) continue;
      final text = item.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.length < 2 || text.length > 80) continue;
      if (RegExp(r'^[?!/@]').hasMatch(text)) continue;
      if (RegExp(r'[<>\x00-\x1f\x7f]|https?://', caseSensitive: false).hasMatch(text)) continue;
      if (!seen.add(text.toLowerCase())) continue;
      out.add(text);
      if (out.length == 3) break;
    }
    return out;
  }

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

int followUpsAt(List<ChatMessage> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final role = messages[i].role;
    if (role == ChatRole.self) return -1;
    if (role == ChatRole.bot) return messages[i].followUps.isEmpty ? -1 : i;
  }
  return -1;
}
