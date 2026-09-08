import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What the day's free allowance has left, as the worker sees it.
class FreeAllowance {
  const FreeAllowance({
    required this.used,
    required this.limit,
    required this.left,
    required this.resetsAt,
  });

  final int used;
  final int limit;
  final int left;
  final int resetsAt;

  static FreeAllowance? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final limit = (raw['limit'] as num?)?.toInt() ?? 0;
    if (limit <= 0) return null;
    return FreeAllowance(
      used: (raw['used'] as num?)?.toInt() ?? 0,
      limit: limit,
      left: (raw['left'] as num?)?.toInt() ?? 0,
      resetsAt: (raw['resetsAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The free daily allowance, as this device sees it.
///
/// The real count is the worker's: it is claimed under the same lock every
/// balance moves under, and nothing here can grant a reply the worker will not.
/// What this adds is a count of what THIS DEVICE has used today, whatever key
/// was signed in at the time — because the server's count is keyed to a pubkey,
/// and generating another pubkey is a tap in this app's own gate.
///
/// It is deliberately a speed bump and not a control. Clearing the app's data
/// walks straight past it, and that is fine: the point is that "sign out, make
/// a new key, keep going" does not work by simply doing it.
///
/// The one thing it must never do is tell the worker about itself. A device
/// counter reported to the server would link a person's keys to each other,
/// which is the exact thing this app is built not to do — a stronger cap bought
/// with the product's whole premise. So it stays here, the app declines to
/// offer a free reply, and the worker never learns a device exists.
class FreeTier {
  FreeTier(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'nymbot_free_device';

  // The day is UTC, because that is what the worker resets on and two
  // different midnights would be worse than one inconvenient one.
  static String _today() =>
      DateTime.now().toUtc().toIso8601String().substring(0, 10);

  int get used {
    try {
      final raw = _prefs.getString(_key);
      if (raw == null || raw.isEmpty) return 0;
      final held = jsonDecode(raw);
      if (held is! Map || held['day'] != _today()) return 0;
      final n = (held['used'] as num?)?.toInt() ?? 0;
      return n < 0 ? 0 : n;
    } catch (_) {
      // The allowance is the worker's to enforce, so this failing open is the
      // right way for it to fail.
      return 0;
    }
  }

  Future<void> _write(int n) async {
    try {
      await _prefs.setString(_key, jsonEncode({'day': _today(), 'used': n}));
    } catch (_) {
      // Best effort by design.
    }
  }

  int leftOf(int limit) => limit <= 0 ? 0 : (limit - used).clamp(0, limit);

  /// Whether this device still has a free reply in it. A balance is never
  /// gated by this: someone who has paid is not on the free tier at all, and
  /// must never be told they are.
  bool allows(int limit, int balance) {
    if (balance > 0) return true;
    if (limit <= 0) return true;
    return used < limit;
  }

  /// One free reply came back. Counted here whichever key asked for it.
  Future<void> spent() => _write(used + 1);

  /// The worker is the authority on the key's own count, so when it says more
  /// has been used than this device has seen, this device believes it — a
  /// second device, or the same one after its data was cleared. It never
  /// revises the count downwards, which is what would make a fresh key reset
  /// the device.
  Future<void> observe(int seen) async {
    if (seen > used) await _write(seen);
  }

  /// Only for a test, or for someone who asked to be forgotten.
  Future<void> forget() async {
    try {
      await _prefs.remove(_key);
    } catch (_) {
      // Best effort by design.
    }
  }
}
