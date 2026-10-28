import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/crypto/channel.dart';
import '../models/conversation.dart';
import '../models/nostr_event.dart';
import '../models/workspace.dart';
import 'nostr/event_signer.dart';

abstract class ChanWire {
  Stream<dynamic> get stream;
  void add(String text);
  Future<void> close();
}

class _WsWire implements ChanWire {
  _WsWire(Uri url) : _ch = WebSocketChannel.connect(url);
  final WebSocketChannel _ch;

  @override
  Stream<dynamic> get stream => _ch.stream;

  @override
  void add(String text) => _ch.sink.add(text);

  @override
  Future<void> close() async {
    try {
      await _ch.sink.close();
    } catch (_) {}
  }
}

typedef ChanWireFactory = ChanWire Function(Uri url);

class ChanFailure implements Exception {
  ChanFailure(this.code);
  final String code;

  bool get unsupported => code == 'unavailable' || code == 'unsupported';

  @override
  String toString() => 'ChanFailure($code)';
}

class ChanEvent {
  ChanEvent(this.type, this.body);
  final int type;
  final Map<String, dynamic> body;
}

int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class ChanLink {
  ChanLink._(this._sock, this.n, this.cert, this._state, this.user);
  final ChanSocket _sock;
  final String n;
  final ChannelCert cert;
  final ChannelState _state;
  final String user;
  final _events = StreamController<ChanEvent>.broadcast(sync: true);
  final List<Uint8List> _parts = [];
  int? _partType;
  int _partSize = 0;
  String? deadCode;
  Future<void> _tx = Future.value();
  Future<void> _rx = Future.value();

  Stream<ChanEvent> get events => _events.stream;
  bool get dead => deadCode != null;
  bool get usable => !dead && _sock.connected && _nowSec() < cert.exp - 60;

  Future<int> send(int type, Map<String, dynamic> body) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final next = _tx.then((_) async {
      if (dead) throw ChanFailure(deadCode!);
      var at = 0;
      var total = 0;
      do {
        final end = at + channelMaxBody < bytes.length ? at + channelMaxBody : bytes.length;
        Uint8List f;
        try {
          f = await channelSealFrame(_state, type, Uint8List.sublistView(bytes, at, end), more: end < bytes.length);
        } on ChannelError catch (e) {
          if (e.code != 'oversize') _die(e.code);
          throw ChanFailure(e.code);
        }
        final text = channelEncodeFrame(f);
        total += f.length;
        _sock._raw(['CHAN', n, text]);
        at = end;
      } while (at < bytes.length);
      return total;
    });
    _tx = next.then((_) {}, onError: (_) {});
    return next;
  }

  void _frame(String text) {
    _rx = _rx.then((_) async {
      if (dead) return;
      try {
        final f = await channelOpenFrame(_state, channelDecodeFrame(text), null);
        if (_partType != null && _partType != f.type) {
          _die('malformed');
          return;
        }
        _partType = f.type;
        _parts.add(f.body);
        _partSize += f.body.length;
        if (_partSize > 16 * 1024 * 1024) {
          _die('oversize');
          return;
        }
        if (f.more) return;
        final whole = _parts.length == 1 ? _parts.first : Uint8List.fromList([for (final p in _parts) ...p]);
        final type = _partType!;
        _parts.clear();
        _partType = null;
        _partSize = 0;
        var body = <String, dynamic>{};
        try {
          final d = jsonDecode(utf8.decode(whole));
          if (d is Map<String, dynamic>) body = d;
        } catch (_) {}
        if (type == ChannelType.close) {
          _die('closed');
          return;
        }
        if (type == ChannelType.abort) {
          _die('${body['code'] ?? 'abort'}');
          return;
        }
        _events.add(ChanEvent(type, body));
      } on ChannelError catch (e) {
        _die(e.code);
      }
    });
  }

  void _die(String code) {
    if (dead) return;
    deadCode = code;
    _sock._links.remove(n);
    _events.add(ChanEvent(ChannelType.abort, {'code': code}));
  }

  void close() {
    if (dead) return;
    send(ChannelType.close, const {}).then((_) {}, onError: (_) {}).whenComplete(() => _die('closed'));
  }
}

