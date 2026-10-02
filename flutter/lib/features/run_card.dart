import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import '../models/conversation.dart';
import '../services/background_jobs.dart';
import '../services/git_review.dart';
import '../state/app_controller.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';
import 'sheets/sheet.dart';

void _toast(BuildContext context, String text) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..clearSnackBars()
    ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}

Future<void> addInstructions(BuildContext context,
    {required String runId, Conversation? conv}) async {
  final app = AppScope.read(context);
  final text = await showNymDialog<String>(
    context: context,
    builder: (dialog) => const _SteerDialog(),
  );
  final body = text?.trim() ?? '';
  if (body.isEmpty || !context.mounted) return;
  final outcome = await app.steer(runId, body, conv: conv);
  if (!context.mounted) return;
  switch (outcome) {
    case 'ok':
      _toast(context, t('Passed on. It applies at the next step.'));
    case 'long':
      _toast(context, t('That is too long. Instructions can be up to 2,000 characters.'));
    case 'failed':
      _toast(context, t('Could not pass that on. Try again in a moment.'));
    default:
      final again = await offerAsMessage(context,
          late: outcome == 'final');
      if (again == true) {
        await app.send(body, target: conv ?? app.current, withAttachments: const []);
      }
  }
}

class _SteerDialog extends StatefulWidget {
  const _SteerDialog();

  @override
  State<_SteerDialog> createState() => _SteerDialogState();
}

class _SteerDialogState extends State<_SteerDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(t('Add instructions')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('Nymbot passes this to the running request at its next step. It does not change what the request can spend.'),
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('steer-text'),
              controller: _field,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              decoration: InputDecoration(
                  hintText: t('For example: also cover the pricing')),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(context, _field.text),
            child: Text(t('Send to this request')),
          ),
        ],
      );
}

Future<bool?> offerAsMessage(BuildContext context, {bool late = false}) =>
    showNymDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(late
            ? t('That request is already writing its answer')
            : t('That request has finished')),
        content: Text(t('Send your instructions as a new message instead?')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(t('Cancel'))),
          FilledButton(
            key: const ValueKey('steer-send-as-message'),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(t('Send as a message')),
          ),
        ],
      ),
    );

class RunPlan extends StatelessWidget {
  const RunPlan({super.key, required this.plan});

  final List<Map<String, dynamic>> plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t('Plan'),
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: theme.hintColor)),
        for (final item in plan)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 6),
                  child: switch ('${item['state']}') {
                    'done' => NymGlyph('check',
                        size: 12, weight: 2.4, color: theme.colorScheme.primary),
                    'doing' => NymGlyph('dot',
                        size: 12, filled: true, color: theme.colorScheme.primary),
                    'skipped' =>
                      NymGlyph('close', size: 12, color: theme.hintColor),
                    _ => NymGlyph('circle', size: 12, color: theme.hintColor),
                  },
                ),
                Expanded(
                  child: Text(
                    '${item['text']}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: item['state'] == 'skipped' ? theme.hintColor : null,
                      decoration: item['state'] == 'skipped'
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class RunBranches extends StatelessWidget {
  const RunBranches({super.key, required this.branches});

  final List<Map<String, dynamic>> branches;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in branchStepsOf(branches))
          Text(t('Working on branch {branch}', {'branch': '${b['branch']}'}),
              style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                  color: theme.hintColor)),
      ],
    );
  }
}

class RunControls extends StatelessWidget {
  const RunControls({super.key, required this.run});

