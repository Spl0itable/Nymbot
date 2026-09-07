import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'code_highlight.dart';
import 'diff_view.dart';
import 'i18n/i18n.dart';

class MarkdownBody extends StatelessWidget {
  const MarkdownBody(
    this.source, {
    super.key,
    this.wrapCode = false,
    this.monospace = false,
  });

  final String source;
  final bool wrapCode;
  final bool monospace;

  static final _bullet = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+');
  static final _fence = RegExp(r'^\s*(?:```|~~~)([\w+#.-]*)\s*$');
  static final _fenceEnd = RegExp(r'^\s*(?:```|~~~)\s*$');
  static final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _rule = RegExp(r'^\s*(?:[-*_]\s*){3,}$');
  static final _quote = RegExp(r'^\s*>\s?');
  static final _callout = RegExp(r'^\s*>\s*\[!(\w+)\]\s*(.*)$');
  static final _divider = RegExp(r'^\s*\|?[\s:-]*-[\s|:-]*\|?\s*$');
  static final _imageUrl =
      RegExp(r'\.(png|jpe?g|gif|webp|avif|bmp)(\?|$)', caseSensitive: false);
  static final _bareUrl = RegExp(r'^https?://\S+$');

  static String plain(String source) => source
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'[#*_>|~]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

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

      final fence = _fence.firstMatch(line);
      if (fence != null) {
        final lang = fence.group(1) ?? '';
        final body = <String>[];
        i++;
        while (i < lines.length && !_fenceEnd.hasMatch(lines[i])) {
          body.add(lines[i++]);
        }
        i++;
        gap();
        // A patch is read as a patch: per file, with what it costs on the
        // header rather than counted off the `+` lines by eye.
        if (lang == 'diff' || lang == 'patch') {
          blocks.add(DiffView(source: body.join('\n')));
        } else {
          blocks.add(CodeBlock(code: body.join('\n'), language: lang, wrap: wrapCode));
        }
        continue;
      }

      if (line.trimLeft().startsWith('|') &&
          i + 1 < lines.length &&
          _divider.hasMatch(lines[i + 1]) &&
          lines[i + 1].contains('-')) {
        final head = _row(line);
        final align = _row(lines[i + 1]).map(_alignOf).toList();
        final rows = <List<String>>[];
        i += 2;
        while (i < lines.length &&
            lines[i].contains('|') &&
            lines[i].trim().isNotEmpty) {
          rows.add(_row(lines[i++]));
        }
        gap();
        blocks.add(_Table(head: head, rows: rows, align: align, parent: this));
        continue;
      }

      final heading = _heading.firstMatch(line);
      if (heading != null) {
        gap();
        final level = heading.group(1)!.length;
        blocks.add(_inline(
          context,
          heading.group(2)!,
          style: (level <= 2
                  ? Theme.of(context).textTheme.titleMedium
                  : Theme.of(context).textTheme.titleSmall)
              ?.copyWith(fontWeight: FontWeight.w700),
        ));
        i++;
        continue;
      }

      if (_rule.hasMatch(line)) {
        gap();
        blocks.add(const Divider());
        i++;
        continue;
      }

      final callout = _callout.firstMatch(line);
      if (callout != null) {
        final kind = callout.group(1)!.toLowerCase();
        final body = <String>[];
        final first = callout.group(2) ?? '';
        if (first.isNotEmpty) body.add(first);
        i++;
        while (i < lines.length && _quote.hasMatch(lines[i])) {
          body.add(lines[i++].replaceFirst(_quote, ''));
        }
        gap();
        blocks.add(_Callout(kind: kind, body: body.join('\n'), parent: this));
        continue;
      }

      if (_quote.hasMatch(line)) {
        final body = <String>[];
        while (i < lines.length && _quote.hasMatch(lines[i])) {
          body.add(lines[i++].replaceFirst(_quote, ''));
        }
        gap();
        blocks.add(_Quote(body.join('\n'), parent: this));
        continue;
      }

