import 'dart:convert';

import '../features/i18n/i18n.dart';
import 'sandbox_protocol.dart';

class RunnerImage {
  const RunnerImage({
    required this.name,
    required this.label,
    this.instanceType = '',
    this.maxTimeoutSec = 900,
    this.creditsPerMinute = 0,
  });

  final String name;
  final String label;
  final String instanceType;
  final int maxTimeoutSec;
  final double creditsPerMinute;

  static RunnerImage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.isEmpty) return null;
    final label = raw['label'];
    final max = raw['maxTimeoutSec'];
    final cpm = raw['creditsPerMinute'];
    return RunnerImage(
      name: name,
      label: label is String && label.isNotEmpty ? label : name,
      instanceType: '${raw['instanceType'] ?? ''}',
      maxTimeoutSec: max is num && max > 0 ? max.toInt() : 900,
      creditsPerMinute: cpm is num && cpm > 0 ? cpm.toDouble() : 0,
    );
  }
}

class RunnerInfo {
  const RunnerInfo({this.available = false, this.images = const []});

  final bool available;
  final List<RunnerImage> images;

  RunnerImage? image(String? name) {
    for (final i in images) {
      if (i.name == name) return i;
    }
    return null;
  }

  static RunnerInfo fromJson(Object? raw) {
    if (raw is! Map || raw['available'] != true) return const RunnerInfo();
    final images = [
      for (final i in (raw['images'] is List ? raw['images'] as List : const []))
        if (RunnerImage.fromJson(i) != null) RunnerImage.fromJson(i)!,
    ];
    return RunnerInfo(available: images.isNotEmpty, images: images);
  }
}

class ServerRunEvent {
  const ServerRunEvent(this.type, this.data);

  final String type;
  final Map<String, dynamic> data;
}

class ServerRunResponse {
  const ServerRunResponse({required this.status, this.error = const {}, this.events});

  final int status;
  final Map<String, dynamic> error;
  final Stream<ServerRunEvent>? events;
}

class ServerRunState {
  String stdout = '';
  String stderr = '';
  String? error;
  int? exitCode;
  bool timedOut = false;
  int ms = 0;
  bool truncated = false;
  bool filesTruncated = false;
  List<Map<String, dynamic>> files = const [];
  double? charged;
  double? balance;
  bool done = false;

  void take(ServerRunEvent e) {
    final d = e.data;
    switch (e.type) {
      case 'out':
        final text = d['data'] is String ? d['data'] as String : '';
        if (d['stream'] == 'stderr') {
          stderr = _clip(stderr + text);
        } else {
          stdout = _clip(stdout + text);
        }
      case 'note':
        truncated = true;
      case 'exit':
        exitCode = d['code'] is num ? (d['code'] as num).toInt() : null;
        timedOut = d['timedOut'] == true;
        ms = d['runMs'] is num ? (d['runMs'] as num).toInt() : 0;
        filesTruncated = d['filesTruncated'] == true;
        files = [
          for (final f in (d['files'] is List ? d['files'] as List : const []))
            if (f is Map && f['path'] is String)
              {'name': f['path'], 'size': f['size'], 'data': f['data']},
        ];
      case 'error':
        error = d['message'] is String && (d['message'] as String).isNotEmpty
            ? d['message'] as String
            : t('The server run failed.');
        ms = d['billedMs'] is num ? (d['billedMs'] as num).toInt() : ms;
      case 'charged':
        charged = d['credits'] is num ? (d['credits'] as num).toDouble() : 0;
        final b = d['balanceCredits'] ?? d['balance'];
        balance = b is num ? b.toDouble() : null;
        done = true;
    }
  }

  static String _clip(String s) => s.length > SandboxProtocol.textMax
      ? s.substring(s.length - SandboxProtocol.textMax)
      : s;

  SandboxResult result() => SandboxProtocol.result({
        'stdout': stdout,
        'stderr': stderr,
        'files': files,
        'error': error,
        'truncated': truncated || filesTruncated,
        'ms': ms,
      });
}

class ServerRuns {
  ServerRuns._();

  static const timeouts = [60, 300, 900];
  static const filesMax = 200;
  static const filesMaxBytes = 20 * 1024 * 1024;

  static const _languages = {
    'python': 'python',
    'javascript': 'javascript',
    'typescript': 'typescript',
    'bash': 'bash',
    'sh': 'sh',
    'go': 'go',
    'rust': 'rust',
    'java': 'java',
    'dart': 'dart',
    'py': 'python',
    'python3': 'python',
    'js': 'javascript',
    'node': 'javascript',
    'mjs': 'javascript',
    'ts': 'typescript',
    'shell': 'bash',
    'zsh': 'bash',
    'golang': 'go',
    'rs': 'rust',
  };

  static const _images = {
    'python': 'python',
    'javascript': 'node',
    'typescript': 'node',
    'bash': 'polyglot',
    'sh': 'polyglot',
    'go': 'polyglot',
    'rust': 'polyglot',
    'java': 'polyglot',
    'dart': 'flutter',
  };

