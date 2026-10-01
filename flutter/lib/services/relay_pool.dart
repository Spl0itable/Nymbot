import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../models/nostr_event.dart';

class _Relay {
  _Relay(this.url, this.channel);

  final String url;
  final WebSocketChannel channel;
  // A socket stream allows one listener, so this fans frames out.
  final StreamController<List<dynamic>> frames =
      StreamController<List<dynamic>>.broadcast();
  StreamSubscription? tap;
  bool retired = false;
}

/// Publish, fetch and subscribe via the worker's proxy, falling back to direct sockets on the worker's relay set.
class RelayPool {
  RelayPool({
    WebSocketChannel Function(Uri uri)? connect,
    Duration? heldWait,
    Duration? openWait,
  })  : _connect = connect ?? WebSocketChannel.connect,
        heldWait = heldWait ?? defaultHeldWait,
        openWait = openWait ?? defaultOpenWait;

  static const int heldMax = 16;

  @visibleForTesting
  static Duration defaultHeldWait = const Duration(seconds: 15);

  @visibleForTesting
  static Duration defaultOpenWait = const Duration(seconds: 5);

  final Duration heldWait;
  final Duration openWait;
  final WebSocketChannel Function(Uri uri) _connect;
  final List<({NostrEvent event, Duration? timeout, Completer<int> done, Timer timer})>
      _held = [];
  final List<({Completer<bool> done, Timer timer})> _waiting = [];
  bool _flushQueued = false;
  final Map<String, _Relay> _relays = {};
  final Map<String,
          ({Map<String, dynamic> filter, void Function(NostrEvent) onEvent})>
      _standing = {};
  final Set<void Function(int connected, int total)> _listeners = {};
  final Set<Timer> _timers = {};
  final _rng = Random.secure();
  bool _closed = false;

  _Relay? _pool;
  bool _poolUp = false;
  List<String> _upstream = const [];
  bool _direct = false;
  int _tries = 0;
  Timer? _poolTimer;

  static String? get poolUrl => NymbotConfig.apiHost.isEmpty
      ? null
      : 'wss://${NymbotConfig.apiHost}/api/relay-pool';

  bool get pooled => _pool != null && _poolUp;

  int get connected => pooled
      ? (_upstream.isEmpty ? 1 : _upstream.length)
      : _relays.length;

  /// The proxy while it is up, else our own sockets.
  List<_Relay> get _targets => pooled ? [_pool!] : _relays.values.toList();

  void onStatus(void Function(int, int) fn) => _listeners.add(fn);

  void _emit() {
    for (final fn in _listeners.toList()) {
      fn(connected, NymbotConfig.relays.length);
    }
  }

  String _subId() =>
      'nb${List.generate(8, (_) => _rng.nextInt(16).toRadixString(16)).join()}';

  void connect() {
    if (!_direct && _openPool()) return;
    _connectDirect();
  }

  int get backoffTries => _tries;

  void wake() {
    if (_closed) return;
    _tries = 0;
    if (pooled) return;
    if (_pool == null) {
      _poolTimer?.cancel();
      _poolTimer = null;
      _direct = false;
      if (_openPool()) return;
      _direct = true;
    }
    _connectDirect();
  }

  void _connectDirect() {
    for (final url in NymbotConfig.relays) {
      _open(url);
    }
  }

  /// The proxy speaks relay frames, so everything below works unchanged.
  bool _openPool() {
    final url = poolUrl;
    if (url == null || _closed || _pool != null) return _pool != null;
    WebSocketChannel channel;
    try {
      channel = _connect(Uri.parse(url));
    } catch (_) {
      return false;
    }
    final pool = _Relay(url, channel);
    _pool = pool;
    _poolUp = false;
    _upstream = const [];
    pool.tap = channel.stream.listen(
      (raw) {
        List<dynamic> frame;
        try {
          frame = jsonDecode(raw as String) as List<dynamic>;
        } catch (_) {
          return;
        }
        if (frame.isNotEmpty && frame[0] == 'POOL:STATUS') {
          final status = frame.length >= 2 ? frame[1] : null;
          if (status is Map && status['connected'] is List) {
            _upstream = List<String>.from(
                (status['connected'] as List).whereType<String>());
            _emit();
          }
          return;
        }
        _fanOut(pool, frame);
      },
      onError: (_) => _poolDown(pool),
      onDone: () => _poolDown(pool),
      cancelOnError: true,
    );
    channel.ready.then((_) {
      if (_pool != pool) return;
      _poolUp = true;
      _tries = 0;
      _send(pool, ['RELAYS', {'critical': NymbotConfig.relays}]);
      for (final entry in _standing.entries) {
        _send(pool, ['REQ', entry.key, entry.value.filter]);
      }
      _retireDirect();
      _emit();
      _flushHeld();
    }).catchError((_) {
      _poolDown(pool);
    });
    return true;
  }

