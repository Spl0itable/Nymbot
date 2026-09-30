import 'dart:typed_data';

import '../core/crypto/gift_wrap.dart' as giftwrap;
import '../core/crypto/keys.dart';
import '../models/nostr_event.dart';
import 'canary.dart';
import 'nostr/event_signer.dart';

const int kContactMaxChars = 2000;

const List<String> kContactTopics = [
  'General feedback',
  'Bug report',
  'Feature request',
  'Question',
];

enum ContactOutcome { sent, empty, tooLong, failed }

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
  });

  final EventSigner signer;
  final ContactPublish publish;
  final ContactKem kem;
  final String recipient;

  Future<ContactOutcome> send(String topic, String message) async {
    final text = message.trim();
    if (text.isEmpty) return ContactOutcome.empty;
    if (text.length > kContactMaxChars) return ContactOutcome.tooLong;
    final subject = kContactTopics.contains(topic) ? topic : kContactTopics.first;
    try {
      Uint8List? peerKem;
      try {
        peerKem = await kem(recipient);
      } catch (_) {
        peerKem = null;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final rumor = UnsignedEvent(
        pubkey: signer.pubkey,
        createdAt: now ~/ 1000,
        kind: 14,
        tags: [
          ['p', recipient],
          ['x', bytesToHex(randomBytes(32))],
          ['ms', '$now'],
        ],
        content: contactBody(subject, text),
      );
      final wrap = await giftwrap.sealAndWrap(
        rumor: rumor,
        signer: signer,
        recipientPubkey: recipient,
        recipientKemPublicKey: peerKem,
      );
      final accepted =
          await publish(wrap, timeout: const Duration(seconds: 6));
      return accepted > 0 ? ContactOutcome.sent : ContactOutcome.failed;
    } catch (_) {
      return ContactOutcome.failed;
    }
  }
}
