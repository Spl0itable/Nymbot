import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'i18n/i18n.dart';

/// One thing a reply says it read. A chip only ever showed a title; a card
/// shows where it came from and what it said, which is what makes a citation
/// checkable rather than decorative.
class Citation {
  const Citation({
    required this.title,
    this.url = '',
    this.snippet = '',
  });

  final String title;
  final String url;
  final String snippet;

  static Citation fromJson(Map<String, dynamic> j) {
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = j[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return '';
    }

    final url = pick(['url', 'link', 'href']);
    return Citation(
      title: pick(['title', 'name', 'heading']).isEmpty
          ? (url.isEmpty ? t('source') : hostOf(url))
          : pick(['title', 'name', 'heading']),
      url: url,
      snippet: pick(['snippet', 'description', 'excerpt', 'text']),
    );
  }

  /// The bare host, which is the part of a URL a reader actually judges.
  static String hostOf(String url) {
    final parsed = Uri.tryParse(url);
    final host = parsed?.host ?? '';
    if (host.isEmpty) return url;
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  String get host => url.isEmpty ? '' : hostOf(url);

  /// The letter drawn in place of a favicon: no request is made for one, so a
  /// citation card cannot become a tracking pixel.
  String get initial {
    final from = host.isEmpty ? title : host;
    return from.isEmpty ? '?' : from.substring(0, 1).toUpperCase();
  }
}

class CitationCards extends StatelessWidget {
  const CitationCards({super.key, required this.sources, this.max = 8});

  final List<Map<String, dynamic>> sources;
  final int max;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = sources.take(max).map(Citation.fromJson).toList();
    if (cards.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cards.length == 1
                ? t('1 source')
                : t('{n} sources', {'n': cards.length}),
            style: TextStyle(fontSize: 10.5, color: theme.hintColor),
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < cards.length; i++)
            _Card(index: i + 1, citation: cards[i]),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.index, required this.citation});

  final int index;
  final Citation citation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final open = citation.url.isEmpty
        ? null
        : () => launchUrl(Uri.parse(citation.url),
            mode: LaunchMode.externalApplication);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: open,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(citation.initial,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  )),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$index. ${citation.title}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  if (citation.host.isNotEmpty)
                    Text(citation.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5, color: theme.hintColor)),
                  if (citation.snippet.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        citation.snippet,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: theme.hintColor),
                      ),
                    ),
                ],
              ),
            ),
            if (open != null)
              Icon(Icons.open_in_new, size: 13, color: theme.hintColor),
          ],
        ),
      ),
    );
  }
}
