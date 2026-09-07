import 'dart:convert';

class GitRepo {
  GitRepo({
    required this.id,
    required this.repo,
    required this.token,
    this.provider = 'github',
    this.host = '',
    this.branch = '',
    this.paths = '',
    this.label = '',
    this.allowWrites = false,
    this.enabled = true,
  });

  final String id;
  String repo;
  String token;
  String provider;
  String host;
  String branch;
  String paths;
  String label;
  bool allowWrites;
  bool enabled;

  String get display => label.isNotEmpty ? label : repo;

  String get subtitle {
    final bits = <String>[provider];
    if (host.isNotEmpty) bits.add(host);
    if (branch.isNotEmpty) bits.add(branch);
    if (paths.isNotEmpty) bits.add(paths);
    return bits.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'repo': repo,
        'token': token,
        'provider': provider,
        'host': host,
        'branch': branch,
        'paths': paths,
        'label': label,
        'allowWrites': allowWrites,
        'enabled': enabled,
      };

  Map<String, dynamic> toPayload() => {
        'provider': provider,
        'host': host,
        'token': token,
        'repo': repo,
        'branch': branch,
        'allowWrites': allowWrites,
        'paths': paths,
        'label': display,
      };

  static GitRepo fromJson(Map<String, dynamic> j) => GitRepo(
        id: j['id'] as String,
        repo: j['repo'] as String? ?? '',
        token: j['token'] as String? ?? '',
        provider: j['provider'] as String? ?? 'github',
        host: j['host'] as String? ?? '',
        branch: j['branch'] as String? ?? '',
        paths: j['paths'] as String? ?? '',
        label: j['label'] as String? ?? '',
        allowWrites: j['allowWrites'] == true,
        enabled: j['enabled'] != false,
      );

  static String encodeList(List<GitRepo> list) =>
      jsonEncode(list.map((r) => r.toJson()).toList());

  static List<GitRepo> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => GitRepo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

class KnowledgeFile {
  const KnowledgeFile({
    required this.id,
    required this.name,
    this.mime = 'text/plain',
    this.body = '',
  });

  final String id;
  final String name;
  final String mime;
  final String body;

  int get size => body.length;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'mime': mime, 'body': body};

  static KnowledgeFile fromJson(Map<String, dynamic> j) => KnowledgeFile(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        mime: j['mime'] as String? ?? 'text/plain',
        body: j['body'] as String? ?? '',
      );
}

