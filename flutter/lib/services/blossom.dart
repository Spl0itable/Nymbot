import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../config.dart';
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
  static Future<String> _auth(String hashHex, EventSigner signer) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final signed = await signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: now,
      kind: 24242,
      tags: [
        const ['t', 'upload'],
        ['x', hashHex],
        ['expiration', '${now + 600}'],
      ],
      content: 'Uploading blob with SHA-256 hash',
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

  /// Uploads bytes and returns the public URL.
  Future<String> put(Uint8List bytes, String mime, EventSigner signer) async {
    final header =
        await _auth(crypto.sha256.convert(bytes).toString(), signer);
    Object? last;
    for (final host in hosts) {
      try {
        return await _putTo(host, bytes, mime, header);
      } catch (e) {
        last = e;
      }
    }
    throw BlossomFailure(
        'The file could not be uploaded — every media host refused it.'
        '${last == null ? '' : ' ($last)'}');
  }
}

class BlossomFailure implements Exception {
  BlossomFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
