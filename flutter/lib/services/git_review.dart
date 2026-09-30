import '../features/i18n/i18n.dart';

const int maxStallResumes = 3;
const Duration _defaultStall = Duration(seconds: 20);
const Duration _minStall = Duration(seconds: 1);
const Duration _maxStall = Duration(minutes: 2);

Duration? stallWait({
  required bool stalled,
  required bool truncated,
  required String? resumeToken,
  required int retryAfterMs,
}) {
  if (!stalled || !truncated || resumeToken == null || resumeToken.isEmpty) {
    return null;
  }
  final wait =
      retryAfterMs > 0 ? Duration(milliseconds: retryAfterMs) : _defaultStall;
  if (wait < _minStall) return _minStall;
  if (wait > _maxStall) return _maxStall;
  return wait;
}

String stallLine(Duration left, int attempt) {
  final seconds = (left.inMilliseconds / 1000).ceil();
  return t(
      'The gateway is busy. Resuming by itself in {n}s (try {try} of {of}). Stop cancels it.',
      {
        'n': seconds < 1 ? 1 : seconds,
        'try': attempt,
        'of': maxStallResumes,
      });
}

List<Map<String, dynamic>> allStaged(Map<String, dynamic>? staged) {
  if (staged == null) return const [];
  final also = (staged['also'] as List?)?.whereType<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  return [staged, ...also];
}

String stagedStats(Map<String, dynamic> staged) {
  final stats = staged['stats'] is Map ? staged['stats'] as Map : const {};
  final files = (stats['files'] as num?)?.toInt() ??
      ((staged['files'] as List?)?.length ?? 0);
  final bits = <String>[
    files == 1 ? t('1 file changed') : t('{n} files changed', {'n': files}),
    if (stats['added'] != null) '+${(stats['added'] as num).toInt()}',
    if (stats['removed'] != null) '−${(stats['removed'] as num).toInt()}',
  ];
  return bits.join(' · ');
}

Map<String, dynamic> stagedRequest(Map<String, dynamic> staged) => {
      'repo': staged['repo'],
      'branch': staged['branch'],
      'baseSha': staged['baseSha'],
      'message': staged['message'] ?? '',
      'files': staged['files'] ?? const [],
    };

Map<String, dynamic> settledStaged(Map<String, dynamic> staged, String how) => {
      'repo': staged['repo'],
      'branch': staged['branch'],
      'message': staged['message'] ?? '',
      if (staged['stats'] != null) 'stats': staged['stats'],
      'diff': staged['diff'] ?? '',
      if (how == 'applied') 'applied': true,
      if (how == 'discarded') 'discarded': true,
      if (staged['also'] is List)
        'also': (staged['also'] as List)
            .whereType<Map<String, dynamic>>()
            .map((s) => settledStaged(s, how))
            .toList(),
    };

Map<String, dynamic>? checkpointOfApplied(List<Map<String, dynamic>> marks) {
  if (marks.isEmpty) return null;
  return {
    ...marks.first,
    if (marks.length > 1) 'also': marks.sublist(1),
  };
}

const String whenDoneDefault = 'pr';
const List<String> whenDoneOptions = ['pr', 'merge', 'leave'];
const int branchRecordsMax = 50;
const Duration branchCleanupEvery = Duration(hours: 6);

bool isJobBranch(Object? name) =>
    name is String && RegExp(r'^nymbot/[0-9a-f]{8,64}$').hasMatch(name);

List<Map<String, dynamic>> branchStepsOf(Iterable<Object?> raw) {
  final out = <Map<String, dynamic>>[];
  for (final s in raw) {
    if (s is! Map || !isJobBranch(s['branch']) || s['repo'] is! String) continue;
    final sha = '${s['sha'] ?? ''}';
    if (!RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(sha)) continue;
    final one = <String, dynamic>{
      'repo': s['repo'],
      'branch': s['branch'],
      'base': '${s['base'] ?? ''}',
      'sha': sha,
    };
    final at = out.indexWhere((x) => x['branch'] == one['branch']);
    if (at == -1) {
      out.add(one);
    } else {
      out[at] = one;
    }
  }
  return out.length > 4 ? out.sublist(0, 4) : out;
}

