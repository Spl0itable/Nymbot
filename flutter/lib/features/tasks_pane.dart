import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app.dart';
import '../config.dart';
import '../core/theme/theme.dart';
import '../models/conversation.dart';
import '../services/background_jobs.dart';
import '../services/media_cache.dart';
import '../services/tasks.dart';
import '../state/app_controller.dart';
import 'citation_cards.dart';
import 'i18n/i18n.dart';
import 'motion.dart';
import 'nym_glyph.dart';
import 'run_card.dart';
import 'sheets/sheet.dart';

const double kTasksWide = 900;

bool tasksBeside(BuildContext context) => MediaQuery.sizeOf(context).width >= kTasksWide;

String tasksLabel(bool running, int waiting) {
  if (running) return t('Tasks: work is running');
  if (waiting == 1) return t('Tasks: 1 waiting for you');
  if (waiting > 1) return t('Tasks: {n} waiting for you', {'n': waiting});
  return t('Tasks');
}

class TasksButton extends StatelessWidget {
  const TasksButton({super.key, required this.onPressed, this.open = false});

  final VoidCallback onPressed;
  final bool open;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final conv = app.current;
    final live = app.liveTasks(conv) ??
        (conv != null && app.remoteRunsIn(conv).isNotEmpty
            ? (steps: const <Map<String, dynamic>>[], team: null, research: false, label: app.remoteRunsIn(conv).first.label)
            : null);
    final waiting = live == null ? Tasks.waiting(app.messages) : 0;
    var badge = '';
    if (live != null) {
      final groups = Tasks.outline(const [], live: live, catalog: app.mentionCatalog);
      final top = groups.first.items.where((x) => x.depth == 0).toList();
      final done = top.where((x) => x.state == 'done' || x.state == 'skipped').length;
      if (top.length > 1) badge = '$done/${top.length}';
    } else if (waiting > 0) {
      badge = '$waiting';
    }
    final still = reducedMotion(context);
    return IconButton(
      key: const ValueKey('tasks-button'),
      tooltip: tasksLabel(live != null, waiting),
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          NymGlyph('tasks', size: 20, color: open ? theme.colorScheme.primary : null),
          if (live != null)
            SizedBox(
              key: const ValueKey('tasks-running'),
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2, value: still ? 1 : null),
            ),
          if (badge.isNotEmpty)
            Positioned(
              top: -6,
              right: -10,
              child: Container(
                key: const ValueKey('tasks-badge'),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: waiting > 0 ? NymbotColors.lightning : theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: waiting > 0 ? NymbotColors.lightning : theme.dividerColor),
                ),
                child: Text(badge,
                    style: TextStyle(
                        fontSize: 9.5,
                        color: waiting > 0 ? Colors.black : theme.textTheme.bodySmall?.color)),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> showTasksSheet(BuildContext context, {required void Function(String id) onJump}) =>
    showNymSheet<void>(
      context,
      (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.92,
        builder: (_, scroll) => TasksPane(
          controller: scroll,
          onClose: () => Navigator.of(sheet).pop(),
          onJump: (id) {
            Navigator.of(sheet).pop();
            onJump(id);
          },
        ),
      ),
    );

class TasksSplit extends StatelessWidget {
  const TasksSplit({
    super.key,
    required this.open,
    required this.child,
    required this.onJump,
    required this.onClose,
  });

  final bool open;
  final Widget child;
  final void Function(String id) onJump;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      if (!open || box.maxWidth < kTasksWide) return child;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: child),
          const VerticalDivider(width: 1),
          SizedBox(
            key: const ValueKey('tasks-side'),
            width: 380,
            child: Material(child: TasksPane(onJump: onJump, onClose: onClose)),
          ),
        ],
      );
    });
  }
}

class TasksPane extends StatefulWidget {
  const TasksPane({super.key, required this.onJump, required this.onClose, this.controller});

  final void Function(String id) onJump;
  final VoidCallback onClose;
  final ScrollController? controller;

  @override
  State<TasksPane> createState() => _TasksPaneState();
}

