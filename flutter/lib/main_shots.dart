// Screenshot entrypoint. NOT shipped — a development harness for producing
// store artwork and knowledge-base figures from the real app.
//
// It boots the same `NymbotApp` widget tree that `main.dart` boots, with the
// same controller, the same theme and the same widgets. The only difference is
// where the data comes from: instead of relays and the worker (neither of which
// exists on the web target used to render these), the store is seeded through
// the very same public entry points the app uses when restoring its own cache
// — `store.saveConversations`, `store.saveMessages`, `open`.
//
// `enter()` is deliberately never called: that is what opens relay sockets and
// starts polling the worker. Everything these captures show is drawn by the
// app's own widgets from its own state.
//
// Which screen to render is read from the URL, so each capture is one page load
// with no scripted tapping: /?shot=chat, ?shot=models, ?shot=buy, ...
import 'package:flutter/material.dart';

import 'app.dart';
import 'features/i18n/i18n.dart';
import 'features/sheets/credits_sheet.dart';
import 'features/sheets/models_sheet.dart';
import 'features/sheets/repos_sheet.dart';
import 'features/sheets/workspaces_sheet.dart';
import 'models/conversation.dart';
import 'models/workspace.dart';
import 'state/app_controller.dart';

/// A fixed key, so the npub, the avatar and every colour derived from them are
/// the same in every capture rather than reshuffling per run.
const _nsec =
    '5a705a100000000000000000000000000000000000000000000000000000000e';

int _ts(int minutesAgo) => DateTime.now()
    .subtract(Duration(minutes: minutesAgo))
    .millisecondsSinceEpoch;

ChatMessage _self(String id, String content, int minutesAgo) => ChatMessage(
      id: id,
      role: ChatRole.self,
      content: content,
      at: DateTime.fromMillisecondsSinceEpoch(_ts(minutesAgo)),
    );

ChatMessage _bot(
  String id,
  String content, {
  required int minutesAgo,
  double cost = 0,
  String? model,
  bool? pro,
  String? thinking,
  String? task,
}) =>
    ChatMessage(
      id: id,
      role: ChatRole.bot,
      content: content,
      cost: cost,
      model: model,
      pro: pro,
      thinking: thinking,
      task: task,
      at: DateTime.fromMillisecondsSinceEpoch(_ts(minutesAgo)),
    );

/// The chat the artwork leads with: a real question with a real answer, priced
/// the way the app prices one.
List<ChatMessage> _mainThread() => [
      _self('m1', 'Explain ML-KEM in three sentences, then tell me what it '
          'does not protect.', 14),
      _bot(
        'm2',
        'ML-KEM is a key-encapsulation mechanism built on the hardness of '
            'the module learning-with-errors problem, standardized by NIST as '
            'FIPS 203. Two parties use it to agree a shared secret over a '
            'channel an eavesdropper can read, and the security argument does '
            'not rest on factoring or discrete logs — which is the point, '
            'because a quantum computer breaks both.\n\n'
            'What it does not protect:\n\n'
            '- **Who you talked to.** It secures the contents of an exchange, '
            'not the fact that it happened. Metadata is a separate problem.\n'
            '- **Anything already captured.** Traffic recorded today under a '
            'classical key stays recorded; ML-KEM protects what you send from '
            'the moment you adopt it, not retroactively.\n'
            '- **Your endpoint.** A key agreed perfectly still lands on a '
            'device someone can compromise.',
        minutesAgo: 13,
        cost: 1.24,
        model: 'Claude Sonnet 5',
        pro: true,
      ),
      _self('m3', 'Which of those three actually applies to this chat?', 6),
      _bot(
        'm4',
        'The first one, partly. This conversation is gift-wrapped, so a relay '
            'sees a wrapped event and a timestamp — not who wrote it and not '
            'what it says. What it can see is that *some* key published '
            'something at that moment.\n\n'
            'The second does not apply: the post-quantum layer here is on by '
            'default, so nothing in this chat was ever sent under a purely '
            'classical key.\n\n'
            'The third always applies, to everything.',
        minutesAgo: 5,
        cost: 0.87,
        model: 'Claude Sonnet 5',
        pro: true,
      ),
    ];

/// A repository task, which is the app at its most capable: several model
/// calls against real files, and a cost that says so.
List<ChatMessage> _repoThread() => [
      _self('r1', 'Why is the balance not updating after a standard reply?', 22),
      _bot(
        'r2',
        'Found it. `chat.js` builds the reply record from `data.cost` and '
            '`data.balance`, but the worker now sends the fractional figures '
            'as `costCredits` and `balanceCredits` — so the whole-credit '
            'value overwrote the fraction on every turn.\n\n'
            '```diff\n'
            '-  cost: data.cost || 0,\n'
            '-  balance: data.balance,\n'
            '+  cost: data.costCredits != null ? data.costCredits : (data.cost || 0),\n'
            '+  balanceCredits: typeof data.balanceCredits === \'number\'\n'
            '+      ? data.balanceCredits : null,\n'
            '```\n\n'
            'Three call sites read the same pair. I can push the fix to a '
            'branch if you want it.',
        minutesAgo: 20,
        cost: 6.4,
        model: 'Claude Opus 5',
        pro: true,
        task: 'repo',
      ),
    ];

