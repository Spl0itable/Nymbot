import 'dart:typed_data';

import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart';
import '../models/nostr_event.dart';
import 'canary.dart';
import 'nostr/event_signer.dart';
import 'support_thread.dart';

const int kContactMaxChars = 2000;

const List<String> kContactTopics = [
  'General feedback',
  'Bug report',
  'Feature request',
  'Question',
];

enum ContactOutcome { sent, empty, tooLong, refused, failed }

typedef ContactPublish = Future<int> Function(NostrEvent event,
    {Duration? timeout});

typedef ContactKem = Future<Uint8List?> Function(String pubkey);

String contactBody(String topic, String message) =>
    '[Nymbot contact — $topic]\n\n$message';

class DevContact {
  DevContact({
    required this.signer,
    required this.publish,
    required this.kem,
    this.recipient = kDeveloperPubkey,
    this.token,
    this.selfKem,
  });

  final EventSigner signer;
  final ContactPublish publish;
  final ContactKem kem;
  final String recipient;
  final String? token;
  final Uint8List? selfKem;

  SupportMessage? lastSent;

  ContactOutcome? _check(String text) {
    if (text.isEmpty) return ContactOutcome.empty;
    if (text.length > kContactMaxChars) return ContactOutcome.tooLong;
    return null;
  }

  Future<ContactOutcome> send(String topic, String message) async {
    final text = message.trim();
    final refused = _check(text);
    if (refused != null) return refused;
    final subject = kContactTopics.contains(topic) ? topic : kContactTopics.first;
    return _deliver(contactBody(subject, text));
  }

  Future<ContactOutcome> reply(String message) async {
    final text = message.trim();
    final refused = _check(text);
    if (refused != null) return refused;
    return _deliver(text);
  }

  Future<ContactOutcome> _deliver(String body) async {
    try {
      Uint8List? peerKem;
      try {
        peerKem = await kem(recipient);
      } catch (_) {
        peerKem = null;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final tag = token;
      final rumor = UnsignedEvent(
        pubkey: signer.pubkey,
        createdAt: now ~/ 1000,
        kind: 14,
        tags: [
          ['p', recipient],
          ['x', bytesToHex(randomBytes(32))],
          ['ms', '$now'],
          if (tag != null) [kSupportTag, tag],
        ],
        content: body,
      );
      final outer = [
        if (tag != null) ['t', tag],
      ];
      final wrap = await giftwrap.sealAndWrap(
        rumor: rumor,
        signer: signer,
        recipientPubkey: recipient,
        recipientKemPublicKey: peerKem,
        extraTags: outer,
      );
      final accepted =
          await publish(wrap, timeout: const Duration(seconds: 6));
      if (accepted <= 0) return ContactOutcome.refused;
      final id = NostrEvent(
        pubkey: signer.pubkey,
        createdAt: rumor.createdAt,
        kind: rumor.kind,
        tags: rumor.tags,
        content: rumor.content,
      ).computeId();
      lastSent = (id: id, mine: true, content: body, at: now);
      try {
        final copy = await giftwrap.sealAndWrap(
          rumor: rumor,
          signer: signer,
          recipientPubkey: signer.pubkey,
          recipientKemPublicKey: selfKem,
          extraTags: outer,
        );
        await publish(copy, timeout: const Duration(seconds: 4));
      } catch (_) {}
      return ContactOutcome.sent;
    } catch (_) {
      return ContactOutcome.failed;
    }
  }
}
