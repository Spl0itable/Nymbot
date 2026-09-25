import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/crypto/bech32_codec.dart';
import '../core/crypto/keys.dart';
import '../core/crypto/schnorr.dart' as schnorr;
import '../features/i18n/i18n.dart';
import '../models/artifact.dart';
import '../models/bot.dart';
import '../models/compare.dart';
import '../models/connector.dart';
import '../models/invoice.dart';
import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/model_maker.dart';
import '../models/schedule.dart';
import '../models/nostr_event.dart';
import '../models/notice.dart';
import '../models/workspace.dart';
import '../services/account_sync.dart';
import '../services/anon.dart';
import '../services/backup.dart';
import '../services/blossom.dart';
import '../services/chat_engine.dart';
import '../services/connectors.dart';
import '../services/doc_library.dart';
import '../services/free_tier.dart';
import '../services/gifts.dart';
import '../services/key_backup.dart';
import '../services/git_review.dart';
import '../services/memory_keeper.dart';
import '../services/mentions.dart';
import '../services/nickname.dart';
import '../services/nostr/event_signer.dart';
import '../services/nostr/nip46.dart';
import '../services/nostr/signer_links.dart';
import '../services/nymbot_api.dart';
import '../services/passkey_backup.dart';
import '../core/crypto/pq.dart' as pq_crypto;
import '../services/pq_announce.dart';
import '../services/profiles.dart';
import '../services/relay_pool.dart';
import '../services/reply_notify.dart';
import '../services/research.dart';
import '../services/server_runs.dart';
import '../services/spend_caps.dart';
import '../services/storage_sync.dart';
import '../services/tasks.dart';
import '../services/team.dart';
import 'identity.dart';
import 'store.dart';

/// What the account already holds, as the sign-in gate needs to know it.
/// [read] is false when neither D1 nor the relays could be reached — which is
/// not the same answer as "there is no root".
class RootLinkVerdict {
  const RootLinkVerdict(this.status,
      {this.probe, this.epoch = 0, this.announcedOnly = false});

  final String status;
  final AccountRoot? probe;
  final int epoch;
  final bool announcedOnly;
}

typedef ChatSnapshot = ({
  Conversation conv,
  String rootId,
  String? seed,
  int messageCount,
  double creditsSpent,
  double? satsSpent,
  List<ChatMessage> messages,
  List<String> thread,
});

typedef AccountRoot = ({
  bool read,
  bool present,
  String? fingerprint,
  Uint8List? announced,
});

/// One object the whole app listens to: the identity, the conversations, the
/// toolbar's state and the balances.
class AppController extends ChangeNotifier {
  AppController._(this.store, this.identity, this.relays, this.pq, this.api,
      this.anon, this.storage) {
    sync = AccountSync(store: store, identity: identity, storage: storage);
    DocLibrary.bind(store);
  }

  static PqKeyServer? Function(NymbotApi api) pqKeyServer =
      (api) => api.pqKey;

  static Future<AppController> boot(
      {http.Client? client,
      Store? store,
      Nip46SocketFactory? signerSockets,
      PqKeyServer? pqKeys,
      StorageSync? storage}) async {
    store ??= await Store.open();
    final identity = Identity(store,
        restoreSigner: (session) =>
            restoreRemoteSigner(session, sockets: signerSockets));
    final relays = RelayPool();
    final api = NymbotApi(client: client);
    final pq = PqAnnounce(relays,
        store: store, keyServer: pqKeys ?? pqKeyServer(api));
    final anon = AnonMode(store, api, pq);
    storage ??= StorageSync();
    final c = AppController._(store, identity, relays, pq, api, anon, storage);
    c.signerSockets = signerSockets;
    c.blossom = Blossom(client: client);
    c.profiles = Profiles(store, relays, storage);
    c.profiles.addListener(c.notifyListeners);
    await anon.load();
    c.signedIn = await identity.restore();
    c._loadSettings();
    c.invoice = PendingInvoice.decode(store.getString(_invoiceKey));
    await c._loadRepos();
    await c._loadConnectors();
    return c;
  }

  final Store store;
  final Identity identity;
  final RelayPool relays;
  final PqAnnounce pq;
  final NymbotApi api;
  final AnonMode anon;
  final StorageSync storage;

  late final AccountSync sync;

  late final Profiles profiles;

  late final Blossom blossom;

  late final UploadLedger uploads = UploadLedger(
    readRecords: () => store.secret('uploads'),
    writeRecords: (json) => store.setSecret('uploads', json),
  );

  late final ChatEngine chat = ChatEngine(
    identity: identity,
    relays: relays,
    pq: pq,
    api: api,
    anon: anon,
  );

  Nip46SocketFactory? signerSockets;

  KeyBackups keyBackups = KeyBackups.platform();

  late PasskeyBackup passkeys = PasskeyBackup(relays: relays);

  late final ReplyNotify replyNotify = ReplyNotify(
    enabled: () => settings.replyNotify,
    register: _registerReplyNotify,
    titleOf: (id) => _conversationById(id)?.title ?? '',
    open: openChat,
  );

  static const _notifyAskedKey = 'reply_notify_asked';

