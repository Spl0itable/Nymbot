import 'dart:convert';

class SandboxFile {
  const SandboxFile({required this.name, this.text, this.data, this.size = 0, this.skipped = false});

  final String name;
  final String? text;
  final String? data;
  final int size;
  final bool skipped;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (text != null) 'text': text,
        if (data != null) 'data': data,
      };
}

class SandboxTable {
  const SandboxTable({required this.columns, required this.index, required this.rows, this.totalRows});

  final List<String> columns;
  final List<String> index;
  final List<List<String>> rows;
  final int? totalRows;
}

class SandboxResult {
  const SandboxResult({
    this.stdout = '',
    this.stderr = '',
    this.value,
    this.table,
    this.images = const [],
    this.files = const [],
    this.error,
    this.truncated = false,
    this.ms = 0,
  });

  final String stdout;
  final String stderr;
  final String? value;
  final SandboxTable? table;
  final List<String> images;
  final List<SandboxFile> files;
  final String? error;
  final bool truncated;
  final int ms;

  bool get empty =>
      stdout.isEmpty &&
      stderr.isEmpty &&
      value == null &&
      table == null &&
      images.isEmpty &&
      files.isEmpty &&
      error == null;
}

sealed class SandboxEvent {
  const SandboxEvent(this.id);

  final String? id;
}

class SandboxReady extends SandboxEvent {
  const SandboxReady() : super(null);
}

class SandboxStatus extends SandboxEvent {
  const SandboxStatus(super.id, this.phase);

  final String phase;
}

class SandboxDone extends SandboxEvent {
  const SandboxDone(super.id, this.result);

  final SandboxResult result;
}

class SandboxPdfProgress extends SandboxEvent {
  const SandboxPdfProgress(super.id, this.page, this.of);

  final int page;
  final int of;
}

class SandboxPdfDone extends SandboxEvent {
  const SandboxPdfDone(super.id, {required this.pages, required this.headings, required this.total, this.error});

  final List<String> pages;
  final List<({String title, int page})> headings;
  final int total;
  final String? error;
}

class SandboxProtocol {
  SandboxProtocol._();

  static const textMax = 64 * 1024;
  static const imagesMax = 8;
  static const filesMax = 8;
  static const sendMax = 12000;
  static const messageMax = 48 * 1024 * 1024;
  static const fileMax = 1024 * 1024;
  static const imageMax = 2 * 1024 * 1024;
  static const pdfPagesMax = 2000;
  static const pdfTextMax = 8 * 1024 * 1024;
  static const headingsMax = 2000;

  static int base64Max(int bytes) => (bytes + 2) ~/ 3 * 4;

  static final _png = RegExp(r'^data:image/png;base64,[A-Za-z0-9+/=]+$');
  static final _b64 = RegExp(r'^[A-Za-z0-9+/=]*$');

  static const _languages = {
    'python': 'python',
    'py': 'python',
    'python3': 'python',
    'py3': 'python',
    'javascript': 'javascript',
    'js': 'javascript',
    'mjs': 'javascript',
    'node': 'javascript',
  };

  static String? languageOf(String fence) => _languages[fence.trim().toLowerCase()];

  static final pyStdlib = 'abc aifc antigravity argparse array ast asyncio atexit audioop base64 bdb binascii bisect builtins bz2 cProfile calendar cgi cgitb chunk cmath cmd code codecs codeop collections colorsys compileall concurrent configparser contextlib contextvars copy copyreg crypt csv ctypes curses dataclasses datetime dbm decimal difflib dis doctest email encodings ensurepip enum errno faulthandler fcntl filecmp fileinput fnmatch fractions ftplib functools gc genericpath getopt getpass gettext glob graphlib grp gzip hashlib heapq hmac html http idlelib imaplib imghdr importlib inspect io ipaddress itertools json keyword lib2to3 linecache locale logging lzma mailbox mailcap marshal math mimetypes mmap modulefinder msilib msvcrt multiprocessing netrc nis nntplib nt ntpath nturl2path numbers opcode operator optparse os ossaudiodev pathlib pdb pickle pickletools pipes pkgutil platform plistlib poplib posix posixpath pprint profile pstats pty pwd py_compile pyclbr pydoc pydoc_data pyexpat queue quopri random re readline reprlib resource rlcompleter runpy sched secrets select selectors shelve shlex shutil signal site smtplib sndhdr socket socketserver spwd sqlite3 sre_compile sre_constants sre_parse ssl stat statistics string stringprep struct subprocess sunau symtable sys sysconfig syslog tabnanny tarfile telnetlib tempfile termios textwrap this threading time timeit tkinter token tokenize tomllib trace traceback tracemalloc tty turtle turtledemo types typing unicodedata unittest urllib uu uuid venv warnings wave weakref webbrowser winreg winsound wsgiref xdrlib xml xmlrpc zipapp zipfile zipimport zlib zoneinfo'.split(' ').toSet();

