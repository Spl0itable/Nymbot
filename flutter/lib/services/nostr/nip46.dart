import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/crypto/bech32_codec.dart' as bech32;
import '../../core/crypto/keys.dart';
import '../../core/crypto/nip44.dart' as nip44;
import '../../core/crypto/schnorr.dart' as schnorr;
import '../../features/i18n/i18n.dart';
import '../../models/nostr_event.dart';
import 'event_signer.dart';

const int nip46Kind = 24133;

const String nip46DefaultRelay = 'wss://relay.primal.net';

const List<String> nip46Perms = [
  'get_public_key',
  'sign_event:27235',
  'sign_event:13',
  'sign_event:30078',
  'sign_event:1',
  'nip44_encrypt',
  'nip44_decrypt',
];

abstract class Nip46Socket {
  Stream<String> get messages;

  void send(String data);

  Future<void> close();
}

typedef Nip46SocketFactory = Nip46Socket Function(String relay);

class _WebSocket implements Nip46Socket {
  _WebSocket(String relay) : _channel = WebSocketChannel.connect(Uri.parse(relay));

  final WebSocketChannel _channel;

  @override
  Stream<String> get messages =>
      _channel.stream.where((e) => e is String).cast<String>();

  @override
  void send(String data) {
    try {
      _channel.sink.add(data);
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {}
  }
}

Nip46Socket _openWebSocket(String relay) => _WebSocket(relay);

class Nip46Uri {
  const Nip46Uri({required this.pubkey, required this.relays, this.secret});

  final String pubkey;
  final List<String> relays;
  final String? secret;

  static String canonicalRelay(String url) {
    final t = url.trim();
    return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
  }

  static bool validRelay(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        (uri.scheme == 'wss' || uri.scheme == 'ws') &&
        uri.host.isNotEmpty;
  }

  static Nip46Uri parseBunker(String input) {
    final text = input.trim();
    if (!text.toLowerCase().startsWith('bunker://')) {
      throw SignerFailure(t('Paste a bunker:// link from your signer.'));
    }
    final rest = text.substring('bunker://'.length);
    final q = rest.indexOf('?');
    final host = (q < 0 ? rest : rest.substring(0, q)).trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(host)) {
      throw SignerFailure(t('That bunker link does not name a valid signer key.'));
    }
    final relays = <String>[];
    String? secret;
    if (q >= 0) {
      for (final part in rest.substring(q + 1).split('&')) {
        if (part.isEmpty) continue;
        final eq = part.indexOf('=');
        final key = eq < 0 ? part : part.substring(0, eq);
        final value =
            Uri.decodeQueryComponent(eq < 0 ? '' : part.substring(eq + 1));
        if (key == 'relay' && validRelay(value)) {
          final relay = canonicalRelay(value);
          if (!relays.contains(relay)) relays.add(relay);
        } else if (key == 'secret' && value.isNotEmpty) {
          secret = value;
        }
      }
    }
    if (relays.isEmpty) {
      throw SignerFailure(t('That bunker link names no relay.'));
    }
    return Nip46Uri(pubkey: host, relays: relays, secret: secret);
  }
}

class _Pending {
  _Pending(this.completer, this.timer);

  final Completer<Object?> completer;
  Timer timer;
}

class Nip46Signer implements RemoteSigner {
  Nip46Signer._({
    required Uint8List clientSk,
    required this.relays,
    String? remotePubkey,
    String? userPubkey,
    String? secret,
    Nip46SocketFactory? sockets,
    this.timeout = const Duration(seconds: 60),
  })  : _clientSk = clientSk,
        clientPubkey = getPublicKeyHex(clientSk),
        _remote = remotePubkey,
        _user = userPubkey,
        _secret = secret,
        _sockets = sockets ?? _openWebSocket;

  final Uint8List _clientSk;
  final String clientPubkey;
  final List<String> relays;
  final Duration timeout;
  final Nip46SocketFactory _sockets;
  final String? _secret;
  String? _remote;
  String? _user;

  void Function(String url)? onAuthUrl;

  final Map<String, Nip46Socket> _open = {};
  final List<StreamSubscription<String>> _taps = [];
  final Map<String, _Pending> _pending = {};
  final Set<String> _seen = {};
  Completer<String>? _pairing;
  bool _sawBareAck = false;
  bool _closed = false;
  int _counter = 0;
  String _subId = '';

  String? get remotePubkey => _remote;

  @override
  String get pubkey => _user ?? '';

  @override
  bool get isRemote => true;

  @override
  String get method => 'nip46';

  @override
  Map<String, dynamic> get session => {
        'method': 'nip46',
        'client': bytesToHex(_clientSk),
        'remote': _remote,
        'relays': relays,
        'pubkey': _user,
      };

  static Nip46Signer? restore(Map<String, dynamic> session,
      {Nip46SocketFactory? sockets}) {
    try {
      final client = session['client'] as String;
      final remote = session['remote'] as String;
      final user = session['pubkey'] as String;
      final relays = (session['relays'] as List).cast<String>();
      if (!_isKey(remote) || !_isKey(user) || relays.isEmpty) return null;
      return Nip46Signer._(
        clientSk: hexToBytes(client),
        relays: relays,
        remotePubkey: remote,
        userPubkey: user,
        sockets: sockets,
      );
    } catch (_) {
      return null;
    }
  }

