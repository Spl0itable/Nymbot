import 'package:flutter/material.dart';

import '../services/doc_library.dart';
import '../services/doc_search.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';

class DocTray extends StatelessWidget {
  const DocTray({super.key, required this.convId});

  final String? convId;

  @override
  Widget build(BuildContext context) {
    final id = convId;
    if (id == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: DocLibrary.instance,
      builder: (context, _) {
        final docs = DocLibrary.instance.searchable(id);
        if (docs.isEmpty) return const SizedBox.shrink();
        final hint = TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor);
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(t('Searched in this chat:'), style: hint),
              for (final d in docs)
                InputChip(
                  avatar: const NymGlyph('search', size: 15),
                  label: Text(
                    '${d.name} · ${d.paged ? t('{n} pages', {'n': d.pages}) : t('{n} parts', {'n': d.pages})}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  deleteButtonTooltipMessage: t('Remove from this chat'),
                  onDeleted: () => DocLibrary.instance.remove(id, d.id),
                ),
            ],
          ),
        );
      },
    );
  }
}

class DocUsageLine extends StatelessWidget {
  const DocUsageLine({super.key, required this.messageId});

  final String messageId;

  static String describe(DocUsage u) {
    final pages = u.used.join(', ');
    return u.paged
        ? t('Searched {name}, not read whole — used pages {pages} of {total}',
            {'name': u.name, 'pages': pages, 'total': u.total})
        : t('Searched {name}, not read whole — used parts {pages} of {total}',
            {'name': u.name, 'pages': pages, 'total': u.total});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: DocLibrary.instance,
        builder: (context, _) {
          final used = DocLibrary.instance.usageOf(messageId);
          if (used.isEmpty) return const SizedBox.shrink();
          final hint = TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor);
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final u in used) Text(describe(u), style: hint)],
            ),
          );
        },
      );
}
