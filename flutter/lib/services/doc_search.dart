import 'dart:convert';
import 'dart:math' as math;

class DocChunk {
  const DocChunk(this.n, this.t);

  final int n;
  final String t;

  Map<String, dynamic> toJson() => {'n': n, 't': t};

  static DocChunk fromJson(Map<String, dynamic> j) =>
      DocChunk((j['n'] as num?)?.toInt() ?? 1, j['t'] as String? ?? '');
}

class DocHeading {
  const DocHeading(this.title, [this.page]);

  final String title;
  final int? page;

  Map<String, dynamic> toJson() => {'title': title, if (page != null) 'page': page};

  static DocHeading fromJson(Map<String, dynamic> j) =>
      DocHeading(j['title'] as String? ?? '', (j['page'] as num?)?.toInt());
}

class SearchDoc {
  SearchDoc({
    required this.id,
    required this.name,
    this.mime = '',
    this.size = 0,
    this.format = '',
    this.paged = false,
    this.pages = 0,
    this.outline = const [],
    this.chunks = const [],
    this.raw,
    this.searchable = true,
    int? addedAt,
  }) : addedAt = addedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  final String name;
  final String mime;
  final int size;
  final String format;
  final bool paged;
  final int pages;
  final List<DocHeading> outline;
  final List<DocChunk> chunks;
  final String? raw;
  final bool searchable;
  final int addedAt;

  int get chars => chunks.fold(0, (n, c) => n + c.t.length);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mime': mime,
        'size': size,
        'format': format,
        'paged': paged,
        'pages': pages,
        'outline': outline.map((h) => h.toJson()).toList(),
        'chunks': chunks.map((c) => c.toJson()).toList(),
        if (raw != null) 'raw': raw,
        'searchable': searchable,
        'addedAt': addedAt,
      };

  static SearchDoc fromJson(Map<String, dynamic> j) => SearchDoc(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        mime: j['mime'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        format: j['format'] as String? ?? '',
        paged: j['paged'] == true,
        pages: (j['pages'] as num?)?.toInt() ?? 0,
        outline: [
          for (final h in (j['outline'] as List? ?? const []))
            if (h is Map) DocHeading.fromJson(h.cast<String, dynamic>()),
        ],
        chunks: [
          for (final c in (j['chunks'] as List? ?? const []))
            if (c is Map) DocChunk.fromJson(c.cast<String, dynamic>()),
        ],
        raw: j['raw'] as String?,
        searchable: j['searchable'] != false,
        addedAt: (j['addedAt'] as num?)?.toInt(),
      );
}

class DocUsage {
  const DocUsage({
    required this.id,
    required this.name,
    required this.paged,
    required this.total,
    required this.used,
    required this.matched,
  });

  final String id;
  final String name;
  final bool paged;
  final int total;
  final List<int> used;
  final bool matched;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'paged': paged,
        'total': total,
        'used': used,
        'matched': matched,
      };

  static DocUsage fromJson(Map<String, dynamic> j) => DocUsage(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        paged: j['paged'] == true,
        total: (j['total'] as num?)?.toInt() ?? 0,
        used: [for (final n in (j['used'] as List? ?? const [])) (n as num).toInt()],
        matched: j['matched'] != false,
      );
}

class RankedChunk {
  const RankedChunk(this.index, this.score);

  final int index;
  final double score;
}

class DocSearch {
  DocSearch._();

  static const inlineMax = 96 * 1024;
  static const docMaxChars = 8 * 1024 * 1024;
  static const chunkTarget = 1500;
  static const chunkMax = 2000;
  static const turnBudget = 12000;
  static const docMinBudget = 3000;
  static const outlineMax = 24;

  static const _k1 = 1.2;
  static const _b = 0.75;

  static final _stop = ('a an and are as at be but by can could did do does for from had has have how i if in into is it its '
          'me my of on or our so than that the their them then there these they this those to was we were what when where '
          'which who why will with would you your about also any just not no yes one all more most other some such only own '
          'same very s t d ll m re ve please tell show give find does doesn document file pdf page pages')
      .split(' ')
      .toSet();

  static final _split = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static final _digit = RegExp(r'\d');

