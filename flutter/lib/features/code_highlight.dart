import 'package:flutter/material.dart';
import '../core/theme/theme.dart';

class HighlightedCode extends StatelessWidget {
  const HighlightedCode({
    super.key,
    required this.code,
    this.language = '',
    this.wrap = false,
    this.fontSize = 12.5,
  });

  final String code;
  final String language;
  final bool wrap;
  final double fontSize;

  static const _aliases = {
    'javascript': 'js', 'jsx': 'js', 'mjs': 'js', 'cjs': 'js', 'node': 'js',
    'typescript': 'ts', 'tsx': 'ts',
    'python': 'py', 'py3': 'py',
    'golang': 'go',
    'rs': 'rust',
    'shell': 'sh', 'bash': 'sh', 'zsh': 'sh', 'console': 'sh',
    'c++': 'c', 'cpp': 'c', 'h': 'c', 'hpp': 'c', 'objc': 'c',
    'cs': 'java', 'csharp': 'java', 'kotlin': 'java', 'kt': 'java',
    'swift': 'java', 'scala': 'java',
    'postgres': 'sql', 'postgresql': 'sql', 'mysql': 'sql', 'sqlite': 'sql',
    'yml': 'yaml',
    'html': 'markup', 'xml': 'markup', 'svg': 'markup', 'vue': 'markup',
    'scss': 'css', 'less': 'css',
    'patch': 'diff',
  };

  static const _keywords = {
    'js':
        'if else for while return break continue function class const let var new this null true false undefined import export from as default try catch finally throw switch case do in of typeof instanceof await async yield delete void extends super static get set',
    'ts':
        'if else for while return break continue function class const let var new this null true false undefined import export from as default try catch finally throw switch case do in of typeof instanceof await async yield delete void extends super static get set interface type enum implements public private protected readonly namespace declare abstract satisfies keyof infer',
    'dart':
        'abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for get if implements import in interface is late library mixin new null on operator part required rethrow return set show static super switch sync this throw true try typedef var void while with yield',
    'py':
        'def class return if elif else for while import from as pass break continue with try except finally raise lambda yield global nonlocal assert del in is not and or None True False async await match case',
    'go':
        'func package import var const type struct interface map chan go defer if else for range return switch case default break continue fallthrough select nil true false make new len cap append',
    'rust':
        'fn let mut const static struct enum impl trait pub use mod crate self super match if else loop while for in return break continue where as dyn ref move unsafe async await Some None Ok Err true false',
    'java':
        'public private protected class interface extends implements static final void int long double float boolean char String new return if else for while do switch case break continue try catch finally throw throws import package this super null true false abstract synchronized volatile enum record',
    'c':
        'int char float double void long short signed unsigned struct union enum typedef static const extern return if else for while do switch case break continue sizeof goto NULL include define ifdef ifndef endif pragma',
    'sh':
        'if then else elif fi for while do done case esac function return export local readonly set unset echo printf cd exit source shift trap eval exec test',
    'sql':
        'select from where insert update delete into values set join left right inner outer on group by order having limit offset create table alter drop index primary key foreign references null not and or as distinct union all case when then else end',
    'yaml': 'true false null yes no on off',
    'json': 'true false null',
  };

  static const _fallbackKeywords =
      'if else for while return break continue function class const let var new this null true false import export try catch throw switch case';