class _TasksPaneState extends State<TasksPane> {
  static const _gap = Duration(milliseconds: 1500);
  Timer? _speak;
  String _spoken = '';
  DateTime _spokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  AppController? _watching;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_watching == null) {
      _watching = AppScope.read(context);
      _watching!.watchRuns(true);
    }
  }

  @override
  void dispose() {
    _speak?.cancel();
    _watching?.watchRuns(false);
    super.dispose();
  }

  static String _remoteMode(String kind) => switch (kind) {
        'server-run' || 'repo' => 'repo',
        'connector' => 'tool',
        'team' || 'research' => kind,
        _ => 'chat',
      };

  List<TaskGroup> _groups(AppController app) {
    final conv = app.current;
    final out = <TaskGroup>[];
    if (conv != null) {
      for (final run in app.runsIn(conv).reversed) {
        final asked = run.askId == null
            ? null
            : app.messages.where((m) => m.id == run.askId).firstOrNull;
        out.add(Tasks.liveGroup(app.liveTasksOf(run),
            id: run.askId ?? 'live',
            title: asked == null ? run.label : Tasks.clipTitle(asked.content),
            catalog: app.mentionCatalog,
            plan: run.plan,
            run: run.key,
            branches: run.branches));
      }
      for (final r in app.remoteRunsIn(conv)) {
        final asked = app.messages
            .where((m) => m.role == ChatRole.self && m.wire == r.replyTo)
            .firstOrNull;
        out.add(Tasks.liveGroup(
            (steps: const [], team: null, research: false,
                label: r.progress.isNotEmpty
                    ? r.progress
                    : (r.background ? BackgroundJobs.cardLabel() : r.label)),
            id: asked?.id ?? 'live',
            title: r.label,
            plan: r.plan,
            note: r.background ? BackgroundJobs.listMeta() : t('On another device'),
            run: r.replyTo,
            mode: _remoteMode(r.kind),
            branches: r.branches));
      }
    }
    return [...out, ...Tasks.outline(app.messages, catalog: app.mentionCatalog)];
  }

  void _announce(String text) {
    if (text.isEmpty || text == _spoken) return;
    _speak?.cancel();
    final wait = _gap - DateTime.now().difference(_spokenAt);
    void say() {
      if (!mounted) return;
      _spoken = text;
      _spokenAt = DateTime.now();
      unawaited(SemanticsService.sendAnnouncement(
          View.of(context), text, Directionality.of(context)));
    }

    if (wait <= Duration.zero) {
      say();
    } else {
      _speak = Timer(wait, say);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final groups = _groups(app);
    if (groups.isNotEmpty && groups.first.live) {
      final items = groups.first.items;
      final active = items.where((x) => x.state == 'active').toList();
      final now = active.isNotEmpty ? active.last : items.last;
      WidgetsBinding.instance.addPostFrameCallback((_) => _announce(now.label));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(t('Tasks'), style: theme.textTheme.titleMedium),
                ),
              ),
              IconButton(
                key: const ValueKey('tasks-close'),
                icon: const NymGlyph('close', size: 18),
                tooltip: t('Close'),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FocusTraversalGroup(
            child: ListView(
              controller: widget.controller,
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 20),
              children: [
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      t('Nothing here yet. Research, Team mode, repository work, server runs and tool approvals in this chat are listed here, newest first.'),
                      style: TextStyle(color: theme.hintColor, fontSize: 13),
                    ),
                  ),
                for (final g in groups) _group(context, app, g),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _meta(TaskGroup g) {
    if (g.note != null) return '${Tasks.modeLabel(g.mode)} · ${g.note}';
    final state = g.live
        ? t('running')
        : switch (g.state) {
            'waiting' => t('waiting for you'),
            'stopped' => t('stopped'),
            'failed' => t('failed'),
            _ => t('done'),
          };
    return '${Tasks.modeLabel(g.mode)} · $state';
  }

  Widget _group(BuildContext context, AppController app, TaskGroup g) {
    final theme = Theme.of(context);
    final border = g.live
        ? theme.colorScheme.primary.withValues(alpha: 0.5)
        : g.state == 'waiting'
            ? NymbotColors.lightning
            : theme.dividerColor;
    return Container(
      key: ValueKey('tasks-group-${g.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: '${g.title}, ${_meta(g)}',
                  excludeSemantics: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => widget.onJump(g.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(g.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                          Text(_meta(g), style: TextStyle(fontSize: 11, color: theme.hintColor)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (g.live) ...[
                if (_steerable(app, g))
                  TextButton(
                    key: const ValueKey('tasks-steer'),
                    onPressed: () => unawaited(_steer(app, g)),
                    child: Text(t('Add instructions')),
                  ),
                TextButton(
                  key: const ValueKey('tasks-stop'),
                  onPressed: () => _stop(app, g),
                  child: Text(t('Stop')),
                ),
              ],
            ],
          ),
          for (final it in g.items) _item(context, app, g, it),
          if (g.plan.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
              child: RunPlan(plan: g.plan),
            ),
        ],
      ),
    );
  }

  ChatTurn? _local(AppController app, TaskGroup g) =>
      g.run == null ? null : app.turns.values.where((r) => r.key == g.run).firstOrNull;

  bool _steerable(AppController app, TaskGroup g) {
    final local = _local(app, g);
    if (local != null) return local.live || local.phase == 'claiming';
    return g.note != null && g.run != null;
  }

  Future<void> _steer(AppController app, TaskGroup g) async {
    final local = _local(app, g);
    final runId = local?.runId ?? g.run;
    if (runId == null || runId.isEmpty) return;
    await addInstructions(context, runId: runId, conv: local?.conv ?? app.current);
  }

  void _stop(AppController app, TaskGroup g) {
    final local = _local(app, g);
    if (local != null) {
      unawaited(app.stopRun(local));
      return;
    }
    if (g.note != null && g.run != null) {
      final conv = app.current;
      final r = conv == null
          ? null
          : app.remoteRunsIn(conv).where((x) => x.replyTo == g.run).firstOrNull;
      if (r != null) unawaited(app.stopRemote(r));
      return;
    }
    app.stop();
  }

  Widget _mark(BuildContext context, String state) {
    final theme = Theme.of(context);
    switch (state) {
      case 'active':
        return reducedMotion(context)
            ? NymGlyph('dot', size: 12, filled: true, color: theme.colorScheme.primary)
            : const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2));
      case 'done':
        return NymGlyph('check', size: 13, weight: 2.4, color: theme.colorScheme.primary);
      case 'failed':
        return const NymGlyph('close', size: 13, weight: 2.4, color: NymbotColors.danger);
      case 'waiting':
        return const NymGlyph('dot', size: 13, filled: true, color: NymbotColors.lightning);
      case 'stopped':
        return NymGlyph('stop', size: 13, filled: true, color: theme.hintColor);
      default:
        return NymGlyph('circle', size: 13, color: theme.hintColor);
    }
  }

  Widget _favicon(String host) {
    final url = 'https://${NymbotConfig.apiHost}/api/proxy?action=favicon&host=${Uri.encodeComponent(host)}';
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Image(
        image: CachedMediaImage(url),
        width: 12,
        height: 12,
        errorBuilder: (_, _, _) => const SizedBox(width: 12, height: 12),
      ),
    );
  }

  Widget _item(BuildContext context, AppController app, TaskGroup g, TaskItem it) {
    final theme = Theme.of(context);
    final current = it.state == 'active';
    final faint = TextStyle(fontSize: 11, color: theme.hintColor);
    final color = it.state == 'failed'
        ? NymbotColors.danger
        : (it.state == 'pending' || it.state == 'skipped')
            ? theme.hintColor
            : null;
    ChatMessage? message;
    if (it.approval) {
      for (final m in app.messages) {
        if (m.id == g.id) message = m;
      }
    }
    final run = message?.pendingTool?['kind'] == 'server-run';
    return Padding(
      padding: EdgeInsets.only(left: it.depth * 18.0, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            selected: current,
            label: [it.label, Tasks.statusLabel(it.state), if (it.detail.isNotEmpty) it.detail].join(', '),
            excludeSemantics: true,
            child: InkWell(
              key: ValueKey('tasks-item-${it.state}'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => widget.onJump(g.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: current
                    ? BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      )
                    : null,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 2), child: _mark(context, it.state)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(it.label, style: TextStyle(fontSize: 13, color: color)),
                          if (it.detail.isNotEmpty) Text(it.detail, style: faint),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          for (final c in it.children)
            Padding(
              padding: const EdgeInsets.only(left: 27, top: 1),
              child: Row(
                children: [
                  if (it.favicons && Citation.faviconHost(c)) _favicon(c),
                  Expanded(child: Text(c, style: faint)),
                ],
              ),
            ),
          if (it.approval && it.state == 'waiting' && message != null)
            Padding(
              padding: const EdgeInsets.only(left: 27, top: 4, bottom: 2),
              child: Wrap(
                spacing: 6,
                children: [
                  FilledButton(
                    key: const ValueKey('tasks-allow'),
                    onPressed: () => app.allowPendingTool(message!),
                    child: Text(t('Allow once')),
                  ),
                  TextButton(
                    key: const ValueKey('tasks-deny'),
                    onPressed: () => app.denyPendingTool(message!),
                    child: Text(run ? t('Decline') : t('Deny')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
