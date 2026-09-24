import 'package:flutter/material.dart';

import '../core/theme/theme.dart';
import '../services/chat_engine.dart';
import '../services/mentions.dart';
import 'brand_tile.dart';
import 'i18n/i18n.dart';

String mentionPrice(Map<String, dynamic> model, Map<String, dynamic>? pricing) {
  final span = ChatEngine.nominalTurnRange(model, pricing);
  if (span != null) {
    final lo = creditFigure(span.$1);
    final hi = creditFigure(span.$2);
    if (lo == hi) {
      return lo == '1'
          ? t('~{n} credit a reply', {'n': lo})
          : t('~{n} credits a reply', {'n': lo});
    }
    return t('~{low}–{high} credits a reply', {'low': lo, 'high': hi});
  }
  final credits = (model['credits'] as num?)?.toInt() ?? 1;
  final max = (model['max'] as num?)?.toInt() ?? credits;
  final n = max > credits ? '${figure(credits)}–${figure(max)}' : figure(credits);
  return (max <= credits && credits == 1)
      ? t('{n} credit', {'n': n})
      : t('{n} credits', {'n': n});
}

String mentionHint(Map<String, dynamic> model, Map<String, dynamic>? pricing) =>
    t('{name} answers this one from your Pro balance · {price}',
        {'name': model['label'], 'price': mentionPrice(model, pricing)});

class MentionSuggestions extends StatelessWidget {
  const MentionSuggestions({
    super.key,
    required this.query,
    required this.catalog,
    required this.onPick,
  });

  final MentionQuery query;
  final Map<String, dynamic>? catalog;
  final void Function(Map<String, dynamic> model) onPick;

  @override
  Widget build(BuildContext context) {
    final rows = Mentions.suggest(query.query, catalog);
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('mention-suggestions'),
      margin: const EdgeInsets.only(bottom: 6),
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final m = rows[i];
          return InkWell(
            onTap: () => onPick(m),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  BrandTile(slug: (m['authorSlug'] as String?) ?? '', size: 16),
                  const SizedBox(width: 8),
                  Text(
                    '@${m['key']}',
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 13,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      (m['label'] as String?) ?? '',
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: theme.hintColor),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