  static Nip46Signer offer({
    List<String> relays = const [nip46DefaultRelay],
    Nip46SocketFactory? sockets,
    Duration timeout = const Duration(seconds: 60),
  }) {
    final clean = [
      for (final r in relays)
        if (Nip46Uri.validRelay(r)) Nip46Uri.canonicalRelay(r),
    ];
    if (clean.isEmpty) {
      throw SignerFailure(t('Enter a relay address that starts with wss://.'));
    }
    return Nip46Signer._(
      clientSk: generatePrivateKey(),
      relays: clean,
      secret: bytesToHex(randomBytes(16)),
      sockets: sockets,
      timeout: timeout,
    );
  }

  String get connectUri {
    final secret = _secret ?? '';
    final params = <String>[
      for (final r in relays) 'relay=${Uri.encodeQueryComponent(r)}',
      'secret=${Uri.encodeQueryComponent(secret)}',
      'perms=${Uri.encodeQueryComponent(nip46Perms.join(','))}',
      'name=Nymbot',
      'url=${Uri.encodeQueryComponent('https://nymbot.ai')}',
      'metadata=${Uri.encodeQueryComponent(jsonEncode({'name': 'Nymbot'}))}',
    ];
    return 'nostrconnect://$clientPubkey?${params.join('&')}';
  }

  Future<void> waitForSigner({Duration within = const Duration(minutes: 5)}) async {
    if (_secret == null) throw StateError('not an offer');
    final pairing = _pairing ??= Completer<String>();
    _ensureOpen();
    try {
      await pairing.future.timeout(within);
    } on TimeoutException {
      throw SignerFailure(_sawBareAck
          ? t('A signer answered without the connection secret, so Nymbot did not trust it. Update your signer app, or paste a bunker:// link instead.')
          : t('No signer answered in time. Try again.'));
    }
    await _fetchUser();
  }

  static Future<Nip46Signer> bunker(
    String link, {
    Nip46SocketFactory? sockets,
    Duration timeout = const Duration(seconds: 60),
    void Function(String url)? onAuthUrl,
  }) async {
    final parsed = Nip46Uri.parseBunker(link);
    final signer = Nip46Signer._(
      clientSk: generatePrivateKey(),
      relays: parsed.relays,
      remotePubkey: parsed.pubkey,
      sockets: sockets,
      timeout: timeout,
    )..onAuthUrl = onAuthUrl;
    try {
      final secret = parsed.secret;
      final result = await signer._request('connect', [
        parsed.pubkey,
        if (secret != null) secret,
        if (secret != null) nip46Perms.join(','),
      ]);
      if (result != 'ack' && (secret == null || result != secret)) {
        throw SignerFailure(t('The signer did not accept the connection.'));
      }
      await signer._fetchUser();
      return signer;
    } catch (_) {
      await signer.close();
      rethrow;
    }
  }

  Future<void> _fetchUser() async {
    final result = await _request('get_public_key', const []);
    final user = result is String ? result.trim().toLowerCase() : '';
    final hex = user.startsWith('npub1') ? _npubHex(user) : user;
    if (hex == null || !_isKey(hex) || !_onCurve(hex)) {
      throw SignerFailure(t('The signer returned a public key that is not valid.'));
    }
    _user = hex;
  }

  static String? _npubHex(String npub) {
    try {
      return bech32.decodeNpub(npub);
    } catch (_) {
      return null;
    }
  }

