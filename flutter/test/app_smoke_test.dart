import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/app.dart';
import 'package:nymbot/features/brand_tile.dart';
import 'package:nymbot/features/citation_cards.dart';
import 'package:nymbot/features/sheets/cost_sheet.dart';
import 'package:nymbot/features/command_sheet.dart';
import 'package:nymbot/features/compose_controller.dart';
import 'package:nymbot/services/free_tier.dart';
import 'package:nymbot/services/wire_limits.dart';
import 'package:nymbot/features/diff_view.dart';
import 'package:nymbot/features/progress_lines.dart';
import 'package:nymbot/features/gate_screen.dart';
import 'package:nymbot/features/markdown_body.dart';
import 'package:nymbot/features/message_bubble.dart';
import 'package:nymbot/features/nym_avatar.dart';
import 'package:nymbot/features/i18n/i18n.dart';
import 'package:nymbot/features/nym_icons.dart';
import 'package:nymbot/features/purchase_policy.dart';
import 'package:nymbot/config.dart';
import 'package:nymbot/services/profiles.dart';
import 'package:nymbot/services/nostr/event_signer.dart';
import 'package:nymbot/services/relay_pool.dart';
import 'package:nymbot/services/storage_sync.dart';
import 'package:nymbot/core/crypto/pq.dart' as pq;
import 'package:nymbot/state/identity.dart';
import 'package:nymbot/state/store.dart';
import 'package:nymbot/core/crypto/bech32_codec.dart';
import 'package:nymbot/models/artifact.dart';
import 'package:nymbot/models/bot.dart';
import 'package:nymbot/models/schedule.dart';
import 'package:nymbot/models/compare.dart';
import 'package:nymbot/models/conversation.dart';
import 'package:nymbot/models/memory.dart';
import 'package:nymbot/models/workspace.dart';
import 'package:nymbot/services/attachments.dart';
import 'package:nymbot/services/ngit.dart';
import 'package:nymbot/services/chat_engine.dart';
import 'package:nymbot/services/git_forge.dart';
import 'package:nymbot/services/memory_keeper.dart';
import 'package:nymbot/services/nymbot_api.dart';
import 'package:nymbot/services/repo_map.dart';
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

  test('the device keeps its own count of the free allowance', () async {
    // The worker counts per key, and making another key is a tap in this app's
    // own gate — so the device keeps a count of its own. A speed bump, not a
    // control: clearing the app's data walks past it, and it is never reported
    // to the worker, because a device counter the server could see would link
    // a person's keys to each other.
    SharedPreferences.setMockInitialValues({});
    final free = FreeTier(await SharedPreferences.getInstance());

    expect(free.leftOf(3), 3, reason: 'a fresh device has the whole day');
    expect(free.allows(3, 0), isTrue, reason: 'so a message goes');

    await free.spent();
    await free.spent();
    expect(free.leftOf(3), 1, reason: 'each free reply takes one off it');
    expect(free.allows(3, 0), isTrue);

    await free.spent();
    expect(free.leftOf(3), 0, reason: 'the day runs out');
    expect(free.allows(3, 0), isFalse,
        reason: 'and then it stops offering free replies');
    expect(free.allows(3, 12), isTrue,
        reason: 'a balance is never gated by the device count');

    // The worker is the authority on the key's count, but only upwards —
    // believing a lower one is what would let a fresh key reset the device.
    await free.observe(1);
    expect(free.used, 3, reason: 'a lower count does not reset the device');
    await free.observe(9);
    expect(free.used, 9, reason: 'a higher one is believed');

    await free.forget();
    expect(free.used, 0,
        reason: 'and it can be cleared, which is the point of a speed bump');

    final allowance = FreeAllowance.fromJson(
        {'used': 2, 'limit': 20, 'left': 18, 'resetsAt': 123});
    expect(allowance?.left, 18, reason: 'what the worker said survives the trip');
    expect(FreeAllowance.fromJson({'limit': 0}), isNull,
        reason: 'and no allowance is no allowance, not a zero one');
    expect(FreeAllowance.fromJson(null), isNull);
  });

  test('a question too long for one wrap is cut up, not refused', () {
    // NIP-44 refuses a plaintext over 65535 bytes and a gift wrap nests two of
    // them, so a long message used to fail inside the crypto with a byte count
    // and no way to act on it.
    const line = 'the quick brown fox jumps over the lazy dog\n';
    final long = line * 2000;

    expect(WireLimits.bodyCost('hello'), 5,
        reason: 'plain text costs what it looks like');
    expect(WireLimits.bodyCost('"'), 2,
        reason: 'a quote costs what escaping it costs');
    expect(WireLimits.bodyCost('\n'), 2, reason: 'and so does a newline');
    expect(WireLimits.bodyCost('\u{1f600}'), 4,
        reason: 'an emoji is four bytes on the wire, not one character');

    final parts = WireLimits.split(long);
    expect(parts.length, greaterThan(1), reason: 'a long message is cut up');
    expect(parts.join(), long,
        reason: 'and the pieces put back together are the message again');
    expect(parts.every(WireLimits.fits), isTrue,
        reason: 'every piece fits in one wrap');
    expect(parts.take(parts.length - 1).every((p) => p.endsWith('\n')), isTrue,
        reason: 'the cut lands between lines, not mid-sentence');

    expect(WireLimits.split('short').length, 1);
    expect(WireLimits.split('short').first, 'short',
        reason: 'a message that fits is left exactly as it was');

    // A single line with nowhere to break still has to be cut somewhere.
    final unbroken = WireLimits.split('x' * (WireLimits.bodyMax * 3));
    expect(unbroken.length, greaterThan(1));
    expect(unbroken.every(WireLimits.fits), isTrue);
    expect(unbroken.join(), 'x' * (WireLimits.bodyMax * 3));

    expect(WireLimits.partSurcharge('short'), 0,
        reason: 'a message that fits costs nothing extra');
    expect(WireLimits.partSurcharge(long), parts.length - 1,
        reason: 'and one that does not is charged for each extra wrap');

    final split = ChatEngine.estimate('ask', null, wireText: long);
    expect(split.low, 1 + parts.length - 1,
        reason: 'the estimate says the price before it is spent');
    expect(ChatEngine.estimate('ask', null).low, 1,
        reason: 'an ordinary reply is still one credit');
  });

  testWidgets('the composer styles the markdown you write, keeping every character',
      (tester) async {
    // Flutter draws the caret and the selection at offsets into the field's
    // text, so the spans have to spell that text out exactly — nothing may be
    // dropped in the styling, only dressed.
    const source = '## Title\n'
        'a **loud** and *quiet* and `code` and [text](http://x.test)\n'
        '- item\n'
        '> quoted\n'
        '```js\n'
        'const x = **not bold**;\n'
        '```';
    final controller = MarkdownEditingController(text: source);
    late TextSpan built;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          built = controller.buildTextSpan(
              context: context, style: const TextStyle(), withComposing: false);
          return const SizedBox();
        }),
      ),
    ));

    expect(built.toPlainText(), source,
        reason: 'the styled spans read back as the text that was typed');

    final styles = <TextStyle>[];
    built.visitChildren((span) {
      if (span is TextSpan && span.style != null) styles.add(span.style!);
      return true;
    });
    expect(styles.where((s) => s.fontWeight == FontWeight.w700), isNotEmpty,
        reason: 'bold you typed is drawn bold');
    expect(styles.where((s) => s.fontStyle == FontStyle.italic), isNotEmpty,
        reason: 'and italic italic');
    expect(styles.where((s) => s.fontFamily == 'monospace'), isNotEmpty,
        reason: 'and code as code');

    // A wall of source that happens to look like markdown inside a fence is
    // code, not formatting.
    controller.text = '```\n**stays flat**\n```';
    await tester.pump();
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

  test('a persona carries an icon name, not an emoji', () {
    for (final p in Persona.builtins) {
      expect(NymIcons.persona.containsKey(p.icon), isTrue, reason: p.name);
      expect(p.icon, matches(RegExp(r'^[a-z]+$')), reason: p.name);
    }
    // Anything written before the icon set existed falls back rather than
    // drawing a blank square.
    expect(NymIcons.forPersona('\u{1F916}'), NymIcons.forPersona('robot'));
    expect(NymIcons.forPersona(null), NymIcons.forPersona('robot'));
  });

  testWidgets('the app mark is drawn rather than a letter', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: NymbotMark(size: 32))),
    ));
    await tester.pump();
    expect(find.byType(NymbotMark), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('an avatar falls back to the identicon without a picture',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          NymAvatar(seed: 'abc', size: 30),
          NymAvatar(seed: 'nymbot', size: 30, bot: true),
        ]),
      ),
    ));
    await tester.pump();
    expect(find.byType(NymAvatar), findsNWidgets(2));
    // The bot wears the app mark; a person with no profile wears their grid.
    expect(find.byType(NymbotMark), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  test('the auto top-up settings survive a round trip and default sensibly', () {
    final fresh = AppSettings();
    expect(fresh.anonAutoTop, isTrue);
    expect(fresh.anonAutoTopFloor, greaterThan(0));
    expect(fresh.anonAutoTopAmount, greaterThan(0));
    expect(fresh.anonAutoTopTier, 'both');

    final tuned = AppSettings(
      anonAutoTop: false,
      anonAutoTopFloor: 3,
      anonAutoTopAmount: 50,
      anonAutoTopTier: 'pro',
    );
    final back = AppSettings.fromJson(tuned.toJson());
    expect(back.anonAutoTop, isFalse);
    expect(back.anonAutoTopFloor, 3);
    expect(back.anonAutoTopAmount, 50);
    expect(back.anonAutoTopTier, 'pro');
  });

  testWidgets('nothing is moved while anonymous mode is off', (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);
    // The setting is on by default; the mode is not, and the mode is what
    // decides. Without a throwaway key there is nothing to fund.
    expect(controller.settings.anonAutoTop, isTrue);
    expect(controller.anon.enabled, isFalse);
    expect(await controller.autoTopUp(), isNull);
    expect(await controller.autoTopUp(force: true), isNull);
  });

  test('a profile only replaces the generated nym when there is one', () {
    const empty = NostrProfile();
    expect(empty.isEmpty, isTrue);
    const named = NostrProfile(name: 'satoshi');
    expect(named.isEmpty, isFalse);
    final back = NostrProfile.fromJson(
      const NostrProfile(name: 'satoshi', nip05: 'a@b.c', picture: 'https://x/y.png')
          .toJson(),
    );
    expect(back.name, 'satoshi');
    expect(back.nip05, 'a@b.c');
    expect(back.picture, 'https://x/y.png');
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

  test('a reply gives up its whole files as artifacts', () {
    const reply = '''
Here is the page.

```html
<!doctype html>
<title>Landing</title>
<h1>Hello</h1>
<p>Body</p>
```

And a one-liner you would not lift out:

```sh
ls -la
```
''';
    final blocks = ArtifactHarvest.fences(reply);
    expect(blocks.length, 2);
    expect(blocks.first.lang, 'html');
    expect(ArtifactHarvest.worthLifting(blocks[0].body, blocks[0].lang), isTrue);
    expect(ArtifactHarvest.worthLifting(blocks[1].body, blocks[1].lang), isFalse);
  });

  test('an artifact is named after what it is, not its language', () {
    expect(
      ArtifactHarvest.titleFor('html', '<!doctype html>\n<title>Landing</title>\n<h1>Hi</h1>'),
      'Landing',
    );
    expect(ArtifactHarvest.titleFor('markdown', '# Release notes\n\nText'), 'Release notes');
    expect(ArtifactHarvest.titleFor('dart', 'class Ledger {\n}\n'), 'Ledger');
    expect(ArtifactHarvest.titleFor('html', '<!doctype html>\n<div>x</div>'), 'Page');
  });

  test('an artifact keeps every version it was given', () {
    final a = Artifact(id: 'a1', title: 'Landing', lang: 'html', body: 'one');
    a.versions.add(ArtifactVersion(at: DateTime.now(), body: 'one'));
    expect(a.lines, 1);
    expect(a.previewable, isTrue);
    expect(a.readable, isFalse);
    expect(a.extension, 'html');
    final back = Artifact.decodeList(Artifact.encodeList([a])).single;
    expect(back.title, 'Landing');
    expect(back.body, 'one');
    expect(back.versions.length, a.versions.length);
  });

  testWidgets('keeping one of two answers folds it in on a fresh thread',
      (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);
    final conv = await controller.newConversation();
    final before = conv.rootId;
    await controller.open(conv);

    await controller.keepCompare(
      'explain gift wraps',
      const CompareRun(
        model: {'key': 'b', 'label': 'Model B', 'credits': 3},
        reply: 'B says that.',
        cost: 3,
      ),
    );

    expect(controller.messages.length, 2);
    expect(controller.messages.first.content, 'explain gift wraps');
    expect(controller.messages.last.content, 'B says that.');
    expect(controller.messages.last.model, 'Model B');
    expect(conv.rootId, isNot(before));
    expect(conv.seed, contains('B says that.'));
    expect(controller.store.thread(conv.id), isEmpty);
    expect(conv.creditsSpent, 3);
  });

  test('a run that failed is never offered to keep', () {
    const bad = CompareRun(
      model: {'key': 'a', 'label': 'Model A'},
      error: 'No relay accepted your message.',
    );
    expect(bad.ok, isFalse);
    expect(bad.label, 'Model A');
    const good = CompareRun(model: {'key': 'b'}, reply: 'hi');
    expect(good.ok, isTrue);
    expect(good.label, 'b');
    expect(good.price, 1);
  });

  test('a workspace folds its instructions and files into the preamble', () {
    final space = Workspace(
      id: 'w1',
      name: 'Nymbot',
      instructions: 'Always cite the file you changed.',
      files: [
        const KnowledgeFile(id: 'f1', name: 'style.md', body: '# House style'),
      ],
    );
    final conv = Conversation(id: 'c1', rootId: 'r1', workspaceId: 'w1');
    final head = ChatEngine.preamble(conv, const [], null, space);

    expect(head, contains('[custom instructions]'));
    expect(head, contains('Always cite the file you changed.'));
    expect(head, contains('[project knowledge]'));
    expect(head, contains('style.md'));
    expect(head, contains('# House style'));
    expect(head, contains(ChatEngine.standingEnd),
        reason: 'the worker needs to know where the repeats stop');
    expect(head, isNot(contains(r'${')));
  });

  test('knowledge is retrieved against the question, not poured in whole', () {
    // Sending all of it put 90,000 characters in the first message, which the
    // worker cut to 1000 the moment it stopped being the current turn — so a
    // workspace quietly stopped applying after one reply.
    final space = Workspace(
      id: 'w1',
      files: const [
        KnowledgeFile(
          id: 'f1',
          name: 'retry.md',
          body: '# Backoff\n\nThe retry loop sleeps 2s, 4s then 8s.\n\n'
              '# Deadlines\n\nA request is abandoned after 30 seconds.',
        ),
        KnowledgeFile(
          id: 'f2',
          name: 'billing.md',
          body: '# Credits\n\nA credit is 100 sats on the pro tier.\n\n'
              '# Refunds\n\nAn unspent reservation is released, never charged.',
        ),
      ],
    );

    final retry = ChatEngine.knowledgeBlock(
        space, 'why does the retry loop back off so slowly?');
    expect(retry, contains('sleeps 2s, 4s then 8s'),
        reason: 'the passage that answers the question is the one sent');
    expect(retry, isNot(contains('100 sats')),
        reason: 'and the passages that do not are left behind');
    expect(retry, contains('retry.md'));
    expect(retry, contains('billing.md'),
        reason: 'every file is named, so the model knows what else there is');

    final credits = ChatEngine.knowledgeBlock(space, 'how many sats is a credit?');
    expect(credits, contains('100 sats'));
    expect(credits, isNot(contains('sleeps 2s')));

    expect(ChatEngine.knowledgeBlock(space, 'what is the capital of France'),
        isNotEmpty,
        reason: 'a question that matches nothing still gets something to orient on');

    final huge = Workspace(
      id: 'w2',
      files: [KnowledgeFile(id: 'f1', name: 'huge.txt', body: 'x ' * 30000)],
    );
    expect(ChatEngine.knowledgeBlock(huge, 'anything').length, lessThan(6000),
        reason: 'a file far too big for the window never travels whole');
    expect(ChatEngine.knowledgeBlock(null), isEmpty);
  });

  test('standing context rides every message, and the seed rides once', () {
    final space = Workspace(id: 'w1', instructions: 'Be terse.');
    final conv = Conversation(id: 'c1', rootId: 'r1', workspaceId: 'w1');
    final first = ChatEngine.preamble(conv, const [], null, space, null, 'q');
    final later = ChatEngine.preamble(conv, const [], null, space, null, 'q');
    expect(later, first,
        reason: 'what stands is sent every turn, not only the first');

    final seeded = Conversation(
        id: 'c2', rootId: 'r2', workspaceId: 'w1', seed: 'We agreed on X.');
    final head = ChatEngine.preamble(seeded, const [], null, space, null, 'q');
    expect(head.indexOf('[earlier in this conversation]'),
        greaterThan(head.indexOf(ChatEngine.standingEnd)),
        reason: 'the seed sits past the marker, because nothing re-sends it');

    final bare = Conversation(id: 'c3', rootId: 'r3');
    expect(ChatEngine.preamble(bare, const [], null), isEmpty,
        reason: 'a chat with nothing standing sends no stray marker');
  });

  test('a chat with no workspace is unchanged', () {
    final conv = Conversation(id: 'c1', rootId: 'r1');
    expect(ChatEngine.preamble(conv, const [], null, null), isEmpty);
    final back = Conversation.fromJson(
      Conversation(id: 'c2', rootId: 'r2', workspaceId: 'w9').toJson(),
    );
    expect(back.workspaceId, 'w9');
  });

  test('a workspace survives a round trip through JSON', () {
    final space = Workspace(
      id: 'w1',
      name: 'Nymbot',
      instructions: 'be terse',
      files: [const KnowledgeFile(id: 'f1', name: 'a.md', body: 'hi')],
      repoIds: ['r1', 'r2'],
      personaId: 'p1',
    );
    final back = Workspace.decodeList(Workspace.encodeList([space])).single;
    expect(back.name, 'Nymbot');
    expect(back.instructions, 'be terse');
    expect(back.files.single.name, 'a.md');
    expect(back.files.single.size, 2);
    expect(back.repoIds, ['r1', 'r2']);
    expect(back.personaId, 'p1');
  });

  test('a shared bot carries how it answers and nothing else', () {
    final bot = Bot(
      id: 'b1',
      name: 'Release notes',
      tagline: 'Turns a diff into something a human can read',
      icon: 'pen',
      instructions: 'Write plainly. No superlatives.',
      modelKey: 'anthropic/claude-opus-5',
      modelLabel: 'Claude Opus 5',
      starters: ['Summarise the last release'],
    );
    final shared = bot.shareable;
    expect(shared['name'], 'Release notes');
    expect(shared['instructions'], 'Write plainly. No superlatives.');
    expect(shared['model'], 'anthropic/claude-opus-5');
    expect(shared['starters'], ['Summarise the last release']);
    // The whole point: none of these can ride along.
    for (final leak in ['repoIds', 'repos', 'token', 'files', 'seed', 'author']) {
      expect(shared.containsKey(leak), isFalse, reason: leak);
    }
  });

  test('a bot link round-trips through a fragment', () {
    final bot = Bot(
      id: 'b1',
      name: 'Release notes',
      tagline: 'plain English',
      icon: 'pen',
      instructions: 'Write plainly.',
      modelKey: 'k',
      modelLabel: 'Model K',
      starters: ['one', 'two'],
    );
    final link = bot.link();
    expect(link, contains('/app/#bot='));

    final back = Bot.fromLink(link, id: 'b2');
    expect(back, isNotNull);
    expect(back!.id, 'b2');
    expect(back.name, 'Release notes');
    expect(back.instructions, 'Write plainly.');
    expect(back.modelKey, 'k');
    expect(back.modelLabel, 'Model K');
    expect(back.starters, ['one', 'two']);
    expect(back.author, isEmpty);
  });

  test('anything that is not a bot link is refused', () {
    expect(Bot.fromLink('', id: 'x'), isNull);
    expect(Bot.fromLink('https://example.com/#bot=notbase64!!', id: 'x'), isNull);
    expect(Bot.fromLink('https://example.com/#bot=e30', id: 'x'), isNull);
    expect(Bot.fromShared(const {'name': ''}, id: 'x'), isNull);
  });

  test('a published bot is addressable, and its address survives a decode', () {
    final bot = Bot(id: 'b1', name: 'Release Notes!');
    expect(bot.slug, 'release-notes');
    expect(bot.dTag, 'nym-bot-release-notes');

    const pubkey =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
    final naddr = bot.addressFor(pubkey);
    expect(naddr.startsWith('naddr1'), isTrue);

    final ref = decodeNostrRef(naddr);
    expect(ref, isNotNull);
    expect(ref!.kind, NostrRefKind.addr);
    expect(ref.pubkey, pubkey);
    expect(ref.identifier, 'nym-bot-release-notes');
    expect(ref.eventKind, Bot.kind);
  });

  test('a bot in a chat speaks first in the preamble', () {
    final bot = Bot(id: 'b1', name: 'Terse', instructions: 'One sentence only.');
    final conv = Conversation(
      id: 'c1',
      rootId: 'r1',
      botId: 'b1',
      systemPrompt: 'Use British spelling.',
    );
    final head = ChatEngine.preamble(conv, const [], null, null, bot);
    expect(head, contains('One sentence only.'));
    expect(head, contains('Use British spelling.'));
    expect(head.indexOf('One sentence only.'),
        lessThan(head.indexOf('Use British spelling.')));
  });

  testWidgets('a ghost chat is never written to this device', (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);
    final conv = await controller.newConversation();
    await controller.open(conv);

    final prefs = await SharedPreferences.getInstance();
    await controller.note('kept on disk');
    await prefs.reload();
    expect(prefs.getString('msgs_${conv.id}'), isNotNull);

    await controller.setEphemeral(true);
    expect(conv.ephemeral, isTrue);
    await prefs.reload();
    expect(prefs.getString('msgs_${conv.id}'), isNull,
        reason: 'what was already said comes off the disk');
    expect(controller.store.messages(conv.id).length, 1,
        reason: 'but stays on screen');

    await controller.note('said in the dark');
    await prefs.reload();
    expect(prefs.getString('msgs_${conv.id}'), isNull);
    expect(controller.store.messages(conv.id).length, 2);

    await controller.harvestArtifacts(ChatMessage(
      id: 'm1',
      role: ChatRole.bot,
      content: '```html\n<!doctype html>\n<title>Ghost page</title>\n<h1>x</h1>\n<p>y</p>\n```',
    ));
    await prefs.reload();
    expect(prefs.getString('artifacts_${conv.id}'), isNull,
        reason: 'nor is a file it produced');
    expect(controller.artifacts.length, 1);

    await controller.setEphemeral(false);
    await prefs.reload();
    expect(prefs.getString('msgs_${conv.id}'), isNotNull,
        reason: 'turning it off writes back what is on screen');
    expect(controller.store.messages(conv.id).length, 2);
  });

  testWidgets('the startup sweep takes ghosts and stale chats, never a pin',
      (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);

    final ghost = await controller.newConversation();
    await controller.open(ghost);
    await controller.setEphemeral(true);

    final stale = await controller.newConversation();
    stale.updatedAt = DateTime.now().subtract(const Duration(days: 40));
    final pinned = await controller.newConversation();
    pinned.pinned = true;
    pinned.updatedAt = DateTime.now().subtract(const Duration(days: 40));
    final fresh = await controller.newConversation();
    await controller.store.saveConversations(controller.conversations);

    await controller.setAutoDeleteDays(30);
    final swept = await controller.sweepOldChats();

    expect(swept, 2);
    final left = controller.conversations.map((c) => c.id).toList();
    expect(left, contains(pinned.id));
    expect(left, contains(fresh.id));
    expect(left, isNot(contains(ghost.id)));
    expect(left, isNot(contains(stale.id)));
  });

  testWidgets('a chat can be renamed, pinned and deleted without opening it',
      (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);

    final here = await controller.newConversation();
    await controller.open(here);
    final there = await controller.newConversation();
    await controller.open(here);

    await controller.renameCurrent('Somewhere else', target: there);
    await controller.togglePin(target: there);
    expect(there.title, 'Somewhere else');
    expect(there.pinned, isTrue,
        reason: 'a row acts on its own chat, not the one on screen');
    expect(here.title, isNot('Somewhere else'));
    expect(controller.current?.id, here.id,
        reason: 'and leaves you where you were reading');

    await controller.toggleArchive(target: there);
    expect(there.archived, isTrue);
    expect(controller.current?.id, here.id,
        reason: 'archiving elsewhere does not move you either');

    await controller.deleteCurrent(target: there);
    expect(controller.conversations.map((c) => c.id), isNot(contains(there.id)));
    expect(controller.current?.id, here.id,
        reason: 'nor does deleting elsewhere');
  });

  test('a forge listing becomes repositories, whatever forge answered', () {
    final github = GitForge.parse('github', [
      {'full_name': 'nym/beta', 'default_branch': 'trunk', 'private': false},
      {'full_name': 'nym/alpha', 'default_branch': 'main', 'private': true},
      {'name': 'no full name'},
    ]);
    expect(github.map((r) => r.repo), ['nym/alpha', 'nym/beta'],
        reason: 'sorted, and a row without a name is dropped rather than shown blank');
    expect(github.first.branch, 'main');
    expect(github.first.private, isTrue);

    final gitlab = GitForge.parse('gitlab', [
      {
        'path_with_namespace': 'group/thing',
        'default_branch': 'develop',
        'visibility': 'private',
      },
    ]);
    expect(gitlab.single.repo, 'group/thing');
    expect(gitlab.single.branch, 'develop');
    expect(gitlab.single.private, isTrue);

    final bitbucket = GitForge.parse('bitbucket', {
      'values': [
        {
          'full_name': 'team/repo',
          'mainbranch': {'name': 'master'},
          'is_private': false,
        },
      ],
    });
    expect(bitbucket.single.repo, 'team/repo');
    expect(bitbucket.single.branch, 'master');
    expect(bitbucket.single.private, isFalse);

    expect(GitForge.parse('github', {'not': 'a list'}), isEmpty);
    expect(GitForge.needsHost('gitea'), isTrue,
        reason: 'a self-hosted forge has no host to guess');
    expect(GitForge.needsHost('github'), isFalse);
  });

  test('a whole repository is read in one call to the forge', () async {
    final asked = <String>[];
    final client = MockClient((request) async {
      asked.add(request.url.toString());
      return http.Response(
        jsonEncode({
          'truncated': false,
          'tree': [
            {'path': 'README.md', 'type': 'blob'},
            {'path': 'app', 'type': 'tree'},
            {'path': 'app/js/chat.js', 'type': 'blob'},
            {'path': 'app/js/api.js', 'type': 'blob'},
          ],
        }),
        200,
      );
    });
    final read = await GitForge.tree(
      provider: 'github',
      token: 'tok',
      repo: 'nym/mapped',
      branch: 'main',
      client: client,
    );
    expect(asked.length, 1, reason: 'one request, not one per directory');
    expect(asked.single,
        'https://api.github.com/repos/nym/mapped/git/trees/main?recursive=1');
    expect(read.branch, 'main');
    expect(read.paths, ['README.md', 'app/js/chat.js', 'app/js/api.js'],
        reason: 'directories are not files');
  });

  test('a branch nobody named is asked for before the tree is', () async {
    final asked = <String>[];
    final client = MockClient((request) async {
      asked.add(request.url.path);
      if (request.url.path.contains('/git/trees/')) {
        return http.Response(jsonEncode({'tree': <dynamic>[]}), 200);
      }
      return http.Response(jsonEncode({'default_branch': 'trunk'}), 200);
    });
    final read = await GitForge.tree(
      provider: 'github', token: 'tok', repo: 'nym/mapped', client: client);
    expect(read.branch, 'trunk');
    expect(asked.first, '/repos/nym/mapped');
  });

  test('the map names every file, and leaves only build output out', () async {
    final kept = RepoMap.usable([
      'README.md',
      'app/js/chat.js',
      'app/js/api.js',
      'app/icons/mark.png',
      'media/promo.mp4',
      'package-lock.json',
      'node_modules/left-pad/index.js',
      'dist/bundle.js',
      'build/app/outputs/thing.txt',
    ], null);
    expect(
        kept.paths,
        [
          'app/icons/mark.png',
          'app/js/api.js',
          'app/js/chat.js',
          'media/promo.mp4',
          'README.md',
        ],
        reason: 'a picture and a video are named too — asked what the promotional '
            'screenshots look like, the answer is which files exist');
    expect(kept.total, 5);
    expect(kept.dropped, 0);

    final scoped = RepoMap.usable(
      ['app/js/ui.js', 'docs/one.md', 'tools/x.mjs'],
      GitRepo(id: 'r', repo: 'a/b', token: 't', paths: 'app/, docs/one.md'),
    );
    expect(scoped.paths, ['app/js/ui.js', 'docs/one.md'],
        reason: 'a repository restricted to some paths is mapped only there');
  });

  test('a huge repository is capped, and says how much it left out', () {
    final paths = [
      for (var i = 0; i < 2000; i++) 'src/mod$i/thing$i.ts',
    ];
    final kept = RepoMap.usable(paths, null);
    expect(kept.paths.length, RepoMap.filesPerRepo);
    expect(kept.dropped, 2000 - RepoMap.filesPerRepo);
    final text = RepoMap.render(
      'big/repo',
      RepoMapEntry(
        at: 0, usedAt: 0, branch: 'main',
        paths: kept.paths, dropped: kept.dropped, total: kept.total,
      ),
      4000,
      const <String>{},
    );
    expect(text.length, lessThan(5000), reason: 'inside the budget one repository gets');
    expect(text, contains('further files are not named above'));
    expect(RegExp(r'(\d+) further files').firstMatch(text)!.group(1), '1851',
        reason: 'every file left out is counted, whether capped or over budget');
  });

  test('the file list rides the preamble, grouped by directory', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.open();
    final repo = GitRepo(id: 'r1', repo: 'nym/mapped', token: 'tok', branch: 'main');
    final maps = RepoMap(store, client: MockClient((_) async => http.Response(
          jsonEncode({
            'tree': [
              {'path': 'README.md', 'type': 'blob'},
              {'path': 'app/js/chat.js', 'type': 'blob'},
              {'path': 'app/js/api.js', 'type': 'blob'},
            ],
          }),
          200,
        )));
    expect(maps.knows([repo]), isFalse);
    await maps.refresh(repo);
    expect(maps.knows([repo]), isTrue);
    expect(maps.stale(repo), isFalse, reason: 'just read is not stale');

    final block = maps.block([repo], 'where does chat.js send the turn?');
    expect(block, contains('[repository files]'));
    expect(block, contains('nym/mapped@main (3 files)'));
    expect(block, contains('(root): README.md'));
    expect(block, contains('app/js/: chat.js, api.js'),
        reason: 'the file the question named comes first');
    expect(block, contains('a little behind the branch'),
        reason: 'a stale listing must never read as the whole truth');

    final conv = Conversation(id: 'c1', rootId: 'r1');
    final with_ = ChatEngine.preamble(
        conv, [repo], null, null, null, 'chat.js', const [], block);
    final without =
        ChatEngine.preamble(conv, [repo], null, null, null, 'chat.js');
    expect(with_, contains('[repository files]'));
    expect(without, isNot(contains('[repository files]')),
        reason: 'a turn that would not fit with the map sends without it');

    await maps.forget(repo);
    expect(maps.entry(repo), isNull);
  });

  test('a forge that refuses is remembered as nothing, not as an empty repo', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.open();
    final repo = GitRepo(id: 'r1', repo: 'nym/mapped', token: 'tok', branch: 'main');
    final maps = RepoMap(store,
        client: MockClient((_) async => http.Response('nope', 401)));
    await maps.refresh(repo);
    expect(maps.block([repo], 'anything'), isEmpty,
        reason: 'nothing is claimed about a repository that could not be read');
    await maps.ready([repo], within: const Duration(milliseconds: 50));
  });

  test('a busy gateway is read as busy, and a real error is not', () {
    expect(
        NymbotApi.busy(200, {
          'error': 'Wholesale rate limit exceeded for this gateway. '
              'Please reduce request rate or use BYOK.'
        }),
        isTrue);
    expect(NymbotApi.busy(429, const {}), isTrue);
    expect(NymbotApi.busy(200, const {'error': 'upstream model overloaded'}), isTrue);
    expect(NymbotApi.busy(200, const {'error': 'You are out of Pro credits.'}), isFalse);
    expect(NymbotApi.busy(200, const {'ok': true}), isFalse);
  });

  test('two turns from one device never reach the gateway together', () async {
    final signer = LocalSigner(Uint8List.fromList(List<int>.filled(32, 7)));
    var turns = 0;
    var polls = 0;
    var mostTurns = 0;
    var mostPolls = 0;
    final api = NymbotApi(client: MockClient((request) async {
      final action = (jsonDecode(request.body) as Map)['action'];
      if (action == 'pm') {
        if (++turns > mostTurns) mostTurns = turns;
      } else {
        if (++polls > mostPolls) mostPolls = polls;
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (action == 'pm') {
        turns--;
      } else {
        polls--;
      }
      return http.Response(jsonEncode({'ok': true}), 200);
    }));
    await Future.wait<void>([
      api.call('pm', signer, extra: const {'eventId': 'a'}),
      api.call('pm', signer, extra: const {'eventId': 'b'}),
      api.call('pm-progress', signer),
      api.call('pm-progress', signer),
    ]);
    expect(mostTurns, 1, reason: 'a turn is a whole agentic run, so two at once is two bursts');
    expect(mostPolls, 2, reason: 'a progress poll never waits behind a three-minute run');
  });

  test('listing refuses before it asks when it has nothing to ask with', () async {
    await expectLater(
      GitForge.listRepos(provider: 'github', token: ''),
      throwsA(isA<ForgeException>()
          .having((e) => e.reason, 'reason', ForgeFailure.noToken)),
    );
    await expectLater(
      GitForge.listRepos(provider: 'gitea', token: 'x'),
      throwsA(isA<ForgeException>()
          .having((e) => e.reason, 'reason', ForgeFailure.noHost)),
    );
    await expectLater(
      GitForge.listRepos(provider: 'sourcehut', token: 'x'),
      throwsA(isA<ForgeException>()
          .having((e) => e.reason, 'reason', ForgeFailure.unsupported)),
    );
  });

  test('a standing fact is noticed, but a question never is', () {
    final conv = Conversation(id: 'c1', rootId: 'r1');
    expect(MemoryKeeper.propose('call me Lux, by the way', conv).single.topic, 'Name');
    expect(
        MemoryKeeper.propose('I prefer answers that show the code first.', conv)
            .single
            .topic,
        'Preference');
    expect(MemoryKeeper.propose('what do I prefer for breakfast?', conv), isEmpty,
        reason: 'a question about a preference is not a preference');
    expect(MemoryKeeper.propose('should I use rust for this?', conv), isEmpty);
    expect(
        MemoryKeeper.propose(
            'call me Lux', Conversation(id: 'c', rootId: 'r', ephemeral: true)),
        isEmpty,
        reason: 'a ghost chat notices nothing at all');
  });

  test('memory is scoped to the workspace it was saved in', () {
    final all = [
      Memory(id: 'm1', text: 'I work in TypeScript.', topic: 'Tools'),
      Memory(id: 'm2', text: 'This one ships on Fridays.', scope: 'w-alpha'),
      Memory(id: 'm3', text: 'That one is in Go.', scope: 'w-beta'),
    ];
    final loose = MemoryKeeper.forConv(all, Conversation(id: 'c', rootId: 'r'));
    expect(loose.length, 1,
        reason: 'a chat outside a workspace sees only what was saved loose');

    final alpha = MemoryKeeper.forConv(
        all, Conversation(id: 'c', rootId: 'r', workspaceId: 'w-alpha'));
    expect(alpha.map((m) => m.id), containsAll(['m1', 'm2']));
    expect(alpha.map((m) => m.id), isNot(contains('m3')),
        reason: 'and never another workspace');

    expect(
        MemoryKeeper.forConv(all,
            Conversation(id: 'c', rootId: 'r', workspaceId: 'w-alpha', ephemeral: true)),
        isEmpty,
        reason: 'a ghost chat reads none of it');
  });

  test('what rides a message is what bears on it, plus who you are', () {
    final all = [
      Memory(id: 'm1', text: 'Always answer in British English.', topic: 'How to answer'),
      Memory(id: 'm2', text: 'My name is Lux.', topic: 'Name'),
      Memory(id: 'm3', text: 'The staging database is called nym-staging.', topic: 'Note'),
      Memory(id: 'm4', text: 'I run a 2019 ThinkPad.', topic: 'Note'),
    ];
    final conv = Conversation(id: 'c', rootId: 'r');
    final onTopic =
        MemoryKeeper.block(all, conv, 'what is the staging database called?');
    expect(onTopic, contains('nym-staging'));
    expect(onTopic, contains('British English'),
        reason: 'how to answer travels whatever the question is');

    final offTopic = MemoryKeeper.block(all, conv, 'write me a poem');
    expect(offTopic, contains('British English'));
    expect(offTopic, contains('Lux'), reason: 'and so does your name');
    expect(offTopic, isNot(contains('ThinkPad')),
        reason: 'while an unrelated fact stays behind');

    expect(MemoryKeeper.block(const [], conv, 'anything'), isEmpty);
    expect(
        MemoryKeeper.block(
            all, Conversation(id: 'c', rootId: 'r', ephemeral: true), 'anything'),
        isEmpty);
  });

  testWidgets('the same fact told twice is one fact, and rides the preamble',
      (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);

    final conv = await controller.newConversation();
    await controller.open(conv);
    await controller.saveMemory(Memory(id: 'm1', text: 'Call me Lux.', topic: 'Name'));
    await controller.saveMemory(Memory(id: 'm2', text: 'call me lux.', topic: 'Name'));
    expect(controller.memories.length, 1,
        reason: 'matching on the text keeps a repeat from becoming a copy');
    expect(controller.memories.single.id, 'm2',
        reason: 'the later wording is the one kept, not the first');

    final head = ChatEngine.preamble(
        conv, const [], null, null, null, 'who am I?', controller.memories);
    expect(head, contains('[remembered about you]'));
    expect(head.indexOf('[remembered about you]'),
        lessThan(head.indexOf(ChatEngine.standingEnd)),
        reason: 'inside the part the worker strips, since it is sent every turn');

    await controller.deleteMemory('m2');
    expect(controller.memories, isEmpty,
        reason: 'and one can be thrown away on its own');
  });

  testWidgets('typing while it is still writing holds the message', (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);

    final conv = await controller.newConversation();
    await controller.open(conv);

    // The send itself needs the worker; what is under test is the queue.
    controller.sending = true;
    expect(await controller.send('and what about the deadline?'), isFalse,
        reason: 'it says it did not go, so nothing reads out a reply yet');
    await controller.send('also, which branch?');
    expect(controller.queued, ['and what about the deadline?', 'also, which branch?'],
        reason: 'held in the order it was typed, not dropped');

    controller.unqueue(0);
    expect(controller.queued, ['also, which branch?'],
        reason: 'one waiting can be taken back out');

    controller.stop();
    expect(controller.queued, isEmpty,
        reason: 'stop means stop: nothing waiting behind it is sent');

    controller.sending = true;
    await controller.send('one more');
    expect(controller.queued, ['one more']);
    await controller.open(conv);
    expect(controller.queued, isEmpty,
        reason: 'a queue belongs to the chat it was typed into');
  });

  testWidgets('asking it to think harder is priced as the work it is',
      (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);

    final conv = await controller.newConversation();
    await controller.open(conv);
    const model = {'key': 'x', 'label': 'A model', 'credits': 2, 'max': 6};

    final normal = ChatEngine.estimate('hi', model, conv: conv);
    expect(normal.low, 2, reason: 'a normal reply is one pass');

    conv.effort = 'careful';
    expect(ChatEngine.estimate('hi', model, conv: conv).low, 4,
        reason: 'a careful one costs two');
    conv.effort = 'deep';
    final deep = ChatEngine.estimate('hi', model, conv: conv);
    expect(deep.low, 6, reason: 'a deep one costs three');
    expect(deep.high, greaterThan(normal.high),
        reason: 'and the ceiling moves with it too');

    expect(ChatEngine.estimate('hi', model, conv: conv, hasRepos: true).low, 2,
        reason: 'a repo task loops on a budget of its own and ignores it');
    expect(ChatEngine.estimate('hi', null, conv: conv).tier, 'standard',
        reason: 'a standard reply is untouched by any of it');

    conv.effort = 'enormous';
    expect(ChatEngine.effortOf(conv), 'normal',
        reason: 'an effort nobody asked for is normal');

    conv.effort = 'normal';
    expect(await controller.cycleEffort(), 'careful');
    expect(await controller.cycleEffort(), 'deep');
    expect(await controller.cycleEffort(), 'normal',
        reason: 'the chip cycles and comes back round');
    expect(await controller.cycleEffort('deep'), 'deep',
        reason: 'and it can be set by name');
    expect(Conversation.fromJson(conv.toJson()).effort, 'deep',
        reason: 'and it survives a round trip through JSON');
  });

  testWidgets('asking a question differently branches rather than overwriting',
      (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);

    final conv = await controller.newConversation();
    await controller.open(conv);
    conv.systemPrompt = 'Cite the file.';
    conv.effort = 'careful';
    await controller.store.saveConversations(controller.conversations);

    final q2 = ChatMessage(id: 'q2', role: ChatRole.self, content: 'second question');
    controller.messages = [
      ChatMessage(id: 'q1', role: ChatRole.self, content: 'first question'),
      ChatMessage(id: 'a1', role: ChatRole.bot, content: 'first answer'),
      q2,
      ChatMessage(id: 'a2', role: ChatRole.bot, content: 'second answer'),
    ];
    await controller.store.saveMessages(conv.id, controller.messages);
    controller.artifacts = [
      Artifact(id: 'art1', messageId: 'a1', title: 'thing.js', lang: 'js', body: 'const x = 1;'),
    ];

    final copy = await controller.branchBefore(q2);

    expect(controller.store.messages(conv.id).length, 4,
        reason: 'the chat it came from is left exactly as it was');
    expect(controller.store.messages(copy.id).map((m) => m.id), ['q1', 'a1'],
        reason: 'the branch carries what came before, not the question itself');
    expect(copy.title, contains('branch'));
    expect(copy.effort, 'careful', reason: 'carrying the effort the chat was set to');
    expect(copy.systemPrompt, 'Cite the file.', reason: 'and its instructions');
    expect(copy.seed, contains('first answer'));
    expect(copy.rootId, isNot(conv.rootId),
        reason: 'on a thread of its own, not the old one');
    expect(controller.store.artifacts(copy.id).map((a) => a.id), ['art1'],
        reason: 'and the files those messages produced come with them');
  });

  test('a checkpoint survives a round trip, and says what it can undo', () {
    final m = ChatMessage(
      id: 'ck1',
      role: ChatRole.bot,
      content: 'Done — two files.',
      checkpoint: const {
        'repo': 'nym/alpha',
        'branch': 'main',
        'baseSha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'paths': ['src/retry.js', 'README.md'],
        'branches': ['fix/retry'],
        'pulls': ['Opened pull request #7'],
        'undoable': true,
      },
    );
    final back = ChatMessage.fromJson(m.toJson());
    expect(back.checkpoint, isNotNull,
        reason: 'the way back has to outlive the session that made it');
    expect(back.checkpoint!['baseSha'], m.checkpoint!['baseSha']);
    expect((back.checkpoint!['paths'] as List).length, 2);
    expect(back.checkpoint!['undoable'], isTrue);

    // A run with nothing to read the old files back from must not offer a
    // button that cannot work.
    final noBase = ChatMessage(
      id: 'ck2',
      role: ChatRole.bot,
      content: 'Made a branch.',
      checkpoint: const {'repo': 'nym/alpha', 'paths': [], 'undoable': false},
    );
    expect(noBase.checkpoint!['undoable'], isFalse);

    expect(
        ChatMessage(id: 'plain', role: ChatRole.bot, content: 'hi')
            .toJson()
            .containsKey('checkpoint'),
        isFalse,
        reason: 'a reply that changed nothing carries nothing');

    final marked = m.copyWith(checkpoint: {...m.checkpoint!, 'undone': true});
    expect(marked.checkpoint!['undone'], isTrue);
    expect(m.checkpoint!.containsKey('undone'), isFalse,
        reason: 'and marking one spent does not reach back into the original');
  });

  test('a long paste is a document, not a sentence', () {
    expect(Attachments.pasteIsLong('a normal thing somebody types'), isFalse,
        reason: 'what you type by hand stays typed');
    expect(Attachments.pasteIsLong('x' * 1600), isTrue,
        reason: 'a lot of characters counts');
    expect(
        Attachments.pasteIsLong(List.filled(31, 'a').join('\n')), isTrue,
        reason: 'and so does a lot of lines, however short they are');
    expect(Attachments.pasteIsLong(List.filled(5, 'a').join('\n')), isFalse);

    final long = List.generate(40, (i) => 'line $i of a log').join('\n');
    final a = Attachments.fromText(long, id: 'a1');
    expect(a.kind, AttachmentKind.text);
    expect(a.name, 'Pasted text',
        reason: 'named for what it is, not a filename it never had');
    expect(a.lines, 40, reason: 'counting its lines');
    expect(a.measure, '40 lines',
        reason: 'lines say more about a pasted wall of text than bytes do');
    expect(a.text, long, reason: 'and keeping every one of them');
    expect(a.wireBlock, contains('```'),
        reason: 'it travels fenced, so the model reads it as a block');
    expect(Attachment.fromJson(a.toJson()).lines, 40,
        reason: 'and that survives a round trip');
    // A file keeps its bytes; only something pasted is measured in lines.
    final file = Attachment(
        id: 'f1', kind: AttachmentKind.text, name: 'notes.md', size: 2048);
    expect(file.measure, '2 KB');
  });

  test('speech goes one way only', () {
    expect(BotCommands.all().any((c) => c.name == 'voice'), isFalse,
        reason: 'dictation is gone, so ?voice is not a command any more');
    expect(BotCommands.remote().any((c) => c.name == 'speak'), isTrue,
        reason: 'reading something aloud is untouched');
  });

  test('auto-delete is off unless it is asked for', () {
    expect(AppSettings().autoDeleteDays, 0);
    final back = AppSettings.fromJson(
        (AppSettings()..autoDeleteDays = 7).toJson());
    expect(back.autoDeleteDays, 7);
    final conv = Conversation.fromJson(
        Conversation(id: 'c', rootId: 'r', ephemeral: true).toJson());
    expect(conv.ephemeral, isTrue);
    expect(Conversation(id: 'c', rootId: 'r').ephemeral, isFalse);
  });

  test('a missed run catches up once, not once per slot it went past', () {
    final entry = Schedule(
      id: 's1',
      prompt: 'digest',
      repeat: ScheduleRepeat.daily,
      nextAt: DateTime.now().subtract(const Duration(days: 5)),
    );
    expect(entry.due, isTrue);

    entry.advance();

    expect(entry.runs, 1);
    expect(entry.enabled, isTrue);
    expect(entry.due, isFalse, reason: 'the next slot is in the future');
    expect(entry.nextAt.isAfter(DateTime.now()), isTrue);
    expect(entry.nextAt.difference(DateTime.now()).inHours, lessThan(24));
  });

  test('a one-off disables itself once it has run', () {
    final entry = Schedule(
      id: 's1',
      prompt: 'once please',
      repeat: ScheduleRepeat.once,
      nextAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    expect(entry.due, isTrue);
    entry.advance();
    expect(entry.enabled, isFalse);
    expect(entry.due, isFalse);
    expect(entry.runs, 1);
  });

  test('a paused schedule is never due', () {
    final entry = Schedule(
      id: 's1',
      prompt: 'x',
      nextAt: DateTime.now().subtract(const Duration(days: 1)),
      enabled: false,
    );
    expect(entry.due, isFalse);
  });

  test('a schedule survives a round trip through JSON', () {
    final entry = Schedule(
      id: 's1',
      title: 'Morning digest',
      prompt: 'What changed overnight?',
      repeat: ScheduleRepeat.weekly,
      convId: 'c1',
      runs: 3,
    );
    final back = Schedule.decodeList(Schedule.encodeList([entry])).single;
    expect(back.title, 'Morning digest');
    expect(back.prompt, 'What changed overnight?');
    expect(back.repeat, ScheduleRepeat.weekly);
    expect(back.convId, 'c1');
    expect(back.runs, 3);
    expect(back.nextAt.millisecondsSinceEpoch,
        entry.nextAt.millisecondsSinceEpoch);
  });

  testWidgets('a schedule is stored, and only the due one is picked up',
      (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);

    await controller.saveSchedule(Schedule(
      id: 's1',
      title: 'Due',
      prompt: 'now',
      nextAt: DateTime.now().subtract(const Duration(minutes: 5)),
    ));
    await controller.saveSchedule(Schedule(
      id: 's2',
      title: 'Later',
      prompt: 'later',
      nextAt: DateTime.now().add(const Duration(days: 1)),
    ));

    expect(controller.schedules.length, 2);
    expect(controller.dueSchedules.map((s) => s.id), ['s1']);
    expect(controller.store.schedules().length, 2);

    await controller.deleteSchedule('s1');
    expect(controller.dueSchedules, isEmpty);
    expect(controller.store.schedules().length, 1);
  });

  test('a patch is split by file and counted', () {
    const patch = '''
diff --git a/app/js/ui.js b/app/js/ui.js
--- a/app/js/ui.js
+++ b/app/js/ui.js
@@ -10,3 +10,4 @@
 const a = 1;
-const b = 2;
+const b = 3;
+const c = 4;
diff --git a/two.txt b/two.txt
+++ b/two.txt
@@ -1 +1 @@
-c
+d
''';
    final files = DiffFile.parse(patch);
    expect(files.length, 2);
    expect(files.first.path, 'app/js/ui.js');
    expect(files.first.added, 2);
    expect(files.first.removed, 1);
    expect(files.last.path, 'two.txt');
    expect(files.last.added, 1);
    expect(files.last.removed, 1);

    final hunks =
        files.first.lines.where((l) => l.kind == DiffLineKind.hunk).toList();
    expect(hunks.length, 1);
    final adds =
        files.first.lines.where((l) => l.kind == DiffLineKind.add).toList();
    expect(adds.first.newNo, 11, reason: 'numbered from the hunk header');
    expect(adds.first.oldNo, isNull, reason: 'an added line has no old number');
  });

  test('a bare hunk still renders rather than being dropped', () {
    final files = DiffFile.parse('@@ -1 +1 @@\n-a\n+b\n');
    expect(files.length, 1);
    expect(files.single.path, isEmpty);
    expect(files.single.added, 1);
    expect(DiffFile.parse(''), isEmpty);
  });

  test('a citation says where it came from', () {
    final c = Citation.fromJson(const {
      'title': 'NIP-59 gift wrap',
      'url': 'https://www.github.com/nostr-protocol/nips',
      'snippet': 'A gift wrap hides the sender.',
    });
    expect(c.title, 'NIP-59 gift wrap');
    expect(c.host, 'github.com', reason: 'www is noise');
    expect(c.initial, 'G');
    expect(c.snippet, 'A gift wrap hides the sender.');

    // No title: the host is a better label than the whole URL.
    final bare = Citation.fromJson(const {'url': 'https://nist.gov/fips/203'});
    expect(bare.title, 'nist.gov');
    expect(Citation.fromJson(const {}).title, isNotEmpty);
  });

  testWidgets('a message keeps its actions until it is tapped, and names each',
      (tester) async {
    final message = ChatMessage(
      id: 'm1',
      role: ChatRole.bot,
      content: 'hi',
    );
    var toggled = 0;
    Widget host({required bool open}) => MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: message,
              selfPubkey: 'a' * 64,
              settings: AppSettings(),
              onAction: (_, __) {},
              actionsOpen: open,
              onToggleActions: () => toggled++,
            ),
          ),
        );

    await tester.pumpWidget(host(open: false));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsNothing, reason: 'closed by default');

    // The body renders as rich text, so the rendered body is what is tapped.
    await tester.tap(find.byType(MarkdownBody).first, warnIfMissed: false);
    expect(toggled, 1, reason: 'tapping the bubble asks the list to open it');

    await tester.pumpWidget(host(open: true));
    await tester.pumpAndSettle();
    for (final label in ['Copy', 'Ask again', 'Branch from here', 'Quote', 'Delete']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('a reply says what it cost, priced at the published rate',
      (tester) async {
    late List<(String, String)> rows;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        rows = costRows(
          context,
          ChatMessage(
            id: 'm1',
            role: ChatRole.bot,
            content: 'hi',
            cost: 4,
            model: 'Claude Opus 5',
            calls: 2,
            task: 'code',
            repos: const ['nymbot/app'],
          ),
        );
        return const SizedBox.shrink();
      }),
    ));

    final by = {for (final r in rows) r.$1: r.$2};
    expect(by['Charged'], contains('4'));
    expect(by['Tier'], 'Pro');
    expect(by['Model'], 'Claude Opus 5');
    expect(by["At today's price"], contains('400'));
    expect(by['Model calls'], '2');
    expect(by['Routed as'], 'code');
    expect(by['Repositories read'], 'nymbot/app');
    expect(by['When'], isNotEmpty);
  });

  testWidgets('a standard reply is priced off the standard rate',
      (tester) async {
    late Map<String, String> by;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        final rows = costRows(context,
            ChatMessage(id: 'm1', role: ChatRole.bot, content: 'hi', cost: 1));
        by = {for (final r in rows) r.$1: r.$2};
        return const SizedBox.shrink();
      }),
    ));
    expect(by['Tier'], 'Standard');
    expect(by['Model'], 'Auto-routed');
    expect(by["At today's price"], contains('10'));
    expect(by.containsKey('Model calls'), isFalse,
        reason: 'one call is the ordinary case, not worth a row');
  });

  test('what the worker said it did survives a save', () {
    final back = ChatMessage.fromJson(ChatMessage(
      id: 'm1',
      role: ChatRole.bot,
      content: 'hi',
      cost: 4,
      model: 'Claude Opus 5',
      calls: 3,
      task: 'research',
    ).toJson());
    expect(back.calls, 3);
    expect(back.task, 'research');
    expect(ChatMessage(id: 'm2', role: ChatRole.bot, content: 'x').calls, 1);
  });

  testWidgets('a continuation budget is a budget, never a blank cheque',
      (tester) async {
    final controller = await AppController.boot();
    addTearDown(controller.dispose);

    await controller.setAutoContinue(0);
    expect(controller.continueBudget, 0,
        reason: 'off by default: nothing carries on unasked');

    await controller.setAutoContinue(25);
    expect(controller.continueBudget, 25);
    controller.continuedSpend = 10;
    expect(controller.continueBudget, 15, reason: 'legs come off the budget');
    controller.continuedSpend = 40;
    expect(controller.continueBudget, 0, reason: 'never below nothing');

    // "Until my balance runs out" is still the balance, not infinity.
    controller.continuedSpend = 0;
    await controller.setAutoContinue(-1);
    controller.proBalance = 7;
    expect(controller.continueBudget, 7);
    controller.proBalance = null;
    expect(controller.continueBudget, 0,
        reason: 'an unknown balance buys nothing');
  });

  test('a progress step reads as words, and an unknown one says nothing', () {
    expect(
      progressLine((n: 1, kind: 'routing', text: 'Claude Opus 5', tool: '', call: 0, of: 0, flag: false)),
      contains('Claude Opus 5'),
    );
    expect(
      progressLine((n: 2, kind: 'search', text: 'ml-kem', tool: '', call: 0, of: 0, flag: false)),
      contains('ml-kem'),
    );
    final call = progressLine((n: 3, kind: 'model', text: '', tool: '', call: 2, of: 6, flag: false));
    expect(call, contains('2'));
    expect(call, contains('6'));
    final tool = progressLine(
        (n: 4, kind: 'tool', text: 'app/js/ui.js', tool: 'read_file', call: 0, of: 0, flag: false));
    expect(tool, contains('Reading'));
    expect(tool, contains('app/js/ui.js'), reason: 'both what and on what');
    expect(
      progressLine((n: 5, kind: 'thinking', text: 'weighing it up', tool: '', call: 0, of: 0, flag: false)),
      'weighing it up',
    );
    expect(
      progressLine((n: 6, kind: 'who-knows', text: 'x', tool: '', call: 0, of: 0, flag: false)),
      isEmpty,
      reason: 'a step it does not know is silent, not garbage',
    );
  });

  test('a repository announced on Nostr is read off its announcement', () {
    const pk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final naddr = encodeNaddr(
        identifier: 'ngit', pubkey: pk, kind: 30617, relays: ['wss://relay.ngit.dev']);
    final npub = encodeNpub(pk);

    expect(Ngit.parseAddress(naddr)?.identifier, 'ngit',
        reason: 'an naddr is a repository address');
    expect(Ngit.parseAddress('nostr://$naddr')?.identifier, 'ngit',
        reason: 'so is one wearing a nostr:// URL');
    expect(Ngit.parseAddress('nostr://$npub/ngit')?.pubkey, pk,
        reason: 'so is an npub and an identifier');
    expect(Ngit.parseAddress('nostr://$npub/relay.ngit.dev/ngit')?.relays.first,
        'wss://relay.ngit.dev',
        reason: 'a relay hint is read and given its scheme');
    expect(Ngit.parseAddress('nostr://$npub/my%20repo')?.identifier, 'my repo',
        reason: 'and the identifier is percent-decoded');
    expect(Ngit.parseAddress('nostr://danconwaydev.com/relay.ngit.dev/ngit'), isNull,
        reason: 'a NIP-05 owner is refused rather than guessed at');
    expect(Ngit.parseAddress('not an address'), isNull);

    // Nostr carries the announcement; a git server carries the code.
    expect(Ngit.forgeFor('https://github.com/Spl0itable/nym-staging.git')?.repo,
        'Spl0itable/nym-staging');
    expect(Ngit.forgeFor('https://gitlab.com/a/b/c/d.git')?.repo, 'a/b/c/d',
        reason: 'a nested GitLab group survives');
    expect(Ngit.forgeFor('https://codeberg.org/me/repo')?.provider, 'gitea');
    final self = Ngit.forgeFor('https://git.example.org/me/repo.git');
    expect(self?.guessed, isTrue,
        reason: 'a self-hosted forge is a guess, and says so');
    expect(Ngit.forgeFor('git@github.com:me/repo.git'), isNull,
        reason: 'an ssh clone URL has no API to read files through');
    expect(Ngit.forgeFor('git://example.org/me/repo'), isNull);
    expect(Ngit.forgeFor('https://github.com/onlyowner'), isNull,
        reason: 'and a URL naming no repository names no repository');
  });

  test('where a repository was announced travels with it', () {
    final repo = GitRepo(
      id: 'r1',
      repo: 'DanConwayDev/ngit-cli',
      token: 'ghp_x',
      provider: 'github',
      host: 'github.com',
      branch: 'master',
      ngit: const NgitOrigin(
        naddr: 'naddr1abc',
        repoId: 'ngit',
        name: 'ngit',
        web: 'https://gitworkshop.dev/repo/ngit',
        euc: 'abc123',
      ),
    );
    expect(repo.display, 'ngit',
        reason: 'a reply calls it by the name it announces');
    expect(repo.subtitle, contains('ngit'),
        reason: 'and the list says where it came from');
    expect(repo.toPayload()['ngit'], isNotNull,
        reason: 'the worker is told, so the model can name it too');
    final back = GitRepo.fromJson(repo.toJson());
    expect(back.ngit?.naddr, 'naddr1abc', reason: 'and it survives a round trip');
    expect(back.ngit?.euc, 'abc123',
        reason: 'including the commit that tells it from a fork');
    expect(GitRepo.fromJson({'id': 'r2', 'repo': 'a/b'}).ngit, isNull,
        reason: 'a repository typed in by hand has no announcement');
  });

  test('a picture travels as the link the model can be handed', () {
    final pending = Attachment(
      id: 'i1',
      kind: AttachmentKind.image,
      name: 'cat.png',
      mime: 'image/png',
      size: 2048,
      bytesBase64: 'AAAA',
    );
    expect(pending.wireBlock, contains('could not be uploaded'),
        reason: 'a picture nothing can fetch says so rather than pretending');
    pending.url = 'https://blossom.band/abc.png';
    expect(pending.wireBlock, contains('https://blossom.band/abc.png'),
        reason: 'once uploaded the message carries the link, not the filename');
    expect(pending.wireBlock, isNot(contains('KB')),
        reason: 'a size is what you say when you have nothing better');
    expect(pending.toPayload()['url'], 'https://blossom.band/abc.png');
    expect(Attachment.fromJson(pending.toJson()).url, 'https://blossom.band/abc.png',
        reason: 'and it survives a round trip, so a resend does not re-upload');
    expect(
      Attachment(id: 't1', kind: AttachmentKind.text, name: 'a.md', lang: 'markdown', text: 'hi')
          .wireBlock,
      contains('```markdown'),
      reason: 'a text file still travels as its text',
    );
  });

  test('a reply says which tier wrote it', () {
    final pro = ChatMessage(
        id: '1', role: ChatRole.bot, content: 'x', pro: true, model: 'Claude Opus 5');
    final std = ChatMessage(id: '2', role: ChatRole.bot, content: 'x', pro: false);
    expect(pro.pro, isTrue);
    expect(std.pro, isFalse);
    expect(ChatMessage.fromJson(pro.toJson()).pro, isTrue,
        reason: 'and it survives being read back');
    expect(ChatMessage.fromJson(std.toJson()).pro, isFalse);
    // Replies stored before the flag existed fall back to the model name, which
    // is only ever recorded for a frontier model.
    final old = ChatMessage.fromJson({
      'id': '3', 'role': 'bot', 'content': 'x', 'model': 'Claude Opus 5', 'at': 0,
    });
    expect(old.pro, isNull);
    expect(old.model, isNotNull);
  });

  test('the newer progress steps read as words too', () {
    String line(String kind,
            {String text = '', int call = 0, int of = 0, bool flag = false}) =>
        progressLine((n: 1, kind: kind, text: text, tool: '', call: call, of: of, flag: flag));

    expect(line('stage', text: 'reading'), contains('relays'),
        reason: 'the slowest part of a turn is not silent');
    expect(line('page', text: 'https://example.com/a'), contains('https://example.com/a'),
        reason: 'a link being read says which');
    expect(line('vision', call: 2), contains('2'));
    expect(line('vision', call: 1), contains('picture'));
    expect(line('route', text: 'coding'), contains('coding'),
        reason: 'standard routing says which route it took');
    expect(line('route', flag: true), contains('can see'),
        reason: 'or that a picture sent it somewhere else');
    expect(line('effort', text: 'planning'), contains('Planning'));
    expect(line('stage', text: 'something-else'), isEmpty,
        reason: 'a stage it does not know is silent, not garbage');
  });

  test('one model call is not named twice', () {
    TurnStep step(String kind, String text, {int of = 0}) =>
        (n: 1, kind: kind, text: text, tool: '', call: 1, of: of, flag: false);

    final trimmed = trimProgress([
      step('routing', 'Claude Fable 5.1'),
      step('model', 'Claude Fable 5.1'),
      step('thinking', 'weighing it up'),
    ]);
    expect(trimmed.map((s) => s.kind).toList(), ['routing', 'thinking'],
        reason: 'routing already said which model; asking it says nothing new');
    expect(
      trimProgress([
        step('routing', 'Claude Fable 5.1'),
        step('model', 'Claude Fable 5.1', of: 3),
      ]).length,
      2,
      reason: 'but a call out of several still counts itself',
    );
  });

  test('relays are reached through the worker before they are reached directly',
      () {
    expect(RelayPool.poolUrl, 'wss://${NymbotConfig.apiHost}/api/relay-pool');
    final pool = RelayPool();
    expect(pool.pooled, isFalse,
        reason: 'nothing is proxied until the proxy answers');
    expect(pool.connected, 0);
    pool.close();
  });

  testWidgets('the maker of a model is drawn, and an unknown one still is',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Row(children: [
          BrandTile(slug: 'anthropic'),
          BrandTile(slug: 'black-forest-labs'),
          BrandTile(slug: 'someone-new'),
        ]),
      ),
    ));
    expect(BrandMarks.of('anthropic'), isNotNull,
        reason: 'a known maker is drawn as its own mark, not initials');
    expect(BrandMarks.of('black-forest-labs'), isNotNull);
    expect(find.text('SO'), findsOneWidget,
        reason: 'a maker with no entry still gets a tile rather than a gap');
  });

  test('every maker mark parses to the geometry it declares', () {
    expect(BrandMarks.marks, isNotEmpty);
    for (final entry in BrandMarks.marks.entries) {
      final paths = BrandMarks.geometry(entry.key);
      expect(paths.length, entry.value.paths.length, reason: entry.key);
      var bounds = paths.first.getBounds();
      for (final path in paths.skip(1)) {
        bounds = bounds.expandToInclude(path.getBounds());
      }
      final box = entry.value.box;
      expect(bounds.isEmpty, isFalse, reason: entry.key);
      expect(bounds.contains(box.center), isTrue, reason: entry.key);
      expect(bounds.width, greaterThanOrEqualTo(box.width - 0.05), reason: entry.key);
      expect(bounds.height, greaterThanOrEqualTo(box.height - 0.05), reason: entry.key);
      expect(bounds.left, greaterThan(-2.0), reason: entry.key);
      expect(bounds.top, greaterThan(-2.0), reason: entry.key);
      expect(bounds.right, lessThan(26.0), reason: entry.key);
      expect(bounds.bottom, lessThan(26.0), reason: entry.key);
    }
  });

  test('the long-task settings survive a round trip and default off', () {
    final fresh = AppSettings();
    expect(fresh.autoContinue, 0);
    expect(fresh.showProgress, isTrue);
    final back = AppSettings.fromJson((AppSettings()
          ..autoContinue = -1
          ..showProgress = false)
        .toJson());
    expect(back.autoContinue, -1);
    expect(back.showProgress, isFalse);
  });

  // --- what the account already holds -----------------------------------------
  //
  // The root row is Nymchat's, written under the name Nymchat gives it. Both
  // apps have to name it identically or each reads "no root" and mints one,
  // which is the split the row exists to prevent.

  test('the root row is named the way Nymchat names it', () {
    const pubkey =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
    // Nymchat's `_d1Category`: 'nymchat-' + sha256hex(`${pubkey}:d1:${dTag}`).
    final expected = 'nymchat-${crypto.sha256.convert(utf8.encode('$pubkey:d1:nymchat-pq-root')).toString()}';
    expect(StorageSync.categoryFor(pubkey, StorageSync.pqRootDTag), expected);
    // And what the worker will accept as a settings category.
    expect(RegExp(r'^nym(?:chat|bot)-[a-z0-9-]{1,120}$').hasMatch(expected), isTrue);
  });

  test('a root row is read back as the root it names', () async {
    final sk = Uint8List.fromList(List<int>.filled(32, 7));
    final signer = LocalSigner(sk);
    final root = pq.pqGenerateRoot();
    final fingerprint = pq.pqRootFingerprint(root);

    late String written;
    late String blob;
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['action'] == 'settings-set') {
        written = body['category'] as String;
        blob = body['blob'] as String;
        return http.Response(jsonEncode({'ok': true}), 200);
      }
      // The row is echoed back under the name it was written with.
      return http.Response(
        jsonEncode({
          'categories': {
            written: {'blob': blob, 'updatedAt': 1},
          },
        }),
        200,
      );
    });
    final sync = StorageSync(client: client);
    expect(await sync.publishPqRootRecord(signer, root), isTrue);
    expect(written, StorageSync.categoryFor(signer.pubkey, StorageSync.pqRootDTag));

    final read = await sync.pqRootRecord(signer);
    expect(read, isNotNull);
    expect(read!.present, isTrue);
    expect(read.fingerprint, fingerprint);
  });

  test('a row nobody can open is still proof a root exists', () async {
    final signer = LocalSigner(Uint8List.fromList(List<int>.filled(32, 9)));
    final category =
        StorageSync.categoryFor(signer.pubkey, StorageSync.pqRootDTag);
    final sync = StorageSync(
      client: MockClient((request) async => http.Response(
            jsonEncode({
              'categories': {
                category: {'blob': 'not something this key can open', 'updatedAt': 1},
              },
            }),
            200,
          )),
    );
    final read = await sync.pqRootRecord(signer);
    expect(read!.present, isTrue, reason: 'a row is a row');
    expect(read.fingerprint, isNull, reason: 'but it names no root we can check');
  });

  test('a read that did not complete is not an answer', () async {
    final signer = LocalSigner(Uint8List.fromList(List<int>.filled(32, 11)));
    final sync = StorageSync(
      client: MockClient((_) async => http.Response('nope', 503)),
    );
    expect(await sync.pqRootRecord(signer), isNull);
  });

  test('the profile mirror is read as the signed events it stores', () async {
    const pubkey =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
    final event = {
      'id': 'a' * 64,
      'pubkey': pubkey,
      'created_at': 1,
      'kind': 0,
      'tags': <List<String>>[],
      'content': '{"name":"satoshi"}',
      'sig': 'b' * 128,
    };
    final sync = StorageSync(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['action'], 'profile-get');
        expect(body.containsKey('auth'), isFalse, reason: 'a kind 0 is public');
        return http.Response(
          '${jsonEncode([pubkey, {'event': event, 'updatedAt': 2}])}\n'
          '${jsonEncode(['c' * 64, null])}\n',
          200,
        );
      }),
    );
    final got = await sync.profileEvents([pubkey, 'c' * 64]);
    expect(got, isNotNull);
    expect(got!.length, 1, reason: 'a key with no row is simply absent');
    expect(got[pubkey]!.content, '{"name":"satoshi"}');
  });

  test('a code is checked against the root the account recorded', () {
    final mine = pq.pqGenerateRoot();
    final theirs = pq.pqGenerateRoot();
    final code = encodeNymPq(mine);
    expect(Identity.rootFromCode(code), isNotNull);
    expect(Identity.rootFromCode('nsec1notacode'), isNull);
    expect(Identity.fingerprintOfCode(code), pq.pqRootFingerprint(mine));
    expect(Identity.fingerprintOfCode(code) == pq.pqRootFingerprint(theirs), isFalse);
    // The epoch of the root is what decides the key, so the same code produces
    // a different one at each.
    final atZero = Identity.kemForCode(code, 0)!;
    final atOne = Identity.kemForCode(code, 1)!;
    expect(atZero.length, atOne.length);
    expect(atZero, isNot(equals(atOne)));
  });

  test('a mirrored profile becomes the name and avatar the app draws', () async {
    SharedPreferences.setMockInitialValues({});
    const pubkey =
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
    final store = await Store.open();
    final relays = RelayPool();
    var woken = 0;

    // A mirror row that is not signed by the key it claims is not a profile.
    final forged = {
      'id': 'a' * 64,
      'pubkey': pubkey,
      'created_at': 1,
      'kind': 0,
      'tags': <List<String>>[],
      'content': '{"name":"not satoshi","picture":"https://x/evil.png"}',
      'sig': 'b' * 128,
    };
    final refused = Profiles(
      store,
      relays,
      StorageSync(
        client: MockClient((_) async => http.Response(
              '${jsonEncode([pubkey, {'event': forged, 'updatedAt': 1}])}\n',
              200,
            )),
      ),
    );
    await refused.load(pubkey, mirrorOnly: true);
    expect(refused.of(pubkey).hasProfile, isFalse,
        reason: 'a relay never gets to say what a profile is, nor the mirror');
    expect(refused.of(pubkey).name, NymIdentity.name(pubkey),
        reason: 'so the generated nym still stands');

    // And a mirror that has nothing is not an answer yet: the relays have not
    // been asked, so nothing is remembered that would suppress the question.
    final empty = Profiles(
      store,
      relays,
      StorageSync(client: MockClient((_) async => http.Response('', 200))),
    );
    empty.addListener(() => woken++);
    await empty.load(pubkey, mirrorOnly: true);
    expect(woken, 0, reason: 'nothing was learned, so nobody is woken');
  });

  // --- what a figure reads as ---------------------------------------------

  test('a credit figure keeps every digit, however long it gets', () {
    expect([0, 1, 999].map(figure).join(' '), '0 1 999',
        reason: 'nothing to separate below a thousand');
    expect([1000, 1250, 9999].map(figure).join(' '), '1,000 1,250 9,999');
    // Money is never abbreviated: 12,500 credits is not "12.5k", because the
    // 500 is somebody's.
    expect([10000, 12500, 125000].map(figure).join(' '),
        '10,000 12,500 125,000');
    expect([1000000, 12345678].map(figure).join(' '), '1,000,000 12,345,678');
    // The same figure the web app prints, so a balance reads the same in both.
    expect(figure(50000), '50,000');
  });

  test('iOS does not sell credits, and every other platform does', () {
    // The value is the platform's, not this test's; what is pinned is that the
    // question is asked at all and that it answers off-iOS.
    expect(creditPurchasesDisabled, isFalse,
        reason: 'the test host is not iOS, so the sheet still sells');
  });
}
