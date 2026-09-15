import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nymbot/core/crypto/pq.dart' as pq;
import 'package:nymbot/models/conversation.dart';
import 'package:nymbot/services/anon.dart';
import 'package:nymbot/services/chat_engine.dart';
import 'package:nymbot/services/nymbot_api.dart';
import 'package:nymbot/services/pq_announce.dart';
import 'package:nymbot/services/relay_pool.dart';
import 'package:nymbot/state/identity.dart';
import 'package:nymbot/state/store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<Map<String, dynamic>?> sendAndCapture({required String text}) async {
    final store = await Store.open();
    final identity = Identity(store);
    await identity.import(
      'ff00112233445566778899aabbccddeeff00112233445566778899aabbccddee',
      root: Uint8List.fromList(List<int>.filled(pq.pqRootLength, 3)),
    );

    Map<String, dynamic>? seen;
    final api = NymbotApi(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['action'] == 'pm') seen = body;
      return http.Response(jsonEncode({'error': 'stubbed'}), 200);
    }));

    final relays = RelayPool();
    final engine = ChatEngine(
      identity: identity,
      relays: relays,
      pq: PqAnnounce(relays),
      api: api,
      anon: AnonMode(store, api, PqAnnounce(relays)),
    );

    final conv = Conversation(id: 'c1', rootId: 'a' * 64);
    try {
      await engine.send(
        conv: conv,
        text: text,
        onThreadIds: (_) {},
      );
    } catch (_) {
    }
    return seen;
  }

  test('the sealed wrap travels in the request, not only its id', () async {
    final sent = await sendAndCapture(text: 'does this go?');

    expect(sent, isNotNull,
        reason: 'the worker was called with no relay connected at all');
    expect(sent!['eventId'], isA<String>());
    expect(sent['wrap'], isA<Map>(), reason: 'the wrap itself is handed over');

    final wrap = sent['wrap'] as Map;
    expect(wrap['kind'], 1059, reason: 'as a gift wrap');
    expect(wrap['id'], sent['eventId'],
        reason: 'and it is the event the id names');
    expect(wrap['content'], isA<String>());
    expect((wrap['content'] as String).isNotEmpty, isTrue,
        reason: 'sealed, so the worker has something to open');
    expect(wrap['content'], isNot(contains('does this go?')),
        reason: 'and the question is not in it in the clear');
  });

  test('a relay that never answers no longer holds a message up', () async {
    final sent = await sendAndCapture(text: 'still goes');
    expect(sent, isNotNull);
    expect(sent!['wrap'], isNotNull);
  });
}
