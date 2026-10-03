import 'dart:async';

import '../features/i18n/i18n.dart';
import '../features/progress_lines.dart';
import '../models/conversation.dart';
import '../services/chat_engine.dart';
import '../services/research.dart';
import '../services/ask.dart';
import '../services/plan.dart';
import '../services/task_transcript.dart';
import 'app_controller.dart';
import 'store.dart';

typedef TranscriptLog = Future<({bool live, Map<String, dynamic>? run})?> Function(
    Conversation conv, String runId, int since);

class _Seen {
  String label = '';
  bool waiting = false;
}

class TranscriptBook {
  TranscriptBook(this.store);

  final Store store;
  final Map<String, TaskTranscript> live = {};
  final Expando<String> _ids = Expando();
  final Expando<_Seen> _seen = Expando();
  final Expando<bool> _hushed = Expando();
  final Set<String> _dirty = {};
  final Set<String> _loud = {};
  final Map<String, int> _fetched = {};
  final Map<String, int> _missed = {};
  Timer? _timer;
  TranscriptLog? fetchLog;
  void Function()? onChange;
  String? viewing;

  static const flushAfter = Duration(seconds: 1);
  static const logEvery = Duration(seconds: 30);
  static final _hex = RegExp(r'^[0-9a-f]{64}$');

  static int now() => DateTime.now().millisecondsSinceEpoch;