/// Standing context a run of chats shares: instructions, reference files and
/// repositories. Everything in it lives on this device and travels only inside
/// the first message of a chat that uses it.
class Workspace {
  Workspace({
    required this.id,
    this.name = '',
    this.instructions = '',
    List<KnowledgeFile>? files,
    List<String>? repoIds,
    this.personaId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : files = files ?? [],
        repoIds = repoIds ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  String instructions;
  List<KnowledgeFile> files;
  List<String> repoIds;
  String? personaId;
  final DateTime createdAt;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'instructions': instructions,
        'files': files.map((f) => f.toJson()).toList(),
        'repoIds': repoIds,
        'personaId': personaId,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static Workspace fromJson(Map<String, dynamic> j) => Workspace(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        instructions: j['instructions'] as String? ?? '',
        files: (j['files'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(KnowledgeFile.fromJson)
            .toList(),
        repoIds: (j['repoIds'] as List?)?.whereType<String>().toList(),
        personaId: j['personaId'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num?)?.toInt() ?? 0),
      );

  static String encodeList(List<Workspace> list) =>
      jsonEncode(list.map((w) => w.toJson()).toList());

  static List<Workspace> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Workspace.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

class Persona {
  const Persona({
    required this.id,
    required this.name,
    required this.instructions,
    this.icon = 'robot',
    this.builtin = false,
  });

  final String id;
  final String name;
  final String instructions;

  /// A name from the shared icon set rather than an emoji, so the web app and
  /// this one draw the same mark for the same persona.
  final String icon;
  final bool builtin;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'instructions': instructions,
        'icon': icon,
      };

  static Persona fromJson(Map<String, dynamic> j) => Persona(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        instructions: j['instructions'] as String? ?? '',
        icon: j['icon'] as String? ?? 'robot',
      );

  static String encodeList(List<Persona> list) =>
      jsonEncode(list.map((p) => p.toJson()).toList());

  static List<Persona> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Persona.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static const builtins = <Persona>[
    Persona(
      id: 'builtin-engineer',
      builtin: true,
      icon: 'tools',
      name: 'Staff engineer',
      instructions:
          'You are a meticulous staff software engineer. Prefer precise, working code over prose. '
          'Name the files and lines you mean. Call out edge cases, failure modes and the cheapest '
          'correct fix. Never invent APIs — say when you are unsure.',
    ),
    Persona(
      id: 'builtin-reviewer',
      builtin: true,
      icon: 'search',
      name: 'Code reviewer',
      instructions:
          'Review the code as a demanding reviewer would. Report only real defects and concrete '
          'simplifications, most severe first, each with the failing scenario that proves it. '
          'No praise, no summary of what the code does.',
    ),
    Persona(
      id: 'builtin-writer',
      builtin: true,
      icon: 'pen',
      name: 'Editor',
      instructions:
          'You are a ruthless editor. Cut every sentence that carries no information. Prefer plain '
          "words, active voice and concrete nouns. Preserve the author's meaning and voice exactly.",
    ),
    Persona(
      id: 'builtin-socratic',
      builtin: true,
      icon: 'graduation',
      name: 'Tutor',
      instructions:
          'Teach by building the idea up from what the reader already knows. Give one worked example '
          'before any abstraction, check understanding with a single pointed question, and never dump '
          'a wall of definitions.',
    ),
    Persona(
      id: 'builtin-analyst',
      builtin: true,
      icon: 'chart',
      name: 'Analyst',
      instructions:
          'Answer with structure: the claim, the evidence, the uncertainty. Quantify wherever a number '
          'exists. State explicitly which parts are estimates and what would change your mind.',
    ),
    Persona(
      id: 'builtin-terse',
      builtin: true,
      icon: 'terse',
      name: 'Terse',
      instructions:
          'Answer in as few words as the question allows. No preamble, no restating the question, '
          'no closing offer of further help.',
    ),
  ];
}

class SavedPrompt {
  const SavedPrompt({required this.id, required this.title, required this.body});

  final String id;
  final String title;
  final String body;

  List<String> get blanks {
    final out = <String>{};
    for (final m in RegExp(r'\{\{(\w+)\}\}').allMatches(body)) {
      out.add(m.group(1)!);
    }
    return out.toList();
  }

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'body': body};

  static SavedPrompt fromJson(Map<String, dynamic> j) => SavedPrompt(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
      );

  static String encodeList(List<SavedPrompt> list) =>
      jsonEncode(list.map((p) => p.toJson()).toList());

  static List<SavedPrompt> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SavedPrompt.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static const defaults = <SavedPrompt>[
    SavedPrompt(
      id: 'p-explain',
      title: 'Explain this code',
      body: 'Explain what this code does, then name the three things most likely to break it:\n\n'
          '```\n{{code}}\n```',
    ),
    SavedPrompt(
      id: 'p-review',
      title: 'Review a diff',
      body: 'Review this diff for correctness bugs and simplifications. Most severe first, each with '
          'a concrete failing case.\n\n```diff\n{{diff}}\n```',
    ),
    SavedPrompt(
      id: 'p-tests',
      title: 'Write tests',
      body: 'Write thorough tests for the following, covering the boundary and failure cases as well '
          'as the happy path:\n\n```\n{{code}}\n```',
    ),
    SavedPrompt(
      id: 'p-refactor',
      title: 'Refactor',
      body: 'Refactor this for clarity without changing behaviour. Show the diff and say what each '
          'change buys.\n\n```\n{{code}}\n```',
    ),
    SavedPrompt(
      id: 'p-commit',
      title: 'Commit message',
      body: 'Write a commit message for this diff: a subject under 60 characters in the imperative, '
          'then a body explaining why rather than what.\n\n```diff\n{{diff}}\n```',
    ),
    SavedPrompt(
      id: 'p-summarise',
      title: 'Summarise',
      body: 'Summarise the following in {{count}} bullet points, keeping every number and name '
          'intact:\n\n{{text}}',
    ),
    SavedPrompt(
      id: 'p-translate',
      title: 'Translate',
      body: 'Translate the following into {{language}}, preserving tone and formatting:\n\n{{text}}',
    ),
    SavedPrompt(
      id: 'p-brainstorm',
      title: 'Brainstorm',
      body: 'Give me {{count}} genuinely different approaches to {{goal}}. For each: the idea in one '
          'line, why it might win, and what would sink it.',
    ),
  ];
}

class ChatFolder {
  const ChatFolder({required this.id, required this.name});

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static ChatFolder fromJson(Map<String, dynamic> j) =>
      ChatFolder(id: j['id'] as String, name: j['name'] as String? ?? '');

  static String encodeList(List<ChatFolder> list) =>
      jsonEncode(list.map((f) => f.toJson()).toList());

  static List<ChatFolder> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => ChatFolder.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

enum AttachmentKind { image, text }

class Attachment {
  Attachment({
    required this.id,
    required this.kind,
    required this.name,
    this.mime = '',
    this.size = 0,
    this.lang = '',
    this.text,
    this.bytesBase64,
  });

  final String id;
  final AttachmentKind kind;
  final String name;
  final String mime;
  final int size;
  final String lang;
  final String? text;
  final String? bytesBase64;

  String get humanSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).round()} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get wireBlock {
    if (kind == AttachmentKind.text) {
      return '\n\n--- attached file: $name ---\n```$lang\n${text ?? ''}\n```';
    }
    return '\n\n--- attached image: $name (${(size / 1024).round()} KB) ---';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'mime': mime,
        'size': size,
        'lang': lang,
        if (text != null) 'text': text,
        if (bytesBase64 != null) 'bytesBase64': bytesBase64,
      };

  Map<String, dynamic> toPayload() => {
        'kind': kind.name,
        'name': name,
        'mime': mime,
        'size': size,
        if (kind == AttachmentKind.image && bytesBase64 != null)
          'dataUrl': 'data:$mime;base64,$bytesBase64',
      };

  static Attachment fromJson(Map<String, dynamic> j) => Attachment(
        id: j['id'] as String? ?? '',
        kind: j['kind'] == 'image' ? AttachmentKind.image : AttachmentKind.text,
        name: j['name'] as String? ?? '',
        mime: j['mime'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        lang: j['lang'] as String? ?? '',
        text: j['text'] as String?,
        bytesBase64: j['bytesBase64'] as String?,
      );
}

enum ChatTheme { system, dark, light, terminal, midnight }

enum ChatDensity { compact, comfortable, roomy }

enum SidebarGrouping { date, folder, flat }

class AppSettings {
  AppSettings({
    this.theme = ChatTheme.system,
    this.density = ChatDensity.comfortable,
    this.fontScale = 1,
    this.bubbles = true,
    this.avatars = true,
    this.timestamps = true,
    this.typewriter = true,
    this.sendOnEnter = false,
    this.soundOnReply = false,
    this.hapticOnReply = true,
    this.autoSpeak = false,
    this.speechRate = 1,
    this.showReasoningByDefault = false,
    this.monospaceReplies = false,
    this.reduceMotion = false,
    this.webSearch = false,
    this.showCostEstimate = true,
    this.anonAutoTop = true,
    this.anonAutoTopFloor = 10,
    this.anonAutoTopAmount = 25,
    this.anonAutoTopTier = 'both',
    this.autoDeleteDays = 0,
    this.autoContinue = 0,
    this.showProgress = true,
    this.grouping = SidebarGrouping.date,
    this.defaultPersonaId,
    this.defaultRepoIds = const [],
  });

  ChatTheme theme;
  ChatDensity density;
  double fontScale;
  bool bubbles;
  bool avatars;
  bool timestamps;
  bool typewriter;
  bool sendOnEnter;
  bool soundOnReply;
  bool hapticOnReply;
  bool autoSpeak;
  double speechRate;
  bool showReasoningByDefault;
  bool monospaceReplies;
  bool reduceMotion;
  bool webSearch;
  bool showCostEstimate;
  bool anonAutoTop;
  int anonAutoTopFloor;
  int anonAutoTopAmount;
  String anonAutoTopTier;

  /// Chats untouched for this many days are deleted when the app opens. Zero
  /// means never, which is the default: deleting things is the user's call.
  int autoDeleteDays;

  /// How much you are willing to spend letting a capped repo run carry on:
  /// 0 is never, -1 is whatever the balance holds.
  int autoContinue;
  bool showProgress;
  SidebarGrouping grouping;
  String? defaultPersonaId;
  List<String> defaultRepoIds;

  Map<String, dynamic> toJson() => {
        'theme': theme.name,
        'density': density.name,
        'fontScale': fontScale,
        'bubbles': bubbles,
        'avatars': avatars,
        'timestamps': timestamps,
        'typewriter': typewriter,
        'sendOnEnter': sendOnEnter,
        'soundOnReply': soundOnReply,
        'hapticOnReply': hapticOnReply,
        'autoSpeak': autoSpeak,
        'speechRate': speechRate,
        'showReasoningByDefault': showReasoningByDefault,
        'monospaceReplies': monospaceReplies,
        'reduceMotion': reduceMotion,
        'webSearch': webSearch,
        'showCostEstimate': showCostEstimate,
        'anonAutoTop': anonAutoTop,
        'anonAutoTopFloor': anonAutoTopFloor,
        'anonAutoTopAmount': anonAutoTopAmount,
        'anonAutoTopTier': anonAutoTopTier,
        'autoDeleteDays': autoDeleteDays,
        'autoContinue': autoContinue,
        'showProgress': showProgress,
        'grouping': grouping.name,
        'defaultPersonaId': defaultPersonaId,
        'defaultRepoIds': defaultRepoIds,
      };

  static T _enumOf<T>(List<T> values, Object? name, T fallback) {
    for (final v in values) {
      if ((v as Enum).name == name) return v;
    }
    return fallback;
  }

  static AppSettings fromJson(Map<String, dynamic> j) => AppSettings(
        theme: _enumOf(ChatTheme.values, j['theme'], ChatTheme.system),
        density: _enumOf(ChatDensity.values, j['density'], ChatDensity.comfortable),
        fontScale: (j['fontScale'] as num?)?.toDouble() ?? 1,
        bubbles: j['bubbles'] != false,
        avatars: j['avatars'] != false,
        timestamps: j['timestamps'] != false,
        typewriter: j['typewriter'] != false,
        sendOnEnter: j['sendOnEnter'] == true,
        soundOnReply: j['soundOnReply'] == true,
        hapticOnReply: j['hapticOnReply'] != false,
        autoSpeak: j['autoSpeak'] == true,
        speechRate: (j['speechRate'] as num?)?.toDouble() ?? 1,
        showReasoningByDefault: j['showReasoningByDefault'] == true,
        monospaceReplies: j['monospaceReplies'] == true,
        reduceMotion: j['reduceMotion'] == true,
        webSearch: j['webSearch'] == true,
        showCostEstimate: j['showCostEstimate'] != false,
        anonAutoTop: j['anonAutoTop'] != false,
        anonAutoTopFloor: (j['anonAutoTopFloor'] as num?)?.toInt() ?? 10,
        anonAutoTopAmount: (j['anonAutoTopAmount'] as num?)?.toInt() ?? 25,
        anonAutoTopTier: j['anonAutoTopTier'] as String? ?? 'both',
        autoDeleteDays: (j['autoDeleteDays'] as num?)?.toInt() ?? 0,
        autoContinue: (j['autoContinue'] as num?)?.toInt() ?? 0,
        showProgress: j['showProgress'] as bool? ?? true,
        grouping: _enumOf(SidebarGrouping.values, j['grouping'], SidebarGrouping.date),
        defaultPersonaId: j['defaultPersonaId'] as String?,
        defaultRepoIds:
            (j['defaultRepoIds'] as List?)?.map((e) => '$e').toList() ?? const [],
      );
}
