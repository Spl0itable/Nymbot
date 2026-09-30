import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/git_review.dart';
import 'i18n/i18n.dart';
import 'markdown_body.dart';

class BranchChip extends StatefulWidget {
  const BranchChip({super.key, required this.job, this.onAction});

  final Map<String, dynamic> job;
  final Future<void> Function(Map<String, dynamic> job, String op)? onAction;

  @override
  State<BranchChip> createState() => _BranchChipState();
}

class _BranchChipState extends State<BranchChip> {
  bool _busy = false;

  Future<void> _run(String op) async {
    final act = widget.onAction;
    if (act == null || _busy) return;
    setState(() => _busy = true);
    try {
      await act(widget.job, op);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? get _url {
    final pull = widget.job['pull'];
    final url = pull is Map ? '${pull['url'] ?? ''}' : '';
    return url.startsWith('https://') ? url : null;
  }

  Widget _button(String key, String label, String op, {bool primary = false}) {
    final onPressed = _busy ? null : () => _run(op);
    final child = Text(label, style: const TextStyle(fontSize: 12));
    return primary
        ? FilledButton(key: ValueKey(key), onPressed: onPressed, child: child)
        : OutlinedButton(key: ValueKey(key), onPressed: onPressed, child: child);
  }

  Widget _open(String key, String label) {
    final url = _url;
    if (url == null) return _button(key, label, 'pr');
    return OutlinedButton(
      key: ValueKey(key),
      onPressed: () => MarkdownBody.openLink(context, url, url),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = widget.job;
    final merged = job['merged'] == true;
    final deleted = job['deleted'] == true;
    final conflict = job['conflict'] == true;
    final running = job['done'] == false;
    final buttons = <Widget>[
      if (conflict) ...[
        _open('branch-resolve', t('Open the PR to resolve')),
        _button('branch-update', t('Ask Nymbot to update the branch'), 'update',
            primary: true),
      ] else if (!merged && !running) ...[
        _open('branch-open', t('Open PR')),
        _button('branch-merge', t('Merge'), 'merge',
            primary: job['whenDone'] == 'merge'),
      ] else if (merged && _url != null)
        _open('branch-open', t('Open PR')),
      if (!running) _button('branch-delete', t('Delete'), 'delete'),
    ];
    return Container(
      key: ValueKey('branch-chip-${job['branch']}'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        border: Border.all(
            color: conflict ? NymbotColors.lightning : theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Opacity(
        opacity: merged || deleted ? 0.75 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${job['branch']}${'${job['base'] ?? ''}'.isEmpty ? '' : ' → ${job['base']}'}',
              style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback),
            ),
            const SizedBox(height: 2),
            Text(branchState(job),
                style: TextStyle(fontSize: 11.5, color: theme.hintColor)),
            if (!deleted && buttons.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: buttons),
            ],
          ],
        ),
      ),
    );
  }
}
