import 'package:flutter/material.dart';

import '../app.dart';
import '../core/theme/theme.dart';
import '../services/server_runs.dart';
import 'i18n/i18n.dart';

class PendingToolCard extends StatefulWidget {
  const PendingToolCard({
    super.key,
    required this.pending,
    this.onAllow,
    this.onDeny,
    this.onAlwaysAllow,
  });

  static const previewChars = 2000;

  final Map<String, dynamic> pending;
  final VoidCallback? onAllow;
  final VoidCallback? onDeny;
  final VoidCallback? onAlwaysAllow;

  @override
  State<PendingToolCard> createState() => _PendingToolCardState();
}

class _PendingToolCardState extends State<PendingToolCard> {
  bool _all = false;

  Widget _frame(BuildContext context, bool settled, List<Widget> children) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: settled ? theme.dividerColor : theme.colorScheme.primary,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Opacity(
        opacity: settled ? 0.75 : 1,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }

  Widget? _staged(BuildContext context, Object? raw) {
    if (raw is! Map || raw['files'] is! List) return null;
    final files = [
      for (final f in raw['files'] as List)
        if (f is Map && '${f['path'] ?? ''}'.isNotEmpty) f,
    ];
    if (files.isEmpty) return null;
    final theme = Theme.of(context);
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    const mono = TextStyle(fontSize: 11, fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback);
    final branch = '${raw['branch'] ?? ''}';
    final shown = files.take(ServerRuns.stagedShown).toList();
    final more = ((raw['more'] as num?)?.toInt() ?? 0) + files.length - shown.length;
    String diff(Map f) {
      if (f['deleted'] == true) return t('deleted');
      final added = (f['added'] as num?)?.toInt() ?? 0;
      final removed = (f['removed'] as num?)?.toInt() ?? 0;
      return [if (added > 0) '+$added', if (removed > 0) '\u2212$removed'].join(' ');
    }

    return Column(
      key: const ValueKey('server-run-staged'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        Text(
          branch.isNotEmpty ? t('Staged changes on {branch}:', {'branch': branch}) : t('Staged changes:'),
          style: hint,
        ),
        for (final f in shown)
          Text.rich(
            TextSpan(children: [
              TextSpan(text: '${f['path']}'),
              if (diff(f).isNotEmpty) TextSpan(text: '  ${diff(f)}', style: TextStyle(color: theme.hintColor)),
            ]),
            style: mono,
          ),
        if (more > 0) Text(t('+{n} more', {'n': more}), style: hint),
        if (raw['unreviewed'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              t("You haven't reviewed these staged changes. If you allow this run, they go to the server with it."),
              key: const ValueKey('server-run-staged-warn'),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _serverRun(BuildContext context) {
    final theme = Theme.of(context);
    final pending = widget.pending;
    final state = pending['state'] as String? ?? 'waiting';
    final image = '${pending['image'] ?? ''}';
    final scope = context.getElementForInheritedWidgetOfExactType<AppScope>();
    final label = scope == null ? image : AppScope.read(context).runnerLabel(image);
    final timeout = (pending['timeoutSec'] as num?)?.toInt() ?? 0;
    final credits = (pending['maxCredits'] as num?)?.toDouble() ?? 0;
    final repo = '${pending['repo'] ?? ''}';
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    final staged = _staged(context, pending['staged']);
    return _frame(context, state != 'waiting', [
      Text(
        pending['team'] == true
            ? t('The team lead wants to run a command on a Nymbot server')
            : t('Nymbot wants to run a command on a Nymbot server'),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      if (repo.isNotEmpty) Text(t('Repository: {repo}', {'repo': repo}), style: hint),
      Text(t('Image: {image}', {'image': label}), style: hint),
      const SizedBox(height: 4),
      Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 200),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              '${pending['command'] ?? ''}',
              key: const ValueKey('server-run-command'),
              style: const TextStyle(
                  fontSize: 12, fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback),
            ),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(t('Time limit: {time}', {'time': ServerRuns.minutes(timeout)}), style: hint),
      Text(
        t('Up to {credits} Pro credits', {'credits': ServerRuns.credits(credits)}),
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      if (staged != null) staged,
      const SizedBox(height: 6),
      if (state == 'allowed')
        Text(t('Allowed once.'), style: hint)
      else if (state == 'denied')
        Text(t('Declined. Nothing was run.'), style: hint)
      else
        Wrap(
          spacing: 8,
          children: [
            FilledButton(onPressed: widget.onAllow, child: Text(t('Allow once'))),
            OutlinedButton(onPressed: widget.onDeny, child: Text(t('Decline'))),
          ],
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pending['kind'] == 'server-run') return _serverRun(context);
    final theme = Theme.of(context);
    final pending = widget.pending;
    final args = '${pending['args'] ?? '{}'}';
    final long = args.length > PendingToolCard.previewChars;
    final shown = long && !_all ? args.substring(0, PendingToolCard.previewChars) : args;
    final given = pending['argsLength'];
    final total = given is num && given > args.length ? given.toInt() : args.length;
    final hidden = total - shown.length;
    final state = pending['state'] as String? ?? 'waiting';
    final settled = state != 'waiting';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: settled ? theme.dividerColor : theme.colorScheme.primary,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Opacity(
        opacity: settled ? 0.75 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pending['team'] == true
                  ? t('The team lead wants to run {tool} on {connector}',
                      {'tool': '${pending['tool']}', 'connector': '${pending['connector']}'})
                  : t('Nymbot wants to run {tool} on {connector}',
                      {'tool': '${pending['tool']}', 'connector': '${pending['connector']}'}),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: _all ? 360 : 160),
              child: SingleChildScrollView(
                child: SelectableText(
                  shown,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      color: theme.hintColor),
                ),
              ),
            ),
            if (long || hidden > 0)
              Row(
                children: [
                  if (hidden > 0)
                    Expanded(
                      child: Text(
                        t('… {n} more characters', {'n': hidden}),
                        style: TextStyle(fontSize: 12, color: theme.hintColor),
                      ),
                    )
                  else
                    const Spacer(),
                  if (long)
                    TextButton(
                      onPressed: () => setState(() => _all = !_all),
                      child: Text(_all ? t('Show less') : t('Show all')),
                    ),
                ],
              ),
            if (pending['destructive'] == true) ...[
              const SizedBox(height: 4),
              Text(
                t('The connector marks this tool as able to change or delete things.'),
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 6),
            if (state == 'allowed')
              Text(t('Allowed once.'), style: TextStyle(fontSize: 12, color: theme.hintColor))
            else if (state == 'denied')
              Text(t('Denied. Nothing was run.'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor))
            else
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: widget.onAllow,
                    child: Text(t('Allow once')),
                  ),
                  if (widget.onAlwaysAllow != null && pending['destructive'] != true && pending['team'] != true)
                    OutlinedButton(
                      onPressed: widget.onAlwaysAllow,
                      child: Text(t('Always allow this tool')),
                    ),
                  OutlinedButton(
                    onPressed: widget.onDeny,
                    child: Text(t('Deny')),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
