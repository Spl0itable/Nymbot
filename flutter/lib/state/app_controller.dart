import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../core/crypto/bech32_codec.dart';
import '../core/crypto/keys.dart';
import '../features/i18n/i18n.dart';
import '../models/artifact.dart';
import '../models/bot.dart';
import '../models/compare.dart';
import '../models/conversation.dart';
import '../models/schedule.dart';
import '../models/nostr_event.dart';
import '../models/workspace.dart';
import '../services/anon.dart';
import '../services/chat_engine.dart';
import '../services/nymbot_api.dart';
import '../services/pq_announce.dart';
import '../services/profiles.dart';
import '../services/relay_pool.dart';
import 'identity.dart';
import 'store.dart';

/// One object the whole app listens to: the identity, the conversations, the
/// toolbar's state and the balances.
class AppController extends ChangeNotifier {
  AppController._(this.store, this.identity, this.relays, this.pq, this.api, this.anon);

  static Future<AppController> boot() async {
    final store = await Store.open();
    final identity = Identity(store);
    final relays = RelayPool();
    final pq = PqAnnounce(relays);
    final api = NymbotApi();
    final anon = AnonMode(store, api, pq);
    final c = AppController._(store, identity, relays, pq, api, anon);
    c.profiles = Profiles(store, relays);
    c.profiles.addListener(c.notifyListeners);
    await anon.load();
    c.signedIn = await identity.restore();
    c._loadSettings();
    await c._loadRepos();
    return c;
  }

  final Store store;
  final Identity identity;
  final RelayPool relays;
  final PqAnnounce pq;
  final NymbotApi api;
  final AnonMode anon;
  late final Profiles profiles;

  late final ChatEngine chat = ChatEngine(
    identity: identity,
    relays: relays,
    pq: pq,
    api: api,
    anon: anon,
  );

  bool signedIn = false;
  bool _entered = false;
  Timer? _bootWork;
  bool sending = false;
  bool _topping = false;
  String? status;
  int relaysUp = 0;

  List<Conversation> conversations = [];
  Conversation? current;
  List<ChatMessage> messages = [];
  List<Artifact> artifacts = [];

  AppSettings settings = AppSettings();
  List<GitRepo> repos = [];
  Map<String, dynamic>? proModel;
  int? standardBalance;
  int? proBalance;

  String convFilter = 'all';
  String convSearch = '';
  List<String> favouriteModels = [];
  String? quote;
  List<Attachment> attachments = [];

  String? pendingInput;

  void queueInput(String text) {
    pendingInput = text;
    notifyListeners();
  }

  String? takeInput() {
    final text = pendingInput;
    pendingInput = null;
    return text;
  }

  // --- settings ----------------------------------------------------------------

