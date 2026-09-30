import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class FreeAllowance {
  const FreeAllowance({
    required this.used,
    required this.limit,
    required this.left,
    required this.resetsAt,
    this.netSpent = false,
  });

  final int used;
  final int limit;
  final int left;
  final int resetsAt;

  /// True when the network, not this key, used today's replies.
  final bool netSpent;

  static FreeAllowance? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final limit = (raw['limit'] as num?)?.toInt() ?? 0;
    if (limit <= 0) return null;
    return FreeAllowance(
      used: (raw['used'] as num?)?.toInt() ?? 0,
      limit: limit,
      left: (raw['left'] as num?)?.toInt() ?? 0,
      resetsAt: (raw['resetsAt'] as num?)?.toInt() ?? 0,
      netSpent: raw['netSpent'] == true,
    );
  }
}

/// Device-local speed bump on free replies across keys; must never be reported to the worker, which would link keys.
class FreeTier {
  FreeTier(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'nymbot_free_device';

  // UTC, matching the worker's reset.
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
      // Fails open; the worker enforces the allowance.
      return 0;
    }
  }

  Future<void> _write(int n) async {
    try {
      await _prefs.setString(_key, jsonEncode({'day': _today(), 'used': n}));
    } catch (_) {
      // Best effort.
    }
  }

  int leftOf(int limit) => limit <= 0 ? 0 : (limit - used).clamp(0, limit);

  /// A paid balance is never gated by this.
  bool allows(int limit, int balance) {
    if (balance > 0) return true;
    if (limit <= 0) return true;
    return used < limit;
  }

  Future<void> spent() => _write(used + 1);

  /// Adopts the worker's count when higher, never revising downward.
  Future<void> observe(int seen) async {
    if (seen > used) await _write(seen);
  }

  /// Only for tests or a forget-me request.
  Future<void> forget() async {
    try {
      await _prefs.remove(_key);
    } catch (_) {
      // Best effort.
    }
  }
}
