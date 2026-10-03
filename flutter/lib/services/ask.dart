import 'dart:convert';

import '../features/i18n/i18n.dart';

class AskLimits {
  static const questions = 4;
  static const optionsMin = 2;
  static const optionsMax = 4;
  static const question = 300;
  static const header = 30;
  static const label = 60;
  static const description = 160;
  static const other = 500;
  static const waitMs = 86400000;

  static Map<String, int> get asMap => {
        'questions': questions,
        'optionsMin': optionsMin,
        'optionsMax': optionsMax,
        'question': question,
        'header': header,
        'label': label,
        'description': description,
        'other': other,
        'waitMs': waitMs,
      };
}

class Ask {
  static final _id = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');
  static final _block = RegExp(r'<ask_user>([\s\S]*?)</ask_user>');
  static const states = {'waiting', 'sending', 'answered', 'skipped', 'expired'};

  static String clean(Object? v, [int max = 0]) {
    var s = v is String ? v : '';
    s = s
        .replaceAll(RegExp('[\u0000-\u001f\u007f  ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^ +| +$'), '');
    if (max > 0 && s.length > max) {
      s = '${s.substring(0, max - 1).replaceAll(RegExp(r' +$'), '')}…';
    }
    return s;
  }

  static Map<String, dynamic> parse(Object? raw) {
    final list = raw is Map && raw['questions'] is List ? raw['questions'] as List : null;
    if (list == null || list.isEmpty || list.length > AskLimits.questions) {
      return {'error': 'questions'};
    }
    final out = <Map<String, dynamic>>[];
    for (final q in list) {
      if (q is! Map) return {'error': 'question'};
      final text = clean(q['question'], AskLimits.question);
      if (text.isEmpty) return {'error': 'question'};
      final opts = q['options'] is List ? q['options'] as List : const [];
      final seen = <String>{};
      final kept = <Map<String, dynamic>>[];
      for (final o in opts) {
        final obj = o is Map;
        final label = clean(obj ? o['label'] : o, AskLimits.label);
        if (label.isEmpty) return {'error': 'label'};
        final key = label.toLowerCase();
        if (key == 'other') continue;
        if (!seen.add(key)) return {'error': 'duplicate'};
        kept.add({
          'label': label,
          'description': clean(obj ? o['description'] : '', AskLimits.description),
        });
      }
      if (kept.length < AskLimits.optionsMin || kept.length > AskLimits.optionsMax) {
        return {'error': 'options'};
      }
      out.add({
        'question': text,
        'header': clean(q['header'], AskLimits.header),
        'multi': q['multiSelect'] == true || q['multi'] == true,
        'options': kept,
      });
    }
    return {'questions': out};
  }

  static List<Map<String, dynamic>> questionsOf(Object? raw) => raw is List
      ? [
          for (final q in raw)
            if (q is Map) q.cast<String, dynamic>()
        ]
      : const [];

  static List<Map<String, dynamic>> optionsOf(Map<String, dynamic> q) =>
      questionsOf(q['options']);

