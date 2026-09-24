import 'dart:convert';

import '../core/crypto/keys.dart';
import '../models/bot.dart';
import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/schedule.dart';
import '../models/workspace.dart';
import '../state/store.dart';
import 'account_sync.dart';

class Backup {
  const Backup._();

  static const _pretty = JsonEncoder.withIndent('  ');

  static Map<String, dynamic> _chat(Conversation conv, List<ChatMessage> messages) => {
        'conversation': AccountSync.chatToWire(conv),
        'messages': [for (final m in messages) AccountSync.messageToWire(m)],
      };

  static String chat(Conversation conv, List<ChatMessage> messages) =>
      _pretty.convert({
        'version': 2,
        'exportedAt': DateTime.now().millisecondsSinceEpoch,
        'conversations': [_chat(conv, messages)],
      });

  static String everything(Store store) => _pretty.convert({
        'version': 2,
        'exportedAt': DateTime.now().millisecondsSinceEpoch,
        'settings': AccountSync.settingsToWire(store.settings()),
        'folders': [for (final f in store.folders()) f.toJson()],
        'personas': [for (final p in store.customPersonas()) p.toJson()],
        'prompts': [for (final p in store.prompts()) p.toJson()],
        'workspaces': [for (final w in store.workspaces()) w.toJson()],
        'memories': [for (final m in store.memories()) m.toJson()],
        'schedules': [for (final s in store.schedules()) s.toJson()],
        'bots': [for (final b in store.bots()) b.toJson()],
        'conversations': [
          for (final c in store.conversations())
            if (!c.ephemeral) _chat(c, store.messages(c.id)),
        ],
      });

  static String fileName(String title, String extension) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-');
    final base = slug.isEmpty
        ? 'chat'
        : (slug.length > 48 ? slug.substring(0, 48) : slug);
    return '$base.$extension';
  }

  static List<Map<String, dynamic>> _mergeById(
      List<Map<String, dynamic>> held, List<Map<String, dynamic>> incoming) {
    final out = [...held];
    final at = <String, int>{};
    String keyOf(Map<String, dynamic> item) =>
        item['id'] != null ? 'id:${item['id']}' : 'raw:${jsonEncode(item)}';
    for (var i = 0; i < out.length; i++) {
      at[keyOf(out[i])] = i;
    }
    for (final item in incoming) {
      final key = keyOf(item);
      final where = at[key];
      if (where != null) {
        out[where] = item;
      } else {
        at[key] = out.length;
        out.add(item);
      }
    }
    return out;
  }

  static List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : const [];

  static Future<int> restore(Store store, Object? payload,
      {required bool merge}) async {
    if (payload is! Map || payload['conversations'] is! List) {
      throw const FormatException('unreadable');
    }
    if (!merge) {
      for (final c in store.conversations()) {
        await store.dropConversation(c.id);
      }
      await store.saveConversations(const []);
    }

    Future<void> library<T>(
      String name,
      List<Map<String, dynamic>> Function() held,
      List<T> Function(String raw) decode,
      Future<void> Function(List<T> list) save,
    ) async {
      final incoming = payload[name];
      if (incoming is! List) return;
      final list = merge ? _mergeById(held(), _maps(incoming)) : _maps(incoming);
      await save(decode(jsonEncode(list)));
    }

    await library<ChatFolder>('folders',
        () => [for (final f in store.folders()) f.toJson()],
        ChatFolder.decodeList, store.saveFolders);
    await library<Persona>('personas',
        () => [for (final p in store.customPersonas()) p.toJson()],
        Persona.decodeList, store.savePersonas);
    await library<SavedPrompt>('prompts',
        () => [for (final p in store.prompts()) p.toJson()],
        SavedPrompt.decodeList, store.savePrompts);
    await library<Workspace>('workspaces',
        () => [for (final w in store.workspaces()) w.toJson()],
        Workspace.decodeList, store.saveWorkspaces);
    await library<Memory>('memories',
        () => [for (final m in store.memories()) m.toJson()],
        Memory.decodeList, store.saveMemories);
    await library<Schedule>('schedules',
        () => [for (final s in store.schedules()) s.toJson()],
        Schedule.decodeList, store.saveSchedules);
    await library<Bot>('bots', () => [for (final b in store.bots()) b.toJson()],
        Bot.decodeList, store.saveBots);

    final list = merge ? store.conversations() : <Conversation>[];
    var count = 0;
    for (final entry in _maps(payload['conversations'])) {
      final raw = entry['conversation'];
      if (raw is! Map) continue;
      final Conversation conv;
      try {
        conv = AccountSync.chatFromWire({
          ...raw.cast<String, dynamic>(),
          'id': bytesToHex(randomBytes(8)),
        });
      } catch (_) {
        continue;
      }
      final messages = <ChatMessage>[];
      for (final m in _maps(entry['messages'])) {
        try {
          messages.add(AccountSync.messageFromWire(m));
        } catch (_) {}
      }
      list.insert(0, conv);
      await store.saveMessages(conv.id, messages);
      count++;
    }
    await store.saveConversations(list);
    return count;
  }
}
