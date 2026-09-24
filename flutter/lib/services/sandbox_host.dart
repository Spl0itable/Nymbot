import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config.dart';
import '../core/crypto/keys.dart';
import '../features/i18n/i18n.dart';
import 'sandbox_protocol.dart';

class SandboxHost extends ChangeNotifier {
  SandboxHost._();

  static final SandboxHost instance = SandboxHost._();

  static const runTimeout = Duration(seconds: 30);
  static const loadTimeout = Duration(minutes: 3);
  static const pdfTimeout = Duration(minutes: 3);
  static const pdfMaxBytes = 30 * 1024 * 1024;

  static Uri get pageUrl => Uri.parse('https://${NymbotConfig.apiHost}/app/sandbox.html');

  static bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static const pdfOwner = 'pdf';

  static String ownerOf(String? convId) => 'chat:${convId ?? ''}';

  static bool needsFresh(String? last, String next) => last != null && last != next;

  static bool allowedNavigation(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    return u.scheme == 'https' &&
        u.host == NymbotConfig.apiHost &&
        (u.path == '/app/sandbox.html' || u.path == '/app/sandbox') &&
        u.query.isEmpty;
  }

  WebViewController? _controller;
  Completer<void>? _ready;
  bool loadedOnce = false;
  final Queue<Future<void> Function()> _queue = Queue();
  bool _busy = false;
  String? _owner;
  final Map<String, void Function(SandboxEvent)> _listeners = {};

  WebViewController? get controller => _controller;

  Future<void> _start() async {
    if (_controller != null && _ready != null) return _ready!.future;
    final ready = Completer<void>();
    _ready = ready;
    final c = WebViewController();
    _controller = c;
    await c.setJavaScriptMode(JavaScriptMode.unrestricted);
    await c.addJavaScriptChannel('NymbotBridge', onMessageReceived: (m) {
      if (identical(_controller, c)) _onMessage(m.message);
    });
    await c.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (req) =>
          allowedNavigation(req.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
      onPageFinished: (_) => unawaited(_send(SandboxProtocol.encodePing())),
    ));
    notifyListeners();
    await c.loadRequest(pageUrl);
    return ready.future;
  }

  void _onMessage(String raw) {
    final event = SandboxProtocol.decode(raw);
    if (event == null) return;
    if (event is SandboxReady) {
      final r = _ready;
      if (r != null && !r.isCompleted) r.complete();
      return;
    }
    final listener = _listeners[event.id];
    if (listener != null) listener(event);
  }

  Future<void> _send(String json) async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.runJavaScript(SandboxProtocol.receiveScript(json));
    } catch (_) {}
  }

  void _discard() {
    final r = _ready;
    _controller = null;
    _ready = null;
    _owner = null;
    if (r != null && !r.isCompleted) {
      r.future.ignore();
      r.completeError(StateError('discarded'));
    }
    notifyListeners();
  }

  void _claim(String owner) {
    if (needsFresh(_owner, owner)) _discard();
    _owner = owner;
  }

  Future<T> _serial<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _queue.add(() async {
      try {
        done.complete(await job());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    _pump();
    return done.future;
  }

  void _pump() {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    final job = _queue.removeFirst();
    job().whenComplete(() {
      _busy = false;
      _pump();
    });
  }

  static String _id() => bytesToHex(randomBytes(8));

  Future<SandboxResult> run(
    String code,
    String language, {
    List<SandboxFile> files = const [],
    String? convId,
    Duration timeout = runTimeout,
    void Function()? onRunning,
  }) {
    if (!supported) {
      return Future.value(SandboxResult(error: t('Running code needs the Android or iOS app.')));
    }
    return _serial(() async {
      _claim(ownerOf(convId));
      final id = _id();
      final done = Completer<SandboxResult>();
      Timer? timer;
      void finish(SandboxResult r) {
        timer?.cancel();
        _listeners.remove(id);
        if (!done.isCompleted) done.complete(r);
      }

      timer = Timer(loadTimeout, () {
        _discard();
        finish(SandboxResult(error: t('The sandbox did not load. Check your connection and try again.')));
      });
      _listeners[id] = (event) {
        if (event is SandboxStatus && event.phase == 'running') {
          loadedOnce = true;
          onRunning?.call();
          timer?.cancel();
          timer = Timer(timeout, () {
            _discard();
            finish(SandboxResult(
                error: t('Stopped after {n} seconds. Code that runs on your device is given {n} seconds.',
                    {'n': timeout.inSeconds})));
          });
        } else if (event is SandboxDone) {
          finish(event.result);
        }
      };
      try {
        await _start();
        if (!done.isCompleted) {
          await _send(SandboxProtocol.encodeRun(id: id, code: code, language: language, files: files));
        }
      } catch (_) {
        finish(SandboxResult(error: t('The sandbox did not load. Check your connection and try again.')));
      }
      return done.future;
    });
  }

  Future<({List<String> pages, List<({String title, int page})> headings})> pdfText(Uint8List bytes) {
    if (!supported) throw StateError('unsupported');
    if (bytes.length > pdfMaxBytes) throw StateError('too large');
    return _serial(() async {
      _claim(pdfOwner);
      final id = _id();
      final done = Completer<SandboxPdfDone>();
      final timer = Timer(pdfTimeout, () {
        _discard();
        if (!done.isCompleted) done.completeError(TimeoutException('pdf'));
      });
      _listeners[id] = (event) {
        if (event is SandboxPdfDone && !done.isCompleted) done.complete(event);
      };
      try {
        await _start().timeout(loadTimeout);
        await _send(SandboxProtocol.encodePdf(id: id, base64: base64Encode(bytes)));
        final got = await done.future;
        if (got.error != null) throw StateError(got.error!);
        return (pages: got.pages, headings: got.headings);
      } finally {
        timer.cancel();
        _listeners.remove(id);
      }
    });
  }
}
