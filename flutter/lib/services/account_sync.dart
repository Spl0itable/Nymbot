import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../core/crypto/pq.dart' as pq;
import '../models/bot.dart';
import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/schedule.dart';
import '../models/workspace.dart';
import '../state/identity.dart';
import '../state/store.dart';
import 'storage_sync.dart';

class AccountSync {
  AccountSync({
    required Store store,
    required Identity identity,
    required StorageSync storage,
  })  : _store = store,
        _identity = identity,
        _storage = storage;

  final Store _store;
  final Identity _identity;
  final StorageSync _storage;

  static const int maxChats = 400;

  static const int maxMessages = 400;

  static const List<String> libraryNames = [
    'personas',
    'prompts',
    'workspaces',
    'folders',
    'schedules',
    'memories',
    'bots',
    'favouriteModels',
  ];

  bool blocked = false;

  DateTime? lastAt;

  void Function(List<String> touched)? onChange;

  Timer? _timer;
  Future<SyncRound>? _running;
  bool _again = false;

  final Map<String, String> _hashes = {};

  Map<String, dynamic> _remote = {};

  bool get enabled => _identity.present && _store.settings().sync;

  static String _sha256Hex(String text) =>
      crypto.sha256.convert(utf8.encode(text)).toString();

  String categoryFor(String dTag) =>
      'nymbot-${_sha256Hex('${_identity.pubkey}|d1:$dTag').substring(0, 48)}';

  bool get _hybrid => !_identity.rootLocked && _identity.kem != null;

  Future<String?> _seal(String plaintext) async {
    final sk = _identity.privkey;
    if (sk == null) return null;
    final kemPk = _identity.kemPublicKey;
    if (_hybrid && kemPk != null) {
      try {
        return await pq.pq2Encrypt(plaintext, sk, _identity.pubkey, kemPk);
      } catch (_) {
      }
    }
    try {
      return await _identity.signer.nip44Encrypt(_identity.pubkey, plaintext);
    } catch (_) {
      return null;
    }
  }

  Future<String> _open(String blob) async {
    final self = _identity.pqIdentity;
    if (pq.isPq2Payload(blob)) {
      if (self == null) throw StateError('needs the local key');
      return pq.pq2Decrypt(blob, _identity.pubkey, self);
    }
    return _identity.signer.nip44Decrypt(_identity.pubkey, blob);
  }

  static int _stamp(Object? record) {
    if (record is! Map) return 0;
    for (final key in const ['updatedAt', 'at', 'createdAt', 'ts']) {
      final v = record[key];
      if (v is num) return v.toInt();
    }
    return 0;
  }

  static List<Map<String, dynamic>> _mergeById(
    List<Map<String, dynamic>> mine,
    List<Map<String, dynamic>> theirs,
    Map<String, int> graves,
  ) {
    final out = <String, Map<String, dynamic>>{};
    for (final record in [...theirs, ...mine]) {
      final id = record['id'];
      if (id is! String || id.isEmpty) continue;
      if (graves.containsKey(id)) continue;
      final held = out[id];
      if (held == null || _stamp(record) >= _stamp(held)) out[id] = record;
    }
    return out.values.toList();
  }

  static Map<String, dynamic> _overlay(Object? raw, Map<String, dynamic> mine) {
    if (raw is! Map) return mine;
    final out = <String, dynamic>{};
    raw.forEach((k, v) => out['$k'] = v);
    mine.forEach((k, v) {
      final was = out[k];
      if (v is Map<String, dynamic> && was is Map) {
        out[k] = _overlay(was, v);
      } else if (v is List && was is List && v.length == was.length) {
        out[k] = [
          for (var i = 0; i < v.length; i++)
            v[i] is Map<String, dynamic>
                ? _overlay(was[i], v[i] as Map<String, dynamic>)
                : v[i]
        ];
      } else {
        out[k] = v;
      }
    });
    return out;
  }

  static List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : const [];

  Map<String, dynamic>? _remoteRecord(String path, String id) {
    Object? held = _remote;
    for (final step in path.split('.')) {
      if (held is! Map) return null;
      held = held[step];
    }
    final list = held is Map ? held['messages'] : held;
    for (final record in _maps(list)) {
      if (record['id'] == id) return record;
    }
    return null;
  }

