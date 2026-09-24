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
