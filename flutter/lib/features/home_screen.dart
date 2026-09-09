import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart';
import '../core/crypto/keys.dart';
import '../core/theme/theme.dart';
import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/workspace.dart';
import '../services/attachments.dart';
import '../services/chat_engine.dart';
import '../services/transcript.dart';
import '../services/voice.dart';
import '../state/app_controller.dart';
import 'artifact_screen.dart';
import 'compose_controller.dart';
import 'sheets/bots_sheet.dart';
import 'sheets/compare_sheet.dart';
import 'progress_lines.dart';
import 'sheets/help_sheet.dart';
import 'sheets/schedules_sheet.dart';
import 'sheets/workspaces_sheet.dart';
import 'command_sheet.dart';
import 'markdown_body.dart';
import 'message_bubble.dart';
import 'nym_avatar.dart';
import 'nym_icons.dart';
import 'sheets/anon_sheet.dart';
import 'sheets/appearance_sheet.dart';
import 'sheets/credits_sheet.dart';
import 'sheets/identity_sheet.dart';
import 'sheets/library_sheets.dart';
import 'sheets/memory_sheet.dart';
import 'sheets/models_sheet.dart';
import 'sheets/personas_sheet.dart';
import 'sheets/prompts_sheet.dart';
import 'sheets/repos_sheet.dart';
import 'toolbar.dart';
import 'i18n/i18n.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Styles the markdown you write while you write it, so what is in the
  // field looks like what will be sent.
  final _input = MarkdownEditingController();
  final _scroll = ScrollController();
  final _voice = Voice();
  final _keys = <String, GlobalKey>{};

  String _suggestTerm = '';

  /// What the composer held before the last change, so a paste can be told
  /// apart from typing by how much one change added.
  String _lastInput = '';
  String? _highlighted;

  /// Which message has its action row open. One at a time, so a thread does
  /// not fill up with them.
  String? _openActions;
  bool _atBottom = true;
  String? _findTerm;

  AppController? _app;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final near = _scroll.position.maxScrollExtent - _scroll.offset < 140;
      if (near != _atBottom) setState(() => _atBottom = near);
    });
    _voice.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = AppScope.read(context);
      final conv = app.current;
      if (conv != null) _input.text = app.store.draft(conv.id);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
  }

  @override
  void dispose() {
    final app = _app;
    final conv = app?.current;
    if (app != null && conv != null) {
      unawaited(app.store.setDraft(conv.id, _input.text));
    }
    _input.dispose();
    _scroll.dispose();
    _voice.dispose();
    super.dispose();
  }

  void _toBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (animate) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  /// A message that can be taken back. Anything the app decides to keep on your
  /// behalf says so this way, so undoing it is one tap rather than a hunt
  /// through a settings screen.
  void _sayUndo(String text, VoidCallback undo) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: t('Undo'), onPressed: undo),
      ));
  }

  /// Commands handled here, free of charge, never sent anywhere.
  Future<bool> _localCommand(String text) async {
    final app = AppScope.read(context);
    final m = RegExp(r'^\?(\w+|8ball)\s*(.*)$', dotAll: true).firstMatch(text);
    if (m == null) return false;
    final cmd = m.group(1)!.toLowerCase();
    final arg = m.group(2)!.trim();
    if ((cmd == 'image' || cmd == 'video') &&
        RegExp(r'^off$', caseSensitive: false).hasMatch(arg)) {
      await app.setMediaModel(null, forChat: app.current?.mediaModel != null);
      await app.note(t('Back to answering in words.'));
      return true;
    }
    if (!BotCommands.isLocal(cmd)) return false;

    switch (cmd) {
      case 'help':
        await app.note(BotCommands.helpText());
        return true;
      case 'balance':
        await app.refreshBalance(announce: true);
        return true;
      case 'buy':
        await showCreditsSheet(context);
        return true;
      case 'model':
        if (RegExp(r'^off$', caseSensitive: false).hasMatch(arg)) {
          await app.setProModel(null);
          await app.note(t('Back to standard auto-routing.'));
          return true;
        }
        await showModelsSheet(context, filter: arg);
        return true;
      case 'compare':
        await showCompareSheet(context, prefill: arg);
        return true;
      case 'schedule':
        await showSchedulesSheet(context, prefill: arg);
        return true;
      case 'ghost':
        await app.setEphemeral(!(app.current?.ephemeral ?? false));
        await app.note(app.current?.ephemeral == true
            ? t('Ghost chat. Nothing here is being kept.')
            : t('This chat is being kept again.'));
        return true;
      case 'bot':
        if (RegExp(r'^off$', caseSensitive: false).hasMatch(arg)) {
          await app.setBot(null);
          await app.note(t('Back to plain Nymbot.'));
          return true;
        }
        if (arg.isNotEmpty) {
          final hit = app.bots
              .where((b) => b.name.toLowerCase().contains(arg.toLowerCase()));
          if (hit.isNotEmpty) {
            await app.setBot(hit.first.id);
            await app.note(
                t('{name} is answering this chat.', {'name': hit.first.name}));
            return true;
          }
        }
        if (!context.mounted) return true;
        await showBotsSheet(context);
        if (arg.isNotEmpty) await app.note(t('No bot by that name.'));
        return true;
      case 'workspace':
        if (RegExp(r'^off$', caseSensitive: false).hasMatch(arg)) {
          await app.setWorkspace(null);
          await app.note(t('This chat is on its own again.'));
          return true;
        }
        if (arg.isNotEmpty) {
          final hit = app.workspaces.where(
              (w) => w.name.toLowerCase().contains(arg.toLowerCase()));
          if (hit.isNotEmpty) {
            await app.setWorkspace(hit.first.id);
            await app.note(t('This chat starts with that workspace.'));
            return true;
          }
        }
        if (!context.mounted) return true;
        await showWorkspacesSheet(context);
        if (arg.isNotEmpty) await app.note(t('No workspace by that name.'));
        return true;
      case 'git':
      case 'repo':
        return _gitCommand(app, arg);
      case 'anon':
        await showAnonSheet(context);
        return true;
      case 'persona':
        if (RegExp(r'^off$', caseSensitive: false).hasMatch(arg)) {
          await app.setPersona(null);
          await app.note(t('Persona cleared.'));
          return true;
        }
        if (arg.isNotEmpty) {
          for (final p in app.personas) {
            if (p.name.toLowerCase().contains(arg.toLowerCase())) {
              await app.setPersona(p.id);
              await app.note(t('Persona set to {name}.', {'name': p.name}));
              return true;
            }
          }
        }
        await showPersonasSheet(context);
        return true;
      case 'system':
        if (arg.isNotEmpty) {
          await app.setSystemPrompt(arg);
          await app.note(t('Custom instructions saved for this chat.'));
          return true;
        }
        await showSystemPromptSheet(context);
        return true;
      case 'prompt':
        final picked = await showPromptsSheet(context);
        if (picked != null) {
          _input.text = picked;
          setState(() => _suggestTerm = '');
        }
        return true;
      case 'save':
        final body = _input.text.trim().isEmpty ? arg : _input.text.trim();
        if (body.isEmpty) {
          await app.note(t('There is nothing in the composer to save.'));
          return true;
        }
        await app.savePrompt(SavedPrompt(
          id: DateTime.now().millisecondsSinceEpoch.toRadixString(16),
          title: arg.isEmpty ? body.split('\n').first : arg,
          body: body,
        ));
        await app.note(t('Saved to the prompt library.'));
        return true;
      case 'search':
        await _openSearch(term: arg);
        return true;
      case 'pin':
        await app.togglePin();
        await app.note(app.current!.pinned ? t('Pinned.') : t('Unpinned.'));
        return true;
      case 'archive':
        await app.toggleArchive();
        return true;
      case 'tag':
        if (arg.isNotEmpty) {
          final tags = {
            ...app.current!.tags,
            ...arg.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty),
          }.toList();
          await app.setTagsAndFolder(tags, app.current!.folderId);
          await app.note(t('Tagged.'));
          return true;
        }
        await showTagsSheet(context);
        return true;
      case 'rename':
        if (arg.isNotEmpty) {
          await app.renameCurrent(arg);
          return true;
        }
        await _rename();
        return true;
      case 'fork':
        if (app.messages.isEmpty) {
          await app.note(t('There is nothing to branch yet.'));
          return true;
        }
        await app.forkAt(app.messages.last);
        _say(t('Branched. The new chat carries what was said up to that point.'));
        return true;
      case 'export':
        await _share(app);
        return true;
      case 'stats':
        await showStatsSheet(context);
        return true;
      case 'theme':
        if (RegExp(r'^(dark|light|system|terminal|midnight)$', caseSensitive: false)
            .hasMatch(arg)) {
          app.settings.theme = ChatTheme.values.firstWhere(
            (x) => x.name == arg.toLowerCase(),
            orElse: () => ChatTheme.system,
          );
          await app.saveSettings(app.settings);
          await app.note(t('Theme set to {name}.', {'name': arg.toLowerCase()}));
          return true;
        }
        await showAppearanceSheet(context);
        return true;
      case 'settings':
        await showAppearanceSheet(context);
        return true;
      case 'guide':
        await showHelpSheet(context, prefill: arg);
        return true;
      case 'retry':
        await app.retryLast();
        return true;
      case 'effort':
        if (arg.isNotEmpty && !ChatEngine.effortLevels.containsKey(arg.toLowerCase())) {
          await app.note(t('Effort is normal, careful or deep.'));
          return true;
        }
        final level = await app.cycleEffort(arg.isEmpty ? null : arg.toLowerCase());
        _say(switch (level) {
          'careful' => t('Careful: it plans before it answers. Two passes, so '
              'about twice the credits.'),
          'deep' => t('Deep: it plans, answers, then checks its answer. Three '
              'passes, so about three times the credits.'),
          _ => t('Normal effort: one pass.'),
        });
        return true;
      case 'remember':
        if (arg.isNotEmpty) {
          final saved = await app.saveMemory(Memory(
            id: bytesToHex(randomBytes(8)),
            text: arg,
            scope: app.current?.workspaceId,
            source: 'you',
          ));
          if (saved != null) {
            _sayUndo(t('Remembered.'), () => app.deleteMemory(saved.id));
          }
        } else if (mounted) {
          await showMemorySheet(context);
        }
        return true;
      case 'memory':
        await showMemorySheet(context);
        return true;
      case 'forget':
        await app.clearMemories();
        _say(t('Forgotten.'));
        return true;
      case 'clear':
        await app.clearCurrent();
        return true;
      default:
        return false;
    }
  }

  Future<bool> _gitCommand(AppController app, String arg) async {
    if (RegExp(r'^(list|status)$', caseSensitive: false).hasMatch(arg)) {
      if (app.repos.isEmpty) {
        await app.note(t('No repositories connected yet.'));
        return true;
      }
      final scoped = app.current?.repoIds ?? const <String>[];
      await app.note(app.repos
          .map((r) =>
              '${scoped.contains(r.id) ? '[x]' : '[ ]'} ${r.repo}'
              '${r.branch.isEmpty ? '' : '@${r.branch}'}'
              '${r.allowWrites ? ' (writes)' : ''}')
          .join('\n'));
      return true;
    }
    final writes = RegExp(r'^writes\s+(on|off)$', caseSensitive: false).firstMatch(arg);
    if (writes != null) {
      final on = writes.group(1)!.toLowerCase() == 'on';
      for (final r in app.activeRepos) {
        r.allowWrites = on;
        await app.saveRepo(r, useHere: false);
      }
      await app.note(on ? t('Repository writes on.') : t('Repository writes off.'));
      return true;
    }
    if (RegExp(r'^(disconnect|none)$', caseSensitive: false).hasMatch(arg)) {
      await app.setReposHere(const []);
      await app.note(t('No repository is in scope for this chat.'));
      return true;
    }
    if (RegExp(r'^all$', caseSensitive: false).hasMatch(arg)) {
      await app.setReposHere(app.repos.map((r) => r.id).toList());
      await app.note(t('Every connected repository is in scope for this chat.'));
      return true;
    }
    if (arg.isNotEmpty) {
      final needle = arg.replaceFirst(RegExp(r'^use\s+'), '').toLowerCase();
      for (final r in app.repos) {
        if (r.repo.toLowerCase().contains(needle) ||
            r.label.toLowerCase().contains(needle)) {
          await app.toggleRepoHere(r.id);
          final on = (app.current?.repoIds ?? const []).contains(r.id);
          await app.note(on
              ? t('{repo} is now in scope for this chat.', {'repo': r.repo})
              : t('{repo} is no longer in scope for this chat.', {'repo': r.repo}));
          return true;
        }
      }
    }
    await showReposSheet(context);
    return true;
  }

  /// What one change added, when it added anything. A paste arrives as a
  /// single insert at one point, so the common prefix and suffix bracket it.
  static String? _insertedRun(String before, String after) {
    if (after.length <= before.length) return null;
    var head = 0;
    while (head < before.length && before[head] == after[head]) {
      head++;
    }
    var tail = 0;
    while (tail < before.length - head &&
        before[before.length - 1 - tail] == after[after.length - 1 - tail]) {
      tail++;
    }
    final run = after.substring(head, after.length - tail);
    return run.isEmpty ? null : run;
  }

  String _composerHint(Map<String, dynamic>? media) {
    if (media == null) return t('Message Nymbot, or ? for commands');
    return media['kind'] == 'video'
        ? t('Describe the video to make')
        : t('Describe the picture to make');
  }

  Future<void> _send([String? override]) async {
    final text = override ?? _input.text.trim();
    if (text.isEmpty) return;
    final app = AppScope.read(context);
    if (override == null) {
      _input.clear();
      setState(() => _suggestTerm = '');
      await app.store.setDraft(app.current!.id, '');
    }
    if (override == null && await _localCommand(text)) {
      _toBottom();
      return;
    }
    _toBottom();
    // Read for standing facts before the reply comes back, so what is
    // remembered is offered while the message is still on screen.
    final noticed = await app.noticeMemories(text);
    if (noticed.isNotEmpty && mounted) {
      _sayUndo(
        noticed.length == 1
            ? t('Remembered: {what}', {'what': noticed.first.text})
            : t('Remembered {n} things from that.', {'n': noticed.length}),
        () {
          for (final entry in noticed) {
            app.deleteMemory(entry.id);
          }
        },
      );
    }
    // A message typed while it was still writing is held, not sent, so nothing
    // below should read out a reply that has not happened yet.
    final went = await app.send(text);
    _toBottom();
    if (!mounted || !went) return;
    if (app.settings.hapticOnReply) unawaited(HapticFeedback.lightImpact());
    if (app.settings.autoSpeak && app.messages.isNotEmpty) {
      final last = app.messages.last;
      if (last.role == ChatRole.bot) {
        await _voice.speak(last.id, last.content, rate: app.settings.speechRate);
      }
    }
  }

  Future<void> _messageAction(MessageAction action, ChatMessage m) async {
    final app = AppScope.read(context);
    switch (action) {
      case MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: m.content));
        _say(t('Copied.'));
      case MessageAction.speak:
        await _voice.toggleSpeak(m.id, m.content, rate: app.settings.speechRate);
      case MessageAction.regenerate:
        await app.regenerate(m);
        _toBottom();
      case MessageAction.resend:
        await _send(m.content);
      case MessageAction.edit:
        await _edit(m);
      case MessageAction.quote:
        app.setQuote(MarkdownBody.plain(m.content));
      case MessageAction.fork:
        await app.forkAt(m);
        _say(t('Branched. The new chat carries what was said up to that point.'));
      case MessageAction.rateUp:
        await app.rate(m, 1);
      case MessageAction.rateDown:
        await app.rate(m, -1);
      case MessageAction.pin:
        await app.togglePinMessage(m);
        _say(m.pinned ? t('Removed from saved messages.') : t('Saved.'));
      case MessageAction.remember:
        // The words, not the markup: what is remembered has to read as a
        // sentence when it comes back in another chat.
        final words = MarkdownBody.plain(m.content).trim();
        if (words.isEmpty) {
          _say(t('There is nothing in that to remember.'));
        } else {
          final saved = await app.saveMemory(Memory(
            id: bytesToHex(randomBytes(8)),
            text: words.length > Memory.textCap
                ? words.substring(0, Memory.textCap)
                : words,
            scope: app.current?.workspaceId,
            source: 'you',
          ));
          if (saved != null) _sayUndo(t('Remembered.'), () => app.deleteMemory(saved.id));
        }
      case MessageAction.retry:
        final again = m.retry;
        await app.deleteMessage(m);
        if (again != null) await _send(again);
      case MessageAction.delete:
        await app.deleteMessage(m);
    }
  }

  /// Asking the question differently. By default that happens on a branch: the
  /// chat you had is worth keeping, and rewriting in place threw away
  /// everything said after the edited message with no way back.
  /// Putting a repo run back, once it is asked for out loud: it writes to
  /// someone's repository, so it is confirmed rather than done on a tap.
  Future<void> _undo(ChatMessage m) async {
    final app = AppScope.read(context);
    final mark = m.checkpoint;
    if (mark == null) return;
    final paths = (mark['paths'] as List?)?.length ?? 0;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Undo these changes')),
        content: Text(t(
            'Put {n} file(s) back to how they were before this reply, on '
            '{branch}? This commits them as they were — nothing is erased from '
            'the history.',
            {'n': paths, 'branch': mark['branch'] ?? ''})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('Undo them')),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      final data = await app.revertCheckpoint(m);
      final done = ((data['restored'] as List?)?.length ?? 0) +
          ((data['deleted'] as List?)?.length ?? 0);
      final failed = (data['failed'] as List?)?.length ?? 0;
      _say(failed > 0
          ? t('Put {done} back; {failed} could not be. Check the repository.',
              {'done': done, 'failed': failed})
          : t('Put back: {n} file(s) are as they were before that reply.',
              {'n': done}));
    } on ChatFailure catch (e) {
      _say(e.message);
    } catch (_) {
      _say(t('Could not put that back.'));
    }
  }

  Future<void> _edit(ChatMessage m) async {
    final app = AppScope.read(context);
    final controller = TextEditingController(text: m.content);
    var branch = true;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(t('Ask this differently')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 3,
                maxLines: 10,
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: branch,
                title: Text(t('Keep this chat and answer on a branch'),
                    style: const TextStyle(fontSize: 13)),
                onChanged: (v) => setLocal(() => branch = v ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(t('Send')),
            ),
          ],
        ),
      ),
    );
    if (value == null || value.trim().isEmpty) return;
    if (branch) {
      await app.branchBefore(m);
      _say(t('Branched. The chat you had is still in the list.'));
    } else {
      await app.truncateFrom(m);
    }
    await _send(value.trim());
  }

  Future<void> _attach() async {
    final app = AppScope.read(context);
    final picked = await Attachments.pick();
    for (final a in picked.files) {
      app.addAttachment(a);
    }
    if (picked.problems.isNotEmpty && mounted) {
      _say(t('Could not attach: {names}', {'names': picked.problems.join(', ')}));
    }
  }

  Future<void> _openSearch({String term = ''}) async {
    final app = AppScope.read(context);
    final jump = await showSearchSheet(context, term: term);
    if (jump == null) return;
    final conv = app.conversations.firstWhere(
      (c) => c.id == jump.conversationId,
      orElse: () => app.current!,
    );
    await app.open(conv);
    if (jump.messageId != null) _scrollToMessage(jump.messageId!);
  }

  void _scrollToMessage(String id) {
    setState(() => _highlighted = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _keys[id];
      final ctx = key?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 250), alignment: 0.4);
      }
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlighted = null);
    });
  }

  Future<void> _share(AppController app) async {
    final conv = app.current!;
    final body = Transcript.markdown(conv, app.messages, repos: app.activeRepos);
    await Share.share(
      body,
      subject: conv.title.isEmpty ? 'Nymbot' : conv.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final conv = app.current;

    final queued = app.pendingInput;
    if (queued != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final text = app.takeInput();
        if (text == null || !mounted) return;
        _input.text = text;
        _input.selection = TextSelection.collapsed(offset: text.length);
        setState(() => _suggestTerm = '');
      });
    }

    return Scaffold(
      drawer: const _ChatDrawer(),
      appBar: AppBar(
        title: GestureDetector(
          onTap: _rename,
          child: Row(
            children: [
              Flexible(
                child: Text(
                  conv == null || conv.title.isEmpty ? t('New chat') : conv.title,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (conv?.pinned ?? false)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.star, size: 14, color: NymbotColors.lightning),
                ),
            ],
          ),
        ),
        actions: [
          if (conv?.anon ?? false)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                label: const Text('anon', style: TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: Theme.of(context).colorScheme.secondary),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.search, size: 20),
            tooltip: t('Search everything'),
            onPressed: () => _openSearch(),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: t('Chat options'),
            onPressed: () => _menu(app),
          ),
        ],
      ),
      body: Column(
        children: [
          const NymbotToolbar(),
          const ContextBar(),
          if (_findTerm != null) _findBar(context, app),
          Expanded(child: _messages(context, app)),
          _composer(context, app),
        ],
      ),
      floatingActionButton: _atBottom || app.messages.isEmpty
          ? null
          : FloatingActionButton.small(
              tooltip: t('Jump to the newest message'),
              onPressed: () => _toBottom(),
              child: const Icon(Icons.arrow_downward, size: 18),
            ),
    );
  }

  Widget _findBar(BuildContext context, AppController app) {
    final hits = app.messages
        .where((m) => m.content.toLowerCase().contains(_findTerm!.toLowerCase()))
        .toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                hintText: t('Find in this chat'),
              ),
              onChanged: (v) => setState(() => _findTerm = v),
              onSubmitted: (_) {
                if (hits.isNotEmpty) _scrollToMessage(hits.first.id);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              _findTerm!.trim().isEmpty
                  ? ''
                  : t('{n} found', {'n': hits.length}),
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _findTerm = null),
          ),
        ],
      ),
    );
  }

  Widget _messages(BuildContext context, AppController app) {
    if (app.messages.isEmpty && !app.sending) return _empty(context, app);
    // An anonymous chat deliberately shows the throwaway key's own generated
    // nym, never the published profile: the avatar would give away exactly
    // what the mode exists to hide.
    final anonymous = (app.current?.anon ?? false) && app.anon.ready;
    final selfPubkey =
        anonymous ? (app.anon.pubkey ?? app.identity.pubkey) : app.identity.pubkey;
    final me = anonymous ? null : app.profiles.of(selfPubkey);

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: app.messages.length + (app.sending ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= app.messages.length) {
          return TypingIndicator(
            label: app.status ??
                (app.activeRepos.isNotEmpty && app.activeModel != null
                    ? t('Nymbot is reading your repositories')
                    : t('Nymbot is thinking')),
            showAvatar: app.settings.avatars,
            steps: _progressLines(app.progressSteps),
          );
        }
        final m = app.messages[i];
        final previous = i == 0 ? null : app.messages[i - 1];
        final grouped = previous != null &&
            previous.role == m.role &&
            (m.role == ChatRole.self || m.role == ChatRole.bot) &&
            m.at.difference(previous.at).inMinutes.abs() < 10;
        final key = _keys.putIfAbsent(m.id, () => GlobalKey());
        return KeyedSubtree(
          key: key,
          child: MessageBubble(
            message: m,
            artifacts: app.artifactsOf(m.id),
            actionsOpen: _openActions == m.id,
            onToggleActions: () => setState(
                () => _openActions = _openActions == m.id ? null : m.id),
            onOpenArtifact: (a) => showArtifact(context, a),
            onUndoCheckpoint: m.checkpoint == null ? null : () => _undo(m),
            selfPubkey: selfPubkey,
            selfName: me?.name,
            selfPicture: me?.picture ?? '',
            settings: app.settings,
            grouped: grouped,
            speaking: _voice.speakingId == m.id,
            highlighted: _highlighted == m.id,
            onAction: _messageAction,
          ),
        );
      },
    );
  }

  Widget _empty(BuildContext context, AppController app) {
    final bot = app.activeBot;
    final starters = bot != null && bot.starters.isNotEmpty
        ? [for (final s in bot.starters) (bot.name, s)]
        : <(String, String)>[
      (
        t('Explain something'),
        t('Explain ML-KEM in three sentences, then tell me what it does not protect.')
      ),
      (
        t('Work in a repo'),
        t('Read the repositories I connected and tell me where the retry logic gives up too early.')
      ),
      (
        t('Write code'),
        t('Write a small, dependency-free function that debounces an async call and cancels the pending one.')
      ),
      (
        t('Compare options'),
        t('Give me three genuinely different ways to store 200 MB of user data offline in a browser, with what sinks each.')
      ),
      (t('Generate a picture'), '?image a lighthouse at dusk, long exposure, muted palette'),
          ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 20),
          const NymAvatar(seed: 'nymbot', size: 52, bot: true),
          const SizedBox(height: 12),
          Text(bot?.name ?? t('Ask Nymbot anything'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            bot != null
                ? (bot.tagline.isNotEmpty
                    ? bot.tagline
                    : t('This chat answers the way that bot was written to.'))
                : t('End-to-end encrypted, paid a reply at a time. Type ? for '
                    'commands, or start with one of these.'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13),
          ),
          const SizedBox(height: 16),
          for (final s in starters)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                title: Text(s.$1, style: const TextStyle(fontSize: 14)),
                subtitle: Text(s.$2, style: const TextStyle(fontSize: 12)),
                onTap: () {
                  _input.text = s.$2;
                  setState(() {});
                },
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final tip in const ['?help', '?balance', '?model', '?git', '?prompt', '?anon'])
                ActionChip(
                  label: Text(tip, style: const TextStyle(fontSize: 12)),
                  onPressed: () {
                    _input.text = tip;
                    setState(() => _suggestTerm = tip);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context, AppController app) {
    final estimate = app.estimate(_input.text);
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_suggestTerm.startsWith('?') && !_suggestTerm.contains(' '))
              CommandSuggestions(
                term: _suggestTerm,
                onPick: (c) {
                  _input.text = '?${c.name}${c.args.isEmpty ? '' : ' '}';
                  _input.selection =
                      TextSelection.collapsed(offset: _input.text.length);
                  setState(() => _suggestTerm = c.args.isEmpty ? '' : '?${c.name} ');
                  if (c.args.isEmpty) _send();
                },
              ),
            if (app.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // A picture is on its way to a media host the moment it is
                    // attached, because the message carries the link rather than
                    for (final a in app.attachments)
                      InputChip(
                        avatar: a.uploading
                            ? const SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(
                                a.uploadError != null
                                    ? Icons.error_outline
                                    : (a.kind == AttachmentKind.image
                                        ? Icons.image_outlined
                                        : Icons.description_outlined),
                                size: 15,
                                color: a.uploadError != null
                                    ? Theme.of(context).colorScheme.error
                                    : null,
                              ),
                        tooltip: a.uploadError,
                        label: Text(
                          a.uploading
                              ? '${a.name} · ${t('uploading…')}'
                              : (a.uploadError != null
                                  ? '${a.name} · ${t('not uploaded')}'
                                  : '${a.name} · ${a.measure}'),
                          style: TextStyle(
                            fontSize: 11,
                            color: a.uploadError != null
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                        ),
                        onDeleted: () => app.removeAttachment(a.id),
                      ),
                  ],
                ),
              ),
            // What you typed while it was still writing. Shown so the queue is
            // never a surprise, and each one can be taken back out while it
            // waits.
            for (var i = 0; i < app.queued.length; i++)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.fromLTRB(8, 3, 2, 3),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: Theme.of(context).dividerColor,
                      style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Text('#${i + 1}',
                        style: TextStyle(
                            fontSize: 10, color: Theme.of(context).hintColor)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        app.queued[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: Theme.of(context).hintColor),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 15),
                      tooltip: t('Do not send this'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => app.unqueue(i),
                    ),
                  ],
                ),
              ),
            if (app.quote != null)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                        color: Theme.of(context).colorScheme.secondary, width: 2),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        app.quote!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: Theme.of(context).hintColor),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 15),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => app.setQuote(null),
                    ),
                  ],
                ),
              ),
            if (app.status != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(app.status!,
                    style:
                        TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file, size: 20),
                  tooltip: t('Attach a file'),
                  onPressed: _attach,
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 6,
                    textInputAction: app.settings.sendOnEnter
                        ? TextInputAction.send
                        : TextInputAction.newline,
                    onChanged: (v) {
                      // A wall of pasted text is a document, not a sentence:
                      // it goes in as an attachment so the question you are
                      // asking about it stays readable. Only a paste can add
                      // this much in one change; typing cannot.
                      final run = _insertedRun(_lastInput, v);
                      if (run != null && Attachments.pasteIsLong(run)) {
                        final rest = v.replaceFirst(run, '');
                        app.addAttachment(Attachments.fromText(run,
                            id: bytesToHex(randomBytes(8))));
                        _input.text = rest;
                        _input.selection =
                            TextSelection.collapsed(offset: rest.length);
                        _lastInput = rest;
                        final conv = app.current;
                        if (conv != null) app.store.setDraft(conv.id, rest);
                        return;
                      }
                      _lastInput = v;
                      final conv = app.current;
                      if (conv != null) app.store.setDraft(conv.id, v);
                      final next = v.startsWith('?') ? v : '';
                      if (next != _suggestTerm) setState(() => _suggestTerm = next);
                    },
                    onSubmitted: app.settings.sendOnEnter ? (_) => _send() : null,
                    decoration: InputDecoration(
                      hintText: _composerHint(app.activeMediaModel),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (app.sending)
                  IconButton.filledTonal(
                    onPressed: app.stop,
                    tooltip: t('Stop'),
                    icon: const Icon(Icons.stop, size: 20),
                  )
                else
                  IconButton.filledTonal(
                    onPressed: () => _send(),
                    tooltip: t('Send'),
                    icon: const Icon(Icons.send, size: 20),
                  ),
              ],
            ),
            if (app.settings.showCostEstimate && _input.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  estimate.tier == 'pro'
                      ? (estimate.low == estimate.high
                          ? t('About {n} Pro credits', {'n': estimate.low})
                          : t('About {low}–{high} Pro credits',
                              {'low': estimate.low, 'high': estimate.high}))
                      : (estimate.low == 1
                          ? t('1 standard credit')
                          : t('{n} standard credits', {'n': estimate.low})),
                  style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename() async {
    final app = AppScope.read(context);
    final conv = app.current;
    if (conv == null) return;
    await renameChatDialog(context, app, conv);
  }

  Future<void> _menu(AppController app, {Conversation? target}) async {
    final conv = target ?? app.current;
    if (conv == null) return;
    final choice = await showChatMenu(context, conv);
    if (choice == null || !mounted) return;
    if (choice == 'find') {
      if (conv.id != app.current?.id) await app.open(conv);
      if (mounted) setState(() => _findTerm = '');
      return;
    }
    await runChatMenuChoice(context, app, conv, choice);
  }
}