      if (_bullet.hasMatch(line)) {
        final start = i;
        final items = <_ListItem>[];
        final baseIndent = RegExp(r'^\s*').firstMatch(line)!.group(0)!.length;
        while (i < lines.length) {
          final m = _bullet.firstMatch(lines[i]);
          if (m == null) break;
          final indent = m.group(1)!.length;
          if (indent < baseIndent) break;
          final ordered = RegExp(r'^\d').hasMatch(m.group(2)!);
          items.add(_ListItem(
            text: lines[i].substring(m.group(0)!.length),
            ordered: ordered,
            depth: ((indent - baseIndent) / 2).floor(),
          ));
          i++;
        }
        if (i == start) {
          i++;
          continue;
        }
        gap();
        var counter = 0;
        for (final item in items) {
          if (item.ordered && item.depth == 0) counter++;
          blocks.add(_Bullet(item: item, index: counter, parent: this));
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
          !_fence.hasMatch(lines[i]) &&
          !_heading.hasMatch(lines[i]) &&
          !_quote.hasMatch(lines[i]) &&
          !_bullet.hasMatch(lines[i])) {
        para.add(lines[i++]);
      }
      final text = para.join('\n');
      gap();
      // Images and audio arrive as bare URLs the bot uploaded; showing them
      // beats making someone open a link to find out what was generated.
      final bare = text.trim();
      if (_bareUrl.hasMatch(bare) && _imageUrl.hasMatch(bare)) {
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

  static List<String> _row(String line) => line
      .replaceFirst(RegExp(r'^\s*\|'), '')
      .replaceFirst(RegExp(r'\|\s*$'), '')
      .split('|')
      .map((c) => c.trim())
      .toList();

  static TextAlign _alignOf(String cell) {
    if (cell.startsWith(':') && cell.endsWith(':')) return TextAlign.center;
    if (cell.endsWith(':')) return TextAlign.right;
    return TextAlign.left;
  }

  Widget _inline(BuildContext context, String text, {TextStyle? style}) {
    var base = style ?? DefaultTextStyle.of(context).style;
    if (monospace && style == null) {
      base = base.copyWith(fontFamily: 'monospace', fontSize: (base.fontSize ?? 14) - 1);
    }
    return RichText(
      text: TextSpan(style: base, children: _spans(context, text, base)),
    );
  }

  static final _token = RegExp(
    r'`([^`\n]+)`'
    r'|!\[([^\]\n]*)\]\((https?://[^)\s]+)\)'
    r'|\[([^\]\n]+)\]\((https?://[^)\s]+)\)'
    r'|(\*\*\*)([^*\n]+)\*\*\*'
    r'|(\*\*)([^*\n]+)\*\*'
    r'|(?<!\*)\*([^*\n]+)\*(?!\*)'
    r'|~~([^~\n]+)~~'
    r'|==([^=\n]+)=='
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
      } else if (m.group(2) != null || m.group(3) != null) {
        spans.add(WidgetSpan(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(m.group(3)!,
                  errorBuilder: (c, e, s) => Text(m.group(2) ?? '')),
            ),
          ),
        ));
      } else if (m.group(4) != null) {
        spans.add(_link(context, m.group(4)!, m.group(5)!, base));
      } else if (m.group(6) != null) {
        spans.add(TextSpan(
          text: m.group(7),
          style: base.copyWith(
              fontWeight: FontWeight.bold, fontStyle: FontStyle.italic),
        ));
      } else if (m.group(8) != null) {
        spans.add(TextSpan(
            text: m.group(9), style: base.copyWith(fontWeight: FontWeight.bold)));
      } else if (m.group(10) != null) {
        spans.add(TextSpan(
            text: m.group(10), style: base.copyWith(fontStyle: FontStyle.italic)));
      } else if (m.group(11) != null) {
        spans.add(TextSpan(
          text: m.group(11),
          style: base.copyWith(decoration: TextDecoration.lineThrough),
        ));
      } else if (m.group(12) != null) {
        spans.add(TextSpan(
          text: m.group(12),
          style: base.copyWith(backgroundColor: const Color(0x66F7931A)),
        ));
      } else if (m.group(13) != null) {
        spans.add(_link(context, m.group(13)!, m.group(13)!, base));
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

class _ListItem {
  const _ListItem({required this.text, required this.ordered, required this.depth});

  final String text;
  final bool ordered;
  final int depth;
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.item, required this.index, required this.parent});