  List<TaskTranscript> listFor(String convId) {
    final mine = [for (final x in live.values) if (x.conv == convId) x];
    return [
      for (final x in store.transcripts(convId)) if (!mine.any((y) => y.id == x.id)) x,
      ...mine,
    ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  }

  TaskTranscript? _held(String convId, bool Function(TaskTranscript) pick) {
    for (final x in live.values) {
      if (x.conv == convId && pick(x)) return x;
    }
    for (final x in store.transcripts(convId)) {
      if (pick(x)) return x;
    }
    return null;
  }

  TaskTranscript _adopt(TaskTranscript tx) => live[tx.id] ??= tx.copy();

  TaskTranscript? find(String convId, String id) {
    if (id.isEmpty) return null;
    return _held(convId, (x) => x.id == id || x.run == id);
  }

  ({Set<String> ids, Set<String> runs}) index(String convId) {
    final ids = <String>{};
    final runs = <String>{};
    for (final x in listFor(convId)) {
      ids.addAll(x.replies);
      final run = x.run;
      if (run != null) runs.add(run);
    }
    return (ids: ids, runs: runs);
  }

  static bool covers(({Set<String> ids, Set<String> runs}) index, ChatMessage m) =>
      index.ids.contains(m.id) ||
      ((m.role == ChatRole.bot || m.role == ChatRole.note) && m.replyTo != null && index.runs.contains(m.replyTo));

  TaskTranscript? forMessage(String convId, ChatMessage m) {
    final all = listFor(convId);
    for (final x in all) {
      if (x.replies.contains(m.id)) return x;
    }
    final link = m.replyTo;
    if (link != null && link.isNotEmpty && (m.role == ChatRole.bot || m.role == ChatRole.note)) {
      for (final x in all) {
        if (x.run == link) return x;
      }
    }
    return null;
  }

  Map<String, dynamic>? prEvent(String convId, ChatMessage m, String stage, String text) {
    final found = forMessage(convId, m);
    if (found == null) return null;
    final tx = _adopt(found);
    final e = tx.pr(stage, text, now());
    if (e != null) {
      _touch(tx);
      onChange?.call();
    }
    return e;
  }

  TaskTranscript? of(ChatTurn turn) {
    final id = _ids[turn];
    return id == null ? null : live[id];
  }

  void _touch(TaskTranscript tx, {bool loud = false}) {
    if (tx.conv.isEmpty) return;
    _dirty.add(tx.conv);
    if (loud) _loud.add(tx.conv);
    _timer ??= Timer(flushAfter, () => unawaited(flush()));
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final convs = [..._dirty];
    _dirty.clear();
    for (final convId in convs) {
      final loud = _loud.remove(convId);
      if (!store.conversations().any((c) => c.id == convId)) continue;
      var list = listFor(convId);
      if (list.length > TaskTranscript.maxPerChat) list = list.sublist(list.length - TaskTranscript.maxPerChat);
      await store.saveTranscripts(convId, TaskTranscript.fit(list, TaskTranscript.storeMaxChars), quiet: !loud);
    }
    live.removeWhere((id, x) => x.end != null && id != viewing && !_dirty.contains(x.conv));
  }

  static String kindOf(ChatTurn turn) {
    if (turn.team != null) return 'team';
    if (turn.research != null) return 'research';
    if (turn.kind != 'chat' && turn.kind != 'repo' && TaskTranscript.kinds.contains(turn.kind)) return turn.kind;
    if (turn.log.any((s) => s['kind'] == 'tool' && s['connector'] != null)) return 'connector';
    if (turn.kind == 'repo' || turn.log.any((s) => s['kind'] == 'tool' || s['kind'] == 'server-run')) return 'repo';
    return 'chat';
  }

  TaskTranscript begin(ChatTurn turn, {String asked = ''}) {
    final at = now();
    final runId = turn.runId;
    TaskTranscript? tx;
    if (runId.isNotEmpty || turn.askId != null) {
      final held = _held(turn.conv.id, (x) =>
          x.end == null && ((runId.isNotEmpty && x.run == runId) || (turn.askId != null && x.ask == turn.askId)));
      if (held != null) {
        tx = _adopt(held);
        tx.setState('resumed', at);
      }
    }
    tx ??= TaskTranscript.create(
      id: turn.key,
      conv: turn.conv.id,
      at: turn.began.millisecondsSinceEpoch < at ? turn.began.millisecondsSinceEpoch : at,
      kind: kindOf(turn),
      label: asked.isNotEmpty ? asked : turn.label,
      model: turn.model?['label'] as String?,
      run: _hex.hasMatch(runId) ? runId : null,
      ask: turn.askId,
    );
    live[tx.id] = tx;
    _ids[turn] = tx.id;
    _seen[turn] = _Seen();
    _touch(tx);
    return tx;
  }

  void hush(ChatTurn turn, bool on) => _hushed[turn] = on ? true : null;

  void observe(ChatTurn turn, {String Function()? asked}) {
    var tx = of(turn);
    if (tx == null) {
      if (_ids[turn] != null) return;
      tx = begin(turn, asked: asked?.call() ?? '');
    }
    if (tx.end != null) return;
    final seen = _seen[turn] ??= _Seen();
    final at = now();
    var changed = false;
    final runId = turn.runId;
    if (_hex.hasMatch(runId) && tx.run != runId) {
      tx.run = runId;
      changed = true;
    }
    if (turn.askId != null && tx.ask == null) {
      tx.ask = turn.askId;
      changed = true;
    }
    final kind = kindOf(turn);
    if (kind != 'chat' && tx.kind != kind) {
      tx.kind = kind;
      changed = true;
    }
    final model = turn.model?['label'];
    if (tx.model == null && model is String && model.isNotEmpty) tx.model = TaskTranscript.clean(model, TaskTranscript.modelMax);
    final label = turn.status ?? turn.progress ?? t('Nymbot is thinking');
    if (label.isNotEmpty && label != seen.label) {
      seen.label = label;
      if (_hushed[turn] != true && tx.progress(label, at) != null) changed = true;
    }
    final waiting = turn.phase == 'slot';
    if (waiting != seen.waiting) {
      seen.waiting = waiting;
      if (tx.setState(waiting ? 'waiting' : 'running', at) != null) changed = true;
    }
    if (turn.plan.isNotEmpty && tx.setPlan(turn.plan, at) > 0) changed = true;
    for (final b in turn.branches) {
      if (tx.branch(b['repo'], b['branch'], at) != null) changed = true;
    }
    if (changed) _touch(tx);
  }

  static String lineOf(Map<String, dynamic> s) {
    try {
      if (s['kind'] == 'research') return Research.stepLine(Research.stepOf(s));
      final text = s['text'];
      if (s['kind'] == 'team' && text is String && text.trim().isNotEmpty) return text;
      return progressLine(ChatEngine.turnStep(s));
    } catch (_) {
      return '';
    }
  }

  void steps(ChatTurn turn, List<Map<String, dynamic>> raw) {
    if (_ids[turn] == null) observe(turn);
    final tx = of(turn);
    if (tx == null || tx.end != null || raw.isEmpty) return;
    final at = now();
    var changed = false;
    for (final s in raw) {
      if (s['kind'] == 'branch') {
        if (tx.branch(s['repo'], s['branch'], at) != null) changed = true;
        continue;
      }
      if (s['kind'] == 'plan') {
        if (tx.setPlan(ChatEngine.planOf(s['items']), at) > 0) changed = true;
        continue;
      }
      if (tx.step(s, lineOf(s), at) != null) changed = true;
    }
    if (changed) _touch(tx);
  }

  void note(ChatTurn turn, String text, {bool retry = false}) {
    final tx = of(turn);
    if (tx == null || tx.end != null || text.isEmpty) return;
    final at = now();
    if ((retry ? tx.retry(text, at) : tx.progress(text, at)) != null) _touch(tx);
  }

  void _settle(TaskTranscript tx, List<ChatMessage> list, String? link, String? askId) {
    final at = now();
    final mine = <ChatMessage>[];
    if (link != null && link.isNotEmpty) {
      mine.addAll(list.where((m) => m.replyTo == link && m.role != ChatRole.self));
    } else if (askId != null) {
      final from = list.indexWhere((m) => m.id == askId);
      if (from != -1) {
        for (var i = from + 1; i < list.length && list[i].role != ChatRole.self; i++) {
          mine.add(list[i]);
        }
      }
    }
    for (final m in mine) {
      if (!tx.link(m.id)) continue;
      if (m.role == ChatRole.bot) {
        if (tx.model == null && m.model != null) tx.model = TaskTranscript.clean(m.model, TaskTranscript.modelMax);
        final spent = m.cost + m.serverRunCredits;
        if (spent > 0) tx.spend(spent, '', at);
        final qs = Ask.questionsOf(m.ask?['questions']);
        if (qs.isNotEmpty) tx.question('asked', '${qs.first['question'] ?? ''}', qs.length, at);
        final pp = m.proposal;
        if (pp != null && '${pp['summary'] ?? ''}'.isNotEmpty && Plan.itemsOf(pp['items']).isNotEmpty) {
          tx.proposal('proposed', '${pp['summary']}', Plan.itemsOf(pp['items']).length, at);
        }
      } else if (m.role == ChatRole.error) {
        tx.error(m.content, at);
      }
    }
  }

  void finish(ChatTurn turn, List<ChatMessage> list) {
    final tx = of(turn);
    if (tx == null || tx.end != null) return;
    observe(turn);
    final at = now();
    final link = turn.runId.isEmpty ? null : turn.runId;
    _settle(tx, list, link, turn.askId);
    final out = turn.outcome;
    if (out == 'background' && !turn.stopped) {
      tx.setState('parked', at);
      _touch(tx);
      unawaited(flush());
      return;
    }
    final replied = tx.replies.any((id) => list.any((m) => m.id == id && m.role == ChatRole.bot));
    var state = 'completed';
    if (turn.stopped || out == 'stopped') {
      state = 'canceled';
    } else if (!replied) {
      state = 'failed';
    }
    if (out == 'approval' || out == 'question') tx.setState('waiting', at);
    if (out == 'paused') tx.setState('parked', at);
    tx.finish(state, at);
    _touch(tx, loud: true);
    unawaited(flush());
  }

  void asked(ChatTurn turn, String stage, ChatMessage m) {
    final tx = of(turn);
    final qs = Ask.questionsOf(m.ask?['questions']);
    if (tx == null || qs.isEmpty) return;
    if (tx.question(stage, '${qs.first['question'] ?? ''}', qs.length, now()) != null) _touch(tx);
  }

  void planned(ChatTurn turn, String stage, ChatMessage m) {
    final tx = of(turn);
    final p = m.proposal;
    if (tx == null || p == null || '${p['summary'] ?? ''}'.isEmpty) return;
    final steps = Plan.itemsOf(p['approvedItems'] ?? p['items']);
    if (tx.proposal(stage, '${p['summary']}', steps.length, now()) != null) _touch(tx);
  }

  void steered(String runId, String text, {String? convId}) {
    if (runId.isEmpty || text.isEmpty) return;
    TaskTranscript? tx;
    for (final x in live.values) {
      if (x.run == runId || x.id == runId) tx = x;
    }
    if (tx == null && convId != null) {
      final got = find(convId, runId);
      if (got != null) tx = _adopt(got);
    }
    if (tx == null) return;
    tx.steer(text, now());
    _touch(tx);
  }

  TaskTranscript _remoteTx(String convId, RemoteRun r) {
    final held = _held(convId, (x) => x.run == r.replyTo);
    if (held != null) return _adopt(held);
    final tx = TaskTranscript.create(
        id: r.replyTo,
        conv: convId,
        run: r.replyTo,
        kind: r.kind,
        label: r.label,
        at: r.startedAt > 0 ? r.startedAt : now());
    live[tx.id] = tx;
    return tx;
  }

  bool _noteServer(TaskTranscript tx, Map<String, dynamic> r, int at) {
    var changed = false;
    final state = r['state'];
    if (state is String && const ['running', 'parked', 'waiting'].contains(state) && tx.setState(state, at) != null) {
      changed = true;
    }
    final plan = ChatEngine.planOf(r['plan']);
    if (plan.isNotEmpty && tx.setPlan(plan, at) > 0) changed = true;
    final branches = r['branches'];
    if (branches is List) {
      for (final b in branches) {
        if (b is Map && tx.branch(b['repo'], b['branch'], at) != null) changed = true;
      }
    }
    if (tx.merge(r['log']) > 0) changed = true;
    if (changed) _touch(tx);
    return changed;
  }

  void remote(List<RemoteRun> runs, Map<String, Map> raw, Conversation? Function(String thread) convOf,
      bool Function(String runId) local) {
    final at = now();
    for (final r in runs) {
      if (!_hex.hasMatch(r.replyTo) || local(r.replyTo)) continue;
      final conv = convOf(r.thread);
      if (conv == null) continue;
      final tx = _remoteTx(conv.id, r);
      if (tx.end != null) continue;
      _noteServer(tx, {...?raw[r.replyTo]?.cast<String, dynamic>(), 'state': r.state}, at);
      if (at - (_fetched[tx.id] ?? 0) > logEvery.inMilliseconds) unawaited(refresh(tx, conv));
    }
    for (final tx in [...live.values]) {
      if (tx.end != null || tx.run == null || tx.id != tx.run) continue;
      if (runs.any((r) => r.replyTo == tx.run) || local(tx.run!)) continue;
      if (at - (_fetched[tx.id] ?? 0) <= logEvery.inMilliseconds) continue;
      final conv = store.conversations().where((c) => c.id == tx.conv).firstOrNull;
      if (conv != null) unawaited(refresh(tx, conv));
    }
  }

  Future<bool> refresh(TaskTranscript tx, Conversation conv) async {
    final fetch = fetchLog;
    final run = tx.run;
    if (fetch == null || run == null || !_hex.hasMatch(run)) return false;
    _fetched[tx.id] = now();
    ({bool live, Map<String, dynamic>? run})? got;
    try {
      got = await fetch(conv, run, tx.startedAt);
    } catch (_) {
      got = null;
    }
    if (got == null) return false;
    final at = now();
    final r = got.run;
    if (!got.live && r == null && tx.id == tx.run && viewing != tx.id) {
      final n = (_missed[tx.id] ?? 0) + 1;
      _missed[tx.id] = n;
      if (n >= 3) {
        live.remove(tx.id);
        _missed.remove(tx.id);
      }
      return false;
    }
    if (r != null) _noteServer(tx, r, at);
    if (!got.live && r != null && tx.end == null && tx.id == tx.run) {
      final s = '${r['state'] ?? ''}';
      if (const ['done', 'stopped', 'failed'].contains(s)) {
        final when = (r['finishedAt'] as num?)?.toInt() ?? at;
        tx.finish(s == 'done' ? 'completed' : (s == 'stopped' ? 'canceled' : 'failed'), when);
        _touch(tx, loud: true);
      }
    }
    onChange?.call();
    return true;
  }

  Future<void> background(String runId, Conversation conv, Map r, List<ChatMessage> list, {bool ended = false}) async {
    final held = _held(conv.id, (x) => x.run == runId);
    if (held == null) return;
    final fresh = !live.containsKey(held.id);
    final tx = _adopt(held);
    final at = now();
    if (fresh && tx.end == null) tx.setState('resumed', at);
    _noteServer(tx, r.cast<String, dynamic>(), at);
    if (r['log'] == null && (ended || at - (_fetched[tx.id] ?? 0) > logEvery.inMilliseconds)) {
      final fetch = fetchLog;
      _fetched[tx.id] = at;
      if (fetch != null) {
        try {
          final got = await fetch(conv, runId, tx.startedAt);
          final run = got?.run;
          if (run != null) _noteServer(tx, run, now());
        } catch (_) {}
      }
    }
    if (ended && tx.end == null) {
      _settle(tx, list, runId, tx.ask);
      final s = '${r['state'] ?? ''}';
      tx.finish(s == 'stopped' ? 'canceled' : (s == 'failed' ? 'failed' : 'completed'), now());
      _touch(tx, loud: true);
      await flush();
    } else {
      _touch(tx);
    }
    onChange?.call();
  }

  Future<TaskTranscript?> scheduled(Conversation conv, ChatMessage reply, String runId, String label) async {
    if (!_hex.hasMatch(runId) || find(conv.id, runId) != null) return null;
    final at = reply.at.millisecondsSinceEpoch;
    final tx = TaskTranscript.create(id: runId, conv: conv.id, run: runId, kind: 'chat', label: label, at: at - 1);
    tx.link(reply.id);
    live[tx.id] = tx;
    final fetch = fetchLog;
    if (fetch != null) {
      try {
        final got = await fetch(conv, runId, at - 3600000);
        final run = got?.run;
        if (run != null) tx.merge(run['log']);
        final first = tx.entries.where((e) => e['type'] == 'progress').firstOrNull;
        if (first != null && (first['t'] as int) < tx.startedAt) {
          tx.startedAt = first['t'] as int;
          tx.entries.first['t'] = first['t'];
        }
      } catch (_) {}
    }
    tx.finish('completed', at > tx.updatedAt ? at : tx.updatedAt);
    _touch(tx, loud: true);
    await flush();
    return tx;
  }

  void dispose() {
    if (_timer != null) unawaited(flush());
    _timer?.cancel();
    _timer = null;
  }

  void forget(String convId) {
    live.removeWhere((_, x) => x.conv == convId);
    _dirty.remove(convId);
    _loud.remove(convId);
  }
}