/// One item from the chat menu, run against [conv] — which need not be the chat
/// on screen, since the sidebar opens this menu on a row. The items that open
/// an editor bound to the chat in view select it first; everything else acts
/// where it stands. 'find' belongs to the chat screen and is handled there.
Future<void> runChatMenuChoice(BuildContext context, AppController app,
    Conversation conv, String choice) async {
  final elsewhere = conv.id != app.current?.id;
  final messenger = ScaffoldMessenger.of(context);
  // Selecting the chat first is an await, so the context that opens the sheet
  // afterwards has to be checked rather than assumed.
  Future<bool> select() async {
    if (elsewhere) await app.open(conv);
    return context.mounted;
  }

  switch (choice) {
    case 'rename':
      await renameChatDialog(context, app, conv);
    case 'pin':
      await app.togglePin(target: conv);
    case 'archive':
      await app.toggleArchive(target: conv);
    case 'duplicate':
      await app.duplicateCurrent(target: conv);
    case 'system':
      if (await select() && context.mounted) await showSystemPromptSheet(context);
    case 'tags':
      if (await select() && context.mounted) await showTagsSheet(context);
    case 'stats':
      if (await select() && context.mounted) await showStatsSheet(context);
    case 'share':
      await Share.share(
        Transcript.markdown(conv,
            elsewhere ? app.store.messages(conv.id) : app.messages,
            repos: app.activeRepos),
        subject: conv.title.isEmpty ? 'Nymbot' : conv.title,
      );
    case 'copy':
      await Clipboard.setData(ClipboardData(text: Transcript.markdown(
          conv,
          elsewhere ? app.store.messages(conv.id) : app.messages,
          repos: app.activeRepos)));
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
            content: Text(t('Copied.')),
            duration: const Duration(seconds: 3)));
    case 'clear':
      await app.clearCurrent(target: conv);
    case 'delete':
      await confirmDeleteChat(context, app, conv);
  }
}

