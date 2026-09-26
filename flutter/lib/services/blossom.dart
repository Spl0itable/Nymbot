import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/crypto/keys.dart' as keys;
import '../models/nostr_event.dart';
import 'nostr/event_signer.dart';

/// Uploading a file so the model can actually see it.
class Blossom {
  Blossom({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// The same hosts Nymchat mirrors across, so a blob uploaded in one app
  /// resolves in the other.
  static const List<String> hosts = [
    'https://blossom.band',
    'https://blossom.primal.net',
    'https://nostr.download',
  ];

  /// Uploads go through the worker's media proxy: it holds the CORS headers the
  /// hosts do not all send, and it keeps the uploader's address off them.
  static String uploadUrl(String host) =>
      'https://${NymbotConfig.apiHost}/api/proxy'
      '?action=upload&server=${Uri.encodeComponent(host)}';

  /// BUD-02 upload auth.
  static Future<String> _auth(String hashHex, EventSigner signer,
      {String verb = 'upload'}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final signed = await signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: now,
      kind: 24242,
      tags: [
        ['t', verb],
        ['x', hashHex],
        ['expiration', '${now + 600}'],
      ],
      content: verb == 'delete'
          ? 'Delete blob'
          : 'Uploading blob with SHA-256 hash',
    ));
    return 'Nostr ${base64Encode(utf8.encode(jsonEncode(signed.toJson())))}';
  }

  Future<String> _putTo(
      String host, Uint8List bytes, String mime, String header) async {
    final resp = await _client
        .put(
          Uri.parse(uploadUrl(host)),
          headers: {
            'Authorization': header,
            'Content-Type': mime.isEmpty ? 'application/octet-stream' : mime,
            'User-Agent': NymbotConfig.userAgent,
          },
          body: bytes,
        )
        .timeout(const Duration(seconds: 45));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw BlossomFailure('HTTP ${resp.statusCode}');
    }
    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) throw BlossomFailure('no url');
    final url = decoded['url'] ??
        (decoded['nip94'] is Map ? decoded['nip94']['url'] : null);
    if (url is! String || url.isEmpty) throw BlossomFailure('no url');
    return url;
  }

  Future<BlossomPlacement> placeUnlinked(Uint8List bytes, String mime) async {
    final sk = keys.generatePrivateKey();
    final placed = await place(bytes, mime, LocalSigner(sk));
    return BlossomPlacement(
      url: placed.url,
      host: placed.host,
      sha256: placed.sha256,
      sk: keys.bytesToHex(sk),
    );
  }

  Future<BlossomPlacement> place(
      Uint8List bytes, String mime, EventSigner signer) async {
    final sha256 = crypto.sha256.convert(bytes).toString();
    final header = await _auth(sha256, signer);
    Object? last;
    for (final host in hosts) {
      try {
        final url = await _putTo(host, bytes, mime, header);
        return BlossomPlacement(url: url, host: host, sha256: sha256);
      } catch (e) {
        last = e;
      }
    }
    throw BlossomFailure(
        'The file could not be uploaded — every media host refused it.'
        '${last == null ? '' : ' ($last)'}');
  }

  Future<BlossomSpread> spread(
      Uint8List bytes, String mime, EventSigner signer) async {
    final sha256 = crypto.sha256.convert(bytes).toString();
    final header = await _auth(sha256, signer);
    Object? last;
    final tries = await Future.wait(NymbotConfig.shareHosts.map((host) async {
      try {
        await _putTo(host, bytes, mime, header);
        return host;
      } catch (e) {
        last = e;
        return null;
      }
    }));
    final accepted = tries.whereType<String>().toList();
    if (accepted.isEmpty) {
      throw BlossomFailure(
          'The file could not be uploaded — every media host refused it.'
          '${last == null ? '' : ' ($last)'}');
    }
    return BlossomSpread(hosts: accepted, sha256: sha256);
  }

  Future<int> remove(String host, String sha256, EventSigner signer) async {
    final header = await _auth(sha256, signer, verb: 'delete');
    final resp = await _client
        .post(
          Uri.parse('https://${NymbotConfig.apiHost}/api/proxy'
              '?action=delete&server=${Uri.encodeComponent(host)}'
              '&x=${Uri.encodeComponent(sha256)}'),
          headers: {
            'Authorization': header,
            'User-Agent': NymbotConfig.userAgent,
          },
        )
        .timeout(const Duration(seconds: 30));
    return resp.statusCode;
  }
}

class BlossomPlacement {
  const BlossomPlacement(
      {required this.url,
      required this.host,
      required this.sha256,
      this.sk = ''});
  final String url;
  final String host;
  final String sha256;
  final String sk;
}

class BlossomSpread {
  const BlossomSpread({required this.hosts, required this.sha256});
  final List<String> hosts;
  final String sha256;
  String get host => hosts.first;
}

class UploadLedger {
  UploadLedger({required this.readRecords, required this.writeRecords});

  static const cap = 500;

  final Future<String?> Function() readRecords;
  final Future<void> Function(String json) writeRecords;

  Future<Map<String, Map<String, String>>> _all() async {
    final out = <String, Map<String, String>>{};
    final raw = await readRecords();
    if (raw == null || raw.isEmpty) return out;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return out;
      decoded.forEach((k, v) {
        if (k is! String || v is! Map) return;
        final host = v['server'], sha = v['sha256'], sk = v['sk'];
        if (host is String && sha is String && sk is String) {
          out[k] = {'server': host, 'sha256': sha, 'sk': sk};
        }
      });
    } catch (_) {}
    return out;
  }

  Future<void> remember(BlossomPlacement placed) async {
    if (placed.sk.isEmpty) return;
    final all = await _all();
    all.remove(placed.url);
    all[placed.url] = {
      'server': placed.host,
      'sha256': placed.sha256,
      'sk': placed.sk,
    };
    while (all.length > cap) {
      all.remove(all.keys.first);
    }
    await writeRecords(jsonEncode(all));
  }

  Future<BlossomPlacement?> lookup(String url) async {
    final hit = (await _all())[url];
    if (hit == null) return null;
    return BlossomPlacement(
      url: url,
      host: hit['server']!,
      sha256: hit['sha256']!,
      sk: hit['sk']!,
    );
  }

  Future<void> forget(String url) async {
    final all = await _all();
    if (all.remove(url) == null) return;
    await writeRecords(jsonEncode(all));
  }
}

class BlossomFailure implements Exception {
  BlossomFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