  Map<String, dynamic> _convToWire(Conversation conv, Map<String, dynamic>? raw) {
    final mine = conv.toJson();
    mine['stats'] = {
      'messages': conv.messageCount,
      'credits': conv.creditsSpent,
    };
    return _overlay(raw, mine);
  }

  static Conversation _convFromWire(Map<String, dynamic> j) {
    final stats = j['stats'];
    if (stats is Map) {
      j = {...j};
      j['messageCount'] ??= stats['messages'];
      j['creditsSpent'] ??= stats['credits'];
    }
    return Conversation.fromJson(j);
  }

  Map<String, dynamic> _msgToWire(ChatMessage msg, Map<String, dynamic>? raw) {
    final mine = msg.toJson();
    mine['ts'] = msg.at.millisecondsSinceEpoch;
    return _overlay(raw, mine);
  }

  static ChatMessage _msgFromWire(Map<String, dynamic> j) {
    if (j['at'] == null && j['ts'] != null) {
      j = {...j};
      j['at'] = j['ts'];
    }
    return ChatMessage.fromJson(j);
  }

  Map<String, dynamic> _settingsToWire(AppSettings s, Object? raw) {
    final mine = s.toJson();
    mine['sidebarGrouping'] = s.grouping.name;
    mine['defaultPersona'] = s.defaultPersonaId;
    mine['defaultRepos'] = s.defaultRepoIds;
    mine['showTokenEstimate'] = s.showCostEstimate;
    return _overlay(raw, mine);
  }

  static AppSettings _settingsFromWire(Map<String, dynamic> j) {
    j = {...j};
    j['grouping'] ??= j['sidebarGrouping'];
    j['defaultPersonaId'] ??= j['defaultPersona'];
    j['defaultRepoIds'] ??= j['defaultRepos'];
    j['showCostEstimate'] ??= j['showTokenEstimate'];
    return AppSettings.fromJson(j);
  }

  Future<Map<String, dynamic>> snapshot() async {
    final graves = _store.syncGraves();
    final out = <String, dynamic>{};

    out['settings'] = _settingsToWire(_store.settings(), _remote['settings']);

    final library = <String, dynamic>{
      'personas': [
        for (final p in _store.customPersonas())
          _overlay(_remoteRecord('library.personas', p.id), p.toJson())
      ],
      if (_store.getString('prompts') != null)
        'prompts': [
          for (final p in _store.prompts())
            _overlay(_remoteRecord('library.prompts', p.id), p.toJson())
        ],
      'workspaces': [
        for (final w in _store.workspaces())
          _overlay(_remoteRecord('library.workspaces', w.id), w.toJson())
      ],
      'folders': [
        for (final f in _store.folders())
          _overlay(_remoteRecord('library.folders', f.id), f.toJson())
      ],
      'schedules': [
        for (final s in _store.schedules())
          _overlay(_remoteRecord('library.schedules', s.id), s.toJson())
      ],
      'memories': [
        for (final m in _store.memories())
          _overlay(_remoteRecord('library.memories', m.id), m.toJson())
      ],
      'bots': [
        for (final b in _store.bots())
          _overlay(_remoteRecord('library.bots', b.id), b.toJson())
      ],
      'favouriteModels': _store.favouriteModels(),
    };
    library['repos'] = [
      for (final r in await _store.repos())
        _overlay(_remoteRecord('library.repos', r.id), {
          ...r.toJson()..remove('token'),
          'tokenElsewhere': r.token.isNotEmpty,
        })
    ];
    out['library'] = library;

    final chats = _store
        .conversations()
        .where((c) =>
            c.id.isNotEmpty &&
            !c.ephemeral &&
            !_store.isGhost(c.id) &&
            !graves.containsKey(c.id))
        .take(maxChats)
        .toList();
    out['chats'] = [
      for (final c in chats) _convToWire(c, _remoteRecord('chats', c.id))
    ];
    for (final conv in chats) {
      final msgs = _store.messages(conv.id);
      if (msgs.isEmpty) continue;
      final kept = msgs.length > maxMessages
          ? msgs.sublist(msgs.length - maxMessages)
          : msgs;
      out['chat-${conv.id}'] = {
        'id': conv.id,
        'messages': [
          for (final m in kept)
            _msgToWire(m, _remoteRecord('chat-${conv.id}', m.id))
        ],
      };
    }
    out['graves'] = graves;
    return out;
  }