class ChanSocket {
  ChanSocket(this.url, this.botPk, this._factory);
  final Uri url;
  final String botPk;
  final ChanWireFactory _factory;
  ChanWire? _wire;
  StreamSubscription<dynamic>? _sub;
  final Map<String, ChanLink> _links = {};
  final Map<String, Completer<List<dynamic>>> _waits = {};

  bool get connected => _wire != null;

  void _ensure() {
    if (_wire != null) return;
    final w = _factory(url);
    _wire = w;
    _sub = w.stream.listen(_onRaw, onDone: () => _gone(w), onError: (_) => _gone(w), cancelOnError: true);
  }

  void _gone(ChanWire w) {
    if (!identical(_wire, w)) return;
    _wire = null;
    final sub = _sub;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
    for (final l in _links.values.toList()) {
      l._die('dropped');
    }
    _links.clear();
    for (final c in _waits.values) {
      if (!c.isCompleted) c.completeError(ChanFailure('dropped'));
    }
    _waits.clear();
  }

  void _raw(List<dynamic> msg) {
    final w = _wire;
    if (w == null) throw ChanFailure('dropped');
    w.add(jsonEncode(msg));
  }

  void _onRaw(dynamic data) {
    _rx++;
    List<dynamic>? m;
    try {
      final d = jsonDecode(data is String ? data : utf8.decode((data as List).cast<int>()));
      if (d is List) m = d;
    } catch (_) {}
    if (m == null || m.length < 2) return;
    final n = '${m[1]}';
    final tag = m[0];
    if (tag == 'CHAN_CERT' || tag == 'CHAN_ERR') {
      final w = _waits.remove(n);
      if (w != null && !w.isCompleted) {
        w.complete(m);
        return;
      }
      if (tag == 'CHAN_ERR') _links[n]?._die('${m.length > 2 ? m[2] : 'failed'}');
      return;
    }
    if (tag == 'CHAN') _links[n]?._frame('${m.length > 2 ? m[2] : ''}');
  }

  Future<ChanLink> open(EventSigner signer, {Duration timeout = const Duration(seconds: 8)}) async {
    _ensure();
    final h = await channelNewHello(signer.pubkey);
    final n = h.hello['n'] as String;
    final tpl = channelAuthTemplate(h.hello, url.toString(), null);
    final auth = await signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: tpl['created_at'] as int,
      kind: tpl['kind'] as int,
      tags: [for (final t in tpl['tags'] as List) List<String>.from(t as List)],
      content: '',
    ));
    final wait = Completer<List<dynamic>>();
    _waits[n] = wait;
    _raw(['CHAN_OPEN', h.hello, auth.toJson()]);
    List<dynamic> got;
    try {
      got = await wait.future.timeout(timeout);
    } on TimeoutException {
      _waits.remove(n);
      final w = _wire;
      if (w != null && _links.isEmpty) {
        _gone(w);
        unawaited(w.close());
      }
      throw ChanFailure('timeout');
    }
    if (got[0] == 'CHAN_ERR') throw ChanFailure('${got.length > 2 ? got[2] : 'failed'}');
    final raw = got.length > 2 ? got[2] : null;
    if (raw is! Map) throw ChanFailure('malformed');
    ChannelCert cert;
    ChannelFinish fin;
    try {
      cert = channelVerifyCert(raw.cast<String, dynamic>(), botPk: botPk, userPk: signer.pubkey, nonce: n);
      fin = await channelClientFinish(hello: h, authId: auth.id, cert: cert, botPk: botPk);
    } on ChannelError catch (e) {
      throw ChanFailure(e.code);
    }
    final link = ChanLink._(this, n, cert, fin.state, signer.pubkey);
    _links[n] = link;
    _raw(['CHAN_KEY', n, channelEncodeFrame(fin.kemCt)]);
    return link;
  }

  Future<void> close() async {
    final w = _wire;
    if (w == null) return;
    _gone(w);
    await w.close();
  }

  static const Duration probeTimeout = Duration(seconds: 3);
  static final Random _rng = Random.secure();
  int _rx = 0;
  bool _probing = false;

  Future<void> probe({Duration timeout = probeTimeout}) async {
    final w = _wire;
    if (w == null || _probing) return;
    _probing = true;
    final before = _rx;
    final n = List<String>.generate(16, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final wait = Completer<List<dynamic>>();
    _waits[n] = wait;
    try {
      _raw(['CHAN_KEY', n, '']);
      await wait.future.timeout(timeout);
    } on TimeoutException {
      _waits.remove(n);
      if (identical(_wire, w) && _rx == before) {
        _gone(w);
        unawaited(w.close());
      }
    } catch (_) {
      _waits.remove(n);
    } finally {
      _probing = false;
    }
  }
}

