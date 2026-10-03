import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import '../services/share_file.dart';
import '../services/task_transcript.dart';
import '../services/team.dart';
import '../state/app_controller.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';
import 'sheets/sheet.dart';

String transcriptKind(String kind) => switch (kind) {
      'research' => t('Research'),
      'team' => t('Team'),
      'repo' => t('Repository task'),
      'connector' => t('Connector'),
      'server-run' => t('Server run'),
      'media' => t('Media'),
      'compare' => t('Compare'),
      _ => t('Reply'),
    };

String _planState(Object? s) => switch (s) {
      'doing' => t('doing'),
      'done' => t('done'),
      'skipped' => t('skipped'),
      'removed' => t('removed'),
      _ => t('planned'),
    };

String _stateLabel(Object? s) => switch (s) {
      'parked' => t('Parked'),
      'waiting' => t('Waiting'),
      'resumed' => t('Resumed'),
      _ => t('Running'),
    };

String _credits(Object? v) => Team.credits(((v as num?) ?? 0).toDouble());

String _seconds(Object? ms) {
  final n = (((ms as num?) ?? 0) / 1000).round();
  return t('{n} s', {'n': figure(n < 0 ? 0 : n)});
}

String transcriptEntryLine(Map<String, dynamic> e) {
  final n = (e['n'] as num?)?.toInt() ?? 1;
  final times = n > 1 ? ' ${t('(×{n})', {'n': n})}' : '';
  final text = '${e['text'] ?? ''}';
  switch (e['type']) {
    case 'start':
      final model = e['model'];
      return t('Started: {label}', {'label': text}) + (model is String ? ' · $model' : '');
    case 'progress':
      return text + times;
    case 'plan':
      final stage = e['stage'];
      if (stage == null) return t('Plan: {item} ({state})', {'item': text, 'state': _planState(e['state'])});
      final steps = n > 1 ? ' ${t('({n} steps)', {'n': n})}' : '';
      return switch (stage) {
        'approved' => t('You approved the plan: {summary}', {'summary': text}) + steps,
        'edited' => t('You edited and approved the plan: {summary}', {'summary': text}) + steps,
        'rejected' => t('You rejected the plan: {summary}', {'summary': text}),
        'expired' => t('The plan was not approved in time: {summary}', {'summary': text}),
        _ => t('Nymbot proposed a plan: {summary}', {'summary': text}) + steps,
      };
    case 'branch':
      final repo = e['repo'];
      return t('Working on branch {branch}', {'branch': text}) + (repo is String ? ' · $repo' : '');
    case 'steer':
      return t('You added instructions: {text}', {'text': text});
    case 'state':
      return t('State: {state}', {'state': _stateLabel(e['state'])});
    case 'run':
      if (e['stage'] != 'done') return t('Server run started: {command}', {'command': text});
      final bits = [
        if (e['code'] != null) t('exit {code}', {'code': '${e['code']}'}),
        if (e['ms'] != null) _seconds(e['ms']),
        if (e['lines'] != null) t('{n} output lines', {'n': e['lines']}),
        if (e['files'] != null) t('{n} files', {'n': e['files']}),
        if (e['cost'] != null) t('{credits} credits', {'credits': _credits(e['cost'])}),
      ];
      return t('Server run finished') + (bits.isEmpty ? '' : ': ${bits.join(' · ')}');
    case 'worker':
      return t('Worker {n}: {text}', {'n': e['lane'], 'text': text}) + times;
    case 'error':
      return t('Error: {text}', {'text': text});
    case 'retry':
      return t('Retrying: {text}', {'text': text});
    case 'cost':
      return t('Step cost: {credits} credits', {'credits': _credits(e['cost'])});
    case 'end':
      final what = e['state'] == 'failed'
          ? t('Failed')
          : (e['state'] == 'canceled' ? t('Canceled') : t('Completed'));
      final cost = e['cost'] == null ? '' : ' · ${t('{credits} credits', {'credits': _credits(e['cost'])})}';
      return '$what · ${TaskTranscript.rel((e['ms'] as num?) ?? 0)}$cost';
    case 'omitted':
      return n == 1 ? t('1 step omitted') : t('{n} steps omitted', {'n': n});
    case 'pr':
      return switch (e['stage']) {
        'watch' => t('Pull request watch: {text}', {'text': text}),
        'ci-failed' => t('CI failed: {text}', {'text': text}),
        'ci-passed' => t('CI passing again: {text}', {'text': text}),
        'review' => t('Review comments: {text}', {'text': text}),
        'fix' => t('Fix run: {text}', {'text': text}),
        'merged' => t('Pull request merged: {text}', {'text': text}),
        'closed' => t('Pull request closed: {text}', {'text': text}),
        _ => t('Stopped watching: {text}', {'text': text}),
      };
    case 'question':
      final stage = e['stage'];
      final what = stage == 'answered'
          ? t('You answered: {question}', {'question': text})
          : stage == 'skipped'
              ? t('You skipped: {question}', {'question': text})
              : stage == 'expired'
                  ? t('No answer came in time: {question}', {'question': text})
                  : t('Nymbot asked: {question}', {'question': text});
      final more = stage == 'asked' && n > 1 ? ' ${t('(+{n} more)', {'n': n - 1})}' : '';
      return what.replaceAll(RegExp(r': $'), '') + more;
    default:
      return text;
  }
}