  static String? languageOf(String fence) => _languages[fence.trim().toLowerCase()];

  static const _shellWord = r'(?:^|[\s;&|(`!])';
  static final _shellPolyglot =
      RegExp('$_shellWord' r'(?:go|cargo|rustc|rustup|javac|java|mvn|gradle)(?=[\s;&|)`]|$)', multiLine: true);
  static final _shellPython =
      RegExp('$_shellWord' r'(?:pip3?|python3?|pytest|poetry|uv|pipx)(?=[\s;&|)`]|$)', multiLine: true);
  static final _shellNode =
      RegExp('$_shellWord' r'(?:npm|npx|node|yarn|pnpm|tsx|corepack)(?=[\s;&|)`]|$)', multiLine: true);

  static String shellImage(String code) {
    final text = code.replaceAll(RegExp(r'^\s*#.*$', multiLine: true), '');
    if (_shellPolyglot.hasMatch(text)) return 'polyglot';
    final py = _shellPython.hasMatch(text);
    final js = _shellNode.hasMatch(text);
    if (py && !js) return 'python';
    if (js && !py) return 'node';
    return 'polyglot';
  }

  static String? imageFor(String language, {String? code}) =>
      (language == 'bash' || language == 'sh') && code != null ? shellImage(code) : _images[language];

  static bool canRun(RunnerInfo info, String? language, String code) =>
      language != null && info.available && info.image(imageFor(language, code: code)) != null;

  static int clampTimeout(int sec, RunnerImage image) =>
      sec > image.maxTimeoutSec ? image.maxTimeoutSec : sec;

  static List<int> timeoutsFor(RunnerImage image) {
    final out = <int>{for (final s in timeouts) clampTimeout(s, image)}.toList()..sort();
    return out;
  }

  static double maxCredits(RunnerImage image, int timeoutSec) {
    final billed = (timeoutSec / 10).ceil() * 10;
    final milli = ((image.creditsPerMinute * 1000 + 0.5) * billed / 60 - 1e-9).ceil();
    return (milli < 1 ? 1 : milli) / 1000;
  }

  static String safeName(String name) {
    var s = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '_').trim();
    if (s.isEmpty || s == '.' || s == '..') s = 'file';
    if (s.startsWith('~')) s = '_${s.substring(1)}';
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  static List<Map<String, String>> filesPayload(List<SandboxFile> files) {
    final out = <Map<String, String>>[];
    final seen = <String>{};
    var total = 0;
    for (final f in files) {
      if (out.length >= filesMax) break;
      final data = f.data ?? (f.text == null ? null : base64Encode(utf8.encode(f.text!)));
      if (data == null) continue;
      final size = data.length ~/ 4 * 3;
      if (total + size > filesMaxBytes) continue;
      var name = safeName(f.name);
      final base = name;
      for (var n = 2; seen.contains(name); n++) {
        name = '$n-$base';
      }
      seen.add(name);
      total += size;
      out.add({'path': name, 'data': data});
    }
    return out;
  }

  static ServerRunEvent? decodeLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return null;
    try {
      final raw = jsonDecode(text);
      if (raw is! Map || raw['type'] is! String) return null;
      return ServerRunEvent(raw['type'] as String, raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  static String credits(num value) {
    var s = value.toDouble().toStringAsFixed(3);
    while (s.contains('.') && (s.endsWith('0') || s.endsWith('.'))) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String minutes(int sec) => sec % 60 == 0
      ? t('{n} min', {'n': sec ~/ 60})
      : t('{n} s', {'n': sec});

  static Map<String, dynamic> pendingFrom(Map p, String token) => {
        'kind': 'server-run',
        'id': '${p['id'] ?? ''}',
        'image': '${p['image'] ?? ''}',
        'command': '${p['command'] ?? ''}',
        'timeoutSec': p['timeoutSec'] is num ? (p['timeoutSec'] as num).toInt() : 0,
        'maxCredits': p['maxCredits'] is num ? (p['maxCredits'] as num).toDouble() : 0.0,
        if (p['repo'] is String && (p['repo'] as String).isNotEmpty) 'repo': p['repo'],
        if (p['team'] == true) 'team': true,
        'token': token,
        'state': 'waiting',
      };

  static List<Map<String, dynamic>> runsOf(Object? raw) => [
        for (final r in (raw is List ? raw : const []))
          if (r is Map)
            {
              'image': '${r['image'] ?? ''}',
              'command': '${r['command'] ?? ''}',
              'milli': r['milli'] is num ? (r['milli'] as num).toInt() : 0,
              'billedMs': r['billedMs'] is num ? (r['billedMs'] as num).toInt() : 0,
              'code': r['code'] is num ? (r['code'] as num).toInt() : null,
              'ok': r['ok'] == true,
            },
      ].take(20).toList();
}
