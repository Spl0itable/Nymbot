import '../features/i18n/i18n.dart';
import 'chat_engine.dart';

typedef ResearchEstimate = ({int low, int high, int max});

typedef ResearchClaim = ({String question, Object payload, String? blocked});

typedef ResearchLine = ({String line, String stage, bool current});

class Research {
  const Research._();

  static final RegExp _command =
      RegExp(r'^\s*\?research\b[ \t]*', caseSensitive: false);

  static String? command(String text) {
    if (!_command.hasMatch(text)) return null;
    return text.replaceFirst(_command, '').trim();
  }

  static int _whole(Object? v) {
    final n = (v as num?)?.toDouble() ?? 0;
    return n.isFinite && n > 0 ? n.round() : 0;
  }

  static ResearchEstimate? estimateOf(Object? raw) {
    if (raw is! Map) return null;
    final low = _whole(raw['low']);
    var high = _whole(raw['high']);
    if (high < low) high = low;
    var max = _whole(raw['max']);
    if (max < high) max = high;
    if (max <= 0) return null;
    return (low: low, high: high, max: max);
  }

  static ResearchEstimate? estimateFor(
      Map<String, dynamic>? model, Map<String, dynamic>? pricing) {
    if (model == null) return null;
    final own = estimateOf(model['research']);
    if (own != null) return own;
    final byKey = pricing?['researchByKey'];
    if (byKey is Map) return estimateOf(byKey[model['key']]);
    return null;
  }

  static Map<String, dynamic> researchByKey(Map<String, dynamic>? catalog) {
    final out = <String, dynamic>{};
    final list = catalog?['models'];
    if (list is! List) return out;
    for (final m in list) {
      if (m is Map && m['key'] is String && m['research'] is Map) {
        out[m['key'] as String] = m['research'];
      }
    }
    return out;
  }

  static String needsPro() => t(
      'Deep research needs a Pro model: it runs many searches and model calls. Pick one with ?model first.');

  static String priceLine(String label, ResearchEstimate? est) {
    if (est == null) return t('Deep research with {model}', {'model': label});
    if (est.low == est.high) {
      return t('Deep research with {model} · about {n} Pro credits, up to {max}',
          {'model': label, 'n': est.low, 'max': est.max});
    }
    return t(
        'Deep research with {model} · about {low}–{high} Pro credits, up to {max}',
        {'model': label, 'low': est.low, 'high': est.high, 'max': est.max});
  }

  static String? hint({
    required String text,
    required bool armed,
    required Map<String, dynamic>? model,
    Map<String, dynamic>? pricing,
  }) {
    final typed = command(text);
    if (!armed && (typed == null || typed.isEmpty)) return null;
    if (model == null) return needsPro();
    final label = (model['label'] as String?) ?? (model['key'] as String? ?? '');
    return priceLine(label, estimateFor(model, pricing));
  }

  static Object payload(ResearchEstimate? est) =>
      est == null ? true : <String, dynamic>{'max': est.max};

  static ResearchClaim? claim(
    String typed, {
    required bool armed,
    required Map<String, dynamic>? model,
    Map<String, dynamic>? pricing,
  }) {
    final asked = command(typed);
    if (asked == null && !armed) return null;
    final question = asked ?? typed.trim();
    if (model == null) {
      return (question: question, payload: true, blocked: needsPro());
    }
    if (question.isEmpty) {
      return (
        question: question,
        payload: true,
        blocked: t('Say what to research after ?research.')
      );
    }
    return (
      question: question,
      payload: payload(estimateFor(model, pricing)),
      blocked: null
    );
  }

  static TurnStep stepOf(Map<String, dynamic> s) => (
        n: (s['n'] as num?)?.toInt() ?? 0,
        kind: 'research',
        text: (s['query'] ?? s['host'] ?? '').toString(),
        tool: (s['stage'] ?? '').toString(),
        call: (s['found'] as num?)?.toInt() ??
            (s['sources'] as num?)?.toInt() ??
            (s['subs'] as num?)?.toInt() ??
            0,
        of: (s['of'] as num?)?.toInt() ?? 0,
        flag: s['news'] == true,
      );

  static String stepLine(TurnStep step) {
    if (step.kind != 'research') return '';
    switch (step.tool) {
      case 'plan':
        return t('Planning the research');
      case 'planned':
        return t('Planned {n} questions to answer', {'n': step.call});
      case 'resume':
        return t('Picking the research back up');
      case 'search':
        return step.flag
            ? t('Searching the news for “{query}”', {'query': step.text})
            : t('Searching for “{query}”', {'query': step.text});
      case 'read':
        return t('Reading {host}',
            {'host': step.text.replaceFirst(RegExp(r'^www\.'), '')});
      case 'note':
        return step.call > 0
            ? t('Noted {n} findings', {'n': step.call})
            : t('Nothing new on that round');
      case 'write':
        return t('Writing the report from {n} sources', {'n': step.call});
      case 'pause':
        return t('Pausing here to carry on in a new step');
      default:
        return '';
    }
  }

  static List<ResearchLine> lines(List<TurnStep> steps) {
    final kept = <({String line, String stage})>[];
    for (final s in steps) {
      if (s.kind != 'research') continue;
      final line = stepLine(s);
      if (line.isEmpty || (kept.isNotEmpty && kept.last.line == line)) continue;
      kept.add((line: line, stage: s.tool));
    }
    if (kept.isEmpty) {
      return [(line: t('Starting the research'), stage: 'start', current: true)];
    }
    return [
      for (var i = 0; i < kept.length; i++)
        (line: kept[i].line, stage: kept[i].stage, current: i == kept.length - 1),
    ];
  }
}
