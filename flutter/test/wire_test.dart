import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/core/crypto/gift_wrap.dart' as giftwrap;
import 'package:nymbot/core/crypto/keys.dart';
import 'package:nymbot/core/crypto/pq.dart' as pq;
import 'package:nymbot/models/nostr_event.dart';

/// The transport a turn actually rides on: a hybrid gift wrap the recipient can
/// open and nobody else can, carrying the conversation marker the worker scopes
/// history by.
void main() {
  test('a hybrid wrap opens for the recipient and nobody else', () async {
    final senderSk = generatePrivateKey();
    final recipientSk = generatePrivateKey();
    final recipientPub = getPublicKeyHex(recipientSk);
    final recipientKem = pq.pqKeypairFromRoot(pq.pqGenerateRoot(), 0);

    final rumor = UnsignedEvent(
      pubkey: getPublicKeyHex(senderSk),
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: 14,
      tags: [
        ['p', recipientPub],
        ['nymthread', 'a' * 64],
      ],
      content: 'why does the voucher retry give up early?',
    );

    final wrap = await giftwrap.pq2Nip59Wrap(
      rumor: rumor,
      senderPrivkey: senderSk,
      recipientPubkey: recipientPub,
      recipientKemPublicKey: recipientKem.publicKey,
    );

    expect(wrap.kind, 1059);
    // The wrap is signed by a single-use key, never the sender's.
    expect(wrap.pubkey, isNot(getPublicKeyHex(senderSk)));
    expect(wrap.content.contains('voucher'), isFalse);

    final opened = await giftwrap.unwrapGiftWrap(wrap, [
      (
        sk: recipientSk,
        bitchat: false,
        kemSk: recipientKem.secretKey,
        kemPk: recipientKem.publicKey,
      ),
    ]);
    expect(opened, isNotNull);
    expect(opened!.isPq, isTrue);
    expect(opened.rumor['content'], rumor.content);
    // The seal names the real sender; the wrap never does.
    expect(opened.seal.pubkey, getPublicKeyHex(senderSk));

    // The conversation marker survives, which is what keeps chats separate.
    final tags = (opened.rumor['tags'] as List).cast<List>();
    expect(
      tags.firstWhere((t) => t.first == 'nymthread')[1],
      'a' * 64,
    );

    // Someone else's key, even with a valid KEM keypair of their own, gets
    // nothing.
    final strangerSk = generatePrivateKey();
    final strangerKem = pq.pqKeypairFromRoot(pq.pqGenerateRoot(), 0);
    final refused = await giftwrap.unwrapGiftWrap(wrap, [
      (
        sk: strangerSk,
        bitchat: false,
        kemSk: strangerKem.secretKey,
        kemPk: strangerKem.publicKey,
      ),
    ]);
    expect(refused, isNull);
  });

  test('a classical wrap still opens, for a recipient with no announced key',
      () async {
    final senderSk = generatePrivateKey();
    final recipientSk = generatePrivateKey();

    final wrap = giftwrap.nip59Wrap(
      rumor: UnsignedEvent(
        pubkey: getPublicKeyHex(senderSk),
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 14,
        tags: const [],
        content: 'hello',
      ),
      senderPrivkey: senderSk,
      recipientPubkey: getPublicKeyHex(recipientSk),
    );

    final opened = await giftwrap
        .unwrapGiftWrap(wrap, [giftwrap.classicalCandidate(recipientSk)]);
    expect(opened, isNotNull);
    expect(opened!.isPq, isFalse);
    expect(opened.rumor['content'], 'hello');
  });

  test('the ML-KEM keypair is a pure function of the root', () {
    final root = pq.pqGenerateRoot();
    final a = pq.pqKeypairFromRoot(root, 0);
    final b = pq.pqKeypairFromRoot(root, 0);
    expect(a.publicKey, b.publicKey);
    // A different epoch is a different key, which is what rotation rests on.
    expect(pq.pqKeypairFromRoot(root, 1).publicKey, isNot(a.publicKey));
  });
}