  void _poolDown(_Relay pool) {
    if (_pool != pool) return;
    _pool = null;
    _poolUp = false;
    _upstream = const [];
    pool.tap?.cancel();
    if (!pool.frames.isClosed) pool.frames.close();
    try {
      pool.channel.sink.close();
    } catch (_) {}
    _emit();
    if (_closed) return;
    _direct = true;
    _connectDirect();
    _retryPool();
  }

  void _retryPool() {
    if (_poolTimer != null || _closed) return;
    final wait = min(15000 * (1 << min(_tries++, 3)), 120000);
    final timer = Timer(Duration(milliseconds: wait + _rng.nextInt(4000)), () {
      _poolTimer = null;
      if (_closed || _pool != null) return;
      _direct = false;
      if (!_openPool()) {
        _direct = true;
        _retryPool();
      }
    });
    _poolTimer = timer;
    _track(timer);
  }

  /// Closes redundant direct sockets without letting an in-flight reconnect revive them.
  void _retireDirect() {
    _direct = false;
    for (final relay in _relays.values.toList()) {
      relay.retired = true;
      relay.tap?.cancel();
      if (!relay.frames.isClosed) relay.frames.close();
      try {
        relay.channel.sink.close();
      } catch (_) {}
    }
    _relays.clear();
  }

  void _fanOut(_Relay relay, List<dynamic> frame) {
    if (!relay.frames.isClosed) relay.frames.add(frame);
    if (frame.length >= 3 && frame[0] == 'EVENT') {
      final standing = _standing[frame[1]];
      if (standing == null) return;
      try {
        standing.onEvent(NostrEvent.fromJson(frame[2] as Map<String, dynamic>));
      } catch (_) {}
    }
  }

  void _open(String url) {
    if (_closed || _poolUp || _relays.containsKey(url)) return;
    WebSocketChannel channel;
    try {
      channel = _connect(Uri.parse(url));
    } catch (_) {
      return;
    }
    final relay = _Relay(url, channel);
    _relays[url] = relay;
    relay.tap = channel.stream.listen(
      (raw) {
        List<dynamic> frame;
        try {
          frame = jsonDecode(raw as String) as List<dynamic>;
        } catch (_) {
          return;
        }
        _fanOut(relay, frame);
      },
      onError: (_) => _drop(url),
      onDone: () => _drop(url),
      cancelOnError: true,
    );
    _emit();
    for (final entry in _standing.entries) {
      _send(relay, ['REQ', entry.key, entry.value.filter]);
    }
    _flushSoon();
  }

  void _flushSoon() {
    if (_flushQueued) return;
    _flushQueued = true;
    scheduleMicrotask(() {
      _flushQueued = false;
      _flushHeld();
    });
  }

  void _flushHeld() {
    if (_targets.isEmpty) return;
    final waiting = List.of(_waiting);
    _waiting.clear();
    for (final w in waiting) {
      w.timer.cancel();
      if (!w.done.isCompleted) w.done.complete(true);
    }
    final held = List.of(_held);
    _held.clear();
    for (final item in held) {
      item.timer.cancel();
      publish(item.event, timeout: item.timeout).then((n) {
        if (!item.done.isCompleted) item.done.complete(n);
      });
    }
  }

  Future<int> _hold(NostrEvent event, Duration? timeout) {
    if (_held.length >= heldMax) {
      final oldest = _held.removeAt(0);
      oldest.timer.cancel();
      if (!oldest.done.isCompleted) oldest.done.complete(0);
    }
    final done = Completer<int>();
    late final ({NostrEvent event, Duration? timeout, Completer<int> done, Timer timer}) item;
    final timer = Timer(heldWait, () {
      _held.remove(item);
      if (!done.isCompleted) done.complete(0);
    });
    item = (event: event, timeout: timeout, done: done, timer: timer);
    _held.add(item);
    return done.future;
  }

  Future<bool> _awaitOpen() {
    if (_targets.isNotEmpty) return Future.value(true);
    if (_closed || openWait <= Duration.zero) return Future.value(false);
    final done = Completer<bool>();
    late final ({Completer<bool> done, Timer timer}) entry;
    final timer = Timer(openWait, () {
      _waiting.remove(entry);
      if (!done.isCompleted) done.complete(_targets.isNotEmpty);
    });
    entry = (done: done, timer: timer);
    _waiting.add(entry);
    return done.future;
  }

