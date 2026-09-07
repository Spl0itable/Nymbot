import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nymbot/app.dart';
import 'package:nymbot/features/citation_cards.dart';
import 'package:nymbot/features/sheets/cost_sheet.dart';
import 'package:nymbot/features/command_sheet.dart';
import 'package:nymbot/features/diff_view.dart';
import 'package:nymbot/features/progress_lines.dart';
import 'package:nymbot/features/gate_screen.dart';
import 'package:nymbot/features/markdown_body.dart';
import 'package:nymbot/features/message_bubble.dart';
import 'package:nymbot/features/nym_avatar.dart';
import 'package:nymbot/features/nym_icons.dart';
import 'package:nymbot/services/profiles.dart';
import 'package:nymbot/core/crypto/bech32_codec.dart';
import 'package:nymbot/models/artifact.dart';
import 'package:nymbot/models/bot.dart';
import 'package:nymbot/models/schedule.dart';
import 'package:nymbot/models/compare.dart';
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
    expect(head, contains('--- style.md ---'));
    expect(head, contains('# House style'));
    expect(head, isNot(contains(r'${')));
  });

  test('a file too big for the window is cut and says so', () {
    final space = Workspace(
      id: 'w1',
      files: [
        KnowledgeFile(id: 'f1', name: 'huge.txt', body: 'x' * 40000),
      ],
    );
    final block = ChatEngine.knowledgeBlock(space);
    expect(block.contains('[…trimmed to fit]'), isTrue);
    expect(block.length, lessThan(40000));
    expect(ChatEngine.knowledgeBlock(null), isEmpty);
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
      progressLine((n: 1, kind: 'routing', text: 'Claude Opus 5', tool: '', call: 0, of: 0)),
      contains('Claude Opus 5'),
    );
    expect(
      progressLine((n: 2, kind: 'search', text: 'ml-kem', tool: '', call: 0, of: 0)),
      contains('ml-kem'),
    );
    final call = progressLine((n: 3, kind: 'model', text: '', tool: '', call: 2, of: 6));
    expect(call, contains('2'));
    expect(call, contains('6'));
    final tool = progressLine(
        (n: 4, kind: 'tool', text: 'app/js/ui.js', tool: 'read_file', call: 0, of: 0));
    expect(tool, contains('Reading'));
    expect(tool, contains('app/js/ui.js'), reason: 'both what and on what');
    expect(
      progressLine((n: 5, kind: 'thinking', text: 'weighing it up', tool: '', call: 0, of: 0)),
      'weighing it up',
    );
    expect(
      progressLine((n: 6, kind: 'who-knows', text: 'x', tool: '', call: 0, of: 0)),
      isEmpty,
      reason: 'a step it does not know is silent, not garbage',
    );
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
}
