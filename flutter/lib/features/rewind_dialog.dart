import 'package:flutter/material.dart';

import '../services/rewind.dart';
import 'i18n/i18n.dart';

class RewindDialog extends StatefulWidget {
  const RewindDialog({super.key, required this.count, required this.items});

  final int count;
  final List<RewindItem> items;

  static ({String label, String note}) describe(RewindItem i) {
    switch (i.kind) {
      case 'files':
        final where = i.branch.isEmpty ? i.repo : '${i.repo} · ${i.branch}';
        return (
          label: i.paths.length == 1
              ? t('Undo 1 file change in {repo}', {'repo': where})
              : t('Undo {n} file changes in {repo}', {'n': i.paths.length, 'repo': where}),
          note: i.can
              ? i.paths.take(6).join(', ') + (i.paths.length > 6 ? ' …' : '')
              : i.why == 'undone'
                  ? t('Already put back.')
                  : t('No commit was recorded to read the old files back from.'),
        );
      case 'pull':
        return (
          label: t('Close PR #{n} (unmerged) in {repo}', {'n': i.number, 'repo': i.repo}),
          note: !i.can
              ? t('No commit was recorded for it, so it is left alone.')
              : i.isJob
                  ? t('Only if it is still open and ends at the commit Nymbot made.')
                  : t('Only if it is still open on {branch}.', {'branch': i.branch}),
        );
      case 'revert':
        return (
          label: t('Revert merged PR #{n} in {repo} with a new pull request',
              {'n': i.number, 'repo': i.repo}),
          note: i.can
              ? t('Opens a pull request that puts back what it changed on {base}. Nothing is force-pushed.',
                  {'base': i.base})
              : i.why == 'forge'
                  ? t('This forge cannot open a revert from Nymbot. Revert the merge on the forge.')
                  : t('No commit was recorded for it, so it is left alone.'),
        );
      case 'branch':
        return (
          label: t('Delete branch {branch} in {repo}', {'branch': i.branch, 'repo': i.repo}),
          note: i.can
              ? t('Only if it still ends at the commit Nymbot made.')
              : t('No commit was recorded for it, so it is left alone.'),
        );
      case 'connector':
        final args = i.args.length > 120 ? i.args.substring(0, 120) : i.args;
        return (
          label: t('{connector}: {tool}', {'connector': i.connector, 'tool': i.tool}),
          note: t('Can\'t be undone from Nymbot') + (args.isEmpty ? '' : ' · $args'),
        );
      default:
        return (
          label: i.count == 1 ? t('1 server run') : t('{n} server runs', {'n': i.count}),
          note: t('Sandboxed on the server, so there is nothing to undo.'),
        );
    }
  }

  @override
  State<RewindDialog> createState() => _RewindDialogState();
}

class _RewindDialogState extends State<RewindDialog> {
  late final Set<String> _picked = Rewind.picks(widget.items);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = TextStyle(fontSize: 12, color: theme.hintColor);
    final lead = widget.count == 1
        ? t('This removes the 1 message after this one.')
        : t('This removes the {n} messages after this one.', {'n': widget.count});
    final more = widget.items.isEmpty
        ? t('They changed nothing outside the chat.')
        : t('They did these things outside the chat. Tick what to undo as well.');
    return AlertDialog(
      title: Text(t('Rewind to here')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$lead $more'),
            const SizedBox(height: 8),
            for (final i in widget.items)
              Builder(builder: (context) {
                final d = RewindDialog.describe(i);
                final body = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.label, style: const TextStyle(fontSize: 13)),
                    Text(d.note, style: hint),
                  ],
                );
                if (!i.can) {
                  return Padding(
                    key: ValueKey('rewind-${i.id}'),
                    padding: const EdgeInsets.fromLTRB(48, 6, 0, 6),
                    child: body,
                  );
                }
                return CheckboxListTile(
                  key: ValueKey('rewind-${i.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _picked.contains(i.id),
                  title: body,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _picked.add(i.id);
                    } else {
                      _picked.remove(i.id);
                    }
                  }),
                );
              }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Cancel')),
        ),
        FilledButton(
          key: const ValueKey('rewind-confirm'),
          style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
          onPressed: () => Navigator.of(context).pop(<String>{..._picked}),
          child: Text(t('Rewind')),
        ),
      ],
    );
  }
}