  void _drop(String url) {
    final relay = _relays.remove(url);
    relay?.tap?.cancel();
    if (relay != null && !relay.frames.isClosed) relay.frames.close();
    _emit();
    if (_closed || _poolUp || (relay?.retired ?? false)) return;
    // Jittered to avoid a reconnect stampede.
    _track(Timer(Duration(milliseconds: 4000 + _rng.nextInt(6000)), () => _open(url)));
  }

  /// Tracked so [close] can cancel reconnects scheduled before shutdown.
  void _track(Timer timer) => _timers.add(timer);

  void _send(_Relay relay, List<dynamic> frame) {
    try {
      relay.channel.sink.add(jsonEncode(frame));
    } catch (_) {}
  }

  /// Completes with the OK count after the first couple of acceptances.
  Future<int> publish(NostrEvent event, {Duration? timeout}) {
    final open = _targets;
    if (open.isEmpty) {
      return _closed || heldWait <= Duration.zero
          ? Future.value(0)
          : _hold(event, timeout);
    }
    // The proxy sends one OK per event regardless of relay count.
    final need = pooled ? 1 : 2;
    final done = Completer<int>();
    final taps = <StreamSubscription>[];
    var accepted = 0;

    void finish() {
      if (done.isCompleted) return;
      for (final t in taps) {
        t.cancel();
      }
      done.complete(accepted);
    }

    for (final relay in open) {
      taps.add(relay.frames.stream.listen((frame) {
        if (frame.length >= 3 &&
            frame[0] == 'OK' &&
            frame[1] == event.id &&
            frame[2] != false) {
          accepted++;
          if (accepted >= need) finish();
        }
      }));
      _send(relay, ['EVENT', event.toJson()]);
    }
    _track(Timer(timeout ?? const Duration(seconds: 4), finish));
    return done.future;
  }

  /// One-shot query across the pool, deduplicated by event id.
  Future<List<NostrEvent>> fetch(Map<String, dynamic> filter,
      {Duration? timeout}) async {
    if (_targets.isEmpty && !await _awaitOpen()) return const [];
    return _fetchOpen(filter, timeout);
  }

  Future<List<NostrEvent>> _fetchOpen(
      Map<String, dynamic> filter, Duration? timeout) {
    final open = _targets;
    if (open.isEmpty) return Future.value(const []);
    final id = _subId();
    final found = <String, NostrEvent>{};
    final done = Completer<List<NostrEvent>>();
    final taps = <StreamSubscription>[];
    var eose = 0;

    void finish() {
      if (done.isCompleted) return;
      for (final t in taps) {
        t.cancel();
      }
      for (final relay in open) {
        _send(relay, ['CLOSE', id]);
      }
      done.complete(found.values.toList());
    }

    for (final relay in open) {
      taps.add(relay.frames.stream.listen((frame) {
        if (frame.length < 2 || frame[1] != id) return;
        if (frame[0] == 'EVENT' && frame.length >= 3) {
          try {
            final evt = NostrEvent.fromJson(frame[2] as Map<String, dynamic>);
            found[evt.id] = evt;
          } catch (_) {}
        } else if (frame[0] == 'EOSE') {
          if (++eose >= open.length) finish();
        }
      }));
      _send(relay, ['REQ', id, filter]);
    }
    _track(Timer(timeout ?? const Duration(seconds: 4), finish));
    return done.future;
  }

