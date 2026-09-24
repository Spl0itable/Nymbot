import '../features/i18n/i18n.dart';
import '../models/model_maker.dart';
import 'chat_engine.dart';
import 'research.dart';

typedef TeamSetting = ({int workers, String key, String label});

typedef TeamEstimate = ({int max, double typical, String? error});

typedef TeamLane = ({int lane, String title, List<ResearchLine> lines, String state});

typedef TeamRow = ({String who, String model, double credits, String status});

class Team {
  const Team._();

  static const int minWorkers = 2;
  static const int maxWorkers = 4;
  static const int defaultWorkers = 3;

  static const Set<String> _final = {'done', 'stopped', 'failed', 'rework-failed'};
  static const Set<String> _statuses = {'done', 'stopped', 'failed', 'pending'};

  static int clampWorkers(Object? n) {
    final v = n is num && n.isFinite ? n.round() : null;
    if (v == null) return defaultWorkers;
    return v < minWorkers ? minWorkers : (v > maxWorkers ? maxWorkers : v);
  }

  static TeamSetting? settingOf(Object? raw) {
    if (raw is! Map) return null;
    final model = raw['model'];
    if (model is! Map) return null;
    final key = model['key'];
    if (key == null || '$key'.isEmpty) return null;
    final label = model['label'];
    return (
      workers: clampWorkers(raw['workers']),
      key: '$key',
      label: label == null || '$label'.isEmpty ? '$key' : '$label',
    );
  }

  static Map<String, dynamic> stored(int workers, String key, String label) => {
        'workers': clampWorkers(workers),
        'model': {'key': key, 'label': label},
      };

  static String? mode({
    required Map<String, dynamic>? lead,
    required bool research,
    required bool repos,
  }) {
    if (lead == null) return null;
    if (research) return 'research';
    return repos ? 'repo' : null;
  }

  static Map<String, dynamic>? claim(
    Object? raw, {
    required Map<String, dynamic>? lead,
    required bool research,
    required bool repos,
  }) {
    final team = settingOf(raw);
    if (team == null) return null;
    final m = mode(lead: lead, research: research, repos: repos);
    if (m == null) return null;
    return {'workers': team.workers, 'model': team.key, 'mode': m};
  }

  static List<Map<String, dynamic>> _chatModels(Map<String, dynamic>? catalog) {
    final list = catalog?['models'];
    if (list is! List) return const [];
    return [
      for (final m in list.whereType<Map<String, dynamic>>())
        if (m['key'] is String &&
            m['command'] == null &&
            ((m['kind'] as String?) ?? 'chat') == 'chat')
          m,
    ];
  }

  static double _price(Map<String, dynamic> m, Map<String, dynamic>? catalog) =>
      ChatEngine.nominalTurnRange(m, catalog)?.$1 ??
      ((m['credits'] as num?)?.toDouble() ?? 0);

  static double _ceiling(Map<String, dynamic> m) =>
      ((m['max'] ?? m['credits']) as num?)?.toDouble() ?? 0;

  static ({String key, String label})? defaultWorker(
      Map<String, dynamic>? catalog, Map<String, dynamic>? leader) {
    final rows = _chatModels(catalog);
    if (rows.isEmpty) return null;
    final leaderKey = leader?['key'];
    final full = rows.where((m) => m['key'] == leaderKey).firstOrNull;
    final family = full != null
        ? ModelMaker.of(full, catalog)?.slug
        : leader?['slug'] as String?;
    final metered = rows
        .where((m) => ChatEngine.nominalTurnCredits(m, catalog) != null)
        .toList();
    Map<String, dynamic>? cheapest(List<Map<String, dynamic>> list) {
      if (list.isEmpty) return null;
      final sorted = [...list]..sort((a, b) {
          final c = _price(a, catalog).compareTo(_price(b, catalog));
          return c != 0 ? c : _ceiling(a).compareTo(_ceiling(b));
        });
      return sorted.first;
    }

    final pick = (family == null
            ? null
            : cheapest([
                for (final m in metered)
                  if (ModelMaker.of(m, catalog)?.slug == family) m
              ])) ??
        cheapest(metered) ??
        cheapest(rows);
    if (pick == null) return null;
    final key = pick['key'] as String;
    return (key: key, label: (pick['label'] as String?) ?? key);
  }

  static String labelOf(Map<String, dynamic>? catalog, String key) {
    final list = catalog?['models'];
    if (list is List) {
      for (final m in list.whereType<Map<String, dynamic>>()) {
        if (m['key'] == key && m['label'] is String) return m['label'] as String;
      }
    }
    return key;
  }