  Future<List<String>> apply(Map<String, dynamic> remote) =>
      _store.quiet(() => _apply(remote));

  Future<List<String>> _apply(Map<String, dynamic> remote) async {
    final touched = <String>[];
    final graves = {..._store.syncGraves()};
    final theirGraves = remote['graves'];
    if (theirGraves is Map) {
      theirGraves.forEach((k, v) {
        if (v is num) graves['$k'] = v.toInt();
      });
    }
    await _store.saveSyncGraves(graves);

    final settings = remote['settings'];
    if (settings is Map) {
      final theirs = _settingsToWire(
          _settingsFromWire(settings.cast<String, dynamic>()), null);
      final mine = _settingsToWire(_store.settings(), null);
      await _store.saveSettings(_settingsFromWire(_overlay(theirs, mine)));
      touched.add('settings');
    }

    final library = remote['library'];
    if (library is Map) {
      Future<void> foldList(
        String name,
        List<Map<String, dynamic>> mine,
        Future<void> Function(List<Map<String, dynamic>>) save,
      ) async {
        final theirs = library[name];
        if (theirs is! List) return;
        await save(_mergeById(mine, _maps(theirs), graves));
        touched.add(name);
      }

      await foldList(
        'personas',
        [for (final p in _store.customPersonas()) p.toJson()],
        (merged) => _store
            .savePersonas([for (final j in merged) Persona.fromJson(j)]),
      );
      await foldList(
        'prompts',
        [for (final p in _store.prompts()) p.toJson()],
        (merged) => _store
            .savePrompts([for (final j in merged) SavedPrompt.fromJson(j)]),
      );
      await foldList(
        'workspaces',
        [for (final w in _store.workspaces()) w.toJson()],
        (merged) => _store
            .saveWorkspaces([for (final j in merged) Workspace.fromJson(j)]),
      );
      await foldList(
        'folders',
        [for (final f in _store.folders()) f.toJson()],
        (merged) => _store
            .saveFolders([for (final j in merged) ChatFolder.fromJson(j)]),
      );
      await foldList(
        'schedules',
        [for (final s in _store.schedules()) s.toJson()],
        (merged) => _store
            .saveSchedules([for (final j in merged) Schedule.fromJson(j)]),
      );
      await foldList(
        'memories',
        [for (final m in _store.memories()) m.toJson()],
        (merged) =>
            _store.saveMemories([for (final j in merged) Memory.fromJson(j)]),
      );
      await foldList(
        'bots',
        [for (final b in _store.bots()) b.toJson()],
        (merged) => _store.saveBots([for (final j in merged) Bot.fromJson(j)]),
      );

      final favourites = library['favouriteModels'];
      if (favourites is List) {
        final merged = <String>{
          ..._store.favouriteModels(),
          ...favourites.map((e) => '$e'),
        };
        await _store.saveFavouriteModels(merged.toList());
        touched.add('favouriteModels');
      }

      final repos = library['repos'];
      if (repos is List) {
        final mine = await _store.repos();
        final held = {for (final r in mine) r.id: r.token};
        final merged = _mergeById(
            [for (final r in mine) r.toJson()], _maps(repos), graves);
        await _store.saveRepos([
          for (final j in merged)
            GitRepo.fromJson({
              ...j,
              'token': held[j['id']] ?? (j['token'] as String? ?? ''),
            })
        ]);
        touched.add('repos');
      }
    }

    final chats = remote['chats'];
    if (chats is List) {
      final mine = _store.conversations();
      final ghosts = {
        for (final c in mine)
          if (_store.isGhost(c.id)) c.id
      };
      final incoming = [
        for (final j in _maps(chats))
          if (j['id'] is String && !ghosts.contains(j['id'])) j
      ];
      final merged =
          _mergeById([for (final c in mine) _convToWire(c, null)], incoming, graves)
              .map(_convFromWire)
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _store.saveConversations(merged);
      touched.add('chats');
    }

    for (final key in remote.keys) {
      if (!key.startsWith('chat-')) continue;
      final entry = remote[key];
      if (entry is! Map) continue;
      final id = entry['id'];
      if (id is! String || id.isEmpty) continue;
      if (graves.containsKey(id) || _store.isGhost(id)) continue;
      final mine = _store.messages(id);
      final merged = _mergeById(
        [for (final m in mine) _msgToWire(m, null)],
        _maps(entry['messages']),
        graves,
      ).map(_msgFromWire).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (merged.length != mine.length) {
        await _store.saveMessages(id, merged);
        touched.add(key);
      }
    }
    return touched;
  }

