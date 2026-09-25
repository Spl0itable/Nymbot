import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart';
import '../core/crypto/keys.dart';
import '../core/theme/theme.dart';
import '../models/conversation.dart';
import '../models/memory.dart';
import '../models/workspace.dart';
import '../services/attachments.dart';
import '../services/backup.dart';
import '../services/share_file.dart';
import '../services/chat_engine.dart';
import '../services/dictation.dart';
import '../services/gifts.dart';
import '../services/incoming.dart';
import '../services/mentions.dart';
import '../services/picture_edit.dart';
import '../services/spend_caps.dart';
import '../services/transcript.dart';
import '../services/voice.dart';
import '../state/app_controller.dart';
import 'artifact_screen.dart';
import 'tasks_pane.dart';
import 'caps_sheet.dart';
import 'code_frame.dart';
import 'dictation_wave.dart';
import 'doc_tray.dart';
import 'compose_controller.dart';
import 'sheets/bots_sheet.dart';
import 'sheets/compare_sheet.dart';
import 'sheets/connectors_sheet.dart';
import 'progress_lines.dart';
import 'research_view.dart';
import 'team_view.dart';
import 'share_chat_sheet.dart';
import 'shared_chat_screen.dart';
import 'sticky_avatar.dart';
import '../services/research.dart';
import 'run_output.dart';
import 'sheets/help_sheet.dart';
import 'sheets/schedules_sheet.dart';
import 'sheets/workspaces_sheet.dart';
import 'sheets/sheet.dart';
import 'command_palette.dart';
import 'command_sheet.dart';
import 'markdown_body.dart';
import 'motion.dart';
import 'mention_suggestions.dart';
import 'message_bubble.dart';
import 'notice_banner.dart';
import 'nym_avatar.dart';
import 'nym_icons.dart';
import 'sheets/anon_sheet.dart';
import 'sheets/artifact_library_sheet.dart';
import 'sheets/appearance_sheet.dart';
import 'sheets/credits_sheet.dart';
import 'sheets/gift_sheet.dart';
import 'sheets/identity_sheet.dart';
import 'sheets/library_sheets.dart';
import 'sheets/memory_sheet.dart';
import 'sheets/models_sheet.dart';
import 'sheets/personas_sheet.dart';
import 'sheets/prompts_sheet.dart';
import 'sheets/repos_sheet.dart';
import 'toolbar.dart';
import 'i18n/i18n.dart';
import 'nym_glyph.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // Styles the markdown you write while you write it, so what is in the
  // field looks like what will be sent.
  final _input = MarkdownEditingController();
  late final _inputFocus = FocusNode(onKeyEvent: _composerKey);
  final _inputScroll = ScrollController();
  final _queueEditor = TextEditingController();
  final _scroll = ScrollController();
  final _voice = Voice();
  final _keys = <String, GlobalKey>{};
  final _draftKey = GlobalKey();
  ChatTurn? _draftTurn;
  bool _followDraft = false;

  String _suggestTerm = '';
  bool _hasText = false;

  /// What the composer held before the last change, so a paste can be told
  /// apart from typing by how much one change added.
  String _lastInput = '';
  String? _highlighted;

  /// Which message has its action row open. One at a time, so a thread does
  /// not fill up with them.
  String? _openActions;
  bool _atBottom = true;
  bool _makerLookup = false;
  String? _findTerm;
  int _findAt = 0;
  bool _followingUp = false;
  String? _shownConv;
  int _settling = 0;
  String? _revealId;
  int _revealAt = 0;
  Timer? _revealTimer;
  Completer<void>? _revealDone;
  String? _dictation;
  DateTime? _dictateFrom;
  Timer? _dictateTick;
  DictationMeter? _meter;
  Timer? _levelTick;

  AppController? _app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final near = _scroll.position.maxScrollExtent - _scroll.offset < 140;
      if (near != _atBottom) setState(() => _atBottom = near);
    });
    _voice.addListener(() => setState(() {}));
    RunOutputs.toComposer.addListener(_takeRunOutput);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = AppScope.read(context);
      final conv = app.current;
      if (conv != null) _input.setMarkdown(app.store.draft(conv.id));
      app.onCapPrompt = _capPrompt;
      unawaited(Incoming.listen(_incoming));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_app?.resumed());
  }

  Future<void> _incoming(IncomingItem item) async {
    if (!mounted) return;
    final app = AppScope.read(context);
    final url = item.url;
    if (url != null) {
      switch (Incoming.kindOf(url)) {
        case 'bot':
          await showAddBot(context, prefill: url);
        case 'chat':
          await showSharedChat(context, url);
        case 'gift':
          await showRedeemGiftSheet(context, prefill: url);
        default:
          _say(t('That link is not one Nymbot can open.'));
      }
      return;
    }
    if (app.current == null || app.messages.isNotEmpty) {
      await app.newConversation();
    }
    final text = item.text?.trim() ?? '';
    if (text.isNotEmpty) {
      final draft = _input.markdown.trim();
      _input.setMarkdown(draft.isEmpty ? text : '$draft\n\n$text');
      _edited();
    }
    if (item.files.isNotEmpty) {
      final picked = await Attachments.intake(item.files);
      for (final a in picked.files) {
        app.addAttachment(a);
      }
      if (picked.problems.isNotEmpty) {
        _say(t('Could not attach: {names}',
            {'names': picked.problems.join('; ')}));
      }
    }
    if (mounted) _inputFocus.requestFocus();
  }

  Future<void> _toggleDictation() async {
    if (_dictation == 'recording') return _finishDictation();
    if (_dictation != null) return;
    setState(() => _dictation = 'starting');
    try {
      await Dictation.start();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _dictation = null);
      _say(e.code == 'denied'
          ? t('The microphone is blocked. Allow it for Nymbot in your device '
              'settings, then try again.')
          : t('The microphone could not be started.'));
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _dictation = null);
      _say(t('The microphone could not be started.'));
      return;
    }
    if (!mounted) return;
    if (_dictation != 'starting') {
      await Dictation.cancel();
      return;
    }
    _dictateFrom = DateTime.now();
    _dictateTick?.cancel();
    _dictateTick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (DateTime.now().difference(_dictateFrom!) >= Dictation.limit) {
        _say(t('That is the two-minute limit for one clip, so it stopped there.'));
        unawaited(_finishDictation());
        return;
      }
      setState(() {});
    });
    setState(() => _dictation = 'recording');
    unawaited(SemanticsService.announce(t('Recording'), Directionality.of(context)));
    _startLevels();
  }

  void _startLevels() {
    _levelTick?.cancel();
    final meter = DictationMeter();
    _meter = meter;
    var busy = false;
    var misses = 0;
    _levelTick = Timer.periodic(DictationMeter.interval, (timer) async {
      if (busy) return;
      busy = true;
      final level = await Dictation.level();
      busy = false;
      if (!mounted || _meter != meter || _dictation != 'recording') return;
      final wasQuiet = meter.noSound;
      meter.add(level);
      if (level == null) {
        misses++;
        if (misses >= 10 && !meter.metering) timer.cancel();
        return;
      }
      misses = 0;
      if (meter.noSound && !wasQuiet) {
        unawaited(SemanticsService.announce(
            t('No sound is coming in. Check your microphone.'),
            Directionality.of(context)));
      }
      setState(() {});
    });
  }

  void _stopLevels() {
    _levelTick?.cancel();
    _levelTick = null;
  }

  Future<void> _cancelDictation() async {
    _dictateTick?.cancel();
    _stopLevels();
    _meter = null;
    final was = _dictation;
    setState(() => _dictation = null);
    await Dictation.cancel();
    if (was != null) _say(t('Dictation canceled.'));
  }

  Future<void> _finishDictation() async {
    if (_dictation != 'recording') return;
    _dictateTick?.cancel();
    _stopLevels();
    final silent = _meter?.silentClip ?? false;
    _meter = null;
    setState(() => _dictation = 'sending');
    void settle(String? message) {
      if (!mounted) return;
      setState(() => _dictation = null);
      if (message != null) _say(message);
    }

    Uint8List? audio;
    try {
      audio = await Dictation.stop();
    } catch (_) {
      audio = null;
    }
    if (!mounted || _dictation != 'sending') return;
    if (silent) {
      settle(t('No sound was picked up, so nothing was sent. Check your '
          'microphone and try again.'));
      return;
    }
    if (audio == null || audio.isEmpty) {
      settle(t('Nothing was recorded.'));
      return;
    }
    if (audio.length > Dictation.maxBytes) {
      settle(t('That clip is too long. Dictation takes up to two minutes at a time.'));
      return;
    }
    final app = AppScope.read(context);
    final heard = await app.transcribe(audio);
    if (!mounted || _dictation != 'sending') return;
    final error = heard.error;
    if (error != null) {
      settle(error);
      return;
    }
    final said = heard.text ?? '';
    if (said.isEmpty) {
      settle(t('Nothing was heard. Try again a little closer to the microphone.'));
      return;
    }
    settle(null);
    final draft = _input.markdown.trimRight();
    _input.setMarkdown(draft.isEmpty ? said : '$draft $said');
    _edited();
    _inputFocus.requestFocus();
  }

  Future<void> _saveQueued(AppController app) async {
    if (_queueEditor.text.trim().isEmpty) {
      final drop = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('Remove this message from the queue?')),
          content: Text(t('It is empty now, so there is nothing left to send.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t('Keep editing'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t('Remove it'))),
          ],
        ),
      );
      if (drop != true) return;
    }
    await app.saveQueued(_queueEditor.text);
  }

  Widget _queueEditorRow(BuildContext context, AppController app) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('queue-editor'),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.secondary),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('Editing queued message'),
              style: TextStyle(fontSize: 11, color: theme.hintColor)),
          TextField(
            controller: _queueEditor,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            style: const TextStyle(fontSize: 13),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => app.cancelQueuedEdit(),
                child: Text(t('Cancel')),
              ),
              FilledButton(
                onPressed: () => _saveQueued(app),
                child: Text(t('Save')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dictationStrip(BuildContext context) {
    final theme = Theme.of(context);
    final sending = _dictation == 'sending';
    final spent = _dictateFrom == null
        ? Duration.zero
        : DateTime.now().difference(_dictateFrom!);
    String clock(Duration d) {
      final seconds = d.isNegative ? 0 : d.inSeconds;
      return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    }

    final left = Dictation.limit - spent + const Duration(milliseconds: 999);
    final meter = sending ? null : _meter;
    final quiet = meter != null && meter.noSound;
    return Padding(
      key: const ValueKey('dictation-strip'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              NymGlyph('mic', size: 16, color: NymbotColors.danger),
              const SizedBox(width: 6),
              Expanded(
                child: Semantics(
                  liveRegion: sending,
                  child: Text(
                    sending
                        ? t('Transcribing…')
                        : t('Listening… {time}', {'time': clock(spent)}),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              if (!sending)
                Text(
                  t('{time} left', {'time': clock(left)}),
                  key: const ValueKey('dictation-left'),
                  style: TextStyle(fontSize: 12, color: theme.hintColor),
                ),
            ],
          ),
          if (meter != null && meter.metering)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DictationWave(
                key: const ValueKey('dictation-wave'),
                levels: meter.levels,
                quiet: quiet,
              ),
            ),
          if (quiet)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                t('No sound is coming in. Check your microphone.'),
                key: const ValueKey('dictation-hint'),
                style: TextStyle(fontSize: 12, color: NymbotColors.danger),
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(onPressed: _cancelDictation, child: Text(t('Cancel'))),
              if (!sending)
                FilledButton(
                  onPressed: _finishDictation,
                  child: Text(t('Stop and transcribe')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _takeRunOutput() {
    final text = RunOutputs.toComposer.value;
    if (text == null) return;
    RunOutputs.toComposer.value = null;
    final draft = _input.markdown.trim();
    _input.setMarkdown(draft.isEmpty ? text : '$draft\n\n$text');
    _inputFocus.requestFocus();
  }

  @override
  void dispose() {
    RunOutputs.toComposer.removeListener(_takeRunOutput);
    Incoming.stop();
    WidgetsBinding.instance.removeObserver(this);
    final app = _app;
    final conv = app?.current;
    if (app != null && conv != null) {
      unawaited(app.store.setDraft(conv.id, _input.markdown));
    }
    _stopReveal();
    _dictateTick?.cancel();
    _stopLevels();
    if (_dictation != null) unawaited(Dictation.cancel());
    _input.dispose();
    _queueEditor.dispose();
    _inputFocus.dispose();
    _inputScroll.dispose();
    _scroll.dispose();
    _voice.dispose();
    super.dispose();
  }

  void _toBottom({bool animate = true}) {
    _settling++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (animate && !reducedMotion(context)) {
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

  void _settleBottom(int token, int tries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _settling || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if ((_scroll.offset - end).abs() > 0.5) _scroll.jumpTo(end);
      if (tries > 0) _settleBottom(token, tries - 1);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _openedChat() {
    _openActions = null;
    _stopReveal();
    _settleBottom(++_settling, 8);
  }

  void _stopReveal() {
    _revealTimer?.cancel();
    _revealTimer = null;
    _revealId = null;
    final done = _revealDone;
    _revealDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> _typeOut(ChatMessage reply) {
    _stopReveal();
    final done = _revealDone = Completer<void>();
    final length = reply.content.length;
    final step = math.max(2, (length / 90).round());
    setState(() {
      _revealId = reply.id;
      _revealAt = 0;
    });
    _revealTimer = Timer.periodic(const Duration(milliseconds: 12), (_) {
      if (!mounted || _revealId != reply.id) {
        _stopReveal();
        return;
      }
      final next = _revealAt + step;
      if (next >= length) {
        setState(_stopReveal);
        return;
      }
      setState(() => _revealAt = next);
    });
    return done.future;
  }

  Future<void> _landed(AppController app, String? asked) async {
    final last = app.current?.id == asked && app.messages.isNotEmpty
        ? app.messages.last
        : null;
    final reply = last != null && last.role == ChatRole.bot ? last : null;
    if (reply != null &&
        app.settings.typewriter &&
        !app.streamedReplies.contains(reply.id) &&
        reply.content.length < 12000) {
      await _typeOut(reply);
    }
    if (!mounted) return;
    announceReply(app.settings);
    if (app.settings.autoSpeak && reply != null && app.current?.id == asked) {
      await _voice.speak(reply.id, reply.content,
          rate: app.settings.speechRate,
          voice: app.settings.voiceUri,
          language: Voice.languageFor(reply.content, I18n.lang));
    }
  }

  void _toReply() {
    if (!mounted) return;
    final messages = AppScope.read(context).messages;
    if (messages.isEmpty || messages.last.role != ChatRole.bot) {
      _toBottom();
      return;
    }
    final id = messages.last.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _alignTop(id, 4));
  }

  double? _topOf(GlobalKey? key) {
    final box = key?.currentContext?.findRenderObject();
    final viewport = box == null ? null : RenderAbstractViewport.maybeOf(box);
    if (box == null || viewport == null) return null;
    final position = _scroll.position;
    return (viewport.getOffsetToReveal(box, 0).offset - 8)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  void _alignTop(String id, int tries) {
    if (!mounted || !_scroll.hasClients) return;
    final top = _topOf(_keys[id]);
    if (top == null) {
      if (tries <= 0) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _alignTop(id, tries - 1));
      return;
    }
    if (reducedMotion(context)) {
      _scroll.jumpTo(top);
      return;
    }
    _scroll.animateTo(
      top,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _trackDraft(AppController app) {
    final turn = app.turnOf(app.current);
    final shown = turn != null &&
        turn.team == null &&
        turn.research == null &&
        (turn.draft?.trim() ?? '').isNotEmpty;
    if (!shown) return;
    if (_draftTurn != turn) {
      _draftTurn = turn;
      _followDraft = _atBottom;
    }
    if (_followDraft) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pinDraft());
    }
  }

  void _pinDraft() {
    if (!mounted || !_followDraft || !_scroll.hasClients) return;
    final top = _topOf(_draftKey);
    if (top == null || (top - _scroll.offset).abs() < 0.5) return;
    _scroll.jumpTo(top);
  }

  bool _threadScrolled(ScrollNotification n) {
    if (n.depth != 0) return false;
    final dragged = (n is ScrollStartNotification && n.dragDetails != null) ||
        (n is ScrollUpdateNotification && n.dragDetails != null) ||
        (n is OverscrollNotification && n.dragDetails != null);
    if (dragged ||
        (n is UserScrollNotification && n.direction != ScrollDirection.idle)) {
      _followDraft = false;
    }
    if (dragged && _inputFocus.hasFocus) _inputFocus.unfocus();
    return false;
  }

  bool get _touchKeyboard => switch (Theme.of(context).platform) {
        TargetPlatform.iOS || TargetPlatform.android => true,
        _ => false,
      };

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
    if ((cmd == 'image' || cmd == 'video' || cmd == 'speak') &&
        RegExp(r'^off$', caseSensitive: false).hasMatch(arg)) {
      await app.setMediaModel(null, forChat: app.current?.mediaModel != null);
      await app.note(t('Back to answering in words.'));
      return true;
    }
    if (cmd == 'research') {
      if (app.activeModel == null) {
        await app.note(Research.needsPro());
        return true;
      }
      if (arg.isNotEmpty) return false;
      if (!app.researchNext) app.toggleResearch();
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
        await showCreditsSheet(context,
            credits: RegExp(r'^\d+$').hasMatch(arg) ? int.parse(arg) : null);
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
      case 'gift':
        if (Gifts.codeOf(arg) != null) {
          await showRedeemGiftSheet(context, prefill: arg.trim());
        } else {
          await showGiftSheet(context);
        }
        return true;
      case 'transfer':
        final moved = await moveWholeBalance(context, app,
            prefill: pubkeyFrom(arg) == null ? '' : arg.trim());
        if (moved != null) await app.note(moved.message);
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
        final picked = await showPromptsSheet(context, filter: arg);
        if (picked != null) {
          _input.setMarkdown(picked);
          setState(() => _suggestTerm = '');
        }
        return true;
      case 'save':
        final body = _input.markdown.trim().isEmpty ? arg : _input.markdown.trim();
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
      case 'folder':
        if (arg.isNotEmpty) {
          final hit = app.folders
              .where((f) => f.name.toLowerCase() == arg.toLowerCase());
          final folder =
              hit.isNotEmpty ? hit.first : await app.createFolder(arg);
          await app.setTagsAndFolder(app.current!.tags, folder.id);
          await app.note(t('Filed in {name}.', {'name': folder.name}));
          return true;
        }
        await showTagsSheet(context);
        return true;
      case 'shortcuts':
        await showShortcutsSheet(context);
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
        final format = arg.toLowerCase();
        await exportChat(app, app.current!,
            format == 'json' || format == 'txt' ? format : 'md');
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
        if (app.memories.isEmpty) {
          await app.note(t('Nothing is remembered yet.'));
          return true;
        }
        if (await confirmForgetAll(context)) {
          await app.clearMemories();
          _say(t('Forgotten.'));
        }
        return true;
      case 'clear':
        final before = await app.clearCurrent();
        if (before != null) _sayUndo(t('Cleared.'), () => app.restore(before));
        return true;
      default:
        return false;
    }
  }

  Future<bool> _gitCommand(AppController app, String arg) async {
    if (RegExp(r'^add$', caseSensitive: false).hasMatch(arg)) {
      await showReposSheet(context);
      return true;
    }
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

  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyUpEvent &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        _pickMention()) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) {
      final keys = HardwareKeyboard.instance;
      final mod = keys.isControlPressed || keys.isMetaPressed;
      final key = event.logicalKey;
      if (mod && !keys.isAltPressed) {
        final kind = keys.isShiftPressed
            ? (key == LogicalKeyboardKey.keyE ? 'fence' : null)
            : switch (key) {
                LogicalKeyboardKey.keyB => 'bold',
                LogicalKeyboardKey.keyI => 'italic',
                LogicalKeyboardKey.keyE => 'code',
                _ => null,
              };
        if (kind != null) {
          if (_input.format(kind)) _edited();
          return KeyEventResult.handled;
        }
      }
      final enter = key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter;
      if (enter && mod) {
        _send(null, false, true);
        return KeyEventResult.handled;
      }
      if (enter &&
          !keys.isShiftPressed &&
          !keys.isAltPressed &&
          AppScope.read(context).settings.sendOnEnter) {
        if (!_pickMention()) _send(null, false, true);
        return KeyEventResult.handled;
      }
    }
    return _input.handleKey(node, event);
  }

  void _edited() {
    _lastInput = _input.text;
    final app = AppScope.read(context);
    final conv = app.current;
    if (conv != null) unawaited(app.store.setDraft(conv.id, _input.markdown));
    setState(() => _hasText = _input.text.trim().isNotEmpty);
  }

  Map<ShortcutActivator, VoidCallback> _shortcuts(AppController app) {
    final bindings = <ShortcutActivator, VoidCallback>{};
    void both(LogicalKeyboardKey key, VoidCallback run, {bool shift = false}) {
      bindings[SingleActivator(key, control: true, shift: shift)] = run;
      bindings[SingleActivator(key, meta: true, shift: shift)] = run;
    }

    both(LogicalKeyboardKey.keyK, _palette);
    both(LogicalKeyboardKey.keyN, () => app.newConversation());
    both(LogicalKeyboardKey.keyF, () => setState(() => _findTerm = ''));
    both(LogicalKeyboardKey.keyF, () => _openSearch(), shift: true);
    both(LogicalKeyboardKey.keyM, () => showModelsSheet(context), shift: true);
    both(LogicalKeyboardKey.keyG, () => showReposSheet(context), shift: true);
    both(LogicalKeyboardKey.keyP, () => _runPalette((kind: 'action', value: 'prompts')),
        shift: true);
    both(LogicalKeyboardKey.keyS, () => app.retryLast(), shift: true);
    both(LogicalKeyboardKey.keyC, () async {
      final replies = app.messages.where((m) => m.role == ChatRole.bot);
      if (replies.isEmpty) return;
      await Clipboard.setData(ClipboardData(text: replies.last.content));
      _say(t('Copied.'));
    }, shift: true);
    bindings[const SingleActivator(LogicalKeyboardKey.escape)] = () {
      if (_findTerm != null) setState(() => _findTerm = null);
    };
    bindings[const SingleActivator(LogicalKeyboardKey.escape, shift: true)] =
        () {
      if (app.sending) app.stop();
    };
    return bindings;
  }

  Future<void> _palette() async {
    final choice = await showCommandPalette(context);
    if (choice != null && mounted) await _runPalette(choice);
  }

  Future<void> _runPalette(PaletteChoice choice) async {
    final app = AppScope.read(context);
    switch (choice.kind) {
      case 'command':
        _input.setMarkdown('?${choice.value}');
        _lastInput = _input.text;
        setState(() => _suggestTerm = choice.value.endsWith(' ')
            ? ''
            : '?${choice.value}');
        _inputFocus.requestFocus();
        if (!choice.value.endsWith(' ')) await _send();
      case 'chat':
        final hit = app.conversations.where((c) => c.id == choice.value);
        if (hit.isNotEmpty) await app.open(hit.first);
      case 'message':
        final parts = choice.value.split(' ');
        final hit = app.conversations.where((c) => c.id == parts.first);
        if (hit.isEmpty) return;
        _shownConv = hit.first.id;
        await app.open(hit.first);
        if (parts.last.isNotEmpty) _scrollToMessage(parts.last);
      case 'action':
        switch (choice.value) {
          case 'new':
            await app.newConversation();
          case 'search':
            await _openSearch();
          case 'models':
            await showModelsSheet(context);
          case 'repos':
            await showReposSheet(context);
          case 'personas':
            await showPersonasSheet(context);
          case 'system':
            await showSystemPromptSheet(context);
          case 'prompts':
            final picked = await showPromptsSheet(context);
            if (picked != null && mounted) {
              _input.setMarkdown(picked);
              _edited();
            }
          case 'saved':
            final jump = await showSavedMessagesSheet(context);
            if (jump != null && mounted) {
              await _runPalette((
                kind: 'message',
                value: '${jump.conversationId} ${jump.messageId ?? ''}',
              ));
            }
          case 'settings':
            await showAppearanceSheet(context);
          case 'memory':
            await showMemorySheet(context);
          case 'shortcuts':
            await showShortcutsSheet(context);
          case 'credits':
            await showCreditsSheet(context);
          case 'anon':
            await showAnonSheet(context);
          case 'identity':
            await showIdentitySheet(context);
          case 'stats':
            await showStatsSheet(context);
          case 'export-md':
            if (app.current != null) await exportChat(app, app.current!, 'md');
          case 'tags':
            await showTagsSheet(context);
          case 'clear':
            final before = await app.clearCurrent();
            if (before != null) {
              _sayUndo(t('Cleared.'), () => app.restore(before));
            }
        }
    }
  }

  bool _pickMention() {
    final query = Mentions.typing(_input.markdown);
    if (query == null) return false;
    final rows = Mentions.suggest(query.query, AppScope.read(context).mentionCatalog);
    if (rows.isEmpty) return false;
    _completeMention(rows.first, query.fresh);
    return true;
  }

  void _completeMention(Map<String, dynamic> model, bool fresh) {
    _input.setMarkdown(Mentions.completion(model, fresh: fresh));
    _lastInput = _input.text;
    setState(() {
      _suggestTerm = '';
      _hasText = true;
    });
    _inputFocus.requestFocus();
  }

  Map<String, dynamic>? _mentionFor(AppController app) {
    final text = _input.markdown;
    if (Mentions.parse(text) == null) return null;
    if (app.mentionCatalog == null) {
      unawaited(app.ensureMentionCatalog());
      return null;
    }
    final found = Mentions.apply(text, app.mentionCatalog);
    return found != null && found.resolved ? found.model : null;
  }

  String _composerHint(Map<String, dynamic>? media,
      [List<Attachment> attachments = const []]) {
    if (PictureEdit.pinnedImage(media) && PictureEdit.hasPicture(attachments)) {
      return PictureEdit.hint();
    }
    if (media == null) return t('Ask something, or type ? for commands');
    return switch (media['kind']) {
      'video' => t('Describe the video to make'),
      'speech' => t('Type what to read aloud'),
      _ => t('Describe the picture to make'),
    };
  }

  Future<void> _send(
      [String? override, bool bare = false, bool fromKey = false]) async {
    final text = override ?? _input.markdown.trim();
    if (text.isEmpty) return;
    final app = AppScope.read(context);
    if (_touchKeyboard &&
        (!fromKey || MediaQuery.viewInsetsOf(context).bottom > 0)) {
      _inputFocus.unfocus();
    }
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
    if (!bare) {
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
    }
    // A message typed while it was still writing is held, not sent, so nothing
    // below should read out a reply that has not happened yet.
    final asked = app.current?.id;
    final went = await app.send(text, bare: bare);
    final back = app.takeCapReturned();
    if (back != null && mounted && app.current?.id == asked) {
      _input.setMarkdown(back);
      _lastInput = _input.text;
      setState(() => _hasText = true);
    }
    if (went && app.current?.id == asked) {
      final last = app.messages.isEmpty ? null : app.messages.last;
      final streamed = last != null && app.streamedReplies.contains(last.id);
      if (!streamed || _followDraft) _toReply();
      _followDraft = false;
    } else {
      _toBottom();
    }
    if (!mounted || !went) return;
    await _landed(app, asked);
  }

  Future<String> _capPrompt(CapPrompt prompt) async {
    if (!mounted) return 'cancel';
    final conv = AppScope.read(context).current;
    final choice = await showCapPrompt(context, prompt);
    if (choice == 'raise' && mounted && conv != null) {
      await showCapsSheet(context, conv);
    }
    return choice;
  }

  Future<void> _followUp(ChatMessage m, String text) async {
    final app = AppScope.read(context);
    if (_followingUp || app.sending || app.queued.isNotEmpty) return;
    final at = followUpsAt(app.messages);
    if (at < 0 || app.messages[at].id != m.id || !m.followUps.contains(text)) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _followingUp = true);
    try {
      await _send(text, true);
    } finally {
      if (mounted) setState(() => _followingUp = false);
    }
  }

  void _editFollowUp(String text) {
    final app = AppScope.read(context);
    final draft = _input.markdown.trim();
    final next = draft.isEmpty ? text : '$draft $text';
    _input.setMarkdown(next);
    _lastInput = _input.text;
    setState(() {
      _suggestTerm = '';
      _hasText = true;
    });
    final conv = app.current;
    if (conv != null) unawaited(app.store.setDraft(conv.id, next));
    _inputFocus.requestFocus();
  }

  Future<void> _messageAction(MessageAction action, ChatMessage m) async {
    final app = AppScope.read(context);
    switch (action) {
      case MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: m.content));
        _say(t('Copied.'));
      case MessageAction.speak:
        await _voice.toggleSpeak(m.id, m.content,
            rate: app.settings.speechRate,
            voice: app.settings.voiceUri,
            language: Voice.languageFor(m.content, I18n.lang));
      case MessageAction.regenerate:
        await app.regenerate(m);
        _toReply();
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
        final before = await app.deleteMessage(m);
        if (before != null) {
          _sayUndo(t('Message deleted.'), () => app.restore(before));
        }
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

  Future<void> _applyStaged(ChatMessage m) async {
    final app = AppScope.read(context);
    try {
      await app.applyStaged(m);
      _say(t('Applied as one commit.'));
    } on ChatFailure catch (e) {
      _say(e.message);
    } catch (_) {
      _say(t('Could not apply those changes.'));
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
    final source = await showNymSheet<String>(
      context,
      (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (key, icon, label) in [
                ('photos', const NymGlyph('picture', size: 20), t('Photos')),
                ('camera', const Icon(Icons.photo_camera_outlined),
                    t('Take a photo')),
                ('files', const NymGlyph('attach', size: 20), t('Files')),
              ])
                ListTile(
                  leading: icon,
                  title: Text(label),
                  onTap: () => Navigator.pop(sheet, key),
                ),
            ],
          ),
        ),
      ),
    );
    if (source == null) return;
    final ({List<Attachment> files, List<String> problems}) picked;
    try {
      picked = source == 'files'
          ? await Attachments.pick()
          : await Attachments.pickPictures(camera: source == 'camera');
    } catch (_) {
      _say(t('Could not open that. Check that Nymbot may use it in your '
          'device settings.'));
      return;
    }
    for (final a in picked.files) {
      app.addAttachment(a);
    }
    if (picked.problems.isNotEmpty && mounted) {
      _say(t('Could not attach: {names}', {'names': picked.problems.join('; ')}));
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
    if (jump.messageId != null) _shownConv = conv.id;
    await app.open(conv);
    if (jump.messageId != null) _scrollToMessage(jump.messageId!);
  }

  Future<void> _jumpFromLibrary(ArtifactJump jump) async {
    final app = AppScope.read(context);
    final hit = app.conversations.where((c) => c.id == jump.conversationId);
    if (hit.isEmpty) return;
    final artifactId = jump.artifactId;
    if (artifactId == null) {
      await _runPalette((
        kind: 'message',
        value: '${jump.conversationId} ${jump.messageId ?? ''}',
      ));
      return;
    }
    await app.open(hit.first);
    if (!mounted) return;
    final made = app.artifacts.where((a) => a.id == artifactId);
    if (made.isNotEmpty) await showArtifact(context, made.first);
  }

  bool _tasksOpen = false;

  void _openTasks(BuildContext context) {
    if (tasksBeside(context)) {
      setState(() => _tasksOpen = !_tasksOpen);
      return;
    }
    unawaited(showTasksSheet(context, onJump: _jumpFromTasks));
  }

  void _jumpFromTasks(String id) {
    if (id == 'live') {
      _toBottom();
      return;
    }
    _scrollToMessage(id);
  }

  void _scrollToMessage(String id) {
    final token = ++_settling;
    setState(() => _highlighted = id);
    _seek(id, token, 60, true);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _highlighted == id) setState(() => _highlighted = null);
    });
  }

  void _seek(String id, int token, int tries, bool first) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _settling || !_scroll.hasClients) return;
      final ctx = _keys[id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: reducedMotion(context)
                ? Duration.zero
                : const Duration(milliseconds: 250),
            alignment: 0.4);
        return;
      }
      if (tries <= 0) return;
      final messages = AppScope.read(context).messages;
      final at = messages.indexWhere((m) => m.id == id);
      if (at < 0) return;
      int? low;
      for (var i = 0; i < messages.length; i++) {
        if (_keys[messages[i].id]?.currentContext != null) {
          low = i;
          break;
        }
      }
      final position = _scroll.position;
      final double target;
      if (first || low == null) {
        target = position.maxScrollExtent * at / math.max(1, messages.length - 1);
      } else if (at < low) {
        target = position.pixels - position.viewportDimension * 0.8;
      } else {
        target = position.pixels + position.viewportDimension * 0.8;
      }
      _scroll.jumpTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent));
      _seek(id, token, tries - 1, false);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final conv = app.current;
    if (conv?.id != _shownConv) {
      _shownConv = conv?.id;
      _openedChat();
    }

    final queued = app.pendingInput;
    if (queued != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final text = app.takeInput();
        if (text == null || !mounted) return;
        _input.setMarkdown(text);
        setState(() => _suggestTerm = '');
      });
    }

    return CallbackShortcuts(
      bindings: _shortcuts(app),
      child: Focus(
        autofocus: true,
        child: Scaffold(
          drawer: _ChatDrawer(onJump: _jumpFromLibrary),
          drawerEdgeDragWidth: MediaQuery.sizeOf(context).width * 0.5,
          appBar: AppBar(
            title: Semantics(
              button: true,
              hint: t('Rename this chat'),
              child: InkWell(
                key: const ValueKey('chat-title'),
                borderRadius: BorderRadius.circular(6),
                onTap: _rename,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          conv == null || conv.title.isEmpty
                              ? t('New chat')
                              : conv.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (conv?.pinned ?? false)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: NymGlyph('star',
                              size: 14,
                              filled: true,
                              color: NymbotColors.lightning),
                        ),
                      if (conv != null) CapBadge(conv: conv),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              if (conv?.anon ?? false)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Chip(
                    label: Text(t('anon'), style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: Theme.of(context).colorScheme.secondary),
                  ),
                ),
              TasksButton(open: _tasksOpen, onPressed: () => _openTasks(context)),
              IconButton(
                icon: const NymGlyph('search', size: 20),
                tooltip: t('Search everything'),
                onPressed: () => _openSearch(),
              ),
              IconButton(
                icon: const NymGlyph('more', size: 20, filled: true),
                tooltip: t('Chat options'),
                onPressed: () => _menu(app),
              ),
            ],
          ),
          body: TasksSplit(
            open: _tasksOpen,
            onJump: _jumpFromTasks,
            onClose: () => setState(() => _tasksOpen = false),
            child: Column(
            children: [
              const NoticeBanner(),
              const NymbotToolbar(),
              const ContextBar(),
              if (_findTerm != null) _findBar(context, app),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _messages(context, app)),
                    const SandboxView(),
                    if (!_atBottom && app.messages.isNotEmpty)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          heroTag: 'toBottom',
                          tooltip: t('Jump to the newest message'),
                          onPressed: () => _toBottom(),
                          child: const NymGlyph('down', size: 18),
                        ),
                      ),
                  ],
                ),
              ),
              _composer(context, app),
            ],
          ),
          ),
        ),
      ),
    );
  }

  List<String> _findHits(AppController app) {
    final term = (_findTerm ?? '').toLowerCase().trim();
    if (term.isEmpty) return const [];
    return [
      for (final m in app.messages)
        if (m.content.toLowerCase().contains(term)) m.id,
    ];
  }

  void _stepFind(AppController app, int delta) {
    final hits = _findHits(app);
    if (hits.isEmpty) return;
    setState(() => _findAt = (_findAt + delta + hits.length) % hits.length);
    _scrollToMessage(hits[_findAt]);
  }

  Widget _findBar(BuildContext context, AppController app) {
    final hits = _findHits(app);
    final at = hits.isEmpty ? 0 : _findAt.clamp(0, hits.length - 1);
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
              onChanged: (v) {
                setState(() {
                  _findTerm = v;
                  _findAt = 0;
                });
                final first = _findHits(app);
                if (first.isNotEmpty) _scrollToMessage(first.first);
              },
              onSubmitted: (_) => _stepFind(app, 1),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              _findTerm!.trim().isEmpty
                  ? ''
                  : hits.isEmpty
                      ? t('none')
                      : t('{n} of {total}', {'n': at + 1, 'total': hits.length}),
              style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
            ),
          ),
          IconButton(
            icon: const NymGlyph('up', size: 20),
            tooltip: t('Previous match'),
            onPressed: hits.isEmpty ? null : () => _stepFind(app, -1),
          ),
          IconButton(
            icon: const NymGlyph('down', size: 20),
            tooltip: t('Next match'),
            onPressed: hits.isEmpty ? null : () => _stepFind(app, 1),
          ),
          IconButton(
            icon: const NymGlyph('close', size: 18),
            tooltip: t('Close find'),
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
    final offer = app.sending ||
            app.queued.isNotEmpty ||
            _followingUp ||
            _revealId != null
        ? -1
        : followUpsAt(app.messages);
    final messages = app.messages;
    if (app.mentionCatalog == null &&
        !_makerLookup &&
        messages.any((m) =>
            m.role == ChatRole.bot && m.model != null && m.modelMaker == null && (m.pro ?? true))) {
      _makerLookup = true;
      unawaited(app.ensureMentionCatalog());
    }
    final groupStart = List<int>.filled(messages.length, 0);
    for (var j = 1; j < messages.length; j++) {
      final m = messages[j];
      final previous = messages[j - 1];
      final together = previous.role == m.role &&
          (m.role == ChatRole.self || m.role == ChatRole.bot) &&
          m.at.difference(previous.at).inMinutes.abs() < 10;
      groupStart[j] = together ? groupStart[j - 1] : j;
    }

    _trackDraft(app);
    return StickyAvatarScope(
      child: NotificationListener<ScrollNotification>(
        onNotification: _threadScrolled,
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          itemCount: app.messages.length + (app.sending ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= app.messages.length && app.teaming) {
              return TeamProgress(
                label: app.status ?? t('Nymbot is leading a team'),
                showAvatar: app.settings.avatars,
                steps: app.progressSteps,
                workers: app.teamWorkers,
              );
            }
            if (i >= app.messages.length && app.researching) {
              return ResearchProgress(
                label: app.status ?? t('Nymbot is researching'),
                showAvatar: app.settings.avatars,
                steps: app.progressSteps,
              );
            }
            if (i >= app.messages.length) {
              final status = TypingIndicator(
                label: app.status ??
                    (app.activeRepos.isNotEmpty && app.activeModel != null
                        ? t('Nymbot is reading your repositories')
                        : t('Nymbot is thinking')),
                showAvatar: app.settings.avatars,
                steps: _progressLines(app.progressSteps),
              );
              final partial = app.progressDraft?.trim() ?? '';
              if (partial.isEmpty) return status;
              final model = app.activeModel;
              final previous = messages.isEmpty ? null : messages.last;
              final together = previous != null &&
                  previous.role == ChatRole.bot &&
                  DateTime.now().difference(previous.at).inMinutes.abs() < 10;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  KeyedSubtree(
                    key: _draftKey,
                    child: MessageBubble(
                      key: const ValueKey('reply-draft'),
                      message: ChatMessage(
                        id: 'reply-draft',
                        role: ChatRole.bot,
                        content: partial,
                        pro: model != null,
                        model: model?['label'] as String?,
                      ),
                      draft: true,
                      selfPubkey: selfPubkey,
                      settings: app.settings,
                      onAction: (_, __) {},
                      grouped: together,
                      avatarGroup: together
                          ? messages[groupStart[messages.length - 1]].id
                          : 'reply-draft',
                      modelCatalog: app.mentionCatalog,
                    ),
                  ),
                  status,
                ],
              );
            }
            final m = messages[i];
            final grouped = groupStart[i] != i;
            final lastInGroup =
                i + 1 >= messages.length || groupStart[i + 1] != groupStart[i];
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
                onAllowTool: m.pendingTool == null ? null : () => app.allowPendingTool(m),
                onDenyTool: m.pendingTool == null ? null : () => app.denyPendingTool(m),
                onAlwaysAllowTool:
                    app.canAlwaysAllow(m.pendingTool) ? () => app.allowPendingToolAlways(m) : null,
                onApplyStaged: m.staged == null ? null : () => _applyStaged(m),
                onDiscardStaged: m.staged == null ? null : () => AppScope.read(context).discardStaged(m),
                selfPubkey: selfPubkey,
                selfName: app.selfNameIn(app.current, me?.name),
                selfPicture: me?.picture ?? '',
                settings: app.settings,
                grouped: grouped,
                lastInGroup: lastInGroup,
                avatarGroup: messages[groupStart[i]].id,
              modelCatalog: app.mentionCatalog,
                speaking: _voice.speakingId == m.id,
                highlighted: _highlighted == m.id,
                onAction: _messageAction,
                followUps: i == offer ? m.followUps : const [],
                onFollowUp: (text) => _followUp(m, text),
                onEditFollowUp: _editFollowUp,
                reveal: _revealId == m.id ? _revealAt : null,
              ),
            );
          },
        ),
      ),
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

    return NotificationListener<ScrollNotification>(
      onNotification: _threadScrolled,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                    _input.setMarkdown(s.$2);
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
                      _input.setMarkdown(tip);
                      setState(() => _suggestTerm = tip);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer(BuildContext context, AppController app) {
    final estimate = app.estimate(_input.markdown);
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
            if (Mentions.typing(_suggestTerm) case final query?)
              MentionSuggestions(
                query: query,
                catalog: app.mentionCatalog,
                onPick: (m) => _completeMention(m, query.fresh),
              ),
            if (_suggestTerm.startsWith('?') && !_suggestTerm.contains(' '))
              CommandSuggestions(
                term: _suggestTerm,
                onPick: (c) {
                  _input.setMarkdown('?${c.name}${c.args.isEmpty ? '' : ' '}');
                  setState(() => _suggestTerm = c.args.isEmpty ? '' : '?${c.name} ');
                  if (c.args.isEmpty) _send();
                },
              ),
            DocTray(convId: app.current?.id),
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
                            : a.uploadError != null
                                ? Icon(Icons.error_outline,
                                    size: 15,
                                    color: Theme.of(context).colorScheme.error)
                                : NymGlyph(
                                    a.kind == AttachmentKind.image
                                        ? 'picture'
                                        : 'artifacts',
                                    size: 15),
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
              if (app.editingQueued == i)
                _queueEditorRow(context, app)
              else
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.fromLTRB(8, 0, 0, 0),
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
                              fontSize: 10,
                              color: Theme.of(context).hintColor)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          app.queued[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor),
                        ),
                      ),
                      IconButton(
                        key: ValueKey('queue-edit-$i'),
                        icon: const NymGlyph('pencil', size: 15),
                        tooltip: t('Edit message'),
                        constraints:
                            const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: app.editingQueued == null
                            ? () {
                                _queueEditor.text = app.queued[i];
                                app.editQueued(i);
                              }
                            : null,
                      ),
                      IconButton(
                        icon: const NymGlyph('close', size: 15),
                        tooltip: t('Do not send this'),
                        constraints:
                            const BoxConstraints(minWidth: 48, minHeight: 48),
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
                      icon: const NymGlyph('close', size: 15),
                      tooltip: t('Remove the quote'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => app.setQuote(null),
                    ),
                  ],
                ),
              ),
            if (_dictation == 'recording' || _dictation == 'sending')
              _dictationStrip(context),
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
                  icon: const NymGlyph('attach', size: 20),
                  tooltip: t('Attach a file'),
                  onPressed: _attach,
                ),
                if (Dictation.supported)
                  IconButton(
                    key: const ValueKey('mic'),
                    onPressed: _dictation == 'starting' || _dictation == 'sending'
                        ? null
                        : _toggleDictation,
                    tooltip: _dictation == 'recording'
                        ? t('Stop and transcribe')
                        : t('Dictate a message'),
                    isSelected: _dictation == 'recording',
                    icon: const NymGlyph('mic', size: 20),
                    selectedIcon: const NymGlyph('mic',
                        size: 20, color: NymbotColors.danger),
                  ),
                Expanded(
                  child: CodeFrame(
                    controller: _input,
                    scroll: _inputScroll,
                    child: TextField(
                      controller: _input,
                      focusNode: _inputFocus,
                      scrollController: _inputScroll,
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
                          final rest = _input.markdown.replaceFirst(run, '');
                          app.addAttachment(Attachments.fromText(run,
                              id: bytesToHex(randomBytes(8))));
                          _input.setMarkdown(rest);
                          _lastInput = _input.text;
                          final conv = app.current;
                          if (conv != null) app.store.setDraft(conv.id, rest);
                          return;
                        }
                        _lastInput = v;
                        final conv = app.current;
                        if (conv != null) app.store.setDraft(conv.id, _input.markdown);
                        final mentioning = Mentions.typing(v) != null;
                        if (mentioning && app.mentionCatalog == null) {
                          unawaited(app.ensureMentionCatalog());
                        }
                        final next = (v.startsWith('?') || mentioning) ? v : '';
                        final has = v.trim().isNotEmpty;
                        if (next != _suggestTerm || has != _hasText) {
                          setState(() {
                            _suggestTerm = next;
                            _hasText = has;
                          });
                        }
                      },
                      onSubmitted: app.settings.sendOnEnter
                          ? (_) {
                              if (!_pickMention()) _send();
                            }
                          : null,
                      decoration: InputDecoration(
                        hintText: _composerHint(app.activeMediaModel, app.attachments),
                        hintStyle: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (app.sending) ...[
                  IconButton.filledTonal(
                    onPressed: app.stop,
                    tooltip: t('Stop'),
                    style: IconButton.styleFrom(
                      foregroundColor: NymbotColors.danger,
                      backgroundColor:
                          NymbotColors.danger.withValues(alpha: 0.16),
                    ),
                    icon: const NymGlyph('stop', size: 20, filled: true),
                  ),
                  if (_hasText) ...[
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      onPressed: () => _send(),
                      tooltip: t('Send when this one is done'),
                      icon: const NymGlyph('send', size: 20),
                    ),
                  ],
                ] else
                  IconButton.filledTonal(
                    onPressed: () => _send(),
                    tooltip: t('Send'),
                    icon: const NymGlyph('send', size: 20),
                  ),
              ],
            ),
            if (app.researchHint(_input.markdown) != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  app.researchHint(_input.markdown)!,
                  key: const ValueKey('research-hint'),
                  style:
                      TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                ),
              )
            else if (_mentionFor(app) case final mentioned?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  mentionHint(mentioned, app.catalogPricing),
                  style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                ),
              )
            else if (PictureEdit.editing(
                    _input.markdown, app.attachments, app.activeMediaModel) &&
                PictureEdit.instruction(_input.markdown).isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  PictureEdit.hint(),
                  style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                ),
              )
            else if (app.repoNeedsPro)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  t('Only a Pro model can read a repository — pick one with ?model, or this chat answers without it.'),
                  style:
                      TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                ),
              )
            else if (app.settings.showCostEstimate && _input.markdown.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  withCapRoom(app, estimate.tier == 'pro'
                      ? (creditAmount(estimate.low, estimate.metered) ==
                              creditAmount(estimate.high, estimate.metered)
                          ? t('About {n} Pro credits', {
                              'n': creditAmount(estimate.low, estimate.metered)
                            })
                          : t('About {low}–{high} Pro credits', {
                              'low':
                                  creditAmount(estimate.low, estimate.metered),
                              'high':
                                  creditAmount(estimate.high, estimate.metered)
                            }))
                      : estimate.metered
                          ? (creditAmount(estimate.low, true) ==
                                  creditAmount(estimate.high, true)
                              ? t('{n} standard credits',
                                  {'n': creditAmount(estimate.low, true)})
                              : t('About {low}–{high} standard credits', {
                                  'low': creditAmount(estimate.low, true),
                                  'high': creditAmount(estimate.high, true)
                                }))
                          : (estimate.low == 1
                              ? t('1 standard credit')
                              : t('{n} standard credits',
                                  {'n': figure(estimate.low.round())}))),
                  style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                ),
              )
            else if (_input.markdown.trim().isNotEmpty && app.capRoomLine.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  app.capRoomLine,
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
    case 'caps':
      await showCapsSheet(context, conv);
    case 'share-link':
      await showShareChatSheet(context, app, conv,
          elsewhere ? app.store.messages(conv.id) : app.messages);
    case 'share':
      await Share.share(
        Transcript.markdown(conv,
            elsewhere ? app.store.messages(conv.id) : app.messages,
            repos: reposOf(app, conv)),
        subject: conv.title.isEmpty ? 'Nymbot' : conv.title,
      );
    case 'export-md':
      await exportChat(app, conv, 'md');
    case 'export-txt':
      await exportChat(app, conv, 'txt');
    case 'export-json':
      await exportChat(app, conv, 'json');
    case 'copy':
      await Clipboard.setData(ClipboardData(text: Transcript.markdown(
          conv,
          elsewhere ? app.store.messages(conv.id) : app.messages,
          repos: reposOf(app, conv))));
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
            content: Text(t('Copied.')),
            duration: const Duration(seconds: 3)));
    case 'clear':
      final before = await app.clearCurrent(target: conv);
      if (before != null) {
        messenger
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text(t('Cleared.')),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
                label: t('Undo'), onPressed: () => app.restore(before)),
          ));
      }
    case 'delete':
      await confirmDeleteChat(context, app, conv);
  }
}