  static Map<String, dynamic> answers(List<Map<String, dynamic>> questions, Object? raw) {
    if (questions.isEmpty) return {'error': 'questions'};
    if (raw is! Map) return {'error': 'answers'};
    if (raw['skipped'] == true) return {'skipped': true};
    final list = raw['answers'] is List ? raw['answers'] as List : null;
    if (list == null || list.length != questions.length) return {'error': 'answers'};
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < questions.length; i++) {
      final a = list[i];
      if (a is! Map) return {'error': 'answers'};
      final sel = a['selected'] ?? const [];
      if (sel is! List) return {'error': 'selected'};
      final picked = <int>[];
      final count = optionsOf(questions[i]).length;
      for (final n in sel) {
        if (n is! int || n < 0 || n >= count || picked.contains(n)) {
          return {'error': 'selected'};
        }
        picked.add(n);
      }
      picked.sort();
      final other = clean(a['other'], AskLimits.other);
      final total = picked.length + (other.isNotEmpty ? 1 : 0);
      final multi = questions[i]['multi'] == true;
      if (multi ? total < 1 : total != 1) return {'error': multi ? 'empty' : 'single'};
      out.add({'selected': picked, 'other': other});
    }
    return {'answers': out};
  }

  static String answerText(List<Map<String, dynamic>> questions, Map<String, dynamic> answered) {
    if (answered['skipped'] == true) {
      return 'The user chose not to answer these questions. Carry on with your best judgment and say which assumptions you made.';
    }
    final given = questionsOf(answered['answers']);
    final lines = <String>['The user answered:'];
    for (var i = 0; i < questions.length; i++) {
      final q = questions[i];
      final a = given[i];
      final opts = optionsOf(q);
      final parts = <String>[
        for (final n in (a['selected'] as List)) '${opts[n as int]['label']}',
      ];
      final other = '${a['other'] ?? ''}';
      if (other.isNotEmpty) parts.add('Other: $other');
      lines.add('${i + 1}. ${q['question']}');
      lines.add('Answer: ${parts.join('; ')}');
    }
    return lines.join('\n');
  }

  static ({String text, Map<String, dynamic>? ask}) take(Object? text) {
    final src = text is String ? text : '';
    String? last;
    for (final m in _block.allMatches(src)) {
      last = m.group(1);
    }
    var rest = src.replaceAll(_block, '');
    final open = rest.indexOf(RegExp(r'<ask_user\b'));
    if (open != -1) rest = rest.substring(0, open);
    rest = rest.replaceAll(RegExp(r'\n{3,}'), '\n\n').replaceAll(RegExp(r'^\s+|\s+$'), '');
    Map<String, dynamic>? ask;
    if (last != null) {
      Object? obj;
      try {
        obj = jsonDecode(last);
      } catch (_) {
        obj = null;
      }
      final parsed = obj is Map ? parse(obj) : const {'error': 'json'};
      if (parsed['error'] == null && obj is Map) {
        final id = obj['id'];
        ask = {
          'id': id is String && _id.hasMatch(id) ? id : '',
          'questions': parsed['questions'],
        };
      }
    }
    return (text: rest, ask: ask);
  }

  static Map<String, dynamic>? record(Map<String, dynamic>? took, Map<String, dynamic>? data, [int? now]) {
    if (took == null || '${took['id'] ?? ''}'.isEmpty) return null;
    final d = data ?? const <String, dynamic>{};
    final p = d['pendingTool'] is Map &&
            (d['pendingTool'] as Map)['kind'] == 'question' &&
            (d['pendingTool'] as Map)['id'] == took['id']
        ? (d['pendingTool'] as Map)
        : null;
    final at = now ?? DateTime.now().millisecondsSinceEpoch;
    final exp = p != null && p['expiresAt'] is num && (p['expiresAt'] as num) > 0
        ? ((p['expiresAt'] as num).toInt() < at + AskLimits.waitMs
            ? (p['expiresAt'] as num).toInt()
            : at + AskLimits.waitMs)
        : at + AskLimits.waitMs;
    final bgRaw = d['background'];
    final bg = bgRaw is Map &&
            bgRaw['waiting'] == true &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch('${bgRaw['runId'] ?? ''}')
        ? '${bgRaw['runId']}'
        : null;
    final tok = d['resumeToken'];
    final token = bg == null && tok is String && RegExp(r'^[0-9a-f]{32,64}$', caseSensitive: false).hasMatch(tok)
        ? tok
        : null;
    return {
      'id': took['id'],
      'questions': took['questions'],
      'plain': bg == null && token == null,
      'token': token,
      'runId': bg,
      'expiresAt': exp,
      'state': 'waiting',
    };
  }

  static String? stateOf(Map<String, dynamic>? a, [int? now]) {
    if (a == null) return null;
    final s = states.contains(a['state']) ? a['state'] as String : 'waiting';
    final exp = a['expiresAt'];
    if ((s == 'waiting' || s == 'sending') &&
        exp is num &&
        exp > 0 &&
        (now ?? DateTime.now().millisecondsSinceEpoch) >= exp) {
      return 'expired';
    }
    return s;
  }

  static bool pending(Map<String, dynamic>? a, [int? now]) => stateOf(a, now) == 'waiting';

  static String cut(String text) {
    final at = text.toLowerCase().indexOf('<ask_user');
    return at == -1 ? text : text.substring(0, at).replaceAll(RegExp(r'\s+$'), '');
  }

  static String errorText(String code) {
    switch (code) {
      case 'single':
        return t('Pick one answer for each question, or write your own.');
      case 'empty':
        return t('Pick at least one answer for each question, or write your own.');
      default:
        return t('That answer does not fit the question.');
    }
  }

  static ({String label, String state})? taskItem(Map<String, dynamic>? a, [int? now]) {
    if (a == null) return null;
    final qs = questionsOf(a['questions']);
    if (qs.isEmpty) return null;
    final first = '${qs.first['question'] ?? ''}';
    final s = stateOf(a, now);
    if (s == 'expired') return (label: t('Question expired: {question}', {'question': first}), state: 'stopped');
    if (s == 'waiting' || s == 'sending') {
      return (label: t('Waiting for your answer: {question}', {'question': first}), state: 'waiting');
    }
    return (label: t('Answered: {question}', {'question': first}), state: 'done');
  }
}
