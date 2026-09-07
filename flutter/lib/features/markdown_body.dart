import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Reply rendering. A small, explicit subset: headings, code blocks, lists,
/// block quotes, and inline emphasis, code and links.
class MarkdownBody extends StatelessWidget {
  const MarkdownBody(this.source, {super.key});

  final String source;

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    var i = 0;

    void gap() {
      if (blocks.isNotEmpty) blocks.add(const SizedBox(height: 10));
    }

    while (i < lines.length) {
      final line = lines[i];

      final fence = RegExp(r'^\s*```(\w*)\s*$').firstMatch(line);
      if (fence != null) {
        final body = <String>[];
        i++;
        while (i < lines.length && !RegExp(r'^\s*```\s*$').hasMatch(lines[i])) {
          body.add(lines[i++]);
        }
        i++;
        gap();
        blocks.add(_CodeBlock(body.join('\n')));
        continue;
      }

      final heading = RegExp(r'^(#{1,4})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        gap();
        blocks.add(_inline(context, heading.group(2)!,
            style: Theme.of(context).textTheme.titleSmall));
        i++;
        continue;
      }

      if (RegExp(r'^\s*(?:[-*_]\s*){3,}$').hasMatch(line)) {
        gap();
        blocks.add(const Divider());
        i++;
        continue;
      }

      if (RegExp(r'^\s*>\s?').hasMatch(line)) {
        final body = <String>[];
        while (i < lines.length && RegExp(r'^\s*>\s?').hasMatch(lines[i])) {
          body.add(lines[i++].replaceFirst(RegExp(r'^\s*>\s?'), ''));
        }
        gap();
        blocks.add(_Quote(body.join('\n')));
        continue;
      }

      final bullet = RegExp(r'^\s*([-*+]|\d+\.)\s+');
      if (bullet.hasMatch(line)) {
        final items = <String>[];
        final ordered = RegExp(r'^\s*\d+\.\s+').hasMatch(line);
        while (i < lines.length && bullet.hasMatch(lines[i])) {
          items.add(lines[i++].replaceFirst(bullet, ''));
        }
        gap();
        for (var n = 0; n < items.length; n++) {
          blocks.add(Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(ordered ? '${n + 1}.' : '•'),
                ),
                Expanded(child: _inline(context, items[n])),
              ],
            ),
          ));
        }
        continue;
      }

      if (line.trim().isEmpty) {
        i++;
        continue;
      }

      final para = <String>[];
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          !RegExp(r'^\s*```').hasMatch(lines[i]) &&
          !RegExp(r'^#{1,4}\s').hasMatch(lines[i]) &&
          !RegExp(r'^\s*>\s?').hasMatch(lines[i]) &&
          !bullet.hasMatch(lines[i])) {
        para.add(lines[i++]);
      }
      final text = para.join('\n');
      gap();
      // Images and audio arrive as bare URLs the bot uploaded; showing them
      // beats making someone open a link to find out what was generated.
      final bare = text.trim();
      if (RegExp(r'^https?://\S+$').hasMatch(bare) &&
          RegExp(r'\.(png|jpe?g|gif|webp|avif)(\?|$)', caseSensitive: false)
              .hasMatch(bare)) {
        blocks.add(ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(bare, errorBuilder: (c, e, s) => _inline(c, bare)),
        ));
      } else {
        blocks.add(_inline(context, text));
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks);
  }

  Widget _inline(BuildContext context, String text, {TextStyle? style}) {
    final base = style ?? DefaultTextStyle.of(context).style;
    return RichText(text: TextSpan(style: base, children: _spans(context, text, base)));
  }

  static final _token = RegExp(
    r'`([^`\n]+)`'
    r'|\[([^\]\n]+)\]\((https?://[^)\s]+)\)'
    r'|(\*\*)([^*\n]+)\*\*'
    r'|(?<!\*)\*([^*\n]+)\*(?!\*)'
    r'|(https?://[^\s<)]+)',
  );

  List<InlineSpan> _spans(BuildContext context, String text, TextStyle base) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _token.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      if (m.group(1) != null) {
        spans.add(TextSpan(
          text: m.group(1),
          style: base.copyWith(
            fontFamily: 'monospace',
            backgroundColor: theme.dividerColor,
          ),
        ));
      } else if (m.group(2) != null) {
        spans.add(_link(context, m.group(2)!, m.group(3)!, base));
      } else if (m.group(4) != null) {
        spans.add(TextSpan(
            text: m.group(5), style: base.copyWith(fontWeight: FontWeight.bold)));
      } else if (m.group(6) != null) {
        spans.add(TextSpan(
            text: m.group(6), style: base.copyWith(fontStyle: FontStyle.italic)));
      } else if (m.group(7) != null) {
        spans.add(_link(context, m.group(7)!, m.group(7)!, base));
      }
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return spans;
  }

  InlineSpan _link(BuildContext context, String label, String href, TextStyle base) {
    return TextSpan(
      text: label,
      style: base.copyWith(
        color: Theme.of(context).colorScheme.secondary,
        decoration: TextDecoration.underline,
      ),
      recognizer: TapGestureRecognizer()
        ..onTap = () => launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.code);

  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).dividerColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          code,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
        ),
      ),
      child: MarkdownBody(text),
    );
  }
}
