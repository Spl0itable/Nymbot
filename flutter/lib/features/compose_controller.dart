import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/theme/theme.dart';

/// The composer, which shows the markdown you write as what it means.
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({String? text}) : super() {
    if (text != null && text.isNotEmpty) setMarkdown(text);
  }

  static final RegExp _inline = RegExp(
    r'\*\*([\s\S]+?)\*\*'
    r'|__([\s\S]+?)__'
    r'|\*([^*\n]+?)\*'
    r'|_([^_\n]+?)_'
    r'|~~([\s\S]+?)~~'
    r'|\[([^\][]*)\]\(([^()\s]*)\)',
  );

  static final RegExp _fence = RegExp(r'^[ \t]*(```|~~~)([\w+#.-]*)[ \t]*$');
  static final RegExp _codeSpan = RegExp(r'(`+)([^`\n]+?)\1');
  static final RegExp _heading = RegExp(r'^#{1,6}[ \t]+');
  static final RegExp _quote = RegExp(r'^[ \t]*>[ \t]?');
  static final RegExp _bullet = RegExp(r'^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+');

  final List<_Code> _code = <_Code>[];
  final List<_Block> _blocks = <_Block>[];
  bool _applying = false;

  List<TextRange> get blocks =>
      [for (final b in _blocks) TextRange(start: b.start, end: b.end)];

  List<TextRange> get codeSpans =>
      [for (final c in _code) TextRange(start: c.start, end: c.end)];

  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (!down && key != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed || keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final sel = value.selection;
    if (!sel.isValid || !sel.isCollapsed) return KeyEventResult.ignored;
    final at = sel.extentOffset;
    final block = _blockAt(at);
    if (block == null) return KeyEventResult.ignored;
    final text = this.text;
    if (down) {
      if (block.end != text.length || text.indexOf('\n', at) != -1) {
        return KeyEventResult.ignored;
      }
      _applying = true;
      value = TextEditingValue(
        text: '$text\n',
        selection: TextSelection.collapsed(offset: text.length + 1),
      );
      _applying = false;
      return KeyEventResult.handled;
    }
    if (block.start != 0 || (at > 0 && text.lastIndexOf('\n', at - 1) != -1)) {
      return KeyEventResult.ignored;
    }
    for (final c in _code) {
      c.start++;
      c.end++;
    }
    for (final b in _blocks) {
      b.start++;
      b.end++;
    }
    _applying = true;
    value = TextEditingValue(
      text: '\n$text',
      selection: const TextSelection.collapsed(offset: 0),
    );
    _applying = false;
    return KeyEventResult.handled;
  }

  String get markdown {
    final text = this.text;
    final cuts = <_Cut>[];
    for (final c in _code) {
      if (c.end <= c.start) continue;
      final body = text.substring(c.start, c.end);
      var mark = '`';
      while (body.contains(mark)) {
        mark += '`';
      }
      cuts.add(_Cut(c.start, c.end, mark, mark));
    }
    for (final b in _blocks) {
      if (b.end <= b.start) continue;
      cuts.add(_Cut(b.start, b.end, '```${b.lang}\n', '\n```'));
    }
    cuts.sort((x, y) => x.start.compareTo(y.start));
    final out = StringBuffer();
    var at = 0;
    for (final c in cuts) {
      if (c.start < at) continue;
      out.write(text.substring(at, c.start));
      out.write(c.open);
      out.write(text.substring(c.start, c.end));
      out.write(c.close);
      at = c.end;
    }
    out.write(text.substring(at));
    return out.toString();
  }

  void setMarkdown(String source) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final shown = <String>[];
    final spans = <List<int>>[]; // [line, start, end] within that line
    final blockLines = <List<Object>>[]; // [firstLine, lastLine, lang]
    String? open;
    var first = 0;
    String lang = '';
    for (final line in lines) {
      final fence = _fence.firstMatch(line);
      if (fence != null && (open == null || fence.group(1) == open)) {
        if (open == null) {
          open = fence.group(1);
          lang = fence.group(2) ?? '';
          first = shown.length;
        } else {
          if (shown.length == first) shown.add('');
          blockLines.add([first, shown.length - 1, lang]);
          open = null;
        }
        continue;
      }
      if (open != null) {
        shown.add(line);
        continue;
      }
      final out = StringBuffer();
      var at = 0;
      for (final m in _codeSpan.allMatches(line)) {
        out.write(line.substring(at, m.start));
        final start = out.length;
        out.write(m.group(2));
        spans.add([shown.length, start, out.length]);
        at = m.end;
      }
      out.write(line.substring(at));
      shown.add(out.toString());
    }
    if (open != null) {
      if (shown.length == first) shown.add('');
      blockLines.add([first, shown.length - 1, lang]);
    }
    final starts = <int>[];
    var offset = 0;
    for (final line in shown) {
      starts.add(offset);
      offset += line.length + 1;
    }
    _code
      ..clear()
      ..addAll(spans.map((s) => _Code(starts[s[0]] + s[1], starts[s[0]] + s[2])));
    _blocks
      ..clear()
      ..addAll(blockLines.map((b) {
        final a = b[0] as int;
        final z = b[1] as int;
        return _Block(starts[a], starts[z] + shown[z].length, b[2] as String);
      }));
    final text = shown.join('\n');
    _applying = true;
    value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _applying = false;
  }

  @override
  set value(TextEditingValue next) {
    if (_applying) {
      super.value = next;
      return;
    }
    final oldText = super.value.text;
    final newText = next.text;
    if (oldText == newText) {
      super.value = next;
      return;
    }
    if (newText.isEmpty) {
      _code.clear();
      _blocks.clear();
      super.value = next;
      return;
    }
    var a = 0;
    final shortest = math.min(oldText.length, newText.length);
    while (a < shortest && oldText.codeUnitAt(a) == newText.codeUnitAt(a)) {
      a++;
    }
    var bo = oldText.length;
    var bn = newText.length;
    while (bo > a && bn > a && oldText.codeUnitAt(bo - 1) == newText.codeUnitAt(bn - 1)) {
      bo--;
      bn--;
    }
    final removed = bo - a;
    final inserted = bn - a;
    _shift(a, removed, inserted, newText);
    if (removed == 0 && inserted == 1) {
      final ch = newText[a];
      final ruled = ch == '`'
          ? _pairBacktick(next, a)
          : ch == '\n'
              ? _enter(next, a)
              : null;
      if (ruled != null) {
        super.value = ruled;
        return;
      }
    }
    super.value = next;
  }

  void _shift(int at, int removed, int inserted, String text) {
    final delta = inserted - removed;
    final cut = at + removed;
    for (final c in _code.toList()) {
      if (c.end <= at) continue;
      if (c.start >= cut) {
        c.start += delta;
        c.end += delta;
      } else if (c.start < at && cut < c.end) {
        c.end += delta;
      } else if (c.start < at) {
        c.end = at + inserted;
      } else if (cut < c.end) {
        c.start = at + inserted;
        c.end += delta;
      } else {
        _code.remove(c);
        continue;
      }
      if (c.end <= c.start) _code.remove(c);
    }
    for (final b in _blocks.toList()) {
      if (b.end < at) continue;
      if (removed > 0 && at <= b.start && b.end <= cut && (at < b.start || cut > b.end)) {
        _blocks.remove(b);
        continue;
      }
      if (b.start > cut) {
        b.start += delta;
        b.end += delta;
      } else if (b.start <= at && cut <= b.end) {
        b.end += delta;
      } else if (b.start < at) {
        b.end = at + inserted;
      } else if (cut < b.end) {
        b.start = at + inserted;
        b.end += delta;
      } else {
        _blocks.remove(b);
        continue;
      }
      if (b.end < b.start) {
        _blocks.remove(b);
        continue;
      }
      _alignBlock(b, text);
      if (b.start == b.end && (at < b.start || at > b.end)) _blocks.remove(b);
    }
    _code.removeWhere((c) => _blocks.any((b) => b.start <= c.start && c.end <= b.end));
  }

  static int _lineStart(String text, int at) =>
      at <= 0 ? 0 : text.lastIndexOf('\n', at - 1) + 1;

  static void _alignBlock(_Block b, String text) {
    b.start = _lineStart(text, b.start);
    final nl = text.indexOf('\n', b.end);
    b.end = nl == -1 ? text.length : nl;
    if (b.end < b.start) b.end = b.start;
  }

  _Block? _blockAt(int offset) {
    for (final b in _blocks) {
      if (b.start <= offset && offset <= b.end) return b;
    }
    return null;
  }

  bool _inCode(int offset) => _code.any((c) => c.start < offset && offset < c.end);

  TextEditingValue? _pairBacktick(TextEditingValue next, int at) {
    final text = next.text;
    if (at == 0 || _blockAt(at) != null) return null;
    final lineStart = _lineStart(text, at);
    final j = text.lastIndexOf('`', at - 1);
    if (j == -1 || j < lineStart) return null;
    if (at - j < 2 || _inCode(j)) return null;
    final body = text.substring(j + 1, at);
    if (body.trim().isEmpty) return null;
    final out = text.substring(0, j) + body + text.substring(at + 1);
    _drop(at, 1);
    _drop(j, 1);
    _code.removeWhere((c) => c.start >= j && c.end <= j + body.length);
    _code.add(_Code(j, j + body.length));
    return TextEditingValue(
      text: out,
      selection: TextSelection.collapsed(offset: j + body.length),
    );
  }

  TextEditingValue? _enter(TextEditingValue next, int at) {
    final text = next.text;
    final lineStart = _lineStart(text, at);
    final line = text.substring(lineStart, at);
    final block = _blockAt(lineStart);
    final fence = _fence.firstMatch(line);
    if (fence != null && block == null) {
      final out = text.substring(0, lineStart) + text.substring(at + 1);
      _drop(lineStart, at + 1 - lineStart);
      _blocks.add(_Block(lineStart, lineStart, fence.group(2) ?? ''));
      return TextEditingValue(
        text: out,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    if (block != null && fence != null && (fence.group(2) ?? '').isEmpty) {
      final out = text.substring(0, lineStart) + text.substring(at + 1);
      _drop(lineStart, at + 1 - lineStart);
      if (lineStart - 1 < block.start) {
        _blocks.remove(block);
      } else {
        block.end = lineStart - 1;
      }
      return TextEditingValue(
        text: out,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    if (block != null && line.isEmpty && block.end == at + 1) {
      final out = text.substring(0, at) + text.substring(at + 1);
      _drop(at, 1);
      if (lineStart - 1 < block.start) {
        _blocks.remove(block);
      } else {
        block.end = lineStart - 1;
      }
      return TextEditingValue(
        text: out,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }
    return null;
  }

  void _drop(int at, int length) {
    final end = at + length;
    for (final c in _code.toList()) {
      if (c.start >= end) {
        c.start -= length;
        c.end -= length;
      } else if (c.end > at) {
        c.start = math.min(c.start, at);
        c.end = math.max(at, c.end - length);
        if (c.end <= c.start) _code.remove(c);
      }
    }
    for (final b in _blocks.toList()) {
      if (b.start >= end) {
        b.start -= length;
        b.end -= length;
      } else if (b.end >= at) {
        b.start = math.min(b.start, at);
        b.end = math.max(at, b.end - length);
      }
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }

    final base = style ?? const TextStyle();
    final theme = Theme.of(context);
    final faint = base.copyWith(
        color: theme.hintColor, fontWeight: FontWeight.normal, fontStyle: FontStyle.normal);
    final mono = base.copyWith(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      fontSize: (base.fontSize ?? 14) * 0.92,
    );

    final spans = <InlineSpan>[];
    final text = this.text;
    var at = 0;
    while (true) {
      final nl = text.indexOf('\n', at);
      final end = nl == -1 ? text.length : nl;
      final block = _blockAt(at);
      if (block != null && end <= block.end) {
        spans.add(TextSpan(text: text.substring(at, end), style: mono));
      } else {
        _line(spans, text, at, end, base, faint, mono, theme);
      }
      if (nl == -1) break;
      spans.add(TextSpan(text: '\n', style: base));
      at = nl + 1;
    }
    return TextSpan(style: base, children: spans);
  }

  void _line(List<InlineSpan> spans, String text, int from, int to, TextStyle base,
      TextStyle faint, TextStyle mono, ThemeData theme) {
    final line = text.substring(from, to);
    var restAt = from;
    TextStyle body = base;

    final heading = _heading.matchAsPrefix(line);
    final quote = _quote.matchAsPrefix(line);
    final bullet = _bullet.matchAsPrefix(line);
    if (heading != null) {
      spans.add(TextSpan(text: heading[0], style: faint));
      restAt += heading.end;
      body = base.copyWith(fontWeight: FontWeight.w700);
    } else if (quote != null) {
      spans.add(TextSpan(text: quote[0], style: faint));
      restAt += quote.end;
      body = base.copyWith(color: theme.hintColor, fontStyle: FontStyle.italic);
    } else if (bullet != null) {
      spans.add(TextSpan(text: bullet[0], style: faint));
      restAt += bullet.end;
    }

    final codes = _code.where((c) => c.start >= restAt && c.end <= to).toList()
      ..sort((x, y) => x.start.compareTo(y.start));
    var at = restAt;
    for (final c in codes) {
      if (c.start > at) _prose(spans, text.substring(at, c.start), body, faint, mono, theme);
      spans.add(TextSpan(text: text.substring(c.start, c.end), style: mono));
      at = c.end;
    }
    if (at < to) _prose(spans, text.substring(at, to), body, faint, mono, theme);
  }

  void _prose(List<InlineSpan> spans, String rest, TextStyle body, TextStyle faint,
      TextStyle mono, ThemeData theme) {
    var at = 0;
    for (final m in _inline.allMatches(rest)) {
      if (m.start > at) {
        spans.add(TextSpan(text: rest.substring(at, m.start), style: body));
      }
      if (m[1] != null) {
        _wrapped(spans, '**', m[1]!, body.copyWith(fontWeight: FontWeight.w700), faint);
      } else if (m[2] != null) {
        _wrapped(spans, '__', m[2]!, body.copyWith(fontWeight: FontWeight.w700), faint);
      } else if (m[3] != null) {
        _wrapped(spans, '*', m[3]!, body.copyWith(fontStyle: FontStyle.italic), faint);
      } else if (m[4] != null) {
        _wrapped(spans, '_', m[4]!, body.copyWith(fontStyle: FontStyle.italic), faint);
      } else if (m[5] != null) {
        _wrapped(spans, '~~', m[5]!,
            body.copyWith(decoration: TextDecoration.lineThrough), faint);
      } else {
        spans.add(TextSpan(text: '[', style: faint));
        spans.add(TextSpan(text: m[6], style: body.copyWith(color: theme.colorScheme.primary)));
        spans.add(TextSpan(text: '](', style: faint));
        spans.add(TextSpan(text: m[7], style: mono.copyWith(color: theme.hintColor)));
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

class _Code {
  _Code(this.start, this.end);
  int start;
  int end;
}

class _Block {
  _Block(this.start, this.end, this.lang);
  int start;
  int end;
  String lang;
}

class _Cut {
  const _Cut(this.start, this.end, this.open, this.close);
  final int start;
  final int end;
  final String open;
  final String close;
}
