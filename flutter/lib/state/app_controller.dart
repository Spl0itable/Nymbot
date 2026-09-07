import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../core/crypto/keys.dart';
import '../features/i18n/i18n.dart';
import '../models/conversation.dart';
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

  List<GitRepo> get activeRepos {
    final ids = current?.repoIds ?? const <String>[];
    return repos.where((r) => ids.contains(r.id) && r.enabled).toList();
  }

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

  Persona? get activePersona => store.persona(current?.personaId);

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
    );
    conversations.insert(0, conv);
    await store.saveConversations(conversations);
    await open(conv);
    return conv;
  }

  Future<void> open(Conversation conv) async {
    current = conv;
    messages = store.messages(conv.id);
    attachments = [];
    quote = null;
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
    chat.abort();
    sending = false;
    status = null;
    notifyListeners();
  }

  Future<void> send(String text) async {
    final conv = current;
    if (conv == null || sending || text.trim().isEmpty) return;
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
        attachments: sent,
        quote: quoted,
        webSearch: settings.webSearch,
        firstTurn: store.thread(conv.id).isEmpty,
        onThreadIds: (ids) {
          final thread = [...store.thread(conv.id), ...ids];
          unawaited(store.setThread(conv.id, thread));
        },
      );
      await _add(ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.bot,
        content: res.reply,
        thinking: res.thinking,
        cost: res.cost,
        model: res.pro ? (activeModel?['label'] as String?) : null,
        repos: res.repos.length > 1 ? res.repos : const [],
        sources: res.sources,
      ));
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
      sending = false;
      status = null;
      notifyListeners();
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
