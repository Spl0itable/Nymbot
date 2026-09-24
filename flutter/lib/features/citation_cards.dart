import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
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

  /// The letter drawn while the favicon loads, and instead of it when the site
  /// has none.
  String get initial {
    final from = host.isEmpty ? title : host;
    return from.isEmpty ? '?' : from.substring(0, 1).toUpperCase();
  }

  String get faviconUrl {
    if (host.isEmpty) return '';
    final target = Uri.encodeComponent(host);
    return 'https://${NymbotConfig.apiHost}/api/proxy?action=favicon&host=$target';
  }
}

class CitationCards extends StatefulWidget {
  const CitationCards(
      {super.key, required this.sources, this.max = 8, this.storageId});

  final List<Map<String, dynamic>> sources;
  final int max;
  final String? storageId;

  static const collapseAbove = 2;

  @override
  State<CitationCards> createState() => _CitationCardsState();
}

class _CitationCardsState extends State<CitationCards> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _open = widget.storageId != null &&
        PageStorage.maybeOf(context)?.readState(context,
                identifier: 'sources:${widget.storageId}') ==
            true;
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (widget.storageId != null) {
      PageStorage.maybeOf(context)?.writeState(context, _open,
          identifier: 'sources:${widget.storageId}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = widget.sources.take(widget.max).map(Citation.fromJson).toList();
    if (cards.isEmpty) return const SizedBox.shrink();
    final label = cards.length == 1
        ? t('1 source')
        : t('{n} sources', {'n': cards.length});

    if (cards.length <= CitationCards.collapseAbove) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 10.5, color: theme.hintColor),
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < cards.length; i++)
              _Card(index: i + 1, citation: cards[i]),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            label: label,
            hint: _open ? t('Hide sources') : t('Show sources'),
            excludeSemantics: true,
            onTap: _toggle,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _toggle,
              child: Container(
                constraints: const BoxConstraints(minHeight: 40),
                padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 10, 4),
                decoration: BoxDecoration(
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Wrap(
                        spacing: 3,
                        runSpacing: 3,
                        children: [
                          for (final c in cards) _Mark(citation: c),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(fontSize: 10.5, color: theme.hintColor),
                    ),
                    Icon(_open ? Icons.expand_less : Icons.expand_more,
                        size: 16, color: theme.hintColor),
                  ],
                ),
              ),
            ),
          ),
          if (_open) ...[
            const SizedBox(height: 4),
            for (var i = 0; i < cards.length; i++)
              _Card(index: i + 1, citation: cards[i]),
          ],
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
            _Mark(citation: citation),
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

class _Mark extends StatelessWidget {
  const _Mark({required this.citation});

  final Citation citation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final letter = Container(
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
    );
    final src = citation.faviconUrl;
    if (src.isEmpty) return letter;
    return SizedBox(
      width: 20,
      height: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Image.network(
          src,
          width: 20,
          height: 20,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => letter,
          frameBuilder: (_, child, frame, wasSync) =>
              frame == null && !wasSync ? letter : child,
        ),
      ),
    );
  }
}
