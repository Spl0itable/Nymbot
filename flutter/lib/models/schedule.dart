import 'dart:convert';

enum ScheduleRepeat { once, hourly, daily, weekly }

/// A prompt Nymbot sends for you on a schedule. There is no server doing this:
/// a run happens in the app while it is open, which is why a missed run catches
/// up once rather than firing for every slot it went past.
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
    DateTime? createdAt,
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
  final DateTime createdAt;

  bool get due => enabled && !nextAt.isAfter(DateTime.now());

  Duration? get step => switch (repeat) {
        ScheduleRepeat.hourly => const Duration(hours: 1),
        ScheduleRepeat.daily => const Duration(days: 1),
        ScheduleRepeat.weekly => const Duration(days: 7),
        ScheduleRepeat.once => null,
      };

  /// Forward to the next slot after now, so a run missed while the app was shut
  /// does not queue up every slot it went past.
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
        'createdAt': createdAt.millisecondsSinceEpoch,
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
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
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