class NymbotChannels {
  NymbotChannels({required this.url, required this.botPk, ChanWireFactory? wire, this.openTimeout = const Duration(seconds: 8)})
      : _factory = wire ?? ((u) => _WsWire(u));
  final Uri url;
  final String botPk;
  final Duration openTimeout;
  final ChanWireFactory _factory;
  final Map<String, ChanSocket> _socks = {};
  final Map<String, Future<ChanLink>> _warm = {};
  final Map<String, ChanLink> _ready = {};
  int opened = 0;

  ChanSocket socketOf(String pk) => _socks.putIfAbsent(pk, () => ChanSocket(url, botPk, _factory));

  Future<ChanLink> _open(EventSigner s) {
    opened++;
    return socketOf(s.pubkey).open(s, timeout: openTimeout);
  }

  void prewarm(EventSigner s) {
    final pk = s.pubkey;
    final ready = _ready[pk];
    if (ready != null && ready.usable) return;
    if (ready != null) {
      _ready.remove(pk);
      _warm.remove(pk);
      ready.close();
    }
    if (_warm.containsKey(pk)) return;
    final f = _open(s);
    _warm[pk] = f;
    f.then((l) {
      if (identical(_warm[pk], f)) _ready[pk] = l;
    }, onError: (_) {
      if (identical(_warm[pk], f)) _warm.remove(pk);
    });
  }

  Future<ChanLink> take(EventSigner s) async {
    final pk = s.pubkey;
    final w = _warm.remove(pk);
    _ready.remove(pk);
    if (w != null) {
      try {
        final l = await w;
        if (l.usable) return l;
        l.close();
      } catch (_) {}
    }
    return _open(s);
  }

  void give(EventSigner s, ChanLink l) {
    final pk = s.pubkey;
    if (_warm.containsKey(pk) || !l.usable) {
      l.close();
      return;
    }
    _warm[pk] = Future.value(l);
    _ready[pk] = l;
  }

  final List<(String, ChanSocket)> _queue = [];
  Timer? _head;
  String? _headPk;
  int Function(String pk)? _slot;
  bool Function(String pk)? _free;
  void Function(String pk, bool waited)? _acted;

  void _revive(String pk, ChanSocket s) {
    if (!identical(_socks[pk], s)) return;
    final l = _ready.remove(pk);
    _warm.remove(pk);
    l?.close();
    if (!s.connected) return;
    if (s._links.values.every((x) => identical(x, l))) {
      unawaited(s.close());
    } else {
      unawaited(s.probe());
    }
  }

  void _act(String pk, ChanSocket s, bool waited) {
    _acted?.call(pk, waited);
    _revive(pk, s);
  }

  void _arm(String pk, ChanSocket s) {
    final got = _slot?.call(pk) ?? 0;
    _headPk = pk;
    _head = Timer(Duration(milliseconds: got < 1 ? 1 : got), () {
      final live = identical(_socks[pk], s) && s.connected;
      final ready = _free;
      if (live && ready != null && !ready(pk)) {
        _arm(pk, s);
        return;
      }
      _head = null;
      _headPk = null;
      if (live) _act(pk, s, true);
      _pump();
    });
  }

  void _pump() {
    while (_head == null && _queue.isNotEmpty) {
      final (pk, s) = _queue.removeAt(0);
      if (!identical(_socks[pk], s) || !s.connected) continue;
      _arm(pk, s);
    }
  }