  Conversation? _conversationById(String id) {
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> openChat(String id) async {
    final conv = _conversationById(id);
    if (conv != null) await open(conv);
  }

  Future<Map<String, dynamic>?> _registerReplyNotify(
      String id, Map<String, dynamic> body) async {
    final conv = _conversationById(id);
    if (conv == null) return null;
    final signer =
        conv.anon && anon.ready ? await anon.signer() : identity.signer;
    final res = await api.call('notify-turn', signer,
        extra: body, timeout: const Duration(seconds: 10));
    return res.status == 0 ? null : res.data;
  }

  Future<void> setReplyNotify(bool on) async {
    settings.replyNotify = on;
    await store.saveSettings(settings);
    notifyListeners();
    if (on) await store.setBool(_notifyAskedKey, true);
    await replyNotify.settingChanged(on);
  }

  void _askReplyNotifyOnce() {
    if (!settings.replyNotify || !replyNotify.supported) return;
    if (store.getBool(_notifyAskedKey)) return;
    unawaited(store.setBool(_notifyAskedKey, true));
    unawaited(replyNotify.askPermission());
  }

  bool signedIn = false;
  bool _entered = false;
  Timer? _bootWork;
  Timer? _syncTimer;
  Timer? _noticeTimer;
  int _noticeSeq = 0;
  bool _topping = false;
  int relaysUp = 0;

  final Map<String, ChatTurn> turns = {};
  final Map<String, List<String>> _queues = {};
  final Map<String, int> _queueEdits = {};

  ChatTurn? turnOf(Conversation? conv) =>
      conv == null ? null : turns[conv.id];

  bool sendingIn(Conversation? conv) => turnOf(conv) != null;

  bool get sending => sendingIn(current);

  String? get status => turnOf(current)?.status;

  List<TurnStep> get progressSteps => turnOf(current)?.steps ?? const [];

  String? get progressDraft => turnOf(current)?.draft;

  final Set<String> streamedReplies = {};

  bool researchNext = false;

  bool get researching => turnOf(current)?.research != null;

  bool get teaming => turnOf(current)?.team != null;

  int get teamWorkers =>
      (turnOf(current)?.team?['workers'] as num?)?.toInt() ?? 0;

  Map<String, dynamic>? teamLeadOf(Conversation? conv) =>
      mediaModelOf(conv) != null ? null : modelOf(conv);

  String? teamModeOf(Conversation? conv) => conv == null
      ? null
      : Team.mode(
          lead: teamLeadOf(conv),
          research: researchNext,
          repos: reposOf(conv).isNotEmpty);

  bool get teamAvailable => teamModeOf(current) != null;

  TeamSetting? get teamSetting => Team.settingOf(current?.team);

  bool teamLeadTools(Conversation? conv, {String? mode}) =>
      conv != null &&
      ((!conv.anon && connectorsOf(conv).isNotEmpty) ||
          ((mode ?? teamModeOf(conv)) != 'research' &&
              conv.serverRuns &&
              reposOf(conv).isNotEmpty));

  Future<TeamEstimate> teamEstimate(Conversation conv,
      {required int workers,
      required String model,
      required String mode,
      Map<String, dynamic>? lead}) async {
    final leader = lead ?? teamLeadOf(conv);
    if (leader == null) return (max: 0, typical: 0.0, error: Team.needsPro());
    final res = await api.teamEstimate(Team.estimateBody(
        leader, workers, model, mode,
        leadTools: teamLeadTools(conv, mode: mode)));
    return Team.estimateOf(res.status, res.data);
  }

  Future<void> setTeam(Conversation conv, Map<String, dynamic>? team) async {
    conv.team = team;
    _touch(conv);
    await store.saveConversations(conversations);
    notifyListeners();
  }

  bool toggleResearch() {
    if (!researchNext && activeModel == null) return false;
    researchNext = !researchNext;
    if (researchNext) unawaited(ensurePricing());
    notifyListeners();
    return true;
  }

  String? researchHint(String text) => Research.hint(
      text: text,
      armed: researchNext,
      model: activeModel,
      pricing: catalogPricing);

  List<String> get queued => _queues[current?.id] ?? const [];

  int? get editingQueued => _queueEdits[current?.id];

  void editQueued(int at, {Conversation? target}) {
    final conv = target ?? current;
    final queue = conv == null ? null : _queues[conv.id];
    if (queue == null || at < 0 || at >= queue.length) return;
    _queueEdits[conv!.id] = at;
    notifyListeners();
  }

  Future<void> saveQueued(String text, {Conversation? target}) async {
    final conv = target ?? current;
    if (conv == null) return;
    final at = _queueEdits.remove(conv.id);
    final queue = _queues[conv.id];
    if (at != null && queue != null && at < queue.length) {
      final body = text.trim();
      if (body.isEmpty) {
        queue.removeAt(at);
        if (queue.isEmpty) _queues.remove(conv.id);
      } else {
        queue[at] = body;
      }
    }
    notifyListeners();
    await _sendQueued(conv);
  }

  Future<void> cancelQueuedEdit({Conversation? target}) async {
    final conv = target ?? current;
    if (conv == null || _queueEdits.remove(conv.id) == null) return;
    notifyListeners();
    await _sendQueued(conv);
  }

  @visibleForTesting
  Future<void> carryOnForTest(Conversation conv, TurnResult first) =>
      _carryOn(ChatTurn(conv), first);

  @visibleForTesting
  void holdForTest(Conversation conv) {
    turns[conv.id] = ChatTurn(conv);
    notifyListeners();
  }

  @visibleForTesting
  void watchTurnForTest(ChatTurn turn, String eventId) => _watchTurn(turn, eventId);

  @visibleForTesting
  void draftForTest(ChatTurn turn, String text) {
    turn.draft = text;
    turn.drafted = true;
    notifyListeners();
  }

  @visibleForTesting
  Future<void> landForTest(ChatTurn turn, ChatMessage reply) async {
    _stopWatching(turn, keepDraft: true);
    if (turn.drafted) streamedReplies.add(reply.id);
    turn.draft = null;
    await _addTo(turn.conv, reply);
  }

  @visibleForTesting
  void endTurnForTest(ChatTurn turn) {
    turn.watching = false;
    _endTurn(turn);
  }

  @visibleForTesting
  Future<void> releaseForTest(Conversation conv) async {
    turns.remove(conv.id);
    notifyListeners();
    await _sendQueued(conv);
  }

  List<Conversation> conversations = [];
  Conversation? current;
  List<ChatMessage> messages = [];
  List<Artifact> artifacts = [];

  AppSettings settings = AppSettings();
  List<GitRepo> repos = [];
  List<McpConnector> connectors = [];
  Map<String, dynamic>? proModel;
  Map<String, dynamic>? mediaModel;
  double? standardBalance;
  double? proBalance;
  double? anonStandardBalance;
  double? anonProBalance;

  /// What the day's free allowance has left on the key that is signed in, as
  /// the worker last reported it.
  FreeAllowance? free;

  String convFilter = 'all';
  String convSearch = '';
  List<String> favouriteModels = [];
  List<Notice> notices = [];
  List<int> dismissedNotices = [];
  String? quote;
  List<Attachment> attachments = [];

  Future<String> Function(CapPrompt prompt)? onCapPrompt;
  String? _capReturned;
  String? _capWaive;

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
        mediaModel = j['mediaModel'] as Map<String, dynamic>?;
      } catch (_) {}
    }
    favouriteModels = store.favouriteModels();
    dismissedNotices = store.dismissedNotices();
  }

  Future<void> _saveModel() => store.setString(
      'settings', jsonEncode({'proModel': proModel, 'mediaModel': mediaModel}));

  Future<void> saveSettings(AppSettings next) async {
    settings = next;
    await store.saveSettings(next);
    notifyListeners();
  }

  Future<void> resetSettings() async {
    final kept = (name: settings.nickname, at: settings.nicknameAt);
    await store.resetSettings();
    settings = store.settings();
    if (kept.at > 0) {
      settings
        ..nickname = kept.name
        ..nicknameAt = kept.at;
      await store.saveSettings(settings);
    }
    notifyListeners();
  }

  String get nickname => Nickname.clean(settings.nickname);

  Future<String> setNickname(String value) async {
    final cleaned = Nickname.clean(value);
    settings
      ..nickname = cleaned
      ..nicknameAt = DateTime.now().millisecondsSinceEpoch;
    await store.saveSettings(settings);
    notifyListeners();
    return cleaned;
  }

  String selfNameIn(Conversation? conv, String? published) {
    if (conv?.anon ?? false) return t('Anon');
    final nick = nickname;
    return nick.isNotEmpty ? nick : (published ?? '');
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
    await clearMediaModel();
    notifyListeners();
  }

  Map<String, dynamic>? modelOf(Conversation? conv) =>
      conv?.proModel ?? proModel;

  Map<String, dynamic>? get activeModel => modelOf(current);

  bool get repoNeedsPro => activeRepos.isNotEmpty && activeModel == null;

  Map<String, dynamic>? mediaModelOf(Conversation? conv) =>
      conv?.mediaModel ?? mediaModel;

  Map<String, dynamic>? get activeMediaModel => mediaModelOf(current);

  Future<void> setMediaModel(Map<String, dynamic>? model,
      {bool forChat = false}) async {
    if (forChat) {
      final conv = current;
      if (conv != null) {
        conv.mediaModel = model;
        await store.saveConversations(conversations);
      }
    } else {
      mediaModel = model;
      await _saveModel();
      final conv = current;
      if (conv != null && conv.mediaModel != null) {
        conv.mediaModel = null;
        await store.saveConversations(conversations);
      }
    }
    notifyListeners();
  }

  static final RegExp _hasModelFlag = RegExp(r'(?:^|\s)(?:--model|-m)[\s=]');
  static final RegExp _bareGenerator = RegExp(r'^(\?\w+)\s+(\S+)$');

  /// The catalog names a generator positionally, but the worker reads it only
  /// from --model — left as sent, the name lands in the prompt and the default
  /// generator runs, and is charged, in place of the one that was picked.
  static String generatorCommand(String? command) {
    final raw = (command ?? '').trim();
    if (_hasModelFlag.hasMatch(raw)) return raw;
    return raw.replaceFirstMapped(
        _bareGenerator, (m) => '${m[1]} --model ${m[2]}');
  }

  /// The key that says the turn is Pro. A generator is named inside the
  /// message, never in that field, so a Pro generator carries the key it
  /// should be billed against rather than putting a chat model in the picker.
  Map<String, dynamic>? get proModelForTurn => proModelForTurnOf(current);

  Map<String, dynamic>? proModelForTurnOf(Conversation? conv) {
    final model = modelOf(conv);
    if (model != null) return model;
    final media = mediaModelOf(conv);
    final key = media?['proKey'] as String?;
    return (mediaNeedsPro(media) && key != null) ? {'key': key} : null;
  }

  static Map<String, dynamic> mediaFor(Map<String, dynamic> m,
      {String? slug, Map<String, dynamic>? catalog}) {
    final credits = (m['credits'] as num?)?.toInt() ?? 0;
    final media = <String, dynamic>{
      'key': m['key'],
      'label': m['label'],
      'kind': m['kind'] ?? 'image',
      'credits': credits,
      'max': (m['max'] as num?)?.toInt() ?? credits,
      'command': generatorCommand(m['command'] as String?),
      'slug': slug,
    };
    if (mediaNeedsPro(media)) media['proKey'] = cheapestChatKey(catalog);
    return media;
  }

  static String? cheapestChatKey(Map<String, dynamic>? catalog) {
    final groups =
        (catalog?['groups'] as List?)?.cast<Map<String, dynamic>>() ??
            const [];
    final byKey = {
      for (final m in (catalog?['models'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[])
        m['key'] as String: m
    };
    String? best;
    var cheapest = 1 << 30;
    var ceiling = 1 << 30;
    for (final group in groups) {
      for (final key in (group['keys'] as List).cast<String>()) {
        final m = byKey[key];
        if (m == null) continue;
        final kind = m['kind'] as String?;
        if ((kind != null && kind != 'chat') || m['command'] != null) continue;
        final credits = (m['credits'] as num?)?.toInt() ?? 0;
        final max = (m['max'] as num?)?.toInt() ?? credits;
        if (credits > cheapest || (credits == cheapest && max >= ceiling)) {
          continue;
        }
        cheapest = credits;
        ceiling = max;
        best = m['key'] as String?;
      }
    }
    return best;
  }

  static bool mediaNeedsPro(Map<String, dynamic>? media) =>
      media != null &&
      (media['kind'] == 'image' ||
          media['kind'] == 'video' ||
          media['kind'] == 'speech');

  Future<void> clearMediaModel() async {
    if (activeMediaModel == null) return;
    final conv = current;
    if (conv != null && conv.mediaModel != null) {
      conv.mediaModel = null;
      await store.saveConversations(conversations);
    }
    if (mediaModel != null) {
      mediaModel = null;
      await _saveModel();
    }
    notifyListeners();
  }

  Future<void> dropProMedia() async {
    if (!mediaNeedsPro(activeMediaModel)) return;
    await clearMediaModel();
  }

  static final RegExp _commandVerb = RegExp(r'^\?(\w+)');
  static final RegExp _commandHead = RegExp(r'^\?(\w+)\s*([\s\S]*)$');
  static final RegExp _listsModels = RegExp(r'^models?$', caseSensitive: false);

  String withMediaModel(String text, {Conversation? conv}) {
    final media = mediaModelOf(conv ?? current);
    final command = media?['command'] as String?;
    if (command == null || command.isEmpty) return text;
    final verb = _commandVerb.firstMatch(command)?.group(1) ?? '';
    final head = _commandHead.firstMatch(text);
    if (head == null) {
      return text.startsWith('!') ? text : '$command $text';
    }
    final rest = (head.group(2) ?? '').trim();
    if (head.group(1)!.toLowerCase() != verb.toLowerCase()) return text;
    if (rest.isEmpty || _listsModels.hasMatch(rest)) return text;
    if (_hasModelFlag.hasMatch(rest)) return text;
    return '$command $rest';
  }

  Future<void> toggleFavouriteModel(String key) async {
    favouriteModels = favouriteModels.contains(key)
        ? (favouriteModels.where((k) => k != key).toList())
        : ([...favouriteModels, key]);
    await store.saveFavouriteModels(favouriteModels);
    notifyListeners();
  }

  Future<void> setAnonEnabled(bool on) async {
    await anon.setEnabled(on);
    final conv = current;
    if (conv != null && messages.isEmpty && conv.anon != on) {
      conv.anon = on;
      await store.saveConversations(conversations);
    }
    if (on) {
      await anon.flush(identity: identity.signer);
      await autoTopUp();
    }
    notifyListeners();
  }

  bool get canFlipAnon =>
      current != null &&
      !messages.any((m) => m.role == ChatRole.self || m.role == ChatRole.bot);

  Future<bool> setChatAnon(bool on) async {
    final conv = current;
    if (conv == null || !canFlipAnon) return false;
    if (on && !anon.enabled) await setAnonEnabled(true);
    conv.anon = on;
    await store.saveConversations(conversations);
    notifyListeners();
    return true;
  }

  Future<Conversation> newAnonConversation() async {
    if (!anon.enabled) await setAnonEnabled(true);
    final conv = await newConversation();
    conv.anon = true;
    await store.saveConversations(conversations);
    notifyListeners();
    return conv;
  }

  Future<({String? text, String? error})> transcribe(Uint8List audio) async {
    final signer = spendingAnon ? await anon.signer() : identity.signer;
    final res = await api.call('transcribe', signer,
        extra: {'audio': base64Encode(audio)},
        timeout: const Duration(seconds: 60));
    final error = res.data['error'];
    if (error is String && error.isNotEmpty) return (text: null, error: error);
    final said = '${res.data['text'] ?? ''}'.trim();
    return (text: said, error: null);
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
    final ghosts = {
      for (final c in conversations)
        if (c.ephemeral) c.id
    };
    for (final id in doomed) {
      if (!ghosts.contains(id)) await store.bury(id);
      await store.dropConversation(id);
      await DocLibrary.instance.forget(id);
    }
    conversations.removeWhere((c) => doomed.contains(c.id));
    await store.saveConversations(conversations);
    return doomed.length;
  }

  // --- carrying a capped run on --------------------------------------------

  double get continueBudget =>
      continueBudgetAfter(turnOf(current)?.continuedSpend ?? 0);

  /// What is left of this chat's continuation budget. A budget of -1 is
  /// "whatever the balance holds", which is still a real ceiling — it is just
  /// the user's own balance rather than a number they typed.
  double continueBudgetAfter(double spent) {
    final cap = settings.autoContinue;
    if (cap == 0) return 0;
    if (cap < 0) {
      final have = proBalance;
      return have == null || have < 0 ? 0 : have;
    }
    final left = cap - spent;
    return left < 0 ? 0 : left;
  }

  Future<void> setAutoContinue(int credits) async {
    settings.autoContinue = credits;
    await store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setSync(bool on) async {
    settings.sync = on;
    await store.saveSettings(settings);
    if (on) {
      sync.follow();
      unawaited(sync.run());
    } else {
      sync.stop();
    }
    notifyListeners();
  }

  Future<void> setShowProgress(bool on) async {
    settings.showProgress = on;
    await store.saveSettings(settings);
    notifyListeners();
  }

  Notice? get visibleNotice =>
      settings.notices ? Notice.newest(notices, dismissedNotices) : null;

  Future<void> setNotices(bool on) async {
    settings.notices = on;
    await store.saveSettings(settings);
    if (on) {
      unawaited(refreshNotices());
    } else {
      notices = [];
    }
    notifyListeners();
  }

  Future<void> refreshNotices() async {
    if (!settings.notices) return;
    final seq = ++_noticeSeq;
    final fresh = await api.notices();
    if (seq != _noticeSeq) return;
    if (!settings.notices || (fresh.isEmpty && notices.isEmpty)) return;
    notices = fresh;
    notifyListeners();
  }

  Future<void> dismissNotice(int id) async {
    dismissedNotices = Notice.dismiss(dismissedNotices, id);
    notifyListeners();
    await store.saveDismissedNotices(dismissedNotices);
  }

  /// Polls the worker for what the turn is doing. Stops the moment the turn is
  /// over, and never keeps the send waiting on it.
  void _watchTurn(ChatTurn turn, String eventId) {
    _askReplyNotifyOnce();
    replyNotify.pendingTurn(turn.conv.id, eventId);
    final showSteps = settings.showProgress ||
        turn.research != null ||
        turn.team != null;
    turn.watching = true;
    turn.draft = null;
    turn.steps = showSteps
        ? turn.steps.where((s) => s.n == 0 && s.kind == 'stage').toList()
        : [];
    () async {
      var after = 0;
      var draftAfter = 0;
      while (turn.watching) {
        final signer = turn.conv.anon && anon.enabled
            ? await anon.signer()
            : identity.signer;
        String? draft;
        final raw = await chat.progressRaw(signer, eventId,
            after: after,
            draftAfter: draftAfter,
            onDraft: (text, seq) {
              draft = text;
              draftAfter = seq;
            });
        final steps = ChatEngine.steps(raw);
        if (!turn.watching) return;
        if (steps.isNotEmpty) after = steps.last.n;
        if (steps.isNotEmpty && showSteps) {
          turn.steps = [...turn.steps, ...steps];
          turn.log = [...turn.log, ...Tasks.compactAll(raw)];
        }
        if (draft != null) {
          turn.draft = draft;
          turn.drafted = true;
        }
        if ((steps.isNotEmpty && showSteps) || draft != null) notifyListeners();
        final fast = turn.draft != null && turn.research == null;
        await Future<void>.delayed(signer.isRemote
            ? const Duration(seconds: 5)
            : Duration(milliseconds: fast ? 600 : 2000));
      }
    }()
        .catchError((_) {});
  }

  void _localStep(ChatTurn turn, Map<String, dynamic> step) {
    if (!settings.showProgress && turn.research == null && turn.team == null) {
      return;
    }
    turn.steps = [...turn.steps, ChatEngine.turnStep({...step, 'n': 0})];
    notifyListeners();
  }

  void _stopWatching(ChatTurn turn, {bool keepDraft = false}) {
    if (!turn.watching && turn.steps.isEmpty && (keepDraft || turn.draft == null)) return;
    turn.watching = false;
    turn.steps = [];
    if (!keepDraft) turn.draft = null;
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

  bool get languageChosen => store.getBool('lang_chosen');

  Future<void> markLanguageChosen() async {
    await store.setBool('lang_chosen', true);
    notifyListeners();
  }

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

  Workspace? get activeWorkspace => workspaceOf(current);

  Workspace? workspaceOf(Conversation? conv) =>
      store.workspace(conv?.workspaceId);

  List<GitRepo> get activeRepos => reposOf(current);

  /// A chat sees its own repositories plus the ones its workspace carries, in
  /// that order and without duplicates.
  List<GitRepo> reposOf(Conversation? conv) {
    final ids = [
      ...conv?.repoIds ?? const <String>[],
      ...workspaceOf(conv)?.repoIds ?? const <String>[],
    ];
    final out = <GitRepo>[];
    final seen = <String>{};
    for (final id in ids) {
      if (out.any((r) => r.id == id)) continue;
      for (final r in repos) {
        if (r.id != id || !r.enabled) continue;
        final where = [r.provider, r.host, r.repo, r.branch].join('|');
        if (!seen.add(where)) continue;
        out.add(r);
      }
    }
    return out;
  }

  /// Repositories this chat picked itself, as opposed to the ones it inherits
  /// from its workspace.
  bool ownsRepo(String id) => current?.repoIds.contains(id) ?? false;

  Future<GitRepo> saveRepo(GitRepo repo, {bool useHere = true}) async {
    final at = repos.indexWhere((r) => r.id == repo.id);
    final before = at == -1 ? '' : repos[at].token;
    if (repo.token != before) {
      repo.tokenAt = DateTime.now().millisecondsSinceEpoch;
    } else if (at != -1 && repo.tokenAt == 0) {
      repo.tokenAt = repos[at].tokenAt;
    }
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

  Future<void> disconnectRepo(String id) async {
    final at = repos.indexWhere((r) => r.id == id);
    if (at == -1 || repos[at].token.isEmpty) return;
    repos[at]
      ..token = ''
      ..tokenAt = DateTime.now().millisecondsSinceEpoch;
    await store.saveRepos(repos);
    notifyListeners();
  }

  Future<void> deleteRepo(String id) async {
    await store.bury(id);
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

  RunnerInfo runner = const RunnerInfo();

  bool get runnerAvailable => runner.available;

  Future<RunnerInfo> refreshRunner() async {
    final fresh = await api.runnerInfo();
    final changed = fresh.available != runner.available || fresh.images.length != runner.images.length;
    runner = fresh;
    if (changed) notifyListeners();
    return runner;
  }

  bool serverRunsOf(Conversation? conv) =>
      conv != null && conv.serverRuns && runner.available && reposOf(conv).isNotEmpty;

  Future<void> toggleServerRuns() async {
    final conv = current;
    if (conv == null) return;
    conv.serverRuns = !conv.serverRuns;
    await store.saveConversations(conversations);
    notifyListeners();
  }

  String runnerLabel(String image) => runner.image(image)?.label ?? image;

  Future<bool> serverRunCapGate(Conversation? conv, double credits) async {
    if (conv == null || !SpendCaps.any(conv, botOf(conv))) return true;
    final gate = await _capGate(conv, true, credits);
    return gate == 'send' || gate == 'ok';
  }

  Future<ServerRunResponse> startServerRun(
      Conversation? conv, Map<String, dynamic> body) async {
    final useAnon = conv != null && conv.anon && anon.ready;
    final signer = useAnon ? await anon.signer() : identity.signer;
    return api.runnerRun(signer, body);
  }

  Future<void> serverRunCharged(Conversation? conv, ServerRunState state) async {
    final credits = state.charged ?? 0;
    _creditBalance(true, state.balance, anonKey: conv != null && conv.anon && anon.ready);
    if (conv != null && credits > 0) {
      _bumpSpent(conv, credits, true);
      conv.creditsSpent += credits;
      _touch(conv);
      await store.saveConversations(conversations);
      await store.recordUsage(credits);
    }
    notifyListeners();
  }

  Future<String> serverRunNoCredits(Conversation? conv, Map<String, dynamic> data) async {
    final useAnon = conv != null && conv.anon && anon.ready;
    final free = data['balanceCredits'] ?? data['balance'];
    if (free is num) _creditBalance(true, free.toDouble(), anonKey: useAnon);
    final topped = useAnon ? await autoTopUp(force: true) : null;
    notifyListeners();
    if (topped != null) {
      return '${describeTopUp(topped)} ${t('Run it again when you are ready.')}';
    }
    return (data['error'] as String?) ?? t('You are out of Pro credits.');
  }

  Future<void> _loadConnectors() async {
    connectors = await store.connectors();
  }

  List<McpConnector> get activeConnectors => connectorsOf(current);

  List<McpConnector> connectorsOf(Conversation? conv) =>
      Connectors.forChat(connectors, conv?.connectorIds ?? const []);

  Future<McpConnector> saveConnector(McpConnector c, {bool useHere = true}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    c.updatedAt = now;
    final at = connectors.indexWhere((x) => x.id == c.id);
    if (at == -1 || !c.sameSecrets(connectors[at])) {
      c.secretAt = now;
    } else if (c.secretAt == 0) {
      c.secretAt = connectors[at].secretAt;
    }
    if (at == -1) {
      connectors = [...connectors, c];
    } else {
      connectors[at] = c;
    }
    await store.saveConnectors(connectors);
    final conv = current;
    if (useHere &&
        conv != null &&
        !conv.connectorIds.contains(c.id) &&
        conv.connectorIds.length < McpConnector.maxPerChat) {
      conv.connectorIds = [...conv.connectorIds, c.id];
      await store.saveConversations(conversations);
    }
    notifyListeners();
    return c;
  }

  Future<void> deleteConnector(String id) async {
    await store.bury(id);
    connectors = connectors.where((c) => c.id != id).toList();
    await store.saveConnectors(connectors);
    for (final c in conversations) {
      c.connectorIds = c.connectorIds.where((x) => x != id).toList();
    }
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<bool> toggleConnectorHere(String id) async {
    final conv = current;
    if (conv == null) return false;
    if (!conv.connectorIds.contains(id) &&
        conv.connectorIds.length >= McpConnector.maxPerChat) {
      return false;
    }
    conv.connectorIds = conv.connectorIds.contains(id)
        ? conv.connectorIds.where((x) => x != id).toList()
        : [...conv.connectorIds, id];
    await store.saveConversations(conversations);
    notifyListeners();
    return true;
  }

  Future<void> setConnectorsHere(List<String> ids) async {
    final conv = current;
    if (conv == null) return;
    conv.connectorIds = ids.take(McpConnector.maxPerChat).toList();
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<List<ConnectorTool>> probeConnector(McpConnector c) =>
      Connectors.probe(api, identity.signer, c, before: c.tools);

  Future<void> _settlePending(Conversation conv, ChatMessage m, String state) async {
    final p = m.pendingTool;
    if (p == null) return;
    await _putPending(conv, m, {...p, 'state': state});
  }

  Future<void> _putPending(
      Conversation conv, ChatMessage m, Map<String, dynamic> settled) async {
    final list = conv.id == current?.id ? messages : store.messages(conv.id);
    final next = list.map((x) => x.id == m.id ? x.copyWith(pendingTool: settled) : x).toList();
    if (conv.id == current?.id) messages = next;
    await store.saveMessages(conv.id, next);
    notifyListeners();
  }

  McpConnector? connectorForPending(Map<String, dynamic>? p) =>
      Connectors.connectorFor(connectors, p);

  bool canAlwaysAllow(Map<String, dynamic>? p) =>
      p != null &&
      p['kind'] != 'server-run' &&
      p['team'] != true &&
      p['destructive'] != true &&
      connectorForPending(p) != null;

  Future<void> allowPendingToolAlways(ChatMessage m) async {
    final p = m.pendingTool;
    final c = connectorForPending(p);
    if (p != null && c != null && canAlwaysAllow(p)) {
      c.trust('${p['tool'] ?? ''}');
      await saveConnector(c, useHere: false);
    }
    await allowPendingTool(m);
  }

  Future<void> denyPendingTool(ChatMessage m) async {
    final conv = current;
    if (conv == null) return;
    if (m.pendingTool?['kind'] == 'server-run' || m.pendingTool?['team'] == true) {
      return _resumePending(m, approve: false);
    }
    await _settlePending(conv, m, 'denied');
  }

  Future<void> allowPendingTool(ChatMessage m) => _resumePending(m, approve: true);

  Future<void> _resumePending(ChatMessage m, {required bool approve}) async {
    final conv = current;
    final p = m.pendingTool;
    if (conv == null || p == null || turns.containsKey(conv.id)) return;
    final run = p['kind'] == 'server-run';
    final runCredits = run && approve ? ((p['maxCredits'] as num?)?.toDouble() ?? 0) : 0.0;
    final token = p['token'] as String? ?? '';
    if (token.isEmpty) {
      await _settlePending(conv, m, 'denied');
      await note(t('That request has expired. Ask again and Nymbot will start it fresh.'), conv: conv);
      return;
    }
    final model = modelOf(conv);
    final text = t('Continue.');
    double? maxCost;
    final waived = _capWaive == conv.id;
    _capWaive = null;
    if (SpendCaps.any(conv, botOf(conv))) {
      final est = ChatEngine.estimate(text, model,
          conv: conv,
          hasRepos: reposOf(conv).isNotEmpty,
          pricing: catalogPricing);
      if (!waived) {
        final gate = await _capGate(conv, est.tier == 'pro' || run, est.high + runCredits);
        if (gate != 'send' && gate != 'ok') return;
        if (gate == 'ok') {
          maxCost = SpendCaps.maxCost(conv, botOf(conv), _messagesOf(conv),
              pro: est.tier == 'pro' || run);
        }
      }
    }
    await _settlePending(conv, m, approve ? 'allowed' : 'denied');
    final turn = ChatTurn(conv);
    if (p['team'] == true) turn.team = <String, dynamic>{};
    turns[conv.id] = turn;
    turn.status = run
        ? (approve ? t('Running on a Nymbot server…') : t('Continuing without the server run…'))
        : approve
            ? t('Running {tool} on {connector}', {'tool': '${p['tool']}', 'connector': '${p['connector']}'})
            : t('Carrying on without {tool}', {'tool': '${p['tool']}'});
    notifyListeners();
    TurnResult? carry;
    var resendWaived = false;
    try {
      final res = await chat.send(
        conv: conv,
        text: text,
        maxCost: maxCost,
        proModel: model,
        repos: reposOf(conv),
        connectors: connectorsOf(conv),
        mcpApprove: !run && approve ? '${p['id']}' : null,
        mcpDecline: !run && !approve ? '${p['id']}' : null,
        serverRuns: serverRunsOf(conv),
        runApprove: run && approve ? '${p['id']}' : null,
        runDecline: run && !approve ? '${p['id']}' : null,
        timeout: run && approve
            ? NymbotConfig.pmTimeout +
                Duration(seconds: ((p['timeoutSec'] as num?)?.toInt() ?? 0) + 180)
            : null,
        persona: personaOf(conv),
        workspace: workspaceOf(conv),
        bot: botOf(conv),
        memories: store.memories(),
        webSearch: settings.webSearch,
        firstTurn: false,
        resume: token,
        onTurn: (eventId) => _watchTurn(turn, eventId),
        onStep: (step) => _localStep(turn, step),
        onThreadIds: (ids) {
          final thread = [...store.thread(conv.id), ...ids];
          unawaited(store.setThread(conv.id, thread));
        },
        control: turn.control,
      );
      _stopWatching(turn, keepDraft: true);
      final reply = ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.bot,
        content: res.reply,
        thinking: res.thinking,
        cost: res.cost,
        pro: res.pro,
        model: res.pro ? (model?['label'] as String?) : null,
        modelKey: res.pro ? _maker(model)?.key : null,
        modelMaker: res.pro ? _maker(model)?.slug : null,
        modelMakerName: res.pro ? _maker(model)?.name : null,
        calls: res.modelCalls,
        checkpoint: res.checkpoint,
        pendingTool: res.pendingTool,
        sources: res.sources,
        followUps: res.followUps,
        serverRunCredits: res.serverRunCredits,
        serverRuns: res.serverRuns,
        team: Team.normalize(res.team),
      );
      if (turn.drafted) streamedReplies.add(reply.id);
      turn.draft = null;
      await _addTo(conv, reply);
      await harvestArtifacts(reply, conv: conv);
      _bumpSpent(conv, res.cost + res.serverRunCredits, res.pro);
      conv.messageCount += 1;
      conv.creditsSpent += res.cost + res.serverRunCredits;
      _touch(conv);
      await store.saveConversations(conversations);
      await store.recordUsage(res.cost);
      _creditBalance(res.pro, res.balance, anonKey: conv.anon && anon.ready);
      if (res.truncated) carry = res;
    } on ChatFailure catch (e) {
      _stopWatching(turn);
      if (e.capExceeded) {
        await _putPending(conv, m, p);
        if (onCapPrompt == null) {
          await note(t('Not sent: this reply could go past the chat\'s spending cap, and nobody was here to agree to it.'),
              conv: conv);
        } else {
          final choice = await onCapPrompt!(
              SpendCaps.refusal(e.required, e.pro, team: e.team));
          resendWaived = choice == 'send';
        }
      } else {
        await note(e.message, conv: conv);
      }
    } catch (_) {
      _stopWatching(turn);
      await note(t('Could not carry on from there.'), conv: conv);
    } finally {
      turn.status = null;
      notifyListeners();
    }
    if (carry != null && !turn.stopped) await _carryOn(turn, carry);
    _endTurn(turn);
    if (resendWaived) {
      _capWaive = conv.id;
      await _resumePending(m, approve: approve);
    }
  }

  List<Persona> get personas => store.personas();

  Persona? get activePersona => personaOf(current);

  Persona? personaOf(Conversation? conv) =>
      store.persona(conv?.personaId ?? workspaceOf(conv)?.personaId);

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
    await store.bury(id);
    await store.savePersonas(
        store.customPersonas().where((p) => p.id != id).toList());
    for (final c in conversations) {
      if (c.personaId == id) c.personaId = null;
    }
    await store.saveConversations(conversations);
    notifyListeners();
  }

  List<Bot> get bots => store.bots();

  Bot? get activeBot => botOf(current);

  Bot? botOf(Conversation? conv) => store.bot(conv?.botId);

  Future<void> setBot(String? id,
      {Map<String, dynamic>? model, Map<String, dynamic>? catalog}) async {
    final conv = current;
    if (conv == null) return;
    conv.botId = id;
    final botMedia = conv.mediaModel?['fromBot'] == true;
    if (id != null && model != null && model['command'] != null) {
      final known = catalog ?? mentionCatalog;
      conv.mediaModel = {
        ...mediaFor(model,
            slug: ModelMaker.of(model, known)?.slug, catalog: known),
        'fromBot': true,
      };
    } else {
      if (id == null) {
        conv.proModel = null;
      } else if (model != null) {
        conv.proModel = model;
      }
      if (botMedia) conv.mediaModel = null;
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
    await store.bury(id);
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

  static NostrEvent? newestBotEvent(
      List<NostrEvent> events, String author, String identifier) {
    NostrEvent? best;
    for (final e in events) {
      if (e.pubkey != author || e.kind != Bot.kind) continue;
      if (!e.tags.any((tag) => tag.length > 1 && tag[0] == 'd' && tag[1] == identifier)) continue;
      if (best != null && e.createdAt <= best.createdAt) continue;
      if (!schnorr.verifyEvent(e)) continue;
      best = e;
    }
    return best;
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
    final newest = newestBotEvent(events, ref.pubkey, ref.identifier);
    if (newest == null) return null;
    try {
      final json = jsonDecode(newest.content);
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
    await store.bury(id);
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
    entry.lastConvId = target.id;
    await store.saveSchedules(schedules);
    await note(t('Running “{name}”.',
        {'name': entry.title.isEmpty ? t('Untitled') : entry.title}));
    await send(entry.prompt, unattended: true);
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

  /// Puts a repo run back. Free: it touches no model and spends no credits.
  /// The token travels with the request as it always does, and never anywhere
  /// else.
  Future<Map<String, dynamic>> revertCheckpoint(ChatMessage m) async {
    final mark = m.checkpoint;
    final conv = current;
    if (mark == null || conv == null) {
      throw ChatFailure(t('There is nothing recorded to put back.'));
    }
    final repos = activeRepos;
    final repo = repos.where((r) => r.repo == mark['repo']).firstOrNull ??
        (repos.isEmpty ? null : repos.first);
    if (repo == null) {
      throw ChatFailure(t('That repository is no longer connected.'));
    }
    if (!repo.allowWrites) {
      throw ChatFailure(t('Writes are off for that repository.'));
    }
    final signer = conv.anon ? await anon.signer() : identity.signer;
    final data = await chat.revert(
        repo: repo, checkpoint: mark, signer: signer);
    final failed = (data['failed'] as List?)?.length ?? 0;
    messages = messages
        .map((x) => x.id == m.id
            ? x.copyWith(checkpoint: {...mark, 'undone': failed == 0})
            : x)
        .toList();
    await store.saveMessages(conv.id, messages);
    notifyListeners();
    return data;
  }

  Future<void> applyStaged(ChatMessage m) async {
    final staged = m.staged;
    final conv = current;
    if (staged == null || conv == null) return;
    final marks = <Map<String, dynamic>>[];
    Object? failure;
    for (final one in allStaged(staged)) {
      final repo = activeRepos.where((r) => r.repo == one['repo']).firstOrNull;
      if (repo == null) {
        failure = ChatFailure(t('That repository is no longer connected.'));
        break;
      }
      if (!repo.allowWrites) {
        failure = ChatFailure(t('Writes are off for that repository.'));
        break;
      }
      try {
        final signer = conv.anon ? await anon.signer() : identity.signer;
        final data = await chat.applyStaged(repo: repo, staged: one, signer: signer);
        final mark = data['checkpoint'];
        if (mark is Map<String, dynamic>) marks.add(mark);
      } catch (e) {
        failure = e;
        break;
      }
    }
    final mark = checkpointOfApplied(marks);
    messages = messages
        .map((x) => x.id == m.id
            ? x.copyWith(
                checkpoint: mark,
                staged: failure == null ? settledStaged(staged, 'applied') : null)
            : x)
        .toList();
    await store.saveMessages(conv.id, messages);
    notifyListeners();
    if (failure != null) throw failure;
  }

  Future<void> discardStaged(ChatMessage m) async {
    final staged = m.staged;
    final conv = current;
    if (staged == null || conv == null) return;
    messages = messages
        .map((x) => x.id == m.id
            ? x.copyWith(staged: settledStaged(staged, 'discarded'))
            : x)
        .toList();
    await store.saveMessages(conv.id, messages);
    notifyListeners();
  }

  List<Memory> get memories => store.memories();

  Future<Memory?> saveMemory(Memory entry) async {
    final saved = await store.saveMemory(entry);
    notifyListeners();
    return saved;
  }

  Future<void> deleteMemory(String id) async {
    await store.bury(id);
    await store.deleteMemory(id);
    notifyListeners();
  }

  Future<void> clearMemories() async {
    for (final m in store.memories()) {
      await store.bury(m.id);
    }
    await store.clearMemories();
    notifyListeners();
  }

  /// Reads one message for standing facts and keeps what it finds, handing
  /// back what was saved so the caller can offer to take it straight back.
  /// Nothing enters memory without the writer seeing it happen.
  Future<List<Memory>> noticeMemories(String text) async {
    if (!settings.memoryCapture) return const [];
    final found = MemoryKeeper.propose(text, current);
    if (found.isEmpty) return const [];
    final saved = <Memory>[];
    for (final proposal in found) {
      final entry = await store.saveMemory(Memory(
        id: bytesToHex(randomBytes(8)),
        text: proposal.text,
        topic: proposal.topic,
        scope: current?.workspaceId,
        source: 'chat',
      ));
      if (entry != null) saved.add(entry);
    }
    if (saved.isNotEmpty) notifyListeners();
    return saved;
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
    await store.bury(id);
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
    await store.bury(id);
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

  /// What the account already holds, asked before this device decides what
  /// post-quantum root to give it.
  ///
  /// D1 answers this, not the relays: the root row is where an account records
  /// that it HAS a root, it is written the moment one is minted, and it
  /// survives an announcement expiring. The relay announcement is the second
  /// opinion, for an account whose row predates this or whose row could not be
  /// read. [read] is false when neither source could be reached, and the caller
  /// must not read that as "there is no root".
  Future<AccountRoot> probeAccountRoot(EventSigner signer) async {
    PqRootLookup? row;
    try {
      row = await storage.pqRootRecord(signer);
    } catch (_) {
      row = null;
    }
    PqKey? announced;
    try {
      relays.connect();
      announced = await pq.resolve(signer.pubkey);
    } catch (_) {
      announced = null;
    }
    return (
      read: row != null,
      present: row?.present ?? false,
      fingerprint: row?.fingerprint,
      announced: announced?.pk,
    );
  }

  /// The same question, asked again on every launch of a device that is already
  /// signed in. A launch that could not reach the worker settles nothing, so it
  /// has to be re-asked rather than answered once: the row may have appeared
  /// since, and a root of ours that never got a row leaves every other device
  /// reading "no root".
  Future<void> settleRoot() async {
    if (!identity.present) return;
    final signer = identity.signer;
    PqRootLookup? row;
    try {
      row = await storage.pqRootRecord(signer);
    } catch (_) {
      return;
    }
    if (row == null) return;
    final held = identity.rootFingerprint;
    if (!row.present) {
      final root = identity.root;
      if (root != null) {
        try {
          await storage.publishPqRootRecord(signer, root);
        } catch (_) {}
        return;
      }
      if (identity.rootUnreadable) {
        identity.rootLocked = true;
        return;
      }
      PqKey? announced;
      try {
        relays.connect();
        announced = await pq.resolve(signer.pubkey);
      } catch (_) {
        announced = null;
      }
      if (announced != null) {
        identity.rootLocked = true;
        return;
      }
      // A sign-in that could not reach the worker left this device without a
      // root rather than minting one blind. The account turns out to have none,
      // so this is the moment to make it.
      await mintAndRecordRoot();
      await note(t('Your post-quantum recovery code is ready. Open Identity to '
          'save it — nobody can reissue it.'));
      return;
    }
    if (held.isEmpty) {
      identity.rootLocked = true;
      return;
    }
    // A row we could not read is still proof a root exists; only a root whose
    // fingerprint the record names is proof we hold THAT one.
    if (row.fingerprint == null || row.fingerprint == held) return;
    identity.rootLocked = true;
  }

  Future<RootLinkVerdict> checkRootCode(String code) async {
    final root = Identity.rootFromCode(code);
    if (root == null) return const RootLinkVerdict('invalid');
    if (!identity.present) return const RootLinkVerdict('invalid');
    if (identity.rootCode == code.trim() && !identity.rootLocked) {
      return const RootLinkVerdict('same');
    }
    final probe = await probeAccountRoot(identity.signer);
    final fingerprint = pq_crypto.pqRootFingerprint(root);
    if (probe.fingerprint != null && probe.fingerprint != fingerprint) {
      return RootLinkVerdict('mismatch', probe: probe);
    }
    var epoch = 0;
    final announced = probe.announced;
    if (announced != null) {
      final matched = _epochOfCode(code, announced);
      if (matched == null && probe.fingerprint == null) {
        return RootLinkVerdict('mismatch', probe: probe, announcedOnly: true);
      }
      if (matched != null) epoch = matched;
    }
    return RootLinkVerdict('ok', probe: probe, epoch: epoch);
  }

  int? _epochOfCode(String code, Uint8List announced) {
    for (var epoch = 0; epoch <= Identity.epochScan; epoch++) {
      final derived = Identity.kemForCode(code, epoch);
      if (derived != null && _sameBytes(derived, announced)) return epoch;
    }
    return null;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<bool> linkRootCode(String code, RootLinkVerdict verdict) async {
    if (verdict.status != 'ok') return false;
    try {
      await identity.adoptRootCode(code, epoch: verdict.epoch);
    } catch (_) {
      return false;
    }
    final probe = verdict.probe;
    if (probe == null || !probe.present || probe.fingerprint == null) {
      final root = identity.root;
      if (root != null) {
        try {
          await storage.publishPqRootRecord(identity.signer, root);
        } catch (_) {}
      }
    }
    sync.blocked = false;
    try {
      identity.rootLocked =
          await pq.announceRoot(identity.signer, identity) == null;
    } catch (_) {}
    unawaited(sync.run().then((_) => notifyListeners()));
    notifyListeners();
    return true;
  }

  Future<bool> replaceRootCode(String code) async {
    final root = Identity.rootFromCode(code);
    if (root == null || !identity.present) return false;
    try {
      await identity.adoptRootCode(code, epoch: 0);
    } catch (_) {
      return false;
    }
    identity.rootLocked = false;
    var recorded = false;
    try {
      recorded = await storage.publishPqRootRecord(identity.signer, root);
    } catch (_) {
      recorded = false;
    }
    if (!recorded) return false;
    sync.blocked = false;
    try {
      await pq.announceRoot(identity.signer, identity, force: true);
    } catch (_) {}
    unawaited(sync.run().then((_) => notifyListeners()));
    notifyListeners();
    return true;
  }

  /// Mints the root for an account that turns out not to have one, and records
  /// it, so the next device asks for the code instead of minting a rival.
  Future<String> mintAndRecordRoot({String? existing}) async {
    final String code;
    if (existing != null && Identity.rootFromCode(existing) != null) {
      await identity.adoptRootCode(existing, epoch: 0);
      code = identity.rootCode;
    } else {
      code = await identity.mintRoot();
    }
    final root = identity.root;
    if (root != null) {
      try {
        await storage.publishPqRootRecord(identity.signer, root);
      } catch (_) {}
    }
    return code;
  }

  Future<void> carryNewKey() async {
    final kem = identity.kem;
    if (!identity.present || kem == null || identity.rootLocked) return;
    try {
      pq.selfAnnouncement =
          await pq.build(identity.signer, kem, epoch: identity.epoch);
    } catch (_) {}
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
    unawaited(replyNotify.attach());

    sync.onChange = _afterSync;
    sync.follow();
    unawaited(sync.run().then((round) {
      if (round.isOk || round.state == 'blocked') notifyListeners();
    }));
    _syncTimer = Timer.periodic(
        const Duration(minutes: 5), (_) => unawaited(sync.run()));
    unawaited(refreshNotices());
    unawaited(refreshRunner());
    _noticeTimer = Timer.periodic(
        const Duration(minutes: 15), (_) => unawaited(refreshNotices()));

    // The announcement and the bot's key are what make a reply post-quantum;
    // neither blocks the first message. Held so it can be cancelled: a wipe or
    // a disposed controller must not leave network work running behind it.
    _bootWork = Timer(const Duration(milliseconds: 400), () async {
      // A published profile is what the account already tells the world;
      // showing it costs no privacy and makes the app feel signed in. The
      // mirror answers in one round trip and needs no relay, so the name and
      // avatar are drawn before anything else waits on one.
      await profiles.load(identity.pubkey, mirrorOnly: true);
      notifyListeners();
      try {
        await pq.resolveBot();
      } catch (_) {}
      try {
        await settleRoot();
      } catch (_) {}
      // A locked device holds a root that is not this account's — already
      // settled against the account's own record, which the relays cannot
      // contradict. Announcing over the real key would strand every device.
      if (identity.kem != null && !identity.rootLocked) {
        try {
          identity.rootLocked =
              await pq.announceRoot(identity.signer, identity) == null;
        } catch (_) {}
      }
      await refreshBalance();
      await resumeInvoice();
      await anon.flush(identity: identity.signer);
      startScheduler();
      await runDueSchedules();
      await autoTopUp();
      // Whatever the mirror did not have. A no-op when it did.
      await profiles.load(identity.pubkey);
      notifyListeners();
    });
  }

  void _afterSync(List<String> touched) {
    if (touched.contains('settings')) _loadSettings();
    if (touched.contains('repos')) unawaited(_loadRepos());
    if (touched.contains('connectors')) unawaited(_loadConnectors());
    if (touched.contains('favouriteModels')) {
      favouriteModels = store.favouriteModels();
    }
    if (touched.contains('schedules')) schedules = store.schedules();
    if (touched.contains('chats')) {
      conversations = store.conversations();
      final open = current;
      if (open != null) {
        for (final c in conversations) {
          if (c.id == open.id) current = c;
        }
      }
    }
    final open = current;
    if (open != null && touched.contains('chat-${open.id}')) {
      messages = store.messages(open.id);
    }
    if (open != null && touched.contains('arts-${open.id}')) {
      artifacts = store.artifacts(open.id);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    replyNotify.detach();
    _bootWork?.cancel();
    _syncTimer?.cancel();
    _noticeTimer?.cancel();
    _scheduler?.cancel();
    _invoicePoll?.cancel();
    sync.stop();
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
    replyNotify.viewingChat(conv.id);
    messages = store.messages(conv.id);
    artifacts = store.artifacts(conv.id);
    attachments = [];
    quote = null;
    notifyListeners();
  }

  List<Artifact> artifactsOf(String messageId) =>
      artifacts.where((a) => a.messageId == messageId).toList();

  Future<List<Artifact>> harvestArtifacts(ChatMessage message,
      {Conversation? conv}) async {
    if (message.role != ChatRole.bot) return const [];
    final target = conv ?? current;
    if (target == null) return const [];
    final shown = target.id == current?.id;
    var list = shown ? artifacts : store.artifacts(target.id);
    final made = <Artifact>[];
    for (final block in ArtifactHarvest.fences(message.content)) {
      if (!ArtifactHarvest.worthLifting(block.body, block.lang)) continue;
      final title = ArtifactHarvest.titleFor(block.lang, block.body);
      final at = list.indexWhere((a) => a.title == title && a.lang == block.lang);
      if (at == -1) {
        final entry = Artifact(
          id: bytesToHex(randomBytes(8)),
          title: title,
          lang: block.lang,
          body: block.body,
          messageId: message.id,
          versions: [ArtifactVersion(at: DateTime.now(), body: block.body)],
        );
        list = [...list, entry];
        made.add(entry);
      } else {
        final entry = list[at];
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
      if (shown) artifacts = list;
      await store.saveArtifacts(target.id, list);
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
    await store.bury(id);
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
      return store.searchText(c.id).contains(needle);
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

  /// The chat-scoped actions all take an optional target, because the sidebar
  /// can act on a chat without opening it first.
  Future<void> renameCurrent(String title, {Conversation? target}) async {
    final conv = target ?? current;
    if (conv == null) return;
    conv.title = title.trim();
    conv.updatedAt = DateTime.now();
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> togglePin({Conversation? target}) async {
    final conv = target ?? current;
    if (conv == null) return;
    conv.pinned = !conv.pinned;
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Future<void> toggleArchive({Conversation? target}) async {
    final conv = target ?? current;
    if (conv == null) return;
    conv.archived = !conv.archived;
    await store.saveConversations(conversations);
    // Only step off a chat you are actually looking at.
    if (conv.archived && conv.id == current?.id) {
      final live = conversations.where((c) => !c.archived).toList();
      if (live.isEmpty) {
        await newConversation();
      } else {
        await open(live.first);
      }
    }
    notifyListeners();
  }

  Future<void> deleteCurrent({Conversation? target}) async {
    final conv = target ?? current;
    if (conv == null) return;
    final wasOpen = conv.id == current?.id;
    await store.bury(conv.id);
    conversations.removeWhere((c) => c.id == conv.id);
    await store.saveConversations(conversations);
    await store.dropConversation(conv.id);
    await DocLibrary.instance.forget(conv.id);
    if (!wasOpen) {
      notifyListeners();
      return;
    }
    final live = conversations.where((c) => !c.archived).toList();
    if (live.isEmpty) {
      await newConversation();
    } else {
      await open(live.first);
    }
  }

  Future<Conversation> duplicateCurrent({Conversation? target}) async {
    final conv = target ?? current!;
    final copy = Conversation(
      id: bytesToHex(randomBytes(8)),
      rootId: bytesToHex(randomBytes(32)),
      title: '${conv.title.isEmpty ? t('New chat') : conv.title} ${t('(copy)')}',
      anon: conv.anon,
      folderId: conv.folderId,
      tags: [...conv.tags],
      repoIds: [...conv.repoIds],
      personaId: conv.personaId,
      systemPrompt: conv.systemPrompt,
      proModel: conv.proModel,
      mediaModel: conv.mediaModel,
    );
    conversations.insert(0, copy);
    await store.saveConversations(conversations);
    await store.saveMessages(copy.id, store.messages(conv.id));
    await open(copy);
    return copy;
  }

  /// A copy of this chat carrying everything up to a point, on a thread of its
  /// own, with the whole standing setup — repositories, persona, workspace,
  /// bot, model, effort — so the branch answers the way the chat it came from
  /// does. The original is untouched, which is the whole point of a branch.
  Future<Conversation> branchFrom(List<ChatMessage> kept) async {
    final conv = current!;
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
      title: '${conv.title.isEmpty ? t('New chat') : conv.title} ${t('(branch)')}',
      anon: conv.anon,
      ephemeral: conv.ephemeral,
      effort: conv.effort,
      folderId: conv.folderId,
      tags: [...conv.tags],
      repoIds: [...conv.repoIds],
      personaId: conv.personaId,
      workspaceId: conv.workspaceId,
      botId: conv.botId,
      systemPrompt: conv.systemPrompt,
      proModel: conv.proModel,
      mediaModel: conv.mediaModel,
      seed: seed,
    );
    conversations.insert(0, copy);
    await store.saveConversations(conversations);
    await store.saveMessages(copy.id, kept);
    // The files a branch was built on belong to it as much as the words that
    // produced them, and they are cheap to carry.
    final ids = kept.map((m) => m.id).toSet();
    final carried =
        artifacts.where((a) => ids.contains(a.messageId)).toList();
    if (carried.isNotEmpty) await store.saveArtifacts(copy.id, carried);
    await open(copy);
    return copy;
  }

  Future<Conversation> forkAt(ChatMessage message) async {
    final at = messages.indexWhere((m) => m.id == message.id);
    return branchFrom(messages.sublist(0, at + 1));
  }

  /// Asking the question differently, on a branch: everything before it comes
  /// along, the question itself is replaced by what was typed instead.
  Future<Conversation> branchBefore(ChatMessage message) async {
    final at = messages.indexWhere((m) => m.id == message.id);
    return branchFrom(messages.sublist(0, at < 0 ? 0 : at));
  }

  /// A fresh root id is what actually resets the model's context: the worker
  /// scopes history to the marker, so a new one is a new thread.
  ChatSnapshot _snapshot(Conversation conv) => (
        conv: conv,
        rootId: conv.rootId,
        seed: conv.seed,
        messageCount: conv.messageCount,
        creditsSpent: conv.creditsSpent,
        satsSpent: conv.satsSpent,
        messages: conv.id == current?.id
            ? [...messages]
            : store.messages(conv.id),
        thread: store.thread(conv.id),
      );

  Future<ChatSnapshot?> clearCurrent({Conversation? target}) async {
    final conv = target ?? current;
    if (conv == null) return null;
    final before = _snapshot(conv);
    conv.rootId = bytesToHex(randomBytes(32));
    conv.messageCount = 0;
    conv.creditsSpent = 0;
    conv.satsSpent = 0;
    if (conv.id == current?.id) messages = [];
    await store.saveMessages(conv.id, const []);
    await store.setThread(conv.id, const []);
    await store.saveConversations(conversations);
    notifyListeners();
    return before;
  }

  Future<void> restore(ChatSnapshot before) async {
    final conv = before.conv;
    if (!conversations.any((c) => c.id == conv.id)) return;
    conv.rootId = before.rootId;
    conv.seed = before.seed;
    conv.messageCount = before.messageCount;
    conv.creditsSpent = before.creditsSpent;
    conv.satsSpent = before.satsSpent;
    if (conv.id == current?.id) messages = [...before.messages];
    await store.saveMessages(conv.id, before.messages);
    await store.setThread(conv.id, before.thread);
    await store.saveConversations(conversations);
    notifyListeners();
  }

  void _touch(Conversation conv) {
    conv.updatedAt = DateTime.now();
    conversations.removeWhere((c) => c.id == conv.id);
    conversations.insert(0, conv);
  }

  Future<void> _add(ChatMessage m) => _addTo(current!, m);

  Future<void> _addTo(Conversation conv, ChatMessage m) async {
    if (conv.id == current?.id) {
      messages = [...messages, m];
      await store.saveMessages(conv.id, messages);
    } else {
      await store.saveMessages(conv.id, [...store.messages(conv.id), m]);
    }
    notifyListeners();
  }

  Future<void> note(String text, {Conversation? conv}) =>
      _addTo(conv ?? current!, ChatMessage(
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

  Future<void> _rethread(Conversation conv) async {
    conv.rootId = bytesToHex(randomBytes(32));
    final seed = compareSeed();
    conv.seed = seed.isEmpty ? null : seed;
    await store.setThread(conv.id, const []);
    await store.saveConversations(conversations);
  }

  Future<ChatSnapshot?> deleteMessage(ChatMessage m) async {
    final conv = current;
    if (conv == null) return null;
    final before = _snapshot(conv);
    messages = messages.where((x) => x.id != m.id).toList();
    await store.saveMessages(conv.id, messages);
    if (m.role == ChatRole.self || m.role == ChatRole.bot) {
      await _rethread(conv);
    }
    notifyListeners();
    return before;
  }

  Future<void> truncateFrom(ChatMessage m, {bool inclusive = true}) async {
    final conv = current;
    final at = messages.indexWhere((x) => x.id == m.id);
    if (conv == null || at == -1) return;
    final cut = inclusive ? at : at + 1;
    final dropped = messages.sublist(cut);
    messages = messages.sublist(0, cut);
    await store.saveMessages(conv.id, messages);
    if (dropped.any((x) => x.role == ChatRole.self || x.role == ChatRole.bot)) {
      await _rethread(conv);
    }
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
    unawaited(uploadAttachment(a));
  }

  void removeAttachment(String id) {
    DocLibrary.instance.dropPending(id);
    for (final a in attachments) {
      final url = a.url;
      if (a.id == id && url != null) unawaited(dropUpload(url));
    }
    attachments = attachments.where((a) => a.id != id).toList();
    notifyListeners();
  }

  Future<bool> dropUpload(String url) async {
    final placed = await uploads.lookup(url);
    if (placed == null) return false;
    var status = 0;
    try {
      status = await blossom.remove(
          placed.host, placed.sha256, LocalSigner(hexToBytes(placed.sk)));
    } catch (_) {
      status = 0;
    }
    await uploads.forget(url);
    return status >= 200 && status < 300;
  }

  /// A picture has to be somewhere the worker can fetch it before the model can
  /// be handed the image rather than the file's name.
  Future<void> uploadAttachment(Attachment a) async {
    if (a.kind != AttachmentKind.image) return;
    if (a.url != null || a.uploading) return;
    final raw = a.bytesBase64;
    if (raw == null || raw.isEmpty) return;
    a.uploading = true;
    a.uploadError = null;
    notifyListeners();
    try {
      final placed = await blossom.placeUnlinked(base64Decode(raw), a.mime);
      a.url = placed.url;
      try {
        await uploads.remember(placed);
      } catch (_) {}
    } catch (e) {
      a.uploadError = e is BlossomFailure ? e.message : e.toString();
    } finally {
      a.uploading = false;
      notifyListeners();
    }
  }

  /// Everything still on its way up, finished before the message goes.
  Future<List<Attachment>> settleAttachments(List<Attachment> list) async {
    await Future.wait(list.map(uploadAttachment));
    return list
        .where((a) => a.kind == AttachmentKind.image && a.url == null)
        .toList();
  }

  // --- sending -------------------------------------------------------------------

  void stop({Conversation? target}) {
    final conv = target ?? current;
    if (conv == null) return;
    // Stop means stop: a run carrying itself on must not start another leg
    // after the one being aborted, and nothing waiting behind it goes either.
    _queues.remove(conv.id);
    _queueEdits.remove(conv.id);
    final turn = turns.remove(conv.id);
    if (turn != null) {
      turn.stopped = true;
      turn.control.cancel();
      _stopWatching(turn);
      turn.status = null;
    }
    notifyListeners();
  }

  void _endTurn(ChatTurn turn) {
    if (turns[turn.conv.id] == turn) turns.remove(turn.conv.id);
    unawaited(_keepTasks(turn));
    final said = _messagesOf(turn.conv).lastWhere(
        (m) => m.role != ChatRole.note,
        orElse: () => ChatMessage(id: '', role: ChatRole.note, content: ''));
    unawaited(replyNotify.settled(turn.conv.id,
        replied: said.role == ChatRole.bot));
    turn.status = null;
    notifyListeners();
  }

  LiveTasks? liveTasks(Conversation? conv) {
    final turn = turnOf(conv);
    if (turn == null) return null;
    return (
      steps: turn.log,
      team: turn.team,
      research: turn.research != null,
      label: turn.status ?? t('Nymbot is thinking'),
    );
  }

  Future<void> _keepTasks(ChatTurn turn) async {
    if (turn.kept) return;
    turn.kept = true;
    if (turn.log.isEmpty && turn.team == null && turn.research == null) return;
    final conv = turn.conv;
    final list = _messagesOf(conv);
    final hit = Tasks.target(list, turn.began);
    if (hit == null) return;
    final rec = Tasks.record(
        (steps: turn.log, team: turn.team, research: turn.research != null, label: ''),
        turn.stopped ? 'stopped' : (hit['bot'] == true ? 'done' : 'failed'));
    if (rec == null) return;
    final next = [for (final m in list) m.id == hit['id'] ? m.copyWith(tasks: rec) : m];
    if (conv.id == current?.id) messages = next;
    notifyListeners();
    await store.saveMessages(conv.id, next);
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

    final caps = List<double?>.filled(models.length, null);
    if (SpendCaps.any(conv, botOf(conv))) {
      final ests = [
        for (final model in models)
          ChatEngine.estimate(body, model,
              conv: conv,
              hasRepos: reposOf(conv).isNotEmpty,
              pricing: catalogPricing),
      ];
      final pro = ests.any((e) => e.tier == 'pro');
      final sats = ests.fold<double>(
          0, (n, e) => n + SpendCaps.satsFor(e.high, e.tier == 'pro'));
      final gate = await _capGate(conv, pro, sats / SpendCaps.rate(pro));
      if (gate != 'send' && gate != 'ok') return const [];
      if (gate == 'ok') {
        for (var i = 0; i < models.length; i++) {
          caps[i] = SpendCaps.maxCost(
              conv, botOf(conv), _messagesOf(conv),
              pro: ests[i].tier == 'pro', share: models.length);
        }
      }
    }

    final turn = ChatTurn(conv);
    turns[conv.id] = turn;
    notifyListeners();

    final seed = compareSeed();
    final scoped = activeRepos;
    final persona = activePersona;
    final space = activeWorkspace;
    final bot = activeBot;

    Future<CompareRun> once(Map<String, dynamic> model, double? maxCost) async {
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
          maxCost: maxCost,
          proModel: model,
          repos: scoped,
          persona: persona,
          workspace: space,
          bot: bot,
          memories: store.memories(),
          webSearch: settings.webSearch,
          firstTurn: true,
          // Neither run touches the conversation's stored thread: the seed
          // carries what was said, and the real chat is untouched until one of
          fresh: true,
          onThreadIds: (_) {},
          control: turn.control,
        );
        return CompareRun(
          model: model,
          reply: res.reply,
          thinking: res.thinking,
          cost: res.cost,
          sources: res.sources,
          followUps: res.followUps,
        );
      } on ChatFailure catch (e) {
        return CompareRun(model: model, error: e.message);
      } catch (e) {
        return CompareRun(model: model, error: e.toString());
      }
    }

    final out = await Future.wait(
        [for (var i = 0; i < models.length; i++) once(models[i], caps[i])]);
    _endTurn(turn);

    final spent = out.fold<double>(0, (n, r) => n + r.cost);
    if (spent > 0) await store.recordUsage(spent);
    if (spent > 0) {
      _bumpSpent(conv, spent, true);
      await store.saveConversations(conversations);
    }
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
      pro: true,
      model: run.label,
      modelKey: _maker(run.model)?.key,
      modelMaker: _maker(run.model)?.slug,
      modelMakerName: _maker(run.model)?.name,
      sources: run.sources,
      followUps: run.followUps,
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

  /// What was typed while a reply was still being written, in the order it was
  /// typed. Held rather than dropped: typing mid-reply used to do nothing at
  /// all, with no sign the message had gone anywhere.
  void unqueue(int at, {Conversation? target}) {
    final conv = target ?? current;
    final queue = conv == null ? null : _queues[conv.id];
    if (queue == null || at < 0 || at >= queue.length) return;
    queue.removeAt(at);
    final editing = _queueEdits[conv!.id];
    if (editing != null) {
      if (editing == at) {
        _queueEdits.remove(conv.id);
      } else if (editing > at) {
        _queueEdits[conv.id] = editing - 1;
      }
    }
    if (queue.isEmpty) _queues.remove(conv.id);
    notifyListeners();
  }

  /// Sends the next thing that was waiting. One at a time: they were typed as
  /// a conversation, so they have to arrive as one.
  Future<void> _sendQueued(Conversation conv) async {
    final queue = _queues[conv.id];
    if (queue == null || queue.isEmpty || turns.containsKey(conv.id)) return;
    final editing = _queueEdits[conv.id];
    if (editing == 0) return;
    final next = queue.removeAt(0);
    if (editing != null) _queueEdits[conv.id] = editing - 1;
    if (queue.isEmpty) _queues.remove(conv.id);
    notifyListeners();
    await send(next, target: conv);
  }

  /// Returns false when the message was held for later rather than sent, so a
  /// caller does not go on to read out a reply that has not happened yet.
  Future<bool> send(String text,
      {Conversation? target, bool bare = false, bool unattended = false}) async {
    final conv = target ?? current;
    if (conv == null || text.trim().isEmpty) return false;
    if (turns.containsKey(conv.id)) {
      if (bare) return false;
      (_queues[conv.id] ??= []).add(text.trim());
      notifyListeners();
      return false;
    }
    // The free allowance, as this device sees it. The worker counts per key,
    // and making another key is a tap in this app's own gate — so the device
    // keeps a count of its own and stops offering free replies once it is
    // spent, whichever key is signed in. A speed bump, never reported to the
    // worker: see AppController.freeAllows.
    final typed = text.trim();
    MentionResult? mention;
    final head = bare ? null : Mentions.parse(typed);
    if (head != null) {
      final catalog = await ensureMentionCatalog();
      mention = catalog == null
          ? MentionResult(unknown: head.name, text: typed)
          : Mentions.apply(typed, catalog);
      if (mention != null && mention.resolved && mention.text.isEmpty) {
        await note(t('Say what to ask {name} after the mention.',
            {'name': mention.model!['label']}), conv: conv);
        if (conv.id == current?.id) _capReturned = typed;
        return false;
      }
      final wallet = conv.anon && anon.ready ? anonProBalance : proBalance;
      if (mention != null && mention.resolved && wallet != null && wallet <= 0) {
        await note(t('@{name} answers from your Pro balance, which is empty. Type ?buy to top up, then send it again.',
            {'name': mention.model!['key']}), conv: conv);
        if (conv.id == current?.id) _capReturned = typed;
        return false;
      }
    }
    final asked = mention != null && mention.resolved ? Mentions.pinned(mention.model!) : null;
    if (asked == null && !freeAllows) {
      await note(freeSpentMessage(), conv: conv);
      return false;
    }
    final research = bare
        ? null
        : Research.claim(asked != null ? mention!.text : typed,
            armed: researchNext,
            model: asked ?? modelOf(conv),
            pricing: catalogPricing);
    if (research != null && researchNext) {
      researchNext = false;
      notifyListeners();
    }
    if (research?.blocked != null) {
      await note(research!.blocked!, conv: conv);
      return false;
    }
    final team = bare
        ? null
        : Team.claim(conv.team,
            lead: asked ?? teamLeadOf(conv),
            research: research != null,
            repos: reposOf(conv).isNotEmpty);
    final body = research != null
        ? research.question
        : asked != null
            ? mention!.text
        : (bare ? typed : withMediaModel(typed, conv: conv));
    final composing = !bare && conv.id == current?.id;
    final sent = composing ? [...attachments] : <Attachment>[];
    final quoted = composing ? quote : null;

    // A picture has to be uploaded before the message goes, since it is the link
    // that travels and the link the model is handed.
    if (sent.any((a) => a.kind == AttachmentKind.image && a.url == null)) {
      final stranded = await settleAttachments(sent);
      if (stranded.isNotEmpty) {
        await note(
            stranded.length == 1
                ? t('{name} could not be uploaded, so Nymbot will not be able to see it.',
                    {'name': stranded.first.name})
                : t('{names} could not be uploaded, so Nymbot will not be able to see them.',
                    {'names': stranded.map((a) => a.name).join(', ')}),
            conv: conv);
      }
    }

    double? maxCost;
    if (SpendCaps.any(conv, botOf(conv))) {
      final waived = _capWaive == conv.id;
      _capWaive = null;
      var est = _capEstimate(conv, body, model: asked);
      if (!waived) {
        if (team != null) {
          final priced = await teamEstimate(conv,
              workers: team['workers'] as int,
              model: team['model'] as String,
              mode: team['mode'] as String,
              lead: asked);
          if (priced.error == null) {
            est = (
              tier: 'pro',
              low: priced.typical,
              high: priced.max.toDouble(),
              metered: true
            );
          }
        }
        final gate = await _capGate(conv, est.tier == 'pro', est.high,
            unattended: unattended);
        if (gate != 'send' && gate != 'ok') {
          if (composing) _capReturned = typed;
          return false;
        }
        if (gate == 'ok') {
          maxCost = SpendCaps.maxCost(conv, botOf(conv), _messagesOf(conv),
              pro: est.tier == 'pro');
        }
      }
    }

    if (composing) {
      attachments = [];
      quote = null;
    }

    final selfId = bytesToHex(randomBytes(8));
    final docsUsed = DocLibrary.instance.usageFor(conv.id, body, sent);
    final mine = ChatMessage(
      id: selfId,
      role: ChatRole.self,
      content: typed,
      attachments: sent,
      quote: quoted,
    );
    await _addTo(conv, mine);
    unawaited(DocLibrary.instance.recordUsage(selfId, docsUsed));
    unawaited(DocLibrary.instance.keep(conv.id, sent));

    if (conv.title.isEmpty) {
      conv.title = ChatEngine.titleFor(typed);
      _touch(conv);
      await store.saveConversations(conversations);
    }
    if (mention?.unknown != null) {
      await note(t('No model called @{name}, so that went as an ordinary message. Type @ to pick one.',
          {'name': mention!.unknown}), conv: conv);
    }

    final turn = ChatTurn(conv);
    turn.research = research?.payload;
    turn.team = team;
    turns[conv.id] = turn;
    notifyListeners();
    turn.control.onStatus = (s) {
      turn.status = s;
      notifyListeners();
    };

    final scoped = reposOf(conv);
    final model = asked ?? modelOf(conv);
    TurnResult? carry;
    var resendWaived = false;
    try {
      final res = await chat.send(
        conv: conv,
        text: body,
        maxCost: maxCost,
        proModel: asked ?? proModelForTurnOf(conv),
        repos: scoped,
        connectors: connectorsOf(conv),
        serverRuns: serverRunsOf(conv),
        persona: personaOf(conv),
        workspace: workspaceOf(conv),
        bot: botOf(conv),
        memories: store.memories(),
        attachments: sent,
        quote: quoted,
        webSearch: settings.webSearch,
        firstTurn: store.thread(conv.id).isEmpty,
        research: research?.payload,
        team: team,
        onTurn: (eventId) => _watchTurn(turn, eventId),
        onStep: (step) => _localStep(turn, step),
        onThreadIds: (ids) {
          final thread = [...store.thread(conv.id), ...ids];
          unawaited(store.setThread(conv.id, thread));
        },
        control: turn.control,
      );
      _stopWatching(turn, keepDraft: true);
      final reply = ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.bot,
        content: res.reply,
        thinking: res.thinking,
        cost: res.cost,
        pro: res.pro,
        model: res.pro ? (model?['label'] as String?) : null,
        modelKey: res.pro ? _maker(model)?.key : null,
        modelMaker: res.pro ? _maker(model)?.slug : null,
        modelMakerName: res.pro ? _maker(model)?.name : null,
        calls: res.modelCalls,
        // What it changed in a repository, and where the branch stood before
        // it did — so the run can be put back.
        checkpoint: res.checkpoint,
        pendingTool: res.pendingTool,
        staged: res.staged,
        repos: res.repos.length > 1 ? res.repos : const [],
        sources: res.sources,
        followUps: res.followUps,
        serverRunCredits: res.serverRunCredits,
        serverRuns: res.serverRuns,
        team: Team.normalize(res.team),
      );
      if (turn.drafted) streamedReplies.add(reply.id);
      turn.draft = null;
      await _addTo(conv, reply);
      await harvestArtifacts(reply, conv: conv);
      if (conv.seed != null) conv.seed = null;
      _bumpSpent(conv, res.cost + res.serverRunCredits, res.pro);
      conv.messageCount += 1;
      conv.creditsSpent += res.cost + res.serverRunCredits;
      _touch(conv);
      await store.saveConversations(conversations);
      await store.recordUsage(res.cost);
      if (res.free != null) {
        // Counted on this device as well as on the key, so a fresh key does
        // not start the day over.
        free = res.free;
        await store.freeTier.spent();
        await store.freeTier.observe(res.free!.used);
      }
      _creditBalance(res.pro, res.balance, anonKey: conv.anon && anon.ready);
      if (conv.anon && anon.ready && anonStandardBalance == null) {
        unawaited(refreshBalance());
      }
      if (res.lowBalance) {
        // In an anonymous chat a low balance is usually the throwaway key
        // running dry rather than the nym, which is what the automatic
        // transfer is for.
        final topped = conv.anon ? await autoTopUp() : null;
        if (topped != null) {
          await note(describeTopUp(topped), conv: conv);
        } else {
          await note(
              res.pro
                  ? t('Pro credits running low: {n} left. Tap Buy to top up.',
                      {'n': res.balance})
                  : t('Credits running low: {n} left. Tap Buy to top up.',
                      {'n': res.balance}),
              conv: conv);
        }
      }
      if (res.truncated) carry = res;
    } on ChatFailure catch (e) {
      if (e.cancelled) {
        await note(t('Stopped. That reply was not charged for unless it had already finished.'),
            conv: conv);
      } else if (e.capExceeded) {
        await _dropMessage(conv, mine);
        if (unattended || onCapPrompt == null) {
          await note(t('Not sent: this reply could go past the chat\'s spending cap, and nobody was here to agree to it.'),
              conv: conv);
        } else {
          final choice = await onCapPrompt!(
              SpendCaps.refusal(e.required, e.pro, team: e.team));
          if (choice == 'send') {
            resendWaived = true;
          } else if (composing) {
            _capReturned = typed;
          }
          if (composing) {
            attachments = sent;
            quote = quoted;
          }
        }
      } else if (e.team && !e.noCredits) {
        await _dropMessage(conv, mine);
        await note(Team.refusal(e), conv: conv);
        if (composing) {
          _capReturned = typed;
          attachments = sent;
          quote = quoted;
        }
      } else if (e.noCredits) {
        _creditBalance(e.pro, e.balance, anonKey: conv.anon && anon.ready);
        // The worker says the day is spent. Believe it over the device's own
        // count, which can only ever be behind.
        if (e.free != null) {
          free = e.free;
          await store.freeTier.observe(e.free!.used);
        }
        if (e.free != null && !e.pro) {
          // The allowance ran out, not a balance: that is a time, not a wall,
          // and there is nothing to top up from.
          await note(freeSpentMessage(), conv: conv);
        } else {
          final topped = conv.anon ? await autoTopUp(force: true) : null;
          if (topped != null) {
            await note('${describeTopUp(topped)} '
                '${t('Send that again when you are ready.')}', conv: conv);
          } else {
            await note(e.team ? Team.refusal(e) : e.message, conv: conv);
          }
        }
      } else {
        await _addTo(conv, ChatMessage(
          id: bytesToHex(randomBytes(8)),
          role: ChatRole.error,
          content: e.message,
          retry: typed,
        ));
      }
    } catch (e) {
      await _addTo(conv, ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.error,
        content: t('Something went wrong sending that message.'),
        retry: typed,
      ));
    } finally {
      _stopWatching(turn);
      turn.status = null;
      notifyListeners();
    }
    if (carry != null && !turn.stopped) await _carryOn(turn, carry, asked: asked);
    _endTurn(turn);
    if (resendWaived) {
      _capWaive = conv.id;
      return send(typed, target: conv, bare: bare);
    }
    await _sendQueued(conv);
    return true;
  }

  List<ChatMessage> _messagesOf(Conversation conv) =>
      conv.id == current?.id ? messages : store.messages(conv.id);

  CostEstimate _capEstimate(Conversation conv, String body,
      {Map<String, dynamic>? model}) {
    if (model == null && conv.id == current?.id) return estimate(body);
    return ChatEngine.estimate(body, model ?? modelOf(conv),
        conv: conv,
        hasRepos: reposOf(conv).isNotEmpty,
        pricing: catalogPricing);
  }

  void _bumpSpent(Conversation conv, double cost, bool pro) {
    conv.satsSpent = SpendCaps.nextSpent(conv, _messagesOf(conv), cost, pro);
  }

  Future<void> _dropMessage(Conversation conv, ChatMessage m) async {
    if (conv.id == current?.id) {
      messages = messages.where((x) => x.id != m.id).toList();
      await store.saveMessages(conv.id, messages);
    } else {
      await store.saveMessages(conv.id,
          store.messages(conv.id).where((x) => x.id != m.id).toList());
    }
    notifyListeners();
  }

  Future<String> _capGate(Conversation conv, bool pro, double high,
      {bool unattended = false}) async {
    final check = SpendCaps.check(conv, botOf(conv), _messagesOf(conv),
        pro: pro, high: high);
    if (check.state == 'ok') return 'ok';
    if (unattended || onCapPrompt == null) {
      await note(
          check.state == 'block'
              ? t('Not sent: this chat has reached its spending cap.')
              : t('Not sent: this reply could go past the chat\'s spending cap, and nobody was here to agree to it.'),
          conv: conv);
      return 'cancel';
    }
    final choice = await onCapPrompt!(SpendCaps.prompt(check, credits: high));
    return check.state == 'block' && choice == 'send' ? 'cancel' : choice;
  }

  String? takeCapReturned() {
    final back = _capReturned;
    _capReturned = null;
    return back;
  }

  CapLimits capLimitsOf(Conversation conv) =>
      SpendCaps.limits(conv, botOf(conv));

  double capSpentOf(Conversation conv) =>
      SpendCaps.spent(conv, _messagesOf(conv));

  String capUsedLineOf(Conversation conv) =>
      SpendCaps.usedLine(conv, botOf(conv), _messagesOf(conv));

  String get capRoomLine {
    final conv = current;
    return conv == null
        ? ''
        : SpendCaps.roomLine(conv, botOf(conv), _messagesOf(conv));
  }

  Future<void> setCaps(Conversation conv, {int? total, int? perReply}) async {
    conv.capSats = SpendCaps.positive(total);
    conv.askAboveSats = SpendCaps.positive(perReply);
    _touch(conv);
    await store.saveConversations(conversations);
    notifyListeners();
  }

  static const _legGapMs = 3500;
  static const _legGapJitterMs = 1500;
  static const _legStallWaits = [
    Duration(seconds: 8),
    Duration(seconds: 20),
    Duration(seconds: 45),
  ];
  final _rng = math.Random();

  Future<void> _legPause(ChatTurn turn, Duration total) async {
    final until = DateTime.now().add(total);
    while (!turn.stopped) {
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) break;
      await Future<void>.delayed(
          left > const Duration(milliseconds: 250)
              ? const Duration(milliseconds: 250)
              : left);
    }
  }

  /// A repo run stopped at its tool-call cap with work left. Spend the budget
  /// the user set on carrying it on, one leg at a time, saying what each leg
  /// cost as it goes — never silently.
  Future<void> _carryOn(ChatTurn turn, TurnResult first,
      {Map<String, dynamic>? asked}) {
    final conv = turn.conv;
    final research = turn.research;
    final model = asked ?? modelOf(conv);
    return _carryOnWith(
        turn,
        first,
        (token) => chat.send(
              conv: conv,
              text: t('Continue.'),
              maxCost: SpendCaps.maxCost(conv, botOf(conv), _messagesOf(conv),
                  pro: true),
              proModel: model,
              repos: reposOf(conv),
              connectors: connectorsOf(conv),
              serverRuns: serverRunsOf(conv),
              persona: personaOf(conv),
              workspace: workspaceOf(conv),
              bot: botOf(conv),
              memories: store.memories(),
              webSearch: settings.webSearch,
              firstTurn: false,
              resume: token,
              research: research,
              onTurn: (eventId) => _watchTurn(turn, eventId),
              onStep: (step) => _localStep(turn, step),
              onThreadIds: (ids) {
                final thread = [...store.thread(conv.id), ...ids];
                unawaited(store.setThread(conv.id, thread));
              },
              control: turn.control,
            ),
        model: model);
  }

  @visibleForTesting
  Future<void> carryOnWithForTest(ChatTurn turn, TurnResult first,
          Future<TurnResult> Function(String token) leg) =>
      _carryOnWith(turn, first, leg);

  Future<void> _stallPause(ChatTurn turn, Duration wait, int attempt) async {
    final until = DateTime.now().add(wait);
    while (!turn.stopped) {
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) break;
      turn.status = stallLine(left, attempt);
      notifyListeners();
      await Future<void>.delayed(
          left > const Duration(milliseconds: 250)
              ? const Duration(milliseconds: 250)
              : left);
    }
    turn.status = null;
    notifyListeners();
  }

  Future<void> _carryOnWith(ChatTurn turn, TurnResult first,
      Future<TurnResult> Function(String token) leg,
      {Map<String, dynamic>? model}) async {
    final conv = turn.conv;
    final research = turn.research;
    var token = first.resumeToken;
    var reserve = first.nextReserve;
    var stall = stallWait(
        stalled: first.stalled,
        truncated: first.truncated,
        resumeToken: first.resumeToken,
        retryAfterMs: first.retryAfterMs);
    var stallResumes = 0;
    if ((token == null || token.isEmpty) && first.capStopped) {
      await note(t('That answer stopped early to stay inside this chat\'s spending cap.'),
          conv: conv);
      return;
    }
    if (token == null || token.isEmpty) {
      await note(t('That answer stopped early and could not be resumed. Ask again to pick it up.'),
          conv: conv);
      return;
    }
    var left = research != null
        ? double.infinity
        : continueBudgetAfter(turn.continuedSpend);
    if (stall == null && left <= 0) {
      await note(t('That answer stopped early — the task needs more steps than one '
          'turn holds. Set “When a repo task runs out of room” in Settings and '
          'Nymbot will carry on by itself.'), conv: conv);
      return;
    }
    if (stall == null && reserve > left) {
      await note(t('That answer stopped early. Carrying on reserves {n} more credits than the budget left.',
          {'n': reserve - left}), conv: conv);
      return;
    }

    final answered = model ?? modelOf(conv);
    var legs = 0;
    var stalls = 0;
    while (token != null &&
        token.isNotEmpty &&
        !turn.stopped &&
        (stall != null ? stallResumes < maxStallResumes : left > 0)) {
      if (stall != null) {
        stallResumes++;
        legs = 1;
        await _stallPause(turn, stall, stallResumes);
        if (turn.stopped) break;
      } else if (legs++ > 0) {
        final gap = _legGapMs + _rng.nextInt(_legGapJitterMs);
        turn.status = t('Pausing a moment so the next step does not crowd the last');
        notifyListeners();
        await _legPause(turn, Duration(milliseconds: gap));
        if (turn.stopped) break;
      }
      if (SpendCaps.any(conv, botOf(conv)) &&
          SpendCaps.check(conv, botOf(conv), _messagesOf(conv),
                      pro: true, high: 0)
                  .state ==
              'block') {
        await note(t('Stopped: this chat has reached its spending cap.'),
            conv: conv);
        return;
      }
      turn.status = t('Carrying on where it left off');
      notifyListeners();
      TurnResult next;
      try {
        next = await leg(token);
      } on ChatFailure catch (e) {
        _stopWatching(turn);
        turn.status = null;
        final again = e.resumeToken;
        if (stall != null &&
            again != null &&
            again.isNotEmpty &&
            !turn.stopped &&
            stallResumes < maxStallResumes) {
          token = again;
          continue;
        }
        if (again != null &&
            again.isNotEmpty &&
            stalls < _legStallWaits.length &&
            !turn.stopped) {
          final wait = _legStallWaits[stalls++];
          token = again;
          legs = 0;
          await note(t('That step could not go out — the gateway is busy. '
              'Nothing is lost; trying again in {n} seconds.',
              {'n': wait.inSeconds}), conv: conv);
          await _legPause(turn, wait);
          continue;
        }
        if (again != null && again.isNotEmpty) {
          await note(t('Stopped there — the gateway stayed busy. The work so '
              'far is saved, so ask it to carry on later.'), conv: conv);
          return;
        }
        if (e.capExceeded) {
          await note(t('Stopped: carrying on could go past this chat\'s spending cap.'),
              conv: conv);
          return;
        }
        await note(e.message, conv: conv);
        return;
      } catch (_) {
        _stopWatching(turn);
        turn.status = null;
        await note(t('Could not carry on from there.'), conv: conv);
        return;
      }
      stalls = 0;
      _stopWatching(turn);
      turn.status = null;

      final more = ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.bot,
        content: next.reply,
        thinking: next.thinking,
        cost: next.cost,
        pro: next.pro,
        model: next.pro ? (answered?['label'] as String?) : null,
        modelKey: next.pro ? _maker(answered)?.key : null,
        modelMaker: next.pro ? _maker(answered)?.slug : null,
        modelMakerName: next.pro ? _maker(answered)?.name : null,
        calls: next.modelCalls,
        pendingTool: next.pendingTool,
        checkpoint: next.checkpoint,
        staged: next.staged,
        sources: next.sources,
        followUps: next.followUps,
        serverRunCredits: next.serverRunCredits,
        serverRuns: next.serverRuns,
        team: Team.normalize(next.team),
      );
      await _addTo(conv, more);
      await harvestArtifacts(more, conv: conv);
      _bumpSpent(conv, next.cost + next.serverRunCredits, next.pro);
      conv.messageCount += 1;
      conv.creditsSpent += next.cost + next.serverRunCredits;
      _touch(conv);
      await store.saveConversations(conversations);
      await store.recordUsage(next.cost);
      turn.continuedSpend += next.cost;
      _creditBalance(next.pro, next.balance,
          anonKey: conv.anon && anon.ready);

      left = research != null
          ? double.infinity
          : continueBudgetAfter(turn.continuedSpend);
      token = next.truncated ? next.resumeToken : null;
      reserve = next.nextReserve;
      stall = stallWait(
          stalled: next.stalled,
          truncated: next.truncated,
          resumeToken: next.resumeToken,
          retryAfterMs: next.retryAfterMs);
      if (stall != null) continue;

      if (token != null &&
          token.isNotEmpty &&
          research == null &&
          settings.autoContinue == 0) {
        await note(t('That answer stopped early — the task needs more steps than one '
            'turn holds. Set “When a repo task runs out of room” in Settings and '
            'Nymbot will carry on by itself.'), conv: conv);
        return;
      }
      if (token != null && token.isNotEmpty && reserve > left) {
        await note(t('Stopped: carrying on again needs {n} credits and {left} are left in the budget.',
            {'n': reserve, 'left': left}), conv: conv);
        return;
      }
      if (token != null && token.isNotEmpty && left <= 0) {
        await note(t('Budget spent — {n} credits on carrying that on. Raise it in Settings to go further.',
            {'n': turn.continuedSpend}), conv: conv);
        return;
      }
    }
    if (token != null && token.isNotEmpty && stall != null && !turn.stopped) {
      await note(t('Stopped there — the gateway stayed busy. The work so '
          'far is saved, so ask it to carry on later.'), conv: conv);
      return;
    }
    if (turn.continuedSpend > 0 && (token == null || token.isEmpty)) {
      await note(t('Finished. Carrying on cost {n} extra credits.', {'n': turn.continuedSpend}),
          conv: conv);
    }
  }

  // --- balances --------------------------------------------------------------------

  @visibleForTesting
  void creditBalanceForTest(bool pro, double? value, {required bool anonKey}) =>
      _creditBalance(pro, value, anonKey: anonKey);

  void _creditBalance(bool pro, double? value, {required bool anonKey}) {
    if (value == null) return;
    if (anonKey) {
      if (pro) {
        anonProBalance = value;
      } else {
        anonStandardBalance = value;
      }
      return;
    }
    if (pro) {
      proBalance = value;
    } else {
      standardBalance = value;
    }
  }

  static const _invoiceKey = 'pendingInvoice';

  PendingInvoice? invoice;
  String? invoiceStatus;
  bool invoiceWarn = false;
  bool invoiceBusy = false;
  bool _claiming = false;
  Timer? _invoicePoll;

  Future<EventSigner> _invoiceSigner(PendingInvoice inv) async =>
      inv.anon ? await anon.signer() : identity.signer;

  void _invoiceSay(String? text, {bool warn = false}) {
    invoiceStatus = text;
    invoiceWarn = warn;
    notifyListeners();
  }

  Future<void> _keepInvoice(PendingInvoice? inv) async {
    invoice = inv;
    if (inv == null) {
      _invoicePoll?.cancel();
      _invoicePoll = null;
      await store.remove(_invoiceKey);
    } else {
      await store.setString(_invoiceKey, inv.encode());
    }
  }

  Future<bool> createInvoice(int credits, String tier) async {
    if (invoiceBusy) return false;
    if (credits <= 0) {
      _invoiceSay(t('Enter how many credits to buy.'), warn: true);
      return false;
    }
    final sats = credits * (NymbotConfig.satsPerCredit[tier] ?? 10);
    invoiceBusy = true;
    _invoiceSay(t('Creating an invoice…'));
    final useAnon = (current?.anon ?? false) && anon.ready;
    final signer = useAnon ? await anon.signer() : identity.signer;
    ApiResult res;
    try {
      res = await api.createInvoice(signer, amountSats: sats, tier: tier);
    } finally {
      invoiceBusy = false;
    }
    final pr = res.data['pr'];
    final id = res.data['invoiceId'];
    if (pr is! String || pr.isEmpty || id is! String || id.isEmpty) {
      _invoiceSay(
          (res.data['error'] as String?) ?? t('Could not create an invoice.'),
          warn: true);
      return false;
    }
    await _keepInvoice(PendingInvoice(
      id: id,
      pr: pr,
      tier: tier,
      anon: useAnon,
      credits: credits,
      sats: sats,
    ));
    _invoiceSay(t('Pay {sats} sats. This updates the moment it settles.',
        {'sats': figure(sats)}));
    _pollInvoice();
    return true;
  }

  void _pollInvoice() {
    _invoicePoll?.cancel();
    final inv = invoice;
    if (inv == null) return;
    var ticks = 0;
    _invoicePoll = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (invoice != inv) {
        timer.cancel();
        return;
      }
      if (++ticks > 60) {
        timer.cancel();
        if (_invoicePoll == timer) _invoicePoll = null;
        _invoiceSay(
            inv.paid
                ? t('Your payment arrived but the credits are not added yet. '
                    'Tap Add my credits to try again.')
                : t('Still waiting on this payment. If you have paid, tap '
                    'I\u2019ve paid — otherwise create a new invoice.'),
            warn: true);
        return;
      }
      if (invoiceBusy || _claiming) return;
      await checkInvoice();
      if (invoice != inv) timer.cancel();
    });
  }

  Future<void> checkInvoice({bool manual = false}) async {
    final inv = invoice;
    if (inv == null || _claiming || (manual && invoiceBusy)) return;
    if (!inv.paid) {
      if (manual) {
        invoiceBusy = true;
        _invoiceSay(t('Checking your payment…'));
      }
      ApiResult check;
      try {
        check = await api.checkInvoice(await _invoiceSigner(inv), inv.id);
      } finally {
        if (manual) invoiceBusy = false;
      }
      if (invoice != inv) return;
      if (check.data['paid'] != true) {
        if (inv.stale) {
          await _keepInvoice(null);
          _invoiceSay(null);
          return;
        }
        if (manual) {
          _invoiceSay(
              (check.data['error'] as String?) ??
                  t('Not paid yet. Finish paying in your wallet, then tap it '
                      'again.'),
              warn: true);
        }
        return;
      }
      inv.paid = true;
      await _keepInvoice(inv);
    }
    await _claimInvoice(inv);
  }

  Future<void> _claimInvoice(PendingInvoice inv) async {
    if (_claiming || invoice != inv) return;
    _claiming = true;
    invoiceBusy = true;
    _invoiceSay(t('Adding your credits…'));
    try {
      final claim =
          await api.claimCredits(await _invoiceSigner(inv), inv.id);
      final error = claim.data['error'] as String?;
      if (error == null) {
        await _keepInvoice(null);
        _invoiceSay(t('Credited. Balance: {balance}.',
            {'balance': figure(claim.data['balance'])}));
        await refreshBalance();
      } else if (error.toLowerCase().contains('already claimed')) {
        await _keepInvoice(null);
        _invoiceSay(t('That payment was already credited. Create a new '
            'invoice to buy more.'));
      } else {
        _invoiceSay(error, warn: true);
      }
    } catch (_) {
      _invoiceSay(t('Your payment could not be credited yet.'), warn: true);
    } finally {
      _claiming = false;
      invoiceBusy = false;
      notifyListeners();
    }
  }

  Future<void> resumeInvoice() async {
    final inv = invoice;
    if (inv == null) return;
    if (inv.stale) {
      await _keepInvoice(null);
      notifyListeners();
      return;
    }
    await checkInvoice();
    if (invoice == inv && _invoicePoll == null && !inv.paid) _pollInvoice();
  }

  Future<int> importBackup(Object? payload, {required bool merge}) async {
    final count = await Backup.restore(store, payload, merge: merge);
    conversations = store.conversations();
    schedules = store.schedules();
    final live = conversations.where((c) => !c.archived).toList();
    if (live.isEmpty) {
      await newConversation();
    } else {
      await open(live.first);
    }
    notifyListeners();
    return count;
  }

  Future<void> resumed() async {
    if (!signedIn || identity.pubkey.isEmpty) return;
    if (_entered) relays.wake();
    await refreshNotices();
    await refreshBalance();
    await resumeInvoice();
    if (_entered) await runDueSchedules();
  }

  Future<void> dropInvoice() async {
    await _keepInvoice(null);
    _invoiceSay(null);
  }

  Map<String, int> giftMinimum = Map.of(Gifts.minimum);
  int giftTtlDays = 30;

  Future<Map<String, String>> giftCodes() async =>
      Gifts.keptFrom(await store.secret(Gifts.keptKey));

  String _giftError(ApiResult res, String fallback) {
    final said = res.data['error'];
    return said is String && said.isNotEmpty ? said : fallback;
  }

  Future<({GiftRecord? gift, String? error})> makeGift(
      {required String tier, required int amount, required String code}) async {
    final res = await api.giftCreate(identity.signer,
        tier: tier, amount: amount, code: code);
    final gift = GiftRecord.fromJson(res.data['gift']);
    if (res.status != 200 || res.data['ok'] != true || gift == null) {
      return (
        gift: null,
        error: _giftError(res, t('The gift could not be made. Nothing left your balance.')),
      );
    }
    await store.setSecret(Gifts.keptKey, Gifts.keptWith(await giftCodes(), gift.id, code));
    await refreshBalance();
    return (gift: gift, error: null);
  }

  Future<List<GiftRecord>?> listGifts() async {
    final res = await api.giftList(identity.signer);
    final list = res.data['gifts'];
    if (res.status != 200 || list is! List) return null;
    final min = res.data['min'];
    if (min is Map) {
      giftMinimum = {
        for (final tier in const ['standard', 'pro'])
          tier: (min[tier] as num?)?.toInt() ?? Gifts.minimum[tier]!,
      };
    }
    final days = (res.data['ttlDays'] as num?)?.toInt() ?? 0;
    if (days > 0) giftTtlDays = days;
    return list.map(GiftRecord.fromJson).whereType<GiftRecord>().toList();
  }

  Future<({bool ok, String message})> cancelGift(GiftRecord g) async {
    final res = await api.giftCancel(identity.signer, g.id);
    if (res.status != 200 || res.data['ok'] != true) {
      return (ok: false, message: _giftError(res, t('The gift could not be canceled.')));
    }
    await refreshBalance();
    final back = (res.data['refunded'] as num?)?.toInt() ?? 0;
    return (
      ok: true,
      message: back > 0
          ? t('Canceled. {what} are back on your balance.',
              {'what': Gifts.credits(res.data['tier'] == 'pro' ? 'pro' : 'standard', back)})
          : t('That gift was already closed.'),
    );
  }

  Future<({GiftRecord? gift, String? error})> peekGift(String code) async {
    final res = await api.giftPeek(identity.signer, code);
    final gift = GiftRecord.fromJson(res.data['gift']);
    if (res.status != 200 || gift == null) {
      return (gift: null, error: _giftError(res, t('That gift could not be looked up.')));
    }
    return (gift: gift, error: null);
  }

  Future<({bool ok, String message})> redeemGift(String code) async {
    final res = await api.giftRedeem(identity.signer, code);
    if (res.status != 200 || res.data['ok'] != true) {
      return (ok: false, message: _giftError(res, t('The gift could not be claimed.')));
    }
    await refreshBalance();
    final got = (res.data['credited'] as num?)?.toInt() ?? 0;
    return (
      ok: true,
      message: t('Added {what} to your balance.',
          {'what': Gifts.credits(res.data['tier'] == 'pro' ? 'pro' : 'standard', got)}),
    );
  }

  Future<void> refreshBalance({bool announce = false}) async {
    final inAnonChat = (current?.anon ?? false) && anon.ready;
    final res = await api.balance(identity.signer);
    if (res.data['error'] != null) {
      if (announce) await note(t('Could not reach Nymbot to check your balance.'));
      return;
    }
    standardBalance = (res.data['balanceCredits'] as num?)?.toDouble()
        ?? (res.data['balance'] as num?)?.toDouble() ?? 0;
    proBalance = (res.data['proBalanceCredits'] as num?)?.toDouble()
        ?? (res.data['proBalance'] as num?)?.toDouble() ?? 0;
    if (anon.ready) {
      final mine = await api.balance(await anon.signer());
      if (mine.data['error'] == null) {
        anonStandardBalance = (mine.data['balanceCredits'] as num?)?.toDouble()
            ?? (mine.data['balance'] as num?)?.toDouble() ?? 0;
        anonProBalance = (mine.data['proBalanceCredits'] as num?)?.toDouble()
            ?? (mine.data['proBalance'] as num?)?.toDouble() ?? 0;
      }
    } else {
      anonStandardBalance = null;
      anonProBalance = null;
    }
    // The worker is the authority on what this key has used; the device keeps
    // its own count so signing in with a fresh key does not start the day over.
    final seen = FreeAllowance.fromJson(res.data['free']);
    if (seen != null) {
      free = seen;
      await store.freeTier.observe(seen.used);
    }
    notifyListeners();
    if (announce) {
      await note(inAnonChat
          ? t("This chat's anonymous balance: {standard} standard, {pro} Pro. "
              'Your nym still holds {nymStandard} standard and {nymPro} Pro.', {
              'standard': anonStandardBalance,
              'pro': anonProBalance,
              'nymStandard': standardBalance,
              'nymPro': proBalance,
            })
          : t('Your balance: {standard} standard, {pro} Pro.',
              {'standard': standardBalance, 'pro': proBalance}));
    }
  }

  bool get proTier => activeModel != null || mediaNeedsPro(activeMediaModel);

  bool get spendingAnon => (current?.anon ?? false) && anon.ready;

  double? get shownBalance => spendingAnon
      ? (proTier ? anonProBalance : anonStandardBalance)
      : (proTier ? proBalance : standardBalance);

  /// How many free replies are actually available: the lower of what the worker
  /// says this key has left and what this device has left. Null when the free
  /// tier is not in play.
  int? get freeLeft {
    final held = free;
    if (held == null || held.limit <= 0) return null;
    final here = store.freeTier.leftOf(held.limit);
    return held.left < here ? held.left : here;
  }

  /// Whether a message may go at all. Only ever false on the free tier with the
  /// day spent — a balance is never gated by the device count, because someone
  /// who has paid is not on the free tier and must never be told they are.
  ///
  /// The device's count is a speed bump, not a control: clearing the app's data
  /// walks past it. What it must never do is reach the worker, because a device
  /// counter the server could see would link a person's keys to each other,
  /// which is the one thing this app is built not to do.
  bool get freeAllows {
    if (proTier) return true;
    if ((standardBalance ?? 0) > 0) return true;
    final held = free;
    if (held == null || held.limit <= 0) return true;
    return store.freeTier.allows(held.limit, (standardBalance ?? 0).floor());
  }

  /// The day is spent. Said as a time and a price rather than as a wall.
  String freeSpentMessage() {
    final at = free?.resetsAt ?? 0;
    // Whose allowance ran out matters.
    final byAddress = free?.netSpent ?? false;
    if (at <= 0) {
      return byAddress
          ? t("This address has used today's free replies — a new key does not "
              'get another set, because they are counted per address too. Tap '
              'Buy for credits.')
          : t("That is today's free replies used. Tap Buy for credits, which "
              'also unlock the sharper models, repositories, images and web search.');
    }
    final when = DateTime.fromMillisecondsSinceEpoch(at);
    final clock = '${when.hour.toString().padLeft(2, '0')}'
        ':${when.minute.toString().padLeft(2, '0')}';
    return byAddress
        ? t("This address has used today's free replies — a new key does not "
            'get another set, because they are counted per address too. They '
            'come back at {time}, or tap Buy for credits.', {'time': clock})
        : t(
            "That is today's free replies used. They come back at {time} — or tap "
            'Buy for credits, which also unlock the sharper models, repositories, '
            'images and web search.',
            {'time': clock});
  }

  String get satsLabel => activeModel != null ? 'Pro' : 'Standard';

  int satsFor(int credits, String tier) =>
      credits * (NymbotConfig.satsPerCredit[tier] ?? 10);

  static const List<Map<String, num>> bulkBonusFallback = [
    {'bonus': 0.10, 'standardSats': 500, 'proSats': 5000},
    {'bonus': 0.15, 'standardSats': 1000, 'proSats': 10000},
    {'bonus': 0.20, 'standardSats': 5000, 'proSats': 50000},
  ];

  List<Map<String, num>> get bulkBonus {
    final raw = catalogPricing?['bulkBonus'];
    if (raw is! List) return bulkBonusFallback;
    final rows = <Map<String, num>>[];
    for (final r in raw) {
      if (r is! Map) continue;
      final bonus = (r['bonus'] as num?) ?? 0;
      final std = (r['standardSats'] as num?) ?? 0;
      final pro = (r['proSats'] as num?) ?? 0;
      if (bonus > 0 && std > 0) {
        rows.add({'bonus': bonus, 'standardSats': std, 'proSats': pro});
      }
    }
    return rows.isEmpty ? bulkBonusFallback : rows;
  }

  int creditsCredited(int credits, String tier) {
    if (credits <= 0) return 0;
    final sats = satsFor(credits, tier);
    final key = tier == 'pro' ? 'proSats' : 'standardSats';
    var best = 0.0;
    for (final row in bulkBonus) {
      final at = (row[key] ?? 0).toDouble();
      final bonus = (row['bonus'] ?? 0).toDouble();
      if (at > 0 && sats >= at && bonus > best) best = bonus;
    }
    return (credits * (1 + best)).floor();
  }

  Map<String, dynamic>? catalogPricing;

  Map<String, dynamic>? mentionCatalog;

  ModelMaker? _maker(Map<String, dynamic>? model) => ModelMaker.of(model, mentionCatalog);
  Future<Map<String, dynamic>?>? _mentionLoad;

  Future<Map<String, dynamic>?> ensureMentionCatalog() {
    if (mentionCatalog != null) return Future.value(mentionCatalog);
    return _mentionLoad ??= api.models().then((catalog) {
      if (catalog != null && catalog['models'] is List) {
        mentionCatalog = catalog;
        notePricing(catalog);
      }
      _mentionLoad = null;
      notifyListeners();
      return mentionCatalog;
    }).catchError((_) {
      _mentionLoad = null;
      return null;
    });
  }

  void notePricing(Map<String, dynamic>? catalog) {
    if (catalog == null) return;
    final usd = (catalog['usdPerCredit'] as num?)?.toDouble() ?? 0;
    if (usd <= 0) return;
    catalogPricing = {
      'usdPerCredit': usd,
      'standardUsdPerCredit': catalog['standardUsdPerCredit'],
      'standardRoutes': catalog['standardRoutes'],
      'btcUsd': catalog['btcUsd'],
      'minChargeCredits': catalog['minChargeCredits'],
      'bulkBonus': catalog['bulkBonus'],
      'researchByKey': Research.researchByKey(catalog),
    };
    notifyListeners();
  }

  Future<void> ensurePricing() async {
    if (catalogPricing != null) return;
    notePricing(await api.models());
  }

  CostEstimate estimate(String text) => ChatEngine.estimate(text, activeModel,
      conv: current,
      hasRepos: activeRepos.isNotEmpty,
      pricing: catalogPricing,
      historyChars: _historyCharsNow(),
      // Priced against what will actually go on the wire — the standing
      // context and the attachments included — because that is what decides
      // whether the question needs more than one wrap, and each extra one is a
      // credit.
      wireText: _wireTextNow(text));

  int _historyCharsNow() {
    var n = 0;
    for (var i = messages.length - 1; i >= 0 && n < 160000; i--) {
      n += messages[i].content.length;
    }
    return n;
  }

  String _wireTextNow(String text) {
    final conv = current;
    if (conv == null) return text;
    final head = ChatEngine.preamble(conv, activeRepos, activePersona,
        activeWorkspace, activeBot, text, store.memories());
    final attached = attachments.map((a) => a.wireBlock).join();
    final searched = DocLibrary.instance.wireFor(conv.id, text, attachments);
    return '$head$text$attached$searched';
  }

  /// Normal, careful, deep and back. Each step is another model call the reply
  /// takes and the balance pays for, so the toolbar's estimate moves with it.
  Future<String> cycleEffort([String? to]) async {
    const order = ['normal', 'careful', 'deep'];
    final conv = current;
    if (conv == null) return 'normal';
    final at = order.indexOf(ChatEngine.effortOf(conv));
    final next = (to != null && order.contains(to))
        ? to
        : order[(at + 1) % order.length];
    conv.effort = next;
    _touch(conv);
    await store.saveConversations(conversations);
    notifyListeners();
    return next;
  }

  static ({double standard, double pro}) _spent(Iterable<ChatMessage> list) {
    var standard = 0.0;
    var pro = 0.0;
    for (final m in list) {
      if (m.role != ChatRole.bot) continue;
      if (m.pro ?? (m.model != null)) {
        pro += m.cost;
      } else {
        standard += m.cost;
      }
      pro += m.serverRunCredits;
    }
    return (standard: standard, pro: pro);
  }

  ({int sent, int replies, double standard, double pro, int words})
      currentStats() {
    var sent = 0;
    var replies = 0;
    var words = 0;
    for (final m in messages) {
      if (m.role == ChatRole.self) sent++;
      if (m.role == ChatRole.bot) replies++;
      words += m.content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    }
    final spent = _spent(messages);
    return (
      sent: sent,
      replies: replies,
      standard: spent.standard,
      pro: spent.pro,
      words: words,
    );
  }

  ({int replies, double standard, double pro}) deviceStats() {
    var replies = 0;
    var standard = 0.0;
    var pro = 0.0;
    for (final conv in conversations) {
      final list =
          conv.id == current?.id ? messages : store.messages(conv.id);
      replies += list.where((m) => m.role == ChatRole.bot).length;
      final spent = _spent(list);
      standard += spent.standard;
      pro += spent.pro;
    }
    return (replies: replies, standard: standard, pro: pro);
  }

  Future<void> wipe() => _leave(purge: true);

  Future<void> disconnectSigner() => _leave(purge: false);

  Future<void> _leave({required bool purge}) async {
    _bootWork?.cancel();
    _syncTimer?.cancel();
    _noticeTimer?.cancel();
    sync.stop();
    sync.forget();
    // Signed while the key is still here; bounded so a signer that never
    // answers cannot hold the wipe up.
    if (purge && signedIn) {
      await api.purgeAccount(identity.signer).timeout(
            const Duration(seconds: 3),
            onTimeout: () => false,
          );
    }
    await store.wipe();
    identity.forget();
    relays.close();
    conversations = [];
    messages = [];
    repos = [];
    connectors = [];
    notices = [];
    dismissedNotices = [];
    current = null;
    turns.clear();
    _queues.clear();
    _queueEdits.clear();
    signedIn = false;
    _entered = false;
    notifyListeners();
  }
}

class ChatTurn {
  ChatTurn(this.conv);

  final Conversation conv;
  final TurnControl control = TurnControl();
  String? status;

  /// What the running turn is doing, newest last. Advisory: it is emptied the
  /// moment a turn ends, and an empty list simply shows the plain spinner.
  List<TurnStep> steps = [];
  List<Map<String, dynamic>> log = [];
  String? draft;
  bool drafted = false;
  final DateTime began = DateTime.now();
  bool kept = false;
  bool watching = false;
  bool stopped = false;

  Object? research;
  Map<String, dynamic>? team;

  /// Credits already spent carrying the current chat's run on, so a budget is
  /// a budget for the task rather than for each leg of it.
  double continuedSpend = 0;
}
