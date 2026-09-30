import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../features/i18n/i18n.dart';
import '../models/schedule.dart';

class ServerSchedules {
  ServerSchedules._();

  static const limit = 10;
  static const maxDays = 90;
  static const defaultCap = 5;
  static const defaultDaily = 50;
  static const runCaps = [1, 2, 5, 10, 25, 50];
  static const dailyCaps = [10, 25, 50, 100, 250];
  static const slotsMax = 48;
  static const lookBack = Duration(hours: 48);

  static String payload(Schedule s,
      {required String mode,
      required String thread,
      String model = '',
      String tier = 'standard'}) {
    final run = mode == 'run';
    final prompt = s.prompt.length > 4000 ? s.prompt.substring(0, 4000) : s.prompt;
    final title = s.title.length > 120 ? s.title.substring(0, 120) : s.title;
    return jsonEncode({
      'repeat': s.repeat.name,
      'nextAt': s.nextAt.millisecondsSinceEpoch,
      if (run) 'prompt': prompt,
      if (run) 'title': title,
      'thread': thread,
      if (run) 'model': model,
      'tier': run && model.isNotEmpty ? 'pro' : (run ? tier : 'standard'),
    });
  }

  static String sha(String payload) =>
      crypto.sha256.convert(utf8.encode(payload)).toString();

  static Map<String, dynamic> body(Schedule s,
      {required String mode,
      required String payload,
      required int dailyCap,
      required int now,
      Map<String, dynamic>? push}) {
    final expires = now + const Duration(days: maxDays).inMilliseconds - 60000;
    final cap = s.serverCap <= 0 ? defaultCap : (s.serverCap > 1000 ? 1000 : s.serverCap);
    return {
      'id': s.id,
      'mode': mode,
      'sha256': sha(payload),
      'expiresAt': expires,
      if (mode == 'run') 'maxCreditsPerRun': cap,
      'dailyCap': dailyCap.clamp(1, 10000),
      'payload': payload,
      if (push != null) 'push': push,
    };
  }

  static String consent(int n) => t(
      "When this is on, Nymbot's server keeps a copy of this scheduled prompt and its settings, sealed with a key the server holds, so it can run it at the set time while your app is closed. The server can read it when it runs, the same as any message you send. It spends up to {n} credits per run from your balance. Turning this off, deleting the schedule, or wiping the app deletes the server copy at once.",
      {'n': n});

  static String dueText() => t('A scheduled prompt is due. Open Nymbot to run it.');

  static String disabledText() =>
      t('A server schedule was turned off after failing 3 times in a row.');

  static String savedRun() => t('Saved. The server will run it while the app is closed.');

  static String savedNotify() => t('Saved. The server will notify you when it is due.');

  static String noPush() => t(
      'Notifications are off for this app, so the server cannot tell you when it is due. Allow notifications first.');

  static String unavailable() => t(
      'Server schedules are not available right now, so this one runs only while the app is open.');

  static String? refusal(int status, Map<String, dynamic> data) {
    if (status == 200 && data['ok'] == true) return null;
    if (status == 409 || data['limit'] != null) {
      return t('The server keeps up to 10 schedules. Delete one first, or keep this one on this device.');
    }
    if (data['noCredits'] == true || status == 402) {
      return t('Server schedules spend your paid balance, which is empty. Top up first.');
    }
    if (status == 503 || data['unavailable'] == true || status == 0 || status == 404 ||
        data['error'] == 'Unknown action') {
      return unavailable();
    }
    final error = data['error'];
    return t('The server could not take this schedule: {error}',
        {'error': error is String && error.isNotEmpty ? error : t('The request failed.')});
  }

  static int? _step(ScheduleRepeat r) => switch (r) {
        ScheduleRepeat.hourly => const Duration(hours: 1).inMilliseconds,
        ScheduleRepeat.daily => const Duration(days: 1).inMilliseconds,
        ScheduleRepeat.weekly => const Duration(days: 7).inMilliseconds,
        ScheduleRepeat.once => null,
      };

  static List<int> firedSlots(Schedule s,
      {required int serverNextAt, required int since, int? now}) {
    final base = s.nextAt.millisecondsSinceEpoch;
    final step = _step(s.repeat);
    final at = now ?? DateTime.now().millisecondsSinceEpoch;
    final floor = at - lookBack.inMilliseconds;
    if (step == null) {
      return base > since && base <= at && base >= floor ? [base] : const [];
    }
    final out = <int>[];
    var slot = base;
    if (slot < floor) slot += ((floor - slot) / step).ceil() * step;
    while (slot < serverNextAt && slot <= at && out.length < slotsMax) {
      if (slot > since) out.add(slot);
      slot += step;
    }
    return out;
  }

  static String eventIdFor(String id, int firedAt) =>
      crypto.sha256.convert(utf8.encode('nymsched-event|$id|$firedAt')).toString();

  static String until(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static String rowLine(Schedule s) {
    if (s.server == null) return '';
    if (s.serverOff) {
      return t('The server stopped running this after 3 failures in a row. Save it again to retry.');
    }
    if (s.serverSha == null) return s.serverError ?? '';
    if (s.server == 'run') {
      return t('Runs on the server until {date}', {'date': until(s.serverExpiresAt)});
    }
    if (s.server == 'notify') {
      return t('Notifies you when due until {date}', {'date': until(s.serverExpiresAt)});
    }
    return '';
  }

  static ({String id, int firedAt})? tagOf(Map<String, dynamic>? rumor) {
    final tags = rumor?['tags'];
    if (tags is! List) return null;
    for (final tag in tags) {
      if (tag is List && tag.length > 2 && tag[0] == 'nymsched' && tag[1] is String) {
        final at = int.tryParse('${tag[2]}');
        if (at != null) return (id: tag[1] as String, firedAt: at);
      }
    }
    return null;
  }
}
