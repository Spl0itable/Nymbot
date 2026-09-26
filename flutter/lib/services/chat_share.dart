import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/crypto/keys.dart' as keys;
import '../models/conversation.dart';
import '../models/nostr_event.dart';
import '../models/workspace.dart';
import '../features/i18n/i18n.dart';
import 'blossom.dart';
import 'nostr/event_signer.dart';

class ShareOptions {
  const ShareOptions({
    this.upTo,
    this.reasoning = false,
    this.sources = true,
    this.files = false,
    this.images = false,
  });

  final String? upTo;
  final bool reasoning;
  final bool sources;
  final bool files;
  final bool images;

  ShareOptions copyWith({
    String? upTo,
    bool clearUpTo = false,
    bool? reasoning,
    bool? sources,
    bool? files,
    bool? images,
  }) =>
      ShareOptions(
        upTo: clearUpTo ? null : (upTo ?? this.upTo),
        reasoning: reasoning ?? this.reasoning,
        sources: sources ?? this.sources,
        files: files ?? this.files,
        images: images ?? this.images,
      );
}

class SealedShare {
  const SealedShare(this.bytes, this.key);
  final Uint8List bytes;
  final Uint8List key;
}

class ShareRef {
  const ShareRef(
      {required this.server, required this.sha256, required this.key});
  final String server;
  final String sha256;
  final Uint8List key;
}

class ShareRecord {
  ShareRecord({
    required this.id,
    required this.link,
    required this.server,
    required this.sha256,
    required this.createdAt,
    required this.included,
    required this.sk,
    List<String>? servers,
    List<String>? notes,
  })  : servers = (servers == null || servers.isEmpty) ? [server] : servers,
        notes = notes ?? [];

  final String id;
  final String link;
  final String server;
  final List<String> servers;
  final String sha256;
  final int createdAt;
  final Map<String, dynamic> included;
  final String sk;
  final List<String> notes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'link': link,
        'server': server,
        'servers': servers,
        'sha256': sha256,
        'createdAt': createdAt,
        'included': included,
        'sk': sk,
        'notes': notes,
      };

  static ShareRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    if (j['id'] is! String || j['link'] is! String || j['sk'] is! String) {
      return null;
    }
    return ShareRecord(
      id: j['id'] as String,
      link: j['link'] as String,
      server: (j['server'] ?? '') as String,
      sha256: (j['sha256'] ?? '') as String,
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      included: (j['included'] is Map)
          ? (j['included'] as Map).cast<String, dynamic>()
          : <String, dynamic>{},
      sk: j['sk'] as String,
      servers: (j['servers'] as List?)?.whereType<String>().toList(),
      notes: (j['notes'] as List?)?.whereType<String>().toList(),
    );
  }
}

class ShareFailure implements Exception {
  ShareFailure(this.message, {this.gone = false});
  final String message;
  final bool gone;
  @override
  String toString() => message;
}

class ChatShare {
  const ChatShare._();

  static const int schema = 1;
  static const int format = 1;
  static const int ivBytes = 12;
  static const int tagBytes = 16;
  static const int maxBytes = 12 * 1024 * 1024;
  static const Map<String, String> app = {
    'name': 'nymbot-flutter',
    'version': '1.0.6',
  };

  static final AesGcm _aes = AesGcm.with256bits();