  final ChatTurn run;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final state = switch (run.phase) {
      'slot' => t('Waiting for a free slot'),
      'offline' => t('Waiting for connection'),
      'claiming' => t('Still working on that one…'),
      _ => null,
    };
    final progress = run.progress ?? '';
    return Padding(
      key: ValueKey('run-${run.key}'),
      padding: const EdgeInsets.fromLTRB(44, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state != null && state != run.status)
            Text(state, style: TextStyle(fontSize: 12, color: theme.hintColor)),
          if (progress.isNotEmpty)
            Text(progress,
                style: TextStyle(fontSize: 12, color: theme.hintColor)),
          if (run.branches.isNotEmpty) RunBranches(branches: run.branches),
          if (run.plan.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: RunPlan(plan: run.plan),
            ),
          Wrap(
            spacing: 4,
            children: [
              if (run.live || run.phase == 'claiming')
                TextButton.icon(
                  key: const ValueKey('run-steer'),
                  onPressed: () => unawaited(
                      addInstructions(context, runId: run.runId, conv: run.conv)),
                  icon: const NymGlyph('pencil', size: 14),
                  label: Text(t('Add instructions')),
                ),
              TextButton.icon(
                key: const ValueKey('run-stop'),
                onPressed: () => unawaited(app.stopRun(run)),
                style: TextButton.styleFrom(foregroundColor: NymbotColors.danger),
                icon: const NymGlyph('stop', size: 14, filled: true),
                label: Text(t('Stop')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class RunCapActions extends StatelessWidget {
  const RunCapActions({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final cap = message.runCap ?? const <String, dynamic>{};
    final choices = AppController.runCapChoices(cap);
    if (choices.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          if (choices.contains('start'))
            FilledButton(
              key: const ValueKey('runcap-start'),
              onPressed: () => unawaited(app.startAnyway(message)),
              child: Text(t('Start anyway')),
            ),
          if (choices.contains('always'))
            OutlinedButton(
              key: const ValueKey('runcap-always'),
              onPressed: () => unawaited(app.alwaysAllowRuns(message)),
              child: Text(t('Always allow up to {n}',
                  {'n': AppController.runCapAllow(cap)})),
            ),
          if (choices.contains('wait'))
            TextButton(
              key: const ValueKey('runcap-wait'),
              onPressed: () => unawaited(app.waitForSlot(message)),
              child: Text(t('Wait')),
            ),
        ],
      ),
    );
  }
}

class SteerOfferActions extends StatelessWidget {
  const SteerOfferActions({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          OutlinedButton(
            key: const ValueKey('steer-offer-send'),
            onPressed: () => unawaited(app.sendSteerOffer(message)),
            child: Text(t('Send as a message')),
          ),
        ],
      ),
    );
  }
}

class PendingActions extends StatelessWidget {
  const PendingActions({super.key, required this.message, required this.onEdit});

  final ChatMessage message;
  final void Function(String text) onEdit;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Text(t('Waiting for connection'),
              style: TextStyle(fontSize: 11.5, color: theme.hintColor)),
          TextButton(
            key: ValueKey('pending-edit-${message.id}'),
            onPressed: () async {
              final text = await app.editPending(message);
              if (text != null) onEdit(text);
            },
            child: Text(t('Edit')),
          ),
          TextButton(
            key: ValueKey('pending-delete-${message.id}'),
            onPressed: () async {
              final ok = await showNymDialog<bool>(
                context: context,
                builder: (dialog) => AlertDialog(
                  title: Text(t('Delete this message?')),
                  content: Text(t('It has not been sent yet.')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialog, false),
                        child: Text(t('Cancel'))),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      child: Text(t('Delete')),
                    ),
                  ],
                ),
              );
              if (ok == true) await app.deletePending(message);
            },
            child: Text(t('Delete')),
          ),
        ],
      ),
    );
  }
}

String _age(int startedAt) {
  if (startedAt <= 0) return '';
  final mins = DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(startedAt))
      .inMinutes;
  if (mins < 1) return t('just now');
  if (mins < 60) return t('{n} min', {'n': mins});
  return t('{n} h', {'n': mins ~/ 60});
}

Future<void> showRunningNow(BuildContext context) async {
  final app = AppScope.read(context);
  app.watchRuns(true);
  try {
    await showNymSheet<void>(context, (sheet) => const _RunningNow());
  } finally {
    app.watchRuns(false);
  }
}

class _RunningNow extends StatelessWidget {
  const _RunningNow();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final local = [...app.turns.values]..sort((a, b) => b.began.compareTo(a.began));
    final remote = app.otherRuns;
    Widget row({
      required String key,
      required String chat,
      required String label,
      required String progress,
      required String age,
      List<Map<String, dynamic>> branches = const [],
      required VoidCallback? onOpen,
      required VoidCallback? onSteer,
      required VoidCallback onStop,
    }) =>
        Container(
          key: ValueKey('running-$key'),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(chat,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
              if (label.isNotEmpty)
                Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              if (progress.isNotEmpty || age.isNotEmpty)
                Text([progress, age].where((x) => x.isNotEmpty).join(' · '),
                    style: TextStyle(fontSize: 11.5, color: theme.hintColor)),
              if (branches.isNotEmpty) RunBranches(branches: branches),
              Wrap(
                spacing: 4,
                children: [
                  if (onOpen != null)
                    TextButton(onPressed: onOpen, child: Text(t('Open'))),
                  if (onSteer != null)
                    TextButton(onPressed: onSteer, child: Text(t('Add instructions'))),
                  TextButton(
                    onPressed: onStop,
                    style: TextButton.styleFrom(foregroundColor: NymbotColors.danger),
                    child: Text(t('Stop')),
                  ),
                ],
              ),
            ],
          ),
        );
    String title(Conversation? c) => c == null
        ? t('Unknown chat')
        : (c.title.isEmpty ? t('New chat') : c.title);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            Semantics(
              header: true,
              child: Text(t('Running now'), style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 10),
            if (local.isEmpty && remote.isEmpty)
              Text(t('Nothing is running right now.'),
                  style: TextStyle(color: theme.hintColor, fontSize: 13)),
            for (final run in local)
              row(
                key: run.key,
                chat: title(run.conv),
                label: run.label,
                progress: run.status ?? run.progress ?? '',
                age: _age(run.began.millisecondsSinceEpoch),
                branches: run.branches,
                onOpen: () {
                  Navigator.of(context).pop();
                  unawaited(app.open(run.conv));
                },
                onSteer: run.live
                    ? () => unawaited(addInstructions(context, runId: run.runId, conv: run.conv))
                    : null,
                onStop: () => unawaited(app.stopRun(run)),
              ),
            for (final run in remote)
              row(
                key: run.replyTo,
                chat: title(app.chatOfThread(run.thread)),
                label: run.background
                    ? '${BackgroundJobs.cardLabel()}: ${run.label}'
                    : run.label,
                progress: run.background && run.progress.isEmpty
                    ? BackgroundJobs.cardStatus()
                    : run.progress,
                age: run.background
                    ? '${BackgroundJobs.listMeta()} · ${_age(run.startedAt)}'
                    : _age(run.startedAt),
                branches: run.branches,
                onOpen: app.chatOfThread(run.thread) == null
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        unawaited(app.open(app.chatOfThread(run.thread)!));
                      },
                onSteer: () => unawaited(addInstructions(context,
                    runId: run.replyTo, conv: app.chatOfThread(run.thread))),
                onStop: () => unawaited(app.stopRemote(run)),
              ),
          ],
        ),
      ),
    );
  }
}

