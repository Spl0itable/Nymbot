import '../features/i18n/i18n.dart';

class BackgroundRun {
  BackgroundRun({
    required this.runId,
    required this.conv,
    required this.until,
    Set<String>? claimed,
    int? startedAt,
    Map<String, dynamic>? last,
  })  : last = last ?? <String, dynamic>{},
        claimed = claimed ?? <String>{},
        startedAt = startedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String runId;
  final String conv;
  final int until;
  final Set<String> claimed;
  final int startedAt;
  Map<String, dynamic> last;

  Map<String, dynamic> toJson() => {
        'runId': runId,
        'conv': conv,
        'until': until,
        'claimed': claimed.toList(),
        'startedAt': startedAt,
        if (last.isNotEmpty) 'last': last,
      };

  static BackgroundRun? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['runId'];
    final conv = raw['conv'];
    if (id is! String || id.isEmpty || conv is! String) return null;
    return BackgroundRun(
      runId: id,
      conv: conv,
      until: (raw['until'] as num?)?.toInt() ?? 0,
      claimed: {
        for (final c in (raw['claimed'] is List ? raw['claimed'] as List : const []))
          if (c is String) c,
      },
      startedAt: (raw['startedAt'] as num?)?.toInt(),
      last: raw['last'] is Map
          ? (raw['last'] as Map).cast<String, dynamic>()
          : null,
    );
  }
}

class BackgroundJobs {
  BackgroundJobs._();

  static const maxLegs = 40;
  static const hours = 6;
  static const keepAfter = Duration(hours: 24);
  static const runsKey = 'bg_runs';

  static bool eligible({
    required bool anon,
    required bool ghost,
    required bool pro,
    double? proBalance,
    double? standardBalance,
    required double budget,
    bool long = false,
  }) {
    if (anon || ghost) return false;
    final paid = pro ? (proBalance ?? 0) > 0 : (standardBalance ?? 0) > 0;
    if (!paid) return false;
    return budget > 0 || long;
  }

  static Map<String, dynamic>? grant({
    required bool? optedIn,
    required bool anon,
    required bool ghost,
    required bool pro,
    double? proBalance,
    double? standardBalance,
    required double budget,
    bool long = false,
    Map<String, dynamic>? notify,
  }) {
    if (optedIn != true) return null;
    if (!eligible(
        anon: anon,
        ghost: ghost,
        pro: pro,
        proBalance: proBalance,
        standardBalance: standardBalance,
        budget: budget,
        long: long)) {
      return null;
    }
    final credits = budget.isFinite && budget > 0 ? budget.floor() : 0;
    return {
      if (budget > 0 && budget.isFinite) 'maxCredits': credits < 1 ? 1 : credits,
      'maxLegs': maxLegs,
      'notify': ?notify,
    };
  }

  static ({String runId, int until})? handover(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['runId'];
    if (id is! String || id.isEmpty) return null;
    return (runId: id, until: (raw['until'] as num?)?.toInt() ?? 0);
  }

  static String pushText() => t('Your task is done');

  static String promptTitle() => t('Keep long tasks going while the app is closed?');

  static String promptBody(double? credits, {bool own = false}) {
    final spend = own || credits == null || credits <= 0
        ? t("It spends no more than this task's own credit limit and deletes it all when the task ends.")
        : t('It spends up to {n} credits on this task and deletes it all when the task ends.',
            {'n': credits.floor() < 1 ? 1 : credits.floor()});
    return '${t("This task needs more steps than one turn holds. Nymbot's server can carry it on by itself, so it finishes even if you close the app. To do that, the server keeps what the next step needs, sealed with a key the server holds, for at most 6 hours: the task's saved progress and its settings, including the tokens for the repositories and connectors it uses.")} '
        '$spend ${t('You can change this at any time in Settings.')}';
  }

  static String promptConfirm() => t('Keep going on the server');

  static String promptCancel() => t('Keep it on this device');

  static String cardLabel() => t('Working in the background');

  static String cardStatus() =>
      t("You can close the app. Nymbot's server carries this on for up to 6 hours.");

  static String listMeta() => t('In the background');

  static String? endNote(String state, {Map<String, dynamic>? body}) {
    switch (state) {
      case 'done':
        return t('Finished in the background.');
      case 'failed':
        return t('That task failed in the background. Nothing more was charged.');
      case 'stopped':
        return t('Stopped.');
      case 'parked':
        final b = body ?? const <String, dynamic>{};
        if (b['noCredits'] == true) {
          return t('Paused in the background: you are out of credits. Top up, then ask it to carry on.');
        }
        if (b['capExceeded'] == true) {
          return t("Paused in the background: carrying on could go past this chat's spending cap.");
        }
        final bg = b['background'];
        final reason = bg is Map ? bg['reason'] : null;
        if (reason == 'legs') {
          return t('Paused: the task took the most steps one background run may take.');
        }
        if (reason == 'credits') {
          return t('Paused: the task spent the credit limit it had for running in the background.');
        }
        if (reason == 'time') {
          return t('Paused: the task reached the 6-hour limit for running in the background.');
        }
        return t('Paused. Open the chat to carry on.');
    }
    return null;
  }

  static const ended = {'done', 'failed', 'stopped', 'parked', 'waiting'};

  static List<String> legsOf(Object? raw) => [
        for (final l in (raw is List ? raw : const []))
          if (l is String && l.isNotEmpty) l,
      ];
}
