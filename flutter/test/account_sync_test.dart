import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nymbot/core/crypto/pq.dart' as pq;
import 'package:nymbot/models/conversation.dart';
import 'package:nymbot/models/workspace.dart';
import 'package:nymbot/services/account_sync.dart';
import 'package:nymbot/services/storage_sync.dart';
import 'package:nymbot/state/identity.dart';
import 'package:nymbot/state/store.dart';

class FakeD1 {
  final Map<String, String> rows = {};
  int writes = 0;

  http.Client get client => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        switch (body['action']) {
          case 'settings-set':
            writes++;
            rows[body['category'] as String] = body['blob'] as String;
            return http.Response(jsonEncode({'ok': true}), 200);
          case 'settings-get':
            return http.Response(
              jsonEncode({
                'categories': {
                  for (final e in rows.entries)
                    e.key: {'blob': e.value, 'updatedAt': 1},
                },
              }),
              200,
            );
          default:
            return http.Response(jsonEncode({'ok': true}), 200);
        }
      });
}

const _key = 'ff'
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddee';

Future<({Store store, Identity identity})> device({bool withRoot = true}) async {
  final store = await Store.open();
  final identity = Identity(store);
  await identity.import(_key,
      root: withRoot
          ? Uint8List.fromList(List<int>.filled(pq.pqRootLength, 7))
          : null);
  return (store: store, identity: identity);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('a row is named the way the web app names it', () async {
    final d = await device();
    final sync = AccountSync(
        store: d.store, identity: d.identity, storage: StorageSync());
    final want = 'nymbot-${crypto.sha256.convert(utf8.encode('${d.identity.pubkey}|d1:chats')).toString().substring(0, 48)}';
    expect(sync.categoryFor('chats'), want);
    expect(sync.categoryFor('chats').length, 'nymbot-'.length + 48);
  });

  test('what leaves the device is sealed, and opens again here', () async {
    final d = await device();
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );

    final conv = Conversation(id: 'c1', rootId: 'r1', title: 'Tide tables');
    await d.store.saveConversations([conv]);
    await d.store.saveMessages('c1', [
      ChatMessage(id: 'm1', role: ChatRole.self, content: 'when is high water'),
    ]);

    final round = await sync.run();
    expect(round.isOk, isTrue);

    final everything = d1.rows.values.join('\n');
    expect(everything, isNot(contains('Tide tables')));
    expect(everything, isNot(contains('high water')));
    expect(d1.rows, contains(sync.categoryFor('chats')));
    expect(d1.rows, contains(sync.categoryFor('chat-c1')));

    final remote = await sync.pull();
    expect(remote, isNotNull);
    expect(sync.blocked, isFalse);
    final chats = remote!['chats'] as List;
    expect(chats.single['title'], 'Tide tables');
  });

  test('a chat the account holds lands on a device that never had it',
      () async {
    final d = await device();
    final d1 = FakeD1();
    final storage = StorageSync(client: d1.client);
    final first = AccountSync(
        store: d.store, identity: d.identity, storage: storage);

    await d.store.saveConversations(
        [Conversation(id: 'c1', rootId: 'r1', title: 'Tide tables')]);
    await d.store.saveMessages('c1', [
      ChatMessage(id: 'm1', role: ChatRole.self, content: 'when is high water'),
      ChatMessage(id: 'm2', role: ChatRole.bot, content: '06:14'),
    ]);
    expect((await first.run()).isOk, isTrue);

    await d.store.saveConversations([]);
    await d.store.saveMessages('c1', []);
    final second = AccountSync(
        store: d.store, identity: d.identity, storage: storage);
    final round = await second.run();

    expect(round.isOk, isTrue);
    expect(round.touched, contains('chats'));
    expect(d.store.conversations().single.title, 'Tide tables');
    expect(d.store.messages('c1').map((m) => m.content),
        ['when is high water', '06:14']);
  });

  test('a chat written by the web app opens on the phone', () async {
    final d = await device();
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );

    Future<void> seed(String dTag, Object value) async {
      final plain = jsonEncode({'__cat': dTag, 'v': value});
      d1.rows[sync.categoryFor(dTag)] =
          await d.identity.signer.nip44Encrypt(d.identity.pubkey, plain);
    }

    await seed('chats', [
      {
        'id': 'w1',
        'rootId': 'r9',
        'title': 'From the browser',
        'createdAt': 1000,
        'updatedAt': 2000,
        'stats': {'messages': 2, 'credits': 7},
        'codeWrap': true,
      }
    ]);
    await seed('chat-w1', {
      'id': 'w1',
      'messages': [
        {'id': 'm1', 'role': 'self', 'content': 'hello', 'ts': 1500},
        {'id': 'm2', 'role': 'bot', 'content': 'hi', 'ts': 1600, 'cost': 3},
      ],
    });

    expect((await sync.run()).isOk, isTrue);

    final conv = d.store.conversations().single;
    expect(conv.id, 'w1');
    expect(conv.title, 'From the browser');
    expect(conv.messageCount, 2);
    expect(conv.creditsSpent, 7);
    expect(conv.updatedAt.millisecondsSinceEpoch, 2000);

    final msgs = d.store.messages('w1');
    expect(msgs.map((m) => m.content), ['hello', 'hi']);
    expect(msgs.first.at.millisecondsSinceEpoch, 1500);
    expect(msgs.last.cost, 3);
  });

  test('a chat written here carries both apps\' spellings, and keeps what it '
      'has no field for', () async {
    final d = await device();
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );

    final plain = jsonEncode({
      '__cat': 'chats',
      'v': [
        {
          'id': 'w1',
          'rootId': 'r9',
          'title': 'From the browser',
          'updatedAt': 1,
          'codeWrap': true,
        }
      ]
    });
    d1.rows[sync.categoryFor('chats')] =
        await d.identity.signer.nip44Encrypt(d.identity.pubkey, plain);

    expect((await sync.run()).isOk, isTrue);
    final back = (await sync.pull())!['chats'] as List;
    final conv = back.single as Map<String, dynamic>;

    expect(conv['stats'], {'messages': 0, 'credits': 0.0});
    expect(conv['messageCount'], 0);
    expect(conv['codeWrap'], isTrue);
  });

  test('a ghost chat is never written to the account', () async {
    final d = await device();
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );

    await d.store.saveConversations([
      Conversation(id: 'keep', rootId: 'r1', title: 'Kept'),
      Conversation(id: 'ghost', rootId: 'r2', title: 'Gone', ephemeral: true),
    ]);
    await d.store.saveMessages('ghost', [
      ChatMessage(id: 'g1', role: ChatRole.self, content: 'not for the server'),
    ]);

    expect((await sync.run()).isOk, isTrue);
    final chats = (await sync.pull())!['chats'] as List;
    expect(chats.map((c) => (c as Map)['id']), ['keep']);
    expect(d1.rows, isNot(contains(sync.categoryFor('chat-ghost'))));
  });

  test('deleting on one device is not undone by another that still has it',
      () async {
    final d = await device();
    final d1 = FakeD1();
    final storage = StorageSync(client: d1.client);
    final first = AccountSync(
        store: d.store, identity: d.identity, storage: storage);

    await d.store.saveConversations([
      Conversation(id: 'c1', rootId: 'r1', title: 'One'),
      Conversation(id: 'c2', rootId: 'r2', title: 'Two'),
    ]);
    expect((await first.run()).isOk, isTrue);

    await d.store.bury('c2');
    await d.store.saveConversations(
        [Conversation(id: 'c1', rootId: 'r1', title: 'One')]);
    final second = AccountSync(
        store: d.store, identity: d.identity, storage: storage);
    expect((await second.run()).isOk, isTrue);

    expect(d.store.conversations().map((c) => c.id), ['c1']);
    final chats = (await second.pull())!['chats'] as List;
    expect(chats.map((c) => (c as Map)['id']), ['c1']);
  });

  test('newest wins where two devices changed the same chat', () async {
    final d = await device();
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );

    final plain = jsonEncode({
      '__cat': 'chats',
      'v': [
        {
          'id': 'c1',
          'rootId': 'r1',
          'title': 'Renamed elsewhere, later',
          'updatedAt': 9000,
        },
        {
          'id': 'c2',
          'rootId': 'r2',
          'title': 'Renamed elsewhere, earlier',
          'updatedAt': 10,
        },
      ]
    });
    d1.rows[sync.categoryFor('chats')] =
        await d.identity.signer.nip44Encrypt(d.identity.pubkey, plain);

    await d.store.saveConversations([
      Conversation(
          id: 'c1',
          rootId: 'r1',
          title: 'Renamed here, earlier',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(20)),
      Conversation(
          id: 'c2',
          rootId: 'r2',
          title: 'Renamed here, later',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(5000)),
    ]);

    expect((await sync.run()).isOk, isTrue);
    final titles = {for (final c in d.store.conversations()) c.id: c.title};
    expect(titles['c1'], 'Renamed elsewhere, later');
    expect(titles['c2'], 'Renamed here, later');
  });

  test('a repository travels without its token', () async {
    final d = await device();
    final d1 = FakeD1();
    final storage = StorageSync(client: d1.client);
    final sync = AccountSync(
        store: d.store, identity: d.identity, storage: storage);

    await d.store.saveRepos([
      GitRepo(id: 'g1', repo: 'me/thing', token: 'ghp_secret', branch: 'main'),
    ]);
    expect((await sync.run()).isOk, isTrue);

    expect(d1.rows.values.join('\n'), isNot(contains('ghp_secret')));
    final library = (await sync.pull())!['library'] as Map;
    final repo = (library['repos'] as List).single as Map;
    expect(repo['repo'], 'me/thing');
    expect(repo.containsKey('token'), isFalse);
    expect(repo['tokenElsewhere'], isTrue);

    final second = AccountSync(
        store: d.store, identity: d.identity, storage: storage);
    expect((await second.run()).isOk, isTrue);
    expect((await d.store.repos()).single.token, 'ghp_secret');
  });

  test('a device that cannot open the account rows refuses to write over them',
      () async {
    final d = await device();
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );
    d1.rows[sync.categoryFor('chats')] = 'sealed to a key this device lacks';

    await d.store.saveConversations(
        [Conversation(id: 'c1', rootId: 'r1', title: 'Local only')]);
    final round = await sync.run();

    expect(round.state, 'blocked');
    expect(sync.blocked, isTrue);
    expect(d1.writes, 0);
    expect(d1.rows[sync.categoryFor('chats')],
        'sealed to a key this device lacks');
  });

  test('a read that did not complete is not an answer', () async {
    final d = await device();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(
          client: MockClient((_) async => http.Response('nope', 503))),
    );
    expect(await sync.pull(), isNull);
    expect((await sync.run()).state, 'offline');
  });

  test('turning it off stops this device reading or writing', () async {
    final d = await device();
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );
    final settings = d.store.settings()..sync = false;
    await d.store.saveSettings(settings);

    expect(sync.enabled, isFalse);
    expect((await sync.run()).state, 'skipped');
    expect(d1.rows, isEmpty);
  });

  test('an unchanged row is not sent twice', () async {
    final d = await device();
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );
    await d.store.saveConversations(
        [Conversation(id: 'c1', rootId: 'r1', title: 'Steady')]);

    expect((await sync.run()).isOk, isTrue);
    final first = d1.writes;
    expect(first, greaterThan(0));
    expect((await sync.run()).isOk, isTrue);
    expect(d1.writes, first, reason: 'nothing changed, so nothing was written');
  });

  test('a device with no post-quantum root still seals to its own key',
      () async {
    final d = await device(withRoot: false);
    final d1 = FakeD1();
    final sync = AccountSync(
      store: d.store,
      identity: d.identity,
      storage: StorageSync(client: d1.client),
    );
    await d.store.saveConversations(
        [Conversation(id: 'c1', rootId: 'r1', title: 'Classical')]);

    expect((await sync.run()).isOk, isTrue);
    expect(d1.rows.values.join('\n'), isNot(contains('Classical')));
    final chats = (await sync.pull())!['chats'] as List;
    expect((chats.single as Map)['title'], 'Classical');
  });

  test('the account root row is left to its own reader and writer', () async {
    final d = await device();
    final d1 = FakeD1();
    final storage = StorageSync(client: d1.client);
    expect(
        await storage.publishPqRootRecord(d.identity.signer, d.identity.root!),
        isTrue);

    final sync = AccountSync(
        store: d.store, identity: d.identity, storage: storage);
    final remote = await sync.pull();
    expect(remote, isNotNull);
    expect(remote!.containsKey(StorageSync.pqRootDTag), isFalse);

    expect((await sync.run()).isOk, isTrue);
    final root = await storage.pqRootRecord(d.identity.signer);
    expect(root!.fingerprint, pq.pqRootFingerprint(d.identity.root!));
  });
}
