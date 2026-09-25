import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../features/i18n/i18n.dart';

class ReplyNotifyChannel {
  ReplyNotifyChannel([MethodChannel? channel])
      : channel = channel ?? const MethodChannel('ai.nymbot/notify');

  final MethodChannel channel;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  Future<bool> permission() async => await _call<bool>('permission') ?? false;

  Future<bool> wait(
          {required String title,
          required String text,
          required String channelName}) async =>
      await _call<bool>(
          'wait', {'title': title, 'text': text, 'channel': channelName}) ??
      false;

  Future<void> stopWaiting() => _call<Object?>('stopWaiting');

  Future<bool> reply(
          {required String chat,
          required String title,
          required String body,
          required String channelName}) async =>
      await _call<bool>('reply', {
        'chat': chat,
        'title': title,
        'body': body,
        'channel': channelName,
      }) ??
      false;

  Future<void> viewing(String? chat) =>
      _call<Object?>('viewing', {'chat': chat});

  Future<String?> initial() => _call<String>('initial');

  Future<String?> token() => _call<String>('token');

  Future<int?> beginBackground() => _call<int>('beginBackground');

  Future<void> endBackground(int id) =>
      _call<Object?>('endBackground', {'id': id});

  void onOpen(Future<void> Function(String chat) open) {
    try {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'open' && call.arguments is String) {
          await open(call.arguments as String);
          return null;
        }
        throw MissingPluginException();
      });
    } catch (_) {}
  }
}

typedef NotifyRegister = Future<Map<String, dynamic>?> Function(
    String conv, Map<String, dynamic> body);

class ReplyNotify with WidgetsBindingObserver {
  ReplyNotify({
    required this.enabled,
    required this.register,
    required this.titleOf,
    required this.open,
    ReplyNotifyChannel? channel,
    TargetPlatform? platform,
    bool? sandbox,
  })  : channel = channel ?? ReplyNotifyChannel(),
        _platform = platform,
        sandbox = sandbox ?? kDebugMode;

  final bool Function() enabled;
  final NotifyRegister register;
  final String Function(String conv) titleOf;
  final Future<void> Function(String conv) open;
  final ReplyNotifyChannel channel;
  final TargetPlatform? _platform;
  final bool sandbox;

  static const proactiveAfter = Duration(seconds: 10);
  static final _chatId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  final Map<String, String> pending = {};
  final Set<String> registered = {};
  final Set<String> _answered = {};
  final Map<String, Timer> _timers = {};
  bool background = false;
  bool waiting = false;
  String? viewing;
  bool _attached = false;

  TargetPlatform get platform => _platform ?? defaultTargetPlatform;

  bool get supported =>
      !kIsWeb &&
      (platform == TargetPlatform.android || platform == TargetPlatform.iOS);

  bool get _ios => platform == TargetPlatform.iOS;

  Future<void> attach() async {
    if (_attached || !supported) return;
    _attached = true;
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    channel.onOpen(open);
    final chat = await channel.initial();
    if (chat != null && chat.isNotEmpty) await open(chat);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  Future<bool> askPermission() async {
    if (!supported) return false;
    return channel.permission();
  }

  void viewingChat(String? conv) {
    viewing = conv;
    if (supported) unawaited(channel.viewing(conv));
  }

  void pendingTurn(String conv, String eventId) {
    if (!supported) return;
    pending[conv] = eventId;
    _timers.remove(conv)?.cancel();
    if (!enabled()) return;
    if (background) {
      if (_ios) {
        unawaited(_registerAll());
      } else {
        unawaited(_startWaiting());
      }
      return;
    }
    if (_ios) {
      _timers[conv] = Timer(proactiveAfter, () {
        _timers.remove(conv);
        if (pending[conv] == eventId && enabled()) {
          unawaited(_register(conv, eventId));
        }
      });
    }
  }

  Future<void> settled(String conv, {required bool replied}) async {
    if (!supported) return;
    _timers.remove(conv)?.cancel();
    final eventId = pending.remove(conv);
    final handled = eventId != null &&
        (registered.remove(eventId) | _answered.remove(eventId));
    if (eventId != null &&
        enabled() &&
        !handled &&
        !(!background && viewing == conv)) {
      await _show(conv, replied: replied);
    }
    if (pending.isEmpty) await _stopWaiting();
  }

  Future<void> settingChanged(bool on) async {
    if (!supported) return;
    if (!on) {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
      await _stopWaiting();
      return;
    }
    await askPermission();
    if (background && pending.isNotEmpty) {
      if (_ios) {
        await _registerAll();
      } else {
        await _startWaiting();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(lifecycle(state));
  }

  Future<void> lifecycle(AppLifecycleState state) async {
    if (!supported) return;
    switch (state) {
      case AppLifecycleState.resumed:
        background = false;
        await _stopWaiting();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (background) return;
        background = true;
        if (!enabled() || pending.isEmpty) return;
        if (_ios) {
          await _registerAll();
        } else {
          await _startWaiting();
        }
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _startWaiting() async {
    if (waiting || _ios) return;
    waiting = await channel.wait(
      title: 'Nymbot',
      text: t('Waiting for Nymbot\'s reply…'),
      channelName: t('Waiting for replies'),
    );
  }

  Future<void> _stopWaiting() async {
    if (_ios) return;
    waiting = false;
    await channel.stopWaiting();
  }

  Future<void> _show(String conv, {required bool replied}) async {
    final title = titleOf(conv).trim();
    await channel.reply(
      chat: conv,
      title: replied
          ? t('Nymbot replied')
          : t('Nymbot could not finish that reply'),
      body: title.isEmpty ? t('Open the chat to read it.') : title,
      channelName: t('Replies'),
    );
  }

  Future<void> _registerAll() async {
    final work = [
      for (final e in pending.entries)
        if (!registered.contains(e.value)) (conv: e.key, eventId: e.value),
    ];
    if (work.isEmpty) return;
    final task = await channel.beginBackground();
    try {
      await Future.wait([for (final w in work) _register(w.conv, w.eventId)]);
    } finally {
      if (task != null && task > 0) await channel.endBackground(task);
    }
  }

  Future<void> _register(String conv, String eventId) async {
    if (!_ios || !enabled() || registered.contains(eventId)) return;
    if (!_chatId.hasMatch(conv)) return;
    final token = await channel.token();
    if (token == null || token.isEmpty) return;
    Map<String, dynamic>? res;
    try {
      res = await register(conv, {
        'eventId': eventId,
        'token': token,
        'env': sandbox ? 'sandbox' : 'production',
        'chat': conv,
        'text': t('Your reply is ready'),
      });
    } catch (_) {
      res = null;
    }
    if (res == null || pending[conv] != eventId) return;
    if (res['done'] == true) {
      _answered.add(eventId);
      if (background || viewing != conv) await _show(conv, replied: true);
      return;
    }
    if (res['ok'] == true) registered.add(eventId);
  }
}
