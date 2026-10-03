import 'dart:convert';

import '../features/i18n/i18n.dart';

class PrWatch {
  PrWatch._();

  static const fixModes = ['off', 'ask', 'auto'];
  static const fixDefault = 'ask';
  static const capDefault = 20;
  static const capChoices = [5, 10, 20, 50, 100];
  static const max = 5;
  static const listEvery = Duration(milliseconds: 120000);
  static const peekEvery = Duration(milliseconds: 120000);
  static const recordsMax = 20;
  static const storeKey = 'pr_watches';
  static const kinds = [
    'ci-failed',
    'ci-passed',
    'review',
    'merged',
    'closed',
    'auth',
    'expired',
    'gone',
    'limit',
    'fix',
  ];
  static const stages = <String, String>{
    'ci-failed': 'ci-failed',
    'ci-passed': 'ci-passed',
    'review': 'review',
    'merged': 'merged',
    'closed': 'closed',
    'fix': 'fix',
    'auth': 'stopped',
    'expired': 'stopped',
    'gone': 'stopped',
    'limit': 'stopped',
  };

  static final _sha = RegExp(r'^[0-9a-fA-F]{40,64}$');
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _id = RegExp(r'^[0-9a-f]{32}$');

  static String repoChoice(Object? raw) => raw == 'on' || raw == 'off' ? raw as String : '';

  static bool watchOn(Object? repo, bool defaultOn) {
    final own = repoChoice(repo);
    return own.isNotEmpty ? own == 'on' : defaultOn;
  }

  static String fixMode(Object? raw) =>
      raw is String && fixModes.contains(raw) ? raw : fixDefault;

  static int fixCap(Object? raw) {
    final n = raw is num ? raw : (raw is String ? num.tryParse(raw) : null);
    if (n == null || !n.isFinite || n <= 0 || n > 1000) return capDefault;
    return n.toInt();
  }

  static int pullNo(Map? job) {
    final pull = job?['pull'];
    if (pull is! Map) return 0;
    final n = pull['number'];
    final v = n is num ? n : num.tryParse('${n ?? ''}');
    if (v == null || v != v.roundToDouble() || v < 1) return 0;
    return v.toInt();
  }

  static bool canWatch(Map? job) =>
      job != null &&
      pullNo(job) > 0 &&
      job['merged'] != true &&
      job['closed'] != true &&
      job['deleted'] != true &&
      job['done'] != false;

  static String keyOf(Object? repo, Object? branch) => '${repo ?? ''}#${branch ?? ''}';

  static String liveText(Map? live) {
    if (live == null) return '';
    if (live['pr'] == 'merged' || live['state'] == 'merged') return t('Merged.');
    if (live['pr'] == 'closed' || live['state'] == 'closed') {
      return t('Closed without merging.');
    }
    final bits = <String>[];
    switch (live['ci']) {
      case 'failing':
        bits.add(t('CI failing'));
      case 'passing':
        bits.add(t('CI passing'));
      case 'running':
        bits.add(t('CI running'));
    }
    final raw = live['comments'];
    final n = raw is num ? raw.toInt() : 0;
    if (n > 0) {
      bits.add(n == 1 ? t('1 review comment') : t('{n} review comments', {'n': n}));
    }
    if (live['state'] == 'stopped') bits.add(t('No longer watched.'));
    return bits.join(' · ');
  }

  static Map<String, dynamic> watchBody(
    Map<String, dynamic> git,
    Map job, {
    String? thread,
    String? fix,
    num? cap,
    String? model,
    String? planFirst,
    Map<String, dynamic>? push,
  }) {
    final mode = fixModes.contains(fix) ? fix! : fixDefault;
    final m = model ?? '';
    final sha = '${job['sha'] ?? ''}';
    return {
      'git': git,
      'watch': {
        'number': pullNo(job),
        'branch': '${job['branch'] ?? job['head'] ?? ''}',
        'base': '${job['base'] ?? ''}',
        'sha': _sha.hasMatch(sha) ? sha : '',
        'thread': _hex64.hasMatch(thread ?? '') ? thread : '',
        'fix': mode != 'off' && m.isEmpty ? 'off' : mode,
        'cap': cap != null && cap > 0 ? cap : capDefault,
        'model': mode != 'off' ? m : '',
        'planFirst': const ['always', 'changing', 'never'].contains(planFirst) ? planFirst : 'changing',
        'push': ?push,
      },
    };
  }

  static List<Map<String, dynamic>> fresh(Map? watch, int seen) {
    final raw = watch?['events'];
    final out = <Map<String, dynamic>>[
      for (final e in (raw is List ? raw : const []))
        if (e is Map && e['seq'] is num && (e['seq'] as num) > seen && kinds.contains(e['kind']))
          e.cast<String, dynamic>(),
    ]..sort((a, b) => (a['seq'] as num).compareTo(b['seq'] as num));
    return out;
  }

  static String stageOf(Object? kind) => stages[kind] ?? '';

  static Map<String, dynamic> eventMessage(Map watch, Map ev) => {
        'id': watch['id'],
        'kind': ev['kind'],
        'seq': ev['seq'],
        'number': watch['number'],
        'repo': watch['repo'],
        'branch': watch['branch'],
        if (ev['offer'] == true) 'offer': true,
      };

  static List<Map<String, dynamic>> decodeRecords(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [
        for (final r in list)
          if (r is Map && _id.hasMatch('${r['id'] ?? ''}') && r['convId'] is String)
            r.cast<String, dynamic>(),
      ];
    } catch (_) {
      return [];
    }
  }

  static String encodeRecords(List<Map<String, dynamic>> list) => jsonEncode(
      list.length > recordsMax ? list.sublist(list.length - recordsMax) : list);

  static String fixHint(String branch, int cap) => t(
      'Nymbot can try a fix on {branch}. It goes through your plan setting and spends at most {n} credits.',
      {'branch': branch, 'n': cap});

  static String fixLabel(String mode) => switch (mode) {
        'off' => t('Off'),
        'auto' => t('Start a fix run'),
        _ => t('Ask me first'),
      };
}
