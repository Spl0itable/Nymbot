import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import '../core/utils/safe_url.dart';
import '../features/i18n/i18n.dart';

typedef BotFileFetch = Future<Uint8List> Function(Uri url);
typedef BotFileShare = Future<void> Function(Uint8List bytes, String name, String mime);
typedef BotFileLaunch = Future<bool> Function(String url);

class BotFile {
  const BotFile({
    required this.url,
    required this.name,
    required this.ext,
    required this.label,
    required this.kind,
    required this.type,
    required this.size,
    required this.opens,
  });

  final String url;
  final String name;
  final String ext;
  final String label;
  final String kind;
  final String type;
  final int size;
  final bool opens;

  static final _line = RegExp(
      r'^\[([^\]\n]{1,200})\]\((https://[^\s)#]+)#nymbot-file&([^\s)]*)\)$');
  static final _pending = RegExp(r'^nymbot-file\b', caseSensitive: false);
  static final _pendingName = RegExp(
      r'''(?:name|filename)\s*=\s*(?:"([^"]{1,200})"|'([^']{1,200})'|([^\s"']{1,200}))''',
      caseSensitive: false);
  static final _unsafe = RegExp(
      '[\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u202a-\\u202e\\u2066-\\u2069\\ufeff]');

  static const _kinds = {
    'pdf': ('PDF', 'pdf', true),
    'docx': ('Word', 'doc', false),
    'xlsx': ('Excel', 'sheet', false),
    'csv': ('CSV', 'sheet', true),
    'md': ('Markdown', 'text', true),
    'txt': ('Text', 'text', true),
    'json': ('JSON', 'text', true),
    'html': ('HTML', 'code', false),
    'zip': ('ZIP', 'archive', false),
  };

  static const safeTypes = {
    'pdf': 'application/pdf',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'csv': 'text/csv',
    'md': 'text/markdown',
    'txt': 'text/plain',
    'json': 'application/json',
    'html': 'application/octet-stream',
    'zip': 'application/zip',
  };

  static String cleanName(String raw) {
    final s = raw
        .replaceAll(_unsafe, '')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    if (s.isEmpty) return 'file';
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  static BotFile? parse(String line) {
    final m = _line.firstMatch(line.trim());
    if (m == null) return null;
    final uri = Uri.tryParse(m.group(2)!);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    final params = <String, String>{};
    for (final kv in m.group(3)!.split('&')) {
      final at = kv.indexOf('=');
      if (at <= 0) continue;
      try {
        params[kv.substring(0, at)] = Uri.decodeComponent(kv.substring(at + 1));
      } catch (_) {}
    }
    final name = cleanName(params['name'] ?? m.group(1)!);
    final ext = (RegExp(r'\.([a-z0-9]{1,8})$', caseSensitive: false).firstMatch(name)?.group(1) ?? '').toLowerCase();
    final meta = _kinds[ext];
    return BotFile(
      url: uri.toString(),
      name: name,
      ext: ext,
      label: meta?.$1 ?? (ext.isEmpty ? t('File') : ext.toUpperCase()),
      kind: meta?.$2 ?? 'file',
      type: safeTypes[ext] ?? 'application/octet-stream',
      size: int.tryParse(params['size'] ?? '') ?? 0,
      opens: meta?.$3 ?? false,
    );
  }

  static List<BotFile>? paragraph(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;
    final files = <BotFile>[];
    for (final l in lines) {
      final f = parse(l);
      if (f == null) return null;
      files.add(f);
    }
    return files;
  }

  static bool isPending(String info) => _pending.hasMatch(info.trim());

  static String pendingName(String info) {
    final m = _pendingName.firstMatch(info);
    final raw = m?.group(1) ?? m?.group(2) ?? m?.group(3);
    return raw == null ? t('File') : cleanName(raw);
  }

  static String sizeLabel(int bytes) {
    if (bytes < 1024) return t('{n} B', {'n': bytes});
    if (bytes < 1024 * 1024) return t('{n} KB', {'n': (bytes / 1024).round().clamp(1, 1023)});
    return t('{n} MB', {'n': (bytes / (1024 * 1024)).toStringAsFixed(1)});
  }

  String get subtitle => size > 0 ? t('{type} · {size}', {'type': label, 'size': sizeLabel(size)}) : label;
}

class BotFiles {
  const BotFiles._();

  static BotFileFetch fetch = _fetch;
  static BotFileShare share = _share;
  static BotFileLaunch launch = (url) => launchSafeUrl(url);

  static Future<Uint8List> _fetch(Uri url) async {
    final res = await http.get(url).timeout(const Duration(seconds: 90));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return res.bodyBytes;
  }

  static Future<void> _share(Uint8List bytes, String name, String mime) async {
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, mimeType: mime, name: name)],
      fileNameOverrides: [name],
    ));
  }

  static Future<bool> save(BotFile file) async {
    try {
      final bytes = await fetch(Uri.parse(file.url));
      await share(bytes, file.name, file.type);
      return true;
    } catch (_) {
      await launch(file.url);
      return false;
    }
  }

  static Future<bool> open(BotFile file) async {
    if (!file.opens) return save(file);
    return launch(file.url);
  }

  static ({String name, String type, Uint8List bytes})? decodeRendered(Map<String, dynamic> data) {
    final b64 = data['data'];
    if (b64 is! String || b64.isEmpty) return null;
    final ext = data['type'] == BotFile.safeTypes['pdf'] ? 'pdf' : 'docx';
    final name = BotFile.cleanName('${data['name'] ?? 'artifact.$ext'}');
    try {
      return (name: name, type: BotFile.safeTypes[ext]!, bytes: base64Decode(b64));
    } on FormatException {
      return null;
    }
  }
}
