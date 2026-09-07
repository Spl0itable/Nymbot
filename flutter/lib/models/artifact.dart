import 'dart:convert';

class ArtifactVersion {
  const ArtifactVersion({required this.at, required this.body, this.note = ''});

  final DateTime at;
  final String body;
  final String note;

  Map<String, dynamic> toJson() =>
      {'at': at.millisecondsSinceEpoch, 'body': body, 'note': note};

  static ArtifactVersion fromJson(Map<String, dynamic> j) => ArtifactVersion(
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
        body: j['body'] as String? ?? '',
        note: j['note'] as String? ?? '',
      );
}

class Artifact {
  Artifact({
    required this.id,
    required this.title,
    required this.lang,
    required this.body,
    this.messageId,
    List<ArtifactVersion>? versions,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : versions = versions ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  final String lang;
  String body;
  final String? messageId;
  List<ArtifactVersion> versions;
  final DateTime createdAt;
  DateTime updatedAt;

  int get lines => body.split('\n').length;

  static const _previewable = {'html', 'svg', 'xml', 'markdown', 'md'};

  bool get previewable => _previewable.contains(lang.toLowerCase());
  bool get readable => lang.toLowerCase() == 'markdown' || lang.toLowerCase() == 'md';

  String get extension {
    const map = {
      'js': 'js', 'jsx': 'jsx', 'ts': 'ts', 'tsx': 'tsx', 'dart': 'dart',
      'py': 'py', 'rb': 'rb', 'go': 'go', 'rust': 'rs', 'java': 'java',
      'c': 'c', 'cpp': 'cpp', 'sh': 'sh', 'bash': 'sh', 'sql': 'sql',
      'json': 'json', 'yaml': 'yml', 'html': 'html', 'css': 'css',
      'svg': 'svg', 'xml': 'xml', 'markdown': 'md', 'md': 'md',
      'csv': 'csv', 'diff': 'diff',
    };
    return map[lang.toLowerCase()] ?? 'txt';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'lang': lang,
        'body': body,
        'messageId': messageId,
        'versions': versions.map((v) => v.toJson()).toList(),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static Artifact fromJson(Map<String, dynamic> j) => Artifact(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        lang: j['lang'] as String? ?? '',
        body: j['body'] as String? ?? '',
        messageId: j['messageId'] as String?,
        versions: (j['versions'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ArtifactVersion.fromJson)
            .toList(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num?)?.toInt() ?? 0),
      );

  static String encodeList(List<Artifact> list) =>
      jsonEncode(list.map((a) => a.toJson()).toList());

  static List<Artifact> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Artifact.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

/// Pulls the whole files out of a reply, so a page or a script opens beside
/// the chat rather than scrolling away inside a bubble.
class ArtifactHarvest {
  const ArtifactHarvest._();

  static const _minLines = 12;
  static const _minChars = 320;
  static const _previewable = {'html', 'svg', 'xml', 'markdown', 'md'};

  static const _titles = {
    'html': 'Page', 'svg': 'Drawing', 'markdown': 'Document', 'md': 'Document',
    'json': 'Data', 'csv': 'Table', 'sql': 'Query', 'diff': 'Patch', 'sh': 'Script',
  };

  static bool worthLifting(String body, String lang) {
    if (body.trim().isEmpty) return false;
    final lines = body.split('\n').length;
    if (_previewable.contains(lang.toLowerCase())) return lines >= 4;
    return lines >= _minLines || body.length >= _minChars;
  }

  static String titleFor(String lang, String body) {
    final title = RegExp(r'<title>([^<]{1,48})</title>', caseSensitive: false)
        .firstMatch(body);
    if (title != null) return title.group(1)!.trim();
    final heading = RegExp(r'^#{1,3}\s+(.+)$', multiLine: true).firstMatch(body);
    if (heading != null) {
      final h = heading.group(1)!;
      return h.length > 48 ? h.substring(0, 48) : h;
    }
    // The word boundary matters: without it `<!doctype html>` reads as
    // `type html` and every page is called "html".
    final named = RegExp(
            r'\b(?:class|function|def|const|interface|struct|fn|type)\s+([A-Za-z_$][\w$]*)')
        .firstMatch(body);
    if (named != null) return named.group(1)!;
    final known = _titles[lang.toLowerCase()];
    if (known != null) return known;
    final first = body.split('\n').firstWhere((l) => l.trim().isNotEmpty,
        orElse: () => 'Snippet');
    final cleaned = first.replaceFirst(RegExp(r'^[^\w<]+'), '');
    if (cleaned.isEmpty) return 'Snippet';
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  static List<({String lang, String body})> fences(String markdown) {
    final out = <({String lang, String body})>[];
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    var i = 0;
    while (i < lines.length) {
      final open = RegExp(r'^\s*(?:```|~~~)([\w+#.-]*)\s*$').firstMatch(lines[i]);
      if (open == null) {
        i++;
        continue;
      }
      final lang = (open.group(1) ?? '').toLowerCase();
      final body = <String>[];
      i++;
      while (i < lines.length && !RegExp(r'^\s*(?:```|~~~)\s*$').hasMatch(lines[i])) {
        body.add(lines[i++]);
      }
      i++;
      out.add((lang: lang, body: body.join('\n')));
    }
    return out;
  }
}
