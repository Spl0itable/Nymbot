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
          required String channelName,
          String? asked}) async =>
      await _call<bool>('reply', {
        'chat': chat,
        'title': title,
        'body': body,
        'channel': channelName,
        if (asked != null) 'asked': asked,
      }) ??
      false;

  Future<void> viewing(String? chat) =>
      _call<Object?>('viewing', {'chat': chat});

  Future<Object?> initial() => _call<Object>('initial');

  Future<String?> token() => _call<String>('token');

  Future<int?> beginBackground() => _call<int>('beginBackground');

  Future<void> endBackground(int id) =>
      _call<Object?>('endBackground', {'id': id});

  Future<bool> checks(bool on, {String? channelName}) async =>
      await _call<bool>('checks', {
        'on': on,
        if (channelName != null) 'channel': channelName,
      }) ??
      false;

  Future<List<String>> pushed() async {
    final raw = await _call<Object>('pushed');
    return [
      for (final id in (raw is List ? raw : const []))
        if (id is String && id.isNotEmpty) id,
    ];
  }

  Future<Map<String, String>?> upState() async {
    final raw = await _call<Object>('upState');
    if (raw is! Map) return null;
    final endpoint = raw['endpoint'], p256dh = raw['p256dh'], auth = raw['auth'];
    if (endpoint is! String || p256dh is! String || auth is! String) return null;
    if (endpoint.isEmpty || p256dh.isEmpty || auth.isEmpty) return null;
    return {
      'endpoint': endpoint,
      'p256dh': p256dh,
      'auth': auth,
      if (raw['distributor'] is String) 'distributor': raw['distributor'] as String,
    };
  }

  Future<List<({String package, String name})>> upDistributors() async {
    final raw = await _call<Object>('upDistributors');
    return [
      for (final d in (raw is List ? raw : const []))
        if (d is Map && d['package'] is String)
          (package: d['package'] as String, name: '${d['name'] ?? d['package']}'),
    ];
  }

  Future<bool> upRegister(String distributor,
          {String? channelName, Map<String, String>? texts}) async =>
      await _call<bool>('upRegister', {
        'distributor': distributor,
        if (channelName != null) 'channel': channelName,
        if (texts != null) 'texts': texts,
      }) ??
      false;

  Future<void> upUnregister() => _call<Object?>('upUnregister');

  void onOpen(Future<void> Function(String chat) open,
      {Future<void> Function(String chat, String asked)? openAt}) {
    try {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'open' && call.arguments is String) {
          await open(call.arguments as String);
          return null;
        }
        final args = call.arguments;
        if (call.method == 'open' && args is Map && args['chat'] is String) {
          final asked = args['asked'];
          if (asked is String && asked.isNotEmpty && openAt != null) {
            await openAt(args['chat'] as String, asked);
          } else {
            await open(args['chat'] as String);
          }
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
    this.openAt,
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
  final Future<void> Function(String conv, String asked)? openAt;
  final ReplyNotifyChannel channel;
  final TargetPlatform? _platform;
  final bool sandbox;

  static const proactiveAfter = Duration(seconds: 10);
  static final _chatId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  final Map<String, String> pending = {};
  final Map<String, String> _chatOf = {};
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
    channel.onOpen(open, openAt: openAt);
    final first = await channel.initial();
    if (first is String && first.isNotEmpty) await open(first);
    if (first is Map && first['chat'] is String) {
      final chat = first['chat'] as String;
      final asked = first['asked'];
      if (asked is String && asked.isNotEmpty && openAt != null) {
        await openAt!(chat, asked);
      } else if (chat.isNotEmpty) {
        await open(chat);
      }
    }
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

  Future<Map<String, dynamic>?> pushRegistration(String chat, String text) async {
    if (!supported || !_chatId.hasMatch(chat)) return null;
    final said = text.length > 80 ? text.substring(0, 80) : text;
    if (_ios) {
      final token = await channel.token();
      if (token == null || token.isEmpty) return null;
      return {
        'env': sandbox ? 'sandbox' : 'production',
        'token': token,
        'chat': chat,
        'text': said,
      };
    }
    final up = await channel.upState();
    if (up == null) return null;
    return {
      'env': 'unifiedpush',
      'endpoint': up['endpoint'],
      'keys': {'p256dh': up['p256dh'], 'auth': up['auth']},
      'chat': chat,
      'text': said,
    };
  }

  Future<bool> askPermission() async {
    if (!supported) return false;
    return channel.permission();
  }

  void viewingChat(String? conv) {
    viewing = conv;
    if (supported) unawaited(channel.viewing(conv));
  }

  String _convOf(String key) => _chatOf[key] ?? key;

  void pendingTurn(String conv, String eventId, {String? run}) {
    if (!supported) return;
    final key = run ?? conv;
    pending[key] = eventId;
    _chatOf[key] = conv;
    _timers.remove(key)?.cancel();
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
      _timers[key] = Timer(proactiveAfter, () {
        _timers.remove(key);
        if (pending[key] == eventId && enabled()) {
          unawaited(_register(conv, eventId, key: key));
        }
      });
    }
  }

  Future<void> settled(String conv,
      {required bool replied,
      String? run,
      String? asked,
      bool stopped = false,
      String? state}) async {
    if (!supported) return;
    final key = run ?? conv;
    _timers.remove(key)?.cancel();
    final eventId = pending.remove(key);
    _chatOf.remove(key);
    final handled = eventId != null &&
        (registered.remove(eventId) | _answered.remove(eventId));
    if (eventId != null &&
        !stopped &&
        enabled() &&
        !handled &&
        !(!background && viewing == conv)) {
      await _show(conv, replied: replied, asked: asked, state: state);
    }
    if (pending.isEmpty) await _stopWaiting();
  }

  Future<void> incoming(String conv,
      {required String title, required String body}) async {
    if (!supported || !enabled()) return;
    if (!background && viewing == conv) return;
    await channel.reply(
      chat: conv,
      title: title,
      body: body,
      channelName: t('Replies'),
    );
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

  static Map<String, String> stateText() => {
        'paused': t('Paused. Open the chat to carry on.'),
        'approval': t('Waiting for your approval.'),
        'stopped': t('Stopped.'),
        'failed': t('That request failed.'),
      };

  static Map<String, String> pushTexts() => {
        ...stateText(),
        'disabled':
            t('A server schedule was turned off after failing 3 times in a row.'),
        'title:done': t('Nymbot replied'),
        'title:paused': t('Nymbot replied'),
        'title:approval': t('Nymbot replied'),
        'title:failed': t('Nymbot could not finish that reply'),
      };

  static String headingFor(String? state, {required bool replied}) {
    if (state == 'failed' || state == 'stopped') {
      return t('Nymbot could not finish that reply');
    }
    if (state != null) return t('Nymbot replied');
    return replied
        ? t('Nymbot replied')
        : t('Nymbot could not finish that reply');
  }

  Future<void> _show(String conv,
      {required bool replied, String? asked, String? state}) async {
    final title = titleOf(conv).trim();
    final said = stateText()[state];
    await channel.reply(
      chat: conv,
      asked: asked,
      title: headingFor(state, replied: replied),
      body: said ?? (title.isEmpty ? t('Open the chat to read it.') : title),
      channelName: t('Replies'),
    );
  }

  Future<void> _registerAll() async {
    final work = [
      for (final e in pending.entries)
        if (!registered.contains(e.value))
          (conv: _convOf(e.key), eventId: e.value, key: e.key),
    ];
    if (work.isEmpty) return;
    final task = await channel.beginBackground();
    try {
      await Future.wait(
          [for (final w in work) _register(w.conv, w.eventId, key: w.key)]);
    } finally {
      if (task != null && task > 0) await channel.endBackground(task);
    }
  }

  Future<void> _register(String conv, String eventId, {String? key}) async {
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
    if (res == null || pending[key ?? conv] != eventId) return;
    if (res['done'] == true) {
      _answered.add(eventId);
      if (background || viewing != conv) await _show(conv, replied: true);
      return;
    }
    if (res['ok'] == true) registered.add(eventId);
  }
}
