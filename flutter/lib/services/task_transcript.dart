import 'dart:convert';

class TaskTranscript {
  TaskTranscript._(this.id);

  static const version = 1;
  static const maxEntries = 2000;
  static const head = 100;
  static const textMax = 300;
  static const labelMax = 120;
  static const modelMax = 80;
  static const repoMax = 120;
  static const planMax = 20;
  static const branchMax = 20;
  static const replyMax = 50;
  static const maxPerChat = 100;
  static const storeMaxChars = 400000;
  static const syncMaxChars = 200000;
  static const kinds = ['chat', 'research', 'team', 'repo', 'connector', 'server-run', 'media', 'compare'];
  static const ends = ['completed', 'failed', 'canceled'];
  static const states = ['running', 'parked', 'waiting', 'resumed'];
  static const planStates = ['planned', 'doing', 'done', 'skipped', 'removed'];
  static const types = [
    'start', 'progress', 'plan', 'branch', 'steer', 'state', 'run', 'worker', 'error', 'retry', 'cost', 'end', 'omitted', 'question', 'pr'
  ];
  static const prStages = ['watch', 'ci-failed', 'ci-passed', 'review', 'fix', 'merged', 'closed', 'stopped'];
  static const questionStages = ['asked', 'answered', 'skipped', 'expired'];
  static const proposalStages = ['proposed', 'approved', 'edited', 'rejected', 'expired'];

  String id;
  String conv = '';
  String? run;
  String? ask;
  String? model;
  String kind = 'chat';
  String label = '';
  int startedAt = 0;
  int updatedAt = 0;
  String state = 'running';
  double cost = 0;
  int serverAt = 0;
  int seenAt = 0;
  List<Map<String, dynamic>> plan = [];
  List<String> branches = [];
  List<String> replies = [];
  String? end;
  int? endedAt;
  List<Map<String, dynamic>> entries = [];

  String get key => run ?? id;

  static final _control = RegExp(r'[\x00-\x1f\x7f]+');
  static final _space = RegExp(r'\s+');

  static String clean(Object? v, int max) {
    final s = '${v ?? ''}'.replaceAll(_control, ' ').replaceAll(_space, ' ').trim();
    return s.length > max ? '${s.substring(0, max - 1)}…' : s;
  }

  static int? _int(Object? v) {
    if (v == null || v is bool) return null;
    if (v is num) return v.isFinite ? v.floor() : null;
    if (v is String) {
      if (v.trim().isEmpty) return null;
      final n = num.tryParse(v.trim());
      return n != null && n.isFinite ? n.floor() : null;
    }
    return null;
  }

  static double? _money(Object? v) {
    if (v == null || v is bool) return null;
    num? n;
    if (v is num) n = v;
    if (v is String && v.trim().isNotEmpty) n = num.tryParse(v.trim());
    if (n == null || !n.isFinite || n <= 0) return null;
    return (n * 1e6).round() / 1e6;
  }

