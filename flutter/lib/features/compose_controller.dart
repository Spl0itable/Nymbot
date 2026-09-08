import 'package:flutter/material.dart';

/// The composer, which shows the markdown you write as what it means.
///
/// A plain field can only ever show `**loud**` as five literal characters, so
/// what you were writing and what you would be sending looked like two
/// different things. This styles the markup in place while you type: the marks
/// stay where you put them, dimmed, and the text between them is drawn bold,
/// italic or as code.
///
/// Keeping the marks is what makes it safe. Flutter requires the spans to
/// spell out the field's text exactly, character for character, and the caret
/// and selection are offsets into that same text — so nothing may be dropped,
/// only dressed.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  // One pass, left to right. Each alternative captures its marks apart from
  // its body so both can be emitted; dropping a mark would shift every offset
  // after it.
  static final RegExp _inline = RegExp(
    r'(`+)([^`]*?)\1'
    r'|\*\*([\s\S]+?)\*\*'
    r'|__([\s\S]+?)__'
    r'|\*([^*\n]+?)\*'
    r'|_([^_\n]+?)_'
    r'|~~([\s\S]+?)~~'
    r'|\[([^\][]*)\]\(([^()\s]*)\)',
  );

  static final RegExp _fence = RegExp(r'^[ \t]*(```|~~~)');
  static final RegExp _heading = RegExp(r'^#{1,6}[ \t]+');
  static final RegExp _quote = RegExp(r'^[ \t]*>[ \t]?');
  static final RegExp _bullet = RegExp(r'^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+');

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // An IME needs its composing region drawn its own way, and the text under
    // it is half-formed anyway. It is left alone until it settles.
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }

    final base = style ?? const TextStyle();
    final theme = Theme.of(context);
    final faint = base.copyWith(
        color: theme.hintColor, fontWeight: FontWeight.normal, fontStyle: FontStyle.normal);
    final mono = base.copyWith(fontFamily: 'monospace', fontSize: (base.fontSize ?? 14) * 0.92);

    final spans = <InlineSpan>[];
    final lines = text.split('\n');
    var inFence = false;
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(TextSpan(text: '\n', style: base));
      final line = lines[i];
      if (_fence.hasMatch(line)) {
        spans.add(TextSpan(text: line, style: mono.copyWith(color: theme.hintColor)));
        inFence = !inFence;
        continue;
      }
      if (inFence) {
        spans.add(TextSpan(text: line, style: mono));
        continue;
      }
      _line(spans, line, base, faint, mono, theme);
    }
    return TextSpan(style: base, children: spans);
  }

  void _line(List<InlineSpan> spans, String line, TextStyle base, TextStyle faint,
      TextStyle mono, ThemeData theme) {
    var rest = line;
    TextStyle body = base;

    final heading = _heading.matchAsPrefix(line);
    final quote = _quote.matchAsPrefix(line);
    final bullet = _bullet.matchAsPrefix(line);
    if (heading != null) {
      spans.add(TextSpan(text: heading[0], style: faint));
      rest = line.substring(heading.end);
      body = base.copyWith(fontWeight: FontWeight.w700);
    } else if (quote != null) {
      spans.add(TextSpan(text: quote[0], style: faint));
      rest = line.substring(quote.end);
      body = base.copyWith(color: theme.hintColor, fontStyle: FontStyle.italic);
    } else if (bullet != null) {
      spans.add(TextSpan(text: bullet[0], style: faint));
      rest = line.substring(bullet.end);
    }

    var at = 0;
    for (final m in _inline.allMatches(rest)) {
      if (m.start > at) {
        spans.add(TextSpan(text: rest.substring(at, m.start), style: body));
      }
      if (m[1] != null) {
        spans.add(TextSpan(text: m[1], style: faint));
        spans.add(TextSpan(text: m[2], style: mono));
        spans.add(TextSpan(text: m[1], style: faint));
      } else if (m[3] != null) {
        _wrapped(spans, '**', m[3]!, body.copyWith(fontWeight: FontWeight.w700), faint);
      } else if (m[4] != null) {
        _wrapped(spans, '__', m[4]!, body.copyWith(fontWeight: FontWeight.w700), faint);
      } else if (m[5] != null) {
        _wrapped(spans, '*', m[5]!, body.copyWith(fontStyle: FontStyle.italic), faint);
      } else if (m[6] != null) {
        _wrapped(spans, '_', m[6]!, body.copyWith(fontStyle: FontStyle.italic), faint);
      } else if (m[7] != null) {
        _wrapped(spans, '~~', m[7]!,
            body.copyWith(decoration: TextDecoration.lineThrough), faint);
      } else {
        spans.add(TextSpan(text: '[', style: faint));
        spans.add(TextSpan(text: m[8], style: body.copyWith(color: theme.colorScheme.primary)));
        spans.add(TextSpan(text: '](', style: faint));
        spans.add(TextSpan(text: m[9], style: mono.copyWith(color: theme.hintColor)));
        spans.add(TextSpan(text: ')', style: faint));
      }
      at = m.end;
    }
    if (at < rest.length) spans.add(TextSpan(text: rest.substring(at), style: body));
  }

  void _wrapped(List<InlineSpan> spans, String mark, String inner, TextStyle style,
      TextStyle faint) {
    spans.add(TextSpan(text: mark, style: faint));
    spans.add(TextSpan(text: inner, style: style));
    spans.add(TextSpan(text: mark, style: faint));
  }
}