class RunSettings extends StatelessWidget {
  const RunSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.settings;
    final hint = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          key: const ValueKey('max-runs'),
          value: app.runLimit,
          isExpanded: true,
          decoration: InputDecoration(labelText: t('Requests at once')),
          items: [
            for (var n = 1; n <= 10; n++)
              DropdownMenuItem(value: n, child: Text('$n')),
          ],
          onChanged: (v) => app.setMaxRuns(v ?? 3),
        ),
        const SizedBox(height: 4),
        Text(
            t('How many requests can run at the same time across your chats. Each running request holds its credits until it finishes.'),
            style: hint),
        const SizedBox(height: 16),
        Text(t('Standing permissions'),
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: const ValueKey('policy-read-only'),
          value: s.readOnlyTools,
          isExpanded: true,
          decoration: InputDecoration(labelText: t('Read-only tool calls')),
          items: [
            DropdownMenuItem(value: 'ask', child: Text(t('Ask me first'))),
            DropdownMenuItem(value: 'allow', child: Text(t('Always allow'))),
          ],
          onChanged: (v) => app.setPolicy(readOnlyTools: v),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('policy-server-runs'),
          value: s.serverRunPolicy,
          isExpanded: true,
          decoration: InputDecoration(labelText: t('Server runs')),
          items: [
            DropdownMenuItem(value: 'ask', child: Text(t('Ask me first'))),
            DropdownMenuItem(
                value: 'allow',
                child: Text(t('Allow when they fit the reply\'s budget'))),
          ],
          onChanged: (v) => app.setPolicy(serverRuns: v),
        ),
        const SizedBox(height: 4),
        Text(t('Anything that deletes, pushes or could cost more than the reply holds always asks.'),
            style: hint),
      ],
    );
  }
}

Future<void> showChatPermissions(BuildContext context, Conversation conv) =>
    showNymSheet<void>(context, (sheet) {
      final app = AppScope.of(sheet);
      final own = conv.policy ?? const <String, String>{};
      final hint = TextStyle(fontSize: 11, color: Theme.of(sheet).hintColor);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t('Standing permissions'),
                  style: Theme.of(sheet).textTheme.titleMedium),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const ValueKey('chat-policy-read-only'),
                value: own['readOnlyTools'] ?? 'default',
                isExpanded: true,
                decoration: InputDecoration(labelText: t('Read-only tool calls')),
                items: [
                  DropdownMenuItem(value: 'default', child: Text(t('Use my default'))),
                  DropdownMenuItem(value: 'ask', child: Text(t('Ask me first'))),
                  DropdownMenuItem(value: 'allow', child: Text(t('Always allow'))),
                ],
                onChanged: (v) => app.setChatPolicy(conv, readOnlyTools: v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('chat-policy-server-runs'),
                value: own['serverRuns'] ?? 'default',
                isExpanded: true,
                decoration: InputDecoration(labelText: t('Server runs')),
                items: [
                  DropdownMenuItem(value: 'default', child: Text(t('Use my default'))),
                  DropdownMenuItem(value: 'ask', child: Text(t('Ask me first'))),
                  DropdownMenuItem(
                      value: 'allow',
                      child: Text(t('Allow when they fit the reply\'s budget'))),
                ],
                onChanged: (v) => app.setChatPolicy(conv, serverRuns: v),
              ),
              const SizedBox(height: 4),
              Text(t('Anything that deletes, pushes or could cost more than the reply holds always asks.'),
                  style: hint),
            ],
          ),
        ),
      );
    });