  static String _stem(String w) {
    if (w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
    if (RegExp(r'(sses|xes|ches|shes)$').hasMatch(w)) return w.substring(0, w.length - 2);
    if (RegExp(r'[^s]s$').hasMatch(w)) return w.substring(0, w.length - 1);
    if (w.endsWith('ing') && w.length > 6) return w.substring(0, w.length - 3);
    if (w.endsWith('ed') && w.length > 5) return w.substring(0, w.length - 2);
    return w;
  }

  static List<String> tokens(String text) {
    final out = <String>[];
    for (final w in text.toLowerCase().split(_split)) {
      if (w.isEmpty) continue;
      if (w.length < 2 && !_digit.hasMatch(w)) continue;
      if (_stop.contains(w)) continue;
      out.add(w.length > 4 ? _stem(w) : w);
    }
    return out;
  }

  static final _indexes = Expando<_Index>();

  static _Index _indexOf(List<DocChunk> chunks) {
    final cached = _indexes[chunks];
    if (cached != null) return cached;
    final docs = <({Map<String, int> tf, int len})>[];
    for (final c in chunks) {
      final tf = <String, int>{};
      final words = tokens(c.t);
      for (final w in words) {
        tf[w] = (tf[w] ?? 0) + 1;
      }
      docs.add((tf: tf, len: words.length));
    }
    final df = <String, int>{};
    for (final d in docs) {
      for (final w in d.tf.keys) {
        df[w] = (df[w] ?? 0) + 1;
      }
    }
    final total = docs.fold<int>(0, (n, d) => n + d.len);
    final avg = docs.isEmpty ? 1.0 : math.max(1.0, total / docs.length);
    final idx = _Index(docs, df, avg);
    _indexes[chunks] = idx;
    return idx;
  }

  static List<RankedChunk> rank(List<DocChunk> chunks, String query) {
    if (chunks.isEmpty) return const [];
    final idx = _indexOf(chunks);
    final terms = tokens(query).toSet();
    final n = chunks.length;
    final scored = <RankedChunk>[];
    for (var i = 0; i < idx.docs.length; i++) {
      final d = idx.docs[i];
      var score = 0.0;
      for (final w in terms) {
        final tf = d.tf[w];
        if (tf == null) continue;
        final df = idx.df[w] ?? 0;
        final idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
        score += idf * (tf * (_k1 + 1)) / (tf + _k1 * (1 - _b + _b * d.len / idx.avg));
      }
      if (score > 0) scored.add(RankedChunk(i, score));
    }
    scored.sort((a, b) {
      final by = b.score.compareTo(a.score);
      return by != 0 ? by : a.index.compareTo(b.index);
    });
    return scored;
  }

  static ({List<DocChunk> chunks, bool matched}) select(SearchDoc doc, String query, int budget) {
    final chunks = doc.chunks;
    final picked = <int>[];
    var used = 0;
    bool take(int i) {
      if (i < 0 || i >= chunks.length || picked.contains(i)) return false;
      final c = chunks[i];
      if (used + c.t.length > budget && picked.isNotEmpty) return false;
      picked.add(i);
      used += c.t.length;
      return true;
    }

    for (final r in rank(chunks, query)) {
      if (used >= budget) break;
      take(r.index);
    }
    final matched = picked.isNotEmpty;
    if (!matched) {
      for (var i = 0; i < chunks.length && used < budget; i++) {
        if (!take(i)) break;
      }
    }
    picked.sort();
    return (chunks: [for (final i in picked) chunks[i]], matched: matched);
  }

  static List<String> _splitLong(String text) {
    final out = <String>[];
    var rest = text;
    while (rest.length > chunkMax) {
      var cut = rest.lastIndexOf('\n', chunkTarget);
      if (cut < chunkTarget ~/ 2) cut = rest.lastIndexOf('. ', chunkTarget) + 1;
      if (cut < chunkTarget ~/ 2) cut = rest.lastIndexOf(' ', chunkTarget);
      if (cut < chunkTarget ~/ 2) cut = chunkTarget;
      out.add(rest.substring(0, cut).trim());
      rest = rest.substring(cut);
    }
    if (rest.trim().isNotEmpty) out.add(rest.trim());
    return out;
  }

  static List<String> chunkText(String text) {
    final out = <String>[];
    var cur = '';
    for (final raw in text.split(RegExp(r'\n\s*\n'))) {
      final p = raw.trim();
      if (p.isEmpty) continue;
      final pieces = p.length > chunkMax ? _splitLong(p) : [p];
      for (final piece in pieces) {
        if (cur.isNotEmpty && cur.length + piece.length + 2 > chunkTarget) {
          out.add(cur);
          cur = piece;
        } else {
          cur = cur.isEmpty ? piece : '$cur\n\n$piece';
        }
      }
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  static List<DocChunk> chunkPages(List<String> pages) => [
        for (var i = 0; i < pages.length; i++)
          for (final piece in chunkText(pages[i])) DocChunk(i + 1, piece),
      ];

  static ({List<String> chunks, List<String> columns, int rows}) chunkTable(String text, String sep) {
    final lines = text.split(RegExp(r'\r?\n'));
    final head = lines.isEmpty ? '' : lines.removeAt(0);
    final out = <String>[];
    var cur = <String>[];
    var size = head.length;
    var rows = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      rows++;
      if (cur.isNotEmpty && size + line.length + 1 > chunkTarget) {
        out.add('$head\n${cur.join('\n')}');
        cur = [];
        size = head.length;
      }
      cur.add(line.length > chunkMax ? line.substring(0, chunkMax) : line);
      size += line.length + 1;
    }
    if (cur.isNotEmpty) out.add('$head\n${cur.join('\n')}');
    final columns = head
        .split(sep)
        .map((s) => s.trim().replaceAll(RegExp(r'^"|"$'), ''))
        .where((s) => s.isNotEmpty)
        .toList();
    return (chunks: out, columns: columns, rows: rows);
  }

  static List<DocHeading> markdownHeadings(String text) {
    final out = <DocHeading>[];
    for (final m in RegExp(r'^(#{1,3})\s+(.{2,90})$', multiLine: true).allMatches(text)) {
      if (out.length >= outlineMax) break;
      out.add(DocHeading(m.group(2)!.trim()));
    }
    return out;
  }

  static String decodeEntities(String text) => text.replaceAllMapped(
        RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp|#39);'),
        (m) {
          final e = m.group(1)!;
          if (e.startsWith('#')) {
            final code = e.startsWith('#x')
                ? int.tryParse(e.substring(2), radix: 16) ?? 32
                : int.tryParse(e.substring(1)) ?? 32;
            if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return m.group(0)!;
            return String.fromCharCode(code);
          }
          return const {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' '}[e] ?? ' ';
        },
      );

  static String _tags(String s, RegExp pattern, String by) {
    final end = s.lastIndexOf('>') + 1;
    if (end == 0) return s;
    return s.substring(0, end).replaceAll(pattern, by) + s.substring(end);
  }

  static Match? _next(RegExp pattern, String s, int from) =>
      from > s.length ? null : pattern.allMatches(s, from).firstOrNull;

  static String _dropBlocks(String s) {
    final open = RegExp(r'<(script|style|noscript|template|svg|iframe|object)\b', caseSensitive: false);
    final closes = <String, Match>{};
    final unclosed = <String>{};
    final out = StringBuffer();
    var copied = 0;
    var from = 0;
    for (;;) {
      final m = _next(open, s, from);
      if (m == null) break;
      final tag = m.group(1)!.toLowerCase();
      Match? close;
      if (!unclosed.contains(tag)) {
        close = closes[tag];
        if (close == null || close.start < m.end) {
          close = _next(RegExp('</$tag\\s*>', caseSensitive: false), s, m.end);
          if (close == null) {
            unclosed.add(tag);
          } else {
            closes[tag] = close;
          }
        }
      }
      if (close == null) {
        from = m.start + 1;
        continue;
      }
      out
        ..write(s.substring(copied, m.start))
        ..write(' ');
      copied = close.end;
      from = close.end;
    }
    out.write(s.substring(copied));
    return out.toString();
  }

  static String _dropComments(String s) {
    final out = StringBuffer();
    var copied = 0;
    for (;;) {
      final at = s.indexOf('<!--', copied);
      if (at < 0) break;
      final end = s.indexOf('-->', at + 4);
      if (end < 0) break;
      out
        ..write(s.substring(copied, at))
        ..write(' ');
      copied = end + 3;
    }
    out.write(s.substring(copied));
    return out.toString();
  }

  static String _headings(String s) {
    final open = RegExp(r'<h([1-6])\b', caseSensitive: false);
    final closes = <String, Match>{};
    final unclosed = <String>{};
    final out = StringBuffer();
    var copied = 0;
    var from = 0;
    var gt = -1;
    for (;;) {
      final m = _next(open, s, from);
      if (m == null) break;
      if (gt < m.end) gt = s.indexOf('>', m.end);
      if (gt < 0) break;
      final n = m.group(1)!;
      Match? close;
      if (!unclosed.contains(n)) {
        close = closes[n];
        if (close == null || close.start <= gt) {
          close = _next(RegExp('</h$n\\s*>', caseSensitive: false), s, gt + 1);
          if (close == null) {
            unclosed.add(n);
          } else {
            closes[n] = close;
          }
        }
      }
      if (close == null) {
        from = m.start + 1;
        continue;
      }
      final level = math.min(3, int.parse(n));
      final inner = _tags(s.substring(gt + 1, close.start), RegExp(r'<[^>]*>'), '').trim();
      out
        ..write(s.substring(copied, m.start))
        ..write('\n\n${'#' * level} $inner\n\n');
      copied = close.end;
      from = close.end;
    }
    out.write(s.substring(copied));
    return out.toString();
  }

  static String stripHtml(String html) {
    var s = _dropBlocks(html);
    s = _dropComments(s);
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    s = _headings(s);
    s = _tags(s, RegExp(r'<(br|li|tr)\b[^>]*>', caseSensitive: false), '\n');
    s = _tags(s, RegExp(r'<(td|th)\b[^>]*>', caseSensitive: false), '\t');
    s = _tags(
        s,
        RegExp(r'</?(p|div|section|article|header|footer|main|aside|ul|ol|table|blockquote|pre|hr|dt|dd|figure|figcaption|nav)\b[^>]*>',
            caseSensitive: false),
        '\n\n');
    s = _tags(s, RegExp(r'<[^>]*>'), '');
    s = decodeEntities(s);
    return s
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n[ \t]+'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static List<String> _paragraphs(String xml) {
    final out = <String>[];
    final space = RegExp(r'\s');
    var from = 0;
    var gt = -1;
    var closed = true;
    for (;;) {
      final at = xml.indexOf('<w:p', from);
      if (at < 0) break;
      final after = at + 4;
      from = after;
      if (after >= xml.length) break;
      final c = xml[after];
      int body;
      if (c == '/') {
        if (xml.startsWith('/>', after)) {
          out.add('');
          from = after + 2;
        }
        continue;
      } else if (c == '>') {
        body = after + 1;
      } else if (space.hasMatch(c)) {
        if (gt < after) gt = xml.indexOf('>', after);
        if (gt < 0) break;
        if (xml[gt - 1] == '/') {
          out.add('');
          from = gt + 1;
          continue;
        }
        body = gt + 1;
      } else {
        continue;
      }
      final end = closed ? xml.indexOf('</w:p>', body) : -1;
      if (end < 0) {
        closed = false;
        continue;
      }
      out.add(xml.substring(body, end));
      from = end + 6;
    }
    return out;
  }

  static String docxText(String xml) {
    final out = <String>[];
    final piece = RegExp(r'<w:[t](?:\s[^<>]*)?>([^<]*)</w:t>|<w:tab\s*/>|<w:(?:br|cr)(?:\s[^<>]*)?/>');
    final style = RegExp(r'<w:pStyle\s+w:val="([^"<]*)"');
    for (final body in _paragraphs(xml)) {
      final buf = StringBuffer();
      for (final m in piece.allMatches(body)) {
        final whole = m.group(0)!;
        if (m.group(1) != null) {
          buf.write(decodeEntities(m.group(1)!));
        } else if (whole.startsWith('<w:tab')) {
          buf.write('\t');
        } else {
          buf.write('\n');
        }
      }
      final text = buf.toString();
      final val = style.firstMatch(body)?.group(1) ?? '';
      final h = RegExp(r'^heading\s?(\d)', caseSensitive: false).firstMatch(val);
      if (text.trim().isNotEmpty && (h != null || val.toLowerCase() == 'title')) {
        final level = h == null ? 1 : math.min(3, int.parse(h.group(1)!));
        out.add('${'#' * level} ${text.trim()}');
      } else {
        out.add(text);
      }
    }
    return out.join('\n\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static int wireCost(String text) => utf8.encode(jsonEncode(text)).length - 2;

  static String pageMarked(List<String> pages) {
    if (pages.length == 1) return pages.first;
    return [for (var i = 0; i < pages.length; i++) '[page ${i + 1}]\n${pages[i]}'].join('\n\n');
  }

  static String _ext(String name) {
    final at = name.lastIndexOf('.');
    return at == -1 ? '' : name.substring(at + 1).toLowerCase();
  }

  static ({String? text, SearchDoc? doc}) fromPages({
    required String id,
    required String name,
    required String mime,
    required int size,
    required List<String> pages,
    List<DocHeading> headings = const [],
  }) {
    final text = pageMarked(pages);
    if (wireCost(text) <= inlineMax) return (text: text, doc: null);
    return (
      text: null,
      doc: SearchDoc(
        id: id,
        name: name,
        mime: mime,
        size: size,
        format: _ext(name),
        paged: true,
        pages: pages.length,
        outline: headings.take(outlineMax).toList(),
        chunks: chunkPages(pages),
      ),
    );
  }

  static SearchDoc fromText({
    required String id,
    required String name,
    required String text,
    String mime = 'text/plain',
    int? size,
  }) {
    final ext = _ext(name);
    var body = text;
    if (ext == 'html' || ext == 'htm' || ext == 'xhtml') body = stripHtml(body);
    if (ext == 'csv' || ext == 'tsv') {
      final table = chunkTable(body, ext == 'tsv' ? '\t' : ',');
      final chunks = [for (var i = 0; i < table.chunks.length; i++) DocChunk(i + 1, table.chunks[i])];
      return SearchDoc(
        id: id,
        name: name,
        mime: mime,
        size: size ?? text.length,
        format: ext,
        pages: chunks.length,
        outline: [
          DocHeading('Columns: ${table.columns.take(30).join(', ')}'),
          DocHeading('${table.rows} rows'),
        ],
        chunks: chunks,
        raw: text,
      );
    }
    final pieces = chunkText(body);
    return SearchDoc(
      id: id,
      name: name,
      mime: mime,
      size: size ?? text.length,
      format: ext.isEmpty ? 'txt' : ext,
      pages: pieces.length,
      outline: markdownHeadings(body),
      chunks: [for (var i = 0; i < pieces.length; i++) DocChunk(i + 1, pieces[i])],
      raw: text,
    );
  }

  static String _unit(SearchDoc doc, bool plural) =>
      doc.paged ? (plural ? 'pages' : 'page') : (plural ? 'parts' : 'part');

  static List<({SearchDoc doc, List<DocChunk> chunks, bool matched})> plan(List<SearchDoc> docs, String question) {
    if (docs.isEmpty) return const [];
    final per = math.max(docMinBudget, turnBudget ~/ docs.length);
    return [
      for (final doc in docs)
        () {
          final sel = select(doc, question, per);
          return (doc: doc, chunks: sel.chunks, matched: sel.matched);
        }(),
    ];
  }

  static String wireFor(List<SearchDoc> docs, String question) {
    final out = StringBuffer();
    for (final p in plan(docs, question)) {
      final doc = p.doc;
      out.write('\n\n--- attached document: ${doc.name} (${doc.pages} ${_unit(doc, doc.pages != 1)}, '
          'searched rather than read whole) ---\n');
      if (doc.outline.isNotEmpty) {
        out.write('Outline: ${doc.outline.map((h) => h.page != null ? '${h.title} (p. ${h.page})' : h.title).join('; ')}\n');
      }
      out.write(p.matched
          ? "This document is too long to send whole. These are the passages, found on the user's device, that best "
              'match the question; the rest of it was not sent. If the answer may be in a part not shown, say so.\n'
          : 'This document is too long to send whole, and nothing in it matched the question, so this is its '
              'beginning; the rest of it was not sent. Say so if the answer is not here.\n');
      for (final c in p.chunks) {
        out.write('\n[${_unit(doc, false)} ${c.n}]\n${c.t}\n');
      }
      out.write('--- end of excerpts from ${doc.name} ---');
    }
    return out.toString();
  }

  static List<DocUsage> usage(List<SearchDoc> docs, String question) => [
        for (final p in plan(docs, question))
          DocUsage(
            id: p.doc.id,
            name: p.doc.name,
            paged: p.doc.paged,
            total: p.doc.pages,
            used: p.chunks.map((c) => c.n).toSet().toList(),
            matched: p.matched,
          ),
      ];
}

class _Index {
  _Index(this.docs, this.df, this.avg);

  final List<({Map<String, int> tf, int len})> docs;
  final Map<String, int> df;
  final double avg;
}
