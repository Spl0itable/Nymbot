import '../features/i18n/i18n.dart';
import '../features/progress_lines.dart';
import '../models/conversation.dart';
import 'chat_engine.dart';
import 'git_review.dart';
import 'research.dart';
import 'team.dart';

typedef LiveTasks = ({
  List<Map<String, dynamic>> steps,
  Map<String, dynamic>? team,
  bool research,
  String label,
});

class TaskItem {
  TaskItem(this.label, this.state,
      {this.detail = '',
      List<String>? children,
      this.depth = 0,
      this.favicons = false,
      this.approval = false,
      this.tool = '',
      this.group = false,
      this.run})
      : children = children ?? [];

  String label;
  String state;
  String detail;
  List<String> children;
  final int depth;
  final bool favicons;
  final bool approval;
  final String tool;
  final bool group;
  Map<String, dynamic>? run;
}

class TaskGroup {
  TaskGroup({
    required this.id,
    required this.mode,
    required this.live,
    required this.title,
    required this.state,
    required this.items,
  });

  final String id;
  final String mode;
  final bool live;
  final String title;
  final String state;
  final List<TaskItem> items;
}

class Tasks {
  const Tasks._();

  static const _kinds = {'team', 'research', 'tool', 'connector', 'server-run', 'search', 'page'};
  static const _text = ['stage', 'text', 'query', 'host', 'tool', 'target', 'connector', 'image', 'command', 'model'];
  static const _numbers = ['lane', 'credits', 'code', 'subs', 'queries', 'found', 'sources', 'workers', 'ms', 'round'];
  static const maxSteps = 160;
  static const _headSteps = 40;
  static const _maxWorkers = 4;
  static const _final = {'done': 'done', 'stopped': 'stopped', 'failed': 'failed', 'rework-failed': 'failed'};

  static String _clip(Object? v, int max) {
    final s = '${v ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > max ? s.substring(0, max) : s;
  }

  static Map<String, dynamic>? compact(Object? step) {
    if (step is! Map || !_kinds.contains(step['kind'])) return null;
    final out = <String, dynamic>{'kind': step['kind']};
    for (final k in _text) {
      final v = step[k];
      if (v is String && v.trim().isNotEmpty) out[k] = _clip(v, 200);
    }
    for (final k in _numbers) {
      final v = step[k];
      if (v is num && v.isFinite) out[k] = v;
    }
    if (step['news'] == true) out['news'] = true;
    final q = step['questions'];
    if (q is List) {
      final kept = q.whereType<String>().map((x) => _clip(x, 160)).where((x) => x.isNotEmpty).take(5).toList();
      if (kept.isNotEmpty) out['questions'] = kept;
    }
    return out;
  }

  static List<Map<String, dynamic>> compactAll(List<Object?> steps) =>
      steps.map(compact).whereType<Map<String, dynamic>>().toList();

  static List<Map<String, dynamic>> _bounded(List<Map<String, dynamic>> list) {
    if (list.length <= maxSteps) return list;
    return [...list.sublist(0, _headSteps), ...list.sublist(list.length - (maxSteps - _headSteps))];
  }

  static String modeOf(Map<String, dynamic>? team, bool research, List<Map<String, dynamic>> steps) {
    if (team != null) return 'team';
    if (research) return 'research';
    if (steps.any((s) => s['kind'] == 'tool' || s['kind'] == 'server-run')) return 'repo';
    return 'chat';
  }

  static Map<String, dynamic>? record(LiveTasks live, String end) {
    final steps = _bounded(live.steps);
    final mode = modeOf(live.team, live.research, steps);
    if (steps.isEmpty && mode == 'chat') return null;
    final workers = (live.team?['workers'] as num?)?.floor() ?? 0;
    return {
      'v': 1,
      'mode': mode,
      'end': end,
      'steps': steps,
      if (workers > 0) 'workers': workers > _maxWorkers ? _maxWorkers : workers,
    };
  }

  static ({String mode, String end, List<Map<String, dynamic>> steps, int workers})? normalize(Object? raw) {
    if (raw is! Map || raw['steps'] is! List) return null;
    final mode = const ['team', 'research', 'repo', 'chat'].contains(raw['mode']) ? raw['mode'] as String : 'chat';
    final end = const ['done', 'stopped', 'failed'].contains(raw['end']) ? raw['end'] as String : 'done';
    final steps = _bounded(compactAll(raw['steps'] as List));
    final w = (raw['workers'] as num?)?.floor() ?? 0;
    return (mode: mode, end: end, steps: steps, workers: w < 0 ? 0 : (w > _maxWorkers ? _maxWorkers : w));
  }

