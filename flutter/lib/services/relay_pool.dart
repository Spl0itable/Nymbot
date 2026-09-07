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
}

/// A small relay pool: publish, one-shot fetch, and a live subscription.
///
/// Direct sockets rather than a proxy. The relay set is the one the Nymbot
/// worker itself reads from, because a wrap published anywhere else is one it
/// can never fetch and open.
class RelayPool {
  final Map<String, _Relay> _relays = {};
  final Map<String,
          ({Map<String, dynamic> filter, void Function(NostrEvent) onEvent})>
      _standing = {};
  final Set<void Function(int connected, int total)> _listeners = {};
  final Set<Timer> _timers = {};
  final _rng = Random.secure();
  bool _closed = false;

  int get connected => _relays.length;

  void onStatus(void Function(int, int) fn) => _listeners.add(fn);

  void _emit() {
    for (final fn in _listeners.toList()) {
      fn(_relays.length, NymbotConfig.relays.length);
    }
  }

  String _subId() =>
      'nb${List.generate(8, (_) => _rng.nextInt(16).toRadixString(16)).join()}';

  void connect() {
    for (final url in NymbotConfig.relays) {
      _open(url);
    }
  }

  void _open(String url) {
    if (_closed || _relays.containsKey(url)) return;
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
        if (!relay.frames.isClosed) relay.frames.add(frame);
        if (frame.length >= 3 && frame[0] == 'EVENT') {
          final standing = _standing[frame[1]];
          if (standing == null) return;
          try {
            standing.onEvent(
                NostrEvent.fromJson(frame[2] as Map<String, dynamic>));
          } catch (_) {}
        }
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
    relay?.frames.close();
    _emit();
    if (_closed) return;
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
    final open = _relays.values.toList();
    if (open.isEmpty) return Future.value(0);
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
          if (accepted >= 2) finish();
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
    final open = _relays.values.toList();
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

  /// A standing subscription, replayed onto relays as they reconnect.
  void Function() subscribe(
      Map<String, dynamic> filter, void Function(NostrEvent) onEvent) {
    final id = _subId();
    _standing[id] = (filter: filter, onEvent: onEvent);
    for (final relay in _relays.values) {
      _send(relay, ['REQ', id, filter]);
    }
    return () {
      _standing.remove(id);
      for (final relay in _relays.values) {
        _send(relay, ['CLOSE', id]);
      }
    };
  }

  void close() {
    _closed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    for (final relay in _relays.values) {
      relay.tap?.cancel();
      relay.frames.close();
      relay.channel.sink.close();
    }
    _relays.clear();
  }
}