  void resumed({
    bool Function(String pk)? shown,
    int Function(String pk)? slot,
    bool Function(String pk)? ready,
    void Function(String pk, bool waited)? acted,
  }) {
    _slot = slot;
    _free = ready;
    _acted = acted;
    for (final e in _socks.entries.toList()) {
      final pk = e.key;
      final s = e.value;
      if (_headPk == pk || _queue.any((q) => q.$1 == pk)) continue;
      if (!s.connected) {
        _revive(pk, s);
        continue;
      }
      if (shown != null && !shown(pk)) {
        _queue.add((pk, s));
        continue;
      }
      _act(pk, s, false);
    }
    _pump();
  }

  Future<void> close() async {
    _head?.cancel();
    _head = null;
    _headPk = null;
    _queue.clear();
    for (final s in _socks.values) {
      await s.close();
    }
    _socks.clear();
    _warm.clear();
    _ready.clear();
  }
}

Future<NostrEvent> chanSealTurn(Map<String, dynamic> rumor, EventSigner signer, ChannelCert cert) async {
  final content = await signer.nip44Encrypt(cert.s, jsonEncode(rumor));
  return signer.sign(UnsignedEvent(
      pubkey: signer.pubkey, createdAt: _nowSec(), kind: 13, content: content));
}

final RegExp _hex64Run = RegExp(r'^[0-9a-f]{64}$');
final RegExp _hex128 = RegExp(r'^[0-9a-f]{128}$');

String chanToken(String run, String k) => _hex64Run.hasMatch(run) ? '$run$k' : 'chan:$run:$k';

({String run, String k})? chanTokenOf(String? token) {
  if (token != null && _hex128.hasMatch(token)) return (run: token.substring(0, 64), k: token.substring(64));
  if (token == null || !token.startsWith('chan:')) return null;
  final rest = token.substring(5);
  final i = rest.lastIndexOf(':');
  if (i <= 0) return null;
  final k = rest.substring(i + 1);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(k)) return null;
  return (run: rest.substring(0, i), k: k);
}

class ChanHistory {
  static const int window = 48;
  static const int threadWindow = 40;
  static const int keep = 40;
  static const int foldMax = 40;
  static const String seedHead = '[earlier in this conversation]\n';
  static final RegExp _bang = RegExp(r'^\s*!\s*\S');

  static String _reference(Map<String, dynamic> a) {
    final image = a['kind'] == 'image' || '${a['mime'] ?? ''}'.startsWith('image/');
    final name = '${a['name'] ?? ''}';
    return '[${image ? 'image' : 'file'}: ${name.isEmpty ? (image ? 'image' : 'file') : name}]';
  }

  static List<Map<String, dynamic>> normalize(List<ChatMessage> msgs, {String? exclude}) {
    final out = <Map<String, dynamic>>[];
    for (final m in msgs) {
      if (m.role != ChatRole.self && m.role != ChatRole.bot) continue;
      if (m.pending != null) continue;
      if (exclude != null && m.wire == exclude) continue;
      final s = m.chanSummary;
      final q = m.quote;
      final seed = m.seed;
      out.add({
        'role': m.role == ChatRole.self ? 'user' : 'assistant',
        'content': m.content,
        'at': m.at.millisecondsSinceEpoch,
        if (q != null && q.isNotEmpty) 'quote': q,
        if (seed != null && seed.isNotEmpty) 'seed': seed,
        if (m.attachments.isNotEmpty)
          'attachments': [
            for (final a in m.attachments) {'kind': a.kind == AttachmentKind.image ? 'image' : 'file', 'name': a.name},
          ],
        if (s != null && s.text.isNotEmpty) 'summary': s.toJson(),
      });
    }
    return out;
  }

  static List<Map<String, dynamic>> _rows(List<Map<String, dynamic>> msgs, int upto) {
    final rows = <Map<String, dynamic>>[];
    var skipping = false;
    for (final m in msgs) {
      final role = m['role'];
      final text = m['content'] is String ? m['content'] as String : '';
      if (role == 'user') {
        skipping = _bang.hasMatch(text);
        if (skipping) continue;
      } else if (role != 'assistant' || skipping) {
        continue;
      }
      var body = text;
      if (role == 'user') {
        final seed = m['seed'];
        final quote = m['quote'];
        final head = seed is String && seed.isNotEmpty ? '$seedHead$seed\n\n' : '';
        final quoted = quote is String && quote.isNotEmpty ? '> ${quote.split('\n').join('\n> ')}\n\n' : '';
        body = '$head$quoted$body';
      }
      final atts = m['attachments'];
      final refs = <String>[
        if (atts is List)
          for (final a in atts)
            if (a is Map) _reference(a.cast<String, dynamic>()),
      ];
      final content = [body, ...refs].where((x) => x.isNotEmpty).join('\n');
      if (content.isEmpty) continue;
      final at = m['at'] is num ? (m['at'] as num).toInt() : 0;
      if (upto > 0 && at <= upto) continue;
      rows.add({'role': role, 'content': content, 'at': at});
    }
    return rows;
  }