  static Map<String, dynamic>? entryOf(Object? raw) {
    if (raw is! Map || !types.contains(raw['type'])) return null;
    final t = _int(raw['t']);
    if (t == null || t < 0) return null;
    final type = raw['type'] as String;
    final out = <String, dynamic>{'t': t, 'type': type};
    final text = clean(raw['text'], type == 'start' ? labelMax : textMax);
    final n = _int(raw['n']);
    switch (type) {
      case 'start':
        out['kind'] = kinds.contains(raw['kind']) ? raw['kind'] : 'chat';
        out['text'] = text;
        final model = clean(raw['model'], modelMax);
        if (model.isNotEmpty) out['model'] = model;
      case 'progress':
        if (text.isEmpty) return null;
        out['text'] = text;
        if (n != null && n > 1) out['n'] = n;
        if (raw['s'] == 1 || raw['s'] == true) out['s'] = 1;
      case 'plan':
        if (text.isEmpty) return null;
        out['text'] = text;
        if (raw['stage'] != null) {
          if (!proposalStages.contains(raw['stage'])) return null;
          out['stage'] = raw['stage'];
          if (n != null && n > 1) out['n'] = n;
        } else {
          out['state'] = planStates.contains(raw['state']) ? raw['state'] : 'planned';
        }
      case 'branch':
        if (text.isEmpty) return null;
        out['text'] = text;
        final repo = clean(raw['repo'], repoMax);
        if (repo.isNotEmpty) out['repo'] = repo;
      case 'state':
        if (!states.contains(raw['state'])) return null;
        out['state'] = raw['state'];
      case 'run':
        out['stage'] = raw['stage'] == 'done' ? 'done' : 'start';
        if (text.isNotEmpty) out['text'] = text;
        for (final k in const ['code', 'ms', 'lines', 'files']) {
          final v = _int(raw[k]);
          if (v != null && (k == 'code' || v >= 0)) out[k] = v;
        }
        final c = _money(raw['cost']);
        if (c != null) out['cost'] = c;
      case 'worker':
        final lane = _int(raw['lane']);
        if (text.isEmpty || lane == null || lane < 1) return null;
        out['lane'] = lane;
        out['text'] = text;
        if (n != null && n > 1) out['n'] = n;
      case 'cost':
        final c = _money(raw['cost']);
        if (c == null) return null;
        out['cost'] = c;
        if (text.isNotEmpty) out['text'] = text;
      case 'end':
        out['state'] = ends.contains(raw['state']) ? raw['state'] : 'completed';
        final ms = _int(raw['ms']);
        out['ms'] = ms != null && ms > 0 ? ms : 0;
        final c = _money(raw['cost']);
        if (c != null) out['cost'] = c;
      case 'omitted':
        if (n == null || n < 1) return null;
        out['n'] = n;
      case 'question':
        if (!questionStages.contains(raw['stage'])) return null;
        out['stage'] = raw['stage'];
        if (text.isNotEmpty) out['text'] = text;
        if (n != null && n > 1) out['n'] = n;
      case 'pr':
        if (!prStages.contains(raw['stage'])) return null;
        out['stage'] = raw['stage'];
        if (text.isNotEmpty) out['text'] = text;
      default:
        if (text.isEmpty) return null;
        out['text'] = text;
    }
    return out;
  }

  void _cap() {
    if (entries.length <= maxEntries) return;
    final k = entries.length - maxEntries;
    final mark = entries.length > head ? entries[head] : null;
    if (mark != null && mark['type'] == 'omitted') {
      mark['n'] = (mark['n'] as int) + k;
      entries.removeRange(head + 1, head + 1 + k);
    } else {
      final first = entries[head]['t'] as int;
      entries.removeRange(head, head + k + 1);
      entries.insert(head, {'t': first, 'type': 'omitted', 'n': k + 1});
    }
  }

  static bool _same(Map<String, dynamic>? a, Map<String, dynamic> b) {
    if (a == null || a['type'] != b['type'] || a['text'] != b['text']) return false;
    if (a['type'] == 'progress') return (a['s'] == 1) == (b['s'] == 1);
    if (a['type'] == 'worker') return a['lane'] == b['lane'];
    return false;
  }

  Map<String, dynamic>? push(Map<String, dynamic> raw) {
    final e = entryOf(raw);
    if (e == null) return null;
    final last = entries.isEmpty ? null : entries.last;
    if ((e['type'] == 'progress' || e['type'] == 'worker') && _same(last, e)) {
      last!['n'] = ((last['n'] as int?) ?? 1) + 1;
    } else {
      entries.add(e);
    }
    final t = e['t'] as int;
    if (t > updatedAt) updatedAt = t;
    _cap();
    return e;
  }

