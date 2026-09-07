import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/app.dart';
import 'package:nymbot/features/command_sheet.dart';
import 'package:nymbot/features/gate_screen.dart';
import 'package:nymbot/features/markdown_body.dart';
import 'package:nymbot/features/nym_avatar.dart';
import 'package:nymbot/models/conversation.dart';
import 'package:nymbot/models/workspace.dart';
import 'package:nymbot/services/chat_engine.dart';
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
    expect(find.textContaining('const x = 1;', findRichText: true), findsWidgets);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.textContaining('```', findRichText: true), findsNothing);
    expect(find.textContaining('**bold**', findRichText: true), findsNothing);
  });

  testWidgets('a code block carries its language and a way to copy it',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MarkdownBody('```dart\nvoid main() {}\n```\n')),
    ));
    await tester.pump();

    expect(find.text('dart'), findsOneWidget);
    expect(find.byIcon(Icons.copy_all_outlined), findsOneWidget);
    expect(find.byIcon(Icons.short_text), findsOneWidget);
  });

  testWidgets('a table renders as a table, not as pipes', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownBody('| a | b |\n| --- | ---: |\n| 1 | 2 |\n'),
      ),
    ));
    await tester.pump();

    expect(find.byType(Table), findsOneWidget);
    expect(find.textContaining('| a |', findRichText: true), findsNothing);
    expect(find.textContaining('1', findRichText: true), findsWidgets);
  });

  testWidgets('a task list renders checkboxes', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MarkdownBody('- [ ] todo\n- [x] done\n')),
    ));
    await tester.pump();

    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outlined), findsOneWidget);
    expect(find.textContaining('[x]', findRichText: true), findsNothing);
  });

  test('a nym reads the same in every surface', () {
    const key = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
    expect(NymIdentity.suffix(key), '1798');
    expect(NymIdentity.name(key), contains('_'));
    expect(NymIdentity.handle(key), NymIdentity.handle(key));
    expect(NymIdentity.handle(key), isNot(NymIdentity.handle('00$key')));
  });

  test('the preamble carries the persona, the repos and the branch seed', () {
    final conv = Conversation(
      id: 'c1',
      rootId: 'r1',
      systemPrompt: 'Always answer in British English.',
      seed: 'User: hello\n\nAssistant: hi',
    );
    final repos = [
      GitRepo(id: '1', repo: 'nymbot/app', token: 'x', branch: 'main'),
      GitRepo(id: '2', repo: 'nymbot/worker', token: 'y', allowWrites: true),
    ];
    const persona = Persona(
      id: 'p',
      name: 'Terse',
      instructions: 'Answer in as few words as the question allows.',
    );

    final head = ChatEngine.preamble(conv, repos, persona);
    expect(head, contains('Answer in as few words'));
    expect(head, contains('Always answer in British English.'));
    expect(head, contains('1. nymbot/app@main (github, read-only)'));
    expect(head, contains('2. nymbot/worker (github, writable)'));
    expect(head, contains('[earlier in this conversation]'));
    expect(head, isNot(contains(r'${')));
  });

  test('a single repository needs no preamble of its own', () {
    final conv = Conversation(id: 'c1', rootId: 'r1');
    final repos = [GitRepo(id: '1', repo: 'nymbot/app', token: 'x')];
    expect(ChatEngine.preamble(conv, repos, null), '');
  });

  test('reasoning is split off whichever tag the model used', () {
    for (final tag in const ['think', 'thinking', 'reasoning']) {
      final split = ChatEngine.splitThinking('<$tag>weighing it up</$tag>Answer.');
      expect(split.thinking, 'weighing it up');
      expect(split.body, 'Answer.');
    }
    final none = ChatEngine.splitThinking('Just the answer.');
    expect(none.thinking, isNull);
    expect(none.body, 'Just the answer.');
  });

  test('the cost estimate follows the pinned model', () {
    expect(ChatEngine.estimate('hello', null).tier, 'standard');
    final pro = ChatEngine.estimate('hello', {'credits': 4, 'max': 9});
    expect(pro.tier, 'pro');
    expect(pro.low, 4);
    expect(pro.high, 9);
    final long = ChatEngine.estimate('x' * 5000, {'credits': 4, 'max': 4});
    expect(long.high, greaterThan(long.low - 1));
  });

  test('an attachment travels as a fenced block the model can read', () {
    final file = Attachment(
      id: 'a',
      kind: AttachmentKind.text,
      name: 'main.dart',
      lang: 'dart',
      size: 20,
      text: 'void main() {}',
    );
    expect(file.wireBlock, contains('--- attached file: main.dart ---'));
    expect(file.wireBlock, contains('```dart'));
    expect(file.wireBlock, contains('void main() {}'));
  });

  test('settings survive a round trip through JSON', () {
    final s = AppSettings(
      theme: ChatTheme.terminal,
      density: ChatDensity.compact,
      fontScale: 1.15,
      bubbles: false,
      sendOnEnter: true,
      grouping: SidebarGrouping.folder,
      defaultRepoIds: const ['r1', 'r2'],
    );
    final back = AppSettings.fromJson(s.toJson());
    expect(back.theme, ChatTheme.terminal);
    expect(back.density, ChatDensity.compact);
    expect(back.fontScale, 1.15);
    expect(back.bubbles, isFalse);
    expect(back.sendOnEnter, isTrue);
    expect(back.grouping, SidebarGrouping.folder);
    expect(back.defaultRepoIds, ['r1', 'r2']);
  });

  test('a conversation keeps its repos, tags and persona across a save', () {
    final conv = Conversation(
      id: 'c1',
      rootId: 'r1',
      title: 'Work',
      pinned: true,
      tags: ['work', 'crypto'],
      repoIds: ['a', 'b'],
      personaId: 'builtin-terse',
      systemPrompt: 'Be brief.',
    );
    final back = Conversation.fromJson(conv.toJson());
    expect(back.pinned, isTrue);
    expect(back.tags, ['work', 'crypto']);
    expect(back.repoIds, ['a', 'b']);
    expect(back.personaId, 'builtin-terse');
    expect(back.systemPrompt, 'Be brief.');
  });

  test('a message keeps its rating, pin and attachments across a save', () {
    final m = ChatMessage(
      id: 'm1',
      role: ChatRole.bot,
      content: 'hello',
      cost: 4,
      rating: -1,
      pinned: true,
      model: 'Claude Opus 5',
      repos: const ['nymbot/app'],
      attachments: [
        Attachment(id: 'a', kind: AttachmentKind.text, name: 'x.txt', text: 'hi'),
      ],
    );
    final back = ChatMessage.fromJson(m.toJson());
    expect(back.rating, -1);
    expect(back.pinned, isTrue);
    expect(back.cost, 4);
    expect(back.model, 'Claude Opus 5');
    expect(back.repos, ['nymbot/app']);
    expect(back.attachments.single.name, 'x.txt');
  });

  test('every local command is one the app answers itself', () {
    for (final c in BotCommands.local()) {
      expect(BotCommands.isLocal(c.name), isTrue, reason: c.name);
      expect(c.hint(), isNotEmpty, reason: c.name);
    }
    expect(BotCommands.isLocal('image'), isFalse);
    expect(BotCommands.match('mod').first.name, 'model');
    expect(BotCommands.helpText(), contains('?help'));
  });
}