  static Map<String, dynamic> estimateBody(
          Map<String, dynamic> lead, int workers, String model, String mode,
          {bool leadTools = false}) =>
      {
        'proModel': lead['key'],
        'team': {'workers': clampWorkers(workers), 'model': model, 'mode': mode},
        if (mode == 'research') 'research': true,
        if (mode == 'repo') 'repos': true,
        if (leadTools) 'leadTools': true,
      };

  static TeamEstimate estimateOf(int status, Map<String, dynamic> data) {
    final max = (data['maxCredits'] as num?)?.toDouble() ?? 0;
    if (status != 200 || data['error'] != null || !(max > 0)) {
      final said = status == 400 && data['error'] is String
          ? _clip(data['error'] as String, 400)
          : '';
      return (
        max: 0,
        typical: 0,
        error: said.isNotEmpty
            ? said
            : t('Could not work out what this team would cost right now.'),
      );
    }
    final typical = (data['typicalCredits'] as num?)?.toDouble() ?? 0;
    return (max: max.ceil(), typical: typical < 0 ? 0 : typical, error: null);
  }

  static String _clip(String text, int n) =>
      text.length > n ? text.substring(0, n) : text;

  static String _decimals(double v, int places) {
    var s = v.toStringAsFixed(places);
    while (s.contains('.') && (s.endsWith('0') || s.endsWith('.'))) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String credits(double v) => _decimals(v < 0 ? 0 : v, 3);

  static String priceLine(TeamEstimate est) =>
      t('Up to {max} Pro credits · usually about {typical}', {
        'max': figure(est.max),
        'typical': _decimals(est.typical, 1),
      });

  static String needsPro() =>
      t('Team mode needs a Pro model to lead it. Pick one with ?model first.');

  static String wrongTask() => t(
      'Team mode is for deep research and repository tasks. Turn Research on or connect a repository first.');

  static String stageLabel(String stage) {
    switch (stage) {
      case 'split':
        return t('Splitting the question');
      case 'plan':
        return t('Planning the work');
      case 'tool':
        return t('Working');
      case 'reconcile':
        return t('Combining what the workers found');
      case 'contradictions':
        return t('Checking where the workers disagree');
      case 'send-back':
        return t('Sending work back for another pass');
      case 'review':
        return t('Reviewing the work');
      case 'write':
        return t('Writing the answer');
      case 'resume':
        return t('Picking the work back up');
      case 'pause':
        return t('Pausing here to carry on in a new step');
      case 'approval':
        return t('Waiting for your approval');
      case 'declined':
        return t('Carrying on without it');
      case 'done':
        return t('Done');
      case 'assigned':
        return t('Given its part');
      case 'start':
        return t('Starting');
      case 'search':
        return t('Searching');
      case 'read':
        return t('Reading');
      case 'note':
        return t('Taking notes');
      case 'rework':
        return t('Reworking its part');
      case 'stopped':
        return t('Stopped at its budget');
      case 'failed':
        return t('Failed');
      case 'rework-failed':
        return t('The rework failed');
      default:
        return '';
    }
  }

  static String _stage(Object? raw) {
    final s = '${raw ?? ''}'.toLowerCase().replaceAll(RegExp(r'[^a-z-]'), '');
    return s.length > 30 ? s.substring(0, 30) : s;
  }

  static TurnStep stepOf(Map<String, dynamic> s) {
    final text = s['text'] is String
        ? _clip((s['text'] as String).replaceAll(RegExp(r'\s+'), ' ').trim(), 200)
        : '';
    return (
      n: (s['n'] as num?)?.toInt() ?? 0,
      kind: 'team',
      text: text,
      tool: _stage(s['stage']),
      call: (s['lane'] as num?)?.floor() ?? 0,
      of: (s['workers'] as num?)?.toInt() ?? 0,
      flag: false,
    );
  }

  static String laneLine(TurnStep step) =>
      step.text.isNotEmpty ? step.text : stageLabel(step.tool);

  static String laneTitle(int lane) =>
      lane == 0 ? t('Lead') : t('Worker {n}', {'n': lane});

  static List<TeamLane> lanes(List<TurnStep> steps, int workers) {
    var count = workers > 0 ? clampWorkers(workers) : 0;
    final kept = <int, List<({String line, String stage})>>{};
    for (final s in steps) {
      if (s.kind == 'routing' && s.of > 0) count = clampWorkers(s.of);
      if (s.kind != 'team') continue;
      final lane = s.call;
      if (lane < 0 || lane > maxWorkers) continue;
      if (lane == 0 && s.of > 0) count = clampWorkers(s.of);
      if (lane > count) count = lane;
      final line = laneLine(s);
      if (line.isEmpty) continue;
      final list = kept.putIfAbsent(lane, () => []);
      if (list.isNotEmpty && list.last.line == line) continue;
      list.add((line: line, stage: s.tool));
    }
    return [
      for (var lane = 0; lane <= count; lane++) _lane(lane, kept[lane] ?? const []),
    ];
  }

  static TeamLane _lane(int lane, List<({String line, String stage})> list) {
    final state =
        list.isNotEmpty && _final.contains(list.last.stage) ? list.last.stage : '';
    final List<ResearchLine> lines = list.isEmpty
        ? [
            (
              line: lane == 0 ? t('Starting the team') : t('Waiting for its part'),
              stage: 'start',
              current: true,
            )
          ]
        : [
            for (var i = 0; i < list.length; i++)
              (
                line: list[i].line,
                stage: list[i].stage,
                current: state.isEmpty && i == list.length - 1,
              ),
          ];
    return (lane: lane, title: laneTitle(lane), lines: lines, state: state);
  }

  static double _positive(Object? v) {
    final n = (v as num?)?.toDouble() ?? 0;
    return n.isFinite && n > 0 ? n : 0;
  }

  static Map<String, dynamic> _worker(Map w, int at, String workerModel) {
    final n = (w['lane'] as num?)?.floor() ?? 0;
    final lane = n == 0 ? at + 1 : n;
    final own = w['model'];
    return {
      'lane': lane < 1 ? 1 : lane,
      'model': _clip(own is String && own.isNotEmpty ? own : workerModel, 200),
      'credits': _positive(w['credits']),
      'steps': _positive(w['steps']).floor(),
      'status': _statuses.contains(w['status']) ? w['status'] : 'done',
    };
  }

  static Map<String, dynamic>? normalize(Object? raw) {
    if (raw is! Map || raw['workers'] is! List) return null;
    final workerModel = _clip('${raw['workerModel'] ?? ''}', 200);
    final list = (raw['workers'] as List).take(maxWorkers).whereType<Map>().toList();
    return {
      'mode': raw['mode'] == 'repo' ? 'repo' : 'research',
      'workerModel': workerModel,
      'overseerCredits': _positive(raw['overseerCredits']),
      'workers': [
        for (var i = 0; i < list.length; i++) _worker(list[i], i, workerModel),
      ],
      'sequential': raw['sequential'] == true,
    };
  }

  static String statusLabel(String status) {
    switch (status) {
      case 'stopped':
        return t('stopped');
      case 'failed':
        return t('failed');
      case 'pending':
        return t('not run yet');
      default:
        return t('done');
    }
  }

  static List<TeamRow> summary(
      Object? raw, String? leadModel, Map<String, dynamic>? catalog) {
    final team = normalize(raw);
    if (team == null) return const [];
    return [
      (
        who: t('Lead'),
        model: leadModel ?? '',
        credits: team['overseerCredits'] as double,
        status: '',
      ),
      for (final w in (team['workers'] as List).cast<Map<String, dynamic>>())
        (
          who: t('Worker {n}', {'n': w['lane']}),
          model: labelOf(catalog, w['model'] as String),
          credits: w['credits'] as double,
          status: w['status'] as String,
        ),
    ];
  }

  static bool sequential(Object? raw) => normalize(raw)?['sequential'] == true;

  static List<(String, String)> costRows(
      Object? raw, Map<String, dynamic>? catalog) {
    final team = normalize(raw);
    if (team == null) return const [];
    return [
      (
        t('Team lead'),
        t('{credits} Pro credits',
            {'credits': credits(team['overseerCredits'] as double)}),
      ),
      for (final w in (team['workers'] as List).cast<Map<String, dynamic>>())
        (
          t('Worker {n} · {model}',
              {'n': w['lane'], 'model': labelOf(catalog, w['model'] as String)}),
          t('{credits} Pro credits · {status}', {
            'credits': credits(w['credits'] as double),
            'status': statusLabel(w['status'] as String),
          }),
        ),
    ];
  }

  static String refusal(ChatFailure e) {
    if (e.noCredits) {
      return t(
          'Team mode can use up to {n} Pro credits and you have {have}. Nothing was run or charged. Top up, use fewer or cheaper workers, or send it without Team mode.',
          {'n': figure(e.required.ceil()), 'have': creditFigure(e.balance)});
    }
    return t(
        'Team mode did not start: {reason} Nothing was sent to a model and nothing was charged.',
        {'reason': _clip(e.message, 400)});
  }
}
