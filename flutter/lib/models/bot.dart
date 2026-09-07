import 'dart:convert';

import '../core/crypto/bech32_codec.dart';

/// A way of answering: a name, standing instructions, a model and a few
/// openers. A bot is shareable precisely because it carries none of the things
/// that would be dangerous to share — no repositories, no tokens, no knowledge
/// files, no transcript.
class Bot {
  Bot({
    required this.id,
    this.name = '',
    this.tagline = '',
    this.icon = 'robot',
    this.instructions = '',
    this.greeting = '',
    this.modelKey,
    this.modelLabel,
    List<String>? starters,
    this.author = '',
    this.naddr = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : starters = starters ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  static const kind = 30078;
  static const dPrefix = 'nym-bot-';

  final String id;
  String name;
  String tagline;
  String icon;
  String instructions;
  String greeting;
  String? modelKey;
  String? modelLabel;
  List<String> starters;
  String author;
  String naddr;
  final DateTime createdAt;
  DateTime updatedAt;

  String get slug {
    final cleaned = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (cleaned.isEmpty) return 'bot';
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  String get dTag => '$dPrefix$slug';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tagline': tagline,
        'icon': icon,
        'instructions': instructions,
        'greeting': greeting,
        'modelKey': modelKey,
        'modelLabel': modelLabel,
        'starters': starters,
        'author': author,
        'naddr': naddr,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static Bot fromJson(Map<String, dynamic> j) => Bot(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        tagline: j['tagline'] as String? ?? '',
        icon: j['icon'] as String? ?? 'robot',
        instructions: j['instructions'] as String? ?? '',
        greeting: j['greeting'] as String? ?? '',
        modelKey: j['modelKey'] as String?,
        modelLabel: j['modelLabel'] as String?,
        starters: (j['starters'] as List?)?.whereType<String>().toList(),
        author: j['author'] as String? ?? '',
        naddr: j['naddr'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (j['createdAt'] as num?)?.toInt() ?? 0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
            (j['updatedAt'] as num?)?.toInt() ?? 0),
      );

  static String encodeList(List<Bot> list) =>
      jsonEncode(list.map((b) => b.toJson()).toList());

  static List<Bot> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Bot.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String _cut(String value, int max) =>
      value.length > max ? value.substring(0, max) : value;

  /// What travels when a bot is shared. Only the four things that make it what
  /// it is; everything else is left behind on purpose.
  Map<String, dynamic> get shareable => {
        'v': 1,
        'name': _cut(name, 60),
        'tagline': _cut(tagline, 160),
        'icon': RegExp(r'^[a-z]+$').hasMatch(icon) ? icon : 'robot',
        'instructions': _cut(instructions, 6000),
        'greeting': _cut(greeting, 400),
        'model': modelKey == null ? null : _cut(modelKey!, 80),
        'modelLabel': modelLabel == null ? null : _cut(modelLabel!, 80),
        'starters':
            starters.take(6).map((s) => _cut(s, 200)).toList(growable: false),
      };

  /// A link anyone can open. The bot rides in the fragment, which browsers
  /// never send to a server, so sharing one is not a request to anybody.
  String link({String origin = 'https://nymbot.com'}) {
    final payload = base64Url
        .encode(utf8.encode(jsonEncode(shareable)))
        .replaceAll('=', '');
    return '$origin/app/#bot=$payload';
  }

  String addressFor(String pubkey) => encodeNaddr(
        identifier: dTag,
        pubkey: pubkey,
        kind: kind,
      );

  /// Reads a bot out of a link or a raw payload. Returns null for anything that
  /// is not one, so a stray fragment is ignored rather than trusted.
  static Bot? fromLink(String text, {required String id}) {
    final raw = text.trim();
    final at = raw.indexOf('bot=');
    var payload = at == -1 ? raw : raw.substring(at + 4);
    payload = payload.split('&').first.trim();
    if (payload.isEmpty) return null;
    try {
      final padded = payload.padRight(
          payload.length + ((4 - payload.length % 4) % 4), '=');
      final json = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (json is! Map<String, dynamic>) return null;
      return fromShared(json, id: id);
    } catch (_) {
      return null;
    }
  }

  static Bot? fromShared(Map<String, dynamic> j,
      {required String id, String author = ''}) {
    final name = j['name'] as String? ?? '';
    if (name.isEmpty) return null;
    final icon = j['icon'] as String? ?? 'robot';
    return Bot(
      id: id,
      name: _cut(name, 60),
      tagline: _cut(j['tagline'] as String? ?? '', 160),
      icon: RegExp(r'^[a-z]+$').hasMatch(icon) ? icon : 'robot',
      instructions: _cut(j['instructions'] as String? ?? '', 6000),
      greeting: _cut(j['greeting'] as String? ?? '', 400),
      modelKey: j['model'] as String?,
      modelLabel: j['modelLabel'] as String?,
      starters: (j['starters'] as List?)
          ?.whereType<String>()
          .take(6)
          .map((s) => _cut(s, 200))
          .toList(),
      author: author,
    );
  }
}
