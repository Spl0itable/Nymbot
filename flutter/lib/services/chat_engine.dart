import 'dart:async';
import 'dart:typed_data';

import '../config.dart';
import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart';
import '../models/bot.dart';
import '../models/conversation.dart';
import '../models/nostr_event.dart';
import '../models/workspace.dart';
import '../state/identity.dart';
import 'anon.dart';
import 'nostr/event_signer.dart';
import 'nymbot_api.dart';
import 'pq_announce.dart';
import 'relay_pool.dart';
import '../features/i18n/i18n.dart';

class ChatFailure implements Exception {
  ChatFailure(this.message,
      {this.noCredits = false,
      this.pro = false,
      this.balance = 0,
      this.cancelled = false});

  final String message;
  final bool noCredits;
  final bool pro;
  final int balance;
  final bool cancelled;

  @override
  String toString() => message;
}

typedef TurnResult = ({
  String reply,
  String? thinking,
  int cost,
  int? balance,
  bool pro,
  int modelCalls,
  bool lowBalance,
  List<String> repos,
  List<Map<String, dynamic>> sources,
  // Set when the run stopped at its tool-call cap with work left. The token
  // buys one more leg; the caller decides whether to spend it.
  bool truncated,
  String? resumeToken,
  int nextReserve,
  String eventId,
});

/// One thing the running turn reported doing.
typedef TurnStep = ({
  int n,
  String kind,
  String text,
  String tool,
  int call,
  int of,
});

typedef CostEstimate = ({String tier, int low, int high});

/// One turn, end to end: seal, publish, ask the worker, open the reply.
class ChatEngine {
  ChatEngine({
    required this.identity,
    required this.relays,
    required this.pq,
    required this.api,
    required this.anon,
  });

  final Identity identity;
  final RelayPool relays;
  final PqAnnounce pq;
  final NymbotApi api;
  final AnonMode anon;

  void Function(String? status)? onStatus;

  bool _cancelled = false;
  bool sending = false;

  void abort() {
    _cancelled = true;
    sending = false;
  }

  static ({String? thinking, String body}) splitThinking(String text) {
    for (final tag in const ['think', 'thinking', 'reasoning']) {
      final m = RegExp(r'^\s*<' '$tag' r'>([\s\S]*?)</' '$tag' r'>\s*',
              caseSensitive: false)
          .firstMatch(text);
      if (m != null) {
        return (thinking: m.group(1)!.trim(), body: text.substring(m.end));
      }
    }
    return (thinking: null, body: text);
  }

  static CostEstimate estimate(String text, Map<String, dynamic>? model) {
    if (model == null) return (tier: 'standard', low: 1, high: 1);
    final bump = text.length > 4000 ? 2 : text.length > 1200 ? 1 : 0;
    final low = (model['credits'] as num?)?.toInt() ?? 1;
    final max = (model['max'] as num?)?.toInt() ?? low;
    final high = max + bump < low ? low : max + bump;
    return (tier: 'pro', low: low, high: high);
  }

  static const knowledgeFileCap = 24000;
  static const knowledgeTotalCap = 90000;

  /// The workspace's files, trimmed to something a context window can hold. A
  /// file that is cut says so, so nothing silently half-arrives.
  static String knowledgeBlock(Workspace? space) {
    final files = space?.files ?? const <KnowledgeFile>[];
    if (files.isEmpty) return '';
    final parts = <String>[];
    var budget = knowledgeTotalCap;
    for (final file in files) {
      if (budget <= 0) break;
      final room = knowledgeFileCap < budget ? knowledgeFileCap : budget;
      final cut = file.body.length > room;
      final text = cut ? file.body.substring(0, room) : file.body;
      budget -= text.length;
      final name = file.name.isEmpty ? 'untitled' : file.name;
      parts.add('--- $name ---\n$text${cut ? '\n[…trimmed to fit]' : ''}');
    }
    final left = files.length - parts.length;
    final tail = left > 0
        ? '\n\n[$left more file(s) not sent — too much to fit]'
        : '';
    return '[project knowledge]\n${parts.join('\n\n')}$tail';
  }