  Future<Map<String, dynamic>?> pull() async {
    final data = await _storage.settingsGet(_identity.signer);
    final categories = data == null ? null : data['categories'];
    if (categories is! Map) return null;
    final out = <String, dynamic>{};
    var unreadable = 0;
    for (final entry in categories.values) {
      if (entry is! Map) continue;
      final blob = entry['blob'];
      if (blob is! String || blob.isEmpty) continue;
      Object? payload;
      try {
        payload = jsonDecode(await _open(blob));
      } catch (_) {
        unreadable++;
        continue;
      }
      if (payload is! Map) continue;
      final name = payload['__cat'];
      if (name is! String || name.isEmpty) continue;
      if (name == StorageSync.pqRootDTag) continue;
      out[name] = payload.containsKey('v') ? payload['v'] : payload;
    }
    blocked = unreadable > 0 && out.isEmpty;
    return out;
  }

  Future<bool> push(String dTag, Object? value) async {
    if (blocked) return false;
    final plain = jsonEncode({'__cat': dTag, 'v': value});
    final category = categoryFor(dTag);
    final hash = _sha256Hex('${_identity.pubkey}|${_hybrid ? 'pq' : 'c'}|$plain');
    if (_hashes[category] == hash) return true;
    final blob = await _seal(plain);
    if (blob == null) return false;
    final ok = await _storage.settingsSet(_identity.signer,
        category: category, blob: blob, contentHash: hash);
    if (!ok) return false;
    _hashes[category] = hash;
    return true;
  }

  Future<SyncRound> run() {
    if (!enabled) return Future.value(const SyncRound.skipped());
    final going = _running;
    if (going != null) {
      _again = true;
      return going;
    }
    final completer = Completer<SyncRound>();
    _running = completer.future;
    unawaited(_round().then(completer.complete, onError: (_, __) {
      completer.complete(const SyncRound.failed());
    }));
    return completer.future;
  }

  Future<SyncRound> _round() async {
    var touched = <String>[];
    try {
      final remote = await pull();
      if (remote == null) return const SyncRound.offline();
      _remote = remote;
      touched = await apply(remote);
      if (blocked) return const SyncRound.blocked();

      final local = await snapshot();
      for (final key in remote.keys) {
        if (key.startsWith('chat-') && !local.containsKey(key)) {
          local[key] = {'id': '', 'messages': const []};
        }
      }
      for (final entry in local.entries) {
        await push(entry.key, entry.value);
      }
      lastAt = DateTime.now();
    } catch (_) {
      return const SyncRound.failed();
    } finally {
      _running = null;
      if (_again) {
        _again = false;
        touch(const Duration(milliseconds: 600));
      }
    }
    if (touched.isNotEmpty) {
      final watcher = onChange;
      if (watcher != null) watcher(touched);
    }
    return SyncRound.ok(touched);
  }

  void follow() => _store.onChanged = touch;

  void touch([Duration delay = const Duration(seconds: 4)]) {
    if (!enabled) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(run());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_store.onChanged == touch) _store.onChanged = null;
  }

  Future<bool> wipeRemote() async {
    final remote = await pull();
    if (remote == null) return false;
    blocked = false;
    _hashes.clear();
    _remote = {};
    for (final dTag in remote.keys) {
      await push(dTag, null);
    }
    return true;
  }

  void forget() {
    _hashes.clear();
    _remote = {};
    blocked = false;
  }
}

class SyncRound {
  const SyncRound._(this.state, [this.touched = const []]);

  const SyncRound.skipped() : this._('skipped');
  const SyncRound.offline() : this._('offline');
  const SyncRound.blocked() : this._('blocked');
  const SyncRound.failed() : this._('failed');
  const SyncRound.ok(List<String> touched) : this._('ok', touched);

  final String state;
  final List<String> touched;

  bool get isOk => state == 'ok';
}