String whenDoneOf(Object? raw) =>
    raw is String && whenDoneOptions.contains(raw) ? raw : '';

String whenDoneFor(String repoChoice, String settingsChoice) {
  final own = whenDoneOf(repoChoice);
  if (own.isNotEmpty) return own;
  final global = whenDoneOf(settingsChoice);
  return global.isNotEmpty ? global : whenDoneDefault;
}

String whenDoneLabel(String choice) {
  switch (choice) {
    case 'merge':
      return t('Offer a merge');
    case 'leave':
      return t('Leave the branch');
    default:
      return t('Open a pull request');
  }
}

List<Map<String, dynamic>> jobsOf(Map<String, dynamic>? mark) {
  if (mark == null) return const [];
  final marks = <Map<String, dynamic>>[
    mark,
    ...((mark['also'] as List?)?.whereType<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[]),
  ];
  final out = <Map<String, dynamic>>[];
  for (final m in marks) {
    final job = m['job'];
    if (job is Map && job['branch'] is String) {
      out.add({'repo': m['repo'], ...Map<String, dynamic>.from(job)});
    }
  }
  return out;
}

List<Map<String, dynamic>> rememberBranch(
    List<Map<String, dynamic>> list, Map<String, dynamic> job,
    {int? now}) {
  final pull = job['pull'];
  final out = list.where((r) => r['branch'] != job['branch']).toList()
    ..add({
      'branch': job['branch'],
      'base': job['base'] ?? '',
      'sha': job['sha'] ?? '',
      'pull': pull is Map && pull['number'] != null
          ? {'number': pull['number'], 'url': pull['url'] ?? ''}
          : null,
      'at': now ?? DateTime.now().millisecondsSinceEpoch,
      'owner': job['owner'] is String &&
              RegExp(r'^[0-9a-f]{64}$').hasMatch(job['owner'] as String)
          ? job['owner']
          : null,
    });
  return out.length > branchRecordsMax
      ? out.sublist(out.length - branchRecordsMax)
      : out;
}

List<Map<String, dynamic>> forgetBranches(
        List<Map<String, dynamic>> list, Iterable<Object?> names) {
  final drop = names.map((e) => '$e').toSet();
  return list.where((r) => !drop.contains(r['branch'])).toList();
}

String branchState(Map<String, dynamic> job) {
  final base = '${job['base'] ?? ''}';
  final pull = job['pull'];
  if (job['deleted'] == true) return t('Branch deleted.');
  if (job['ended'] != null &&
      job['merged'] != true &&
      !(pull is Map && pull['number'] != null)) {
    return t('The task ended early. The branch keeps what it committed.');
  }
  if (job['merged'] == true) return t('Merged into {base}.', {'base': base});
  if (job['conflict'] == true) {
    return t('This branch conflicts with {base}.', {'base': base});
  }
  if (job['fallback'] == 'no-api') {
    return t('This forge has no pull request API Nymbot can use, so the branch was left as it is.');
  }
  if (job['fallback'] == 'failed') {
    return t('The pull request could not be opened, so the branch was left as it is.');
  }
  if (job['done'] == false) return t('The task is still working on this branch.');
  if (pull is Map && pull['number'] != null) {
    return t('Pull request #{n} is open.', {'n': pull['number']});
  }
  if (job['whenDone'] == 'merge') {
    return t('Ready to merge into {base}.', {'base': base});
  }
  return t('Left on its own branch for you to review.');
}

Map<String, dynamic> patchJob(
    Map<String, dynamic> mark, String branch, Map<String, dynamic> patch) {
  Map<String, dynamic> fix(Map<String, dynamic> m) {
    final job = m['job'];
    if (job is Map && job['branch'] == branch) {
      final next = {...Map<String, dynamic>.from(job), ...patch}
        ..removeWhere((k, v) => v == null);
      return {...m, 'job': next};
    }
    return m;
  }

  final out = fix(mark);
  if (mark['also'] is List) {
    out['also'] = (mark['also'] as List)
        .whereType<Map<String, dynamic>>()
        .map(fix)
        .toList();
  }
  return out;
}