Conversation _conv(
  String id,
  String title, {
  bool pinned = false,
  int minutesAgo = 0,
  List<String> repoIds = const [],
  double creditsSpent = 0,
  int messageCount = 0,
}) =>
    Conversation(
      id: id,
      rootId: 'root-$id',
      title: title,
      pinned: pinned,
      repoIds: repoIds,
      creditsSpent: creditsSpent,
      messageCount: messageCount,
      createdAt: DateTime.fromMillisecondsSinceEpoch(_ts(minutesAgo + 90)),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(_ts(minutesAgo)),
    );

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final shot = Uri.base.queryParameters['shot'] ?? 'chat';
  final light = Uri.base.queryParameters['theme'] == 'light';

  final c = await AppController.boot();

  // A real key through the app's own import path, so `signedIn` is genuine and
  // the npub on screen is derived rather than typed in.
  await c.identity.import(_nsec);
  c.signIn();

  // Dark by default: the store artwork, the site and the app's own brand all
  // sit on the same near-black. `?theme=light` renders the other one for the
  // appearance figures.
  await c.saveSettings(AppSettings(
    theme: light ? ChatTheme.light : ChatTheme.dark,
    showCostEstimate: true,
    showProgress: true,
  ));

  // Balances the toolbar and the buy sheet read. Fractional on purpose: a
  // metered reply costs a fraction of a credit, and the artwork should show
  // that rather than a whole number that implies per-message pricing.
  c.standardBalance = 128.5;
  c.proBalance = 42.75;
  c.free = null;

  c.proModel = {
    'key': 'claude-sonnet',
    'label': 'Claude Sonnet 5',
    'credits': 1,
    'max': 8,
    'authorSlug': 'anthropic',
  };

  final conversations = <Conversation>[
    _conv('c1', 'Post-quantum key exchange',
        pinned: true, minutesAgo: 5, creditsSpent: 2.11, messageCount: 4),
    _conv('c2', 'Fix the fractional balance bug',
        minutesAgo: 20, repoIds: ['repo1'], creditsSpent: 6.4, messageCount: 2),
    _conv('c3', 'Rewrite the onboarding copy',
        minutesAgo: 95, creditsSpent: 3.02, messageCount: 8),
    _conv('c4', 'Compare two summarizers',
        minutesAgo: 240, creditsSpent: 1.5, messageCount: 6),
    _conv('c5', 'Lightning invoice edge cases',
        minutesAgo: 1400, creditsSpent: 9.78, messageCount: 12),
    _conv('c6', 'Weekly release notes',
        minutesAgo: 2880, creditsSpent: 4.25, messageCount: 5),
  ];

  await c.store.saveConversations(conversations);
  await c.store.saveMessages('c1', _mainThread());
  await c.store.saveMessages('c2', _repoThread());
  c.conversations = conversations;

  await I18n.load(preferred: c.preferredLanguage);

  runApp(_Shots(
    controller: c,
    shot: shot,
    open: shot == 'repo' ? conversations[1] : conversations[0],
  ));
}

/// Boots the real app, then opens whichever of its own sheets this capture
/// wants, once the first frame is up. The sheets are the app's — this taps
/// them open the way a finger would, so nothing about them is redrawn here.
class _Shots extends StatefulWidget {
  const _Shots(
      {required this.controller, required this.shot, required this.open});

  final AppController controller;
  final String shot;

  final Conversation open;

  @override
  State<_Shots> createState() => _ShotsState();
}

class _ShotsState extends State<_Shots> {
  final _navigator = GlobalKey<NavigatorState>();
  bool _opened = false;

  static const _sheets = {'models', 'buy', 'repos', 'workspaces'};

  @override
  Widget build(BuildContext context) {
    if (!_opened) {
      _opened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // A beat for the first frame to settle before the sheet animates in,
        // so a capture never catches it mid-transition.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await widget.controller.open(widget.open);
        if (!_sheets.contains(widget.shot)) return;
        final ctx = _navigator.currentContext;
        if (ctx == null || !ctx.mounted) return;
        switch (widget.shot) {
          case 'models':
            await showModelsSheet(ctx);
          case 'buy':
            await showCreditsSheet(ctx);
          case 'repos':
            await showReposSheet(ctx);
          case 'workspaces':
            await showWorkspacesSheet(ctx);
        }
      });
    }
    return NymbotApp(controller: widget.controller, navigatorKey: _navigator);
  }
}