  static String b64url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List unb64url(String text) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(text)) {
      throw const FormatException('bad base64');
    }
    return Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));
  }

  static String? roleOf(ChatMessage m) => switch (m.role) {
        ChatRole.self => 'user',
        ChatRole.bot => 'assistant',
        _ => null,
      };

  static List<ChatMessage> shareable(List<ChatMessage> messages) => messages
      .where((m) =>
          roleOf(m) != null &&
          (m.content.trim().isNotEmpty || m.attachments.isNotEmpty))
      .toList();

  static List<Map<String, String>> cleanSources(
      List<Map<String, dynamic>> list) {
    final out = <Map<String, String>>[];
    for (final s in list) {
      final url = s['url'];
      if (url is! String || !RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
        continue;
      }
      final rawTitle = s['title'] ?? s['name'] ?? '';
      final title = rawTitle is String
          ? (rawTitle.length > 300 ? rawTitle.substring(0, 300) : rawTitle)
          : '';
      out.add(title.isEmpty ? {'url': url} : {'url': url, 'title': title});
      if (out.length == 20) break;
    }
    return out;
  }

  static Map<String, dynamic> build(
    Conversation conv,
    List<ChatMessage> messages,
    ShareOptions options, {
    int? now,
  }) {
    final list = shareable(messages);
    var end = list.length;
    if (options.upTo != null) {
      final at = list.indexWhere((m) => m.id == options.upTo);
      if (at != -1) end = at + 1;
    }
    final out = <Map<String, dynamic>>[];
    for (final m in list.take(end)) {
      final role = roleOf(m)!;
      final item = <String, dynamic>{
        'role': role,
        'content': m.content,
        'model': role == 'assistant' && m.model != null ? m.model : null,
        'ts': m.at.millisecondsSinceEpoch,
      };
      if (options.sources) {
        final sources = cleanSources(m.sources);
        if (sources.isNotEmpty) item['sources'] = sources;
      }
      final thinking = m.thinking;
      if (options.reasoning && thinking != null && thinking.isNotEmpty) {
        item['reasoning'] = thinking;
      }
      final files = <Map<String, dynamic>>[];
      for (final a in m.attachments) {
        if (a.kind == AttachmentKind.image && options.images) {
          final data = a.bytesBase64;
          final mime = a.mime.isEmpty ? 'image/png' : a.mime;
          if (data != null &&
              data.isNotEmpty &&
              RegExp(r'^image/(png|jpe?g|gif|webp|avif)$').hasMatch(mime)) {
            files.add({
              'kind': 'image',
              'name': a.name.isEmpty ? 'image' : a.name,
              'data': 'data:$mime;base64,$data',
            });
          }
        } else if (a.kind == AttachmentKind.text && options.files) {
          files.add({
            'kind': 'text',
            'name': a.name.isEmpty ? 'file' : a.name,
            'text': a.text,
          });
        }
      }
      if (files.isNotEmpty) item['attachments'] = files;
      if (m.content.trim().isEmpty && files.isEmpty) continue;
      out.add(item);
    }
    return {
      'v': schema,
      'title': conv.title,
      'sharedAt': now ?? DateTime.now().millisecondsSinceEpoch,
      'app': Map<String, String>.from(app),
      'messages': out,
    };
  }

  static bool valid(Object? transcript) {
    if (transcript is! Map) return false;
    if (transcript['v'] != schema) return false;
    final messages = transcript['messages'];
    if (messages is! List) return false;
    return messages.every((m) =>
        m is Map &&
        (m['role'] == 'user' || m['role'] == 'assistant') &&
        m['content'] is String);
  }

  static Future<SealedShare> seal(String plaintext,
      {Uint8List? key, Uint8List? iv}) async {
    final k = key ?? keys.randomBytes(32);
    final nonce = iv ?? keys.randomBytes(ivBytes);
    final box = await _aes.encrypt(utf8.encode(plaintext),
        secretKey: SecretKey(k), nonce: nonce);
    final out = BytesBuilder(copy: false)
      ..addByte(format)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return SealedShare(out.toBytes(), Uint8List.fromList(k));
  }

  static Future<String> openText(Uint8List bytes, Uint8List key) async {
    if (bytes.length < 1 + ivBytes + tagBytes || bytes[0] != format) {
      throw ShareFailure('format');
    }
    if (key.length != 32) throw ShareFailure('key');
    final nonce = bytes.sublist(1, 1 + ivBytes);
    final body = bytes.sublist(1 + ivBytes, bytes.length - tagBytes);
    final mac = Mac(bytes.sublist(bytes.length - tagBytes));
    final plain = await _aes.decrypt(
        SecretBox(body, nonce: nonce, mac: mac),
        secretKey: SecretKey(key));
    return utf8.decode(plain);
  }

  static Future<Map<String, dynamic>> open(
      Uint8List bytes, Uint8List key) async {
    final decoded = jsonDecode(await openText(bytes, key));
    if (!valid(decoded)) throw ShareFailure('schema');
    return (decoded as Map).cast<String, dynamic>();
  }

  static String link(String server, String sha256, Uint8List key,
      {String? origin}) {
    final head = b64url(
        utf8.encode(jsonEncode({'v': 1, 's': server, 'x': sha256})));
    return '${origin ?? 'https://${NymbotConfig.apiHost}'}/app/share#$head.${b64url(key)}';
  }

  static ShareRef parse(String fragment) {
    var raw = fragment.trim();
    final hash = raw.indexOf('#');
    if (hash != -1) raw = raw.substring(hash + 1);
    final dot = raw.indexOf('.');
    if (dot < 1) throw ShareFailure('bad link');
    try {
      final head = jsonDecode(utf8.decode(unb64url(raw.substring(0, dot))));
      final key = unb64url(raw.substring(dot + 1));
      final server = head is Map ? '${head['s'] ?? ''}' : '';
      final sha256 = head is Map ? '${head['x'] ?? ''}'.toLowerCase() : '';
      if (!RegExp(r'^https://[a-z0-9.-]+$', caseSensitive: false)
          .hasMatch(server)) {
        throw ShareFailure('bad server');
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
        throw ShareFailure('bad hash');
      }
      if (key.length != 32) throw ShareFailure('bad key');
      return ShareRef(server: server, sha256: sha256, key: key);
    } on ShareFailure {
      rethrow;
    } catch (_) {
      throw ShareFailure('bad link');
    }
  }

  static String blobUrl(String server, String sha256) =>
      'https://${NymbotConfig.apiHost}/api/proxy?action=share-blob'
      '&server=${Uri.encodeComponent(server)}&x=${Uri.encodeComponent(sha256)}';

  static List<String> candidates(ShareRef ref) => ref.server == Blossom.ownOrigin
      ? [ref.server]
      : [
          ref.server,
          ...NymbotConfig.shareHosts.where((h) => h != ref.server),
        ];

  static Future<Uint8List> fetchBlob(ShareRef ref,
      {http.Client? client}) async {
    final c = client ?? http.Client();
    final hosts = candidates(ref);
    var gone = 0;
    Object? last;
    for (final server in hosts) {
      try {
        final resp = await c.get(Uri.parse(blobUrl(server, ref.sha256)),
            headers: {'User-Agent': NymbotConfig.userAgent});
        if (resp.statusCode == 404 || resp.statusCode == 410) {
          gone++;
          continue;
        }
        if (resp.statusCode != 200) {
          last = ShareFailure('HTTP ${resp.statusCode}');
          continue;
        }
        final bytes = resp.bodyBytes;
        if (crypto.sha256.convert(bytes).toString() != ref.sha256) {
          last = ShareFailure('hash');
          continue;
        }
        return bytes;
      } catch (e) {
        last = e;
      }
    }
    if (gone == hosts.length) throw ShareFailure('gone', gone: true);
    if (last is ShareFailure) throw last;
    throw ShareFailure(last == null ? 'unavailable' : '$last');
  }

  static Future<Map<String, dynamic>> fetch(ShareRef ref,
      {http.Client? client}) async =>
      open(await fetchBlob(ref, client: client), ref.key);

  static String summary(Map<String, dynamic> transcript) {
    final msgs = (transcript['messages'] as List).cast<Map<String, dynamic>>();
    var sources = 0, images = 0, files = 0, reasoning = 0;
    for (final m in msgs) {
      sources += (m['sources'] as List?)?.length ?? 0;
      if (m['reasoning'] != null) reasoning++;
      for (final a in (m['attachments'] as List?) ?? const []) {
        if (a is Map && a['kind'] == 'image') images++;
        if (a is Map && a['kind'] == 'text') files++;
      }
    }
    final parts = <String>[
      msgs.length == 1
          ? t('1 message')
          : t('{n} messages', {'n': msgs.length}),
    ];
    if (sources > 0) {
      parts.add(sources == 1 ? t('1 source') : t('{n} sources', {'n': sources}));
    }
    if (reasoning > 0) parts.add(t('reasoning on {n}', {'n': reasoning}));
    if (files > 0) {
      parts.add(files == 1 ? t('1 file') : t('{n} files', {'n': files}));
    }
    if (images > 0) {
      parts.add(images == 1 ? t('1 image') : t('{n} images', {'n': images}));
    }
    return parts.join(' · ');
  }

  static String includedText(Map<String, dynamic> inc) {
    final n = (inc['messages'] as num?)?.toInt() ?? 0;
    final parts = <String>[
      n == 1 ? t('1 message') : t('{n} messages', {'n': n}),
    ];
    if (inc['sources'] == true) parts.add(t('sources'));
    if (inc['reasoning'] == true) parts.add(t('reasoning'));
    if (inc['files'] == true) parts.add(t('attached text'));
    if (inc['images'] == true) parts.add(t('images'));
    return parts.join(', ');
  }
}

