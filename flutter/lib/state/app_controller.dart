import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/crypto/bech32_codec.dart';
import '../core/crypto/keys.dart';
import '../core/crypto/schnorr.dart' as schnorr;
import '../core/utils/jitter.dart';
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
import '../services/ask.dart';
import '../services/plan.dart';
import '../services/skills.dart';
import '../services/api_access.dart';
import '../services/background_jobs.dart';
import '../services/backup.dart';
import '../services/rewind.dart';
import '../services/blossom.dart';
import '../services/bot_files.dart';
import '../services/canary.dart';
import '../services/chat_engine.dart';
import '../services/connectors.dart';
import '../services/dev_contact.dart';
import '../services/doc_library.dart';
import '../services/done_since.dart';
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
import '../services/pr_watch.dart';
import '../services/passkey_backup.dart';
import '../core/crypto/pq.dart' as pq_crypto;
import '../services/pq_announce.dart';
import '../services/profiles.dart';
import '../services/relay_pool.dart';
import '../services/reply_notify.dart';
import '../services/research.dart';
import '../services/server_runs.dart';
import '../services/site_checks.dart';
import '../services/server_schedules.dart';
import '../services/spend_caps.dart';
import '../services/storage_sync.dart';
import '../services/task_transcript.dart';
import '../services/support_thread.dart';
import '../services/tasks.dart';
import '../services/team.dart';
import 'identity.dart';
import 'store.dart';
import 'transcript_book.dart';

/// [read] is false when neither D1 nor the relays answered, which is not "no root".
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

typedef RewindOutcome = ({
  ChatSnapshot snapshot,
  String convId,
  List<String> ids,
  List<RewindResult> results,
});

typedef AccountRoot = ({
  bool read,
  bool present,
  String? fingerprint,
  Uint8List? announced,
});

/// The single controller the whole app listens to.
class AppController extends ChangeNotifier {
  AppController._(this.store, this.identity, this.relays, this.pq, this.api,
      this.anon, this.storage) {
    sync = AccountSync(
        store: store, identity: identity, storage: storage, anon: anon);
    DocLibrary.bind(store);
  }

  static PqKeyServer? Function(NymbotApi api) pqKeyServer =
      (api) => api.pqKey;

  static Future<AppController> boot(
      {http.Client? client,
      Store? store,
      Nip46SocketFactory? signerSockets,
      PqKeyServer? pqKeys,
      StorageSync? storage,
      RelayPool? relays}) async {
    store ??= await Store.open();
    final identity = Identity(store,
        restoreSigner: (session) =>
            restoreRemoteSigner(session, sockets: signerSockets));
    relays ??= RelayPool();
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
    await c._loadSkills();
    c.chat.skillsOf = () => c.skills;
    return c;
  }

  final Store store;
  final Identity identity;
  final RelayPool relays;
  final PqAnnounce pq;
  final NymbotApi api;

  late final TranscriptBook transcripts = TranscriptBook(store)
    ..fetchLog = _transcriptLog
    ..onChange = notifyListeners;

  String _askedText(ChatTurn turn) {
    final id = turn.askId;
    if (id == null) return '';
    for (final m in _messagesOf(turn.conv)) {
      if (m.id == id) return m.content;
    }
    return '';
  }

  Future<({bool live, Map<String, dynamic>? run})?> _transcriptLog(
      Conversation conv, String runId, int since) async {
    final signer = await _signerOf(conv);
    final res = await api.liveRuns(signer,
        thread: conv.anon && conv.rootId.isNotEmpty ? conv.rootId : null, log: runId);
    final runs = res.data['runs'];
    final listed = res.status == 200 && runs is List ? runs : null;
    for (final r in listed ?? const []) {
      if (r is Map && r['replyTo'] == runId) return (live: true, run: r.cast<String, dynamic>());
    }
    final done = await api.doneSince(signer, (since - 60000).clamp(0, since), log: runId);
    final ended = done.data['runs'];
    final over = done.status == 200 && ended is List ? ended : null;
    for (final r in over ?? const []) {
      if (r is Map && r['replyTo'] == runId) return (live: false, run: r.cast<String, dynamic>());
    }
    return listed != null || over != null ? (live: false, run: null) : null;
  }

  TaskTranscript? transcriptFor(ChatMessage m) {
    final conv = current;
    return conv == null ? null : transcripts.forMessage(conv.id, m);
  }
  final AnonMode anon;
  final StorageSync storage;

  late final AccountSync sync;

  late final Profiles profiles;

  late final Blossom blossom;