  static String preamble(
    Conversation conv,
    List<GitRepo> repos,
    Persona? persona, [
    Workspace? space,
    Bot? bot,
  ]) {
    final parts = <String>[];
    final instructions = [
      bot?.instructions ?? '',
      persona?.instructions ?? '',
      space?.instructions ?? '',
      conv.systemPrompt,
    ].where((x) => x.trim().isNotEmpty).join('\n\n').trim();
    if (instructions.isNotEmpty) {
      parts.add('[custom instructions]\n$instructions');
    }
    if (repos.length > 1) {
      final lines = <String>[];
      for (var i = 0; i < repos.length; i++) {
        final r = repos[i];
        final branch = r.branch.isEmpty ? '' : '@${r.branch}';
        final access = r.allowWrites ? ', writable' : ', read-only';
        final paths = r.paths.isEmpty ? '' : ' paths: ${r.paths}';
        lines.add('${i + 1}. ${r.repo}$branch (${r.provider}$access)$paths');
      }
      parts.add('[repositories in scope]\n${lines.join('\n')}\n'
          'Refer to a repository by its name when you cite a file.');
    }
    final knowledge = knowledgeBlock(space);
    if (knowledge.isNotEmpty) parts.add(knowledge);
    final seed = conv.seed;
    if (seed != null && seed.isNotEmpty) {
      parts.add('[earlier in this conversation]\n$seed');
    }
    return parts.isEmpty ? '' : '${parts.join('\n\n')}\n\n';
  }