class ChatShareService {
  ChatShareService({
    required this.blossom,
    required this.readRecords,
    required this.writeRecords,
  });

  final Blossom blossom;
  final Future<String?> Function() readRecords;
  final Future<void> Function(String json) writeRecords;

  Future<Map<String, List<ShareRecord>>> _all() async {
    final raw = await readRecords();
    final out = <String, List<ShareRecord>>{};
    if (raw == null || raw.isEmpty) return out;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return out;
      decoded.forEach((k, v) {
        if (k is String && v is List) {
          final list = v.map(ShareRecord.fromJson).whereType<ShareRecord>().toList();
          if (list.isNotEmpty) out[k] = list;
        }
      });
    } catch (_) {}
    return out;
  }

  Future<void> _save(Map<String, List<ShareRecord>> all) => writeRecords(
      jsonEncode(all.map((k, v) => MapEntry(k, v.map((r) => r.toJson()).toList()))));

  static const shareTtlMs = 24 * 60 * 60 * 1000;

  static bool live(ShareRecord r, int nowMs) =>
      r.createdAt <= 0 || nowMs - r.createdAt < shareTtlMs;

  Future<List<ShareRecord>> records(String convId) async {
    final all = await _all();
    final list = all[convId] ?? const <ShareRecord>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    final kept = [for (final r in list) if (live(r, now)) r];
    if (kept.length != list.length) {
      if (kept.isEmpty) {
        all.remove(convId);
      } else {
        all[convId] = kept;
      }
      await _save(all);
    }
    return kept;
  }

  static LocalSigner signerFor(String skHex) =>
      LocalSigner(keys.hexToBytes(skHex));

  Future<ShareRecord> create(
      Conversation conv, List<ChatMessage> messages, ShareOptions options) async {
    final transcript = ChatShare.build(conv, messages, options);
    final count = (transcript['messages'] as List).length;
    if (count == 0) {
      throw ShareFailure(t('There is nothing to share in this chat yet.'));
    }
    final sealed = await ChatShare.seal(jsonEncode(transcript));
    if (sealed.bytes.length > ChatShare.maxBytes) {
      throw ShareFailure(t(
          'That is too large to share. Leave the images out, or share less of the chat.'));
    }
    final skHex = keys.bytesToHex(keys.generatePrivateKey());
    final placed = await blossom.storeShare(sealed.bytes, signerFor(skHex));
    final record = ShareRecord(
      id: keys.bytesToHex(keys.randomBytes(8)),
      link: ChatShare.link(placed.host, placed.sha256, sealed.key),
      server: placed.host,
      servers: placed.hosts,
      sha256: placed.sha256,
      createdAt: transcript['sharedAt'] as int,
      included: {
        'messages': count,
        'upTo': options.upTo,
        'reasoning': options.reasoning,
        'sources': options.sources,
        'files': options.files,
        'images': options.images,
      },
      sk: skHex,
    );
    final all = await _all();
    all[conv.id] = [...?all[conv.id], record];
    await _save(all);
    return record;
  }

  Future<bool> stop(String convId, ShareRecord record) async {
    final done = await Future.wait(record.servers.map((server) => blossom
        .remove(server, record.sha256, signerFor(record.sk))
        .catchError((_) => 0)));
    final all = await _all();
    final next = (all[convId] ?? const <ShareRecord>[])
        .where((r) => r.id != record.id)
        .toList();
    if (next.isEmpty) {
      all.remove(convId);
    } else {
      all[convId] = next;
    }
    await _save(all);
    return done.every((status) => status == 200);
  }

  Future<int> postNote(
    Conversation conv,
    ShareRecord record,
    String comment,
    EventSigner signer,
    Future<int> Function(NostrEvent event) publish,
  ) async {
    if (conv.anon) {
      throw ShareFailure(
          t('An anonymous chat cannot be posted under your key.'));
    }
    final note = comment.trim();
    final event = await signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: 1,
      content: note.isEmpty ? record.link : '$note\n\n${record.link}',
    ));
    final accepted = await publish(event);
    if (accepted > 0) {
      final all = await _all();
      all[conv.id] = [
        for (final r in all[conv.id] ?? const <ShareRecord>[])
          if (r.id == record.id)
            ShareRecord(
              id: r.id,
              link: r.link,
              server: r.server,
              servers: r.servers,
              sha256: r.sha256,
              createdAt: r.createdAt,
              included: r.included,
              sk: r.sk,
              notes: [...r.notes, event.id],
            )
          else
            r,
      ];
      await _save(all);
    }
    return accepted;
  }
}
