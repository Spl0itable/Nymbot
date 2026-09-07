import 'package:flutter/material.dart';

import '../../config.dart';
import '../../models/conversation.dart';
import '../i18n/i18n.dart';
import 'credits_sheet.dart';

/// Everything the device actually knows about one reply's price. Deliberately
/// not an estimate re-run after the fact: what is shown is what the worker
/// charged and what it said it did to earn it.
List<(String, String)> costRows(BuildContext context, ChatMessage m) {
  final pro = m.model != null;
  final sats = m.cost * (NymbotConfig.satsPerCredit[pro ? 'pro' : 'standard'] ?? 1);
  final rows = <(String, String)>[
    (t('Charged'), t('{n} credits', {'n': m.cost})),
    (t('Tier'), pro ? t('Pro') : t('Standard')),
    (t('Model'), m.model ?? t('Auto-routed')),
    (t("At today's price"), t('{n} sats', {'n': sats})),
  ];
  if (m.calls > 1) rows.add((t('Model calls'), '${m.calls}'));
  if (m.task != null) rows.add((t('Routed as'), m.task!));
  if (m.repos.isNotEmpty) {
    rows.add((t('Repositories read'), m.repos.join(', ')));
  }
  if (m.sources.isNotEmpty) {
    rows.add((t('Sources read'), '${m.sources.length}'));
  }
  final at = m.at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  rows.add((t('When'), '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}'));
  return rows;
}

Future<void> showCostSheet(BuildContext context, ChatMessage m) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CostSheet(message: m),
    );

class _CostSheet extends StatelessWidget {
  const _CostSheet({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = costRows(context, message);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('What this reply cost'),
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            for (final row in rows)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: theme.dividerColor)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(row.$1,
                          style: TextStyle(
                              fontSize: 13, color: theme.hintColor)),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        row.$2,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Text(
              message.model != null
                  ? t("A Pro reply costs the model's base and then scales with the "
                      'length of the answer, up to that model\'s cap. The cap is '
                      'held when you send and only the real cost is taken.')
                  : t('A standard reply is one credit, whichever model the router '
                      'picked for it.'),
              style: TextStyle(fontSize: 11.5, color: theme.hintColor),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                showCreditsSheet(context);
              },
              child: Text(t('Buy credits')),
            ),
          ],
        ),
      ),
    );
  }
}
