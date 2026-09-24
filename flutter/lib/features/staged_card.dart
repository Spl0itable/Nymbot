import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/git_review.dart';
import 'diff_view.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';

class StagedCard extends StatefulWidget {
  const StagedCard({
    super.key,
    required this.staged,
    this.onApply,
    this.onDiscard,
  });

  final Map<String, dynamic> staged;
  final Future<void> Function()? onApply;
  final Future<void> Function()? onDiscard;

  @override
  State<StagedCard> createState() => _StagedCardState();
}

class _StagedCardState extends State<StagedCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function()? action) async {
    if (action == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final staged = widget.staged;
    final applied = staged['applied'] == true;
    final discarded = staged['discarded'] == true;
    final hint = TextStyle(fontSize: 11, color: theme.hintColor);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: applied || discarded
                    ? theme.dividerColor
                    : NymbotColors.lightning,
                width: 2,
              ),
            ),
          ),
          child: Opacity(
            opacity: discarded ? 0.7 : 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final one in allStaged(staged)) ...[
                  Row(
                    children: [
                      const NymGlyph('branch', size: 13),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          '${one['repo']}${one['branch'] == null ? '' : ' · ${one['branch']}'}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: kMonoFamily,
                              fontFamilyFallback: kMonoFallback,
                              color: theme.hintColor),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(stagedStats(one),
                      style: const TextStyle(fontSize: 12.5)),
                  if ((one['message'] as String? ?? '').isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(one['message'] as String,
                        key: const ValueKey('staged-message'),
                        style: TextStyle(fontSize: 12, color: theme.hintColor)),
                  ],
                  if ((one['diff'] as String? ?? '').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    DiffView(source: one['diff'] as String),
                  ],
                  const SizedBox(height: 6),
                ],
                if (applied)
                  Text(t('Applied as one commit.'), style: hint)
                else if (discarded)
                  Text(t('Discarded. Nothing was committed.'), style: hint)
                else ...[
                  Text(
                      t('Nothing is committed until you apply it. Applying costs nothing.'),
                      style: hint),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilledButton(
                        key: const ValueKey('staged-apply'),
                        onPressed: _busy || widget.onApply == null
                            ? null
                            : () => _run(widget.onApply),
                        child: Text(_busy ? t('Applying…') : t('Apply')),
                      ),
                      OutlinedButton(
                        key: const ValueKey('staged-discard'),
                        onPressed: _busy || widget.onDiscard == null
                            ? null
                            : () => _run(widget.onDiscard),
                        child: Text(t('Discard')),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