List<GitRepo> reposOf(AppController app, Conversation conv) =>
    app.repos.where((r) => conv.repoIds.contains(r.id)).toList();

Future<void> exportChat(
    AppController app, Conversation conv, String format) async {
  final messages =
      conv.id == app.current?.id ? app.messages : app.store.messages(conv.id);
  final title = conv.title.isEmpty ? t('New chat') : conv.title;
  switch (format) {
    case 'json':
      await ShareFile.text(Backup.chat(conv, messages),
          name: Backup.fileName(title, 'json'),
          mime: 'application/json',
          subject: title);
    case 'txt':
      await ShareFile.text(Transcript.plain(conv, messages),
          name: Backup.fileName(title, 'txt'),
          mime: 'text/plain',
          subject: title);
    default:
      await ShareFile.text(
          Transcript.markdown(conv, messages, repos: reposOf(app, conv)),
          name: Backup.fileName(title, 'md'),
          mime: 'text/markdown',
          subject: title);
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
  const _ChatDrawer({required this.onJump});

  final Future<void> Function(ArtifactJump jump) onJump;

  @override
  State<_ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<_ChatDrawer> {
  static const _menuOpenKey = 'menuOpen';
  bool _libraryOpen = true;
  int? _artifactCount;

  @override
  void initState() {
    super.initState();
    _libraryOpen = AppScope.read(context).store.getBool(_menuOpenKey, fallback: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _artifactCount = artifactIndex(AppScope.read(context)).length);
    });
  }

  Future<void> _openArtifactLibrary() async {
    final jump = await showArtifactLibrarySheet(context);
    if (!mounted) return;
    setState(() => _artifactCount = artifactIndex(AppScope.read(context)).length);
    if (jump == null) return;
    Navigator.pop(context);
    await widget.onJump(jump);
  }

  int? _menuCount(AppController app, String entry) => switch (entry) {
        'workspace' => app.workspaces.length,
        'bot' => app.bots.length,
        'artifacts' => _artifactCount,
        'scheduled' => app.schedules.where((s) => s.enabled).length,
        _ => null,
      };

  void _toggleMenu() {
    setState(() => _libraryOpen = !_libraryOpen);
    unawaited(AppScope.read(context).store.setBool(_menuOpenKey, _libraryOpen));
  }

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
            ? const NymGlyph('star',
                size: 15, filled: true, color: NymbotColors.lightning)
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
            if (app.sendingIn(conv))
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ),
            if (conv.anon)
              Text(t('anon'), style: const TextStyle(fontSize: 11)),
            IconButton(
              icon: const NymGlyph('more', size: 18, filled: true),
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

    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.0);
    final head = <Widget>[
      ListTile(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NymbotMark(size: 26),
            const SizedBox(width: 6),
            // Optical, not geometric: the drawn body sits a hair below
            // its box because of the antennae, so the word is nudged to
            // match its middle.
            Flexible(
              child: Transform.translate(
                offset: const Offset(0, 1.5),
                child: Text(
                  'Nymbot',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kMonoFamily, fontFamilyFallback: kMonoFallback,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
        trailing: IconButton(
          icon: const NymGlyph('plus', size: 20),
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
        height: 42 * scale,
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
    ];
    final toggle = <Widget>[
      const Divider(height: 1),
      InkWell(
        key: const ValueKey('drawer-menu-toggle'),
        onTap: _toggleMenu,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t('Menu'),
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.4,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
              AnimatedRotation(
                turns: _libraryOpen ? 0 : -0.25,
                duration: reducedMotion(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                child: const NymGlyph('chevron', size: 16),
              ),
            ],
          ),
        ),
      ),
    ];
    final menu = <Widget>[
      if (_libraryOpen)
        for (final entry in <(String, String, Future<void> Function())>[
          ('repositories', t('Repositories'),
              () => showReposSheet(context)),
          ('connectors', t('Connectors'),
              () => showConnectorsSheet(context)),
          ('prompt-library', t('Prompt library'), () async {
            final picked = await showPromptsSheet(context);
            if (picked != null) app.queueInput(picked);
            if (picked != null && context.mounted) Navigator.pop(context);
          }),
          ('personas', t('Personas'), () => showPersonasSheet(context)),
          ('workspace', t('Workspaces'), () => showWorkspacesSheet(context)),
          ('bot', t('Bots'), () => showBotsSheet(context)),
          ('artifacts', t('Artifacts'), _openArtifactLibrary),
          ('scheduled', t('Scheduled'), () async {
            final went = await showSchedulesSheet(context);
            if (went != null && context.mounted) Navigator.pop(context);
          }),
          ('saved-messages', t('Saved messages'), () async {
            await showSavedMessagesSheet(context);
          }),
          ('memory', t('Memory'), () => showMemorySheet(context)),
          ('settings', t('Settings'), () => showAppearanceSheet(context)),
          ('help', t('Help'), () => showHelpSheet(context)),
          ('keyboard', t('Getting around'),
              () => showShortcutsSheet(context)),
        ])
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            key: ValueKey('drawer-menu-${entry.$1}'),
            leading: NymGlyph.has(entry.$1)
                ? NymGlyph(entry.$1, size: 18)
                : const Icon(Icons.keyboard_outlined, size: 18),
            title: Text(entry.$2, style: const TextStyle(fontSize: 13)),
            trailing: switch (_menuCount(app, entry.$1)) {
              final int n when n > 0 => Text('$n',
                  key: ValueKey('drawer-count-${entry.$1}'),
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).hintColor)),
              _ => null,
            },
            onTap: entry.$3,
          ),
    ];
    final profile = <Widget>[
      const Divider(height: 1),
      ListTile(
        key: const ValueKey('drawer-profile'),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            NymAvatar(
              seed: app.identity.pubkey,
              size: 28,
              picture: app.profiles.of(app.identity.pubkey).picture,
            ),
            Positioned(
              right: -5.5,
              bottom: -5.5,
              child: NymGlyph(
                'dot',
                size: 18,
                filled: true,
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
          final nick = app.nickname;
          return Row(
            children: [
              Flexible(
                child: Text(
                  nick.isNotEmpty ? nick : who.name,
                  key: const ValueKey('drawer-identity-name'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: who.hasProfile || nick.isNotEmpty ? null : 'monospace',
                    fontSize: 13,
                    color: Theme.of(context).textTheme.bodyMedium?.color,
                  ),
                ),
              ),
              if (who.nip05.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: NymGlyph('verified',
                      size: 12, color: Theme.of(context).colorScheme.secondary),
                ),
            ],
          );
        }),
        subtitle: Text(
          app.standardBalance == null
              ? t('{n} relays', {'n': app.relaysUp})
              : t('{standard} standard · {pro} Pro', {
                  'standard': creditFigure(app.standardBalance),
                  'pro': creditFigure(app.proBalance),
                }),
          style: const TextStyle(fontSize: 11),
        ),
        onTap: () => showIdentitySheet(context),
      ),
    ];
    final empty = Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(t('Nothing here.'),
            style: TextStyle(color: Theme.of(context).hintColor)),
      ),
    );

    return Drawer(
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final needed = 380.0 * scale;
            if (box.maxHeight >= needed) {
              return Column(
                children: [
                  ...head,
                  Expanded(
                    child: rows.isEmpty ? empty : _FadedChatList(children: rows),
                  ),
                  ...toggle,
                  if (menu.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math.min(
                            box.maxHeight * 0.4, box.maxHeight - needed + 60 * scale),
                      ),
                      child: ListView(
                        key: const ValueKey('drawer-menu-list'),
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: menu,
                      ),
                    ),
                  ...profile,
                ],
              );
            }
            return CustomScrollView(
              key: const ValueKey('drawer-scroll'),
              slivers: [
                SliverList(
                  delegate: SliverChildListDelegate([
                    ...head,
                    if (rows.isEmpty) empty,
                    ...rows,
                    ...toggle,
                    ...menu,
                    ...profile,
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FadedChatList extends StatefulWidget {
  const _FadedChatList({required this.children});

  final List<Widget> children;

  @override
  State<_FadedChatList> createState() => _FadedChatListState();
}

class _FadedChatListState extends State<_FadedChatList> {
  static const _fade = 32.0;
  final _scroll = ScrollController();
  bool _more = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_measure);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant _FadedChatList oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted || !_scroll.hasClients) return;
    final more = _scroll.position.extentAfter > 2;
    if (more != _more) setState(() => _more = more);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = DrawerTheme.of(context).backgroundColor ??
        theme.colorScheme.surfaceContainerLow;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        return false;
      },
      child: Stack(
        children: [
          ListView(
            key: const ValueKey('drawer-chat-list'),
            controller: _scroll,
            padding: const EdgeInsets.only(bottom: _fade),
            children: widget.children,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _fade,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: AnimatedOpacity(
                  key: const ValueKey('drawer-fade'),
                  opacity: _more ? 1 : 0,
                  duration: reducedMotion(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 150),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          base.withValues(alpha: 0),
                          base.withValues(alpha: 0.7),
                          base,
                        ],
                        stops: const [0, 0.55, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
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