  /// A conversation is named after the first thing you say in it. Done here, on
  /// the device: the worker is never asked to summarise anything, and never
  /// sees the title.
  static String titleFor(String text) {
    var t = text
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'[`*_>#|]'), '')
        .replaceAll(RegExp(r'https?://\S+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (t.isEmpty) return 'New chat';
    final cmd = RegExp(r'^\?(\w+)\s*(.*)$').firstMatch(t);
    if (cmd != null) {
      final rest = cmd.group(2)!.trim();
      t = rest.isEmpty ? cmd.group(1)! : rest;
    }
    t = t.replaceFirst(RegExp(r'^[!\s]+'), '');
    if (t.length <= 48) return t[0].toUpperCase() + t.substring(1);
    final cut = t.substring(0, 48);
    final space = cut.lastIndexOf(' ');
    final trimmed = space > 24 ? cut.substring(0, space) : cut;
    return '${trimmed.replaceFirst(RegExp(r'[,;:.\-]$'), '')}…';
  }

  String _sharedId() => bytesToHex(randomBytes(32));

  /// Publishes the message and collects the reply.
  Future<TurnResult> send({
    required Conversation conv,
    required String text,
    Map<String, dynamic>? proModel,
    List<GitRepo> repos = const [],
    Persona? persona,
    Workspace? workspace,
    Bot? bot,
    /// Continues a run parked by an earlier truncated turn.
    String? resume,
    /// Called with the turn's own event id as soon as it is published, so a
    /// watcher can start before the answer comes back.
    void Function(String eventId)? onTurn,
    List<Attachment> attachments = const [],
    String? quote,
    bool webSearch = false,
    bool firstTurn = true,
    required void Function(List<String> ids) onThreadIds,
  }) async {
    final rootId = conv.rootId;
    final anonymous = conv.anon;
    _cancelled = false;
    sending = true;
    if (pq.botKey == null) {
      try {
        await pq.resolveBot();
      } catch (_) {}
    }
    if (relays.connected == 0) {
      throw ChatFailure(
          t('Not connected to any relay yet — your message cannot be published.'));
    }

    // Anonymous mode: the throwaway key signs the rumor, the seal and the
    // request, and the reply comes back to it. The account key signs nothing in
    // this conversation at all.
    final useAnon = anonymous && anon.ready;
    final signer = useAnon ? await anon.signer() : identity.signer;
    final senderSk = signer.privkey;
    final selfKem = useAnon
        ? anon.kemOf(await anon.ensure())?.publicKey
        : identity.kemPublicKey;

    final fresh = RegExp(r'^\s*!\s*\S').hasMatch(text);
    final head =
        (firstTurn || fresh) ? preamble(conv, repos, persona, workspace, bot) : '';
    final quoted = (quote == null || quote.isEmpty)
        ? ''
        : '> ${quote.replaceAll('\n', '\n> ')}\n\n';
    final attached = attachments.map((a) => a.wireBlock).join();
    final wireText = '$head$quoted$text$attached';

    final rumor = UnsignedEvent(
      pubkey: signer.pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: 14,
      tags: [
        ['p', NymbotConfig.botPubkey],
        ['x', _sharedId()],
        ['ms', '${DateTime.now().millisecondsSinceEpoch}'],
        ['nymthread', rootId],
      ],
      content: wireText,
    );

    final botKem = pq.botKey?.pk;
    final wrap = await _wrap(rumor, senderSk, NymbotConfig.botPubkey, botKem);
    final accepted = await relays.publish(wrap, timeout: const Duration(seconds: 5));
    if (accepted == 0) {
      throw ChatFailure(
          t('No relay accepted your message. Check your connection and try again.'));
    }

    // A ghost chat publishes nothing it does not have to. The wrap to the bot
    // is how the message gets there at all; the archive copy and the reply's
    // re-publish are for restoring a conversation later, which is exactly what
    // a ghost chat is refusing.
    final ghost = conv.ephemeral;

    // Our own copy, so the conversation restores on another device.
    if (!ghost) {
      try {
        final selfWrap = await _wrap(rumor, senderSk, signer.pubkey, selfKem);
        unawaited(relays.publish(selfWrap, timeout: const Duration(seconds: 3)));
      } catch (_) {
        // The archive copy is best effort.
      }
    }

    // The turn is now identifiable, so anything watching it can start before
    // the answer comes back.
    if (onTurn != null) {
      try {
        onTurn(wrap.id);
      } catch (_) {}
    }

    final announcement =
        useAnon ? await anon.announcement() : pq.selfAnnouncement;
    final extra = <String, dynamic>{
      'eventId': wrap.id,
      'fresh': fresh,
      if (resume != null && resume.isNotEmpty) 'resume': resume,
      if (announcement != null) 'pqAnnouncement': announcement.toJson(),
      if (webSearch) 'web': true,
      if (attachments.isNotEmpty)
        'attachments': attachments.map((a) => a.toPayload()).toList(),
      if (proModel != null) 'proModel': proModel['key'],
      if (proModel != null && repos.isNotEmpty) 'git': repos.first.toPayload(),
      if (proModel != null && repos.isNotEmpty)
        'repos': repos.map((r) => r.toPayload()).toList(),
    };

    // `pending` means an earlier attempt at this same message is still
    // generating. Asking again with the same event id collects that reply
    // rather than paying for a second one.
    ApiResult res;
    var tries = 0;
    while (true) {
      if (_cancelled) throw ChatFailure(t('Stopped.'), cancelled: true);
      res = await api.call('pm', signer,
          extra: extra, timeout: NymbotConfig.pmTimeout);
      if (res.data['pending'] != true || tries++ >= 5) break;
      onStatus?.call(t('Still working on that one…'));
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    if (_cancelled) throw ChatFailure(t('Stopped.'), cancelled: true);
    final data = res.data;

    if (data['pending'] == true) {
      throw ChatFailure((data['message'] as String?) ??
          'Nymbot is still working on that message — its reply will arrive shortly.');
    }
    if (data['noCredits'] == true) {
      throw ChatFailure(
        (data['error'] as String?) ??
            (data['pro'] == true
                ? t('You are out of Pro credits.')
                : t('You are out of credits.')),
        noCredits: true,
        pro: data['pro'] == true,
        balance: (data['balance'] as num?)?.toInt() ?? 0,
      );
    }
    if (res.status >= 400 || data['error'] != null) {
      throw ChatFailure((data['error'] as String?) ?? 'The request failed.');
    }
    final eventJson = data['event'];
    if (eventJson is! Map<String, dynamic>) {
      throw ChatFailure(t('Nymbot sent no reply.'));
    }

    // Both copies go to the relays: the reply so it restores like any other
    // message, and the bot's self-addressed copy so the worker can re-read its
    // own turn as context next time.
    final replyEvent = NostrEvent.fromJson(eventJson);
    if (!ghost) {
      unawaited(relays.publish(replyEvent, timeout: const Duration(seconds: 3)));
    }
    final selfJson = data['selfEvent'];
    NostrEvent? selfEvent;
    if (selfJson is Map<String, dynamic>) {
      selfEvent = NostrEvent.fromJson(selfJson);
      if (!ghost) {
        unawaited(relays.publish(selfEvent, timeout: const Duration(seconds: 3)));
      }
    }

    final recipient = useAnon ? await anon.recipient() : identity.pqIdentity;
    final opened = await giftwrap.unwrapGiftWrap(replyEvent, [
      (
        sk: senderSk,
        bitchat: false,
        kemSk: recipient?.kemSecretKey,
        kemPk: recipient?.kemPublicKey,
      ),
    ]);
    if (opened == null) {
      throw ChatFailure(t('Nymbot replied, but this device could not decrypt it.'));
    }

    onThreadIds([wrap.id, if (selfEvent != null) selfEvent.id]);

    final split = splitThinking(opened.rumor['content'] as String? ?? '');
    return (
      reply: split.body,
      thinking: split.thinking,
      cost: (data['cost'] as num?)?.toInt() ?? 0,
      balance: (data['balance'] as num?)?.toInt(),
      pro: data['pro'] == true,
      modelCalls: (data['modelCalls'] as num?)?.toInt() ?? 1,
      lowBalance: data['lowBalance'] == true,
      repos: repos.map((r) => r.repo).toList(),
      sources: (data['sources'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
          const <Map<String, dynamic>>[],
      truncated: data['truncated'] == true,
      resumeToken: data['resumeToken'] as String?,
      nextReserve: (data['nextReserve'] as num?)?.toInt() ?? 0,
      eventId: wrap.id,
    );
  }

  /// What the turn answering [eventId] is doing. Purely advisory: a failure
  /// returns nothing rather than disturbing the turn.
  Future<List<TurnStep>> progress(
    EventSigner signer,
    String eventId, {
    int after = 0,
  }) async {
    try {
      final res = await api.call(
        'pm-progress',
        signer,
        extra: {'eventId': eventId, 'after': after},
        timeout: const Duration(seconds: 8),
      );
      final steps = (res.data['steps'] as List?) ?? const [];
      return steps.whereType<Map<String, dynamic>>().map((s) => (
            n: (s['n'] as num?)?.toInt() ?? 0,
            kind: s['kind'] as String? ?? '',
            // One field for "the thing this step is about", whichever name the
            // worker gave it — the tool's own name stays separate so a tool
            // step can say both what it did and what it touched.
            text: (s['text'] ?? s['query'] ?? s['target'] ?? s['model'] ?? '')
                .toString(),
            tool: s['tool'] as String? ?? '',
            call: (s['call'] as num?)?.toInt() ?? 0,
            of: (s['of'] as num?)?.toInt() ?? 0,
          )).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<NostrEvent> _wrap(UnsignedEvent rumor, Uint8List senderSk,
      String recipientPubkey, Uint8List? kemPk) {
    if (kemPk == null) {
      return Future.value(giftwrap.nip59Wrap(
        rumor: rumor,
        senderPrivkey: senderSk,
        recipientPubkey: recipientPubkey,
      ));
    }
    return giftwrap.pq2Nip59Wrap(
      rumor: rumor,
      senderPrivkey: senderSk,
      recipientPubkey: recipientPubkey,
      recipientKemPublicKey: kemPk,
    );
  }
}