  static bool _isKey(String? value) =>
      value != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  bool _onCurve(String hex) {
    try {
      nip44.getConversationKey(_clientSk, hex);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _ensureOpen() {
    if (_closed) throw SignerFailure(t('The signer connection is closed.'));
    if (_subId.isEmpty) _subId = 'nymbot-nip46-${bytesToHex(randomBytes(6))}';
    for (final relay in relays) {
      if (_open.containsKey(relay)) continue;
      final Nip46Socket socket;
      try {
        socket = _sockets(relay);
      } catch (_) {
        continue;
      }
      _open[relay] = socket;
      _taps.add(socket.messages.listen(
        _onFrame,
        onError: (_) {},
        onDone: () {
          if (identical(_open[relay], socket)) _open.remove(relay);
        },
        cancelOnError: false,
      ));
      socket.send(jsonEncode([
        'REQ',
        _subId,
        {
          'kinds': [nip46Kind],
          '#p': [clientPubkey],
          'since': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 10,
        },
      ]));
    }
    if (_open.isEmpty) {
      throw SignerFailure(t('Could not reach the signer relay.'));
    }
  }

  void _onFrame(String data) {
    Object? frame;
    try {
      frame = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (frame is! List || frame.length < 3 || frame[0] != 'EVENT') return;
    if (frame[1] != _subId || frame[2] is! Map) return;
    try {
      _onEvent(NostrEvent.fromJson(Map<String, dynamic>.from(frame[2] as Map)));
    } catch (_) {}
  }

  void _onEvent(NostrEvent event) {
    if (event.kind != nip46Kind) return;
    if (!event.tags.any((t) => t.length > 1 && t[0] == 'p' && t[1] == clientPubkey)) {
      return;
    }
    final remote = _remote;
    if (remote != null && event.pubkey != remote) return;
    if (_seen.contains(event.id) || !schnorr.verifyEvent(event)) return;
    _seen.add(event.id);
    if (_seen.length > 500) _seen.remove(_seen.first);
    Map<String, dynamic> reply;
    try {
      final plain = nip44.decrypt(
          event.content, nip44.getConversationKey(_clientSk, event.pubkey));
      final parsed = jsonDecode(plain);
      if (parsed is! Map) return;
      reply = Map<String, dynamic>.from(parsed);
    } catch (_) {
      return;
    }
    final result = reply['result'];
    final error = reply['error'];
    if (remote == null) {
      final secret = _secret;
      final pairing = _pairing;
      if (secret == null || pairing == null || pairing.isCompleted) return;
      if (result is String && result == secret) {
        _remote = event.pubkey;
        pairing.complete(event.pubkey);
      } else if (result == 'ack') {
        _sawBareAck = true;
      }
      return;
    }
    final id = reply['id'];
    if (id is! String) return;
    final pending = _pending[id];
    if (pending == null) return;
    if (result == 'auth_url') {
      final url = error is String ? Uri.tryParse(error) : null;
      if (url != null && url.scheme == 'https') {
        pending.timer.cancel();
        pending.timer = Timer(timeout * 3, () => _expire(id));
        onAuthUrl?.call(url.toString());
      }
      return;
    }
    _pending.remove(id);
    pending.timer.cancel();
    if (pending.completer.isCompleted) return;
    if (error is String && error.isNotEmpty) {
      pending.completer.completeError(
          SignerFailure(t('Your signer declined: {reason}', {'reason': error})));
    } else {
      pending.completer.complete(result);
    }
  }

  void _expire(String id) {
    final pending = _pending.remove(id);
    if (pending == null || pending.completer.isCompleted) return;
    pending.completer.completeError(
        SignerFailure(t('Your signer did not answer in time.')));
  }

  Future<Object?> _request(String method, List<String> params) async {
    final remote = _remote;
    if (remote == null) throw SignerFailure(t('No signer is connected.'));
    _ensureOpen();
    final id = '${bytesToHex(randomBytes(8))}${_counter++}';
    final content = nip44.encrypt(
      jsonEncode({'id': id, 'method': method, 'params': params}),
      nip44.getConversationKey(_clientSk, remote),
    );
    final event = schnorr.finalizeEvent(
      UnsignedEvent(
        pubkey: clientPubkey,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: nip46Kind,
        tags: [
          ['p', remote],
        ],
        content: content,
      ),
      _clientSk,
    );
    final completer = Completer<Object?>();
    _pending[id] = _Pending(completer, Timer(timeout, () => _expire(id)));
    final frame = jsonEncode(['EVENT', event.toJson()]);
    for (final socket in _open.values.toList()) {
      socket.send(frame);
    }
    return completer.future;
  }

  @override
  Future<NostrEvent> sign(UnsignedEvent unsigned) async {
    final asked = UnsignedEvent(
      pubkey: pubkey,
      createdAt: unsigned.createdAt,
      kind: unsigned.kind,
      tags: unsigned.tags,
      content: unsigned.content,
    );
    final result = await _request('sign_event', [jsonEncode(asked.toJson())]);
    Object? parsed = result;
    if (result is String) {
      try {
        parsed = jsonDecode(result);
      } catch (_) {
        parsed = null;
      }
    }
    if (parsed is! Map) {
      throw SignerFailure(t('Your signer returned something that is not a signed event.'));
    }
    return checkSigned(
        asked, NostrEvent.fromJson(Map<String, dynamic>.from(parsed)), pubkey);
  }

  @override
  Future<String> nip44Encrypt(String peerPubkey, String plaintext) async {
    final result = await _request('nip44_encrypt', [peerPubkey, plaintext]);
    if (result is! String || result.isEmpty) {
      throw SignerFailure(t('Your signer could not encrypt that.'));
    }
    return result;
  }

  @override
  Future<String> nip44Decrypt(String peerPubkey, String ciphertext) async {
    final result = await _request('nip44_decrypt', [peerPubkey, ciphertext]);
    if (result is! String) {
      throw SignerFailure(t('Your signer could not decrypt that.'));
    }
    return result;
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final id in _pending.keys.toList()) {
      final pending = _pending.remove(id)!;
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer
            .completeError(SignerFailure(t('The signer connection is closed.')));
      }
    }
    final pairing = _pairing;
    if (pairing != null && !pairing.isCompleted) {
      pairing.completeError(SignerFailure(t('Canceled.')));
    }
    for (final tap in _taps) {
      await tap.cancel();
    }
    _taps.clear();
    for (final socket in _open.values.toList()) {
      socket.send(jsonEncode(['CLOSE', _subId]));
      await socket.close();
    }
    _open.clear();
  }
}
