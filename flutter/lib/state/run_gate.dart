import 'dart:math' as math;

class RunGate {
  static Duration gap = const Duration(minutes: 2);
  static Duration spread = const Duration(minutes: 3);
  static int Function(int top)? draw;
  static int Function()? clock;
  static final math.Random _rng = math.Random.secure();

  RunGate({this.shown});

  final bool Function(bool anon)? shown;

  final Map<bool, int> _at = {false: 0, true: 0};
  final Map<bool, int> _due = {false: 0, true: 0};
  int _sock = 0;
  int _sockAt = 0;

  int _now() => clock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  int _spread() {
    final top = spread.inMilliseconds;
    if (top <= 0) return 0;
    final pick = draw?.call(top) ?? _rng.nextInt(top);
    return pick.clamp(0, top);
  }

  bool _busy(bool anon, int now) => _due[anon]! > 0 && now < _due[anon]! + gap.inMilliseconds;

  int at(bool anon) => _at[anon]!;

  int due(bool anon) => _due[anon]!;

  int get sock => _sock;

  bool _near(int t) {
    final g = gap.inMilliseconds;
    return (_sockAt > 0 && (t - _sockAt).abs() < g) || (_sock > 0 && (t - _sock).abs() < g);
  }

  void _settle(bool anon, int now) {
    final s = shown;
    if (s != null && _due[anon]! > 0 && _due[anon]! <= now && !s(anon)) _due[anon] = 0;
  }

  void release(bool anon, int due) {
    if (due > 0 && _due[anon] == due) _due[anon] = 0;
  }

  bool ready(bool anon) {
    final now = _now();
    _settle(!anon, now);
    return now - _at[!anon]! >= gap.inMilliseconds && !_busy(!anon, now) && _due[anon]! <= now && !_near(now);
  }

  int hold(bool anon) {
    final now = _now();
    if (_due[anon]! > now) return _due[anon]!;
    _settle(!anon, now);
    if (_busy(!anon, now)) return 0;
    final g = gap.inMilliseconds;
    var at = math.max(now, _at[!anon]!) + g + _spread();
    for (final x in [_sockAt, _sock]) {
      if (x > 0 && (at - x).abs() < g) at = x + g + _spread();
    }
    _due[anon] = at;
    return at;
  }

  int slot() {
    final now = _now();
    final g = gap.inMilliseconds;
    var from = math.max(now, math.max(_at[false]!, _at[true]!));
    for (final side in const [false, true]) {
      _settle(side, now);
      final d = _due[side]!;
      if (d > 0 && now < d + g) from = math.max(from, d);
    }
    _sock = from + g + _spread();
    return _sock - now;
  }

  bool free() {
    final now = _now();
    final g = gap.inMilliseconds;
    for (final side in const [false, true]) {
      _settle(side, now);
      final d = _due[side]!;
      if (now - _at[side]! < g || (d > 0 && (now - d).abs() < g)) return false;
    }
    return true;
  }

  void acted(bool anon, {bool waited = false}) {
    stamp(anon);
    if (!waited) return;
    _sockAt = _now();
    _sock = 0;
  }

  void stamp(bool anon) {
    final now = _now();
    _at[anon] = math.max(_at[anon]!, now);
    if (_due[anon]! > 0 && now >= _due[anon]!) _due[anon] = 0;
  }
}

class ChanHooks {
  ChanHooks(this.gate, this.nymKey, this.shownKey);

  final RunGate gate;
  final String Function() nymKey;
  final String Function() shownKey;

  bool shown(String pk) => pk.isNotEmpty && pk == shownKey();

  int slot(String pk) => gate.slot();

  bool ready(String pk) => gate.free();

  void acted(String pk, bool waited) => gate.acted(pk != nymKey(), waited: waited);
}