  final _ListItem item;
  final int index;
  final MarkdownBody parent;

  static final _task = RegExp(r'^\[([ xX])\]\s+(.*)$');

  @override
  Widget build(BuildContext context) {
    final task = _task.firstMatch(item.text);
    return Padding(
      padding: EdgeInsets.only(left: 4 + item.depth * 16.0, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (task != null)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 2),
              child: Icon(
                task.group(1)!.toLowerCase() == 'x'
                    ? Icons.check_box_outlined
                    : Icons.check_box_outline_blank,
                size: 15,
                color: Theme.of(context).colorScheme.primary,
              ),
            )
          else
            SizedBox(width: 22, child: Text(item.ordered ? '$index.' : '•')),
          Expanded(
            child: parent._inline(context, task != null ? task.group(2)! : item.text),
          ),
        ],
      ),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({
    required this.head,
    required this.rows,
    required this.align,
    required this.parent,
  });

  final List<String> head;
  final List<List<String>> rows;
  final List<TextAlign> align;
  final MarkdownBody parent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(String text, int i, {bool header = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 13,
              fontWeight: header ? FontWeight.w600 : FontWeight.normal,
            ),
            textAlign: i < align.length ? align[i] : TextAlign.left,
            child: parent._inline(context, text),
          ),
        );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder(
            horizontalInside: BorderSide(color: theme.dividerColor),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(color: theme.dividerColor.withValues(alpha: 0.4)),
              children: [
                for (var i = 0; i < head.length; i++) cell(head[i], i, header: true),
              ],
            ),
            for (final row in rows)
              TableRow(children: [
                for (var i = 0; i < head.length; i++)
                  cell(i < row.length ? row[i] : '', i),
              ]),
          ],
        ),
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.kind, required this.body, required this.parent});

  final String kind;
  final String body;
  final MarkdownBody parent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = switch (kind) {
      'warning' => const Color(0xFFF7931A),
      'danger' || 'caution' => theme.colorScheme.error,
      'tip' || 'success' => theme.colorScheme.primary,
      _ => theme.colorScheme.secondary,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: accent, width: 3)),
        color: theme.dividerColor.withValues(alpha: 0.35),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            kind.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          const SizedBox(height: 4),
          MarkdownBody(body, wrapCode: parent.wrapCode, monospace: parent.monospace),
        ],
      ),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote(this.text, {required this.parent});

  final String text;
  final MarkdownBody parent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
        ),
      ),
      child: MarkdownBody(text, wrapCode: parent.wrapCode, monospace: parent.monospace),
    );
  }
}

class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.wrap = false,
  });

  final String code;
  final String language;
  final bool wrap;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  late bool _wrap = widget.wrap;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = widget.code.split('\n').length;
    final body = HighlightedCode(
      code: widget.code,
      language: widget.language,
      wrap: _wrap,
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.dividerColor.withValues(alpha: 0.5),
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Text(
                  widget.language.isEmpty ? 'text' : widget.language.toLowerCase(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  lines == 1 ? t('1 line') : t('{n} lines', {'n': lines}),
                  style: TextStyle(fontSize: 11, color: theme.hintColor),
                ),
                const Spacer(),
                _tiny(
                  icon: _wrap ? Icons.wrap_text : Icons.short_text,
                  tooltip: t('Wrap long lines'),
                  onTap: () => setState(() => _wrap = !_wrap),
                ),
                _tiny(
                  icon: _copied ? Icons.check : Icons.copy_all_outlined,
                  tooltip: t('Copy'),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: widget.code));
                    if (!mounted) return;
                    setState(() => _copied = true);
                    Future.delayed(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _copied = false);
                    });
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: _wrap
                ? body
                : SingleChildScrollView(scrollDirection: Axis.horizontal, child: body),
          ),
        ],
      ),
    );
  }

  Widget _tiny({required IconData icon, required String tooltip, required VoidCallback onTap}) =>
      IconButton(
        icon: Icon(icon, size: 15),
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
      );
}