  void _loadSettings() {
    settings = store.settings();
    final raw = store.getString('settings');
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        proModel = j['proModel'] as Map<String, dynamic>?;
      } catch (_) {}
    }
    favouriteModels =
        (jsonDecode(store.getString('favouriteModels') ?? '[]') as List)
            .map((e) => '$e')
            .toList();
  }

  Future<void> _saveModel() =>
      store.setString('settings', jsonEncode({'proModel': proModel}));

  Future<void> saveSettings(AppSettings next) async {
    settings = next;
    await store.saveSettings(next);
    notifyListeners();
  }

  Future<void> resetSettings() async {
    await store.resetSettings();
    settings = store.settings();
    notifyListeners();
  }

  Future<void> setProModel(Map<String, dynamic>? model, {bool forChat = false}) async {
    if (forChat) {
      final conv = current;
      if (conv != null) {
        conv.proModel = model;
        await store.saveConversations(conversations);
      }
    } else {
      proModel = model;
      await _saveModel();
      final conv = current;
      if (conv != null && conv.proModel != null) {
        conv.proModel = null;
        await store.saveConversations(conversations);
      }
    }
    notifyListeners();
  }

  Map<String, dynamic>? get activeModel => current?.proModel ?? proModel;

  Future<void> toggleFavouriteModel(String key) async {
    favouriteModels = favouriteModels.contains(key)
        ? (favouriteModels.where((k) => k != key).toList())
        : ([...favouriteModels, key]);
    await store.setString('favouriteModels', jsonEncode(favouriteModels));
    notifyListeners();
  }

  Future<void> setAnonEnabled(bool on) async {
    await anon.setEnabled(on);
    if (on) {
      await anon.flush(identity: identity.signer);
      await autoTopUp();
    }
    notifyListeners();
  }

  /// Moves credits onto the throwaway key when it is running low, so
  /// anonymous mode does not mean funding a key by hand before every chat.
  ///
  /// Only ever moves from the nym to the throwaway key, never the other way,
  /// and never more than the nym actually holds. One call at a time: a second
  /// while the first is still minting would spend the same balance twice.
  Future<Map<String, int>?> autoTopUp({bool force = false}) async {
    if (!settings.anonAutoTop || !anon.ready) return null;
    if (_topping) return null;
    _topping = true;
    try {
      final floor = settings.anonAutoTopFloor < 0 ? 0 : settings.anonAutoTopFloor;
      final amount =
          settings.anonAutoTopAmount < 1 ? 1 : settings.anonAutoTopAmount;
      final want = settings.anonAutoTopTier;
      final tiers = want == 'both' ? const ['standard', 'pro'] : [want];

      final here = await api.balance(await anon.signer());
      final mine = await api.balance(identity.signer);
      if (here.data['error'] != null || mine.data['error'] != null) return null;

      final moved = <String, int>{};
      for (final tier in tiers) {
        final key = tier == 'pro' ? 'proBalance' : 'balance';
        final have = (here.data[key] as num?)?.toInt();
        final nym = (mine.data[key] as num?)?.toInt();
        if (have == null || nym == null) continue;
        if (!force && have >= floor) continue;
        if (force && have >= floor + amount) continue;
        final take = amount < nym ? amount : nym;
        if (take <= 0) continue;
        try {
          final credited = await anon.moveCredits(identity.signer, take, tier);
          if (credited > 0) moved[tier] = credited;
        } catch (_) {
          // A tier that cannot be funded is not a reason to skip the other.
        }
      }
      if (moved.isEmpty) return null;
      await refreshBalance();
      return moved;
    } catch (_) {
      return null;
    } finally {
      _topping = false;
    }
  }

  String describeTopUp(Map<String, int> moved) {
    final parts = <String>[];
    if (moved['standard'] != null) {
      parts.add(t('{n} standard', {'n': moved['standard']}));
    }
    if (moved['pro'] != null) parts.add(t('{n} Pro', {'n': moved['pro']}));
    return t('Moved {what} onto the throwaway key.', {'what': parts.join(', ')});
  }

  /// Ghost mode, per chat. Turning it on moves what has already been said off
  /// the disk, and turning it off writes back what is on screen — so the switch
  /// never silently loses a conversation either way.
  Future<void> setEphemeral(bool on) async {
    final conv = current;
    if (conv == null || conv.ephemeral == on) return;
    if (on) {
      await store.makeGhost(conv.id);
      conv.ephemeral = true;
    } else {
      conv.ephemeral = false;
      await store.unmakeGhost(conv.id);
    }
    _touch(conv);
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> setAutoDeleteDays(int days) async {
    settings.autoDeleteDays = days < 0 ? 0 : days;
    await store.saveSettings(settings);
    notifyListeners();
  }

  /// Two sweeps, both at startup: a ghost chat has nothing left to show once
  /// the process it lived in is gone, and a chat older than the auto-delete
  /// window is one the user has already said they do not want kept.
  Future<int> sweepOldChats() async {
    final days = settings.autoDeleteDays;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final doomed = conversations
        .where((c) =>
            c.ephemeral ||
            (days > 0 && !c.pinned && c.updatedAt.isBefore(cutoff)))
        .map((c) => c.id)
        .toList();
    if (doomed.isEmpty) return 0;
    for (final id in doomed) {
      await store.dropConversation(id);
    }
    conversations.removeWhere((c) => doomed.contains(c.id));
    await store.saveConversations(conversations);
    return doomed.length;
  }

  // --- carrying a capped run on --------------------------------------------

  /// Credits already spent carrying the current chat's run on, so a budget is
  /// a budget for the task rather than for each leg of it.
  int continuedSpend = 0;

  /// What the running turn is doing, newest last. Advisory: it is emptied the
  /// moment a turn ends, and an empty list simply shows the plain spinner.
  List<TurnStep> progressSteps = [];
  bool _watching = false;
  bool _stopped = false;

  /// What is left of this chat's continuation budget. A budget of -1 is
  /// "whatever the balance holds", which is still a real ceiling — it is just
  /// the user's own balance rather than a number they typed.
  int get continueBudget {
    final cap = settings.autoContinue;
    if (cap == 0) return 0;
    if (cap < 0) {
      final have = proBalance;
      return have == null || have < 0 ? 0 : have;
    }
    final left = cap - continuedSpend;
    return left < 0 ? 0 : left;
  }

  Future<void> setAutoContinue(int credits) async {
    settings.autoContinue = credits;
    await store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setShowProgress(bool on) async {
    settings.showProgress = on;
    await store.saveSettings(settings);
    notifyListeners();
  }

  /// Polls the worker for what the turn is doing. Stops the moment the turn is
  /// over, and never keeps the send waiting on it.
  void _watchTurn(String eventId) {
    if (!settings.showProgress) return;
    _watching = true;
    progressSteps = [];
    () async {
      var after = 0;
      while (_watching) {
        final signer = current?.anon == true && anon.enabled
            ? await anon.signer()
            : identity.signer;
        final steps = await chat.progress(signer, eventId, after: after);
        if (!_watching) return;
        if (steps.isNotEmpty) {
          after = steps.last.n;
          progressSteps = [...progressSteps, ...steps];
          notifyListeners();
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }()
        .catchError((_) {});
  }

  void _stopWatching() {
    if (!_watching && progressSteps.isEmpty) return;
    _watching = false;
    progressSteps = [];
    notifyListeners();
  }

  Future<void> setWebSearch(bool on) async {
    settings.webSearch = on;
    await store.saveSettings(settings);
    notifyListeners();
  }

  /// The language to load at startup. Read here rather than loaded here: the
  /// packs are bundle assets, and `main` is the one place that can wait on the
  /// bundle without a widget test's clock waiting with it.
  String? get preferredLanguage => store.getString('lang');

  /// Reloads the pack in place. Every screen reads `t()` on build, so a
  /// notify is the whole of the switch — no restart, no rebuilt widget tree.
  Future<void> setLanguage(String code) async {
    await store.setString('lang', code);
    await I18n.load(preferred: code);
    notifyListeners();
  }

  Future<void> _loadRepos() async {
    repos = await store.repos();
    if (repos.isEmpty) {
      final legacy = store.getString('settings');
      if (legacy != null) {
        try {
          final j = jsonDecode(legacy) as Map<String, dynamic>;
          final git = j['git'] as Map<String, dynamic>?;
          if (git != null && git['repo'] != null && git['token'] != null) {
            repos = [
              GitRepo(
                id: bytesToHex(randomBytes(8)),
                repo: '${git['repo']}',
                token: '${git['token']}',
                provider: '${git['provider'] ?? 'github'}',
                host: '${git['host'] ?? ''}',
                branch: '${git['branch'] ?? ''}',
                allowWrites: git['allowWrites'] == true,
              )
            ];
            await store.saveRepos(repos);
          }
        } catch (_) {}
      }
    }
  }

  Workspace? get activeWorkspace => store.workspace(current?.workspaceId);

  /// A chat sees its own repositories plus the ones its workspace carries, in
  /// that order and without duplicates.
  List<GitRepo> get activeRepos {
    final ids = [
      ...current?.repoIds ?? const <String>[],
      ...activeWorkspace?.repoIds ?? const <String>[],
    ];
    final out = <GitRepo>[];
    for (final id in ids) {
      if (out.any((r) => r.id == id)) continue;
      for (final r in repos) {
        if (r.id == id && r.enabled) out.add(r);
      }
    }
    return out;
  }

  /// Repositories this chat picked itself, as opposed to the ones it inherits
  /// from its workspace.
  bool ownsRepo(String id) => current?.repoIds.contains(id) ?? false;

  Future<GitRepo> saveRepo(GitRepo repo, {bool useHere = true}) async {
    final at = repos.indexWhere((r) => r.id == repo.id);
    if (at == -1) {
      repos = [...repos, repo];
    } else {
      repos[at] = repo;
    }
    await store.saveRepos(repos);
    final conv = current;
    if (useHere && conv != null && !conv.repoIds.contains(repo.id)) {
      conv.repoIds = [...conv.repoIds, repo.id];
      await store.saveConversations(conversations);
    }
    notifyListeners();
    return repo;
  }

  Future<void> deleteRepo(String id) async {
    repos = repos.where((r) => r.id != id).toList();
    await store.saveRepos(repos);
    for (final c in conversations) {
      c.repoIds = c.repoIds.where((x) => x != id).toList();
    }
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> toggleRepoHere(String id) async {
    final conv = current;
    if (conv == null) return;
    conv.repoIds = conv.repoIds.contains(id)
        ? conv.repoIds.where((x) => x != id).toList()
        : [...conv.repoIds, id];
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> setReposHere(List<String> ids) async {
    final conv = current;
    if (conv == null) return;
    conv.repoIds = ids;
    await store.saveConversations(conversations);
    notifyListeners();
  }

  List<Persona> get personas => store.personas();

  Persona? get activePersona =>
      store.persona(current?.personaId ?? activeWorkspace?.personaId);

  Future<void> setPersona(String? id) async {
    final conv = current;
    if (conv == null) return;
    conv.personaId = id;
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> savePersona(Persona persona) async {
    final list = store.customPersonas();
    final at = list.indexWhere((p) => p.id == persona.id);
    if (at == -1) {
      list.add(persona);
    } else {
      list[at] = persona;
    }
    await store.savePersonas(list);
    notifyListeners();
  }

  Future<void> deletePersona(String id) async {
    await store.savePersonas(
        store.customPersonas().where((p) => p.id != id).toList());
    for (final c in conversations) {
      if (c.personaId == id) c.personaId = null;
    }
    await store.saveConversations(conversations);
    notifyListeners();
  }

  List<Bot> get bots => store.bots();

  Bot? get activeBot => store.bot(current?.botId);

  Future<void> setBot(String? id, {Map<String, dynamic>? model}) async {
    final conv = current;
    if (conv == null) return;
    conv.botId = id;
    if (id == null) {
      conv.proModel = null;
    } else if (model != null) {
      conv.proModel = model;
    }
    _touch(conv);
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<Bot> saveBot(Bot bot) async {
    final list = store.bots();
    bot.updatedAt = DateTime.now();
    final at = list.indexWhere((b) => b.id == bot.id);
    if (at == -1) {
      list.add(bot);
    } else {
      list[at] = bot;
    }
    await store.saveBots(list);
    notifyListeners();
    return bot;
  }

  Future<void> deleteBot(String id) async {
    await store.saveBots(store.bots().where((b) => b.id != id).toList());
    for (final c in conversations) {
      if (c.botId == id) c.botId = null;
    }
    await store.saveConversations(conversations);
    notifyListeners();
  }

  /// Publishing is a claim of authorship, so it is always signed by the account
  /// and never by a throwaway key, whatever mode the chat is in. Kind 30078 is
  /// replaceable, so republishing the same bot replaces it.
  Future<int> publishBot(Bot bot) async {
    final signer = identity.signer;
    final event = await signer.sign(UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: Bot.kind,
      tags: [
        ['d', bot.dTag],
        ['title', bot.name],
        const ['t', 'nymbot'],
      ],
      content: jsonEncode(bot.shareable),
    ));
    final accepted = await relays.publish(event);
    if (accepted > 0) {
      bot.naddr = bot.addressFor(identity.pubkey);
      bot.author = identity.pubkey;
      await saveBot(bot);
    }
    return accepted;
  }

  /// Reads a published bot back off the relays. Returns null when no relay has
  /// it, which is what an unpublished or mistyped address looks like.
  Future<Bot?> fetchBot(String address) async {
    final ref = decodeNostrRef(address.trim());
    if (ref == null ||
        ref.kind != NostrRefKind.addr ||
        ref.eventKind != Bot.kind) {
      return null;
    }
    final events = await relays.fetch({
      'kinds': [Bot.kind],
      'authors': [ref.pubkey],
      '#d': [ref.identifier],
      'limit': 2,
    }, timeout: const Duration(seconds: 5));
    final mine = events.where((e) => e.pubkey == ref.pubkey).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (mine.isEmpty) return null;
    try {
      final json = jsonDecode(mine.first.content);
      if (json is! Map<String, dynamic>) return null;
      return Bot.fromShared(json,
          id: bytesToHex(randomBytes(8)), author: ref.pubkey);
    } catch (_) {
      return null;
    }
  }

  List<Schedule> schedules = [];
  Timer? _scheduler;

  Future<Schedule> saveSchedule(Schedule entry) async {
    final at = schedules.indexWhere((s) => s.id == entry.id);
    if (at == -1) {
      schedules = [...schedules, entry];
    } else {
      schedules[at] = entry;
    }
    await store.saveSchedules(schedules);
    notifyListeners();
    return entry;
  }

  Future<void> deleteSchedule(String id) async {
    schedules = schedules.where((s) => s.id != id).toList();
    await store.saveSchedules(schedules);
    notifyListeners();
  }

  /// Nothing runs on a server, so a run happens here, in the open app, and
  /// only when it is not already waiting on a reply.
  Future<void> runSchedule(String id) async {
    if (sending) return;
    final at = schedules.indexWhere((s) => s.id == id);
    if (at == -1) return;
    final entry = schedules[at];

    Conversation? target;
    for (final c in conversations) {
      if (c.id == entry.convId) target = c;
    }
    if (target == null) {
      target = await newConversation();
      target.title = entry.title;
    } else if (current?.id != target.id) {
      await open(target);
    }

    entry.advance();
    await store.saveSchedules(schedules);
    await note(t('Running “{name}”.',
        {'name': entry.title.isEmpty ? t('Untitled') : entry.title}));
    await send(entry.prompt);
  }

  List<Schedule> get dueSchedules => schedules.where((s) => s.due).toList();

  Future<void> runDueSchedules() async {
    if (sending) return;
    final due = dueSchedules;
    if (due.isEmpty) return;
    await runSchedule(due.first.id);
  }

  void startScheduler() {
    _scheduler?.cancel();
    _scheduler = Timer.periodic(const Duration(minutes: 1), (_) {
      runDueSchedules().catchError((_) {});
    });
  }

  List<Workspace> get workspaces => store.workspaces();

  Future<void> setWorkspace(String? id) async {
    final conv = current;
    if (conv == null) return;
    conv.workspaceId = id;
    _touch(conv);
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> saveWorkspace(Workspace space) async {
    final list = store.workspaces();
    space.updatedAt = DateTime.now();
    final at = list.indexWhere((w) => w.id == space.id);
    if (at == -1) {
      list.add(space);
    } else {
      list[at] = space;
    }
    await store.saveWorkspaces(list);
    notifyListeners();
  }

  Future<void> deleteWorkspace(String id) async {
    await store
        .saveWorkspaces(store.workspaces().where((w) => w.id != id).toList());
    for (final c in conversations) {
      if (c.workspaceId == id) c.workspaceId = null;
    }
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> setSystemPrompt(String text) async {
    final conv = current;
    if (conv == null) return;
    conv.systemPrompt = text.trim();
    await store.saveConversations(conversations);
    notifyListeners();
  }

  List<SavedPrompt> get prompts => store.prompts();

  Future<void> savePrompt(SavedPrompt prompt) async {
    final list = store.prompts();
    final at = list.indexWhere((p) => p.id == prompt.id);
    if (at == -1) {
      list.insert(0, prompt);
    } else {
      list[at] = prompt;
    }
    await store.savePrompts(list);
    notifyListeners();
  }

  Future<void> deletePrompt(String id) async {
    await store.savePrompts(store.prompts().where((p) => p.id != id).toList());
    notifyListeners();
  }

  List<ChatFolder> get folders => store.folders();

  Future<ChatFolder> createFolder(String name) async {
    final folder = ChatFolder(id: bytesToHex(randomBytes(6)), name: name);
    await store.saveFolders([...store.folders(), folder]);
    notifyListeners();
    return folder;
  }

  Future<void> setTagsAndFolder(List<String> tags, String? folderId) async {
    final conv = current;
    if (conv == null) return;
    conv.tags = tags;
    conv.folderId = folderId;
    await store.saveConversations(conversations);
    notifyListeners();
  }

  // --- session -------------------------------------------------------------------

  /// Called once a key exists. `enter` does the rest, driven from the root.
  void signIn() {
    signedIn = true;
    notifyListeners();
  }

  Future<void> enter() async {
    if (_entered) return;
    _entered = true;
    signedIn = true;
    relays.onStatus((up, _) {
      relaysUp = up;
      notifyListeners();
    });
    relays.connect();

    conversations = store.conversations();
    schedules = store.schedules();
    // Before anything is drawn: a ghost chat has nothing left to show now the
    // process it lived in is gone, and a chat past the auto-delete window is
    // one the user has already said they do not want kept.
    await sweepOldChats();
    final live = conversations.where((c) => !c.archived).toList();
    if (live.isEmpty) {
      await newConversation();
    } else {
      await open(live.first);
    }
    notifyListeners();

    // The announcement and the bot's key are what make a reply post-quantum;
    // neither blocks the first message. Held so it can be cancelled: a wipe or
    // a disposed controller must not leave network work running behind it.
    _bootWork = Timer(const Duration(milliseconds: 400), () async {
      try {
        await pq.resolveBot();
      } catch (_) {}
      final kem = identity.kem;
      if (kem != null) {
        try {
          identity.rootLocked = !await pq.announce(identity.signer, kem);
        } catch (_) {}
      }
      await refreshBalance();
      await anon.flush(identity: identity.signer);
      startScheduler();
      await runDueSchedules();
      await autoTopUp();
      // A published profile is what the account already tells the world;
      // showing it costs no privacy and makes the app feel signed in.
      await profiles.load(identity.pubkey);
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _bootWork?.cancel();
    _scheduler?.cancel();
    relays.close();
    super.dispose();
  }

  // --- conversations -----------------------------------------------------------

  Future<Conversation> newConversation() async {
    final conv = Conversation(
      id: bytesToHex(randomBytes(8)),
      rootId: bytesToHex(randomBytes(32)),
      anon: anon.enabled,
      repoIds: [...settings.defaultRepoIds],
      personaId: settings.defaultPersonaId,
      workspaceId: current?.workspaceId,
      botId: current?.botId,
    );
    conversations.insert(0, conv);
    await store.saveConversations(conversations);
    await open(conv);
    return conv;
  }

  Future<void> open(Conversation conv) async {
    current = conv;
    messages = store.messages(conv.id);
    artifacts = store.artifacts(conv.id);
    attachments = [];
    quote = null;
    notifyListeners();
  }

  List<Artifact> artifactsOf(String messageId) =>
      artifacts.where((a) => a.messageId == messageId).toList();

  Future<List<Artifact>> harvestArtifacts(ChatMessage message) async {
    if (message.role != ChatRole.bot) return const [];
    final made = <Artifact>[];
    for (final block in ArtifactHarvest.fences(message.content)) {
      if (!ArtifactHarvest.worthLifting(block.body, block.lang)) continue;
      final title = ArtifactHarvest.titleFor(block.lang, block.body);
      final at = artifacts.indexWhere((a) => a.title == title && a.lang == block.lang);
      if (at == -1) {
        final entry = Artifact(
          id: bytesToHex(randomBytes(8)),
          title: title,
          lang: block.lang,
          body: block.body,
          messageId: message.id,
          versions: [ArtifactVersion(at: DateTime.now(), body: block.body)],
        );
        artifacts = [...artifacts, entry];
        made.add(entry);
      } else {
        final entry = artifacts[at];
        if (entry.body != block.body) {
          entry.versions = [
            ...entry.versions,
            ArtifactVersion(at: DateTime.now(), body: block.body),
          ];
          if (entry.versions.length > 30) {
            entry.versions = entry.versions.sublist(entry.versions.length - 30);
          }
          entry.body = block.body;
          entry.updatedAt = DateTime.now();
        }
        made.add(entry);
      }
    }
    if (made.isNotEmpty) {
      await store.saveArtifacts(current!.id, artifacts);
      notifyListeners();
    }
    return made;
  }

  Future<void> updateArtifact(String id, String body) async {
    final at = artifacts.indexWhere((a) => a.id == id);
    if (at == -1 || artifacts[at].body == body) return;
    final entry = artifacts[at];
    entry.versions = [
      ...entry.versions,
      ArtifactVersion(at: DateTime.now(), body: body, note: 'edited here'),
    ];
    if (entry.versions.length > 30) {
      entry.versions = entry.versions.sublist(entry.versions.length - 30);
    }
    entry.body = body;
    entry.updatedAt = DateTime.now();
    await store.saveArtifacts(current!.id, artifacts);
    notifyListeners();
  }

  Future<void> renameArtifact(String id, String title) async {
    final at = artifacts.indexWhere((a) => a.id == id);
    if (at == -1 || title.trim().isEmpty || artifacts[at].title == title.trim()) return;
    artifacts[at].title = title.trim();
    await store.saveArtifacts(current!.id, artifacts);
    notifyListeners();
  }

  Future<void> revertArtifact(String id, int index) async {
    final at = artifacts.indexWhere((a) => a.id == id);
    if (at == -1) return;
    final entry = artifacts[at];
    if (index < 0 || index >= entry.versions.length) return;
    await updateArtifact(id, entry.versions[index].body);
  }

  Future<void> deleteArtifact(String id) async {
    artifacts = artifacts.where((a) => a.id != id).toList();
    await store.saveArtifacts(current!.id, artifacts);
    notifyListeners();
  }

  List<Conversation> get visibleConversations {
    final needle = convSearch.toLowerCase().trim();
    return conversations.where((c) {
      if (convFilter == 'archived') {
        if (!c.archived) return false;
      } else if (c.archived) {
        return false;
      }
      if (convFilter == 'pinned' && !c.pinned) return false;
      if (convFilter == 'anon' && !c.anon) return false;
      if (convFilter == 'repos' && c.repoIds.isEmpty) return false;
      if (needle.isEmpty) return true;
      if (c.title.toLowerCase().contains(needle)) return true;
      if (c.tags.any((x) => x.toLowerCase().contains(needle))) return true;
      return store
          .messages(c.id)
          .any((m) => m.content.toLowerCase().contains(needle));
    }).toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
  }

  void setFilter(String filter) {
    convFilter = filter;
    notifyListeners();
  }

  void setSearch(String term) {
    convSearch = term;
    notifyListeners();
  }

  Future<void> renameCurrent(String title) async {
    final conv = current;
    if (conv == null) return;
    conv.title = title.trim().isEmpty ? 'New chat' : title.trim();
    conv.updatedAt = DateTime.now();
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> togglePin() async {
    final conv = current;
    if (conv == null) return;
    conv.pinned = !conv.pinned;
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> toggleArchive() async {
    final conv = current;
    if (conv == null) return;
    conv.archived = !conv.archived;
    await store.saveConversations(conversations);
    if (conv.archived) {
      final live = conversations.where((c) => !c.archived).toList();
      if (live.isEmpty) {
        await newConversation();
      } else {
        await open(live.first);
      }
    }
    notifyListeners();
  }

  Future<void> deleteCurrent() async {
    final conv = current;
    if (conv == null) return;
    conversations.removeWhere((c) => c.id == conv.id);
    await store.saveConversations(conversations);
    await store.dropConversation(conv.id);
    final live = conversations.where((c) => !c.archived).toList();
    if (live.isEmpty) {
      await newConversation();
    } else {
      await open(live.first);
    }
  }

  Future<Conversation> duplicateCurrent() async {
    final conv = current!;
    final copy = Conversation(
      id: bytesToHex(randomBytes(8)),
      rootId: bytesToHex(randomBytes(32)),
      title: '${conv.title.isEmpty ? 'New chat' : conv.title} ${t('(copy)')}',
      anon: conv.anon,
      folderId: conv.folderId,
      tags: [...conv.tags],
      repoIds: [...conv.repoIds],
      personaId: conv.personaId,
      systemPrompt: conv.systemPrompt,
      proModel: conv.proModel,
    );
    conversations.insert(0, copy);
    await store.saveConversations(conversations);
    await store.saveMessages(copy.id, store.messages(conv.id));
    await open(copy);
    return copy;
  }

  Future<Conversation> forkAt(ChatMessage message) async {
    final conv = current!;
    final at = messages.indexWhere((m) => m.id == message.id);
    final kept = messages.sublist(0, at + 1);
    final seed = kept
        .where((m) => m.role == ChatRole.self || m.role == ChatRole.bot)
        .toList()
        .reversed
        .take(8)
        .toList()
        .reversed
        .map((m) =>
            '${m.role == ChatRole.self ? 'User' : 'Assistant'}: '
            '${m.content.length > 700 ? m.content.substring(0, 700) : m.content}')
        .join('\n\n');
    final copy = Conversation(
      id: bytesToHex(randomBytes(8)),
      rootId: bytesToHex(randomBytes(32)),
      title: '${conv.title.isEmpty ? 'New chat' : conv.title} ${t('(branch)')}',
      anon: conv.anon,
      folderId: conv.folderId,
      tags: [...conv.tags],
      repoIds: [...conv.repoIds],
      personaId: conv.personaId,
      systemPrompt: conv.systemPrompt,
      proModel: conv.proModel,
      seed: seed,
    );
    conversations.insert(0, copy);
    await store.saveConversations(conversations);
    await store.saveMessages(copy.id, kept);
    await open(copy);
    return copy;
  }

  /// A fresh root id is what actually resets the model's context: the worker
  /// scopes history to the marker, so a new one is a new thread.
  Future<void> clearCurrent() async {
    final conv = current;
    if (conv == null) return;
    conv.rootId = bytesToHex(randomBytes(32));
    conv.messageCount = 0;
    conv.creditsSpent = 0;
    messages = [];
    artifacts = [];
    await store.saveArtifacts(conv.id, const []);
    await store.saveMessages(conv.id, const []);
    await store.setThread(conv.id, const []);
    await store.saveConversations(conversations);
    notifyListeners();
  }

  void _touch(Conversation conv) {
    conv.updatedAt = DateTime.now();
    conversations.removeWhere((c) => c.id == conv.id);
    conversations.insert(0, conv);
  }

  Future<void> _add(ChatMessage m) async {
    messages = [...messages, m];
    await store.saveMessages(current!.id, messages);
    notifyListeners();
  }

  Future<void> note(String text) => _add(ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.note,
        content: text,
      ));

  Future<void> rate(ChatMessage m, int rating) async {
    final next = m.rating == rating ? 0 : rating;
    messages = messages.map((x) => x.id == m.id ? x.copyWith(rating: next) : x).toList();
    await store.saveMessages(current!.id, messages);
    notifyListeners();
  }

  Future<void> togglePinMessage(ChatMessage m) async {
    messages =
        messages.map((x) => x.id == m.id ? x.copyWith(pinned: !x.pinned) : x).toList();
    await store.saveMessages(current!.id, messages);
    notifyListeners();
  }

  Future<void> deleteMessage(ChatMessage m) async {
    messages = messages.where((x) => x.id != m.id).toList();
    await store.saveMessages(current!.id, messages);
    notifyListeners();
  }

  Future<void> truncateFrom(ChatMessage m, {bool inclusive = true}) async {
    final at = messages.indexWhere((x) => x.id == m.id);
    if (at == -1) return;
    messages = messages.sublist(0, inclusive ? at : at + 1);
    await store.saveMessages(current!.id, messages);
    notifyListeners();
  }

  Future<void> regenerate(ChatMessage reply) async {
    final at = messages.indexWhere((m) => m.id == reply.id);
    ChatMessage? question;
    for (var i = at - 1; i >= 0; i--) {
      if (messages[i].role == ChatRole.self) {
        question = messages[i];
        break;
      }
    }
    if (question == null) {
      await note(t('There is nothing to ask again.'));
      return;
    }
    await deleteMessage(reply);
    await send(question.content);
  }

  Future<void> retryLast() async {
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == ChatRole.self) {
        await send(messages[i].content);
        return;
      }
    }
    await note(t('There is nothing to ask again.'));
  }

  void setQuote(String? text) {
    quote = text;
    notifyListeners();
  }

  void addAttachment(Attachment a) {
    attachments = [...attachments, a];
    notifyListeners();
  }

  void removeAttachment(String id) {
    attachments = attachments.where((a) => a.id != id).toList();
    notifyListeners();
  }

  // --- sending -------------------------------------------------------------------

  void stop() {
    // Stop means stop: a run carrying itself on must not start another leg
    // after the one being aborted.
    _stopped = true;
    _stopWatching();
    chat.abort();
    sending = false;
    status = null;
    notifyListeners();
  }

  /// The last few turns, plain enough for a model that has never seen this
  /// thread to pick up where it left off.
  String compareSeed({int limit = 8}) {
    final kept = messages
        .where((m) => m.role == ChatRole.self || m.role == ChatRole.bot)
        .toList();
    final tail = kept.length > limit ? kept.sublist(kept.length - limit) : kept;
    return tail.map((m) {
      final who = m.role == ChatRole.self ? 'User' : 'Assistant';
      final body =
          m.content.length > 700 ? m.content.substring(0, 700) : m.content;
      return '$who: $body';
    }).join('\n\n');
  }

  /// Asks two models the same thing at once, each on a thread of its own so
  /// neither sees the other's answer and this chat is untouched until one is
  /// kept. Two replies, so two charges.
  Future<List<CompareRun>> compare(
      String text, List<Map<String, dynamic>> models) async {
    final conv = current;
    if (conv == null || sending || models.length < 2) return const [];
    final body = text.trim();
    if (body.isEmpty) return const [];

    sending = true;
    status = null;
    notifyListeners();

    final seed = compareSeed();
    final scoped = activeRepos;
    final persona = activePersona;
    final space = activeWorkspace;
    final bot = activeBot;

    Future<CompareRun> once(Map<String, dynamic> model) async {
      final scratch = Conversation(
        id: 'cmp-${bytesToHex(randomBytes(6))}',
        rootId: bytesToHex(randomBytes(32)),
        anon: conv.anon,
        ephemeral: conv.ephemeral,
        repoIds: [...conv.repoIds],
        personaId: conv.personaId,
        workspaceId: conv.workspaceId,
        botId: conv.botId,
        systemPrompt: conv.systemPrompt,
        proModel: model,
        seed: seed.isEmpty ? null : seed,
      );
      try {
        final res = await chat.send(
          conv: scratch,
          text: body,
          proModel: model,
          repos: scoped,
          persona: persona,
          workspace: space,
          bot: bot,
          webSearch: settings.webSearch,
          firstTurn: true,
          onThreadIds: (_) {},
        );
        return CompareRun(
          model: model,
          reply: res.reply,
          thinking: res.thinking,
          cost: res.cost,
          sources: res.sources,
        );
      } on ChatFailure catch (e) {
        return CompareRun(model: model, error: e.message);
      } catch (e) {
        return CompareRun(model: model, error: e.toString());
      }
    }

    final out = await Future.wait(models.map(once));
    sending = false;
    status = null;

    final spent = out.fold<int>(0, (n, r) => n + r.cost);
    if (spent > 0) await store.recordUsage(spent);
    notifyListeners();
    return out;
  }

  /// Folds the winning answer into the chat. Neither reply was on this chat's
  /// thread, so the worker has never seen this turn: the chat takes a fresh
  /// thread and carries the transcript forward as its seed, exactly as a
  /// branch does.
  Future<void> keepCompare(String prompt, CompareRun run) async {
    final conv = current;
    if (conv == null || !run.ok) return;

    await _add(ChatMessage(
      id: bytesToHex(randomBytes(8)),
      role: ChatRole.self,
      content: prompt,
    ));
    final reply = ChatMessage(
      id: bytesToHex(randomBytes(8)),
      role: ChatRole.bot,
      content: run.reply,
      thinking: run.thinking,
      cost: run.cost,
      model: run.label,
      sources: run.sources,
    );
    await _add(reply);
    await harvestArtifacts(reply);

    conv.rootId = bytesToHex(randomBytes(32));
    conv.seed = compareSeed();
    if (conv.title.isEmpty) conv.title = ChatEngine.titleFor(prompt);
    conv.messageCount += 1;
    conv.creditsSpent += run.cost;
    _touch(conv);
    await store.saveConversations(conversations);
    await store.setThread(conv.id, const []);
    notifyListeners();
  }

  Future<void> send(String text) async {
    final conv = current;
    if (conv == null || sending || text.trim().isEmpty) return;
    _stopped = false;
    continuedSpend = 0;
    final body = text.trim();
    final sent = [...attachments];
    final quoted = quote;
    attachments = [];
    quote = null;

    await _add(ChatMessage(
      id: bytesToHex(randomBytes(8)),
      role: ChatRole.self,
      content: body,
      attachments: sent,
      quote: quoted,
    ));

    if (conv.title.isEmpty) {
      conv.title = ChatEngine.titleFor(body);
      _touch(conv);
      await store.saveConversations(conversations);
    }

    sending = true;
    status = null;
    notifyListeners();
    chat.onStatus = (s) {
      status = s;
      notifyListeners();
    };

    final scoped = activeRepos;
    try {
      final res = await chat.send(
        conv: conv,
        text: body,
        proModel: activeModel,
        repos: scoped,
        persona: activePersona,
        workspace: activeWorkspace,
        bot: activeBot,
        attachments: sent,
        quote: quoted,
        webSearch: settings.webSearch,
        firstTurn: store.thread(conv.id).isEmpty,
        onTurn: _watchTurn,
        onThreadIds: (ids) {
          final thread = [...store.thread(conv.id), ...ids];
          unawaited(store.setThread(conv.id, thread));
        },
      );
      _stopWatching();
      final reply = ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.bot,
        content: res.reply,
        thinking: res.thinking,
        cost: res.cost,
        model: res.pro ? (activeModel?['label'] as String?) : null,
        calls: res.modelCalls,
        repos: res.repos.length > 1 ? res.repos : const [],
        sources: res.sources,
      );
      await _add(reply);
      await harvestArtifacts(reply);
      if (conv.seed != null) conv.seed = null;
      conv.messageCount += 1;
      conv.creditsSpent += res.cost;
      _touch(conv);
      await store.saveConversations(conversations);
      await store.recordUsage(res.cost);
      if (res.balance != null) {
        if (res.pro) {
          proBalance = res.balance;
        } else {
          standardBalance = res.balance;
        }
      }
      if (res.lowBalance) {
        // In an anonymous chat a low balance is usually the throwaway key
        // running dry rather than the nym, which is what the automatic
        // transfer is for.
        final topped = conv.anon ? await autoTopUp() : null;
        if (topped != null) {
          await note(describeTopUp(topped));
        } else {
          await note(res.pro
              ? t('Pro credits running low: {n} left. Tap Buy to top up.',
                  {'n': res.balance})
              : t('Credits running low: {n} left. Tap Buy to top up.',
                  {'n': res.balance}));
        }
      }
      if (res.truncated) {
        // Out of the try's finally, so the loop runs with `sending` under its
        // own control rather than fighting the one being unwound.
        unawaited(Future<void>.microtask(() => _carryOn(res)));
      }
    } on ChatFailure catch (e) {
      if (e.cancelled) {
        await note(t('Stopped. That reply was not charged for unless it had already finished.'));
      } else if (e.noCredits) {
        if (e.pro) {
          proBalance = e.balance;
        } else {
          standardBalance = e.balance;
        }
        final topped = conv.anon ? await autoTopUp(force: true) : null;
        if (topped != null) {
          await note('${describeTopUp(topped)} '
              '${t('Send that again when you are ready.')}');
        } else {
          await note(e.message);
        }
      } else {
        await _add(ChatMessage(
          id: bytesToHex(randomBytes(8)),
          role: ChatRole.error,
          content: e.message,
          retry: body,
        ));
      }
    } catch (e) {
      await _add(ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.error,
        content: t('Something went wrong sending that message.'),
        retry: body,
      ));
    } finally {
      _stopWatching();
      sending = false;
      status = null;
      notifyListeners();
    }
  }

  /// A repo run stopped at its tool-call cap with work left. Spend the budget
  /// the user set on carrying it on, one leg at a time, saying what each leg
  /// cost as it goes — never silently.
  Future<void> _carryOn(TurnResult first) async {
    final conv = current;
    if (conv == null) return;
    var token = first.resumeToken;
    var reserve = first.nextReserve;
    if (token == null || token.isEmpty) {
      await note(t('That answer stopped early and could not be resumed. Ask again to pick it up.'));
      return;
    }
    var left = continueBudget;
    if (left <= 0) {
      await note(t('That answer stopped early. Turn on continuing in Appearance, or ask it to carry on.'));
      return;
    }
    if (reserve > left) {
      await note(t('That answer stopped early. Carrying on reserves {n} more credits than the budget left.',
          {'n': reserve - left}));
      return;
    }

    while (token != null && token.isNotEmpty && left > 0 && !_stopped) {
      sending = true;
      status = t('Carrying on where it left off');
      notifyListeners();
      TurnResult next;
      try {
        next = await chat.send(
          conv: conv,
          text: t('Continue.'),
          proModel: activeModel,
          repos: activeRepos,
          persona: activePersona,
          workspace: activeWorkspace,
          bot: activeBot,
          webSearch: settings.webSearch,
          firstTurn: false,
          resume: token,
          onTurn: _watchTurn,
          onThreadIds: (ids) {
            final thread = [...store.thread(conv.id), ...ids];
            unawaited(store.setThread(conv.id, thread));
          },
        );
      } on ChatFailure catch (e) {
        _stopWatching();
        sending = false;
        status = null;
        await note(e.message);
        return;
      } catch (_) {
        _stopWatching();
        sending = false;
        status = null;
        await note(t('Could not carry on from there.'));
        return;
      }
      _stopWatching();
      sending = false;
      status = null;

      final more = ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.bot,
        content: next.reply,
        thinking: next.thinking,
        cost: next.cost,
        model: next.pro ? (activeModel?['label'] as String?) : null,
        calls: next.modelCalls,
        sources: next.sources,
      );
      await _add(more);
      await harvestArtifacts(more);
      conv.messageCount += 1;
      conv.creditsSpent += next.cost;
      _touch(conv);
      await store.saveConversations(conversations);
      await store.recordUsage(next.cost);
      continuedSpend += next.cost;
      if (next.balance != null) {
        if (next.pro) {
          proBalance = next.balance;
        } else {
          standardBalance = next.balance;
        }
      }

      left = continueBudget;
      token = next.truncated ? next.resumeToken : null;
      reserve = next.nextReserve;

      if (token != null && token.isNotEmpty && reserve > left) {
        await note(t('Stopped: carrying on again needs {n} credits and {left} are left in the budget.',
            {'n': reserve, 'left': left}));
        return;
      }
      if (token != null && token.isNotEmpty && left <= 0) {
        await note(t('Budget spent — {n} credits on carrying that on. Raise it in Appearance to go further.',
            {'n': continuedSpend}));
        return;
      }
    }
    if (continuedSpend > 0) {
      await note(t('Finished. Carrying on cost {n} extra credits.', {'n': continuedSpend}));
      continuedSpend = 0;
    }
  }

  // --- balances --------------------------------------------------------------------

  Future<void> refreshBalance({bool announce = false}) async {
    final useAnon = (current?.anon ?? false) && anon.ready;
    final signer = useAnon ? await anon.signer() : identity.signer;
    final res = await api.balance(signer);
    if (res.data['error'] != null) {
      if (announce) await note(t('Could not reach Nymbot to check your balance.'));
      return;
    }
    standardBalance = (res.data['balance'] as num?)?.toInt() ?? 0;
    proBalance = (res.data['proBalance'] as num?)?.toInt() ?? 0;
    notifyListeners();
    if (announce) {
      final vars = {'standard': standardBalance, 'pro': proBalance};
      await note(useAnon
          ? t("This chat's anonymous balance: {standard} standard, {pro} Pro. "
              'Tap Anon to move more across from your nym.', vars)
          : t('Your balance: {standard} standard, {pro} Pro.', vars));
    }
  }

  int? get shownBalance => activeModel != null ? proBalance : standardBalance;

  String get satsLabel => activeModel != null ? 'Pro' : 'Standard';

  int satsFor(int credits, String tier) =>
      credits * (NymbotConfig.satsPerCredit[tier] ?? 10);

  CostEstimate estimate(String text) => ChatEngine.estimate(text, activeModel);

  ({int sent, int replies, int credits, int words}) currentStats() {
    var sent = 0;
    var replies = 0;
    var credits = 0;
    var words = 0;
    for (final m in messages) {
      if (m.role == ChatRole.self) sent++;
      if (m.role == ChatRole.bot) replies++;
      credits += m.cost;
      words += m.content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    }
    return (sent: sent, replies: replies, credits: credits, words: words);
  }

  Future<void> wipe() async {
    _bootWork?.cancel();
    await store.wipe();
    identity.forget();
    relays.close();
    conversations = [];
    messages = [];
    repos = [];
    current = null;
    signedIn = false;
    _entered = false;
    notifyListeners();
  }
}
