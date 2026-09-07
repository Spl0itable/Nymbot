import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/app.dart';
import 'package:nymbot/features/gate_screen.dart';
import 'package:nymbot/features/markdown_body.dart';
import 'package:nymbot/state/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('opens on the gate when there is no key', (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);
    await tester.pumpWidget(NymbotApp(controller: controller));
    await tester.pump();

    expect(find.byType(GateScreen), findsOneWidget);
    expect(find.text('Create a key'), findsOneWidget);
    expect(find.text('I already have one'), findsOneWidget);
  });

  testWidgets('creating a key reveals both things to back up', (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);
    await tester.pumpWidget(NymbotApp(controller: controller));
    await tester.pump();

    await tester.tap(find.text('Create a key'));
    await tester.pumpAndSettle();

    expect(find.text('Back these up now'), findsOneWidget);
    expect(controller.identity.nsec.startsWith('nsec1'), isTrue);
    expect(controller.identity.rootCode.startsWith('nympq1'), isTrue);
    // The ML-KEM keypair is derived from the root, not from the signing key.
    expect(controller.identity.kem, isNotNull);
    expect(controller.identity.kem!.publicKey.length, 1184);
  });

  testWidgets('an imported key is the same account', (tester) async {
    final controller = await AppController.boot();
    await tester.pumpWidget(NymbotApp(controller: controller));
    await tester.pump();

    await tester.tap(find.text('I already have one'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '0000000000000000000000000000000000000000000000000000000000000001',
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(controller.signedIn, isTrue);
    expect(
      controller.identity.pubkey,
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
    );
    // Signing in starts the relay pool and the deferred announcement; both are
    // cancellable, and the test asserts that by ending with nothing pending.
    controller.dispose();
    await tester.pump();
  });

  testWidgets('a reply renders its markdown rather than the source',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownBody(
          '### Heading\n\n'
          'Some **bold** and `code`.\n\n'
          '```js\nconst x = 1;\n```\n\n'
          '- one\n- two\n\n'
          '> quoted\n',
        ),
      ),
    ));
    await tester.pump();

    expect(find.textContaining('Heading', findRichText: true), findsWidgets);
    expect(find.textContaining('const x = 1;'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.textContaining('```', findRichText: true), findsNothing);
    expect(find.textContaining('**bold**', findRichText: true), findsNothing);
  });
}