  static final pyBundled = 'bs4 contourpy cycler decorator fontTools joblib kiwisolver matplotlib matplotlib_pyodide mpmath networkx numpy packaging pandas patsy PIL pyparsing dateutil pytz yaml regex sklearn scipy setuptools pkg_resources six soupsieve sqlite3 statsmodels sympy threadpoolctl xlrd pyodide js'.split(' ').toSet();

  static const pyServerOnly = {
    'socket', 'ssl', 'subprocess', 'multiprocessing', 'threading', 'tkinter', 'turtle', 'curses',
    'readline', 'webbrowser', 'ftplib', 'smtplib', 'poplib', 'imaplib', 'socketserver', 'telnetlib', 'xmlrpc', 'selectors', 'select',
    'urllib.request', 'http.client', 'http.server', 'http.cookiejar',
  };

  static final jsServerOnly = RegExp(
      r'\brequire\s*\(|^\s*import\s[^(]|^\s*export\s[^\n]*\sfrom\s|\bimport\s*\(|\bprocess\.(?:argv|env|exit|stdin|stdout|cwd)\b|\b__dirname\b|\b__filename\b|\bBuffer\.|\bfetch\s*\(|\bXMLHttpRequest\b|\bWebSocket\b|\bEventSource\b',
      multiLine: true);

  static final _pyPlain = RegExp(r'^\s*import\s+([\w.,\s]+?)(?:\s+as\s+\w+)?\s*(?:#.*)?$');
  static final _pyFrom = RegExp(r'^\s*from\s+([\w.]+)\s+import\b');

  static List<String> pythonImports(String code) {
    final out = <String>[];
    for (final line in code.split('\n')) {
      final plain = _pyPlain.firstMatch(line);
      if (plain != null) {
        for (final part in plain.group(1)!.split(',')) {
          final name = part.trim().split(RegExp(r'\s+as\s+')).first.trim();
          if (name.isNotEmpty) out.add(name);
        }
        continue;
      }
      final from = _pyFrom.firstMatch(line);
      if (from != null) out.add(from.group(1)!);
    }
    return out;
  }

  static bool localOk(String? language, String code) {
    if (language == 'python') {
      for (final full in pythonImports(code)) {
        final parts = full.split('.');
        final top = parts.first;
        if (pyServerOnly.contains(top) || pyServerOnly.contains(parts.take(2).join('.'))) return false;
        if (!pyStdlib.contains(top) && !pyBundled.contains(top)) return false;
      }
      return true;
    }
    if (language == 'javascript') return !jsServerOnly.hasMatch(code);
    return false;
  }

  static String encodeRun({
    required String id,
    required String code,
    required String language,
    List<SandboxFile> files = const [],
  }) =>
      jsonEncode({
        'type': 'run',
        'id': id,
        'code': code,
        'language': language == 'javascript' ? 'javascript' : 'python',
        'files': files.map((f) => f.toJson()).toList(),
      });

  static String encodePdf({required String id, required String base64}) =>
      jsonEncode({'type': 'pdf', 'id': id, 'data': base64});

  static String encodePing() => jsonEncode({'type': 'ping'});

  static String receiveScript(String json) => 'window.nymbotSandbox && window.nymbotSandbox.receive(${jsonEncode(json)});';

  static String _clip(Object? v) {
    final s = v is String ? v : '';
    return s.length > textMax ? s.substring(0, textMax) : s;
  }

