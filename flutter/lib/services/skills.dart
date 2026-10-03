import 'dart:convert';

import '../features/i18n/i18n.dart';

class Skill {
  const Skill({
    required this.id,
    required this.name,
    this.description = '',
    required this.body,
    this.order = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final String description;
  final String body;
  final int order;
  final int updatedAt;

  Skill copyWith({String? id, String? name, String? description, String? body, int? order, int? updatedAt}) => Skill(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        body: body ?? this.body,
        order: order ?? this.order,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'body': body,
        'order': order,
        'updatedAt': updatedAt,
      };

  static Skill? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return Skill(
      id: id,
      name: '${raw['name'] ?? ''}',
      description: '${raw['description'] ?? ''}',
      body: '${raw['body'] ?? ''}',
      order: raw['order'] is int && (raw['order'] as int) >= 0 ? raw['order'] as int : 0,
      updatedAt: raw['updatedAt'] is num ? (raw['updatedAt'] as num).toInt() : 0,
    );
  }

  static String encodeList(List<Skill> list) => jsonEncode([for (final s in list) s.toJson()]);

  static List<Skill> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [
        for (final e in list)
          if (Skill.fromJson(e) != null) Skill.fromJson(e)!
      ];
    } catch (_) {
      return [];
    }
  }
}

class Skills {
  static const nameMax = 60;
  static const descriptionMax = 160;
  static const bodyMax = 8000;
  static const slugMax = 40;
  static const maxSkills = 100;
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  static const builtin = <Skill>[
    Skill(
      id: 'builtin-summarize',
      name: 'Summarize this thread',
      description: 'The decisions, open questions and next steps so far',
      body: 'Summarize this conversation so far for someone who has not read it. Start with a one-sentence overview, then list the decisions made, the open questions and the agreed next steps as short bullet points. Keep every name, number and date exactly as written. Do not add anything that was not said.',
    ),
    Skill(
      id: 'builtin-code-review',
      name: 'Code review',
      description: 'Real defects first, each with the case that breaks it',
      body: 'Review the code in this message as a demanding senior reviewer. Report only real defects and concrete simplifications, most severe first. For each one give the file or line, what goes wrong, a concrete input or scenario that triggers it, and the smallest fix. Skip praise, style nits and a summary of what the code does. If you find nothing wrong, say so in one line.',
    ),
    Skill(
      id: 'builtin-release-notes',
      name: 'Write release notes',
      description: 'User-facing notes from changes or a diff',
      body: 'Write release notes from the changes in this message for the people who use the product, not its developers. Group them under New, Improved and Fixed, leaving out empty groups. One line per change, in plain words that say what the user can now do or what no longer goes wrong. Leave out internal refactors, dependency bumps and anything a user would never notice.',
    ),
    Skill(
      id: 'builtin-explain-new',
      name: "Explain like I'm new",
      description: 'Plain words, one example, no jargon',
      body: 'Explain the topic in this message to someone who is new to it. Start from what they already know from everyday life, use one concrete example before any definition, and replace every piece of jargon with plain words, or define it the first time it appears. Keep it short, then end with the one idea they should remember.',
    ),
  ];

  static Map<String, dynamic> builtinJson(Skill s) =>
      {'id': s.id, 'name': s.name, 'description': s.description, 'body': s.body};

  static bool isBuiltin(String id) => builtin.any((s) => s.id == id);

