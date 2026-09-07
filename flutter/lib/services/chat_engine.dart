import 'dart:async';
import 'dart:typed_data';

import '../config.dart';
import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart';
import '../models/nostr_event.dart';
import '../state/identity.dart';
import 'anon.dart';
import 'nymbot_api.dart';
import 'pq_announce.dart';
import 'relay_pool.dart';
import '../features/i18n/i18n.dart';

class ChatFailure implements Exception {
  ChatFailure(this.message, {this.noCredits = false, this.pro = false, this.balance = 0});

  final String message;
  final bool noCredits;
  final bool pro;
  final int balance;

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
});

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

  /// A reply can carry its chain of thought ahead of the answer.
  static ({String? thinking, String body}) splitThinking(String text) {
    final m = RegExp(r'^\s*<think>([\s\S]*?)</think>\s*', caseSensitive: false)
        .firstMatch(text);
    if (m == null) return (thinking: null, body: text);
    return (thinking: m.group(1)!.trim(), body: text.substring(m.end));
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
    required String rootId,
    required bool anonymous,
    required String text,
    Map<String, dynamic>? proModel,
    Map<String, dynamic>? git,
    required void Function(List<String> ids) onThreadIds,
  }) async {
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
      content: text,
    );

    final botKem = pq.botKey?.pk;
    final wrap = await _wrap(rumor, senderSk, NymbotConfig.botPubkey, botKem);
    final accepted = await relays.publish(wrap, timeout: const Duration(seconds: 5));
    if (accepted == 0) {
      throw ChatFailure(
          t('No relay accepted your message. Check your connection and try again.'));
    }

    // Our own copy, so the conversation restores on another device.
    try {
      final selfWrap = await _wrap(rumor, senderSk, signer.pubkey, selfKem);
      unawaited(relays.publish(selfWrap, timeout: const Duration(seconds: 3)));
    } catch (_) {
      // The archive copy is best effort.
    }

    final announcement =
        useAnon ? await anon.announcement() : pq.selfAnnouncement;
    final extra = <String, dynamic>{
      'eventId': wrap.id,
      'fresh': RegExp(r'^\s*!\s*\S').hasMatch(text),
      if (announcement != null) 'pqAnnouncement': announcement.toJson(),
      if (proModel != null) 'proModel': proModel['key'],
      if (proModel != null && git != null && git['token'] != null && git['repo'] != null)
        'git': {
          'provider': git['provider'] ?? 'github',
          'host': git['host'] ?? '',
          'token': git['token'],
          'repo': git['repo'],
          'branch': git['branch'] ?? '',
          'allowWrites': git['allowWrites'] == true,
        },
    };

    // `pending` means an earlier attempt at this same message is still
    // generating. Asking again with the same event id collects that reply
    // rather than paying for a second one.
    ApiResult res;
    var tries = 0;
    while (true) {
      res = await api.call('pm', signer,
          extra: extra, timeout: NymbotConfig.pmTimeout);
      if (res.data['pending'] != true || tries++ >= 5) break;
      onStatus?.call('Still working on that one…');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
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
    unawaited(relays.publish(replyEvent, timeout: const Duration(seconds: 3)));
    final selfJson = data['selfEvent'];
    NostrEvent? selfEvent;
    if (selfJson is Map<String, dynamic>) {
      selfEvent = NostrEvent.fromJson(selfJson);
      unawaited(relays.publish(selfEvent, timeout: const Duration(seconds: 3)));
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
    );
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
