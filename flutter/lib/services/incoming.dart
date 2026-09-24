import 'package:flutter/services.dart';

class IncomingItem {
  const IncomingItem({this.url, this.text, this.files = const []});

  final String? url;
  final String? text;
  final List<({String name, Uint8List bytes})> files;

  static IncomingItem? from(Object? raw) {
    if (raw is! Map) return null;
    if (raw['type'] == 'link') {
      final url = raw['url'];
      return url is String && url.isNotEmpty ? IncomingItem(url: url) : null;
    }
    if (raw['type'] != 'share') return null;
    final text = raw['text'] is String ? raw['text'] as String : null;
    final files = <({String name, Uint8List bytes})>[
      for (final f in (raw['files'] as List?) ?? const [])
        if (f is Map && f['bytes'] is Uint8List)
          (name: '${f['name'] ?? 'shared'}', bytes: f['bytes'] as Uint8List),
    ];
    if ((text == null || text.trim().isEmpty) && files.isEmpty) return null;
    return IncomingItem(text: text, files: files);
  }
}

class Incoming {
  const Incoming._();

  static const channel = MethodChannel('ai.nymbot/intents');

  static String? kindOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https') return null;
    if (uri.host != 'nymbot.ai' && uri.host != 'www.nymbot.ai') return null;
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if ((path == '/app/share' || path == '/app/share.html') &&
        uri.fragment.contains('.')) {
      return 'chat';
    }
    if ((path == '/app' || path == '/app/index.html') &&
        RegExp(r'(^|&)bot=').hasMatch(uri.fragment)) {
      return 'bot';
    }
    if ((path == '/app' || path == '/app/index.html') &&
        RegExp(r'(^|&)gift=', caseSensitive: false).hasMatch(uri.fragment)) {
      return 'gift';
    }
    return null;
  }

  static Future<void> listen(void Function(IncomingItem item) onItem) async {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'incoming') return null;
      final item = IncomingItem.from(call.arguments);
      if (item != null) onItem(item);
      return null;
    });
    try {
      final held = await channel.invokeMethod<List<Object?>>('initial');
      for (final raw in held ?? const <Object?>[]) {
        final item = IncomingItem.from(raw);
        if (item != null) onItem(item);
      }
    } catch (_) {}
  }

  static void stop() => channel.setMethodCallHandler(null);
}