  static String _normalise(String lang) {
    final l = lang.toLowerCase();
    return _aliases[l] ?? l;
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback,
      fontSize: fontSize,
      height: 1.45,
      color: DefaultTextStyle.of(context).style.color,
    );
    return RichText(
      softWrap: wrap,
      overflow: wrap ? TextOverflow.clip : TextOverflow.visible,
      text: TextSpan(style: style, children: spans(context, code, language, style)),
    );
  }

  static List<InlineSpan> spans(
    BuildContext context,
    String code,
    String language,
    TextStyle base,
  ) {
    final palette = _CodePalette.of(context);
    final lang = _normalise(language);
    if (lang == 'diff') return _diff(code, base, palette);
    if (lang.isEmpty || lang == 'text' || lang == 'plain' || lang == 'txt') {
      return [TextSpan(text: code)];
    }
    return _generic(code, lang, base, palette);
  }

  static List<InlineSpan> _diff(String code, TextStyle base, _CodePalette p) {
    final out = <InlineSpan>[];
    for (final line in code.split('\n')) {
      Color? colour;
      if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('@@')) {
        colour = p.meta;
      } else if (line.startsWith('+')) {
        colour = p.ins;
      } else if (line.startsWith('-')) {
        colour = p.del;
      }
      out.add(TextSpan(
        text: '$line\n',
        style: colour == null ? null : base.copyWith(color: colour),
      ));
    }
    return out;
  }

  static final _pattern = RegExp(
    r'(/\*[\s\S]*?\*/)'
    r'|(//[^\n]*)'
    r'|(#[^\n]*)'
    r'|(--[^\n]*)'
    r'''|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)'''
    r'|(\b0[xX][0-9a-fA-F]+\b|\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?\b)'
    r'|([A-Za-z_$][\w$]*)',
  );

  static List<InlineSpan> _generic(
    String code,
    String lang,
    TextStyle base,
    _CodePalette p,
  ) {
    final words = (_keywords[lang] ?? _fallbackKeywords).split(' ').toSet();
    final hashComments =
        lang == 'py' || lang == 'sh' || lang == 'yaml' || lang == 'rust' || lang == 'c';
    final dashComments = lang == 'sql';
    final slashComments = lang != 'py' && lang != 'sh' && lang != 'yaml';

    final out = <InlineSpan>[];
    var at = 0;
    for (final m in _pattern.allMatches(code)) {
      if (m.start > at) out.add(TextSpan(text: code.substring(at, m.start)));
      at = m.end;
      if (m.group(1) != null) {
        out.add(TextSpan(text: m.group(1), style: base.copyWith(color: p.comment)));
      } else if (m.group(2) != null) {
        out.add(slashComments
            ? TextSpan(text: m.group(2), style: base.copyWith(color: p.comment))
            : TextSpan(text: m.group(2)));
      } else if (m.group(3) != null) {
        out.add(hashComments
            ? TextSpan(text: m.group(3), style: base.copyWith(color: p.comment))
            : TextSpan(text: m.group(3)));
      } else if (m.group(4) != null) {
        out.add(dashComments
            ? TextSpan(text: m.group(4), style: base.copyWith(color: p.comment))
            : TextSpan(text: m.group(4)));
      } else if (m.group(5) != null) {
        out.add(TextSpan(text: m.group(5), style: base.copyWith(color: p.string)));
      } else if (m.group(6) != null) {
        out.add(TextSpan(text: m.group(6), style: base.copyWith(color: p.number)));
      } else if (m.group(7) != null) {
        final word = m.group(7)!;
        if (words.contains(word)) {
          out.add(TextSpan(
            text: word,
            style: base.copyWith(color: p.keyword, fontWeight: FontWeight.w600),
          ));
        } else if (word.isNotEmpty && word[0].toUpperCase() == word[0] &&
            word[0].toLowerCase() != word[0]) {
          out.add(TextSpan(text: word, style: base.copyWith(color: p.type)));
        } else {
          out.add(TextSpan(text: word));
        }
      }
    }
    if (at < code.length) out.add(TextSpan(text: code.substring(at)));
    return out;
  }
}

class _CodePalette {
  const _CodePalette({
    required this.keyword,
    required this.string,
    required this.number,
    required this.type,
    required this.comment,
    required this.ins,
    required this.del,
    required this.meta,
  });

  final Color keyword;
  final Color string;
  final Color number;
  final Color type;
  final Color comment;
  final Color ins;
  final Color del;
  final Color meta;

  static _CodePalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const _CodePalette(
            keyword: Color(0xFFFF79C6),
            string: Color(0xFF9AE86B),
            number: Color(0xFFFFB86C),
            type: Color(0xFFFFD866),
            comment: Color(0x99E8EDF4),
            ins: Color(0xFF4ADE80),
            del: Color(0xFFFF6B81),
            meta: Color(0xFF6ECBFF),
          )
        : const _CodePalette(
            keyword: Color(0xFFA626A4),
            string: Color(0xFF2F8A37),
            number: Color(0xFFB96A00),
            type: Color(0xFF8A6D00),
            comment: Color(0x9910151C),
            ins: Color(0xFF167C3A),
            del: Color(0xFFB3202F),
            meta: Color(0xFF0B6FB8),
          );
  }
}