String _when(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

({String title, List<(String, String)> facts, bool running}) transcriptHead(TaskTranscript tx, {bool live = false}) {
  final running = tx.end == null && live;
  final now = DateTime.now().millisecondsSinceEpoch;
  final last = tx.end != null ? (tx.endedAt ?? tx.updatedAt) : (running ? now : tx.updatedAt);
  final state = switch (tx.end) {
    'completed' => t('Completed'),
    'failed' => t('Failed'),
    'canceled' => t('Canceled'),
    _ => running
        ? (tx.state == 'parked' ? t('In the background') : (tx.state == 'waiting' ? t('Waiting') : t('Running')))
        : t('Unfinished'),
  };
  return (
    title: tx.label.isEmpty ? transcriptKind(tx.kind) : tx.label,
    facts: [
      (t('Kind'), transcriptKind(tx.kind)),
      (t('Started'), _when(tx.startedAt)),
      (t('Duration'), TaskTranscript.rel(last - tx.startedAt)),
      (t('State'), state),
      if (tx.model != null) (t('Model'), tx.model!),
      if (tx.cost > 0) (t('Total cost'), t('{credits} credits', {'credits': _credits(tx.cost)})),
    ],
    running: running,
  );
}

String transcriptText(TaskTranscript tx, {bool live = false}) {
  final head = transcriptHead(tx, live: live);
  return [
    '${t('Transcript')}: ${head.title}',
    for (final (k, v) in head.facts) '$k: $v',
    '',
    for (final e in tx.entries) '+${TaskTranscript.rel((e['t'] as int) - tx.startedAt)}  ${transcriptEntryLine(e)}',
  ].join('\n');
}

Future<void> showTranscriptSheet(BuildContext context, {required String convId, required String id, bool remote = false}) {
  final app = AppScope.read(context);
  final tx = app.transcripts.find(convId, id);
  if (tx == null) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(t('There is no transcript for this yet.'))));
    return Future.value();
  }
  return showNymSheet<void>(
    context,
    (sheet) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, scroll) => TranscriptView(convId: convId, id: tx.id, remote: remote, controller: scroll),
    ),
  );
}

class TranscriptView extends StatefulWidget {
  const TranscriptView({super.key, required this.convId, required this.id, this.remote = false, this.controller});