  late final ApiAccess apiAccess =
      ApiAccess(client: api.client, signer: () => identity.signer);

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
    botPubkey: botPubkey,
  );

  Nip46SocketFactory? signerSockets;

  KeyBackups keyBackups = KeyBackups.platform();

  late PasskeyBackup passkeys = PasskeyBackup(relays: relays);

  late final ReplyNotify replyNotify = ReplyNotify(
    enabled: () => settings.replyNotify,
    prefs: () => settings.notify,
    register: _registerReplyNotify,
    titleOf: (id) => _conversationById(id)?.title ?? '',
    open: openChat,
    openAt: openChatAt,
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
    if (conv != null) {
      await open(conv);
      return;
    }
    for (final s in schedules) {
      if (s.id == id && s.due && s.server != 'run') {
        await runSchedule(id);
        return;
      }
    }
  }

  String? jumpTo;

  Future<void> openChatAt(String id, String asked) async {
    final conv = _conversationById(id);
    if (conv == null) return;
    await open(conv);
    for (final m in messages) {
      if (m.role == ChatRole.self && m.wire == asked) jumpTo = m.id;
    }
    notifyListeners();
  }

  String? takeJump() {
    final id = jumpTo;
    jumpTo = null;
    return id;
  }

  Future<Map<String, dynamic>?> _registerReplyNotify(
      String id, Map<String, dynamic> body) async {
    final conv = _conversationById(id);
    if (conv == null || conv.anon) return null;
    final res = await api.call('notify-turn', identity.signer,
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

  @visibleForTesting
  static String botPubkey = NymbotConfig.botPubkey;

  @visibleForTesting
  static List<Duration> claimBackoff = const [
    Duration(seconds: 3),
    Duration(seconds: 6),
    Duration(seconds: 12),
    Duration(seconds: 24),
    Duration(seconds: 48),
    Duration(seconds: 60),
  ];

  static const claimFor = Duration(hours: 1);

  static const slotPollDefault = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];

  @visibleForTesting
  static List<Duration> slotPoll = slotPollDefault;

  @visibleForTesting
  static Duration slotWaitFor = claimFor;

  List<ChatTurn> runsIn(Conversation? conv) {
    if (conv == null) return const [];
    final list = [
      for (final t in turns.values)
        if (t.conv.id == conv.id) t
    ];
    list.sort((a, b) => a.began.compareTo(b.began));
    return list;
  }

  ChatTurn? turnOf(Conversation? conv) {
    final list = runsIn(conv);
    return list.isEmpty ? null : list.last;
  }

  ChatTurn? runOfAsk(Conversation conv, String askId) {
    for (final t in turns.values) {
      if (t.conv.id == conv.id && t.askId == askId) return t;
    }
    return null;
  }

  bool sendingIn(Conversation? conv) => runsIn(conv).isNotEmpty;

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

  @visibleForTesting
  Future<void> carryOnForTest(Conversation conv, TurnResult first) =>
      _carryOn(ChatTurn(conv), first);

  @visibleForTesting
  ChatTurn holdForTest(Conversation conv) {
    final turn = ChatTurn(conv);
    turns[turn.key] = turn;
    notifyListeners();
    return turn;
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
    turns.removeWhere((_, t) => t.conv.id == conv.id);
    notifyListeners();
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
  double? get anonTotalStandard => anon.knownTotals().standard;
  double? get anonTotalPro => anon.knownTotals().pro;
  String? _anonShownFor;

  /// Free allowance left on the signed-in key, as last reported by the worker.
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

  // Settings

  void _loadSettings() {
    settings = store.settings();
    chat.defaultWhenDone = settings.whenDone;
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
    chat.defaultWhenDone = next.whenDone;
    await store.saveSettings(next);
    notifyListeners();
  }

  Future<void> resetSettings() async {
    final kept = (name: settings.nickname, at: settings.nicknameAt);
    await store.resetSettings();
    settings = store.settings();
    chat.defaultWhenDone = settings.whenDone;
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
      settledMedia(conv?.mediaModel ?? mediaModel, mentionCatalog);

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

  /// Moves a positional generator name into --model, which is the only place the worker reads it.
  static String generatorCommand(String? command) {
    final raw = (command ?? '').trim();
    if (_hasModelFlag.hasMatch(raw)) return raw;
    return raw.replaceFirstMapped(
        _bareGenerator, (m) => '${m[1]} --model ${m[2]}');
  }

  /// Generators are named in the message, so a Pro generator still carries the key it is billed against.
  Map<String, dynamic>? get proModelForTurn => proModelForTurnOf(current);

  Map<String, dynamic>? proModelForTurnOf(Conversation? conv) {
    final model = modelOf(conv);
    if (model != null) return model;
    final media = mediaModelOf(conv);
    final key = media?['proKey'] as String?;
    return (mediaNeedsPro(media) && key != null) ? {'key': key} : null;
  }

  static Map<String, dynamic> mediaFor(Map<String, dynamic> m,
      {String? slug, Map<String, dynamic>? catalog, String? resolution}) {
    final top = defaultResolution(m);
    final chosen = resolutionEntry(m, resolution);
    final custom = chosen != null && chosen['res'] != top;
    final credits = custom
        ? (chosen['credits'] as num?)?.toInt() ?? 0
        : (m['credits'] as num?)?.toInt() ?? 0;
    final command = generatorCommand(m['command'] as String?);
    final media = <String, dynamic>{
      'key': m['key'],
      'label': m['label'],
      'kind': m['kind'] ?? 'image',
      'credits': credits,
      'max': custom ? credits : (m['max'] as num?)?.toInt() ?? credits,
      'command': custom ? '$command --res ${chosen['res']}' : command,
      'slug': slug,
    };
    if (top != null) media['resolutionDefault'] = top;
    if (custom) media['resolution'] = chosen['res'];
    if (mediaNeedsPro(media)) media['proKey'] = cheapestChatKey(catalog);
    return media;
  }

  static List<Map<String, dynamic>> resolutionsOf(Map<String, dynamic>? m) => [
        for (final r in (m?['resolutions'] as List?) ?? const [])
          if (r is Map && r['res'] is String && (r['res'] as String).isNotEmpty)
            Map<String, dynamic>.from(r),
      ];

  static String? defaultResolution(Map<String, dynamic>? m) {
    final list = resolutionsOf(m);
    final named = m?['resolution'];
    if (named is String && named.isNotEmpty) {
      if (list.isEmpty || list.any((r) => r['res'] == named)) return named;
    }
    return list.isEmpty ? null : list.last['res'] as String;
  }

  static Map<String, dynamic>? resolutionEntry(
      Map<String, dynamic>? m, String? res) {
    if (res == null) return null;
    for (final r in resolutionsOf(m)) {
      if (r['res'] == res) return r;
    }
    return null;
  }

  static Map<String, dynamic>? catalogRow(
      Map<String, dynamic>? catalog, Object? key) {
    for (final m in (catalog?['models'] as List?) ?? const []) {
      if (m is Map<String, dynamic> && m['key'] == key) return m;
    }
    return null;
  }

  static final RegExp _resFlag =
      RegExp(r'(?:^|\s)--res(?:olution)?(?:[\s=]\S+|(?=\s|$))',
          caseSensitive: false);

  static Map<String, dynamic>? settledMedia(
      Map<String, dynamic>? media, Map<String, dynamic>? catalog) {
    final res = media?['resolution'];
    if (media == null || res == null) return media;
    final row = catalogRow(catalog, media['key']);
    if (row == null || resolutionsOf(row).isEmpty) return media;
    if (resolutionEntry(row, res as String?) != null) return media;
    final top = defaultResolution(row);
    final credits = (row['credits'] as num?)?.toInt() ?? 0;
    return {
      ...media,
      'resolutionDefault': top,
      'credits': credits,
      'max': (row['max'] as num?)?.toInt() ?? credits,
      'command': '${media['command'] ?? ''}'.replaceAll(_resFlag, '').trim(),
    }..remove('resolution');
  }

  static String? mediaResolution(Map<String, dynamic>? media) =>
      (media?['resolution'] ?? media?['resolutionDefault']) as String?;

  static String mediaLabel(Map<String, dynamic> media) {
    final name = '${media['label'] ?? media['key'] ?? ''}';
    final res = mediaResolution(media);
    return res == null ? name : t('{name} · {res}', {'name': name, 'res': res});
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
      if (text.startsWith('!')) return text;
      return _resFlag.hasMatch(text)
          ? '${command.replaceAll(_resFlag, '').trim()} $text'
          : '$command $text';
    }
    final rest = (head.group(2) ?? '').trim();
    if (head.group(1)!.toLowerCase() != verb.toLowerCase()) return text;
    if (rest.isEmpty || _listsModels.hasMatch(rest)) return text;
    if (_hasModelFlag.hasMatch(rest)) return text;
    return _resFlag.hasMatch(rest)
        ? '${command.replaceAll(_resFlag, '').trim()} $rest'
        : '$command $rest';
  }

  Future<void> toggleFavouriteModel(String key) async {
    favouriteModels = favouriteModels.contains(key)
        ? (favouriteModels.where((k) => k != key).toList())
        : ([...favouriteModels, key]);
    await store.saveFavouriteModels(favouriteModels);
    notifyListeners();
  }

  late SupportRelays supportRelays = SupportRelays.pool(relays);

  String supportDeveloper = kDeveloperPubkey;

  void Function()? _supportSub;
  Future<void> _supportChain = Future<void>.value();
  final Set<String> _supportWraps = {};
  Set<String>? _supportSeen;

  bool get supportListening => _supportSub != null;

  Conversation? get supportChat => _conversationById(kSupportChatId);

  List<String> get supportTokens => SupportTokens.of(store);

  Future<String> ensureSupportToken() => SupportTokens.ensure(store);

  DevContact developerContact(
          {ContactPublish? publish, ContactKem? kem, String? token}) =>
      DevContact(
        signer: identity.signer,
        publish: publish ?? supportRelays.publish,
        kem: kem ??
            (pubkey) async => (await pq.resolve(pubkey, viaProxy: true))?.pk,
        recipient: supportDeveloper,
        token: token,
        selfKem: identity.rootLocked ? null : identity.kemPublicKey,
      );

  Future<ContactOutcome> contactDeveloper(String topic, String message,
      {ContactPublish? publish, ContactKem? kem}) async {
    final contact = developerContact(
        publish: publish, kem: kem, token: await ensureSupportToken());
    final outcome = await contact.send(topic, message);
    final sent = contact.lastSent;
    if (outcome == ContactOutcome.sent && sent != null) {
      await _landSupport(sent);
    }
    return outcome;
  }

  Future<ContactOutcome> sendSupport(String text,
      {ContactPublish? publish, ContactKem? kem}) async {
    final contact = developerContact(
        publish: publish, kem: kem, token: await ensureSupportToken());
    final outcome = await contact.reply(text);
    final sent = contact.lastSent;
    if (outcome == ContactOutcome.sent && sent != null) {
      await _landSupport(sent);
    }
    return outcome;
  }

  Set<String> _seenSupport() {
    final held = _supportSeen;
    if (held != null) return held;
    final out = <String>{};
    try {
      final raw = store.getString(kSupportSeenKey);
      if (raw != null) out.addAll((jsonDecode(raw) as List).whereType<String>());
    } catch (_) {}
    for (final m in store.messages(kSupportChatId)) {
      out.add(m.id);
    }
    return _supportSeen = out;
  }

  Future<void> _noteSeen(String id) async {
    final seen = _seenSupport()..add(id);
    final list = seen.toList();
    final kept = list.length > kSupportSeenMax
        ? list.sublist(list.length - kSupportSeenMax)
        : list;
    if (kept.length != list.length) _supportSeen = kept.toSet();
    await store.setString(kSupportSeenKey, jsonEncode(kept));
  }

  Future<bool> _landSupport(SupportMessage m) async {
    if (_seenSupport().contains(m.id)) return false;
    await _noteSeen(m.id);
    var conv = supportChat;
    if (conv == null) {
      conv = Conversation(
        id: kSupportChatId,
        rootId: kSupportChatId,
        title: 'Support',
        support: true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m.at),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(m.at),
      );
      conversations.insert(0, conv);
    }
    final message = ChatMessage(
      id: m.id,
      role: m.mine ? ChatRole.self : ChatRole.bot,
      content: m.content,
      support: true,
      at: DateTime.fromMillisecondsSinceEpoch(m.at),
    );
    final open = conv.id == current?.id;
    final list = [
      ...(open ? messages : store.messages(conv.id)),
      message,
    ]..sort((a, b) => a.at.compareTo(b.at));
    if (open) messages = list;
    await store.saveMessages(conv.id, list);
    if (message.at.isAfter(conv.updatedAt)) conv.updatedAt = message.at;
    if (!m.mine && !open) conv.unread++;
    await store.saveConversations(conversations);
    notifyListeners();
    if (!m.mine) {
      unawaited(replyNotify.incoming(conv.id,
          title: t('Nymbot support replied'),
          body: t('Open the chat to read it.')));
    }
    _startSupport();
    return true;
  }

  int _supportSince() {
    final cursor = store.getInt(kSupportCursorKey);
    if (cursor > 0) return cursor - kSupportSlackSeconds;
    final thread = store.messages(kSupportChatId);
    final first = thread.isEmpty
        ? (supportChat?.createdAt ?? DateTime.now())
        : thread.map((m) => m.at).reduce((a, b) => a.isBefore(b) ? a : b);
    return first.millisecondsSinceEpoch ~/ 1000 - kSupportSlackSeconds;
  }

  Map<String, dynamic>? _supportFilter() {
    final tokens = supportTokens;
    if (supportChat == null || tokens.isEmpty || identity.pubkey.isEmpty) {
      return null;
    }
    return supportFilter(identity.pubkey, tokens, _supportSince());
  }

  void _startSupport({bool restart = false}) {
    if (_supportSub != null && !restart) return;
    final filter = _supportFilter();
    if (filter == null) return;
    _stopSupport();
    _supportSub = supportRelays.subscribe(filter, (e) {
      unawaited(receiveSupportWrap(e));
    });
    unawaited(fetchSupport());
  }

  void _stopSupport() {
    final stop = _supportSub;
    _supportSub = null;
    if (stop != null) stop();
  }

  Future<void> fetchSupport() async {
    if (_supportSub == null) return;
    final filter = _supportFilter();
    if (filter == null) return;
    List<NostrEvent> found;
    try {
      found = await supportRelays.fetch(filter,
          timeout: const Duration(seconds: 6));
    } catch (_) {
      return;
    }
    for (final e in found) {
      unawaited(receiveSupportWrap(e));
    }
    await _supportChain;
  }

  Future<void> receiveSupportWrap(NostrEvent wrap) {
    final next = _supportChain.then((_) => _takeSupportWrap(wrap));
    _supportChain = next.catchError((_) {});
    return _supportChain;
  }

  Future<void> _takeSupportWrap(NostrEvent wrap) async {
    if (wrap.kind != 1059 || identity.pubkey.isEmpty) return;
    if (!_supportWraps.add(wrap.id)) return;
    final opened = await openSupportWrap(
      wrap,
      signer: identity.signer,
      kems: identity.kemCandidates(),
      tokens: supportTokens,
      developer: supportDeveloper,
    );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final seen = wrap.createdAt > now ? now : wrap.createdAt;
    if (opened != null && seen > store.getInt(kSupportCursorKey)) {
      await store.setInt(kSupportCursorKey, seen);
    }
    if (opened == null) return;
    await _landSupport(opened);
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
    final signer = spendingAnon
        ? await anon.signer(pk: current?.anonPk)
        : identity.signer;
    final res = await api.call('transcribe', signer,
        extra: {'audio': base64Encode(audio)},
        timeout: const Duration(seconds: 60));
    final error = res.data['error'];
    if (error is String && error.isNotEmpty) return (text: null, error: error);
    final said = '${res.data['text'] ?? ''}'.trim();
    return (text: said, error: null);
  }

  /// Tops up the throwaway key from the nym only, never beyond its balance, one call at a time.
  Future<Map<String, int>?> autoTopUp({bool force = false, String? pk}) async {
    if (!settings.anonAutoTop || (pk == null && !anon.ready)) return null;
    if (_topping) return null;
    _topping = true;
    try {
      final floor = settings.anonAutoTopFloor < 0 ? 0 : settings.anonAutoTopFloor;
      final amount =
          settings.anonAutoTopAmount < 1 ? 1 : settings.anonAutoTopAmount;
      final want = settings.anonAutoTopTier;
      final tiers = want == 'both' ? const ['standard', 'pro'] : [want];

      final target = (await anon.identityFor(pk))['pk'] as String;
      final here = await api.balance(await anon.signer(pk: target));
      if (here.data['error'] == null) {
        await anon.noteBalanceData(target, here.data);
      }
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
        var credited = 0;
        try {
          credited = await anon.redeemHeld(tier, pk: target, want: amount);
        } catch (_) {}
        final left = amount - credited;
        final take = left < nym ? left : nym;
        if (take > 0) {
          try {
            credited += await anon.moveCredits(identity.signer, take, tier,
                pk: target);
          } catch (_) {
          }
        }
        if (credited > 0) moved[tier] = credited;
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

  Future<Map<String, int>?> fundAnonTurn(Conversation conv,
      {required double need, required String tier}) async {
    if (!conv.anon || _topping) return null;
    final Map<String, dynamic> id;
    try {
      id = await anon.bind(conv);
    } catch (_) {
      return null;
    }
    final pk = id['pk'] as String;
    final pro = tier == 'pro';
    final known = pk == _anonShownFor
        ? (pro ? anonProBalance : anonStandardBalance)
        : null;
    if (known != null && known >= need) return null;
    _topping = true;
    try {
      final here = await api.balance(anon.signerOf(id));
      if (here.data['error'] != null) return null;
      await anon.noteBalanceData(pk, here.data);
      final have = _figureOf(here.data, pro);
      if (have >= need) return null;
      final short = (need - have).ceil();
      var moved = 0;
      try {
        moved = await anon.redeemHeld(tier, pk: pk, want: short);
      } catch (_) {}
      final allowed = settings.anonAutoTopTier == 'both' ||
          settings.anonAutoTopTier == tier;
      if (moved < short && settings.anonAutoTop && allowed) {
        final mine = await api.balance(identity.signer);
        if (mine.data['error'] == null) {
          final amount =
              settings.anonAutoTopAmount < 1 ? 1 : settings.anonAutoTopAmount;
          final gap = short - moved;
          final nym = _figureOf(mine.data, pro).floor();
          final want = gap > amount ? gap : amount;
          final take = want < nym ? want : nym;
          if (take > 0) {
            try {
              moved += await anon.moveCredits(identity.signer, take, tier,
                  pk: pk);
            } catch (_) {}
          }
        }
      }
      if (moved <= 0) return null;
      _topping = false;
      await refreshBalance();
      return {tier: moved};
    } catch (_) {
      return null;
    } finally {
      _topping = false;
    }
  }

  String describeTopUp(Map<String, int> moved) {
    final parts = <String>[];
    if (moved['standard'] != null) {
      parts.add(t('{n} Standard', {'n': moved['standard']}));
    }
    if (moved['pro'] != null) parts.add(t('{n} Pro', {'n': moved['pro']}));
    return t('Moved {what} onto the throwaway key.', {'what': parts.join(', ')});
  }

  /// Per-chat ghost mode; moves messages off disk when on and writes them back when off.
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

  /// Startup sweep of ghost chats and chats past the auto-delete window.
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
      transcripts.forget(id);
      await store.dropConversation(id);
      await DocLibrary.instance.forget(id);
    }
    conversations.removeWhere((c) => doomed.contains(c.id));
    await store.saveConversations(conversations);
    return doomed.length;
  }

  // Carrying a capped run on

  double get continueBudget =>
      continueBudgetAfter(turnOf(current)?.continuedSpend ?? 0);

  /// A budget of -1 means the user's whole balance.
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

  Future<void> setWhenDone(String choice) async {
    final picked = whenDoneOf(choice);
    settings.whenDone =
        picked == whenDoneDefault && whenDoneOf(settings.whenDone).isEmpty
            ? ''
            : picked;
    chat.defaultWhenDone = settings.whenDone;
    await store.saveSettings(settings);
    notifyListeners();
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

  /// Polls the turn's progress until it ends, never delaying the send.
  void _watchTurn(ChatTurn turn, String eventId) {
    _askReplyNotifyOnce();
    replyNotify.pendingTurn(turn.conv.id, eventId,
        run: turn.key, anon: turn.conv.anon);
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
        final signer = turn.conv.anon
            ? await anon.signer(pk: turn.conv.anonPk)
            : identity.signer;
        String? draft;
        final raw = await chat.progressRaw(signer, eventId,
            after: after,
            draftAfter: draftAfter,
            onDraft: (text, seq) {
              draft = text;
              draftAfter = seq;
            },
            onPlan: (plan) {
              if (plan.isNotEmpty) turn.plan = plan;
            });
        final steps = ChatEngine.steps(raw);
        if (!turn.watching) return;
        transcripts.steps(turn, raw);
        await noteBranchSteps(turn, raw);
        if (steps.isNotEmpty) after = steps.last.n;
        if (steps.isNotEmpty && showSteps) {
          turn.steps = [...turn.steps, ...steps];
          turn.log = [...turn.log, ...Tasks.compactAll(raw)];
        }
        if (draft != null) {
          turn.draft = draft;
          turn.drafted = true;
        }
        if ((steps.isNotEmpty && showSteps) || draft != null || turn.plan.isNotEmpty) {
          notifyListeners();
        }
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

  /// Loaded in `main`, which can await the asset bundle without stalling widget test clocks.
  String? get preferredLanguage => store.getString('lang');

  bool get languageChosen => store.getBool('lang_chosen');

  Future<void> markLanguageChosen() async {
    await store.setBool('lang_chosen', true);
    notifyListeners();
  }

  /// Every screen reads `t()` on build, so notifying is enough.
  Future<void> setLanguage(String code) async {
    await store.setString('lang', code);
    await I18n.load(preferred: code);
    notifyListeners();
  }

  static const _gitMigratedKey = 'gitMigrated';

  Future<void> _loadRepos() async {
    repos = await store.repos();
    final legacy = store.getString('settings');
    if (legacy == null) return;
    Map<String, dynamic>? held;
    try {
      final j = jsonDecode(legacy);
      if (j is Map<String, dynamic>) held = j;
    } catch (_) {}
    if (held == null || !held.containsKey('git')) return;
    final git = held['git'];
    final migrated = store.getBool(_gitMigratedKey) ||
        repos.isNotEmpty ||
        await store.secret('repos') != null;
    if (!migrated &&
        git is Map &&
        git['repo'] != null &&
        git['token'] != null) {
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
    await store.setBool(_gitMigratedKey, true);
    held.remove('git');
    await store.setString('settings', jsonEncode(held));
  }

  Workspace? get activeWorkspace => workspaceOf(current);

  Workspace? workspaceOf(Conversation? conv) =>
      store.workspace(conv?.workspaceId);

  List<GitRepo> get activeRepos => reposOf(current);

  /// The chat's own repos then its workspace's, deduplicated.
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

  /// Repos this chat picked itself, not inherited from its workspace.
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
    final gone = repos.where((r) => r.id == id).firstOrNull;
    if (gone != null) unawaited(prWatchStopRepo(gone).catchError((_) => 0));
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

  SiteCheckInfo get siteCheck => runner.siteCheck;

  bool get siteCheckAvailable => runner.siteCheck.available;

  Future<ApiResult> runSiteCheck(Conversation? conv, String url, double maxCost) async {
    final useAnon = conv != null && conv.anon;
    final signer = useAnon ? await anon.signer(pk: conv.anonPk) : identity.signer;
    final res = await api.siteCheck(signer, {'url': url, 'maxCost': maxCost});
    if (res.status != 200 || conv == null) return res;
    final data = res.data;
    final credits = data['credits'] is num ? (data['credits'] as num).toDouble() : 0.0;
    await _addTo(conv, ChatMessage(
      id: bytesToHex(randomBytes(8)),
      role: ChatRole.bot,
      content: SiteChecks.reportMarkdown('${data['url'] ?? url}', data, credits),
      pro: true,
      serverRunCredits: credits,
    ));
    final balance = data['balanceCredits'] ?? data['balance'];
    final state = ServerRunState()
      ..charged = credits
      ..balance = balance is num ? balance.toDouble() : null;
    await serverRunCharged(conv, state);
    return res;
  }

  Future<bool> serverRunCapGate(Conversation? conv, double credits) async {
    if (conv == null || !SpendCaps.any(conv, botOf(conv))) return true;
    final gate = await _capGate(conv, true, credits);
    return gate == 'send' || gate == 'ok';
  }

  Future<ServerRunResponse> startServerRun(
      Conversation? conv, Map<String, dynamic> body) async {
    final useAnon = conv != null && conv.anon;
    final signer =
        useAnon ? await anon.signer(pk: conv.anonPk) : identity.signer;
    return api.runnerRun(signer, body);
  }

  Future<void> serverRunCharged(Conversation? conv, ServerRunState state) async {
    final credits = state.charged ?? 0;
    _creditBalance(true, state.balance,
        anonKey: conv != null && conv.anon,
        anonPk: conv?.anonPk);
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
    final useAnon = conv != null && conv.anon;
    final free = data['balanceCredits'] ?? data['balance'];
    if (free is num) {
      _creditBalance(true, free.toDouble(),
          anonKey: useAnon, anonPk: conv?.anonPk);
    }
    final topped =
        useAnon ? await autoTopUp(force: true, pk: conv.anonPk) : null;
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

  final Set<String> _resuming = {};

  Future<void> _resumePending(ChatMessage m, {required bool approve}) async {
    final conv = current;
    final p = m.pendingTool;
    if (conv == null || p == null || !_resuming.add(m.id)) return;
    try {
      await _resumeRun(conv, m, p, approve: approve);
    } finally {
      _resuming.remove(m.id);
    }
  }

  Future<void> _resumeRun(Conversation conv, ChatMessage m,
      Map<String, dynamic> p, {required bool approve}) async {
    final run = p['kind'] == 'server-run';
    final runCredits = run && approve ? ((p['maxCredits'] as num?)?.toDouble() ?? 0) : 0.0;
    final token = p['token'] as String? ?? '';
    if (token.isEmpty) {
      await _settlePending(conv, m, 'denied');
      await note(t('That request has expired. Ask again and Nymbot will start it fresh.'),
          conv: conv, replyTo: m.replyTo);
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
          web: webOn,
          history: ChatEngine.estHistoryOf(_messagesOf(conv)),
          pricing: catalogPricing);
      if (!waived) {
        final gate = await _capGate(conv, est.tier == 'pro' || run, est.max + runCredits);
        if (gate != 'send' && gate != 'ok') return;
        if (gate == 'ok') {
          maxCost = SpendCaps.maxCost(conv, botOf(conv), _messagesOf(conv),
              pro: est.tier == 'pro' || run);
        }
      }
    }
    await _settlePending(conv, m, approve ? 'allowed' : 'denied');
    final link = m.replyTo;
    String? askId;
    if (link != null) {
      for (final x in _messagesOf(conv)) {
        if (x.role == ChatRole.self && x.wire == link) askId = x.id;
      }
    }
    final turn = ChatTurn(conv, askId: askId, msgId: link);
    if (p['team'] == true) turn.team = <String, dynamic>{};
    turn.model = model;
    turn.kind = run ? 'server-run' : (p['team'] == true ? 'team' : 'connector');
    turns[turn.key] = turn;
    turn.status = run
        ? (approve ? t('Running on a Nymbot server…') : t('Continuing without the server run…'))
        : approve
            ? t('Running {tool} on {connector}', {'tool': '${p['tool']}', 'connector': '${p['connector']}'})
            : t('Carrying on without {tool}', {'tool': '${p['tool']}'});
    turn.control.onStatus = (s) {
      turn.status = s;
      notifyListeners();
    };
    notifyListeners();
    TurnResult? carry;
    var resendWaived = false;
    try {
      await _takeSlot(turn, force: true);
      turn.prepared = await chat.prepare(
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
        persona: personaOf(conv),
        workspace: workspaceOf(conv),
        bot: botOf(conv),
        memories: store.memories(),
        webSearch: webOn,
        resume: token,
        runExtras: {
          ..._runExtras(conv),
          ...await _grantFor(conv, model, team: turn.team),
        },
        onTurn: (eventId) => _watchTurn(turn, eventId),
        onStep: (step) => _localStep(turn, step),
      );
      if (turn.stopped) throw ChatFailure(t('Stopped.'), cancelled: true);
      final res = await _deliver(turn,
          timeout: run && approve
              ? NymbotConfig.pmTimeout +
                  Duration(seconds: ((p['timeoutSec'] as num?)?.toInt() ?? 0) + 180)
              : null);
      carry = await _land(turn, res);
    } on ChatFailure catch (e) {
      if (await _commonFailure(turn, e)) {
        notifyListeners();
      } else if (e.capExceeded) {
        await _putPending(conv, m, p);
        if (onCapPrompt == null) {
          await note(t('Not sent: this reply could go past the chat\'s spending cap, and nobody was here to agree to it.'),
              conv: conv, replyTo: _linkOf(turn));
        } else {
          final choice = await onCapPrompt!(
              SpendCaps.refusal(e.required, e.pro, team: e.team));
          resendWaived = choice == 'send';
        }
      } else {
        await note(e.message, conv: conv, replyTo: _linkOf(turn));
      }
    } catch (_) {
      _stopWatching(turn);
      if (!turn.stopped) {
        await note(t('Could not carry on from there.'), conv: conv, replyTo: _linkOf(turn));
      }
    } finally {
      if (turn.phase != 'claiming') {
        _stopWatching(turn);
        turn.status = null;
      }
      notifyListeners();
    }
    if (carry != null && !turn.stopped) await _carryOn(turn, carry);
    if (turn.phase != 'claiming') _endTurn(turn);
    if (resendWaived) {
      _capWaive = conv.id;
      await _resumeRun(conv, m, p, approve: approve);
    }
  }

  Future<ChatMessage> _putAsk(Conversation conv, ChatMessage m, Map<String, dynamic> patch) async {
    final list = conv.id == current?.id ? messages : store.messages(conv.id);
    ChatMessage? out;
    final next = [
      for (final x in list)
        if (x.id == m.id) out = x.copyWith(ask: {...?x.ask, ...patch}) else x
    ];
    if (conv.id == current?.id) messages = next;
    await store.saveMessages(conv.id, next);
    notifyListeners();
    return out ?? m;
  }

  final Set<String> _answering = {};

  Future<void> answerQuestion(ChatMessage m, Map<String, dynamic> raw) async {
    final conv = current;
    if (conv == null || !_answering.add(m.id)) return;
    try {
      await _answerQuestion(conv, m, raw);
    } finally {
      _answering.remove(m.id);
    }
  }

  Future<void> _answerQuestion(Conversation conv, ChatMessage m, Map<String, dynamic> raw) async {
    var held = _messagesOf(conv).where((x) => x.id == m.id).firstOrNull ?? m;
    final a = held.ask;
    if (a == null) return;
    final state = Ask.stateOf(a);
    if (state == 'expired') {
      await _putAsk(conv, held, {'state': 'expired'});
      return;
    }
    if (state != 'waiting') return;
    final questions = Ask.questionsOf(a['questions']);
    final got = Ask.answers(questions, raw);
    if (got['error'] != null) {
      await _putAsk(conv, held, {'error': Ask.errorText('${got['error']}'), 'draft': raw['answers']});
      return;
    }
    final skipped = got['skipped'] == true;
    final kept = <String, dynamic>{
      'state': skipped ? 'skipped' : 'answered',
      'answers': skipped ? null : got['answers'],
      'error': '',
    };
    final body = <String, dynamic>{
      'id': a['id'],
      if (skipped) 'skipped': true else 'answers': got['answers'],
    };
    held = await _putAsk(conv, held, {'state': 'sending', 'error': ''});
    final runId = a['runId'];
    if (runId is String && runId.isNotEmpty) {
      final res = await api.answer(identity.signer, runId, '${a['id']}',
          answers: skipped ? null : (got['answers'] as List).cast<Map<String, dynamic>>(), skipped: skipped);
      if (res.status == 200 && res.data['ok'] == true) {
        held = await _putAsk(conv, held, kept);
        final turn = ChatTurn(conv, msgId: runId);
        transcripts.begin(turn);
        transcripts.asked(turn, skipped ? 'skipped' : 'answered', held);
        await _trackBackground(turn, (runId: runId, until: (res.data['until'] as num?)?.toInt() ?? 0));
        return;
      }
      if (res.status == 410 || res.status == 409 || res.data['expired'] == true || res.data['gone'] == true) {
        await _putAsk(conv, held, {'state': 'expired'});
        return;
      }
      await _putAsk(conv, held, {
        'state': 'waiting',
        'error': res.data['error'] is String ? res.data['error'] : t('Could not send your answer. Try again.'),
      });
      return;
    }
    final token = a['token'] is String ? a['token'] as String : null;
    final text = Ask.answerText(questions, got);
    final model = modelOf(conv);
    String? askId;
    final link = held.replyTo;
    if (link != null) {
      for (final x in _messagesOf(conv)) {
        if (x.role == ChatRole.self && x.wire == link) askId = x.id;
      }
    }
    final turn = ChatTurn(conv, askId: askId, msgId: link);
    turn.model = model;
    turn.kind = 'chat';
    turns[turn.key] = turn;
    turn.status = t('Carrying on with your answer');
    turn.control.onStatus = (s) {
      turn.status = s;
      notifyListeners();
    };
    transcripts.begin(turn);
    transcripts.asked(turn, skipped ? 'skipped' : 'answered', held);
    notifyListeners();
    TurnResult? carry;
    try {
      await _takeSlot(turn, force: true);
      turn.prepared = await chat.prepare(
        conv: conv,
        text: text,
        maxCost: SpendCaps.any(conv, botOf(conv))
            ? SpendCaps.maxCost(conv, botOf(conv), _messagesOf(conv), pro: model != null)
            : null,
        proModel: model,
        repos: reposOf(conv),
        connectors: connectorsOf(conv),
        serverRuns: serverRunsOf(conv),
        persona: personaOf(conv),
        workspace: workspaceOf(conv),
        bot: botOf(conv),
        memories: store.memories(),
        webSearch: webOn,
        resume: token,
        pendingAnswer: token != null ? body : null,
        runExtras: {
          ..._runExtras(conv),
          if (token != null) ...await _grantFor(conv, model),
        },
        onTurn: (eventId) => _watchTurn(turn, eventId),
        onStep: (step) => _localStep(turn, step),
      );
      if (turn.stopped) throw ChatFailure(t('Stopped.'), cancelled: true);
      final res = await _deliver(turn);
      await _putAsk(conv, held, kept);
      carry = await _land(turn, res);
    } on ChatFailure catch (e) {
      if (e.resumeExpired) {
        await _putAsk(conv, held, {'state': 'expired'});
      } else if (await _commonFailure(turn, e)) {
        await _putAsk(conv, held, {'state': 'waiting'});
        notifyListeners();
      } else {
        await _putAsk(conv, held, {'state': 'waiting', 'error': e.message});
      }
    } catch (_) {
      _stopWatching(turn);
      await _putAsk(conv, held, {'state': 'waiting', 'error': t('Could not send your answer. Try again.')});
    } finally {
      if (turn.phase != 'claiming') {
        _stopWatching(turn);
        turn.status = null;
      }
      notifyListeners();
    }
    if (carry != null && !turn.stopped) await _carryOn(turn, carry);
    if (turn.phase != 'claiming') _endTurn(turn);
  }

  Future<void> _expireQuestions(Conversation conv, String runId) async {
    for (final m in _messagesOf(conv)) {
      if (m.ask != null && m.ask!['runId'] == runId && Ask.pending(m.ask)) {
        await _putAsk(conv, m, {'state': 'expired'});
      }
      if (m.proposal != null && m.proposal!['runId'] == runId && Plan.pending(m.proposal)) {
        await _putPlan(conv, m, {'state': 'expired'});
      }
    }
  }

  Future<ChatMessage> _putPlan(Conversation conv, ChatMessage m, Map<String, dynamic> patch) async {
    final list = conv.id == current?.id ? messages : store.messages(conv.id);
    ChatMessage? out;
    final next = [
      for (final x in list)
        if (x.id == m.id) out = x.copyWith(proposal: {...?x.proposal, ...patch}) else x
    ];
    if (conv.id == current?.id) messages = next;
    await store.saveMessages(conv.id, next);
    notifyListeners();
    return out ?? m;
  }

  Future<void> revisePlan(ChatMessage m, String text) async {
    final conv = current;
    if (conv == null) return;
    final held = _messagesOf(conv).where((x) => x.id == m.id).firstOrNull ?? m;
    final p = held.proposal;
    final said = Plan.note(text);
    if (p == null || Plan.stateOf(p) != 'waiting') return;
    if (said.isEmpty) {
      await _putPlan(conv, held, {'error': t('Say what should change.')});
      return;
    }
    final runId = p['runId'] is String && (p['runId'] as String).isNotEmpty ? p['runId'] as String : held.replyTo;
    var steered = false;
    if (runId != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(runId)) {
      final res = await api.steerRun(identity.signer, runId, said);
      steered = res.status == 200 && res.data['ok'] == true;
      if (steered) transcripts.steered(runId, said, convId: conv.id);
    }
    await decidePlan(held, steered ? {'decision': 'revise'} : {'decision': 'revise', 'edits': {'note': said}});
  }

  Future<void> approvePlanById(String messageId) async {
    final conv = current;
    if (conv == null) return;
    final m = _messagesOf(conv).where((x) => x.id == messageId).firstOrNull;
    if (m != null && m.proposal != null) await decidePlan(m, {'decision': 'approve'});
  }

  Future<void> decidePlan(ChatMessage m, Map<String, dynamic> raw) async {
    final conv = current;
    if (conv == null || !_answering.add(m.id)) return;
    try {
      await _decidePlan(conv, m, raw);
    } finally {
      _answering.remove(m.id);
    }
  }

  Future<void> _decidePlan(Conversation conv, ChatMessage m, Map<String, dynamic> raw) async {
    var held = _messagesOf(conv).where((x) => x.id == m.id).firstOrNull ?? m;
    final p = held.proposal;
    if (p == null) return;
    final state = Plan.stateOf(p);
    if (state == 'expired') {
      await _putPlan(conv, held, {'state': 'expired'});
      return;
    }
    if (state != 'waiting') return;
    final got = Plan.decide(p, raw);
    if (got['error'] != null) {
      await _putPlan(conv, held, {'error': t('That decision does not fit the plan.')});
      return;
    }
    final kept = Plan.keptFor(got);
    final body = Plan.bodyFor(p, got);
    final stage = Plan.stageOf({...p, ...kept});
    held = await _putPlan(conv, held, {'state': 'sending', 'error': ''});
    final runId = p['runId'];
    if (runId is String && runId.isNotEmpty) {
      final res = await api.answer(identity.signer, runId, '${p['id']}',
          decision: '${got['decision']}', edits: body['edits'] is Map ? (body['edits'] as Map).cast<String, dynamic>() : null);
      if (res.status == 200 && res.data['ok'] == true) {
        held = await _putPlan(conv, held, kept);
        final turn = ChatTurn(conv, msgId: runId);
        transcripts.begin(turn);
        if (stage != null) transcripts.planned(turn, stage, held);
        await _trackBackground(turn, (runId: runId, until: (res.data['until'] as num?)?.toInt() ?? 0));
        return;
      }
      if (res.status == 410 || res.status == 409 || res.data['expired'] == true || res.data['gone'] == true) {
        await _putPlan(conv, held, {'state': 'expired'});
        return;
      }
      await _putPlan(conv, held, {
        'state': 'waiting',
        'error': res.data['error'] is String ? res.data['error'] : t('Could not send your decision. Try again.'),
      });
      return;
    }
    final token = p['token'] is String ? p['token'] as String : null;
    final model = modelOf(conv);
    String? askId;
    final link = held.replyTo;
    if (link != null) {
      for (final x in _messagesOf(conv)) {
        if (x.role == ChatRole.self && x.wire == link) askId = x.id;
      }
    }
    final turn = ChatTurn(conv, askId: askId, msgId: link);
    turn.model = model;
    turn.kind = 'chat';
    turns[turn.key] = turn;
    turn.status = t('Carrying on with your decision');
    turn.control.onStatus = (s) {
      turn.status = s;
      notifyListeners();
    };
    transcripts.begin(turn);
    if (stage != null) transcripts.planned(turn, stage, held.copyWith(proposal: {...p, ...kept}));
    notifyListeners();
    TurnResult? carry;
    try {
      await _takeSlot(turn, force: true);
      turn.prepared = await chat.prepare(
        conv: conv,
        text: Plan.textFor(got),
        maxCost: SpendCaps.any(conv, botOf(conv))
            ? SpendCaps.maxCost(conv, botOf(conv), _messagesOf(conv), pro: model != null)
            : null,
        proModel: model,
        repos: reposOf(conv),
        connectors: connectorsOf(conv),
        serverRuns: serverRunsOf(conv),
        persona: personaOf(conv),
        workspace: workspaceOf(conv),
        bot: botOf(conv),
        memories: store.memories(),
        webSearch: webOn,
        resume: token,
        pendingAnswer: token != null ? body : null,
        runExtras: {
          ..._runExtras(conv),
          if (token != null) ...await _grantFor(conv, model),
        },
        onTurn: (eventId) => _watchTurn(turn, eventId),
        onStep: (step) => _localStep(turn, step),
      );
      if (turn.stopped) throw ChatFailure(t('Stopped.'), cancelled: true);
      final res = await _deliver(turn);
      await _putPlan(conv, held, kept);
      carry = await _land(turn, res);
    } on ChatFailure catch (e) {
      if (e.resumeExpired) {
        await _putPlan(conv, held, {'state': 'expired'});
      } else if (await _commonFailure(turn, e)) {
        await _putPlan(conv, held, {'state': 'waiting'});
        notifyListeners();
      } else {
        await _putPlan(conv, held, {'state': 'waiting', 'error': e.message});
      }
    } catch (_) {
      _stopWatching(turn);
      await _putPlan(conv, held, {'state': 'waiting', 'error': t('Could not send your decision. Try again.')});
    } finally {
      if (turn.phase != 'claiming') {
        _stopWatching(turn);
        turn.status = null;
      }
      notifyListeners();
    }
    if (carry != null && !turn.stopped) await _carryOn(turn, carry);
    if (turn.phase != 'claiming') _endTurn(turn);
  }

  List<Skill> skills = [];

  List<Skill> get allSkills => Skills.catalog(skills);

  Skill? skillById(String? id) {
    if (id == null) return null;
    for (final s in allSkills) {
      if (s.id == id) return s;
    }
    return null;
  }

  Skill? skillOf(Conversation? conv) => skillById(conv?.skillId);

  Future<void> _loadSkills() async {
    skills = Skills.ordered(await store.skills());
    notifyListeners();
  }

  Future<({Skill? skill, String? error})> saveSkill(Map<String, dynamic> raw) async {
    final got = Skills.normalize(raw);
    if (got['error'] != null) return (skill: null, error: '${got['error']}');
    final j = (got['skill'] as Map).cast<String, dynamic>();
    final list = [...skills];
    var id = '${j['id']}';
    final at = id.isEmpty ? -1 : list.indexWhere((s) => s.id == id);
    if (at < 0 && list.length >= Skills.maxSkills) return (skill: null, error: 'full');
    if (id.isEmpty || Skills.isBuiltin(id) || at < 0 && list.any((s) => s.id == id)) id = bytesToHex(randomBytes(8));
    final now = DateTime.now().millisecondsSinceEpoch;
    final order = at < 0
        ? (list.isEmpty ? 0 : list.map((s) => s.order).reduce((a, b) => a > b ? a : b) + 1)
        : list[at].order;
    final skill = Skill(
        id: id,
        name: '${j['name']}',
        description: '${j['description']}',
        body: '${j['body']}',
        order: order,
        updatedAt: now);
    if (at < 0) {
      list.add(skill);
    } else {
      list[at] = skill;
    }
    skills = Skills.ordered(list);
    await store.saveSkills(skills);
    notifyListeners();
    return (skill: skill, error: null);
  }

  Future<({Skill? skill, String? error})> duplicateSkill(String id) async {
    final from = skillById(id);
    if (from == null) return (skill: null, error: 'name');
    final name = Skills.isBuiltin(id) ? Skills.label(from) : t('{name} (copy)', {'name': Skills.label(from)});
    return saveSkill({
      'name': name.length > Skills.nameMax ? name.substring(0, Skills.nameMax) : name,
      'description': Skills.describe(from),
      'body': from.body,
    });
  }

  Future<bool> deleteSkill(String id) async {
    if (Skills.isBuiltin(id) || !skills.any((s) => s.id == id)) return false;
    await store.bury(id);
    skills = [
      for (final s in skills)
        if (s.id != id) s
    ];
    await store.saveSkills(skills);
    var changed = false;
    for (final c in conversations) {
      if (c.skillId == id) {
        c.skillId = null;
        changed = true;
      }
    }
    if (changed) await store.saveConversations(conversations);
    notifyListeners();
    return true;
  }

  Future<void> moveSkill(String id, int delta) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    skills = [for (final s in Skills.move(skills, id, delta)) s.copyWith(updatedAt: now)];
    await store.saveSkills(skills);
    notifyListeners();
  }

  Future<Conversation> newChatWithSkill(String id) async {
    final conv = await newConversation();
    conv.skillId = id;
    await store.saveConversations(conversations);
    notifyListeners();
    return conv;
  }

  Future<void> attachSkill(String? id) async {
    final conv = current;
    if (conv == null) return;
    conv.skillId = conv.skillId == id ? null : id;
    _touch(conv);
    await store.saveConversations(conversations);
    notifyListeners();
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

  /// Always signed by the account, never a throwaway key; kind 30078 replaces earlier versions.
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

  /// Null when no relay has it.
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
    final held = schedules.where((s) => s.id == id).firstOrNull;
    await store.bury(id);
    schedules = schedules.where((s) => s.id != id).toList();
    await store.saveSchedules(schedules);
    notifyListeners();
    if (held != null && held.serverSha != null) {
      await api.scheduleDelete(identity.signer, id);
    }
  }

  Future<void> runSchedule(String id) async {
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
        {'name': entry.title.isEmpty ? t('Untitled') : entry.title}), conv: target);
    await send(entry.prompt, target: target, bare: false, unattended: true, withAttachments: const []);
  }

  List<Schedule> get dueSchedules => schedules
      .where((s) =>
          s.due &&
          !(settings.serverSchedules && s.server == 'run' && s.serverSha != null))
      .toList();

  Future<void> runDueSchedules() async {
    final due = dueSchedules;
    if (due.isEmpty) return;
    await runSchedule(due.first.id);
  }

  void startScheduler() {
    _scheduler?.cancel();
    _scheduler = Timer.periodic(const Duration(minutes: 1), (_) {
      runDueSchedules().catchError((_) {});
      prWatchTick().catchError((_) {});
    });
  }

  final Map<String, Map<String, dynamic>> prLive = {};
  final Map<String, ({int at, Map<String, dynamic>? live})> prPeeked = {};
  int _prListedAt = 0;
  Future<int>? _prListing;

  List<Map<String, dynamic>> get prRecords =>
      PrWatch.decodeRecords(store.getString(PrWatch.storeKey));

  Future<void> _savePrRecords(List<Map<String, dynamic>> list) =>
      store.setString(PrWatch.storeKey, PrWatch.encodeRecords(list));

  Map<String, dynamic>? prRecordFor(Object? repo, Object? branch) => prRecords
      .where((r) => r['repo'] == repo && r['branch'] == branch && r['stopped'] != true)
      .firstOrNull;

  bool get prWatching => prRecords.any((r) => r['stopped'] != true);

  Map<String, dynamic>? prLiveFor(Object? repo, Object? branch) {
    final rec = prRecordFor(repo, branch);
    if (rec != null && prLive.containsKey(rec['id'])) return prLive[rec['id']];
    return prPeeked[PrWatch.keyOf(repo, branch)]?.live;
  }

  ({bool on, Map<String, dynamic>? live})? prChip(Conversation? conv, Map<String, dynamic> job) {
    if (conv == null || conv.anon || job['repo'] == null) return null;
    final rec = prRecordFor(job['repo'], job['branch']);
    if (rec == null && !PrWatch.canWatch(job)) return null;
    return (on: rec != null, live: prLiveFor(job['repo'], job['branch']));
  }

  Future<String> prWatchStart(Conversation conv, ChatMessage? m, Map<String, dynamic> job,
      {bool auto = false}) async {
    if (conv.anon) return t('Watching pull requests is not available in anonymous chats.');
    final repo = reposOf(conv).where((r) => r.repo == job['repo']).firstOrNull;
    if (repo == null) return t('That repository is no longer connected.');
    if (!repo.allowWrites) return t('Writes are off for that repository.');
    final model = '${modelOf(conv)?['key'] ?? ''}';
    Map<String, dynamic>? push;
    try {
      push = await replyNotify.pushRegistration(conv.id, t('A pull request you watch changed'), kind: 'prwatch');
    } catch (_) {
      push = null;
    }
    final body = PrWatch.watchBody(repo.toPayload(defaultWhenDone: settings.whenDone), job,
        thread: conv.rootId,
        fix: settings.prFix,
        cap: PrWatch.fixCap(settings.prFixCap),
        model: model,
        planFirst: policyOf(conv)['planFirst'],
        push: push);
    final res = await api.prWatchPut(identity.signer, body);
    if (res.status != 200 || res.data['ok'] != true || res.data['id'] is! String) {
      final error = res.data['error'];
      return error is String && error.isNotEmpty ? error : t('The pull request could not be watched.');
    }
    final watch = body['watch'] as Map<String, dynamic>;
    final id = res.data['id'] as String;
    final list = prRecords
        .where((r) => !(r['repo'] == job['repo'] && r['branch'] == watch['branch']))
        .toList()
      ..add({
        'id': id,
        'repo': job['repo'],
        'branch': watch['branch'],
        'number': watch['number'],
        'convId': conv.id,
        'msgId': m?.id,
        'at': DateTime.now().millisecondsSinceEpoch,
        'seen': 0,
      });
    await _savePrRecords(list);
    final summary = res.data['watch'];
    if (summary is Map) prLive[id] = summary.cast<String, dynamic>();
    if (m != null) {
      transcripts.prEvent(conv.id, m, 'watch', t('Watching pull request #{n}.', {'n': watch['number']}));
    }
    notifyListeners();
    return '';
  }

  Future<String> prWatchStop(Map<String, dynamic> rec) async {
    final res = await api.prWatchStop(identity.signer, '${rec['id']}');
    if (res.status != 200 || res.data['error'] != null) {
      final error = res.data['error'];
      return error is String && error.isNotEmpty ? error : t('The watch could not be stopped.');
    }
    await _savePrRecords(prRecords.where((r) => r['id'] != rec['id']).toList());
    prLive.remove(rec['id']);
    notifyListeners();
    return '';
  }

  Future<int> prWatchStopRepo(GitRepo repo) async {
    final mine = prRecords.where((r) => r['repo'] == repo.repo).toList();
    for (final rec in mine) {
      try {
        await prWatchStop(rec);
      } catch (_) {}
    }
    return mine.length;
  }

  Future<String> prWatchToggle(ChatMessage? m, Map<String, dynamic> job) async {
    final conv = current;
    if (conv == null) return '';
    final rec = prRecordFor(job['repo'], job['branch']);
    try {
      if (rec != null) {
        final err = await prWatchStop(rec);
        return err.isNotEmpty ? err : t('Stopped watching pull request #{n}.', {'n': rec['number']});
      }
      final err = await prWatchStart(conv, m, job);
      return err.isNotEmpty
          ? err
          : t('Watching pull request #{n}. Nymbot posts here when CI fails, a reviewer comments, or it is merged or closed, even with the app closed.',
              {'n': PrWatch.pullNo(job)});
    } catch (_) {
      return t('The forge could not be reached.');
    }
  }

  Future<int> prWatchAuto(Conversation conv, ChatMessage m) async {
    final mark = m.checkpoint;
    if (conv.anon || mark == null) return 0;
    var n = 0;
    for (final job in jobsOf(mark)) {
      if (!PrWatch.canWatch(job) || prRecordFor(job['repo'], job['branch']) != null) continue;
      final repo = reposOf(conv).where((r) => r.repo == job['repo']).firstOrNull;
      if (repo == null || !repo.allowWrites || !PrWatch.watchOn(repo.prWatch, settings.prWatch)) continue;
      if (prRecords.where((r) => r['stopped'] != true).length >= PrWatch.max) break;
      try {
        if ((await prWatchStart(conv, m, job, auto: true)).isEmpty) n++;
      } catch (_) {}
    }
    return n;
  }

  Future<String> prWatchFix(ChatMessage m) async {
    final conv = current;
    final w = m.prWatch;
    if (conv == null || w == null || w['offer'] != true || w['fixed'] == true) return '';
    final seq = w['seq'];
    final res = await api.prWatchFix(identity.signer, '${w['id']}', seq is num ? seq.toInt() : 0);
    if (res.status != 200 || res.data['ok'] != true) {
      final error = res.data['error'];
      return error is String && error.isNotEmpty ? error : t('The fix could not be started.');
    }
    messages = messages.map((x) => x.id == m.id ? x.copyWith(prWatch: {...w, 'fixed': true}) : x).toList();
    await store.saveMessages(conv.id, messages);
    notifyListeners();
    return t('Nymbot will start a fix run on {branch} in a moment. Its reply lands here.', {'branch': w['branch'] ?? ''});
  }

  Future<int> prWatchRefresh({bool force = false}) async {
    if (!prWatching && !force) return 0;
    if (!identity.present) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _prListedAt < PrWatch.listEvery.inMilliseconds) return 0;
    final running = _prListing;
    if (running != null) return running;
    _prListedAt = now;
    final work = () async {
      final res = await api.prWatchList(identity.signer);
      final list = res.data['watches'];
      if (res.status != 200 || list is! List) return 0;
      return prWatchApply([for (final w in list) if (w is Map) w.cast<String, dynamic>()]);
    }();
    _prListing = work;
    try {
      return await work;
    } catch (_) {
      return 0;
    } finally {
      _prListing = null;
    }
  }

  Future<int> prWatchApply(List<Map<String, dynamic>> watches) async {
    final byId = {for (final w in watches) if (w['id'] is String) w['id'] as String: w};
    final list = prRecords;
    var filed = 0;
    for (final rec in list) {
      final w = byId[rec['id']];
      if (w == null) {
        rec['stopped'] = true;
        prLive.remove(rec['id']);
        continue;
      }
      prLive[rec['id'] as String] = w;
      final conv = _conversationById('${rec['convId']}');
      if (conv == null) continue;
      final seen = rec['seen'] is num ? (rec['seen'] as num).toInt() : 0;
      final origin = rec['msgId'] is String
          ? _messagesOf(conv).where((x) => x.id == rec['msgId']).firstOrNull
          : null;
      for (final ev in PrWatch.fresh(w, seen)) {
        rec['seen'] = ev['seq'];
        final at = ev['at'] is num ? (ev['at'] as num).toInt() : DateTime.now().millisecondsSinceEpoch;
        if (ev['kind'] == 'fix' && ev['eventId'] is String && ev['state'] != 'failed') {
          await _prFileFix(conv, rec, ev);
        } else if ('${ev['text'] ?? ''}'.isNotEmpty) {
          await _addTo(
              conv,
              ChatMessage(
                id: bytesToHex(randomBytes(8)),
                role: ChatRole.bot,
                content: '${ev['text']}',
                prWatch: PrWatch.eventMessage(w, ev),
                at: DateTime.fromMillisecondsSinceEpoch(at),
              ));
        }
        if (origin != null) {
          final stage = PrWatch.stageOf(ev['kind']);
          transcripts.prEvent(conv.id, origin, stage.isEmpty ? '${ev['kind']}' : stage, '${ev['text'] ?? ''}');
        }
        if (conv.id != current?.id) conv.unread += 1;
        filed++;
      }
      final fixSha = '${w['fixSha'] ?? ''}';
      if (fixSha.isNotEmpty && origin != null) await _prMoveHead(conv, origin, rec, fixSha);
      if (w['state'] == 'stopped' || w['pr'] == 'merged' || w['pr'] == 'closed') {
        rec['stopped'] = true;
        if (origin != null && w['pr'] == 'merged') await _prPatchJob(conv, origin, '${rec['branch']}', {'merged': true});
        if (origin != null && w['pr'] == 'closed') await _prPatchJob(conv, origin, '${rec['branch']}', {'closed': true});
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await _savePrRecords([
      for (final r in list)
        if (r['stopped'] != true || now - ((r['at'] as num?)?.toInt() ?? 0) < const Duration(days: 7).inMilliseconds) r,
    ]);
    if (filed > 0) await store.saveConversations(conversations);
    notifyListeners();
    return filed;
  }

  Future<void> _prPatchJob(Conversation conv, ChatMessage m, String branch, Map<String, dynamic> patch) async {
    final next = _messagesOf(conv).map((x) {
      final mark = x.checkpoint;
      if (x.id != m.id || mark == null) return x;
      return x.copyWith(checkpoint: patchJob(mark, branch, patch));
    }).toList();
    if (conv.id == current?.id) messages = next;
    await store.saveMessages(conv.id, next);
  }

  Future<void> _prMoveHead(Conversation conv, ChatMessage m, Map<String, dynamic> rec, String sha) async {
    final job = jobsOf(m.checkpoint).where((j) => j['branch'] == rec['branch']).firstOrNull;
    if (job == null || job['sha'] == sha) return;
    await _prPatchJob(conv, m, '${rec['branch']}', {'sha': sha});
    await rememberBranchStep({'repo': rec['repo'], 'branch': rec['branch'], 'base': job['base'] ?? '', 'sha': sha}, conv: conv);
  }

  Future<void> _prFileFix(Conversation conv, Map<String, dynamic> rec, Map<String, dynamic> ev) async {
    final eventId = '${ev['eventId']}';
    final got = await api.claimRun(identity.signer, eventId);
    if (got.status != 200 || got.data['event'] is! Map) return;
    String? link;
    try {
      final res = await chat.openLeg(conv, eventId, 200, got.data,
          onThreadIds: _threadIdsOf(conv),
          onRumor: (rumor) => link = ChatEngine.linkOf(rumor, got.data).replyTo);
      final wire = link ?? eventId;
      final tag = {'id': rec['id'], 'kind': 'fix', 'seq': ev['seq']};
      await _addTo(
          conv,
          ChatMessage(
            id: bytesToHex(randomBytes(8)),
            role: ChatRole.self,
            content: t('Fix what was reported on pull request #{n}.', {'n': rec['number']}),
            wire: wire,
            prWatch: tag,
          ));
      final shadow = ChatTurn(conv, msgId: wire)..model = modelOf(conv);
      final reply = _replyOf(shadow, res);
      await _addTo(conv, ChatMessage.fromJson({...reply.toJson(), 'prWatch': tag}));
      await harvestArtifacts(reply, conv: conv);
      await _count(conv, res);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> prWatchPeek(Conversation conv, Map<String, dynamic> job) async {
    if (conv.anon || !PrWatch.canWatch(job)) return null;
    final key = PrWatch.keyOf(job['repo'], job['branch']);
    final held = prPeeked[key];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (held != null && now - held.at < PrWatch.peekEvery.inMilliseconds) return held.live;
    final repo = reposOf(conv).where((r) => r.repo == job['repo']).firstOrNull;
    if (repo == null) return null;
    prPeeked[key] = (at: now, live: held?.live);
    final res = await api.prWatchPeek(identity.signer, repo.toPayload(defaultWhenDone: settings.whenDone),
        {'number': PrWatch.pullNo(job), 'branch': job['branch']});
    if (res.status != 200 || res.data['error'] != null) return null;
    prPeeked[key] = (at: DateTime.now().millisecondsSinceEpoch, live: res.data);
    return res.data;
  }

  Future<int> prWatchPeekVisible() async {
    final conv = current;
    if (conv == null || conv.anon || replyNotify.background) return 0;
    var n = 0;
    for (final m in messages) {
      final mark = m.checkpoint;
      if (mark == null) continue;
      for (final job in jobsOf(mark)) {
        if (!PrWatch.canWatch(job) || prRecordFor(job['repo'], job['branch']) != null) continue;
        final before = prPeeked[PrWatch.keyOf(job['repo'], job['branch'])]?.live;
        final live = await prWatchPeek(conv, job);
        if (live != null && jsonEncode(before) != jsonEncode(live)) n++;
      }
    }
    if (n > 0) notifyListeners();
    return n;
  }

  Future<void> prWatchTick() async {
    await prWatchRefresh();
    await prWatchPeekVisible();
  }

  /// Free: touches no model; the token travels only with this request.
  Future<List<Map<String, dynamic>>> revertCheckpoint(ChatMessage m) async {
    final conv = current;
    final marks = undoMarks(m.checkpoint);
    if (marks.isEmpty || conv == null) {
      throw ChatFailure(t('There is nothing recorded to put back.'));
    }
    final rows = await _revertMarks(conv, marks);
    bool clean(Map<String, dynamic> r) =>
        r['error'] == null && ((r['failed'] as List?)?.isEmpty ?? true);
    messages = messages.map((x) {
      final mark = x.checkpoint;
      if (x.id != m.id || mark == null) return x;
      return x.copyWith(
          checkpoint: patchMarks(mark, (y) {
        final hit = rows.where((r) =>
            r['repo'] == y['repo'] && '${r['branch'] ?? ''}' == '${y['branch'] ?? ''}');
        return hit.isNotEmpty && clean(hit.first) ? {...y, 'undone': true} : y;
      }));
    }).toList();
    await store.saveMessages(conv.id, messages);
    notifyListeners();
    return rows;
  }

  Future<List<Map<String, dynamic>>> _revertMarks(
      Conversation conv, List<Map<String, dynamic>> marks) async {
    final scoped = reposOf(conv);
    final rows = <Map<String, dynamic>>[];
    final sent = <(GitRepo, Map<String, dynamic>)>[];
    final at = <int>[];
    for (final mark in marks) {
      final row = <String, dynamic>{'repo': mark['repo'], 'branch': mark['branch'] ?? ''};
      rows.add(row);
      final repo = scoped.where((r) => r.repo == mark['repo']).firstOrNull;
      if (repo == null) {
        row['error'] = t('That repository is no longer connected.');
      } else if (!repo.allowWrites) {
        row['error'] = t('Writes are off for that repository.');
      } else {
        sent.add((repo, mark));
        at.add(rows.length - 1);
      }
    }
    if (sent.isEmpty) return rows;
    final signer =
        conv.anon ? await anon.signer(pk: conv.anonPk) : identity.signer;
    final got = await chat.revertMarks(marks: sent, signer: signer);
    for (var i = 0; i < at.length; i++) {
      final r = got[i];
      rows[at[i]].addAll({
        'restored': r['restored'] ?? const [],
        'deleted': r['deleted'] ?? const [],
        'failed': r['failed'] ?? const [],
        if (r['error'] != null) 'error': '${r['error']}',
      });
    }
    return rows;
  }

  Future<String> closeRecordedPull(ChatMessage m, Map<String, dynamic> pr) async {
    final conv = current;
    if (conv == null) return '';
    final repo = activeRepos.where((r) => r.repo == pr['repo']).firstOrNull;
    if (repo == null) return t('That repository is no longer connected.');
    if (!repo.allowWrites) return t('Writes are off for that repository.');
    final number = pr['number'];
    final signer =
        conv.anon ? await anon.signer(pk: conv.anonPk) : identity.signer;
    Map<String, dynamic> data;
    try {
      data = await chat.branchOp(
          repo: repo,
          op: 'close',
          job: {
            'branch': pr['branch'],
            'sha': '',
            'pull': {'number': number},
          },
          signer: signer);
    } catch (e) {
      return t('The forge could not be reached.');
    }
    Future<void> mark(String key) async {
      messages = messages.map((x) {
        final cp = x.checkpoint;
        if (x.id != m.id || cp == null) return x;
        return x.copyWith(
            checkpoint: patchMarks(cp, (y) {
          if (y['repo'] != pr['repo'] || y['prs'] is! List) return y;
          return {
            ...y,
            'prs': [
              for (final p in y['prs'] as List)
                if (p is Map && pullNumberOf(p) == number)
                  {...p.cast<String, dynamic>(), key: true}
                else
                  p,
            ],
          };
        }));
      }).toList();
      await store.saveMessages(conv.id, messages);
      notifyListeners();
    }

    if (data['merged'] == true) {
      await mark('merged');
      return '${data['error'] ?? ''}';
    }
    if (data['error'] != null) return '${data['error']}';
    await mark('closed');
    return t('Closed pull request #{n}.', {'n': number});
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
        final signer =
            conv.anon ? await anon.signer(pk: conv.anonPk) : identity.signer;
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

  Future<String?> _ownerOf(Conversation conv) async =>
      conv.anon ? (await anon.identityFor(conv.anonPk))['pk'] as String? : null;

  Future<int> rememberBranches(
      Conversation conv, Map<String, dynamic> mark) async {
    final jobs = jobsOf(mark);
    if (jobs.isEmpty) return 0;
    final scoped = reposOf(conv);
    final owner = await _ownerOf(conv);
    var n = 0;
    for (final job in jobs) {
      final repo = scoped.where((r) => r.repo == job['repo']).firstOrNull;
      final sha = job['sha'];
      if (repo == null || sha is! String || sha.isEmpty) continue;
      repo.nymBranches = rememberBranch(repo.nymBranches, {...job, 'owner': owner});
      n++;
    }
    if (n > 0) await store.saveRepos(repos);
    return n;
  }

  Future<bool> rememberBranchStep(Map<String, dynamic> step,
      {Conversation? conv, String? owner}) async {
    final found = branchStepsOf([step]);
    if (found.isEmpty) return false;
    final b = found.single;
    final pool = conv == null ? repos : reposOf(conv);
    final repo =
        pool.where((r) => r.repo == b['repo'] && r.allowWrites).firstOrNull;
    if (repo == null) return false;
    final had =
        repo.nymBranches.where((r) => r['branch'] == b['branch']).firstOrNull;
    if (had != null && had['sha'] == b['sha']) return false;
    final by = conv != null ? await _ownerOf(conv) : owner;
    repo.nymBranches = rememberBranch(repo.nymBranches, {
      'branch': b['branch'],
      'base': '${b['base']}'.isNotEmpty ? b['base'] : (had?['base'] ?? ''),
      'sha': b['sha'],
      'pull': had?['pull'],
      'owner': by,
    }, now: (had?['at'] as num?)?.toInt());
    await store.saveRepos(repos);
    return true;
  }

  Future<void> noteBranchSteps(
      ChatTurn turn, List<Map<String, dynamic>> raw) async {
    final found = branchStepsOf(
        raw.where((s) => s['kind'] == 'branch'));
    if (found.isEmpty) return;
    turn.branches = branchStepsOf([...turn.branches, ...found]);
    for (final b in found) {
      await rememberBranchStep(b, conv: turn.conv);
    }
    notifyListeners();
  }

  Future<void> _patchJob(
      ChatMessage m, String branch, Map<String, dynamic> patch) async {
    final conv = current;
    if (conv == null) return;
    messages = messages.map((x) {
      final mark = x.checkpoint;
      if (x.id != m.id || mark == null) return x;
      return x.copyWith(checkpoint: patchJob(mark, branch, patch));
    }).toList();
    await store.saveMessages(conv.id, messages);
    notifyListeners();
  }

  Future<String> branchAction(
      ChatMessage m, Map<String, dynamic> job, String op) async {
    final conv = current;
    final branch = '${job['branch'] ?? ''}';
    final base = '${job['base'] ?? ''}';
    if (conv == null) return '';
    final repo = activeRepos.where((r) => r.repo == job['repo']).firstOrNull;
    if (repo == null) return t('That repository is no longer connected.');
    if (!repo.allowWrites) return t('Writes are off for that repository.');
    final signer =
        conv.anon ? await anon.signer(pk: conv.anonPk) : identity.signer;
    Map<String, dynamic> data;
    try {
      data = await chat.branchOp(repo: repo, op: op, job: job, signer: signer);
    } catch (e) {
      return t('The forge could not be reached.');
    }
    final pullNo = pullNumberOf(job['pull']);
    if (op == 'close' || op == 'revert-pr') {
      if (op == 'close' && data['merged'] == true) {
        await _patchJob(m, branch, {'merged': true});
        return '${data['error'] ?? ''}';
      }
      if (data['moved'] == true && data['error'] == null) {
        return t('The branch has new commits since Nymbot made it, so it was left alone.');
      }
      if (data['error'] != null) return '${data['error']}';
      if (op == 'close') {
        await _patchJob(m, branch, {'closed': true});
        return data['already'] == true
            ? t('Pull request #{n} was already closed.', {'n': pullNo})
            : t('Closed pull request #{n}.', {'n': pullNo});
      }
      final pull = data['pull'];
      await _patchJob(m, branch, {
        'reverted': {
          'branch': '${data['branch'] ?? ''}',
          'base': '${data['base'] ?? ''}',
          'sha': '${data['sha'] ?? ''}',
          'pull': pull is Map ? pull : null,
        },
      });
      if (isJobBranch(data['branch'])) {
        repo.nymBranches = rememberBranch(repo.nymBranches, {
          'branch': data['branch'],
          'base': data['base'] ?? '',
          'sha': data['sha'] ?? '',
          'pull': pull,
          'owner': await _ownerOf(conv),
        });
        await store.saveRepos(repos);
      }
      return t('Opened pull request #{n} to revert the merge, on {branch}.',
          {'n': pull is Map ? pull['number'] : '', 'branch': data['branch']});
    }
    if (data['conflict'] == true) {
      await _patchJob(m, branch, {'conflict': true, 'pull': data['pull'] ?? job['pull']});
      return t('This branch conflicts with {base}. Open the PR to resolve it, or ask Nymbot to update the branch.',
          {'base': base});
    }
    if (data['gone'] == true && data['deleted'] != true) {
      await _patchJob(m, branch, {'deleted': true});
      repo.nymBranches = forgetBranches(repo.nymBranches, [branch]);
      await store.saveRepos(repos);
      return t('That branch is already gone.');
    }
    if (data['moved'] == true) {
      return t('The branch has new commits since Nymbot made it, so it was left alone.');
    }
    if (data['unsupported'] == true) {
      return op == 'update'
          ? t('This forge cannot update the branch without rebasing. Open the PR to update it.')
          : t('This forge has no pull request API Nymbot can use, so the branch was left as it is.');
    }
    if (data['error'] != null) return '${data['error']}';
    switch (op) {
      case 'pr':
        await _patchJob(m, branch, {
          'pull': data['pull'] ?? job['pull'],
          if (data['merged'] == true) 'merged': true,
        });
        if (data['pull'] is Map) {
          repo.nymBranches = [
            for (final r in repo.nymBranches)
              r['branch'] == branch ? {...r, 'pull': data['pull']} : r,
          ];
          await store.saveRepos(repos);
        }
        return '';
      case 'merge':
        await _patchJob(m, branch, {
          'merged': true,
          'conflict': false,
          'pull': data['pull'] ?? job['pull'],
        });
        return t('Merged {branch} into {base}.', {'branch': branch, 'base': base});
      case 'update':
        final sha = data['sha'] is String ? data['sha'] as String : job['sha'];
        await _patchJob(m, branch, {'conflict': false, 'sha': sha});
        repo.nymBranches = rememberBranch(
            repo.nymBranches, {...job, 'sha': sha, 'owner': await _ownerOf(conv)});
        await store.saveRepos(repos);
        return data['upToDate'] == true
            ? t('{branch} already has everything from {base}.',
                {'branch': branch, 'base': base})
            : t('Updated {branch} with a merge commit from {base}.',
                {'branch': branch, 'base': base});
      default:
        await _patchJob(m, branch, {'deleted': true});
        repo.nymBranches = forgetBranches(repo.nymBranches, [branch]);
        await store.saveRepos(repos);
        return t('Deleted {branch}.', {'branch': branch});
    }
  }

  static String? _branchOwner(Map<String, dynamic> r) {
    final v = r['owner'];
    return v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v) ? v : null;
  }

  Future<String> cleanupRepoBranches(GitRepo repo,
      {bool any = true, String? owner}) async {
    if (!repo.allowWrites || repo.token.isEmpty || repo.nymBranches.isEmpty) {
      return t('No Nymbot branches were ready to clean up.');
    }
    final groups = <String?, List<Map<String, dynamic>>>{};
    for (final r in repo.nymBranches) {
      final by = _branchOwner(r);
      if (!any && by != owner) continue;
      (groups[by] ??= []).add(r);
    }
    var done = 0;
    var landed = 0;
    String? failure;
    var sent = 0;
    for (final entry in groups.entries) {
      final id = entry.key == null ? null : anon.heldFor(entry.key);
      if (entry.key != null && id == null) continue;
      if (sent++ > 0) await Jitter.wait();
      try {
        final data = await chat.cleanupBranches(
            repo: repo,
            branches: entry.value,
            signer: id == null ? identity.signer : anon.signerOf(id));
        final gone = [
          ...(data['deleted'] as List? ?? const []),
          ...(data['gone'] as List? ?? const []),
        ];
        landed++;
        if (gone.isNotEmpty) {
          done += gone.length;
          repo.nymBranches = forgetBranches(repo.nymBranches, gone);
          await store.saveRepos(repos);
          notifyListeners();
        }
      } catch (e) {
        failure ??= e is ChatFailure ? e.message : t('The forge could not be reached.');
      }
    }
    if (failure != null && landed == 0) return failure;
    return done == 0
        ? t('No Nymbot branches were ready to clean up.')
        : t('Cleaned up {n} Nymbot branches.', {'n': done});
  }

  final Map<String, int> _cleanedAt = {};

  void cleanupSoon(Conversation conv) {
    unawaited(() async {
      final owner = await _ownerOf(conv);
      if (conv.anon && owner == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final repo in reposOf(conv)) {
        if (!repo.allowWrites ||
            !repo.nymBranches.any((r) => _branchOwner(r) == owner)) {
          continue;
        }
        final key = '${repo.id}:${owner ?? ''}';
        if (now - (_cleanedAt[key] ?? 0) < branchCleanupEvery.inMilliseconds) {
          continue;
        }
        _cleanedAt[key] = now;
        await cleanupRepoBranches(repo, any: false, owner: owner);
      }
    }());
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

  /// Saves found facts and returns them so the caller can offer an undo.
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

  // Session

  /// Called once a key exists; `enter` does the rest.
  void signIn() {
    signedIn = true;
    notifyListeners();
  }

  /// Asks D1 first, then relay announcements; [read] false means neither answered, not "no root".
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

  /// Re-asked every launch, since an unreachable worker settles nothing.
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
      // Sign-in deferred minting; the account turns out to have no root, so mint now.
      await mintAndRecordRoot();
      await note(t('Your post-quantum recovery code is ready. Open Identity to '
          'save it — nobody can reissue it.'));
      return;
    }
    if (held.isEmpty) {
      identity.rootLocked = true;
      return;
    }
    // An unreadable row still proves a root exists; only a matching fingerprint proves it is ours.
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
    sync.forget();
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
    sync.forget();
    try {
      await pq.announceRoot(identity.signer, identity, force: true);
    } catch (_) {}
    unawaited(sync.run().then((_) => notifyListeners()));
    notifyListeners();
    return true;
  }

  /// Mints and records the root so other devices ask for the code instead of minting a rival.
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
    // Before anything is drawn.
    await sweepOldChats();
    await openStartingChat();
    notifyListeners();
    unawaited(replyNotify.attach());
    _startSupport();

    sync.onChange = _afterSync;
    sync.follow();
    unawaited(sync.run().then((round) {
      if (round.isOk || round.state == 'blocked') notifyListeners();
    }));
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(sync.run());
      if (settings.serverSchedules) unawaited(refreshServerSchedules());
    });
    unawaited(refreshNotices());
    unawaited(refreshRunner());
    _noticeTimer = Timer.periodic(
        const Duration(minutes: 15), (_) => unawaited(refreshNotices()));

    // PQ setup does not block the first message; held so a wipe or dispose can cancel it.
    _bootWork = Timer(const Duration(milliseconds: 400), () async {
      // The mirror answers in one round trip without a relay, so name and avatar draw first.
      await profiles.load(identity.pubkey, mirrorOnly: true);
      notifyListeners();
      try {
        await pq.resolveBot();
      } catch (_) {}
      try {
        await settleRoot();
      } catch (_) {}
      // A locked device's root is not the account's, so announcing would strand every device.
      if (identity.kem != null && !identity.rootLocked) {
        try {
          identity.rootLocked =
              await pq.announceRoot(identity.signer, identity) == null;
        } catch (_) {}
      }
      await refreshBalance();
      await resumeInvoice();
      await anon.flush(identity: identity.signer);
      unawaited(resumeClaims());
      unawaited(refreshRuns());
      unawaited(syncChecks());
      _loadBackground();
      if (backgroundRuns.isNotEmpty) unawaited(pollBackground());
      if (settings.serverSchedules) unawaited(refreshServerSchedules());
      if (conversations.any((c) => pendingIn(c).isNotEmpty)) _watchPending();
      startScheduler();
      await runDueSchedules();
      await autoTopUp();
      // Whatever the mirror lacked; a no-op otherwise.
      await profiles.load(identity.pubkey);
      notifyListeners();
    });
  }

  void _afterSync(List<String> touched) {
    if (touched.contains('settings')) {
      _loadSettings();
      unawaited(syncChecks());
    }
    if (touched.contains('repos')) unawaited(_loadRepos());
    if (touched.contains('connectors')) unawaited(_loadConnectors());
    if (touched.contains('skills')) unawaited(_loadSkills());
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
    if (touched.contains('anonKeys') || touched.contains('chats')) {
      unawaited(refreshBalance());
    }
    final open = current;
    if (open != null && touched.contains('chat-${open.id}')) {
      messages = store.messages(open.id);
    }
    if (open != null && touched.contains('arts-${open.id}')) {
      artifacts = store.artifacts(open.id);
    }
    if (touched.contains('chat-$kSupportChatId')) _supportSeen = null;
    _startSupport(restart: touched.contains('supportTokens'));
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_gone) return;
    for (final turn in [...turns.values]) {
      transcripts.observe(turn, asked: () => _askedText(turn));
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    _gone = true;
    transcripts.dispose();
    _pendingTimer?.cancel();
    _runsTimer?.cancel();
    _runsSettle?.cancel();
    _farTimer?.cancel();
    _bgTimer?.cancel();
    for (final turn in turns.values) {
      turn.control.cancel();
    }
    _stopSupport();
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

  // Conversations

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

  static const _viewChatKey = 'view_chat';

  Future<void> openStartingChat() async {
    final id = store.getString(_viewChatKey);
    final remembered = id == null ? null : _conversationById(id);
    if (remembered != null) {
      await open(remembered);
      return;
    }
    final live = conversations.where((c) => !c.archived).toList();
    if (live.isEmpty) {
      await newConversation();
    } else {
      await open(live.first);
    }
  }

  Future<void> open(Conversation conv) async {
    current = conv;
    if (conv.anon &&
        _anonShownFor != null &&
        shownAnonPk != _anonShownFor) {
      anonStandardBalance = null;
      anonProBalance = null;
      unawaited(refreshBalance());
    }
    replyNotify.viewingChat(conv.id);
    messages = store.messages(conv.id);
    artifacts = store.artifacts(conv.id);
    attachments = [];
    quote = null;
    if (conv.unread > 0) {
      conv.unread = 0;
      await store.saveConversations(conversations);
    }
    notifyListeners();
    await store.setString(_viewChatKey, conv.id);
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

  Future<({({String name, String type, Uint8List bytes})? file, String error})> renderArtifactFile(
      Artifact artifact, String format, String body) async {
    final conv = current;
    if (conv == null || (format != 'pdf' && format != 'docx')) return (file: null, error: '');
    if (body.trim().isEmpty) return (file: null, error: t('This artifact is empty.'));
    final res = await api.call('file-render', await _signerOf(conv),
        extra: {'format': format, 'title': artifact.title, 'lang': artifact.lang, 'body': body},
        timeout: const Duration(seconds: 60));
    final file = res.status == 200 ? BotFiles.decodeRendered(res.data) : null;
    if (file == null) return (file: null, error: '${res.data['error'] ?? t('That could not be converted.')}');
    return (file: file, error: '');
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

  /// An optional target lets the sidebar act on a chat without opening it.
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
    transcripts.forget(conv.id);
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
      anonPk: conv.anonPk,
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

  /// Copies the chat up to a point onto a new thread, with its whole setup; the original is untouched.
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
      anonPk: conv.anonPk,
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
    // Artifacts from the kept messages come along too.
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

  /// Branch with everything before [message] and the question replaced.
  Future<Conversation> branchBefore(ChatMessage message) async {
    final at = messages.indexWhere((m) => m.id == message.id);
    return branchFrom(messages.sublist(0, at < 0 ? 0 : at));
  }

  Future<Conversation> forkForEdit(ChatMessage message) async {
    final parent = current!;
    final thread = parent.rootId;
    final copy = await branchBefore(message);
    final before = message.wire;
    if (before != null && before.isNotEmpty) {
      copy.forkOf = {'thread': thread, 'before': before};
      copy.seed = null;
      await store.saveConversations(conversations);
    }
    return copy;
  }

  /// A fresh root id resets the model's context, since the worker scopes history to it.
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

  static int placeAt(List<ChatMessage> list, String? link) {
    if (link == null || link.isEmpty) return list.length;
    final ask = list.lastIndexWhere((x) => x.role == ChatRole.self && x.wire == link);
    if (ask == -1) {
      final last = list.lastIndexWhere((x) => x.replyTo == link);
      return last == -1 ? list.length : last + 1;
    }
    var at = ask + 1;
    while (at < list.length &&
        list[at].role != ChatRole.self &&
        list[at].replyTo == link) {
      at++;
    }
    return at;
  }

  Future<void> _addTo(Conversation conv, ChatMessage m) async {
    if (m.checkpoint != null) await rememberBranches(conv, m.checkpoint!);
    final list = _messagesOf(conv);
    final at = placeAt(list, m.replyTo);
    final next = [...list]..insert(at, m);
    if (conv.id == current?.id) messages = next;
    await store.saveMessages(conv.id, next);
    notifyListeners();
  }

  Future<void> note(String text, {Conversation? conv, String? replyTo}) =>
      _addTo(conv ?? current!, ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.note,
        content: text,
        replyTo: replyTo,
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

  List<RewindItem> rewindEffects(ChatMessage m) =>
      Rewind.effects(Rewind.after(messages, m.id));

  Future<RewindOutcome?> rewindTo(ChatMessage m, Set<String> picked) async {
    final conv = current;
    if (conv == null || sendingIn(conv)) return null;
    final dropped = Rewind.after(messages, m.id);
    if (dropped.isEmpty) return null;
    final items = Rewind.effects(dropped);
    final before = _snapshot(conv);
    await truncateFrom(m, inclusive: false);
    final results = await Rewind.run(
      Rewind.plan(items, picked),
      revert: (item) => _rewindRevert(conv, item),
      deleteBranch: (item) => _rewindBranch(conv, item),
      closePull: (item) => _rewindPullOp(conv, item, 'close'),
      revertPull: (item) => _rewindPullOp(conv, item, 'revert-pr'),
    );
    final ChatSnapshot snap = (
      conv: before.conv,
      rootId: before.rootId,
      seed: before.seed,
      messageCount: before.messageCount,
      creditsSpent: before.creditsSpent,
      satsSpent: before.satsSpent,
      messages: Rewind.settled(before.messages, results),
      thread: before.thread,
    );
    return (
      snapshot: snap,
      convId: conv.id,
      ids: [for (final d in dropped) d.id],
      results: results,
    );
  }

  Future<void> commitRewind(RewindOutcome done) async {
    final gone = done.ids.toSet();
    final conv = conversations.where((c) => c.id == done.convId).firstOrNull;
    if (conv != null) {
      final held = _messagesOf(conv);
      if (held.any((x) => gone.contains(x.id))) {
        final kept = held.where((x) => !gone.contains(x.id)).toList();
        if (conv.id == current?.id) messages = kept;
        await store.saveMessages(conv.id, kept);
      }
    }
    for (final id in done.ids) {
      await store.bury(id);
    }
    notifyListeners();
  }

  Future<void> _rewindRevert(Conversation conv, RewindItem item) async {
    final mark = item.mark;
    if (mark == null) throw RewindRefused(t('There is nothing recorded to put back.'));
    final rows = await _revertMarks(conv, [mark]);
    final r = rows.single;
    if (r['error'] != null) throw RewindRefused('${r['error']}');
    final failed = (r['failed'] as List?)?.length ?? 0;
    if (failed > 0) {
      final done = ((r['restored'] as List?)?.length ?? 0) +
          ((r['deleted'] as List?)?.length ?? 0);
      throw RewindRefused(t('Put {done} back; {failed} could not be. Check the repository.',
          {'done': done, 'failed': failed}));
    }
  }

  Future<Map<String, dynamic>> _rewindPullOp(
      Conversation conv, RewindItem item, String op) async {
    final repo = reposOf(conv).where((r) => r.repo == item.repo).firstOrNull;
    if (repo == null) throw RewindRefused(t('That repository is no longer connected.'));
    if (!repo.allowWrites) throw RewindRefused(t('Writes are off for that repository.'));
    final signer =
        conv.anon ? await anon.signer(pk: conv.anonPk) : identity.signer;
    final data = await chat.branchOp(
        repo: repo,
        op: op,
        job: {
          'branch': item.branch,
          'base': item.base,
          'sha': item.sha,
          'pull': {'number': item.number},
        },
        signer: signer);
    if (data['error'] != null) {
      throw RewindRefused('${data['error']}', moved: data['moved'] == true);
    }
    if (op == 'revert-pr' && isJobBranch(data['branch'])) {
      repo.nymBranches = rememberBranch(repo.nymBranches, {
        'branch': data['branch'],
        'base': data['base'] ?? '',
        'sha': data['sha'] ?? '',
        'pull': data['pull'],
        'owner': await _ownerOf(conv),
      });
      await store.saveRepos(repos);
    }
    return data;
  }

  Future<void> _rewindBranch(Conversation conv, RewindItem item) async {
    final job = item.job;
    if (job == null) throw RewindRefused(t('No commit was recorded for it, so it is left alone.'));
    final repo = reposOf(conv).where((r) => r.repo == item.repo).firstOrNull;
    if (repo == null) throw RewindRefused(t('That repository is no longer connected.'));
    if (!repo.allowWrites) throw RewindRefused(t('Writes are off for that repository.'));
    final signer =
        conv.anon ? await anon.signer(pk: conv.anonPk) : identity.signer;
    final data = await chat.branchOp(repo: repo, op: 'delete', job: job, signer: signer);
    if (data['moved'] == true) {
      throw RewindRefused(
          t('The branch has new commits since Nymbot made it, so it was left alone.'),
          moved: true);
    }
    if (data['error'] != null && data['gone'] != true) {
      throw RewindRefused('${data['error']}');
    }
    repo.nymBranches = forgetBranches(repo.nymBranches, [item.branch]);
    await store.saveRepos(repos);
    if (data['gone'] == true && data['deleted'] != true) {
      throw RewindRefused(t('That branch is already gone.'), gone: true);
    }
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

  /// Uploads so the worker can fetch the image itself.
  Future<void> uploadAttachment(Attachment a) async {
    if (!a.uploads) return;
    if (a.url != null || a.uploading) return;
    final Uint8List data;
    if (a.kind == AttachmentKind.video) {
      final held = a.bytes;
      if (held == null || held.isEmpty) return;
      data = held;
    } else {
      final raw = a.bytesBase64;
      if (raw == null || raw.isEmpty) return;
      data = base64Decode(raw);
    }
    a.uploading = true;
    a.uploadError = null;
    notifyListeners();
    try {
      final placed = await blossom.placeUnlinked(data, a.mime);
      a.url = placed.url;
      a.bytes = null;
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

  /// Waits for pending uploads before the message goes.
  Future<List<Attachment>> settleAttachments(List<Attachment> list) async {
    await Future.wait(list.map(uploadAttachment));
    return list
        .where((a) => a.uploads && a.url == null)
        .toList();
  }

  // Sending

  int get runLimit {
    final n = settings.maxRuns;
    return n >= 1 && n <= 10 ? n : 3;
  }

  Future<void> setMaxRuns(int n) async {
    settings.maxRuns = n.clamp(1, 10);
    await store.saveSettings(settings);
    notifyListeners();
    _wakeSlots();
  }

  Map<String, String> policyOf(Conversation? conv) {
    final own = conv?.policy ?? const <String, String>{};
    final alone = conv?.anon ?? false;
    return {
      'readOnlyTools': own['readOnlyTools'] ?? (alone ? 'ask' : settings.readOnlyTools),
      'serverRuns': own['serverRuns'] ?? (alone ? 'ask' : settings.serverRunPolicy),
      'planFirst': own['planFirst'] ?? (alone ? 'changing' : settings.planFirst),
    };
  }

  Future<void> setPolicy({String? readOnlyTools, String? serverRuns, String? planFirst}) async {
    if (readOnlyTools == 'allow' || readOnlyTools == 'ask') {
      settings.readOnlyTools = readOnlyTools!;
    }
    if (serverRuns == 'allow' || serverRuns == 'ask') {
      settings.serverRunPolicy = serverRuns!;
    }
    if (planFirst == 'always' || planFirst == 'changing' || planFirst == 'never') {
      settings.planFirst = planFirst!;
    }
    await store.saveSettings(settings);
    notifyListeners();
  }

  Future<void> setChatPolicy(Conversation conv,
      {String? readOnlyTools, String? serverRuns, String? planFirst}) async {
    final next = {...?conv.policy};
    void put(String key, String? value) {
      if (value == 'allow' || value == 'ask') next[key] = value!;
      if (value == 'default') next.remove(key);
    }

    put('readOnlyTools', readOnlyTools);
    put('serverRuns', serverRuns);
    if (planFirst == 'always' || planFirst == 'changing' || planFirst == 'never') next['planFirst'] = planFirst!;
    if (planFirst == 'default') next.remove('planFirst');
    conv.policy = next.isEmpty ? null : next;
    _touch(conv);
    await store.saveConversations(conversations);
    notifyListeners();
  }

  Map<String, dynamic> _runExtras(Conversation conv, {String? kind}) => {
        if (settings.maxRuns > 0 && !conv.anon) 'maxRuns': settings.maxRuns,
        'policy': policyOf(conv),
        'runKind': ?kind,
      };

  static String _labelOf(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > 80 ? flat.substring(0, 80) : flat;
  }

  final Set<String> _starting = {};
  final List<Completer<void>> _endWaiters = [];
  final Map<String, ChatTurn> _parked = {};
  Timer? _pendingTimer;
  bool _flushing = false;

  int get _slotsUsed => turns.values.where((t) => t.holdsSlot).length;

  Future<void> _takeSlot(ChatTurn turn, {bool force = false}) async {
    if (turn.holdsSlot) return;
    bool ahead() => turns.values.any((o) =>
        !identical(o, turn) &&
        o.slotWait != null &&
        o.began.isBefore(turn.began));
    while (!force && !turn.stopped && (_slotsUsed >= runLimit || ahead())) {
      turn.phase = 'slot';
      turn.status = t('Waiting for a free slot');
      notifyListeners();
      final wait = turn.slotWait = Completer<void>();
      await wait.future;
    }
    turn.slotWait = null;
    if (turn.stopped) throw ChatFailure(t('Stopped.'), cancelled: true);
    turn.holdsSlot = true;
    turn.phase = 'running';
    if (turn.status == t('Waiting for a free slot')) turn.status = null;
    notifyListeners();
  }

  void _wakeSlots() {
    final waiting = turns.values.where((t) => t.slotWait != null).toList()
      ..sort((a, b) => a.began.compareTo(b.began));
    var free = runLimit - _slotsUsed;
    for (final w in waiting) {
      if (free-- <= 0) break;
      final gate = w.slotWait;
      w.slotWait = null;
      if (gate != null && !gate.isCompleted) gate.complete();
    }
  }

  void _dropRun(ChatTurn turn) {
    turns.removeWhere((_, v) => identical(v, turn));
    if (turn.holdsSlot) {
      turn.holdsSlot = false;
      _wakeSlots();
    }
    notifyListeners();
  }

  void stop({Conversation? target}) {
    final conv = target ?? current;
    if (conv == null) return;
    for (final turn in runsIn(conv)) {
      unawaited(stopRun(turn));
    }
    notifyListeners();
  }

  Future<EventSigner> _signerOf(Conversation conv) async =>
      conv.anon ? await anon.signer(pk: conv.anonPk) : identity.signer;

  Future<void> stopRun(ChatTurn turn) async {
    if (turn.stopped) return;
    turn.stopped = true;
    final told = turn.sent && turn.runId.isNotEmpty;
    turn.control.cancel();
    final gate = turn.slotWait;
    turn.slotWait = null;
    if (gate != null && !gate.isCompleted) gate.complete();
    _stopWatching(turn);
    turn.status = null;
    turn.draft = null;
    unawaited(_dropClaim(turn));
    if (turn.askId != null) {
      await note(t('Stopped.'), conv: turn.conv, replyTo: _linkOf(turn));
    }
    _endTurn(turn);
    if (!told) return;
    final prepared = turn.prepared;
    if (prepared != null) {
      unawaited(_keepStoppedBranches(turn.conv, prepared).catchError((_) {}));
    }
    try {
      final signer = turn.prepared?.signer ?? await _signerOf(turn.conv);
      final res = await api.cancelRun(signer, turn.runId);
      if (res.status == 200) unawaited(refreshBalance());
    } catch (_) {}
  }

  @visibleForTesting
  static Duration stoppedBranchWait = const Duration(minutes: 2);

  Future<void> _keepStoppedBranches(
      Conversation conv, PreparedTurn prepared) async {
    if (!reposOf(conv).any((r) => r.allowWrites && r.jobBranches)) return;
    final until = DateTime.now().add(stoppedBranchWait);
    var i = 0;
    while (!_gone && DateTime.now().isBefore(until)) {
      final step = claimBackoff[math.min(i++, claimBackoff.length - 1)];
      await Future<void>.delayed(step + Jitter.next(step ~/ 4));
      if (_gone || !DateTime.now().isBefore(until)) return;
      final res = await api.claimRun(prepared.signer, prepared.eventId);
      final data = res.data;
      if (res.status == 0 || res.status == 202 || data['pending'] == true) {
        continue;
      }
      if (res.status != 200 || data['unknown'] == true) return;
      final mark = data['checkpoint'];
      if (mark is Map<String, dynamic>) {
        await rememberBranches(_conversationById(conv.id) ?? conv, mark);
      }
      return;
    }
  }

  String? _linkOf(ChatTurn turn) {
    final id = turn.runId;
    return id.isEmpty ? null : id;
  }

  void _endTurn(ChatTurn turn) {
    final ended = turns.values.any((v) => identical(v, turn));
    if (ended) _settleRun(turn);
    turns.removeWhere((_, v) => identical(v, turn));
    if (turn.holdsSlot) turn.holdsSlot = false;
    _wakeSlots();
    if (ended) {
      final waiters = [..._endWaiters];
      _endWaiters.clear();
      for (final w in waiters) {
        if (!w.isCompleted) w.complete();
      }
    }
    unawaited(_keepTasks(turn));
    transcripts.finish(turn, _messagesOf(turn.conv));
    if (ended) {
      final link = _linkOf(turn);
      final list = _messagesOf(turn.conv);
      final replied = link == null
          ? list.lastWhere((m) => m.role != ChatRole.note,
                  orElse: () => ChatMessage(id: '', role: ChatRole.note, content: ''))
              .role ==
              ChatRole.bot
          : list.any((m) => m.role == ChatRole.bot && m.replyTo == link);
      final carried = turn.outcome == 'background';
      unawaited(replyNotify.settled(turn.conv.id,
          replied: replied,
          run: turn.key,
          asked: link,
          stopped: (turn.stopped && turn.outcome != 'stopped') || carried,
          state: turn.outcome ?? (replied ? 'done' : 'failed')));
      if (!carried && link != null && _checksWanted) {
        unawaited(DoneSince.markSeen(store, [link]));
      }
    }
    turn.status = null;
    notifyListeners();
  }

  LiveTasks? liveTasks(Conversation? conv) {
    final turn = turnOf(conv);
    return turn == null ? null : liveTasksOf(turn);
  }

  LiveTasks liveTasksOf(ChatTurn turn) => (
        steps: turn.log,
        team: turn.team,
        research: turn.research != null,
        label: turn.status ?? turn.progress ?? t('Nymbot is thinking'),
      );

  Future<void> _keepTasks(ChatTurn turn) async {
    if (turn.kept) return;
    turn.kept = true;
    if (turn.log.isEmpty &&
        turn.team == null &&
        turn.research == null &&
        turn.plan.isEmpty) {
      return;
    }
    final conv = turn.conv;
    final list = _messagesOf(conv);
    final hit = turn.askId == null
        ? Tasks.target(list, turn.began)
        : Tasks.targetFor(list, turn.askId!, _linkOf(turn));
    if (hit == null) return;
    final rec = Tasks.record(
        (steps: turn.log, team: turn.team, research: turn.research != null, label: ''),
        turn.stopped ? 'stopped' : (hit['bot'] == true ? 'done' : 'failed'),
        plan: turn.plan);
    if (rec == null) return;
    final now = _messagesOf(conv);
    final next = [for (final m in now) m.id == hit['id'] ? m.copyWith(tasks: rec) : m];
    if (conv.id == current?.id) messages = next;
    notifyListeners();
    await store.saveMessages(conv.id, next);
  }

  void Function(List<String> ids) _threadIdsOf(Conversation conv) => (ids) {
        final thread = [...store.thread(conv.id), ...ids];
        unawaited(store.setThread(conv.id, thread));
      };

  Future<TurnResult> _deliver(ChatTurn turn, {Duration? timeout}) async {
    turn.sent = true;
    turn.phase = 'running';
    notifyListeners();
    await _keepClaim(turn);
    try {
      final res = await chat.deliver(turn.prepared!,
          timeout: timeout,
          control: turn.control,
          onThreadIds: _threadIdsOf(turn.conv));
      if (!_gone) await _dropClaim(turn);
      return res;
    } on ChatFailure catch (e) {
      if (!_gone && (!(e.pending || e.lost) || (e.lost && e.offline))) {
        await _dropClaim(turn);
      }
      rethrow;
    } catch (_) {
      if (!_gone) await _dropClaim(turn);
      rethrow;
    }
  }

  ChatMessage _replyOf(ChatTurn turn, TurnResult res) {
    final model = turn.model;
    return ChatMessage(
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
      staged: res.staged,
      repos: res.repos.length > 1 ? res.repos : const [],
      sources: res.sources,
      followUps: res.followUps,
      serverRunCredits: res.serverRunCredits,
      serverRuns: res.serverRuns,
      actions: res.actions,
      team: Team.normalize(res.team),
      replyTo: _linkOf(turn),
      steerOffer: turn.prepared?.steerOffer,
      ask: res.ask,
      proposal: res.proposal,
    );
  }

  String _outcomeOf(TurnResult res) {
    if (res.pendingTool != null) return 'approval';
    if (res.ask != null) return 'question';
    if (res.proposal != null) return 'approval';
    final token = res.resumeToken;
    return token != null && token.isNotEmpty ? 'paused' : 'done';
  }

  Future<void> _count(Conversation conv, TurnResult res) async {
    _bumpSpent(conv, res.cost + res.serverRunCredits, res.pro);
    conv.messageCount += 1;
    conv.creditsSpent += res.cost + res.serverRunCredits;
    _touch(conv);
    await store.saveConversations(conversations);
    await store.recordUsage(res.cost);
    _creditBalance(res.pro, res.balance,
        anonKey: conv.anon, anonPk: conv.anonPk);
  }

  Future<TurnResult?> _land(ChatTurn turn, TurnResult res) async {
    final conv = turn.conv;
    final prepared = turn.prepared;
    if (prepared != null && prepared.plan.isNotEmpty) turn.plan = prepared.plan;
    _stopWatching(turn, keepDraft: true);
    if (res.checkpoint != null) await rememberBranches(conv, res.checkpoint!);
    if (turn.stopped || (prepared?.stopped ?? false)) {
      turn.draft = null;
      if (!turn.stopped) {
        turn.stopped = true;
        turn.outcome = 'stopped';
        await note(t('Stopped.'), conv: conv, replyTo: _linkOf(turn));
      }
      await _count(conv, res);
      return null;
    }
    final reply = _replyOf(turn, res);
    turn.outcome = _outcomeOf(res);
    if (turn.drafted) streamedReplies.add(reply.id);
    turn.draft = null;
    await _addTo(conv, reply);
    if (reply.checkpoint != null) unawaited(prWatchAuto(conv, reply).catchError((_) => 0));
    await harvestArtifacts(reply, conv: conv);
    if (conv.seed != null) conv.seed = null;
    await _count(conv, res);
    final missed = prepared?.steerMissed ?? const <String>[];
    if (missed.isNotEmpty) unawaited(_offerMissed(missed, conv));
    if (res.free != null) {
      // Counted on the device too, so a fresh key does not reset the day.
      free = res.free;
      await store.freeTier.spent();
      await store.freeTier.observe(res.free!.used);
    }
    if (conv.anon && anonStandardBalance == null) {
      unawaited(refreshBalance());
    }
    final handed = prepared?.background;
    if (handed != null) {
      turn.outcome = 'background';
      await _trackBackground(turn, handed);
    }
    if (res.lowBalance) {
      // In an anonymous chat, a low balance usually means the throwaway key ran dry.
      final topped = conv.anon ? await autoTopUp(pk: conv.anonPk) : null;
      if (topped != null) {
        await note(describeTopUp(topped), conv: conv, replyTo: _linkOf(turn));
      } else {
        await note(
            res.pro
                ? t('Pro credits running low: {n} left. Tap Buy to top up.',
                    {'n': creditFigure(res.balance)})
                : t('Credits running low: {n} left. Tap Buy to top up.',
                    {'n': creditFigure(res.balance)}),
            conv: conv,
            replyTo: _linkOf(turn));
      }
    }
    if (handed != null) return null;
    return res.truncated ? res : null;
  }

  Future<bool> _commonFailure(ChatTurn turn, ChatFailure e,
      {ChatMessage? mine}) async {
    final conv = turn.conv;
    _stopWatching(turn);
    if (e.checkpoint != null) await rememberBranches(conv, e.checkpoint!);
    if (e.cancelled || turn.stopped) return true;
    if (e.runCap != null) {
      await _runCapped(turn, e);
      return true;
    }
    if (e.lost && e.offline && mine != null && turn.prepared != null) {
      await _parkOffline(turn, mine);
      return true;
    }
    if (e.pending || e.lost) {
      _startClaim(turn);
      return true;
    }
    return conv.id.isEmpty;
  }

  Future<void> _placeError(ChatTurn turn, String text,
      {String? retry, String? retryEvent}) =>
      _addTo(
          turn.conv,
          ChatMessage(
            id: bytesToHex(randomBytes(8)),
            role: ChatRole.error,
            content: text,
            retry: retry,
            retryEvent: retryEvent,
            replyTo: _linkOf(turn),
          ));

  Future<void> _runAsk(ChatTurn turn, ChatMessage mine,
      {required String body,
      required String typed,
      required bool bare,
      required bool unattended,
      required bool composing,
      required List<Attachment> sent,
      required String? quoted,
      Map<String, dynamic>? asked,
      Object? research,
      Map<String, dynamic>? team,
      double? maxCost}) async {
    final conv = turn.conv;
    turn.research = research;
    turn.team = team;
    turn.kind = team != null
        ? 'team'
        : research != null
            ? 'research'
            : (reposOf(conv).isNotEmpty ? 'repo' : 'chat');
    turn.control.onStatus = (s) {
      turn.status = s;
      notifyListeners();
    };
    final model = asked ?? modelOf(conv);
    turn.model = model;
    TurnResult? carry;
    var resendWaived = false;
    try {
      await _takeSlot(turn);
      final fork = conv.forkOf;
      if (!conv.anon) cleanupSoon(conv);
      final prepared = await chat.prepare(
        conv: conv,
        text: body,
        maxCost: maxCost,
        proModel: asked ?? proModelForTurnOf(conv),
        repos: reposOf(conv),
        connectors: connectorsOf(conv),
        serverRuns: serverRunsOf(conv),
        persona: personaOf(conv),
        workspace: workspaceOf(conv),
        bot: botOf(conv),
        memories: store.memories(),
        attachments: sent,
        quote: quoted,
        webSearch: webOn,
        research: research,
        team: team,
        msgId: turn.msgId,
        runExtras: {
          ..._runExtras(conv),
          'forkOf': ?fork,
          ...await _grantFor(conv, asked ?? proModelForTurnOf(conv),
              research: research, team: team),
        },
        onTurn: (eventId) => _watchTurn(turn, eventId),
        onStep: (step) => _localStep(turn, step),
      );
      turn.prepared = prepared;
      if (fork != null && conv.forkOf == fork) {
        conv.forkOf = null;
        await store.saveConversations(conversations);
      }
      if (turn.stopped) throw ChatFailure(t('Stopped.'), cancelled: true);
      final res = await _deliver(turn);
      carry = await _land(turn, res);
    } on ChatFailure catch (e) {
      if (await _commonFailure(turn, e, mine: mine)) {
        notifyListeners();
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
        _creditBalance(e.pro, e.balance,
            anonKey: conv.anon, anonPk: conv.anonPk);
        // Trust the worker's count over the device's, which can only lag.
        if (e.free != null) {
          free = e.free;
          await store.freeTier.observe(e.free!.used);
        }
        if (e.free != null && !e.pro) {
          // The allowance ran out, not a balance, so there is nothing to top up.
          await note(freeSpentMessage(), conv: conv, replyTo: _linkOf(turn));
        } else {
          final topped = conv.anon
              ? await autoTopUp(force: true, pk: conv.anonPk)
              : null;
          if (topped != null) {
            await note('${describeTopUp(topped)} '
                '${t('Send that again when you are ready.')}', conv: conv, replyTo: _linkOf(turn));
          } else {
            await note(e.team ? Team.refusal(e) : e.message,
                conv: conv, replyTo: _linkOf(turn));
          }
        }
      } else {
        await _placeError(turn, e.message,
            retry: typed, retryEvent: turn.sent ? turn.prepared?.eventId : null);
      }
    } catch (e) {
      if (!turn.stopped) {
        await _placeError(turn, t('Something went wrong sending that message.'),
            retry: typed);
      }
    } finally {
      if (turn.phase != 'claiming') _stopWatching(turn);
      if (turn.phase != 'claiming') turn.status = null;
      notifyListeners();
    }
    if (carry != null && !turn.stopped) await _carryOn(turn, carry, asked: asked);
    if (turn.phase != 'claiming') _endTurn(turn);
    if (resendWaived) {
      _capWaive = conv.id;
      await send(typed, target: conv, bare: bare, withAttachments: sent, withQuote: quoted);
    }
  }

  Future<bool> send(String text,
      {Conversation? target,
      bool bare = false,
      bool unattended = false,
      List<Attachment>? withAttachments,
      String? withQuote}) async {
    final conv = target ?? current;
    if (conv == null || text.trim().isEmpty) return false;
    if (conv.support) {
      return await sendSupport(text) == ContactOutcome.sent;
    }
    final typed = text.trim();
    final guard = '${conv.id}\n$typed';
    if (_starting.contains(guard)) return false;
    _starting.add(guard);
    final composing =
        !bare && withAttachments == null && conv.id == current?.id;
    final sent = withAttachments ?? (composing ? [...attachments] : <Attachment>[]);
    final quoted = withQuote ?? (composing ? quote : null);
    if (composing) {
      attachments = [];
      quote = null;
    }
    final turn = ChatTurn(conv,
        askId: bytesToHex(randomBytes(8)),
        msgId: bytesToHex(randomBytes(32)),
        label: _labelOf(typed));
    turn.unattended = unattended;
    turn.phase = 'starting';
    turns[turn.key] = turn;
    notifyListeners();
    var placed = false;
    void release() {
      if (placed) return;
      placed = true;
      _starting.remove(guard);
    }

    bool bail() {
      release();
      _dropRun(turn);
      if (composing && attachments.isEmpty && quote == null) {
        attachments = sent;
        quote = quoted;
      }
      return false;
    }

    try {
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
          return bail();
        }
        final wallet = conv.anon ? anonProBalance : proBalance;
        if (mention != null && mention.resolved && wallet != null && wallet <= 0) {
          await note(t('@{name} answers from your Pro balance, which is empty. Type ?buy to top up, then send it again.',
              {'name': mention.model!['key']}), conv: conv);
          if (conv.id == current?.id) _capReturned = typed;
          return bail();
        }
      }
      if (api.offline && !bare) {
        await _addTo(conv, ChatMessage(
          id: turn.askId!,
          role: ChatRole.self,
          content: typed,
          attachments: sent,
          quote: quoted,
          pending: 'offline',
        ));
        release();
        _dropRun(turn);
        await _titleFrom(conv, typed);
        _watchPending();
        return true;
      }
      // Device-side free-tier count across keys; never reported to the worker (see [freeAllows]).
      final asked = mention != null && mention.resolved ? Mentions.pinned(mention.model!) : null;
      if (asked == null && !freeAllows) {
        await note(freeSpentMessage(), conv: conv);
        return bail();
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
        return bail();
      }
      final team = bare
          ? null
          : Team.claim(conv.team,
              lead: asked ?? teamLeadOf(conv),
              research: research != null,
              repos: reposOf(conv).isNotEmpty);
      if (!bare &&
          mentionCatalog == null &&
          mediaModelOf(conv)?['resolution'] != null) {
        await ensureMentionCatalog();
      }
      final body = research != null
          ? research.question
          : asked != null
              ? mention!.text
              : (bare ? typed : withMediaModel(typed, conv: conv));

      // Pictures must be uploaded first, since the link is what travels.
      if (sent.any((a) => a.uploads && a.url == null)) {
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
                max: priced.max.toDouble(),
                metered: true,
                unpriced: false
              );
            }
          }
          final gate = await _capGate(conv, est.tier == 'pro', est.max,
              unattended: unattended);
          if (gate != 'send' && gate != 'ok') {
            if (composing) _capReturned = typed;
            return bail();
          }
          if (gate == 'ok') {
            maxCost = SpendCaps.maxCost(conv, botOf(conv), _messagesOf(conv),
                pro: est.tier == 'pro');
          }
        }
      }

      if (conv.anon) {
        final had = conv.anonPk;
        final est = _capEstimate(conv, body, model: asked);
        final funded = await fundAnonTurn(conv,
            need: est.max, tier: est.tier == 'pro' ? 'pro' : 'standard');
        if (had != conv.anonPk) await store.saveConversations(conversations);
        if (funded != null) await note(describeTopUp(funded), conv: conv);
      }

      final selfId = turn.askId!;
      final docsUsed = DocLibrary.instance.usageFor(conv.id, body, sent);
      final mine = ChatMessage(
        id: selfId,
        role: ChatRole.self,
        content: typed,
        attachments: sent,
        quote: quoted,
        wire: turn.msgId,
      );
      await _addTo(conv, mine);
      release();
      turn.phase = 'running';
      unawaited(DocLibrary.instance.recordUsage(selfId, docsUsed));
      unawaited(DocLibrary.instance.keep(conv.id, sent));
      await _titleFrom(conv, typed);
      if (mention?.unknown != null) {
        await note(t('No model called @{name}, so that went as an ordinary message. Type @ to pick one.',
            {'name': mention!.unknown}), conv: conv, replyTo: turn.msgId);
      }
      await _runAsk(turn, mine,
          body: body,
          typed: typed,
          bare: bare,
          unattended: unattended,
          composing: composing,
          sent: sent,
          quoted: quoted,
          asked: asked,
          research: research?.payload,
          team: team,
          maxCost: maxCost);
      return true;
    } catch (e) {
      if (!placed) return bail();
      rethrow;
    } finally {
      release();
    }
  }

  Future<void> _titleFrom(Conversation conv, String typed) async {
    if (conv.title.isNotEmpty) return;
    conv.title = ChatEngine.titleFor(typed);
    _touch(conv);
    await store.saveConversations(conversations);
  }

  // Late replies

  static const _claimsKey = 'pending_claims';

  List<Map<String, dynamic>> _storedClaims() {
    final raw = store.getString(_claimsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw);
      return list is List ? list.whereType<Map<String, dynamic>>().toList() : [];
    } catch (_) {
      return [];
    }
  }

  Future<void> _keepClaim(ChatTurn turn) async {
    final p = turn.prepared;
    if (p == null || turn.conv.ephemeral) return;
    final entry = {
      'conv': turn.conv.id,
      'ask': turn.askId,
      'wire': turn.msgId,
      'label': turn.label,
      'extra': p.extra,
      'msgId': p.msgId,
      'anonPk': p.anonPk,
      'fresh': p.fresh,
      'at': (turn.since ?? turn.began).millisecondsSinceEpoch,
    };
    final text = jsonEncode(entry);
    if (text.length > 256 * 1024) return;
    final list = _storedClaims()..removeWhere((c) => c['extra']?['eventId'] == p.eventId);
    await store.setString(_claimsKey, jsonEncode([...list, entry]));
  }

  Future<void> _dropClaim(ChatTurn turn) async {
    final id = turn.prepared?.eventId;
    if (id == null) return;
    final list = _storedClaims();
    final kept = list.where((c) => c['extra']?['eventId'] != id).toList();
    if (kept.length != list.length) {
      await store.setString(_claimsKey, jsonEncode(kept));
    }
  }

  void _startClaim(ChatTurn turn) {
    if (turn.prepared == null) return;
    turn.phase = 'claiming';
    turn.status = t('Still working on that one…');
    notifyListeners();
    unawaited(_keepClaim(turn));
    unawaited(_claimLoop(turn));
  }

  Future<void> _claimLoop(ChatTurn turn) async {
    final prepared = turn.prepared!;
    final until = (turn.since ?? turn.began).add(claimFor);
    var i = 0;
    var gaveUp = false;
    while (!turn.stopped && !_gone) {
      if (DateTime.now().isAfter(until)) {
        gaveUp = true;
        break;
      }
      final step = claimBackoff[math.min(i++, claimBackoff.length - 1)];
      await Future<void>.delayed(step + Jitter.next(step ~/ 4));
      if (turn.stopped || _gone) return;
      try {
        final got = await chat.claim(prepared,
            onThreadIds: _threadIdsOf(turn.conv));
        if (turn.stopped || _gone) return;
        final result = got.result;
        if (result != null) {
          turn.phase = 'running';
          turn.status = null;
          final carry = await _land(turn, result);
          await _dropClaim(turn);
          if (carry != null && !turn.stopped) {
            await _carryOn(turn, carry, asked: turn.model);
          }
          _endTurn(turn);
          return;
        }
        if (got.unknown) {
          gaveUp = true;
          break;
        }
      } on ChatFailure catch (e) {
        turn.phase = 'running';
        turn.status = null;
        await _dropClaim(turn);
        if (!await _commonFailure(turn, e)) {
          await _placeError(turn, e.message, retryEvent: prepared.eventId);
        }
        if (turn.phase != 'claiming') _endTurn(turn);
        return;
      } catch (_) {}
    }
    if (turn.stopped || _gone || !gaveUp) return;
    turn.phase = 'running';
    turn.status = null;
    await _dropClaim(turn);
    _parked[prepared.eventId] = turn;
    await _placeError(turn,
        t('Nymbot could not finish that one. Try again; it will not be charged twice.'),
        retryEvent: prepared.eventId);
    _endTurn(turn);
  }

  bool _gone = false;

  Future<void> resumeClaims() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = _storedClaims();
    final fresh = list
        .where((c) => now - ((c['at'] as num?)?.toInt() ?? 0) < claimFor.inMilliseconds)
        .toList();
    if (fresh.length != list.length) {
      await store.setString(_claimsKey, jsonEncode(fresh));
    }
    for (final c in fresh) {
      final conv = _conversationById('${c['conv']}');
      final extra = c['extra'];
      if (conv == null || extra is! Map<String, dynamic> || extra['wrap'] is! Map) continue;
      if (turns.values.any((t) => t.prepared?.eventId == extra['eventId'])) continue;
      final signer = c['anonPk'] is String
          ? await anon.signer(pk: c['anonPk'] as String)
          : identity.signer;
      final turn = ChatTurn(conv,
          askId: c['ask'] as String?,
          msgId: c['wire'] as String?,
          label: '${c['label'] ?? ''}');
      turn.sent = true;
      turn.since = DateTime.fromMillisecondsSinceEpoch((c['at'] as num?)?.toInt() ?? 0);
      turn.model = modelOf(conv);
      turn.prepared = PreparedTurn(
        conv: conv,
        signer: signer,
        extra: extra,
        wrap: NostrEvent.fromJson((extra['wrap'] as Map).cast<String, dynamic>()),
        msgId: '${c['msgId'] ?? c['wire'] ?? ''}',
        anonPk: c['anonPk'] as String?,
        fresh: c['fresh'] == true,
      );
      turns[turn.key] = turn;
      turn.phase = 'claiming';
      turn.status = t('Still working on that one…');
      final wait = Jitter.next();
      unawaited(() async {
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        if (turn.stopped || _gone) return;
        await _claimLoop(turn);
      }());
    }
    notifyListeners();
  }

  Future<void> retryMessage(ChatMessage error) async {
    final conv = current;
    final id = error.retryEvent;
    final held = id == null ? null : _parked.remove(id);
    if (conv == null) return;
    if (held == null || held.prepared == null) {
      final again = error.retry;
      await deleteMessage(error);
      if (again != null) await send(again);
      return;
    }
    await _dropMessage(held.conv, error);
    await _redeliver(held);
  }

  Future<void> _redeliver(ChatTurn old,
      {int? maxRuns,
      bool force = false,
      bool afterEnd = false,
      int? waitLimit,
      String? waitText}) async {
    final conv = old.conv;
    final prepared = old.prepared!;
    if (maxRuns != null) prepared.extra['maxRuns'] = maxRuns;
    final turn = ChatTurn(conv,
        askId: old.askId, msgId: old.msgId, label: old.label);
    turn.prepared = prepared;
    turn.model = old.model;
    turn.research = old.research;
    turn.team = old.team;
    turn.kind = old.kind;
    turn.unattended = old.unattended;
    turn.since = old.since ?? old.began;
    turns[turn.key] = turn;
    turn.control.onStatus = (s) {
      turn.status = s;
      notifyListeners();
    };
    notifyListeners();
    TurnResult? carry;
    try {
      if (afterEnd) {
        turn.phase = 'slot';
        turn.status = t('Waiting for a free slot');
        notifyListeners();
        final room = await _waitForRoom(turn, waitLimit ?? runLimit);
        if (turn.stopped) throw ChatFailure(t('Stopped.'), cancelled: true);
        if (!room) {
          turn.phase = 'running';
          turn.status = null;
          _parked[prepared.eventId] = turn;
          await _placeError(turn,
              waitText ?? t('3 requests are already running. Wait for one to finish.'),
              retryEvent: prepared.eventId);
          _endTurn(turn);
          return;
        }
      }
      await _takeSlot(turn, force: force);
      _watchTurn(turn, prepared.eventId);
      final res = await _deliver(turn);
      carry = await _land(turn, res);
    } on ChatFailure catch (e) {
      final mine = _messagesOf(conv).where((m) => m.id == old.askId).firstOrNull;
      if (!await _commonFailure(turn, e, mine: mine)) {
        if (e.noCredits) {
          _creditBalance(e.pro, e.balance, anonKey: conv.anon, anonPk: conv.anonPk);
          await note(e.team ? Team.refusal(e) : e.message, conv: conv, replyTo: _linkOf(turn));
        } else {
          _parked[prepared.eventId] = turn;
          await _placeError(turn, e.message, retryEvent: prepared.eventId);
        }
      }
    } catch (_) {
      if (!turn.stopped) {
        _parked[prepared.eventId] = turn;
        await _placeError(turn, t('Something went wrong sending that message.'),
            retryEvent: prepared.eventId);
      }
    } finally {
      if (turn.phase != 'claiming') {
        _stopWatching(turn);
        turn.status = null;
      }
      notifyListeners();
    }
    if (carry != null && !turn.stopped) await _carryOn(turn, carry, asked: turn.model);
    if (turn.phase != 'claiming') _endTurn(turn);
  }

  // The run cap

  VoidCallback? onBuy;

  static List<String> runCapChoices(Map<String, dynamic> cap) {
    final limit = (cap['limit'] as num?)?.toInt() ?? 0;
    final ceiling = (cap['ceiling'] as num?)?.toInt() ?? 0;
    if (cap['free'] == true) return const [];
    if (limit >= ceiling) return const ['wait'];
    return const ['start', 'always', 'wait'];
  }

  static int runCapAllow(Map<String, dynamic> cap) {
    final running = (cap['running'] as num?)?.toInt() ?? 0;
    final ceiling = (cap['ceiling'] as num?)?.toInt() ?? 10;
    return math.min(running + 1, ceiling);
  }

  Future<void> _runCapped(ChatTurn turn, ChatFailure e) async {
    final conv = turn.conv;
    final cap = e.runCap!;
    if (cap['free'] == true) {
      await note(e.message, conv: conv, replyTo: _linkOf(turn));
      onBuy?.call();
      return;
    }
    final prepared = turn.prepared;
    if (prepared != null) _parked[prepared.eventId] = turn;
    await _addTo(
        conv,
        ChatMessage(
          id: bytesToHex(randomBytes(8)),
          role: ChatRole.error,
          content: e.message,
          runCap: {
            for (final k in const ['running', 'limit', 'ceiling', 'reserve', 'free'])
              if (cap[k] != null) k: cap[k],
          },
          retryEvent: prepared?.eventId,
          replyTo: _linkOf(turn),
        ));
  }

  ChatTurn? _heldFor(ChatMessage card) {
    final id = card.retryEvent;
    return id == null ? null : _parked.remove(id);
  }

  Future<void> startAnyway(ChatMessage card) async {
    final held = _heldFor(card);
    if (held == null || held.prepared == null) return;
    await _dropMessage(held.conv, card);
    final running = (card.runCap?['running'] as num?)?.toInt() ?? runLimit;
    await _redeliver(held, maxRuns: math.min(running + 1, 10), force: true);
  }

  Future<void> alwaysAllowRuns(ChatMessage card) async {
    final held = _heldFor(card);
    final n = runCapAllow(card.runCap ?? const {});
    settings.maxRuns = n.clamp(1, 10);
    await store.saveSettings(settings);
    notifyListeners();
    if (held == null || held.prepared == null) return;
    await _dropMessage(held.conv, card);
    await _redeliver(held, maxRuns: settings.maxRuns, force: true);
  }

  Future<void> waitForSlot(ChatMessage card) async {
    final held = _heldFor(card);
    if (held == null || held.prepared == null) return;
    await _dropMessage(held.conv, card);
    await _redeliver(held,
        afterEnd: true,
        waitLimit: (card.runCap?['limit'] as num?)?.toInt(),
        waitText: card.content);
  }

  Future<bool> _waitForRoom(ChatTurn turn, int limit) async {
    final ended = Completer<void>();
    _endWaiters.add(ended);
    final until = DateTime.now().add(slotWaitFor);
    final signer = turn.prepared?.signer ?? await _signerOf(turn.conv);
    var i = 0;
    while (!turn.stopped && !_gone) {
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) return false;
      final step = slotPoll[math.min(i++, slotPoll.length - 1)];
      final gate = turn.slotWait = Completer<void>();
      await Future.any([
        ended.future,
        gate.future,
        Future<void>.delayed(step < left ? step : left),
      ]);
      turn.slotWait = null;
      if (turn.stopped || _gone) return false;
      if (ended.isCompleted) return true;
      if (DateTime.now().isAfter(until)) return false;
      final res = await api.liveRuns(signer);
      final runs = res.data['runs'];
      if (res.status == 200 && runs is List && runs.length < limit) return true;
    }
    return false;
  }

  // Steering

  final Map<String, String> _steered = {};
  final Map<String, _FarSteer> _farSteers = {};
  Timer? _farTimer;
  bool _farChecking = false;

  static Duration farSteerKeep = const Duration(hours: 2);

  Future<bool?> Function(String text, Conversation conv)? onSteerMissed;

  Future<String> steer(String runId, String text, {Conversation? conv}) async {
    final body = text.trim();
    if (body.isEmpty || runId.isEmpty) return 'failed';
    ChatTurn? local;
    for (final t in turns.values) {
      if (t.runId == runId) local = t;
    }
    final owner = local?.conv ?? conv;
    final signer = local?.prepared?.signer ??
        (owner != null ? await _signerOf(owner) : identity.signer);
    final res = await api.steerRun(signer, runId, body);
    if (res.status == 200 && res.data['ok'] == true) {
      transcripts.steered(runId, body, convId: owner?.id);
      final id = res.data['id'];
      if (id is String && id.isNotEmpty) {
        _steered[id] = body;
        if (_steered.length > 50) _steered.remove(_steered.keys.first);
        if (local == null && RegExp(r'^[0-9a-f]{24}$').hasMatch(id)) {
          _farSteers[id] = _FarSteer(runId, body, owner?.id, signer, DateTime.now());
          if (_farSteers.length > 50) _farSteers.remove(_farSteers.keys.first);
          _watchFarSteers();
        }
      }
      if (local != null) {
        local.progress = t('Passed on. It applies at the next step.');
        notifyListeners();
      }
      return 'ok';
    }
    if (res.status == 413) return 'long';
    if (res.status == 429 || res.status == 0 || res.status >= 500) {
      return 'failed';
    }
    if (res.status == 409 && res.data['final'] == true) return 'final';
    return 'finished';
  }

  void _watchFarSteers() {
    if (_farTimer != null || _gone) return;
    _farTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_farSteers.isEmpty || _gone) {
        _farTimer?.cancel();
        _farTimer = null;
        return;
      }
      if (_runsTimer == null) unawaited(refreshRuns());
    });
  }

  Future<void> _checkFarSteers() async {
    if (_farChecking || _farSteers.isEmpty) return;
    _farChecking = true;
    try {
      final now = DateTime.now();
      _farSteers.removeWhere((_, s) => now.difference(s.at) > farSteerKeep);
      final live = {for (final r in remoteRuns) r.replyTo, for (final t in turns.values) t.runId};
      final groups = <String, List<String>>{};
      final signers = <String, EventSigner>{};
      _farSteers.forEach((id, s) {
        if (live.contains(s.runId)) return;
        if (s.signer.pubkey != identity.pubkey && current?.id != s.convId) return;
        groups.putIfAbsent(s.signer.pubkey, () => []).add(id);
        signers[s.signer.pubkey] = s.signer;
      });
      final offers = <String, List<String>>{};
      final convs = <String, Conversation?>{};
      for (final entry in groups.entries) {
        final ids = entry.value.take(20).toList();
        final res = await api.steerStatus(signers[entry.key]!, ids);
        final states = res.data['states'];
        if (res.status != 200 || states is! Map) continue;
        for (final id in ids) {
          final s = _farSteers[id];
          if (s == null) continue;
          final state = states[id];
          if (state == 'pending' || state == null) {
            s.tries++;
            if (s.tries >= 6) _farSteers.remove(id);
            continue;
          }
          _farSteers.remove(id);
          if (state != 'missed' || _steered.remove(id) == null) continue;
          final conv = s.convId == null
              ? current
              : conversations.where((c) => c.id == s.convId).firstOrNull ?? current;
          if (conv == null) continue;
          offers.putIfAbsent(conv.id, () => []).add(s.text);
          convs[conv.id] = conv;
        }
      }
      for (final entry in offers.entries) {
        final conv = convs[entry.key]!;
        final ask = onSteerMissed;
        if (ask == null) continue;
        final text = entry.value.join('\n\n');
        if (await ask(text, conv) == true) {
          await send(text, target: conv, withAttachments: const []);
        }
      }
    } finally {
      _farChecking = false;
    }
  }

  Future<void> sendSteerOffer(ChatMessage m) async {
    final conv = current;
    if (conv == null) return;
    final at = messages.indexWhere((x) => x.id == m.id);
    if (at < 0) return;
    final text = messages[at].steerOffer;
    if (text == null || text.isEmpty) return;
    messages = [
      for (final x in messages) x.id == m.id ? x.copyWith(clearSteerOffer: true) : x,
    ];
    await store.saveMessages(conv.id, messages);
    notifyListeners();
    await send(text, target: conv, withAttachments: const []);
  }

  Future<void> _offerMissed(List<String> ids, Conversation conv) async {
    for (final id in ids) {
      _farSteers.remove(id);
    }
    final texts = [
      for (final id in ids)
        if (_steered.containsKey(id)) _steered.remove(id)!,
    ];
    if (texts.isEmpty) return;
    final ask = onSteerMissed;
    if (ask == null) return;
    final text = texts.join('\n\n');
    if (await ask(text, conv) == true) {
      await send(text, target: conv, withAttachments: const []);
    }
  }

  Future<bool?> Function(double? credits)? onBackgroundPrompt;
  List<BackgroundRun> backgroundRuns = [];
  Map<String, Map> _runsRaw = {};
  Timer? _bgTimer;
  bool _following = false;
  bool _asking = false;

  static Duration backgroundPoll = const Duration(seconds: 30);

  bool get _checksWanted => DoneSince.wanted(
      backgroundJobs: settings.backgroundJobs,
      serverSchedules: settings.serverSchedules);

  Future<void> setBackgroundJobs(bool on) async {
    settings.backgroundJobs = on;
    await store.saveSettings(settings);
    notifyListeners();
    unawaited(syncChecks());
  }

  Future<void> syncChecks() async {
    if (!replyNotify.supported ||
        replyNotify.platform != TargetPlatform.android) {
      return;
    }
    final on = _checksWanted;
    if (on && store.getInt(DoneSince.sinceKey) <= 0) {
      await store.setInt(
          DoneSince.sinceKey, DateTime.now().millisecondsSinceEpoch);
    }
    await replyNotify.channel.checks(on, channelName: t('Replies'));
  }

  bool get unifiedPushOn => store.getBool(_unifiedPushKey);

  String? get unifiedPushDistributor =>
      unifiedPushOn ? store.getString(_distributorKey) : null;

  static const _unifiedPushKey = 'unifiedpush_on';
  static const _distributorKey = 'unifiedpush_distributor';

  Future<List<({String package, String name})>> pushDistributors() =>
      replyNotify.channel.upDistributors();

  Future<String?> unifiedPushEndpoint() async =>
      (await replyNotify.channel.upState())?['endpoint'];

  Future<bool> useUnifiedPush(String? distributor) async {
    if (distributor == null) {
      await replyNotify.channel.upUnregister();
      await store.remove(_distributorKey);
      await store.setBool(_unifiedPushKey, false);
      notifyListeners();
      return true;
    }
    await replyNotify.askPermission();
    final ok = await replyNotify.channel.upRegister(distributor,
        channelName: t('Replies'), texts: ReplyNotify.pushTexts());
    await store.setBool(_unifiedPushKey, ok);
    if (ok) await store.setString(_distributorKey, distributor);
    notifyListeners();
    return ok;
  }

  bool _bgEligible(Conversation conv, Map<String, dynamic>? model,
          {Object? research, Map<String, dynamic>? team, double spent = 0}) =>
      BackgroundJobs.eligible(
          anon: conv.anon,
          ghost: conv.ephemeral,
          pro: model != null,
          proBalance: proBalance,
          standardBalance: standardBalance,
          budget: continueBudgetAfter(spent),
          long: research != null || team != null);

  Future<Map<String, dynamic>> _grantFor(
      Conversation conv, Map<String, dynamic>? model,
      {Object? research, Map<String, dynamic>? team, double spent = 0}) async {
    if (settings.backgroundJobs != true) return const {};
    if (!_bgEligible(conv, model,
        research: research, team: team, spent: spent)) {
      return const {};
    }
    Map<String, dynamic>? notify;
    if (settings.replyNotify) {
      try {
        notify = await replyNotify.pushRegistration(
            conv.id, BackgroundJobs.pushText(),
            kind: 'background');
      } catch (_) {
        notify = null;
      }
    }
    final grant = BackgroundJobs.grant(
        optedIn: true,
        anon: conv.anon,
        ghost: conv.ephemeral,
        pro: model != null,
        proBalance: proBalance,
        standardBalance: standardBalance,
        budget: continueBudgetAfter(spent),
        long: research != null || team != null,
        notify: notify);
    return grant == null ? const {} : {'background': grant};
  }

  Future<void> _askBackgroundOnce(
      ChatTurn turn, Map<String, dynamic>? model) async {
    final ask = onBackgroundPrompt;
    if (ask == null || _asking || turn.unattended) return;
    if (settings.backgroundJobs != null) return;
    final conv = turn.conv;
    if (!_bgEligible(conv, model,
        research: turn.research,
        team: turn.team,
        spent: turn.continuedSpend)) {
      return;
    }
    _asking = true;
    try {
      final budget = continueBudgetAfter(turn.continuedSpend);
      final own = turn.research != null || turn.team != null;
      final answer = await ask(own || budget <= 0 ? null : budget);
      if (settings.backgroundJobs != null) return;
      await setBackgroundJobs(answer == true);
    } finally {
      _asking = false;
    }
  }

  void _loadBackground() {
    final raw = store.getString(BackgroundJobs.runsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw);
      backgroundRuns = [
        for (final r in (list is List ? list : const []))
          if (BackgroundRun.fromJson(r) != null) BackgroundRun.fromJson(r)!,
      ];
    } catch (_) {
      backgroundRuns = [];
    }
    if (backgroundRuns.isNotEmpty) _watchBackground();
  }

  Future<void> _saveBackground() => store.setString(BackgroundJobs.runsKey,
      jsonEncode([for (final r in backgroundRuns) r.toJson()]));

  void _watchBackground() {
    if (backgroundRuns.isEmpty) {
      _bgTimer?.cancel();
      _bgTimer = null;
      return;
    }
    _bgTimer ??= Timer.periodic(backgroundPoll, (_) {
      if (!_gone) unawaited(pollBackground());
    });
  }

  Future<void> _trackBackground(
      ChatTurn turn, ({String runId, int until}) handed) async {
    final run = BackgroundRun(
        runId: handed.runId, conv: turn.conv.id, until: handed.until);
    backgroundRuns = [
      for (final r in backgroundRuns)
        if (r.runId != run.runId) r,
      run,
    ];
    await _saveBackground();
    _watchBackground();
    notifyListeners();
  }

  Future<void> pollBackground() async {
    if (_following || backgroundRuns.isEmpty || !identity.present) return;
    _following = true;
    try {
      await refreshRuns();
      final listed = <String, Map>{..._runsRaw};
      final missing = [
        for (final r in backgroundRuns)
          if (!listed.containsKey(r.runId)) r
      ];
      if (missing.isNotEmpty) {
        final since = missing
                .map((r) => r.startedAt)
                .reduce((a, b) => a < b ? a : b) -
            60000;
        final res = await api.doneSince(identity.signer, since);
        final ended = res.data['runs'];
        if (res.status == 200 && ended is List) {
          for (final r in ended) {
            if (r is Map && r['replyTo'] is String) {
              listed.putIfAbsent(r['replyTo'] as String, () => r);
            }
          }
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final run in [...backgroundRuns]) {
        if (_gone) return;
        final r = listed[run.runId];
        if (r == null) {
          if (run.until > 0 &&
              now > run.until + BackgroundJobs.keepAfter.inMilliseconds) {
            await _dropBackground(run);
          }
          continue;
        }
        await _followBackground(run, r);
      }
    } finally {
      _following = false;
    }
  }

  Future<void> _dropBackground(BackgroundRun run) async {
    backgroundRuns = [
      for (final r in backgroundRuns)
        if (r.runId != run.runId) r
    ];
    await _saveBackground();
    _watchBackground();
    notifyListeners();
  }

  Future<void> _followBackground(BackgroundRun run, Map r) async {
    final conv = _conversationById(run.conv);
    if (conv == null) {
      await _dropBackground(run);
      return;
    }
    final legs = BackgroundJobs.legsOf(r['legs']);
    for (final leg in legs) {
      if (run.claimed.contains(leg)) continue;
      final got = await api.claimRun(identity.signer, leg);
      if (got.status == 202 || got.status <= 0 || got.data['pending'] == true) {
        break;
      }
      if (got.status != 404) {
        await _landLeg(conv, run, leg, got.status, got.data);
      }
      run.claimed.add(leg);
      await _saveBackground();
    }
    final state = r['state'];
    if (state == 'expired') await _expireQuestions(conv, run.runId);
    await transcripts.background(run.runId, conv, r, _messagesOf(conv),
        ended: state is String && BackgroundJobs.ended.contains(state) && legs.every(run.claimed.contains));
    if (state is! String || !BackgroundJobs.ended.contains(state)) return;
    if (!legs.every(run.claimed.contains)) return;
    final said = BackgroundJobs.endNote(state, body: run.last);
    if (said != null) await note(said, conv: conv, replyTo: run.runId);
    if (_checksWanted) await DoneSince.markSeen(store, [run.runId]);
    await _dropBackground(run);
  }

  Future<void> _landLeg(Conversation conv, BackgroundRun run, String leg,
      int status, Map<String, dynamic> data) async {
    run.last = {
      if (data['noCredits'] == true) 'noCredits': true,
      if (data['capExceeded'] == true) 'capExceeded': true,
      if (data['background'] is Map) 'background': data['background'],
    };
    final shadow = ChatTurn(conv, msgId: run.runId)..model = modelOf(conv);
    try {
      final res = await chat.openLeg(conv, leg, status, data,
          onThreadIds: _threadIdsOf(conv));
      final reply = _replyOf(shadow, res);
      await _addTo(conv, reply);
      await harvestArtifacts(reply, conv: conv);
      await _count(conv, res);
    } on ChatFailure catch (e) {
      if (data['noCredits'] == true || data['capExceeded'] == true) return;
      await note(e.message, conv: conv, replyTo: run.runId);
    } catch (_) {}
  }

  Future<String?> setServerSchedules(bool on) async {
    settings.serverSchedules = on;
    await store.saveSettings(settings);
    notifyListeners();
    unawaited(syncChecks());
    if (on) {
      unawaited(refreshServerSchedules());
      return null;
    }
    var changed = false;
    for (final s in schedules) {
      if (s.server != null || s.serverSha != null || s.serverOff) {
        _unserve(s);
        changed = true;
      }
    }
    if (changed) {
      await store.saveSchedules(schedules);
      notifyListeners();
    }
    final res = await api.scheduleClear(identity.signer);
    return res.status == 200 && res.data['ok'] == true
        ? t("The server's copies of your schedules were deleted.")
        : t('Could not reach the server to delete its copies of your schedules. Try again from Settings.');
  }

  Future<void> setScheduleDailyCap(int credits) async {
    settings.scheduleDailyCap = credits.clamp(1, 10000);
    await store.saveSettings(settings);
    notifyListeners();
    final held = schedules.where((s) => s.server != null).firstOrNull;
    if (held != null && settings.serverSchedules) {
      unawaited(saveServerSchedule(held, held.server));
    }
  }

  Future<String> toggleSchedule(Schedule s) async {
    s.enabled = !s.enabled;
    await saveSchedule(s);
    if (s.server == null || !settings.serverSchedules) return '';
    if (!s.enabled) {
      if (s.serverSha == null) return '';
      s.serverSha = null;
      s.serverExpiresAt = 0;
      await saveSchedule(s);
      await api.scheduleDelete(identity.signer, s.id);
      return '';
    }
    return saveServerSchedule(s, s.server);
  }

  void _unserve(Schedule s) {
    s.server = null;
    s.serverSha = null;
    s.serverExpiresAt = 0;
    s.serverError = null;
    s.serverOff = false;
  }

  Future<String> saveServerSchedule(Schedule s, String? mode) async {
    if (mode == null) {
      final had = s.serverSha != null;
      _unserve(s);
      await saveSchedule(s);
      if (had) await api.scheduleDelete(identity.signer, s.id);
      return '';
    }
    if (!settings.serverSchedules) return '';
    final conv = s.convId == null ? null : _conversationById(s.convId!);
    if (conv != null && conv.anon) {
      final had = s.serverSha != null;
      _unserve(s);
      await saveSchedule(s);
      if (had) await api.scheduleDelete(identity.signer, s.id);
      return ServerSchedules.anonText();
    }
    final run = mode == 'run';
    final model = run ? '${modelOf(conv)?['key'] ?? ''}' : '';
    if (run) {
      final have = model.isEmpty ? standardBalance : proBalance;
      if (have != null && have <= 0) {
        return t('Server schedules spend your paid balance, which is empty. Top up first.');
      }
    }
    final chatId = conv?.id ?? s.id;
    final title = s.title.trim().isEmpty ? t('Your reply is ready') : s.title.trim();
    Map<String, dynamic>? push;
    try {
      push = await replyNotify.pushRegistration(
          chatId, run ? title : ServerSchedules.dueText(),
          kind: 'schedule');
    } catch (_) {
      push = null;
    }
    if (!run && push == null) return ServerSchedules.noPush();
    final text = ServerSchedules.payload(s,
        mode: mode,
        thread: conv?.rootId ?? '',
        model: model,
        tier: model.isEmpty ? 'standard' : 'pro');
    final body = ServerSchedules.body(s,
        mode: mode,
        payload: text,
        dailyCap: settings.scheduleDailyCap,
        now: DateTime.now().millisecondsSinceEpoch,
        push: push);
    final res = await api.schedulePut(identity.signer, body);
    final refused = ServerSchedules.refusal(res.status, res.data);
    if (refused != null) {
      s.server = mode;
      s.serverSha = null;
      s.serverExpiresAt = 0;
      s.serverError = refused;
      await saveSchedule(s);
      return refused;
    }
    s.server = mode;
    s.serverSha = body['sha256'] as String;
    final expires = res.data['expiresAt'];
    s.serverExpiresAt =
        expires is num ? expires.toInt() : body['expiresAt'] as int;
    s.serverError = null;
    s.serverOff = false;
    await saveSchedule(s);
    return run ? ServerSchedules.savedRun() : ServerSchedules.savedNotify();
  }

  bool _refreshing = false;

  Future<void> refreshServerSchedules() async {
    if (_refreshing || !settings.serverSchedules || !identity.present) return;
    if (!schedules.any((s) => s.server != null && s.serverSha != null)) return;
    _refreshing = true;
    try {
      final res = await api.scheduleList(identity.signer);
      final list = res.data['schedules'];
      if (res.status != 200 || list is! List) return;
      final listed = <String, Map>{
        for (final r in list)
          if (r is Map && r['id'] is String) r['id'] as String: r,
      };
      var changed = false;
      for (final s in [...schedules]) {
        if (s.server == null || s.serverSha == null) continue;
        final r = listed[s.id];
        if (r != null && s.serverSha != null && r['sha256'] != s.serverSha) {
          continue;
        }
        if (r == null) {
          if (s.server == 'run' &&
              s.repeat == ScheduleRepeat.once &&
              s.serverSha != null) {
            if (await _claimFired(s, s.nextAt.millisecondsSinceEpoch + 1)) {
              s.enabled = false;
              changed = true;
            }
          }
          continue;
        }
        final off = r['enabled'] == false;
        if (off != s.serverOff) {
          s.serverOff = off;
          changed = true;
        }
        final expires = r['expiresAt'];
        if (expires is num && expires.toInt() != s.serverExpiresAt) {
          s.serverExpiresAt = expires.toInt();
          changed = true;
        }
        final next = r['nextAt'];
        if (s.server == 'run' && next is num) {
          if (await _claimFired(s, next.toInt())) changed = true;
          if (next.toInt() > s.nextAt.millisecondsSinceEpoch) {
            s.nextAt = DateTime.fromMillisecondsSinceEpoch(next.toInt());
            changed = true;
          }
        }
      }
      if (changed) {
        await store.saveSchedules(schedules);
        notifyListeners();
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<bool> _claimFired(Schedule s, int serverNextAt) async {
    final slots = ServerSchedules.firedSlots(s,
        serverNextAt: serverNextAt, since: s.serverSeenAt);
    var moved = false;
    for (final at in slots) {
      final id = ServerSchedules.eventIdFor(s.id, at);
      final got = await api.claimRun(identity.signer, id);
      if (got.status == 202 || got.status <= 0 || got.data['pending'] == true) {
        break;
      }
      if (got.status == 200 && got.data['event'] is Map) {
        await _fileScheduled(s, id, got.data);
      }
      s.serverSeenAt = at;
      moved = true;
    }
    return moved;
  }

  Future<void> _fileScheduled(
      Schedule s, String eventId, Map<String, dynamic> data) async {
    var conv = s.convId == null ? null : _conversationById(s.convId!);
    if (conv != null && conv.anon) conv = null;
    if (conv == null) {
      conv = Conversation(
        id: bytesToHex(randomBytes(8)),
        rootId: bytesToHex(randomBytes(32)),
        title: s.title.isEmpty ? ChatEngine.titleFor(s.prompt) : s.title,
      );
      conversations.insert(0, conv);
      await store.saveConversations(conversations);
    }
    String? link;
    try {
      final res = await chat.openLeg(conv, eventId, 200, data,
          onThreadIds: _threadIdsOf(conv),
          onRumor: (rumor) =>
              link = ChatEngine.linkOf(rumor, data).replyTo);
      final wire = link ?? eventId;
      await _addTo(
          conv,
          ChatMessage(
            id: bytesToHex(randomBytes(8)),
            role: ChatRole.self,
            content: s.prompt.isEmpty ? t('A scheduled prompt') : s.prompt,
            wire: wire,
            sched: s.id,
          ));
      final shadow = ChatTurn(conv, msgId: wire)..model = modelOf(conv);
      final reply = _replyOf(shadow, res);
      unawaited(transcripts.scheduled(conv, reply, wire, s.title.isEmpty ? s.prompt : s.title));
      await _addTo(conv, reply);
      await harvestArtifacts(reply, conv: conv);
      await _count(conv, res);
      s.lastRunAt = DateTime.now();
      s.lastConvId = conv.id;
      s.runs += 1;
      if (conv.id != current?.id) {
        conv.unread += 1;
        await store.saveConversations(conversations);
      }
    } catch (_) {}
  }

  // Runs on any device

  List<RemoteRun> remoteRuns = [];
  int _runsWatchers = 0;
  Timer? _runsTimer;
  static Duration runsReconcile = const Duration(seconds: 30);
  static const _endedGrace = Duration(seconds: 60);
  static const _endedKeep = Duration(hours: 1);
  static const _runsResume = Duration(seconds: 60);
  final Map<String, int> _endedRuns = {};
  Timer? _runsSettle;
  int _runsPolledAt = 0;

  static RemoteRun? remoteRunOf(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['replyTo'];
    if (id is! String || id.isEmpty) return null;
    return (
      replyTo: id,
      thread: raw['thread'] is String ? raw['thread'] as String : '',
      kind: raw['kind'] is String ? raw['kind'] as String : 'chat',
      label: raw['label'] is String ? raw['label'] as String : '',
      progress: raw['progress'] is String ? raw['progress'] as String : '',
      plan: ChatEngine.planOf(raw['plan']),
      state: raw['state'] is String ? raw['state'] as String : 'running',
      startedAt: (raw['startedAt'] as num?)?.toInt() ?? 0,
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
      branches: branchStepsOf(raw['branches'] is List ? raw['branches'] as List : const []),
      background: raw['background'] == true,
      until: (raw['until'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> refreshRuns() async {
    if (!signedIn && identity.pubkey.isEmpty) return;
    _runsPolledAt = DateTime.now().millisecondsSinceEpoch;
    final res = await api.liveRuns(identity.signer);
    final list = res.data['runs'];
    final open = current;
    final ask = open != null && open.anon && open.rootId.isNotEmpty ? open : null;
    List? theirs;
    if (ask != null) {
      await Jitter.wait();
      final got = await api.liveRuns(await _signerOf(ask), thread: ask.rootId);
      final raw = got.data['runs'];
      if (got.status == 200 && raw is List) {
        theirs = [
          for (final r in raw)
            if (r is Map && r['thread'] == ask.rootId) r,
        ];
      }
    }
    if (res.status != 200 || list is! List) return;
    _runsRaw = {
      for (final r in list)
        if (r is Map && r['replyTo'] is String) r['replyTo'] as String: r,
    };
    final mine = list.map(remoteRunOf).whereType<RemoteRun>().toList();
    final others = (theirs ?? const []).map(remoteRunOf).whereType<RemoteRun>().toList();
    for (final r in mine) {
      for (final b in r.branches) {
        await rememberBranchStep(b);
      }
    }
    for (final r in others) {
      for (final b in r.branches) {
        await rememberBranchStep(b, conv: ask);
      }
    }
    final runs = [...mine, ...others];
    for (final r in runs) {
      for (final t in turns.values) {
        if (t.runId == r.replyTo) {
          if (r.progress.isNotEmpty) t.progress = r.progress;
          if (r.plan.isNotEmpty) t.plan = r.plan;
        }
      }
    }
    remoteRuns = [for (final r in runs) if (!_endedHere(r)) r];
    transcripts.remote(remoteRuns, _runsRaw, chatOfThread, _isLocal);
    notifyListeners();
    _reconcileRuns();
    if (_farSteers.isNotEmpty) unawaited(_checkFarSteers());
  }

  bool _endedHere(RemoteRun r) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _endedRuns.removeWhere((_, at) => now - at > _endedKeep.inMilliseconds);
    final at = _endedRuns[r.replyTo];
    if (at == null) return false;
    return r.state != 'running' || now - at < _endedGrace.inMilliseconds;
  }

  void _settleRun(ChatTurn turn) {
    final id = turn.runId;
    if (id.isEmpty || turn.outcome == 'background') return;
    _endedRuns[id] = DateTime.now().millisecondsSinceEpoch;
    remoteRuns = [for (final r in remoteRuns) if (r.replyTo != id) r];
  }

  void _reconcileRuns() {
    if (otherRuns.isEmpty) {
      _runsSettle?.cancel();
      _runsSettle = null;
      return;
    }
    if (_runsSettle != null || _gone) return;
    _runsSettle = Timer(runsReconcile, () {
      _runsSettle = null;
      if (_gone || otherRuns.isEmpty) return;
      unawaited(refreshRuns());
    });
  }

  void _resumeRuns() {
    if (backgroundRuns.isNotEmpty) {
      unawaited(pollBackground());
      return;
    }
    final since = DateTime.now().millisecondsSinceEpoch - _runsPolledAt;
    if (otherRuns.isEmpty && since < _runsResume.inMilliseconds) return;
    unawaited(refreshRuns());
  }

  bool _isLocal(String runId) => turns.values.any((t) => t.runId == runId);

  List<RemoteRun> remoteRunsIn(Conversation conv) => [
        for (final r in remoteRuns)
          if (r.thread == conv.rootId && !_isLocal(r.replyTo)) r
      ];

  List<RemoteRun> get otherRuns =>
      [for (final r in remoteRuns) if (!_isLocal(r.replyTo)) r];

  int get runningCount => turns.values.length + otherRuns.length;

  Conversation? chatOfThread(String thread) {
    if (thread.isEmpty) return null;
    for (final c in conversations) {
      if (c.rootId == thread) return c;
    }
    return null;
  }

  void watchRuns(bool on) {
    _runsWatchers += on ? 1 : -1;
    if (_runsWatchers < 0) _runsWatchers = 0;
    if (_runsWatchers > 0 && _runsTimer == null) {
      unawaited(refreshRuns());
      _runsTimer = Timer.periodic(
          const Duration(seconds: 5), (_) => unawaited(refreshRuns()));
    } else if (_runsWatchers == 0) {
      _runsTimer?.cancel();
      _runsTimer = null;
    }
  }

  Future<void> stopRemote(RemoteRun run) async {
    remoteRuns = remoteRuns.where((r) => r.replyTo != run.replyTo).toList();
    notifyListeners();
    final conv = chatOfThread(run.thread);
    final signer = conv != null ? await _signerOf(conv) : identity.signer;
    await api.cancelRun(signer, run.replyTo);
  }

  // Offline sends

  List<ChatMessage> pendingIn(Conversation conv) =>
      [for (final m in _messagesOf(conv)) if (m.pending != null) m];

  void _watchPending() {
    _pendingTimer ??= Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_flushing || _gone) return;
      if (api.offline) await refreshBalance();
      if (!api.offline && !_gone) await flushPending();
    });
  }

  Future<void> _parkOffline(ChatTurn turn, ChatMessage mine) async {
    final conv = turn.conv;
    final list = _messagesOf(conv);
    final next = [
      for (final m in list)
        if (m.id == mine.id)
          ChatMessage.fromJson({...m.toJson(), 'pending': 'offline'})
        else
          m
    ];
    if (conv.id == current?.id) messages = next;
    await store.saveMessages(conv.id, next);
    _parked[turn.prepared!.eventId] = turn;
    _offlineHeld[mine.id] = turn;
    turn.phase = 'offline';
    turn.status = t('Waiting for connection');
    _watchPending();
    notifyListeners();
  }

  final Map<String, ChatTurn> _offlineHeld = {};

  Future<void> flushPending() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final groups = <String, List<Conversation>>{};
      for (final conv in [...conversations]) {
        if (pendingIn(conv).isEmpty) continue;
        final key = conv.anon
            ? '${(await anon.identityFor(conv.anonPk))['pk']}'
            : '';
        (groups[key] ??= []).add(conv);
      }
      var group = 0;
      for (final convs in groups.values) {
        if (group++ > 0) await Jitter.wait();
        for (final conv in convs) {
          for (final m in pendingIn(conv)) {
            final held = _offlineHeld.remove(m.id);
            final list = _messagesOf(conv);
            if (held != null && held.prepared != null) {
              _parked.remove(held.prepared!.eventId);
              final next = [for (final x in list) x.id == m.id ? x.copyWith(sent: true) : x];
              if (conv.id == current?.id) messages = next;
              await store.saveMessages(conv.id, next);
              await _redeliver(held);
            } else {
              await _dropMessage(conv, m);
              await send(m.content,
                  target: conv, withAttachments: m.attachments, withQuote: m.quote);
            }
            if (api.offline) return;
          }
        }
      }
      if (conversations.every((c) => pendingIn(c).isEmpty)) {
        _pendingTimer?.cancel();
        _pendingTimer = null;
      }
    } finally {
      _flushing = false;
    }
  }

  Future<String?> editPending(ChatMessage m) async {
    final conv = current;
    if (conv == null || m.pending == null) return null;
    final held = _offlineHeld.remove(m.id);
    if (held?.prepared != null) _parked.remove(held!.prepared!.eventId);
    await _dropMessage(conv, m);
    if (m.attachments.isNotEmpty) attachments = [...attachments, ...m.attachments];
    if (m.quote != null) quote = m.quote;
    notifyListeners();
    return m.content;
  }

  Future<void> deletePending(ChatMessage m) async {
    final conv = current;
    if (conv == null || m.pending == null) return;
    final held = _offlineHeld.remove(m.id);
    if (held?.prepared != null) _parked.remove(held!.prepared!.eventId);
    await _dropMessage(conv, m);
  }

  /// The last few turns, as a seed for a model new to this thread.
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

  /// Two models, each on its own thread, leaving this chat untouched until one is kept; charged twice.
  Future<List<CompareRun>> compare(
      String text, List<Map<String, dynamic>> models) async {
    final conv = current;
    if (conv == null || models.length < 2) return const [];
    final body = text.trim();
    if (body.isEmpty) return const [];

    final caps = List<double?>.filled(models.length, null);
    if (SpendCaps.any(conv, botOf(conv))) {
      final ests = [
        for (final model in models)
          ChatEngine.estimate(body, model,
              conv: conv,
              hasRepos: reposOf(conv).isNotEmpty,
              web: webOn,
              history: ChatEngine.estHistoryOf(_messagesOf(conv)),
              pricing: catalogPricing),
      ];
      final pro = ests.any((e) => e.tier == 'pro');
      final sats = ests.fold<double>(
          0, (n, e) => n + SpendCaps.satsFor(e.max, e.tier == 'pro'));
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

    if (conv.anon) {
      try {
        await anon.bind(conv);
        await store.saveConversations(conversations);
      } catch (_) {}
    }

    final seed = compareSeed();
    final scoped = activeRepos;
    final persona = activePersona;
    final space = activeWorkspace;
    final bot = activeBot;

    Future<CompareRun> once(Map<String, dynamic> model, double? maxCost) async {
      final turn = ChatTurn(conv, label: _labelOf(body));
      turn.kind = 'compare';
      turns[turn.key] = turn;
      notifyListeners();
      final scratch = Conversation(
        id: 'cmp-${bytesToHex(randomBytes(6))}',
        rootId: bytesToHex(randomBytes(32)),
        anon: conv.anon,
        anonPk: conv.anonPk,
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
          webSearch: webOn,
          firstTurn: true,
          // Neither run touches the stored thread; the seed carries the context.
          fresh: true,
          onThreadIds: (_) {},
          control: turn.control,
          runExtras: _runExtras(conv, kind: 'compare'),
          onPrepared: (p) {
            turn.prepared = p;
            turn.sent = true;
          },
          slot: () async {
            await _takeSlot(turn);
            return () {};
          },
        );
        _endTurn(turn);
        return CompareRun(
          model: model,
          reply: res.reply,
          thinking: res.thinking,
          cost: res.cost,
          sources: res.sources,
          followUps: res.followUps,
        );
      } on ChatFailure catch (e) {
        _endTurn(turn);
        return CompareRun(model: model, error: e.message);
      } catch (e) {
        _endTurn(turn);
        return CompareRun(model: model, error: e.toString());
      }
    }

    final out = await Future.wait(
        [for (var i = 0; i < models.length; i++) once(models[i], caps[i])]);

    final spent = out.fold<double>(0, (n, r) => n + r.cost);
    if (spent > 0) await store.recordUsage(spent);
    if (spent > 0) {
      _bumpSpent(conv, spent, true);
      await store.saveConversations(conversations);
    }
    notifyListeners();
    return out;
  }

  /// Folds the kept answer in by moving the chat to a fresh thread seeded with the transcript, as a branch does.
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

  List<ChatMessage> _messagesOf(Conversation conv) =>
      conv.id == current?.id ? messages : store.messages(conv.id);

  CostEstimate _capEstimate(Conversation conv, String body,
      {Map<String, dynamic>? model}) {
    if (model == null && conv.id == current?.id) return estimate(body);
    return ChatEngine.estimate(body, model ?? modelOf(conv),
        conv: conv,
        hasRepos: reposOf(conv).isNotEmpty,
        web: webOn,
        history: ChatEngine.estHistoryOf(_messagesOf(conv)),
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

  /// Continues a capped repo run leg by leg within the user's budget, reporting each leg's cost.
  Future<void> _carryOn(ChatTurn turn, TurnResult first,
      {Map<String, dynamic>? asked}) {
    final conv = turn.conv;
    final research = turn.research;
    final model = asked ?? turn.model ?? modelOf(conv);
    return _carryOnWith(turn, first, (token) async {
      turn.prepared = await chat.prepare(
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
        webSearch: webOn,
        resume: token,
        research: research,
        runExtras: {
          ..._runExtras(conv),
          ...await _grantFor(conv, model,
              research: research,
              team: turn.team,
              spent: turn.continuedSpend),
        },
        onTurn: (eventId) => _watchTurn(turn, eventId),
        onStep: (step) => _localStep(turn, step),
      );
      if (turn.stopped) throw ChatFailure(t('Stopped.'), cancelled: true);
      return _deliver(turn);
    }, model: model);
  }

  @visibleForTesting
  Future<void> landResultForTest(ChatTurn turn, TurnResult res) async {
    await _land(turn, res);
  }

  Future<bool> commonFailureForTest(ChatTurn turn, ChatFailure e) =>
      _commonFailure(turn, e);

  Future<void> carryOnWithForTest(ChatTurn turn, TurnResult first,
          Future<TurnResult> Function(String token) leg) =>
      _carryOnWith(turn, first, leg);

  Future<void> _stallPause(ChatTurn turn, Duration wait, int attempt) async {
    final until = DateTime.now().add(wait);
    transcripts.note(turn, stallLine(wait, attempt), retry: true);
    transcripts.hush(turn, true);
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
    transcripts.hush(turn, false);
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
          conv: conv, replyTo: _linkOf(turn));
      return;
    }
    if (token == null || token.isEmpty) {
      await note(t('That answer stopped early and could not be resumed. Ask again to pick it up.'),
          conv: conv, replyTo: _linkOf(turn));
      return;
    }
    await _askBackgroundOnce(turn, model ?? modelOf(conv));
    var left = research != null
        ? double.infinity
        : continueBudgetAfter(turn.continuedSpend);
    if (stall == null && left <= 0) {
      await note(t('That answer stopped early — the task needs more steps than one '
          'turn holds. Set “When a repo task runs out of room” in Settings and '
          'Nymbot will carry on by itself.'), conv: conv, replyTo: _linkOf(turn));
      return;
    }
    if (stall == null && reserve > left) {
      await note(t('That answer stopped early. Carrying on reserves {n} more credits than the budget left.',
          {'n': creditFigure(reserve - left)}), conv: conv, replyTo: _linkOf(turn));
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
            conv: conv, replyTo: _linkOf(turn));
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
        if (e.cancelled || turn.stopped) return;
        if (e.pending || e.lost) {
          _startClaim(turn);
          return;
        }
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
              {'n': wait.inSeconds}), conv: conv, replyTo: _linkOf(turn));
          await _legPause(turn, wait);
          continue;
        }
        if (again != null && again.isNotEmpty) {
          await note(t('Stopped there — the gateway stayed busy. The work so '
              'far is saved, so ask it to carry on later.'), conv: conv, replyTo: _linkOf(turn));
          return;
        }
        if (e.capExceeded) {
          await note(t('Stopped: carrying on could go past this chat\'s spending cap.'),
              conv: conv, replyTo: _linkOf(turn));
          return;
        }
        await note(e.message, conv: conv, replyTo: _linkOf(turn));
        return;
      } catch (_) {
        _stopWatching(turn);
        turn.status = null;
        if (turn.stopped) return;
        await note(t('Could not carry on from there.'), conv: conv, replyTo: _linkOf(turn));
        return;
      }
      stalls = 0;
      _stopWatching(turn);
      turn.status = null;

      final prepared = turn.prepared;
      if (prepared != null && prepared.plan.isNotEmpty) turn.plan = prepared.plan;
      if (turn.stopped || (prepared?.stopped ?? false)) {
        if (!turn.stopped) {
          turn.stopped = true;
          turn.outcome = 'stopped';
          await note(t('Stopped.'), conv: conv, replyTo: _linkOf(turn));
        }
        return;
      }
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
        actions: next.actions,
        team: Team.normalize(next.team),
        replyTo: _linkOf(turn),
      );
      turn.outcome = _outcomeOf(next);
      await _addTo(conv, more);
      await harvestArtifacts(more, conv: conv);
      final handed = prepared?.background;
      _bumpSpent(conv, next.cost + next.serverRunCredits, next.pro);
      conv.messageCount += 1;
      conv.creditsSpent += next.cost + next.serverRunCredits;
      _touch(conv);
      await store.saveConversations(conversations);
      await store.recordUsage(next.cost);
      turn.continuedSpend += next.cost;
      _creditBalance(next.pro, next.balance,
          anonKey: conv.anon, anonPk: conv.anonPk);
      if (handed != null) {
        turn.outcome = 'background';
        await _trackBackground(turn, handed);
        return;
      }

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
            'Nymbot will carry on by itself.'), conv: conv, replyTo: _linkOf(turn));
        return;
      }
      if (token != null && token.isNotEmpty && reserve > left) {
        await note(t('Stopped: carrying on again needs {n} credits and {left} are left in the budget.',
            {'n': creditFigure(reserve), 'left': creditFigure(left)}), conv: conv, replyTo: _linkOf(turn));
        return;
      }
      if (token != null && token.isNotEmpty && left <= 0) {
        await note(t('Budget spent — {n} credits on carrying that on. Raise it in Settings to go further.',
            {'n': creditFigure(turn.continuedSpend)}), conv: conv, replyTo: _linkOf(turn));
        return;
      }
    }
    if (token != null && token.isNotEmpty && stall != null && !turn.stopped) {
      await note(t('Stopped there — the gateway stayed busy. The work so '
          'far is saved, so ask it to carry on later.'), conv: conv, replyTo: _linkOf(turn));
      return;
    }
    if (turn.continuedSpend > 0 && (token == null || token.isEmpty)) {
      await note(t('Finished. Carrying on cost {n} extra credits.', {'n': creditFigure(turn.continuedSpend)}),
          conv: conv, replyTo: _linkOf(turn));
    }
  }

  // Balances

  @visibleForTesting
  void creditBalanceForTest(bool pro, double? value, {required bool anonKey}) =>
      _creditBalance(pro, value, anonKey: anonKey);

  void _creditBalance(bool pro, double? value,
      {required bool anonKey, String? anonPk}) {
    if (value == null) return;
    if (anonKey) {
      final key = anon.heldFor(anonPk)?['pk'] as String? ?? shownAnonPk;
      unawaited(pro
          ? anon.noteBalance(key, pro: value)
          : anon.noteBalance(key, standard: value));
      if (key != shownAnonPk) return;
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
      inv.anon ? await anon.signer(pk: inv.anonPk) : identity.signer;

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

  Future<bool> createInvoice(int credits, String tier, {bool toAnon = false}) async {
    if (invoiceBusy) return false;
    if (credits <= 0) {
      _invoiceSay(t('Enter how many credits to buy.'), warn: true);
      return false;
    }
    final sats = credits * (NymbotConfig.satsPerCredit[tier] ?? 10);
    invoiceBusy = true;
    _invoiceSay(t('Creating an invoice…'));
    final inAnonChat = current?.anon ?? false;
    final useAnon = inAnonChat || toAnon;
    final anonPk = useAnon
        ? (await anon.identityFor(inAnonChat ? current?.anonPk : null))['pk']
            as String
        : null;
    final signer = useAnon ? await anon.signer(pk: anonPk) : identity.signer;
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
      anonPk: anonPk,
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
        if (inv.anon) {
          _creditBalance(inv.tier == 'pro',
              (claim.data['balanceCredits'] as num?)?.toDouble() ??
                  (claim.data['balance'] as num?)?.toDouble(),
              anonKey: true,
              anonPk: inv.anonPk);
        }
        _invoiceSay(inv.anon && !spendingAnon
            ? t('Credited to the throwaway key: {balance}. Start an anonymous '
                'chat to spend them.', {'balance': figure(claim.data['balance'])})
            : t('Credited. Balance: {balance}.',
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
    _resumeRuns();
    if (_entered) relays.wake();
    if (_entered) unawaited(sync.kick());
    if (_entered) unawaited(fetchSupport());
    await refreshNotices();
    await refreshBalance();
    await resumeInvoice();
    if (_entered) await runDueSchedules();
  }

  Future<SyncRound> refreshSync() {
    return sync.refresh().timeout(const Duration(seconds: 15),
        onTimeout: () => const SyncRound.failed());
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
    final inAnonChat = current?.anon ?? false;
    final res = await api.balance(identity.signer);
    if (res.data['error'] != null) {
      if (announce) await note(t('Could not reach Nymbot to check your balance.'));
      return;
    }
    standardBalance = (res.data['balanceCredits'] as num?)?.toDouble()
        ?? (res.data['balance'] as num?)?.toDouble() ?? 0;
    proBalance = (res.data['proBalanceCredits'] as num?)?.toDouble()
        ?? (res.data['proBalance'] as num?)?.toDouble() ?? 0;
    final shown = shownAnonPk;
    final shownId = anon.heldFor(shown);
    if (shownId != null) {
      final mine = await api.balance(anon.signerOf(shownId));
      if (mine.data['error'] == null) {
        anonStandardBalance = _figureOf(mine.data, false);
        anonProBalance = _figureOf(mine.data, true);
        _anonShownFor = shown;
        await anon.noteBalance(shown,
            standard: anonStandardBalance, pro: anonProBalance);
      }
    } else {
      anonStandardBalance = null;
      anonProBalance = null;
    }
    // The worker is authoritative per key; the device count stops a fresh key resetting the day.
    final seen = FreeAllowance.fromJson(res.data['free']);
    if (seen != null) {
      free = seen;
      await store.freeTier.observe(seen.used);
    }
    notifyListeners();
    if (announce) {
      await note(inAnonChat
          ? t("This chat's anonymous balance: {standard} Standard, {pro} Pro. "
              'All your anonymous keys hold {totalStandard} Standard and {totalPro} Pro, the others as of their last use. '
              'Your nym still holds {nymStandard} Standard and {nymPro} Pro.', {
              'standard': creditFigure(anonStandardBalance),
              'pro': creditFigure(anonProBalance),
              'totalStandard': creditFigure(anonTotalStandard),
              'totalPro': creditFigure(anonTotalPro),
              'nymStandard': creditFigure(standardBalance),
              'nymPro': creditFigure(proBalance),
            })
          : t('Your balance: {standard} Standard, {pro} Pro.', {
              'standard': creditFigure(standardBalance),
              'pro': creditFigure(proBalance)
            }));
    }
  }

  bool get proTier => activeModel != null || mediaNeedsPro(activeMediaModel);

  bool get spendingAnon => current?.anon ?? false;

  String? get shownAnonPk =>
      anon.heldFor(current?.anonPk)?['pk'] as String? ?? anon.pubkey;

  static double _figureOf(Map<String, dynamic> data, bool pro) =>
      (data[pro ? 'proBalanceCredits' : 'balanceCredits'] as num?)?.toDouble() ??
      (data[pro ? 'proBalance' : 'balance'] as num?)?.toDouble() ??
      0;

  double? get shownBalance => spendingAnon
      ? (proTier ? anonProBalance : anonStandardBalance)
      : (proTier ? proBalance : standardBalance);

  /// True only once the balances are known and neither the nym nor any throwaway key holds credits.
  bool get freeOnly {
    final standard = standardBalance, pro = proBalance;
    if (standard == null || pro == null) return false;
    if (standard > 0 || pro > 0) return false;
    final held = anon.knownTotals();
    return !((anonStandardBalance ?? 0) > 0 ||
        (anonProBalance ?? 0) > 0 ||
        (held.standard ?? 0) > 0 ||
        (held.pro ?? 0) > 0);
  }

  bool get webOn => settings.webSearch && !freeOnly;

  /// The lower of the worker's and the device's remaining count; null when the free tier is not in play.
  int? get freeLeft {
    final held = free;
    if (held == null || held.limit <= 0) return null;
    final here = store.freeTier.leftOf(held.limit);
    return held.left < here ? held.left : here;
  }

  /// False only on the free tier with the day spent; the device count must never reach the worker.
  bool get freeAllows {
    if (proTier) return true;
    if ((standardBalance ?? 0) > 0) return true;
    final held = free;
    if (held == null || held.limit <= 0) return true;
    return store.freeTier.allows(held.limit, (standardBalance ?? 0).floor());
  }

  /// Phrased as a time and a price, not a wall.
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
  int _pricingTriedAt = 0;

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
    final unpriced = catalog['priceUnavailable'] == true || usd <= 0;
    if (unpriced && catalog['priceUnavailable'] != true) return;
    catalogPricing = {
      'usdPerCredit': unpriced ? null : usd,
      'priceUnavailable': unpriced,
      'standardUsdPerCredit': catalog['standardUsdPerCredit'],
      'standardRoutes': catalog['standardRoutes'],
      'btcUsd': catalog['btcUsd'],
      'minChargeCredits': catalog['minChargeCredits'],
      'estimate': catalog['estimate'],
      'bulkBonus': catalog['bulkBonus'],
      'researchByKey': Research.researchByKey(catalog),
      'models': [
        for (final m in (catalog['models'] as List?) ?? const [])
          if (m is Map && (m['kind'] == null || m['kind'] == 'chat') && m['command'] == null)
            Map<String, dynamic>.from(m),
      ],
      'aliases': catalog['aliases'] is Map ? Map<String, dynamic>.from(catalog['aliases'] as Map) : const <String, dynamic>{},
    };
    notifyListeners();
  }

  Future<void> ensurePricing() async {
    if (catalogPricing != null && catalogPricing!['priceUnavailable'] != true) {
      return;
    }
    notePricing(await api.models());
  }

  CostEstimate estimate(String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (catalogPricing == null && now - _pricingTriedAt > 60000) {
      _pricingTriedAt = now;
      unawaited(ensureMentionCatalog());
    }
    final media = activeMediaModel;
    if (activeModel == null &&
        mediaNeedsPro(media) &&
        media!['credits'] is num &&
        withMediaModel(text) != text) {
      return ChatEngine.generatorEstimate(media);
    }
    return _chatEstimate(text);
  }

  CostEstimate _chatEstimate(String text) => ChatEngine.estimate(text, activeModel,
      conv: current,
      hasRepos: activeRepos.isNotEmpty,
      pricing: catalogPricing,
      history: ChatEngine.estHistoryOf(messages),
      web: webOn,
      // Priced on the full wire text, which decides how many wraps (and credits) it needs.
      wireText: _wireTextNow(text));

  String _wireTextNow(String text) {
    final conv = current;
    if (conv == null) return text;
    final used = chat.skillWire(conv, text);
    text = used.text;
    final head = ChatEngine.preamble(conv, activeRepos, activePersona,
        activeWorkspace, activeBot, text, store.memories(), used.blocks);
    final attached = attachments.map((a) => a.wireBlock).join();
    final searched = DocLibrary.instance.wireFor(conv.id, text, attachments);
    return '$head$text$attached$searched';
  }

  /// Cycles normal, careful, deep; each step is another billed model call.
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
      if (conv.support) continue;
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
    // Signed while the key is still here; bounded so a hung signer cannot block the wipe.
    if (purge && signedIn) {
      await api.purgeAccount(identity.signer).timeout(
            const Duration(seconds: 3),
            onTimeout: () => false,
          );
    }
    _bgTimer?.cancel();
    _bgTimer = null;
    backgroundRuns = [];
    await replyNotify.channel.checks(false);
    if (unifiedPushOn) await replyNotify.channel.upUnregister();
    _stopSupport();
    _supportSeen = null;
    _supportWraps.clear();
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
    for (final turn in turns.values) {
      turn.stopped = true;
      turn.control.cancel();
    }
    turns.clear();
    _parked.clear();
    _offlineHeld.clear();
    remoteRuns = [];
    _farSteers.clear();
    signedIn = false;
    _entered = false;
    notifyListeners();
  }
}

class ChatTurn {
  ChatTurn(this.conv, {String? key, this.askId, this.msgId, this.label = ''})
      : key = key ?? bytesToHex(randomBytes(8));

  final Conversation conv;
  final String key;

  String? askId;

  String? msgId;
  String label;
  String kind = 'chat';
  final TurnControl control = TurnControl();
  String? status;

  String phase = 'running';
  PreparedTurn? prepared;
  bool sent = false;
  bool holdsSlot = false;
  Completer<void>? slotWait;
  String? progress;
  List<Map<String, dynamic>> plan = [];
  List<Map<String, dynamic>> branches = [];
  bool unattended = false;

  /// The running turn's steps, newest last; emptied when a turn ends.
  List<TurnStep> steps = [];
  List<Map<String, dynamic>> log = [];
  String? draft;
  bool drafted = false;
  final DateTime began = DateTime.now();

  DateTime? since;
  bool kept = false;
  bool watching = false;
  bool stopped = false;
  String? outcome;

  Object? research;
  Map<String, dynamic>? team;
  Map<String, dynamic>? model;

  /// Credits spent continuing the current run, so the budget covers the whole task.
  double continuedSpend = 0;

  String get runId => prepared?.replyTo ?? msgId ?? prepared?.msgId ?? '';

  bool get live => phase == 'running' && sent && !stopped;
}

class _FarSteer {
  _FarSteer(this.runId, this.text, this.convId, this.signer, this.at);

  final String runId;
  final String text;
  final String? convId;
  final EventSigner signer;
  final DateTime at;
  int tries = 0;
}

typedef RemoteRun = ({
  String replyTo,
  String thread,
  String kind,
  String label,
  String progress,
  List<Map<String, dynamic>> plan,
  String state,
  int startedAt,
  int updatedAt,
  List<Map<String, dynamic>> branches,
  bool background,
  int until,
});