  static TaskTranscript create({
    required String id,
    required String conv,
    required int at,
    String? kind,
    String? label,
    String? model,
    String? run,
    String? ask,
  }) {
    final tx = TaskTranscript._(id)
      ..conv = conv
      ..kind = kinds.contains(kind) ? kind! : 'chat'
      ..label = clean(label, labelMax)
      ..startedAt = at
      ..updatedAt = at;
    if (run != null && run.isNotEmpty) tx.run = run;
    if (ask != null && ask.isNotEmpty) tx.ask = ask;
    final m = clean(model, modelMax);
    if (m.isNotEmpty) tx.model = m;
    tx.push({'t': at, 'type': 'start', 'kind': tx.kind, 'text': tx.label, 'model': m});
    return tx;
  }

  Map<String, dynamic>? progress(String? text, int at, {bool server = false}) =>
      push({'t': at, 'type': 'progress', 'text': text, 's': server ? 1 : 0});

  static List<Map<String, dynamic>> planItems(Object? raw) {
    final out = <Map<String, dynamic>>[];
    for (final it in raw is List ? raw : const []) {
      if (it is! Map) continue;
      final text = clean(it['text'], labelMax);
      if (text.isEmpty || out.any((x) => x['text'] == text)) continue;
      final s = it['state'];
      out.add({'text': text, 'state': const ['planned', 'doing', 'done', 'skipped'].contains(s) ? s : 'planned'});
      if (out.length >= planMax) break;
    }
    return out;
  }

  int setPlan(Object? items, int at) {
    final next = planItems(items);
    final old = plan;
    var changed = 0;
    for (final it in next) {
      final was = old.where((x) => x['text'] == it['text']).firstOrNull;
      if (was != null && was['state'] == it['state']) continue;
      if (push({'t': at, 'type': 'plan', 'text': it['text'], 'state': it['state']}) != null) changed++;
    }
    for (final it in old) {
      if (next.any((x) => x['text'] == it['text'])) continue;
      if (push({'t': at, 'type': 'plan', 'text': it['text'], 'state': 'removed'}) != null) changed++;
    }
    plan = next;
    return changed;
  }

  Map<String, dynamic>? branch(Object? repo, Object? name, int at) {
    final b = clean(name, textMax);
    if (b.isEmpty || branches.contains(b)) return null;
    branches = [...branches, b];
    if (branches.length > branchMax) branches = branches.sublist(branches.length - branchMax);
    return push({'t': at, 'type': 'branch', 'text': b, 'repo': repo});
  }

  Map<String, dynamic>? steer(String? text, int at) => push({'t': at, 'type': 'steer', 'text': text});

  Map<String, dynamic>? setState(String? s, int at) {
    if (!states.contains(s)) return null;
    final next = s == 'resumed' ? 'running' : s!;
    if (s != 'resumed' && state == next) return null;
    state = next;
    return push({'t': at, 'type': 'state', 'state': s});
  }

  void _addCost(Object? amount) {
    final c = _money(amount);
    if (c != null) cost = ((cost + c) * 1e6).round() / 1e6;
  }

  Map<String, dynamic>? runStep(Map<String, dynamic> o, int at) {
    final e = push({...o, 't': at, 'type': 'run'});
    if (e != null && e['cost'] != null) _addCost(e['cost']);
    return e;
  }

  Map<String, dynamic>? worker(int lane, String? text, int at) =>
      push({'t': at, 'type': 'worker', 'lane': lane, 'text': text});

  Map<String, dynamic>? error(String? text, int at) => push({'t': at, 'type': 'error', 'text': text});

  Map<String, dynamic>? question(String? stage, String? text, int? count, int at) {
    final e = push({'t': at, 'type': 'question', 'stage': stage, 'text': text, 'n': count});
    if (e != null && stage == 'asked') setState('waiting', at);
    return e;
  }

  Map<String, dynamic>? proposal(String? stage, String? text, int? count, int at) {
    final e = push({'t': at, 'type': 'plan', 'stage': stage, 'text': text, 'n': count});
    if (e != null && stage == 'proposed') setState('waiting', at);
    return e;
  }

  Map<String, dynamic>? retry(String? text, int at) => push({'t': at, 'type': 'retry', 'text': text});

  Map<String, dynamic>? pr(String? stage, String? text, int at) =>
      push({'t': at, 'type': 'pr', 'stage': stage, 'text': text});

