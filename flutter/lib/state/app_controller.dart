import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../config.dart';
import '../core/crypto/keys.dart';
import '../features/i18n/i18n.dart';
import '../models/conversation.dart';
import '../services/anon.dart';
import '../services/chat_engine.dart';
import '../services/nymbot_api.dart';
import '../services/pq_announce.dart';
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
    await anon.load();
    c.signedIn = await identity.restore();
    c._loadSettings();
    return c;
  }

  final Store store;
  final Identity identity;
  final RelayPool relays;
  final PqAnnounce pq;
  final NymbotApi api;
  final AnonMode anon;

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
  String? status;
  int relaysUp = 0;

  List<Conversation> conversations = [];
  Conversation? current;
  List<ChatMessage> messages = [];

  Map<String, dynamic>? proModel;
  Map<String, dynamic>? git;
  int? standardBalance;
  int? proBalance;

  // --- settings ----------------------------------------------------------------

  void _loadSettings() {
    final raw = store.getString('settings');
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      proModel = j['proModel'] as Map<String, dynamic>?;
      git = j['git'] as Map<String, dynamic>?;
    } catch (_) {}
  }

  Future<void> _saveSettings() =>
      store.setString('settings', jsonEncode({'proModel': proModel, 'git': git}));

  Future<void> setProModel(Map<String, dynamic>? model) async {
    proModel = model;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setAnonEnabled(bool on) async {
    await anon.setEnabled(on);
    if (on) await anon.flush(identity: identity.signer);
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

  Future<void> setGit(Map<String, dynamic>? config) async {
    git = config;
    await _saveSettings();
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
    if (conversations.isEmpty) {
      await newConversation();
    } else {
      await open(conversations.first);
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
    );
    conversations.insert(0, conv);
    await store.saveConversations(conversations);
    await open(conv);
    return conv;
  }

  Future<void> open(Conversation conv) async {
    current = conv;
    messages = store.messages(conv.id);
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

  Future<void> deleteCurrent() async {
    final conv = current;
    if (conv == null) return;
    conversations.removeWhere((c) => c.id == conv.id);
    await store.saveConversations(conversations);
    await store.dropConversation(conv.id);
    if (conversations.isEmpty) {
      await newConversation();
    } else {
      await open(conversations.first);
    }
  }

  /// A fresh root id is what actually resets the model's context: the worker
  /// scopes history to the marker, so a new one is a new thread.
  Future<void> clearCurrent() async {
    final conv = current;
    if (conv == null) return;
    conv.rootId = bytesToHex(randomBytes(32));
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

  // --- sending -------------------------------------------------------------------

  Future<void> send(String text) async {
    final conv = current;
    if (conv == null || sending || text.trim().isEmpty) return;
    final body = text.trim();

    await _add(ChatMessage(
      id: bytesToHex(randomBytes(8)),
      role: ChatRole.self,
      content: body,
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

    try {
      final res = await chat.send(
        rootId: conv.rootId,
        anonymous: conv.anon,
        text: body,
        proModel: proModel,
        git: git,
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
        model: res.pro ? (proModel?['label'] as String?) : null,
      ));
      _touch(conv);
      await store.saveConversations(conversations);
      if (res.balance != null) {
        if (res.pro) {
          proBalance = res.balance;
        } else {
          standardBalance = res.balance;
        }
      }
      if (res.lowBalance) {
        await note(res.pro
            ? t('Pro credits running low: {n} left. Tap Buy to top up.',
                {'n': res.balance})
            : t('Credits running low: {n} left. Tap Buy to top up.',
                {'n': res.balance}));
      }
    } on ChatFailure catch (e) {
      if (e.noCredits) {
        if (e.pro) {
          proBalance = e.balance;
        } else {
          standardBalance = e.balance;
        }
        await note(e.message);
      } else {
        await _add(ChatMessage(
          id: bytesToHex(randomBytes(8)),
          role: ChatRole.error,
          content: e.message,
        ));
      }
    } catch (e) {
      await _add(ChatMessage(
        id: bytesToHex(randomBytes(8)),
        role: ChatRole.error,
        content: t('Something went wrong sending that message.'),
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
      if (announce) await note('Could not reach Nymbot to check your balance.');
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

  int? get shownBalance => proModel != null ? proBalance : standardBalance;

  String get satsLabel => proModel != null ? 'Pro' : 'Standard';

  int satsFor(int credits, String tier) =>
      credits * (NymbotConfig.satsPerCredit[tier] ?? 10);

  Future<void> wipe() async {
    _bootWork?.cancel();
    await store.wipe();
    identity.forget();
    relays.close();
    conversations = [];
    messages = [];
    current = null;
    signedIn = false;
    _entered = false;
    notifyListeners();
  }
}
