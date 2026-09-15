import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nymbot/models/conversation.dart';
import 'package:nymbot/state/app_controller.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<AppController> ready({required bool anonOn}) async {
    final app = await AppController.boot();
    addTearDown(app.dispose);
    if (anonOn) await app.anon.setEnabled(true);
    app.conversations = [Conversation(id: 'c1', rootId: 'a' * 64, anon: anonOn)];
    app.current = app.conversations.first;
    return app;
  }

  test('an anonymous chat never shows the nym’s figure', () async {
    final app = await ready(anonOn: true);
    expect(app.anon.ready, isTrue, reason: 'there is a throwaway key');

    app.standardBalance = 900;
    app.proBalance = 40;
    app.anonStandardBalance = null;
    app.anonProBalance = null;

    expect(app.spendingAnon, isTrue,
        reason: 'which key pays does not depend on knowing a figure yet');
    expect(app.shownBalance, isNot(900),
        reason: 'so the nym’s credits are never what the chip counts');
    expect(app.shownBalance, isNull,
        reason: 'unknown reads as unknown, and the chip falls back to Buy');

    app.anonStandardBalance = 25;
    expect(app.shownBalance, 25, reason: 'and the throwaway figure lands');
    expect(app.standardBalance, 900, reason: 'with the nym untouched');
  });

  test('a reply that carries no balance does not put the nym’s back',
      () async {
    final app = await ready(anonOn: true);
    app.standardBalance = 900;
    app.anonStandardBalance = 25;
    expect(app.shownBalance, 25);

    // What a free reply looks like: no balance reported at all.
    app.creditBalanceForTest(false, null, anonKey: true);
    expect(app.shownBalance, 25, reason: 'the last known anon figure stands');
    expect(app.shownBalance, isNot(900));

    app.creditBalanceForTest(false, 18, anonKey: true);
    expect(app.shownBalance, 18, reason: 'and a figure that does arrive lands');
    expect(app.standardBalance, 900, reason: 'still without touching the nym');
  });

  test('a chat that is not anonymous counts the nym', () async {
    final app = await ready(anonOn: false);
    app.standardBalance = 900;
    app.anonStandardBalance = 25;
    expect(app.spendingAnon, isFalse);
    expect(app.shownBalance, 900);
  });

  test('a reply in the nym’s own chat never lands on the throwaway key',
      () async {
    final app = await ready(anonOn: false);
    app.standardBalance = 900;
    app.anonStandardBalance = 25;
    app.creditBalanceForTest(false, 880, anonKey: false);
    expect(app.standardBalance, 880);
    expect(app.anonStandardBalance, 25, reason: 'the other wallet is untouched');
  });
}