Future<void> renameChatDialog(
    BuildContext context, AppController app, Conversation conv) async {
  final controller = TextEditingController(text: conv.title);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t('Name this chat')),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(t('Cancel'))),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(t('Save')),
        ),
      ],
    ),
  );
  if (value != null) await app.renameCurrent(value, target: conv);
}

Future<void> confirmDeleteChat(
    BuildContext context, AppController app, Conversation conv) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t('Delete this chat?')),
      content: Text(
        t('Its messages are encrypted to your key and cannot be recovered.'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: NymbotColors.danger),
          onPressed: () => Navigator.pop(context, true),
          child: Text(t('Delete')),
        ),
      ],
    ),
  );
  if (ok == true) await app.deleteCurrent(target: conv);
}

class _ChatDrawer extends StatefulWidget {
  const _ChatDrawer();

  @override
  State<_ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<_ChatDrawer> {
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final list = app.visibleConversations;
    final folders = {for (final f in app.folders) f.id: f.name};

    String groupOf(Conversation c) {
      if (c.pinned) return t('Pinned');
      switch (app.settings.grouping) {
        case SidebarGrouping.flat:
          return '';
        case SidebarGrouping.folder:
          return folders[c.folderId] ?? t('No folder');
        case SidebarGrouping.date:
          final age = DateTime.now().difference(c.updatedAt);
          if (age.inDays < 1) return t('Today');
          if (age.inDays < 2) return t('Yesterday');
          if (age.inDays < 7) return t('This week');
          if (age.inDays < 30) return t('This month');
          return t('Older');
      }
    }

    final rows = <Widget>[];
    String? group;
    for (final conv in list) {
      final label = groupOf(conv);
      if (label.isNotEmpty && label != group) {
        group = label;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.1,
              color: Theme.of(context).hintColor,
            ),
          ),
        ));
      }
      final repos = app.repos.where((r) => conv.repoIds.contains(r.id)).toList();
      final bits = <String>[];
      if (repos.isNotEmpty) bits.add(repos.map((r) => r.display).join(', '));
      if (conv.tags.isNotEmpty) bits.add(conv.tags.map((x) => '#$x').join(' '));
      rows.add(ListTile(
        dense: true,
        selected: conv.id == app.current?.id,
        leading: conv.pinned
            ? const Icon(Icons.star, size: 15, color: NymbotColors.lightning)
            : null,
        horizontalTitleGap: conv.pinned ? null : 0,
        title: Text(
          conv.title.isEmpty ? t('New chat') : conv.title,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: bits.isEmpty
            ? null
            : Text(bits.join(' · '),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11)),
        // The same menu the chat header carries, on the row, so renaming or
        // deleting a chat does not mean opening it first.
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (conv.anon)
              const Text('anon', style: TextStyle(fontSize: 11)),
            IconButton(
              icon: const Icon(Icons.more_vert, size: 18),
              tooltip: t('Chat options'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () async {
                final choice = await showChatMenu(context, conv);
                if (choice == null || !context.mounted) return;
                await runChatMenuChoice(context, app, conv, choice);
              },
            ),
          ],
        ),
        onTap: () async {
          await app.open(conv);
          if (context.mounted) Navigator.pop(context);
        },
      ));
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const NymbotMark(size: 26),
                  const SizedBox(width: 6),
                  // Optical, not geometric: the drawn body sits a hair below
                  // its box because of the antennae, so the word is nudged to
                  // match its middle.
                  Transform.translate(
                    offset: const Offset(0, 1.5),
                    child: Text(
                      'Nymbot',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Icons.add),
                tooltip: t('New chat'),
                onPressed: () async {
                  await app.newConversation();
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                decoration: InputDecoration(
                    isDense: true, hintText: t('Search chats')),
                onChanged: app.setSearch,
              ),
            ),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                children: [
                  for (final filter in <(String, String)>[
                    ('all', t('All')),
                    ('pinned', t('Pinned')),
                    ('repos', t('Repos')),
                    ('anon', t('Anon')),
                    ('archived', t('Archive')),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 5),
                      child: ChoiceChip(
                        label: Text(filter.$2, style: const TextStyle(fontSize: 11)),
                        selected: app.convFilter == filter.$1,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => app.setFilter(filter.$1),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(t('Nothing here.'),
                          style: TextStyle(color: Theme.of(context).hintColor)),
                    )
                  : ListView(children: rows),
            ),
            const Divider(height: 1),
            for (final entry in <(IconData, String, Future<void> Function())>[
              (Icons.account_tree_outlined, t('Repositories'),
                  () => showReposSheet(context)),
              (Icons.chat_bubble_outline, t('Prompt library'), () async {
                final picked = await showPromptsSheet(context);
                if (picked != null) app.queueInput(picked);
                if (picked != null && context.mounted) Navigator.pop(context);
              }),
              (Icons.person_outline, t('Personas'), () => showPersonasSheet(context)),
              (Icons.star_border, t('Saved messages'), () async {
                await showSavedMessagesSheet(context);
              }),
              (Icons.psychology_outlined, t('Memory'),
                  () => showMemorySheet(context)),
              (Icons.tune, t('Settings'), () => showAppearanceSheet(context)),
              (Icons.help_outline, t('Help'), () => showHelpSheet(context)),
              (Icons.keyboard_outlined, t('Getting around'),
                  () => showShortcutsSheet(context)),
            ])
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: Icon(entry.$1, size: 18),
                title: Text(entry.$2, style: const TextStyle(fontSize: 13)),
                onTap: entry.$3,
              ),
            const Divider(height: 1),
            ListTile(
              leading: Stack(
                clipBehavior: Clip.none,
                children: [
                  NymAvatar(
                    seed: app.identity.pubkey,
                    size: 28,
                    picture: app.profiles.of(app.identity.pubkey).picture,
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Icon(
                      Icons.circle,
                      size: 9,
                      color: app.relaysUp > 0
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).disabledColor,
                    ),
                  ),
                ],
              ),
              title: Builder(builder: (context) {
                if (app.identity.pubkey.isEmpty) return const Text('');
                final who = app.profiles.of(app.identity.pubkey);
                return Row(
                  children: [
                    Flexible(
                      // A nym's suffix is what distinguishes it, not what you
                      // read first, so it is dimmed here as it is everywhere
                      // else a nym is shown.
                      child: RichText(
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: TextStyle(
                            fontFamily: who.hasProfile ? null : 'monospace',
                            fontSize: 13,
                            color: Theme.of(context).textTheme.bodyMedium?.color,
                          ),
                          children: who.hasProfile
                              ? [TextSpan(text: who.name)]
                              : [
                                  TextSpan(
                                      text: NymIdentity.name(
                                          app.identity.pubkey)),
                                  TextSpan(
                                    text:
                                        '#${NymIdentity.suffix(app.identity.pubkey)}',
                                    style: TextStyle(
                                      color: Theme.of(context).hintColor,
                                    ),
                                  ),
                                ],
                        ),
                      ),
                    ),
                    if (who.nip05.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(Icons.check_circle_outline,
                            size: 12, color: Theme.of(context).colorScheme.secondary),
                      ),
                  ],
                );
              }),
              subtitle: Text(
                app.standardBalance == null
                    ? t('{n} relays', {'n': app.relaysUp})
                    : t('{standard} standard · {pro} Pro', {
                        'standard': app.standardBalance,
                        'pro': app.proBalance,
                      }),
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => showIdentitySheet(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the feed under the spinner reads as: the steps that still say something
/// new, and never the same line twice in a row.
List<String> _progressLines(List<TurnStep> steps) {
  final out = <String>[];
  for (final s in trimProgress(steps)) {
    final line = progressLine(s);
    if (line.isEmpty || (out.isNotEmpty && out.last == line)) continue;
    out.add(line);
  }
  return out;
}