  Map<String, dynamic>? spend(Object? amount, String? text, int at) {
    final e = push({'t': at, 'type': 'cost', 'cost': amount, 'text': text});
    if (e != null) _addCost(e['cost']);
    return e;
  }

  Map<String, dynamic>? finish(String? s, int at, {Object? total}) {
    if (end != null) return null;
    final last = ends.contains(s) ? s! : 'completed';
    final sum = _money(total);
    if (sum != null) cost = sum;
    final e = push({'t': at, 'type': 'end', 'state': last, 'ms': at - startedAt, 'cost': cost});
    end = last;
    endedAt = at;
    return e;
  }

  Map<String, dynamic>? step(Map<String, dynamic> s, String line, int at) {
    if (at > seenAt) seenAt = at;
    if (s['kind'] == 'server-run') {
      final text = _or(s['command'], s['image']);
      if (s['stage'] == 'done') {
        return runStep({
          'stage': 'done', 'text': text, 'code': s['code'], 'ms': s['ms'], 'lines': s['lines'],
          'files': s['files'], 'cost': s['credits'],
        }, at);
      }
      return runStep({'stage': 'start', 'text': text}, at);
    }
    final lane = _int(s['lane']);
    if (s['kind'] == 'team' && lane != null && lane > 0) {
      return worker(lane, '${_or(s['text'], line)}', at);
    }
    if (line.isEmpty) return null;
    return progress(line, at);
  }

  static Object? _or(Object? a, Object? b) =>
      a == null || a == '' || a == false || a == 0 ? b : a;

