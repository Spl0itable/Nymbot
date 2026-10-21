import 'package:flutter/foundation.dart';

class ModelNotes extends ChangeNotifier {
  String? value;

  void say(String text) {
    value = text;
    notifyListeners();
  }
}

class ChatPick {
  const ChatPick({this.pro, this.media, required this.source, this.fallback});

  final Map<String, dynamic>? pro;
  final Map<String, dynamic>? media;
  final String source;
  final Map<String, dynamic>? fallback;
}

class ChatModelRule {
  static bool _listed(Object? list, Object? aliases, String? key) {
    if (list is! List || key == null || key.isEmpty) return false;
    if (list.contains(key)) return true;
    final to = aliases is Map ? aliases[key] : null;
    return to is String && list.contains(to);
  }

  static String? _blocked(String? pro, String? media, Map? catalog, bool proOk) {
    if (pro == null && media == null) return null;
    if (catalog != null) {
      final aliases = catalog['aliases'] ?? const {};
      if (pro != null && !_listed(catalog['chat'], aliases, pro)) return 'missing';
      if (media != null && !_listed(catalog['media'], aliases, media)) return 'missing';
    }
    return proOk ? null : 'credits';
  }

  static String? _key(Object? v) => v is String && v.isNotEmpty ? v : null;

  static Map<String, dynamic> resolve(Map<String, dynamic> input) {
    final chat = input['chat'] is Map ? input['chat'] as Map : const {};
    final global = input['global'] is Map ? input['global'] as Map : const {};
    final catalog = input['catalog'] is Map ? input['catalog'] as Map : null;
    final reply = input['reply'] is Map ? input['reply'] as Map : null;
    final proOk = input['proOk'] != false;
    final gPro = _key(global['pro']);
    final gMedia = _key(global['media']);
    Map<String, dynamic>? fallback;
    final cPro = _key(chat['pro']);
    final cMedia = _key(chat['media']);
    if (chat['pin'] == true || cPro != null || cMedia != null) {
      final why = _blocked(cPro, cMedia, catalog, proOk);
      if (why == null) {
        return {'pro': cPro, 'media': cMedia, 'source': 'chat', 'fallback': null};
      }
      fallback = {'pro': cPro, 'media': cMedia, 'reason': why};
    } else if (catalog != null && _key(reply?['key']) != null) {
      final key = _key(reply!['key'])!;
      final image = _listed(catalog['media'], catalog['aliases'] ?? const {}, key);
      final pro = image ? null : key;
      final media = image ? key : null;
      if (_blocked(pro, media, catalog, proOk) == null) {
        return {'pro': pro, 'media': media, 'source': 'reply', 'fallback': null};
      }
    }
    final why = _blocked(gPro, gMedia, catalog, proOk);
    if (why == null) {
      return {'pro': gPro, 'media': gMedia, 'source': 'global', 'fallback': fallback};
    }
    return {
      'pro': null,
      'media': null,
      'source': 'default',
      'fallback': fallback ?? {'pro': gPro, 'media': gMedia, 'reason': why},
    };
  }
}