  final String convId;
  final String id;
  final bool remote;
  final ScrollController? controller;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  AppController? _app;
  Timer? _poll;
  String _spoken = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_app != null) return;
    final app = _app = AppScope.read(context);
    app.transcripts.viewing = widget.id;
    if (widget.remote) {
      unawaited(_refresh());
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_refresh()));
    }
  }

  Future<void> _refresh() async {
    final app = _app;
    if (app == null || !mounted) return;
    final tx = app.transcripts.find(widget.convId, widget.id);
    final conv = app.conversations.where((c) => c.id == widget.convId).firstOrNull;
    if (tx == null || conv == null || tx.end != null) {
      _poll?.cancel();
      return;
    }
    await app.transcripts.refresh(app.transcripts.live[tx.id] ?? tx, conv);
  }

  @override
  void dispose() {
    _poll?.cancel();
    final app = _app;
    if (app != null && app.transcripts.viewing == widget.id) app.transcripts.viewing = null;
    super.dispose();
  }

  bool _live(AppController app, TaskTranscript tx) =>
      tx.end == null &&
      (app.turns.values.any((r) => app.transcripts.of(r)?.id == tx.id) ||
          app.remoteRuns.any((r) => r.replyTo == tx.run) ||
          app.backgroundRuns.any((r) => r.runId == tx.run));

  void _announce(String text) {
    if (text.isEmpty || text == _spoken || !mounted) return;
    _spoken = text;
    unawaited(SemanticsService.sendAnnouncement(View.of(context), text, Directionality.of(context)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final tx = app.transcripts.live[widget.id] ?? app.transcripts.find(widget.convId, widget.id);
    if (tx == null) return const SizedBox.shrink();
    final head = transcriptHead(tx, live: _live(app, tx));
    if (head.running && tx.entries.isNotEmpty) {
      final say = transcriptEntryLine(tx.entries.last);
      WidgetsBinding.instance.addPostFrameCallback((_) => _announce(say));
    }
    final faint = TextStyle(fontSize: 11.5, color: theme.hintColor);
    return Column(
      key: const ValueKey('transcript-sheet'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(t('Transcript'), style: theme.textTheme.titleMedium),
                ),
              ),
              IconButton(
                key: const ValueKey('transcript-copy'),
                tooltip: t('Copy'),
                icon: const NymGlyph('copy', size: 18),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: transcriptText(tx, live: head.running)));
                  messenger
                    ..clearSnackBars()
                    ..showSnackBar(SnackBar(content: Text(t('Copied.'))));
                },
              ),
              IconButton(
                key: const ValueKey('transcript-save'),
                tooltip: t('Export as text'),
                icon: const NymGlyph('share', size: 18),
                onPressed: () => unawaited(ShareFile.text(transcriptText(tx, live: head.running),
                    name: 'nymbot-transcript-${tx.startedAt}.txt', mime: 'text/plain', subject: head.title)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            controller: widget.controller,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text(head.title,
                  key: const ValueKey('transcript-label'),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 18,
                runSpacing: 6,
                children: [
                  for (final (k, v) in head.facts)
                    Semantics(
                      label: '$k: $v',
                      excludeSemantics: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(k, style: faint),
                          Text(v, key: ValueKey('transcript-fact-$k'), style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Semantics(
                header: true,
                child: Text(t('Steps'), style: theme.textTheme.titleSmall),
              ),
              const SizedBox(height: 6),
              if (tx.entries.length <= 1)
                Text(t('No steps recorded yet.'), style: faint),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < tx.entries.length; i++) _step(context, tx, i, faint),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _step(BuildContext context, TaskTranscript tx, int i, TextStyle faint) {
    final theme = Theme.of(context);
    final e = tx.entries[i];
    final type = e['type'];
    final when = '+${TaskTranscript.rel((e['t'] as int) - tx.startedAt)}';
    final line = transcriptEntryLine(e);
    final color = switch (type) {
      'error' => NymbotColors.danger,
      'retry' => NymbotColors.lightning,
      'state' || 'omitted' || 'cost' => theme.hintColor,
      'end' when e['state'] == 'failed' => NymbotColors.danger,
      _ => null,
    };
    return Semantics(
      label: '$when, $line',
      excludeSemantics: true,
      child: Container(
        key: ValueKey('transcript-step-$i'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: i == tx.entries.length - 1 ? null : Border(bottom: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 62, child: Text(when, style: faint.copyWith(fontFeatures: const [FontFeature.tabularFigures()]))),
            const SizedBox(width: 6),
            Expanded(
              child: Text(line,
                  style: TextStyle(
                      fontSize: 13,
                      color: color,
                      fontWeight: type == 'start' || type == 'end' ? FontWeight.w600 : null,
                      fontStyle: type == 'omitted' ? FontStyle.italic : null)),
            ),
          ],
        ),
      ),
    );
  }
}