  static List<(int, String)> logOf(Object? raw) {
    final out = <(int, String)>[];
    for (final it in raw is List ? raw : const []) {
      if (it is! List || it.length < 2) continue;
      final t = _int(it[0]);
      final text = clean(it[1], textMax);
      if (t == null || t < 0 || text.isEmpty) continue;
      out.add((t, text));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  int merge(Object? raw) {
    final log = logOf(raw);
    if (log.isEmpty) return 0;
    final cutoff = serverAt > seenAt ? serverAt : seenAt;
    var added = 0;
    for (final (t, text) in log) {
      if (t > serverAt) serverAt = t;
      if (t <= cutoff) continue;
      var at = entries.length;
      while (at > 0 && (entries[at - 1]['t'] as int) > t) {
        at--;
      }
      final prev = at > 0 ? entries[at - 1] : null;
      if (prev != null && prev['type'] == 'progress' && prev['s'] == 1 && prev['text'] == text) {
        prev['n'] = ((prev['n'] as int?) ?? 1) + 1;
      } else {
        entries.insert(at, {'t': t, 'type': 'progress', 'text': text, 's': 1});
      }
      if (t > updatedAt) updatedAt = t;
      added++;
    }
    _cap();
    return added;
  }

  bool link(String? id) {
    final s = id ?? '';
    if (s.isEmpty || replies.contains(s)) return false;
    replies = [...replies, s];
    if (replies.length > replyMax) replies = replies.sublist(replies.length - replyMax);
    return true;
  }

  static TaskTranscript? fromJson(Object? raw) {
    if (raw is! Map || raw['entries'] is! List) return null;
    final id = '${raw['id'] ?? ''}';
    if (id.isEmpty || id.length > 128) return null;
    final tx = TaskTranscript._(id)
      ..conv = _short('${raw['conv'] ?? ''}')
      ..kind = kinds.contains(raw['kind']) ? raw['kind'] as String : 'chat'
      ..label = clean(raw['label'], labelMax)
      ..startedAt = _floor0(raw['startedAt'])
      ..updatedAt = _floor0(raw['updatedAt'])
      ..state = const ['running', 'parked', 'waiting'].contains(raw['state']) ? raw['state'] as String : 'running'
      ..cost = _money(raw['cost']) ?? 0
      ..serverAt = _floor0(raw['serverAt'])
      ..seenAt = _floor0(raw['seenAt'])
      ..plan = planItems(raw['plan'])
      ..branches = [
        for (final b in raw['branches'] is List ? raw['branches'] as List : const [])
          if (clean(b, textMax).isNotEmpty) clean(b, textMax)
      ]
      ..replies = [
        for (final r in raw['replies'] is List ? raw['replies'] as List : const [])
          if (r is String && r.isNotEmpty && r.length <= 128) r
      ];
    if (tx.branches.length > branchMax) tx.branches = tx.branches.sublist(tx.branches.length - branchMax);
    if (tx.replies.length > replyMax) tx.replies = tx.replies.sublist(tx.replies.length - replyMax);
    final run = raw['run'];
    if (run is String && run.isNotEmpty && run.length <= 128) tx.run = run;
    final ask = raw['ask'];
    if (ask is String && ask.isNotEmpty && ask.length <= 128) tx.ask = ask;
    final model = clean(raw['model'], modelMax);
    if (model.isNotEmpty) tx.model = model;
    if (ends.contains(raw['end'])) {
      tx.end = raw['end'] as String;
      tx.endedAt = _floor0(raw['endedAt']);
    }
    for (final e in raw['entries'] as List) {
      final got = entryOf(e);
      if (got != null) tx.entries.add(got);
    }
    if (tx.entries.isEmpty) return null;
    for (final e in tx.entries) {
      final t = e['t'] as int;
      if (t > tx.updatedAt) tx.updatedAt = t;
    }
    tx._cap();
    return tx;
  }

  static String _short(String s) => s.length > 128 ? s.substring(0, 128) : s;

  static int _floor0(Object? v) {
    final n = _int(v);
    return n == null || n < 0 ? 0 : n;
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'id': id,
        'conv': conv,
        'kind': kind,
        'label': label,
        'startedAt': startedAt,
        'updatedAt': updatedAt,
        'state': state,
        'cost': cost,
        'serverAt': serverAt,
        'seenAt': seenAt,
        'plan': [for (final p in plan) {...p}],
        'branches': [...branches],
        'replies': [...replies],
        'entries': [for (final e in entries) {...e}],
        'run': ?run,
        'ask': ?ask,
        'model': ?model,
        'end': ?end,
        if (end != null) 'endedAt': endedAt ?? 0,
      };

  TaskTranscript copy() => fromJson(jsonDecode(jsonEncode(toJson())))!;

  static TaskTranscript _newer(TaskTranscript a, TaskTranscript b) {
    if (a.updatedAt != b.updatedAt) return a.updatedAt > b.updatedAt ? a : b;
    if (a.entries.length != b.entries.length) return a.entries.length > b.entries.length ? a : b;
    return a;
  }

  static List<TaskTranscript> mergeList(List<Object?> mine, List<Object?> theirs) {
    final byKey = <String, TaskTranscript>{};
    for (final raw in [...mine, ...theirs]) {
      final tx = raw is TaskTranscript ? fromJson(raw.toJson()) : fromJson(raw);
      if (tx == null) continue;
      final held = byKey[tx.key];
      byKey[tx.key] = held == null ? tx : _newer(held, tx);
    }
    final out = byKey.values.toList()
      ..sort((a, b) {
        final d = a.startedAt.compareTo(b.startedAt);
        return d != 0 ? d : a.id.compareTo(b.id);
      });
    return out.length > maxPerChat ? out.sublist(out.length - maxPerChat) : out;
  }

  static List<TaskTranscript> fit(List<TaskTranscript> list, int max) {
    final out = [...list];
    int size() => jsonEncode([for (final x in out) x.toJson()]).length;
    while (out.length > 1 && size() > max) {
      var at = 0;
      for (var i = 1; i < out.length; i++) {
        final a = out[at];
        final b = out[i];
        if (a.end == null && b.end != null) {
          at = i;
        } else if ((a.end == null) == (b.end == null) && b.startedAt < a.startedAt) {
          at = i;
        }
      }
      out.removeAt(at);
    }
    return out;
  }

  static String rel(num ms) {
    final total = ms <= 0 ? 0 : (ms / 1000).floor();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }
}