  static Map<String, dynamic> context({required bool threaded, String? seed, required List<Map<String, dynamic>> messages}) {
    if (seed != null && seed.isNotEmpty) return {'history': <Object>[], 'fold': <Object>[], 'summary': null};
    var start = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final s = messages[i]['seed'];
      if (messages[i]['role'] == 'user' && s is String && s.isNotEmpty) {
        start = i;
        break;
      }
    }
    Map? summary;
    for (var i = messages.length - 1; i >= start; i--) {
      final s = messages[i]['summary'];
      if (messages[i]['role'] == 'assistant' && s is Map && s['text'] is String && (s['text'] as String).isNotEmpty) {
        summary = s;
        break;
      }
    }
    final upto = summary != null && summary['upto'] is num ? (summary['upto'] as num).toInt() : 0;
    final rows = _rows(messages.sublist(start), upto);
    final size = threaded ? threadWindow : window;
    final history = rows.length > size ? rows.sublist(rows.length - size) : rows;
    final older = rows.length > keep ? rows.sublist(0, rows.length - keep) : <Map<String, dynamic>>[];
    return {'history': history, 'fold': older.length > foldMax ? older.sublist(0, foldMax) : older, 'summary': summary?['text']};
  }

  static Map<String, dynamic> forChat(List<ChatMessage> msgs, {String? exclude, bool threaded = true, String? seed}) =>
      context(threaded: threaded, seed: seed, messages: normalize(msgs, exclude: exclude));

  static List<Map<String, dynamic>> rows(List<ChatMessage> msgs, {String? exclude}) => _rows(normalize(msgs, exclude: exclude), 0);
}

class ChanRunView {
  ChanRunView(this.run);
  final String run;
  String? draft;
  int seq = 0;
  List<Map<String, dynamic>> plan = const [];
  final List<Map<String, dynamic>> steps = [];
  String? ctl;
  bool accepted = false;
  ChanLink? link;
  Completer<void> _tick = Completer<void>();
  final Completer<void> _first = Completer<void>();

  Future<void> get first => _first.future;

  void arrived() {
    if (!_first.isCompleted) _first.complete();
  }

  void bump() {
    final t = _tick;
    _tick = Completer<void>();
    if (!t.isCompleted) t.complete();
  }

  Future<void> idle(Duration d) => _tick.future.timeout(d, onTimeout: () {});

  void take(ChanEvent ev) {
    final b = ev.body;
    if (ev.type == ChannelType.draft && b['text'] is String) {
      final s = b['seq'] is num ? (b['seq'] as num).toInt() : seq + 1;
      if (s >= seq) {
        seq = s;
        draft = b['text'] as String;
      }
      arrived();
    } else if (ev.type == ChannelType.plan && b['plan'] is List) {
      plan = [for (final p in b['plan'] as List) if (p is Map) p.cast<String, dynamic>()];
    } else if (ev.type == ChannelType.step && b['step'] is Map) {
      final st = (b['step'] as Map).cast<String, dynamic>();
      steps.add({...st, 'n': st['n'] is num ? st['n'] : steps.length + 1});
    } else {
      return;
    }
    bump();
  }
}

class ChanSpec {
  ChanSpec({this.link, required this.rumor, this.rumors = const [], required this.run, this.pq, required this.opts, required this.context, this.resume, this.answer});
  ChanLink? link;
  final Map<String, dynamic> rumor;
  final List<Map<String, dynamic>> rumors;
  final String run;
  final String? pq;
  final Map<String, dynamic> opts;
  final Map<String, dynamic> context;
  final ({String run, String k})? resume;
  final (int, Map<String, dynamic>)? answer;

  String get runId => resume?.run ?? run;
}