  static String _name(Object? raw) {
    final s = raw is String && raw.isNotEmpty ? raw : 'file';
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  static SandboxTable? _table(Object? raw) {
    if (raw is! Map) return null;
    final columns = raw['columns'];
    final rows = raw['rows'];
    if (columns is! List || rows is! List) return null;
    final index = raw['index'];
    final total = raw['total'];
    return SandboxTable(
      columns: columns.take(20).map((c) => '$c').toList(),
      index: index is List ? index.take(50).map((c) => '$c').toList() : const [],
      rows: [
        for (final r in rows.take(50)) r is List ? r.take(20).map((c) => '$c').toList() : <String>[],
      ],
      totalRows: total is List && total.isNotEmpty && total.first is num ? (total.first as num).toInt() : null,
    );
  }

  static SandboxResult result(Map<String, dynamic> m) => SandboxResult(
        stdout: _clip(m['stdout']),
        stderr: _clip(m['stderr']),
        value: m['value'] is String ? _clip(m['value']) : null,
        table: _table(m['table']),
        images: [
          for (final u in (m['images'] is List ? m['images'] as List : const []))
            if (u is String && u.length <= base64Max(imageMax) + 22 && _png.hasMatch(u)) u,
        ].take(imagesMax).toList(),
        files: [
          for (final f in (m['files'] is List ? m['files'] as List : const []))
            if (f is Map) _file(f),
        ].take(filesMax).toList(),
        error: m['error'] == null ? null : _clip('${m['error']}'),
        truncated: m['truncated'] == true,
        ms: (m['ms'] is num) ? (m['ms'] as num).toInt() : 0,
      );

  static SandboxFile _file(Map f) {
    final raw = f['data'];
    final data = raw is String && raw.length <= base64Max(fileMax) && _b64.hasMatch(raw) ? raw : null;
    return SandboxFile(
      name: _name(f['name']),
      size: (f['size'] is num) ? (f['size'] as num).toInt() : 0,
      data: data,
      skipped: data == null,
    );
  }

  static List<String> _pages(Object? raw) {
    final out = <String>[];
    if (raw is! List) return out;
    var left = pdfTextMax;
    for (final p in raw.take(pdfPagesMax)) {
      if (left <= 0) break;
      final text = '$p';
      final kept = text.length > left ? text.substring(0, left) : text;
      out.add(kept);
      left -= kept.length;
    }
    return out;
  }

  static SandboxEvent? decode(String raw) {
    if (raw.length > messageMax) return null;
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (parsed is! Map) return null;
    final m = parsed.cast<String, dynamic>();
    final type = m['type'];
    final id = m['id'] is String ? m['id'] as String : null;
    switch (type) {
      case 'ready':
        return const SandboxReady();
      case 'status':
        if (id == null || m['phase'] is! String) return null;
        return SandboxStatus(id, m['phase'] as String);
      case 'result':
        if (id == null) return null;
        return SandboxDone(id, result(m));
      case 'pdf-progress':
        if (id == null) return null;
        return SandboxPdfProgress(id, (m['page'] as num?)?.toInt() ?? 0, (m['of'] as num?)?.toInt() ?? 0);
      case 'pdf-result':
        if (id == null) return null;
        return SandboxPdfDone(
          id,
          pages: _pages(m['pages']),
          headings: [
            for (final h in (m['headings'] is List ? (m['headings'] as List).take(headingsMax) : const []))
              if (h is Map && h['title'] is String) (title: h['title'] as String, page: (h['page'] as num?)?.toInt() ?? 1),
          ],
          total: (m['total'] as num?)?.toInt() ?? 0,
          error: m['error'] == null ? null : '${m['error']}',
        );
    }
    return null;
  }

  static String tableText(SandboxTable table) {
    final lines = <String>[
      ['', ...table.columns].join('\t'),
      for (var i = 0; i < table.rows.length; i++)
        [i < table.index.length ? table.index[i] : '$i', ...table.rows[i]].join('\t'),
    ];
    return lines.join('\n');
  }

  static String outputText(SandboxResult r, {required String chartsLabel, required String filesLabel}) {
    final parts = <String>[
      if (r.stdout.isNotEmpty) r.stdout.trimRight(),
      if (r.value != null) r.value!,
      if (r.table != null) tableText(r.table!),
      if (r.stderr.isNotEmpty) r.stderr.trimRight(),
      if (r.error != null) r.error!,
      if (r.images.isNotEmpty) chartsLabel,
      if (r.files.isNotEmpty) filesLabel,
    ];
    var body = parts.join('\n\n');
    if (body.length > sendMax) body = '${body.substring(0, sendMax)}\n…';
    return body;
  }
}
