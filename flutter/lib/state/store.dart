import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/free_tier.dart';

import '../models/artifact.dart';
import '../models/bot.dart';
import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/schedule.dart';
import '../models/workspace.dart';

/// Everything the app keeps on the device.
///
/// Secrets — the identity key, the post-quantum root, the anonymous-mode state
/// and the git access token — go to the platform keystore. Conversations and
/// preferences go to shared preferences: they are already encrypted to the key
/// on the relays, and keeping them out of the keystore keeps its surface to the
/// things that must not be readable at rest.
class Store {
  Store(this._prefs);

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _messageCap = 800;

  final SharedPreferences _prefs;

  static Future<Store> open() async => Store(await SharedPreferences.getInstance());

  /// The free allowance this device has spent today, whichever key was signed
  /// in. Handed the same preferences the rest of the store uses, so signing
  /// out does not clear it — which is the whole point of it.
  FreeTier get freeTier => FreeTier(_prefs);

  // --- secrets ---------------------------------------------------------------

  Future<String?> secret(String key) => _secure.read(key: key);
  Future<void> setSecret(String key, String value) =>
      _secure.write(key: key, value: value);
  Future<void> dropSecret(String key) => _secure.delete(key: key);

  // --- preferences -----------------------------------------------------------

  String? getString(String key) => _prefs.getString(key);
  Future<void> setString(String key, String value) => _prefs.setString(key, value);
  bool getBool(String key, {bool fallback = false}) =>
      _prefs.getBool(key) ?? fallback;
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);
  int getInt(String key, {int fallback = 0}) => _prefs.getInt(key) ?? fallback;
  Future<void> setInt(String key, int value) => _prefs.setInt(key, value);
  Future<void> remove(String key) => _prefs.remove(key);

  AppSettings settings() {
    final raw = _prefs.getString('appSettings');
    if (raw == null) return AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings s) =>
      _prefs.setString('appSettings', jsonEncode(s.toJson()));

  Future<void> resetSettings() => _prefs.remove('appSettings');

  Future<List<GitRepo>> repos() async =>
      GitRepo.decodeList(await _secure.read(key: 'repos'));

  Future<void> saveRepos(List<GitRepo> list) =>
      _secure.write(key: 'repos', value: GitRepo.encodeList(list.take(40).toList()));

  Future<GitRepo?> repo(String id) async {
    for (final r in await repos()) {
      if (r.id == id) return r;
    }
    return null;
  }

  List<Persona> customPersonas() =>
      Persona.decodeList(_prefs.getString('personas'));

  List<Persona> personas() => [...Persona.builtins, ...customPersonas()];

  Persona? persona(String? id) {
    if (id == null) return null;
    for (final p in personas()) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> savePersonas(List<Persona> list) =>
      _prefs.setString('personas', Persona.encodeList(list.take(60).toList()));

  List<Bot> bots() => Bot.decodeList(_prefs.getString('bots'));

  Bot? bot(String? id) {
    if (id == null) return null;
    for (final b in bots()) {
      if (b.id == id) return b;
    }
    return null;
  }

  Future<void> saveBots(List<Bot> list) =>
      _prefs.setString('bots', Bot.encodeList(list.take(60).toList()));

  List<Schedule> schedules() =>
      Schedule.decodeList(_prefs.getString('schedules'));

  Future<void> saveSchedules(List<Schedule> list) => _prefs.setString(
      'schedules', Schedule.encodeList(list.take(40).toList()));

  List<Workspace> workspaces() =>
      Workspace.decodeList(_prefs.getString('workspaces'));

  Workspace? workspace(String? id) {
    if (id == null) return null;
    for (final w in workspaces()) {
      if (w.id == id) return w;
    }
    return null;
  }

  Future<void> saveWorkspaces(List<Workspace> list) => _prefs.setString(
      'workspaces', Workspace.encodeList(list.take(40).toList()));

  /// What Nymbot has been told to remember, newest first.
  List<Memory> memories() => Memory.decodeList(_prefs.getString('memories'));

  Future<void> saveMemories(List<Memory> list) => _prefs.setString(
      'memories', Memory.encodeList(list.take(Memory.maxKept).toList()));

  /// Adds or replaces one entry. The same fact told twice is one fact: a chat
  /// that repeats itself should not fill memory with copies.
  Future<Memory?> saveMemory(Memory entry) async {
    entry.text = entry.text.trim();
    if (entry.text.length > Memory.textCap) {
      entry.text = entry.text.substring(0, Memory.textCap);
    }
    if (entry.text.isEmpty) return null;
    entry.updatedAt = DateTime.now();
    final list = memories();
    list.removeWhere((m) =>
        m.id != entry.id &&
        m.scope == entry.scope &&
        m.text.toLowerCase() == entry.text.toLowerCase());
    final at = list.indexWhere((m) => m.id == entry.id);
    if (at == -1) {
      list.insert(0, entry);
    } else {
      list[at] = entry;
    }
    await saveMemories(list);
    return entry;
  }

  Future<void> deleteMemory(String id) async {
    final list = memories()..removeWhere((m) => m.id == id);
    await saveMemories(list);
  }

  Future<void> clearMemories() => saveMemories(const []);

  List<SavedPrompt> prompts() {
    final raw = _prefs.getString('prompts');
    if (raw == null) return [...SavedPrompt.defaults];
    return SavedPrompt.decodeList(raw);
  }

  Future<void> savePrompts(List<SavedPrompt> list) =>
      _prefs.setString('prompts', SavedPrompt.encodeList(list.take(200).toList()));

  List<ChatFolder> folders() => ChatFolder.decodeList(_prefs.getString('folders'));

  Future<void> saveFolders(List<ChatFolder> list) =>
      _prefs.setString('folders', ChatFolder.encodeList(list.take(100).toList()));

  // --- conversations ---------------------------------------------------------

  List<Conversation> conversations() =>
      Conversation.decodeList(_prefs.getString('conversations'));

  Future<void> saveConversations(List<Conversation> list) => _prefs.setString(
      'conversations', Conversation.encodeList(list.take(500).toList()));

  /// Ghost chats live here and nowhere else: the map goes when the process
  /// does, which is the whole promise.
  final Map<String, List<ChatMessage>> _ghosts = {};

  bool isGhost(String convId) {
    for (final c in conversations()) {
      if (c.id == convId) return c.ephemeral;
    }
    return _ghosts.containsKey(convId);
  }

  List<ChatMessage> messages(String convId) {
    if (isGhost(convId)) return [...?_ghosts[convId]];
    return ChatMessage.decodeList(_prefs.getString('msgs_$convId'));
  }

  Future<void> saveMessages(String convId, List<ChatMessage> list) async {
    // Capped so one long conversation cannot fill the store and start failing
    // the writes it needs to make.
    final kept = list.length > _messageCap
        ? list.sublist(list.length - _messageCap)
        : list;
    if (isGhost(convId)) {
      _ghosts[convId] = [...kept];
      await _prefs.remove('msgs_$convId');
      return;
    }
    _ghosts.remove(convId);
    await _prefs.setString('msgs_$convId', ChatMessage.encodeList(kept));
  }

  /// Moves what a chat has already said into memory and off the disk, which is
  /// what turning ghost mode on part-way through has to mean.
  Future<void> makeGhost(String convId) async {
    _ghosts[convId] = ChatMessage.decodeList(_prefs.getString('msgs_$convId'));
    _ghostArtifacts[convId] =
        Artifact.decodeList(_prefs.getString('artifacts_$convId'));
    await _prefs.remove('msgs_$convId');
    await _prefs.remove('artifacts_$convId');
  }

  /// Writes a ghost chat back to disk, so turning the mode off keeps what is
  /// on screen rather than dropping it.
  Future<void> unmakeGhost(String convId) async {
    final kept = _ghosts.remove(convId) ?? const <ChatMessage>[];
    final lifted = _ghostArtifacts.remove(convId) ?? const <Artifact>[];
    await _prefs.setString('msgs_$convId', ChatMessage.encodeList(kept));
    await _prefs.setString('artifacts_$convId', Artifact.encodeList(lifted));
  }

  /// The wrap ids this conversation is made of, newest last.
  List<String> thread(String convId) =>
      _prefs.getStringList('thread_$convId') ?? const [];

  Future<void> setThread(String convId, List<String> ids) {
    final kept = ids.length > 40 ? ids.sublist(ids.length - 40) : ids;
    return _prefs.setStringList('thread_$convId', kept);
  }

  final Map<String, List<Artifact>> _ghostArtifacts = {};

  List<Artifact> artifacts(String convId) {
    if (isGhost(convId)) return [...?_ghostArtifacts[convId]];
    return Artifact.decodeList(_prefs.getString('artifacts_$convId'));
  }

  Future<void> saveArtifacts(String convId, List<Artifact> list) async {
    final kept = list.length > 60 ? list.sublist(list.length - 60) : list;
    // A file lifted out of a ghost chat is still that chat: it stays in memory
    // with the rest of it.
    if (isGhost(convId)) {
      _ghostArtifacts[convId] = [...kept];
      await _prefs.remove('artifacts_$convId');
      return;
    }
    _ghostArtifacts.remove(convId);
    await _prefs.setString('artifacts_$convId', Artifact.encodeList(kept));
  }

  String draft(String convId) => _prefs.getString('draft_$convId') ?? '';

  Future<void> setDraft(String convId, String text) => text.isEmpty
      ? _prefs.remove('draft_$convId')
      : _prefs.setString('draft_$convId', text);

  Future<void> dropConversation(String convId) async {
    _ghosts.remove(convId);
    _ghostArtifacts.remove(convId);
    await _prefs.remove('msgs_$convId');
    await _prefs.remove('thread_$convId');
    await _prefs.remove('draft_$convId');
    await _prefs.remove('artifacts_$convId');
  }

  ({int credits, int replies}) usage() => (
        credits: _prefs.getInt('usageCredits') ?? 0,
        replies: _prefs.getInt('usageReplies') ?? 0,
      );

  Future<void> recordUsage(double cost) async {
    final u = usage();
    await _prefs.setInt('usageCredits', (u.credits + cost).round());
    await _prefs.setInt('usageReplies', u.replies + 1);
  }

  List<({Conversation conv, ChatMessage? message, String excerpt})> searchAll(
    String term, {
    bool includeArchived = false,
  }) {
    final needle = term.toLowerCase().trim();
    if (needle.isEmpty) return const [];
    final out = <({Conversation conv, ChatMessage? message, String excerpt})>[];
    for (final conv in conversations()) {
      if (!includeArchived && conv.archived) continue;
      if (conv.title.toLowerCase().contains(needle)) {
        out.add((conv: conv, message: null, excerpt: conv.title));
      }
      for (final m in messages(conv.id)) {
        final at = m.content.toLowerCase().indexOf(needle);
        if (at == -1) continue;
        final from = at - 40 < 0 ? 0 : at - 40;
        final to = at + needle.length + 80 > m.content.length
            ? m.content.length
            : at + needle.length + 80;
        out.add((
          conv: conv,
          message: m,
          excerpt: '${from > 0 ? '…' : ''}${m.content.substring(from, to).trim()}',
        ));
        if (out.length > 300) return out;
      }
    }
    return out;
  }

  List<({Conversation conv, ChatMessage message})> pinnedMessages() {
    final out = <({Conversation conv, ChatMessage message})>[];
    for (final conv in conversations()) {
      for (final m in messages(conv.id)) {
        if (m.pinned) out.add((conv: conv, message: m));
      }
    }
    out.sort((a, b) => b.message.at.compareTo(a.message.at));
    return out;
  }

  Future<String> exportAll() async {
    return jsonEncode({
      'version': 2,
      'exportedAt': DateTime.now().millisecondsSinceEpoch,
      'settings': settings().toJson(),
      'folders': folders().map((f) => f.toJson()).toList(),
      'personas': customPersonas().map((p) => p.toJson()).toList(),
      'prompts': prompts().map((p) => p.toJson()).toList(),
      'workspaces': workspaces().map((w) => w.toJson()).toList(),
      'memories': memories().map((m) => m.toJson()).toList(),
      'bots': bots().map((b) => b.toJson()).toList(),
      'schedules': schedules().map((s) => s.toJson()).toList(),
      'conversations': conversations()
          .map((c) => {
                'conversation': c.toJson(),
                'messages': messages(c.id).map((m) => m.toJson()).toList(),
              })
          .toList(),
    });
  }

  /// Everything, gone. Not a logout: there is nothing on a server to log out
  /// of, so this is the only kind of deletion there is.
  Future<void> wipe() async {
    await _prefs.clear();
    await _secure.deleteAll();
  }
}