  static String lowerAscii(String s) =>
      s.replaceAllMapped(RegExp('[A-Z]'), (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) + 32));

  static String clean(Object? v) {
    final s = v is String ? v : '';
    return s
        .replaceAll(RegExp('[\u0000-\u001f\u007f  ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^ +| +$'), '');
  }

  static String cleanBody(Object? v) {
    final s = v is String ? v : '';
    return s
        .replaceAll(RegExp(r'\r\n?'), '\n')
        .replaceAll(RegExp('[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'), '')
        .replaceAll(RegExp(r'^\s+|\s+$'), '');
  }

  static Map<String, dynamic> normalize(Object? raw) {
    if (raw is! Map) return {'error': 'name'};
    final name = clean(raw['name']);
    if (name.isEmpty) return {'error': 'name'};
    if (name.length > nameMax) return {'error': 'name-long'};
    final description = clean(raw['description']);
    if (description.length > descriptionMax) return {'error': 'description-long'};
    final body = cleanBody(raw['body']);
    if (body.isEmpty) return {'error': 'body'};
    if (body.length > bodyMax) return {'error': 'body-long'};
    final order = raw['order'] is int && (raw['order'] as int) >= 0 ? raw['order'] as int : 0;
    final up = raw['updatedAt'];
    final updatedAt = up is num && up.isFinite && up > 0 ? up.floor() : 0;
    final id = raw['id'];
    return {
      'skill': {
        'id': id is String && _id.hasMatch(id) ? id : '',
        'name': name,
        'description': description,
        'body': body,
        'order': order,
        'updatedAt': updatedAt,
      }
    };
  }

  static String slug(String name) {
    var s = lowerAscii(name).replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.length > slugMax) s = s.substring(0, slugMax).replaceAll(RegExp(r'-+$'), '');
    return s;
  }

  static String slugOf(Skill s) {
    final out = slug(s.name);
    if (out.isNotEmpty) return out;
    final tail = lowerAscii(s.id).replaceAll(RegExp('[^a-z0-9]'), '');
    return 'skill-${tail.length > 8 ? tail.substring(0, 8) : tail}';
  }

  static List<Skill> ordered(List<Skill> list) {
    final indexed = [for (var i = 0; i < list.length; i++) (s: list[i], i: i)];
    indexed.sort((a, b) {
      final d = a.s.order - b.s.order;
      return d != 0 ? d : a.i - b.i;
    });
    return [for (final x in indexed) x.s];
  }

  static List<Skill> catalog(List<Skill> own) => [...ordered(own), ...builtin];

  static ({String id, String rest})? invocation(String text, List<Skill> list) {
    final m = RegExp(r'^/([A-Za-z0-9-]{1,48})(?=\s|$)').firstMatch(text);
    if (m == null) return null;
    final want = lowerAscii(m.group(1)!);
    for (final s in list) {
      if (slugOf(s) == want) {
        return (id: s.id, rest: text.substring(m.group(0)!.length).replaceAll(RegExp(r'^\s+|\s+$'), ''));
      }
    }
    return null;
  }

  static String block(Skill s) => '[skill: ${s.name}]\n${s.body}';

  static int _score(Skill s, String term) {
    if (term.isEmpty) return 1;
    final sl = slugOf(s);
    if (sl == term) return 1000;
    if (sl.startsWith(term)) return 500 - sl.length;
    if (sl.contains(term)) return 200 - sl.length;
    if (lowerAscii(s.name).contains(term)) return 100;
    if (lowerAscii(s.description).contains(term)) return 50;
    return 0;
  }

  static List<Skill> match(String term, List<Skill> list, [int limit = 8]) {
    final needle = lowerAscii(term).replaceFirst(RegExp('^/'), '').replaceAll(RegExp(r'^\s+|\s+$'), '');
    final scored = [
      for (var i = 0; i < list.length; i++) (s: list[i], i: i, n: _score(list[i], needle))
    ].where((x) => x.n > 0).toList();
    scored.sort((a, b) {
      final d = b.n - a.n;
      return d != 0 ? d : a.i - b.i;
    });
    return [for (final x in scored.take(limit)) x.s];
  }

  static List<Skill> move(List<Skill> list, String id, int delta) {
    final out = [...ordered(list)];
    final at = out.indexWhere((s) => s.id == id);
    if (at >= 0) {
      var to = at + delta;
      if (to < 0) to = 0;
      if (to > out.length - 1) to = out.length - 1;
      final item = out.removeAt(at);
      out.insert(to, item);
    }
    return [for (var i = 0; i < out.length; i++) out[i].copyWith(order: i)];
  }

  static ({String text, List<String> blocks, Skill? skill}) wire(
      String text, List<Skill> all, Skill? attached) {
    final used = invocation(text, all);
    Skill? skill;
    if (used != null) {
      for (final s in all) {
        if (s.id == used.id) skill = s;
      }
    }
    final blocks = <String>[
      if (attached != null) block(attached),
      if (skill != null && (attached == null || attached.id != skill.id)) block(skill),
    ];
    return (
      text: skill != null ? (used!.rest.isEmpty ? skill.name : used.rest) : text,
      blocks: blocks,
      skill: skill
    );
  }

  static String label(Skill s) {
    switch (s.id) {
      case 'builtin-summarize':
        return t('Summarize this thread');
      case 'builtin-code-review':
        return t('Code review');
      case 'builtin-release-notes':
        return t('Write release notes');
      case 'builtin-explain-new':
        return t("Explain like I'm new");
      default:
        return s.name;
    }
  }

  static String describe(Skill s) {
    switch (s.id) {
      case 'builtin-summarize':
        return t('The decisions, open questions and next steps so far');
      case 'builtin-code-review':
        return t('Real defects first, each with the case that breaks it');
      case 'builtin-release-notes':
        return t('User-facing notes from changes or a diff');
      case 'builtin-explain-new':
        return t('Plain words, one example, no jargon');
      default:
        return s.description;
    }
  }

  static String errorText(String code) {
    switch (code) {
      case 'name':
        return t('Give the skill a name.');
      case 'name-long':
        return t('A skill name can be at most {n} characters.', {'n': nameMax});
      case 'description-long':
        return t('A skill description can be at most {n} characters.', {'n': descriptionMax});
      case 'body':
        return t('Write the instructions the skill gives Nymbot.');
      case 'body-long':
        return t('Skill instructions can be at most {n} characters.', {'n': bodyMax});
      case 'full':
        return t('You can keep up to {n} skills.', {'n': maxSkills});
      default:
        return t('That skill could not be saved.');
    }
  }
}
