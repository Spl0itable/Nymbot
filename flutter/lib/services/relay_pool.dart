import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../models/nostr_event.dart';

class _Relay {
  _Relay(this.url, this.channel);

  final String url;
  final WebSocketChannel channel;
  // A socket's stream can only be listened to once, so the one listener fans
  // out to everything that wants frames from this relay.
  final StreamController<List<dynamic>> frames =
      StreamController<List<dynamic>>.broadcast();
  StreamSubscription? tap;
  bool retired = false;
}

/// A small relay pool: publish, one-shot fetch, and a live subscription.
///
/// The worker's multiplexed proxy carries all of it when it can reach it — one
/// socket instead of ten, and relays never see the reader's address. Direct
/// sockets are the fallback, and the proxy is retried in the background.
///
/// The relay set is the one the Nymbot worker itself reads from, because a wrap
/// published anywhere else is one it can never fetch and open.
class RelayPool {
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

  /// Whoever the frames go to: the proxy while it is up, our own sockets otherwise.
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

  void _connectDirect() {
    for (final url in NymbotConfig.relays) {
      _open(url);
    }
  }

  /// The proxy speaks the same frames as a relay, so everything below works
  /// unchanged once it is the target.
  bool _openPool() {
    final url = poolUrl;
    if (url == null || _closed || _pool != null) return _pool != null;
    WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
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
    }).catchError((_) => _poolDown(pool));
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

  /// Lets go of the sockets the proxy has made redundant, without letting a
  /// reconnect already in flight bring them back.
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
      channel = WebSocketChannel.connect(Uri.parse(url));
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
  }

  void _drop(String url) {
    final relay = _relays.remove(url);
    relay?.tap?.cancel();
    if (relay != null && !relay.frames.isClosed) relay.frames.close();
    _emit();
    if (_closed || _poolUp || (relay?.retired ?? false)) return;
    // Staggered, so a relay that drops everyone at once is not met with a
    // synchronised stampede.
    _track(Timer(Duration(milliseconds: 4000 + _rng.nextInt(6000)), () => _open(url)));
  }

  /// Held so [close] can cancel it. Without this a reconnect scheduled just
  /// before shutdown outlives the pool.
  void _track(Timer timer) => _timers.add(timer);

  void _send(_Relay relay, List<dynamic> frame) {
    try {
      relay.channel.sink.add(jsonEncode(frame));
    } catch (_) {}
  }

  /// Publishes to every open relay and completes with how many said OK.
  ///
  /// One acceptance is enough for the worker to find the wrap, so this waits
  /// for the first couple rather than for all of them.
  Future<int> publish(NostrEvent event, {Duration? timeout}) {
    final open = _targets;
    if (open.isEmpty) return Future.value(0);
    // The proxy forwards one OK per event however many relays took it, so there
    // one is the pair.
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

  /// One-shot query across the pool, de-duplicated by event id.
  Future<List<NostrEvent>> fetch(Map<String, dynamic> filter,
      {Duration? timeout}) {
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

  /// A one-shot query against relays this app does not keep open.
  Future<List<NostrEvent>> fetchFrom(
      List<String> urls, Map<String, dynamic> filter,
      {Duration? timeout}) {
    final list = urls
        .where((u) => u.startsWith('wss://') || u.startsWith('ws://'))
        .toSet()
        .take(8)
        .toList();
    if (list.isEmpty) return Future.value(const []);
    final id = _subId();
    final found = <String, NostrEvent>{};
    final done = Completer<List<NostrEvent>>();
    final channels = <WebSocketChannel>[];
    final taps = <StreamSubscription>[];
    var closed = 0;

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

    // Through the proxy while it is carrying us, so a relay we have never spoken
    // to does not learn the reader's address.
    late void Function(String, bool) dial;
    void give(String url, bool viaProxy) {
      if (viaProxy) {
        dial(url, false);
      } else if (++closed >= list.length) {
        finish();
      }
    }

    dial = (String url, bool viaProxy) {
      final target = viaProxy
          ? 'wss://${NymbotConfig.apiHost}/api/relay?relay=${Uri.encodeComponent(url)}'
          : url;
      WebSocketChannel channel;
      try {
        channel = WebSocketChannel.connect(Uri.parse(target));
      } catch (_) {
        give(url, viaProxy);
        return;
      }
      channels.add(channel);
      var spoke = false;
      taps.add(channel.stream.listen((raw) {
        List<dynamic> frame;
        try {
          frame = jsonDecode(raw as String) as List<dynamic>;
        } catch (_) {
          return;
        }
        if (frame.length < 2 || frame[1] != id) return;
        spoke = true;
        if (frame[0] == 'EVENT' && frame.length >= 3) {
          try {
            final evt = NostrEvent.fromJson(frame[2] as Map<String, dynamic>);
            found[evt.id] = evt;
          } catch (_) {}
        } else if (frame[0] == 'EOSE') {
          if (++closed >= list.length) finish();
        }
      }, onError: (_) {
        if (spoke || done.isCompleted) return;
        spoke = true;
        give(url, viaProxy);
      }, onDone: () {
        if (spoke || done.isCompleted) return;
        spoke = true;
        give(url, viaProxy);
      }, cancelOnError: true));
      try {
        channel.sink.add(jsonEncode(['REQ', id, filter]));
      } catch (_) {}
    };

    final proxy = pooled && NymbotConfig.apiHost.isNotEmpty;
    for (final url in list) {
      dial(url, proxy);
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