  static Map<String, dynamic>? target(List<ChatMessage> list, DateTime since) {
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.role == ChatRole.bot && !m.at.isBefore(since)) return {'id': m.id, 'bot': true};
      if (m.role == ChatRole.self || m.role == ChatRole.bot) break;
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.role == ChatRole.bot) return null;
      if (m.role == ChatRole.self) return m.tasks != null ? null : {'id': m.id, 'bot': false};
    }
    return null;
  }

  static String _stage(Object? raw) {
    final s = '${raw ?? ''}'.toLowerCase().replaceAll(RegExp(r'[^a-z-]'), '');
    return s.length > 30 ? s.substring(0, 30) : s;
  }

  static String _teamLine(Map<String, dynamic> s) {
    final text = _clip(s['text'], 200);
    return text.isNotEmpty ? text : Team.stageLabel(_stage(s['stage']));
  }

  static String statusLabel(String state) {
    switch (state) {
      case 'done':
        return t('done');
      case 'failed':
        return t('failed');
      case 'stopped':
        return t('stopped');
      case 'waiting':
        return t('waiting for you');
      case 'active':
        return t('in progress');
      case 'skipped':
        return t('skipped');
      default:
        return t('not run yet');
    }
  }

  static String modeLabel(String mode) {
    switch (mode) {
      case 'team':
        return t('Team');
      case 'research':
        return t('Research');
      case 'repo':
        return t('Repository task');
      case 'tool':
        return t('Tool call');
      default:
        return t('Reply');
    }
  }

  static String _endState(String end) => end == 'failed' ? 'failed' : (end == 'stopped' ? 'stopped' : 'done');

  static List<TaskItem> _settle(List<TaskItem> items, bool live, String end) {
    if (items.isEmpty) return items;
    final last = items.last;
    if (live) {
      if (last.state == 'done') last.state = 'active';
      return items;
    }
    if (end == 'stopped' && (last.state == 'active' || last.state == 'pending')) last.state = 'stopped';
    for (final it in items) {
      if (it.state == 'active') it.state = _endState(end);
    }
    return items;
  }

  static List<TaskItem> _teamItems(List<Map<String, dynamic>> steps, ChatMessage? m, bool live, String end,
      int workers0, Map<String, dynamic>? catalog) {
    final lead = <TaskItem>[];
    final lanes = <int, ({String assigned, List<String> lines, String stage})>{};
    var workers = workers0;
    var workerKey = '';
    var split = -1;
    for (final s in steps) {
      if (s['kind'] != 'team') continue;
      final lane = (s['lane'] as num?)?.floor() ?? 0;
      if (lane < 0 || lane > _maxWorkers) continue;
      final stage = _stage(s['stage']);
      if (lane == 0) {
        final w = (s['workers'] as num?)?.floor() ?? 0;
        if (w > 0) workers = w > _maxWorkers ? _maxWorkers : w;
        if (s['model'] is String) workerKey = s['model'] as String;
        final line = _teamLine(s);
        if (line.isEmpty || (lead.isNotEmpty && lead.last.label == line)) continue;
        lead.add(TaskItem(line, stage == 'approval' ? 'waiting' : (stage == 'declined' ? 'skipped' : 'done')));
        continue;
      }
      if (lane > workers) workers = lane;
      final w = lanes[lane] ?? (assigned: '', lines: <String>[], stage: '');
      if (stage == 'assigned') {
        lanes[lane] = (assigned: _clip(s['text'], 200), lines: w.lines, stage: w.stage);
        if (split < 0) split = lead.length;
      } else {
        final line = _teamLine(s);
        if (line.isNotEmpty && (w.lines.isEmpty || w.lines.last != line)) w.lines.add(line);
        lanes[lane] = (assigned: w.assigned, lines: w.lines, stage: stage);
      }
    }
    for (var i = 0; i < lead.length - 1; i++) {
      if (lead[i].state == 'waiting') lead[i].state = 'done';
    }
    final team = Team.normalize(m?.team);
    final summary = team == null ? const <Map<String, dynamic>>[] : (team['workers'] as List).cast<Map<String, dynamic>>();
    for (final w in summary) {
      final n = (w['lane'] as num).floor();
      if (n > workers) workers = n > _maxWorkers ? _maxWorkers : n;
    }
    final crew = <TaskItem>[];
    for (var lane = 1; lane <= workers; lane++) {
      final w = lanes[lane] ?? (assigned: '', lines: <String>[], stage: '');
      Map<String, dynamic>? sum;
      for (final x in summary) {
        if ((x['lane'] as num).floor() == lane) sum = x;
      }
      var state = _final[w.stage] ?? '';
      if (state.isEmpty) {
        if (live) {
          state = w.lines.isNotEmpty ? 'active' : 'pending';
        } else if (sum != null) {
          state = sum['status'] == 'pending' ? 'pending' : (_final[sum['status']] ?? 'done');
        } else {
          state = _endState(end);
        }
      }
      final key = (sum?['model'] as String?) ?? (team?['workerModel'] as String?) ?? workerKey;
      final bits = [
        t('Worker {n}', {'n': lane}),
        if (key.isNotEmpty) Team.labelOf(catalog, key),
        if (sum != null) t('{credits} Pro credits', {'credits': Team.credits(sum['credits'] as double)}),
        statusLabel(state),
      ];
      final lines = w.lines.length > 6 ? w.lines.sublist(w.lines.length - 6) : w.lines;
      crew.add(TaskItem(w.assigned.isNotEmpty ? w.assigned : t('Worker {n}', {'n': lane}), state,
          depth: 1, detail: bits.join(' · '), children: [...lines]));
    }
    final before = split < 0 ? [...lead] : lead.sublist(0, split);
    final after = split < 0 ? <TaskItem>[] : lead.sublist(split);
    final out = before;
    if (crew.isNotEmpty) {
      final busy = crew.any((c) => c.state == 'active' || c.state == 'pending');
      final bad = crew.any((c) => c.state == 'failed');
      final cost = team == null
          ? ''
          : t('{credits} Pro credits', {'credits': Team.credits(team['overseerCredits'] as double)});
      out.add(TaskItem(t('{n} workers', {'n': crew.length}),
          live && busy && after.isEmpty ? 'active' : (bad ? 'failed' : 'done'),
          detail: cost.isEmpty ? '' : t('Lead: {cost}', {'cost': cost}), group: true));
      out.addAll(crew);
    }
    out.addAll(after);
    final top = out.where((x) => x.depth == 0).toList();
    if (live) {
      if (top.isNotEmpty && top.last.state == 'done' && !(top.last.group && crew.any((c) => c.state == 'active'))) {
        top.last.state = 'active';
      }
    } else {
      _settle(top, false, end);
    }
    return out;
  }

  static String _host(Object? url) {
    final u = Uri.tryParse('${url ?? ''}');
    return (u?.host ?? '').replaceFirst(RegExp(r'^www\.'), '');
  }

  static List<TaskItem> _researchItems(List<Map<String, dynamic>> steps, ChatMessage? m, bool live, String end) {
    TaskItem? plan;
    final searches = <TaskItem>[];
    final hosts = <String>[];
    var writing = false;
    var lastStage = '';
    for (final s in steps) {
      if (s['kind'] != 'research') continue;
      final stage = '${s['stage'] ?? ''}';
      lastStage = stage;
      if (stage == 'plan') {
        plan ??= TaskItem(t('Planning the research'), 'active');
      } else if (stage == 'planned') {
        plan ??= TaskItem('', 'done');
        plan.label = Research.stepLine(Research.stepOf(s));
        plan.state = 'done';
        plan.children = [...((s['questions'] as List?)?.whereType<String>() ?? const <String>[])].take(5).toList();
      } else if (stage == 'search') {
        final line = Research.stepLine(Research.stepOf(s));
        if (!searches.any((x) => x.label == line)) searches.add(TaskItem(line, 'done'));
      } else if (stage == 'read') {
        final host = '${s['host'] ?? ''}'.replaceFirst(RegExp(r'^www\.'), '');
        if (host.isNotEmpty && !hosts.contains(host)) hosts.add(host);
      } else if (stage == 'write') {
        writing = true;
      }
    }
    if (plan != null && plan.state == 'active' && (searches.isNotEmpty || !live)) plan.state = 'done';
    if (live && lastStage == 'search' && searches.isNotEmpty) searches.last.state = 'active';
    final shown = hosts.isNotEmpty
        ? hosts
        : <String>{for (final s in m?.sources ?? const <Map<String, dynamic>>[]) _host(s['url'])}
            .where((h) => h.isNotEmpty)
            .toList();
    final items = <TaskItem>[if (plan != null) plan, ...searches];
    if (shown.isNotEmpty) {
      items.add(TaskItem(
          shown.length == 1 ? t('Read 1 source') : t('Read {n} sources', {'n': shown.length}),
          live && lastStage == 'read' ? 'active' : 'done',
          children: shown.take(12).toList(),
          favicons: true));
    }
    var write = 'pending';
    if (!live) {
      write = _endState(end);
    } else if (writing) {
      write = 'active';
    }
    items.add(TaskItem(t('Writing the report'), write));
    if (!live) {
      for (final it in items) {
        if (it.state == 'active') it.state = write;
      }
    }
    return items;
  }

  static String _runDetail(Map<String, dynamic> run) {
    final bits = <String>[];
    if ('${run['image'] ?? ''}'.isNotEmpty) bits.add('${run['image']}');
    if (run['code'] != null) bits.add(t('exit {code}', {'code': '${run['code']}'}));
    final ms = (run['ms'] as num?) ?? (run['billedMs'] as num?) ?? 0;
    if (ms > 0) {
      final sec = (ms / 1000).round();
      bits.add(t('{n} s', {'n': figure(sec < 1 ? 1 : sec)}));
    }
    if (run['milli'] != null) {
      bits.add(t('{credits} Pro credits', {'credits': Team.credits(((run['milli'] as num?) ?? 0) / 1000)}));
    } else if (run['credits'] != null) {
      bits.add(t('{credits} Pro credits', {'credits': Team.credits(((run['credits'] as num?) ?? 0).toDouble())}));
    }
    return bits.join(' · ');
  }

  static String _runLabel(Map<String, dynamic> run) {
    final command = _clip(run['command'], 120);
    return command.isNotEmpty
        ? t('Server run: {command}', {'command': command})
        : t('Server run on {image}', {'image': '${run['image'] ?? ''}'});
  }

  static List<TaskItem> _workItems(List<Map<String, dynamic>> steps, ChatMessage? m, bool live, String end) {
    final out = <TaskItem>[];
    final runs = <TaskItem>[];
    for (final s in steps) {
      final kind = s['kind'];
      if (kind == 'server-run') {
        if (s['stage'] == 'start') {
          final run = <String, dynamic>{'image': s['image'], 'command': s['command']};
          final it = TaskItem(_runLabel(run), 'active', run: run, detail: '${s['image'] ?? ''}');
          runs.add(it);
          out.add(it);
        } else if (s['stage'] == 'done') {
          final open = runs.where((r) => r.state == 'active').toList();
          if (open.isEmpty) continue;
          final it = open.last;
          it.run!.addAll({'code': s['code'], 'ms': s['ms'], 'credits': s['credits']});
          it.state = s['code'] == null || s['code'] == 0 ? 'done' : 'failed';
          it.detail = _runDetail(it.run!);
        }
        continue;
      }
      if (kind == 'tool' && s['connector'] == null) {
        final target = _clip(s['target'], 160);
        final tool = '${s['tool'] ?? ''}';
        if (out.isNotEmpty && out.last.tool == tool && out.last.run == null) {
          if (target.isNotEmpty && !out.last.children.contains(target)) out.last.children.add(target);
          continue;
        }
        out.add(TaskItem(toolLabel(tool), 'done', tool: tool, children: target.isEmpty ? [] : [target]));
        continue;
      }
      final line = progressLine(ChatEngine.turnStep(s));
      if (line.isEmpty || (out.isNotEmpty && out.last.label == line)) continue;
      out.add(TaskItem(line, 'done'));
    }
    final kept = m?.serverRuns ?? const <Map<String, dynamic>>[];
    for (var i = 0; i < kept.length; i++) {
      final r = kept[i];
      final state = r['code'] == 0 ? 'done' : 'failed';
      if (i < runs.length) {
        final it = runs[i];
        it.run!.addAll(r);
        it.label = _runLabel(it.run!);
        it.state = state;
        it.detail = _runDetail(it.run!);
      } else {
        out.add(TaskItem(_runLabel(r), state, run: {...r}, detail: _runDetail(r)));
      }
    }
    for (final it in out) {
      if (it.children.length > 8) it.children = it.children.sublist(it.children.length - 8);
    }
    return _settle(out, live, end);
  }

  static List<TaskItem> _trailing(ChatMessage? m) {
    final out = <TaskItem>[];
    if (m == null) return out;
    final staged = m.staged;
    if (staged != null) {
      final all = allStaged(staged);
      final applied = staged['applied'] == true;
      final discarded = staged['discarded'] == true;
      out.add(TaskItem(
          applied
              ? t('Staged changes applied')
              : (discarded ? t('Staged changes discarded') : t('Changes staged for your review')),
          applied ? 'done' : (discarded ? 'skipped' : 'waiting'),
          detail: all
              .map((s) => '${s['repo'] ?? ''}${'${s['branch'] ?? ''}'.isEmpty ? '' : ' · ${s['branch']}'}')
              .join(', '),
          children: all.map((s) => '${s['message'] ?? ''}').where((x) => x.isNotEmpty).take(3).toList()));
    } else if (m.checkpoint != null && '${m.checkpoint!['repo'] ?? ''}'.isNotEmpty) {
      out.add(TaskItem(t('Changes committed to {repo}', {'repo': '${m.checkpoint!['repo']}'}), 'done'));
    }
    final p = m.pendingTool;
    if (p != null) {
      final run = p['kind'] == 'server-run';
      final settled = p['state'];
      final state = settled == 'allowed' ? 'done' : (settled == 'denied' ? 'skipped' : 'waiting');
      final label = run
          ? t('Run on a Nymbot server: {command}', {'command': _clip(p['command'], 120)})
          : t('Use {connector}: {tool}', {'connector': '${p['connector'] ?? ''}', 'tool': '${p['tool'] ?? ''}'});
      final bits = [
        if (p['team'] == true) t('Asked by the team lead'),
        if (run && '${p['image'] ?? ''}'.isNotEmpty) '${p['image']}',
        if (run && ((p['maxCredits'] as num?) ?? 0) > 0)
          t('Up to {credits} Pro credits', {'credits': Team.credits(((p['maxCredits'] as num?) ?? 0).toDouble())}),
        if (state != 'waiting') settled == 'allowed' ? t('allowed once') : (run ? t('declined') : t('denied')),
      ];
      out.add(TaskItem(label, state, detail: bits.join(' · '), approval: true));
    }
    return out;
  }

  static List<TaskItem> itemsFor(String mode, List<Map<String, dynamic>> steps, ChatMessage? m, bool live, String end,
      int workers, Map<String, dynamic>? catalog) {
    final List<TaskItem> items;
    if (mode == 'team') {
      items = _teamItems(steps, m, live, end, workers, catalog);
    } else if (mode == 'research') {
      items = _researchItems(steps, m, live, end);
    } else {
      items = _workItems(steps, m, live, end);
    }
    return [...items, ..._trailing(m)];
  }

  static String _asked(List<ChatMessage> list, int i) {
    for (var j = i; j >= 0; j--) {
      if (list[j].role == ChatRole.self) return _clip(list[j].content, 90);
    }
    return '';
  }

  static TaskGroup? _groupOf(ChatMessage m, List<ChatMessage> list, int i, Map<String, dynamic>? catalog) {
    final rec = normalize(m.tasks);
    var mode = rec?.mode;
    if (mode == null) {
      if (m.team != null) {
        mode = 'team';
      } else if (m.serverRuns.isNotEmpty || m.staged != null || m.checkpoint != null) {
        mode = 'repo';
      } else if (m.pendingTool != null) {
        mode = 'tool';
      }
    }
    if (mode == null) return null;
    final end = rec?.end ?? 'done';
    final items = itemsFor(mode, rec?.steps ?? const [], m.role == ChatRole.bot ? m : null, false, end,
        rec?.workers ?? 0, catalog);
    if (items.isEmpty) return null;
    final asked = _asked(list, i);
    return TaskGroup(
      id: m.id,
      mode: mode,
      live: false,
      title: asked.isNotEmpty ? asked : modeLabel(mode),
      state: items.any((x) => x.state == 'waiting') ? 'waiting' : end,
      items: items,
    );
  }

  static List<TaskGroup> outline(List<ChatMessage> list, {LiveTasks? live, Map<String, dynamic>? catalog}) {
    final groups = <TaskGroup>[];
    if (live != null) {
      final mode = modeOf(live.team, live.research, live.steps);
      final workers = (live.team?['workers'] as num?)?.floor() ?? 0;
      var items = mode == 'chat' && live.steps.isEmpty
          ? <TaskItem>[]
          : itemsFor(mode, live.steps, null, true, '', workers, catalog);
      if (items.isEmpty) items = [TaskItem(live.label, 'active')];
      final asked = _asked(list, list.length - 1);
      groups.add(TaskGroup(
        id: 'live',
        mode: mode,
        live: true,
        title: asked.isNotEmpty ? asked : live.label,
        state: 'running',
        items: items,
      ));
    }
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.role != ChatRole.bot && !(m.role == ChatRole.self && m.tasks != null)) continue;
      final g = _groupOf(m, list, i, catalog);
      if (g != null) groups.add(g);
    }
    return groups;
  }

  static int waiting(List<ChatMessage> list) {
    final recent = list.length > 40 ? list.sublist(list.length - 40) : list;
    return recent.where((m) {
      final p = m.pendingTool;
      return p != null && (p['state'] == null || p['state'] == 'waiting');
    }).length;
  }
}
