import 'dart:convert';

enum ScheduleRepeat { once, hourly, daily, weekly }

/// A prompt sent on a schedule, run in the app while open; a missed run catches up once.
class Schedule {
  Schedule({
    required this.id,
    this.title = '',
    this.prompt = '',
    this.repeat = ScheduleRepeat.daily,
    DateTime? nextAt,
    this.convId,
    this.enabled = true,
    this.runs = 0,
    this.lastRunAt,
    this.lastConvId,
    DateTime? createdAt,
    this.server,
    this.serverCap = 5,
    this.serverSha,
    this.serverExpiresAt = 0,
    this.serverError,
    this.serverOff = false,
    this.serverSeenAt = 0,
  })  : nextAt = nextAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();

  final String id;
  String title;
  String prompt;
  ScheduleRepeat repeat;
  DateTime nextAt;
  String? convId;
  bool enabled;
  int runs;
  DateTime? lastRunAt;
  String? lastConvId;
  final DateTime createdAt;
  String? server;
  int serverCap;
  String? serverSha;
  int serverExpiresAt;
  String? serverError;
  bool serverOff;
  int serverSeenAt;

  bool get due => enabled && !nextAt.isAfter(DateTime.now());

  Duration? get step => switch (repeat) {
        ScheduleRepeat.hourly => const Duration(hours: 1),
        ScheduleRepeat.daily => const Duration(days: 1),
        ScheduleRepeat.weekly => const Duration(days: 7),
        ScheduleRepeat.once => null,
      };

  /// Moves to the next slot after now so missed slots do not queue up.
  void advance() {
    runs += 1;
    lastRunAt = DateTime.now();
    final s = step;
    if (s == null) {
      enabled = false;
      return;
    }
    var next = nextAt.add(s);
    final now = DateTime.now();
    while (!next.isAfter(now)) {
      next = next.add(s);
    }
    nextAt = next;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'prompt': prompt,
        'repeat': repeat.name,
        'nextAt': nextAt.millisecondsSinceEpoch,
        'convId': convId,
        'enabled': enabled,
        'runs': runs,
        'lastRunAt': lastRunAt?.millisecondsSinceEpoch,
        'lastConvId': lastConvId,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'server': server,
        'serverCap': serverCap,
        if (serverSha != null) 'serverSha': serverSha,
        if (serverExpiresAt > 0) 'serverExpiresAt': serverExpiresAt,
        if (serverError != null) 'serverError': serverError,
        if (serverOff) 'serverOff': true,
        if (serverSeenAt > 0) 'serverSeenAt': serverSeenAt,
      };

  static Schedule fromJson(Map<String, dynamic> j) => Schedule(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        prompt: j['prompt'] as String? ?? '',
        repeat: ScheduleRepeat.values.firstWhere(
          (r) => r.name == j['repeat'],
          orElse: () => ScheduleRepeat.daily,
        ),
        nextAt: DateTime.fromMillisecondsSinceEpoch(
            (j['nextAt'] as num?)?.toInt() ?? 0),
        convId: j['convId'] as String?,
        enabled: j['enabled'] as bool? ?? true,
        runs: (j['runs'] as num?)?.toInt() ?? 0,
        lastRunAt: j['lastRunAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (j['lastRunAt'] as num).toInt()),
        lastConvId: j['lastConvId'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
        server: j['server'] == 'notify' || j['server'] == 'run'
            ? j['server'] as String
            : null,
        serverCap: j['serverCap'] is num && (j['serverCap'] as num) > 0
            ? (j['serverCap'] as num).toInt()
            : 5,
        serverSha: j['serverSha'] is String ? j['serverSha'] as String : null,
        serverExpiresAt: (j['serverExpiresAt'] as num?)?.toInt() ?? 0,
        serverError:
            j['serverError'] is String ? j['serverError'] as String : null,
        serverOff: j['serverOff'] == true,
        serverSeenAt: (j['serverSeenAt'] as num?)?.toInt() ?? 0,
      );

  static String encodeList(List<Schedule> list) =>
      jsonEncode(list.map((s) => s.toJson()).toList());

  static List<Schedule> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Schedule.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