  /// One-shot query against relays not kept open.
  Future<List<NostrEvent>> fetchFrom(
      List<String> urls, Map<String, dynamic> filter,
      {Duration? timeout}) {
    if (NymbotConfig.apiHost.isEmpty) return Future.value(const []);
    final list =
        urls.where((u) => u.startsWith('wss://')).toSet().take(8).toList();
    if (list.isEmpty) return Future.value(const []);
    final id = _subId();
    final found = <String, NostrEvent>{};
    final done = Completer<List<NostrEvent>>();
    final channels = <WebSocketChannel>[];
    final taps = <StreamSubscription>[];
    var ended = 0;

    void finish() {
      if (done.isCompleted) return;
      for (final t in taps) {
        t.cancel();
      }
      for (final c in channels) {
        try {
          c.sink.close();
        } catch (_) {}
      }
      done.complete(found.values.toList());
    }

    void give() {
      if (++ended >= list.length) finish();
    }

    for (final url in list) {
      final target =
          'wss://${NymbotConfig.apiHost}/api/relay?relay=${Uri.encodeComponent(url)}';
      WebSocketChannel channel;
      try {
        channel = _connect(Uri.parse(target));
      } catch (_) {
        give();
        continue;
      }
      channels.add(channel);
      var over = false;
      void end() {
        if (over) return;
        over = true;
        give();
      }

      taps.add(channel.stream.listen((raw) {
        List<dynamic> frame;
        try {
          frame = jsonDecode(raw as String) as List<dynamic>;
        } catch (_) {
          return;
        }
        if (frame.length < 2 || frame[1] != id) return;
        if (frame[0] == 'EVENT' && frame.length >= 3) {
          try {
            final evt = NostrEvent.fromJson(frame[2] as Map<String, dynamic>);
            found[evt.id] = evt;
          } catch (_) {}
        } else if (frame[0] == 'EOSE') {
          end();
        }
      }, onError: (_) => end(), onDone: end, cancelOnError: true));
      channel.ready.then((_) {}, onError: (_) => end());
      try {
        channel.sink.add(jsonEncode(['REQ', id, filter]));
      } catch (_) {}
    }
    _track(Timer(timeout ?? const Duration(seconds: 6), finish));
    return done.future;
  }

  Future<int> publishTo(List<String> urls, NostrEvent event,
      {Duration? timeout}) {
    final list = urls.where((u) => u.startsWith('wss://')).toSet().toList();
    if (list.isEmpty || _closed) return Future.value(0);
    final done = Completer<int>();
    final channels = <WebSocketChannel>[];
    final taps = <StreamSubscription>[];
    var accepted = 0;
    var ended = 0;

    void finish() {
      if (done.isCompleted) return;
      for (final t in taps) {
        t.cancel();
      }
      for (final c in channels) {
        try {
          c.sink.close();
        } catch (_) {}
      }
      done.complete(accepted);
    }

    void give() {
      if (++ended >= list.length) finish();
    }

    final frame = jsonEncode(['EVENT', event.toJson()]);
    for (final url in list) {
      WebSocketChannel channel;
      try {
        channel = _connect(Uri.parse(
            'wss://${NymbotConfig.apiHost}/api/relay?relay=${Uri.encodeComponent(url)}'));
      } catch (_) {
        give();
        continue;
      }
      channels.add(channel);
      var over = false;
      void end() {
        if (over) return;
        over = true;
        give();
      }

      taps.add(channel.stream.listen((raw) {
        List<dynamic> reply;
        try {
          reply = jsonDecode(raw as String) as List<dynamic>;
        } catch (_) {
          return;
        }
        if (reply.length < 3 || reply[0] != 'OK' || reply[1] != event.id) return;
        if (reply[2] == true) accepted++;
        end();
      }, onError: (_) => end(), onDone: end, cancelOnError: true));
      channel.ready.then((_) {}, onError: (_) => end());
      try {
        channel.sink.add(frame);
      } catch (_) {
        end();
      }
    }
    _track(Timer(timeout ?? const Duration(seconds: 6), finish));
    return done.future;
  }

  /// A standing subscription, replayed onto relays as they reconnect.
  void Function() subscribe(
      Map<String, dynamic> filter, void Function(NostrEvent) onEvent) {
    final id = _subId();
    _standing[id] = (filter: filter, onEvent: onEvent);
    for (final relay in _targets) {
      _send(relay, ['REQ', id, filter]);
    }
    return () {
      _standing.remove(id);
      for (final relay in _targets) {
        _send(relay, ['CLOSE', id]);
      }
    };
  }

  void close() {
    _closed = true;
    for (final item in _held) {
      item.timer.cancel();
      if (!item.done.isCompleted) item.done.complete(0);
    }
    _held.clear();
    for (final w in _waiting) {
      w.timer.cancel();
      if (!w.done.isCompleted) w.done.complete(false);
    }
    _waiting.clear();
    _poolTimer?.cancel();
    _poolTimer = null;
    final pool = _pool;
    _pool = null;
    _poolUp = false;
    if (pool != null) {
      pool.tap?.cancel();
      if (!pool.frames.isClosed) pool.frames.close();
      try {
        pool.channel.sink.close();
      } catch (_) {}
    }
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    for (final relay in _relays.values) {
      relay.tap?.cancel();
      if (!relay.frames.isClosed) relay.frames.close();
      relay.channel.sink.close();
    }
    _relays.clear();
  }
}
