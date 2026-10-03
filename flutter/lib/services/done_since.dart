import 'dart:convert';

import '../features/i18n/i18n.dart';
import '../models/workspace.dart';
import '../state/store.dart';
import 'nostr/event_signer.dart';
import 'nymbot_api.dart';
import 'reply_notify.dart';

typedef DoneNote = ({
  String chat,
  String? asked,
  String state,
  String title,
  String body,
});

class DoneSince {
  DoneSince._();

  static const sinceKey = 'done_since_at';
  static const seenKey = 'done_since_seen';
  static const seenMax = 300;

  static bool wanted({required bool? backgroundJobs, required bool serverSchedules}) =>
      backgroundJobs == true || serverSchedules;

  static Set<String> seen(Store store) {
    final raw = store.getString(seenKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final list = jsonDecode(raw);
      return {
        for (final id in (list is List ? list : const []))
          if (id is String) id,
      };
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> markSeen(Store store, Iterable<String> ids) async {
    final fresh = [for (final id in ids) if (id.isNotEmpty) id];
    if (fresh.isEmpty) return;
    final held = seen(store).toList()
      ..removeWhere(fresh.contains)
      ..addAll(fresh);
    final kept =
        held.length > seenMax ? held.sublist(held.length - seenMax) : held;
    await store.setString(seenKey, jsonEncode(kept));
  }

  static String _pushState(String state) => switch (state) {
        'parked' => 'paused',
        'waiting' => 'approval',
        _ => state,
      };

  static List<DoneNote> notes(
    Object? runs, {
    required Set<String> seen,
    required ({String id, String title})? Function(String thread) chatOf,
    NotifyPrefs? prefs,
  }) {
    final out = <DoneNote>[];
    final want = prefs ?? NotifyPrefs();
    for (final r in (runs is List ? runs : const [])) {
      if (r is! Map) continue;
      final id = r['replyTo'];
      final state = r['state'];
      if (id is! String || id.isEmpty || state is! String) continue;
      if (state == 'stopped' || state == 'running' || seen.contains(id)) continue;
      final thread = r['thread'] is String ? r['thread'] as String : '';
      final chat = chatOf(thread);
      final push = _pushState(state);
      if (!want.wants(push, r['background'] == true ? 'background' : 'turn')) continue;
      final began = r['startedAt'], ended = r['finishedAt'];
      if (began is num &&
          ended is num &&
          began > 0 &&
          want.quick(DateTime.fromMillisecondsSinceEpoch(began.toInt()),
              now: DateTime.fromMillisecondsSinceEpoch(ended.toInt()))) {
        continue;
      }
      final said = ReplyNotify.stateText()[push];
      final title = chat?.title.trim() ?? '';
      out.add((
        chat: chat?.id ?? id,
        asked: id,
        state: push,
        title: ReplyNotify.headingFor(push == 'done' ? null : push, replied: true),
        body: said ?? (title.isEmpty ? t('Open the chat to read it.') : title),
      ));
    }
    return out;
  }

  static Future<List<DoneNote>> check({
    required NymbotApi api,
    required EventSigner signer,
    required Store store,
    required Future<void> Function(DoneNote note) post,
    Iterable<String> pushed = const [],
    NotifyPrefs? prefs,
  }) async {
    final since = store.getInt(sinceKey);
    final res = await api.doneSince(signer, since);
    final now = res.data['now'];
    if (res.status != 200 || now is! num) return const [];
    if (since <= 0) {
      await store.setInt(sinceKey, now.toInt());
      return const [];
    }
    final chats = {
      for (final c in store.conversations())
        if (c.rootId.isNotEmpty) c.rootId: (id: c.id, title: c.title),
    };
    final held = seen(store)..addAll(pushed);
    final found = notes(res.data['runs'],
        seen: held, chatOf: (thread) => chats[thread], prefs: prefs);
    for (final n in found) {
      try {
        await post(n);
      } catch (_) {}
    }
    await markSeen(store, [for (final n in found) n.asked ?? '', ...pushed]);
    await store.setInt(sinceKey, now.toInt());
    return found;
  }
}
