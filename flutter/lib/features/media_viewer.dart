import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/utils/safe_url.dart';
import '../models/workspace.dart';
import '../services/media_cache.dart';
import 'i18n/i18n.dart';
import 'markdown_body.dart';
import 'nym_glyph.dart';

@immutable
class ViewerItem {
  const ViewerItem({
    required this.image,
    this.url,
    this.source,
    this.bytes,
    this.name,
    this.label = '',
  });

  factory ViewerItem.network(String url, {String label = ''}) {
    final source = MarkdownBody.imageSource(url) ?? url;
    return ViewerItem(
      image: CachedMediaImage(source),
      url: url,
      source: source,
      label: label,
    );
  }

  factory ViewerItem.memory(Uint8List bytes,
          {String? name, String label = ''}) =>
      ViewerItem(
          image: MemoryImage(bytes), bytes: bytes, name: name, label: label);

  static final Expando<Uint8List> _decoded = Expando<Uint8List>();

  static Uint8List? attachmentBytes(Attachment a) {
    if (a.kind != AttachmentKind.image) return null;
    final held = a.bytes;
    if (held != null && held.isNotEmpty) return held;
    final cached = _decoded[a];
    if (cached != null) return cached;
    final b64 = a.bytesBase64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      final out = base64Decode(b64);
      _decoded[a] = out;
      return out;
    } catch (_) {
      return null;
    }
  }

  static ViewerItem? attachment(Attachment a) {
    if (a.kind != AttachmentKind.image) return null;
    final bytes = attachmentBytes(a);
    if (bytes != null) {
      return ViewerItem.memory(bytes, name: a.name, label: a.name);
    }
    final url = a.url;
    if (url != null && MarkdownBody.imageSource(url) != null) {
      final item = ViewerItem.network(url, label: a.name);
      return ViewerItem(
          image: item.image,
          url: url,
          source: item.source,
          name: a.name,
          label: a.name);
    }
    return null;
  }

  final ImageProvider image;
  final String? url;
  final String? source;
  final Uint8List? bytes;
  final String? name;
  final String label;
}

class ViewableImage extends StatelessWidget {
  const ViewableImage({super.key, required this.item, required this.child});

  final ViewerItem item;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: t('Open image full screen'),
      child: MouseRegion(
        cursor: SystemMouseCursors.zoomIn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => MediaViewer.openFrom(context, this),
          child: child,
        ),
      ),
    );
  }
}

class MediaViewerScope extends StatefulWidget {
  const MediaViewerScope({super.key, required this.child});

  final Widget child;

  static bool present(BuildContext context) =>
      context.findAncestorStateOfType<_MediaViewerScopeState>() != null;

  @override
  State<MediaViewerScope> createState() => _MediaViewerScopeState();
}

class _MediaViewerScopeState extends State<MediaViewerScope> {
  List<ViewableImage> collect() {
    final out = <ViewableImage>[];
    void visit(Element e) {
      final w = e.widget;
      if (w is ViewableImage) out.add(w);
      e.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return out;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

String _sniffMime(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return 'image/gif';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return '';
}

String viewerFileName(ViewerItem item, String mime) {
  const byType = {
    'image/png': 'png',
    'image/jpeg': 'jpg',
    'image/gif': 'gif',
    'image/webp': 'webp',
  };
  final ext = byType[mime];
  final hasExt = RegExp(r'\.[a-z0-9]{2,5}$', caseSensitive: false);
  final name = (item.name ?? '').replaceAll(RegExp(r'[/\\]'), '_').trim();
  if (name.isNotEmpty) {
    if (hasExt.hasMatch(name) || ext == null) return name;
    return '$name.$ext';
  }
  final url = item.url;
  if (url != null && url.isNotEmpty && !url.startsWith('data:')) {
    final named = MediaBlock.fileName(url, mime);
    if (hasExt.hasMatch(named) || ext == null) return named;
    return '$named.$ext';
  }
  return 'nymbot.${ext ?? 'png'}';
}

class MediaViewer extends StatefulWidget {
  const MediaViewer(
      {super.key, required this.items, required this.initialIndex});

  final List<ViewerItem> items;
  final int initialIndex;

  static Future<void> open(
      BuildContext context, List<ViewerItem> items, int index) {
    if (items.isEmpty) return Future.value();
    final at = index.clamp(0, items.length - 1);
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 150),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (_, _, _) =>
            MediaViewer(items: items, initialIndex: at),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  static Future<void> openFrom(BuildContext context, ViewableImage tapped) {
    final scope = context.findAncestorStateOfType<_MediaViewerScopeState>();
    final all = scope?.collect() ?? const <ViewableImage>[];
    final at = all.indexWhere((w) => identical(w, tapped));
    if (at < 0) return open(context, [tapped.item], 0);
    return open(context, [for (final w in all) w.item], at);
  }

  static Future<void> openAttachments(
      BuildContext context, List<Attachment> all, Attachment tapped) {
    final items = <ViewerItem>[];
    var at = 0;
    for (final a in all) {
      final item = ViewerItem.attachment(a);
      if (item == null) continue;
      if (identical(a, tapped)) at = items.length;
      items.add(item);
    }
    return open(context, items, at);
  }

  static Future<Uint8List> bytesOf(ViewerItem item) async {
    final held = item.bytes;
    if (held != null) return held;
    final src = item.source ?? item.url;
    if (src == null) throw StateError('nothing to save');
    return MediaCache.instance.load<Uint8List>(src, (b) async => b);
  }

  static Future<bool> save(ViewerItem item, {Rect? origin}) async {
    try {
      final bytes = await bytesOf(item);
      final name = viewerFileName(item, _sniffMime(bytes));
      final dir = await Directory.systemTemp.createTemp('nymbot-save');
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      final mime = _sniffMime(bytes);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, name: name, mimeType: mime.isEmpty ? null : mime)],
        sharePositionOrigin: origin,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer>
    with SingleTickerProviderStateMixin {
  static const double _minScale = 1;
  static const double _maxScale = 5;

  late int _index = widget.initialIndex;

  double _scale = 1, _tx = 0, _ty = 0;
  double _startScale = 1, _startTx = 0, _startTy = 0;
  Offset _startFocal = Offset.zero;
  String? _mode;
  double? _fade;
  bool _fadingOut = false;
  bool _saving = false;
  Timer? _navTimer;

  final GlobalKey _imgKey = GlobalKey();
  final GlobalKey _saveKey = GlobalKey();
  late final AnimationController _anim = AnimationController(vsync: this);

  bool get _many => widget.items.length > 1;

  @override
  void dispose() {
    _navTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  void _animateTo(double scale, double tx, double ty, Duration duration) {
    _anim.stop();
    final s0 = _scale, x0 = _tx, y0 = _ty;
    final curve = CurvedAnimation(parent: _anim, curve: Curves.ease);
    void tick() {
      if (!mounted) return;
      setState(() {
        final v = curve.value;
        _scale = s0 + (scale - s0) * v;
        _tx = x0 + (tx - x0) * v;
        _ty = y0 + (ty - y0) * v;
      });
    }

    curve.addListener(tick);
    _anim.duration = duration;
    _anim.forward(from: 0).whenCompleteOrCancel(() {
      curve.removeListener(tick);
      curve.dispose();
    });
  }

  void _reset({required bool animate}) {
    setState(() => _fade = null);
    if (animate) {
      _animateTo(1, 0, 0, const Duration(milliseconds: 250));
    } else {
      _anim.stop();
      setState(() {
        _scale = 1;
        _tx = 0;
        _ty = 0;
      });
    }
  }

  (double, double) _clampedPan() {
    final box = _imgKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return (_tx, _ty);
    final maxX = math.max(0.0, (box.size.width * _scale - box.size.width) / 2);
    final maxY =
        math.max(0.0, (box.size.height * _scale - box.size.height) / 2);
    return (_tx.clamp(-maxX, maxX), _ty.clamp(-maxY, maxY));
  }

  void _baseline(Offset focal, int pointers) {
    _startScale = _scale;
    _startTx = _tx;
    _startTy = _ty;
    _startFocal = focal;
    _mode = pointers >= 2 ? 'pinch' : (_scale > _minScale ? 'pan' : 'swipe');
  }

  void _onScaleStart(ScaleStartDetails d) {
    _anim.stop();
    _baseline(d.focalPoint, d.pointerCount);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final pinch = d.pointerCount >= 2;
    if (_mode == null || pinch != (_mode == 'pinch')) {
      _baseline(d.focalPoint, d.pointerCount);
    }
    final delta = d.focalPoint - _startFocal;
    setState(() {
      if (_mode == 'pinch') {
        _scale = (_startScale * d.scale).clamp(_minScale, _maxScale);
        _tx = _startTx + delta.dx;
        _ty = _startTy + delta.dy;
      } else if (_mode == 'pan') {
        _tx = _startTx + delta.dx;
        _ty = _startTy + delta.dy;
      } else {
        _tx = delta.dx;
        _ty = delta.dy;
        final progress = math.min(1.0, Offset(_tx, _ty).distance / 300);
        _fade = 1 - progress;
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final mode = _mode;
    if (d.pointerCount == 0) _mode = null;
    if (mode == 'swipe') {
      final horizontal = _tx.abs() > _ty.abs();
      if (_many && horizontal) {
        if (_tx.abs() > 60 && _navigate(_tx < 0 ? 1 : -1)) return;
        _reset(animate: true);
        return;
      }
      final travel = _many ? _ty.abs() : Offset(_tx, _ty).distance;
      if (travel > 100) {
        _close();
        return;
      }
      _reset(animate: true);
    } else if (mode == 'pinch' || mode == 'pan') {
      if (_scale <= _minScale) {
        _reset(animate: true);
      } else {
        final (cx, cy) = _clampedPan();
        _animateTo(_scale, cx, cy, const Duration(milliseconds: 250));
      }
    }
  }

  void _onDoubleTap() {
    if (_scale > _minScale) {
      _reset(animate: true);
    } else {
      _animateTo(2.5, _tx, _ty, const Duration(milliseconds: 250));
    }
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final next = (_scale * math.exp(-e.scrollDelta.dy * 0.002))
        .clamp(_minScale, _maxScale);
    if (next == _scale) return;
    if (next <= _minScale) {
      _reset(animate: false);
      return;
    }
    setState(() => _scale = next);
    final (cx, cy) = _clampedPan();
    setState(() {
      _tx = cx;
      _ty = cy;
    });
  }

  bool _navigate(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.items.length) return false;
    setState(() {
      _fadingOut = true;
      _fade = null;
    });
    _animateTo(1, 0, 0, const Duration(milliseconds: 180));
    _navTimer?.cancel();
    _navTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      setState(() {
        _index = next;
        _fadingOut = false;
      });
    });
    return true;
  }

  Future<void> _save() async {
    if (_saving) return;
    final item = widget.items[_index];
    final messenger = ScaffoldMessenger.of(context);
    final box = _saveKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    setState(() => _saving = true);
    final done = await MediaViewer.save(item, origin: origin);
    if (!done) {
      final url = item.url;
      if (url != null && url.startsWith('http') && await launchSafeUrl(url)) {
        messenger.showSnackBar(SnackBar(
            content:
                Text(t('Opened it outside the app — save it from there.'))));
      } else {
        messenger.showSnackBar(
            SnackBar(content: Text(t('That file could not be saved.'))));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Widget _chip({
    required Key key,
    required String label,
    required Widget glyph,
    required VoidCallback? onTap,
    double side = 40,
  }) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: Material(
          key: key,
          color: const Color(0xCC141423),
          shape: const CircleBorder(side: BorderSide(color: Color(0x1FFFFFFF))),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
                width: side, height: side, child: Center(child: glyph)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_index];
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _navigate(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _navigate(1),
      },
      child: Focus(
        autofocus: true,
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: t('Image viewer'),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    key: const ValueKey('viewer-backdrop'),
                    onTap: _close,
                    behavior: HitTestBehavior.opaque,
                    child: ColoredBox(
                      color:
                          Colors.black.withValues(alpha: 0.85 * (_fade ?? 1)),
                    ),
                  ),
                ),
                Center(
                  child: Listener(
                    onPointerSignal: _onPointerSignal,
                    child: GestureDetector(
                      key: const ValueKey('viewer-image'),
                      onTap: _scale > _minScale ? null : _close,
                      onDoubleTap: _onDoubleTap,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onScaleEnd: _onScaleEnd,
                      child: Transform.translate(
                        offset: Offset(_tx, _ty),
                        child: Transform.scale(
                          scale: _scale,
                          child: AnimatedOpacity(
                            opacity: _fadingOut ? 0 : 1,
                            duration: const Duration(milliseconds: 120),
                            curve: Curves.linear,
                            child: Container(
                              key: _imgKey,
                              constraints: BoxConstraints(
                                maxWidth: screen.width * 0.9,
                                maxHeight: screen.height * 0.9,
                              ),
                              decoration: BoxDecoration(
                                border:
                                    Border.all(color: const Color(0x1FFFFFFF)),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x80000000),
                                    offset: Offset(0, 8),
                                    blurRadius: 32,
                                  ),
                                ],
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Semantics(
                                image: true,
                                label: item.label,
                                child: Image(
                                  key: ValueKey('viewer-picture-$_index'),
                                  image: item.image,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  loadingBuilder: (c, child, p) => p == null
                                      ? child
                                      : SizedBox(
                                          width: 64,
                                          height: 64,
                                          child: Center(
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white70,
                                              value: (p.expectedTotalBytes ??
                                                          0) >
                                                      0
                                                  ? p.cumulativeBytesLoaded /
                                                      p.expectedTotalBytes!
                                                  : null,
                                            ),
                                          ),
                                        ),
                                  errorBuilder: (_, _, _) => const SizedBox(
                                    width: 96,
                                    height: 96,
                                    child: NymGlyph('picture',
                                        size: 40, color: Colors.white54),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_many) ...[
                  if (_index > 0)
                    Positioned(
                      left: 20 + pad.left,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _chip(
                          key: const ValueKey('viewer-prev'),
                          label: t('Previous image'),
                          glyph: const NymGlyph('chevron',
                              size: 22, color: Colors.white, quarterTurns: 1),
                          onTap: () => _navigate(-1),
                          side: 44,
                        ),
                      ),
                    ),
                  if (_index < widget.items.length - 1)
                    Positioned(
                      right: 20 + pad.right,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _chip(
                          key: const ValueKey('viewer-next'),
                          label: t('Next image'),
                          glyph: const NymGlyph('chevron',
                              size: 22, color: Colors.white, quarterTurns: 3),
                          onTap: () => _navigate(1),
                          side: 44,
                        ),
                      ),
                    ),
                  Positioned(
                    bottom: 28 + pad.bottom,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          t('{n} of {total}',
                              {'n': _index + 1, 'total': widget.items.length}),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ],
                Positioned(
                  top: 20 + pad.top,
                  right: 70 + pad.right,
                  child: KeyedSubtree(
                    key: _saveKey,
                    child: _chip(
                      key: const ValueKey('viewer-save'),
                      label: t('Save this file'),
                      glyph: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const NymGlyph('save',
                              size: 20, color: Colors.white),
                      onTap: _saving ? null : _save,
                    ),
                  ),
                ),
                Positioned(
                  top: 20 + pad.top,
                  right: 20 + pad.right,
                  child: _chip(
                    key: const ValueKey('viewer-close'),
                    label: t('Close'),
                    glyph:
                        const NymGlyph('close', size: 20, color: Colors.white),
                    onTap: _close,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AttachmentThumb extends StatelessWidget {
  const AttachmentThumb({super.key, required this.attachment, this.size = 32});

  final Attachment attachment;
  final double size;

  @override
  Widget build(BuildContext context) {
    final item = ViewerItem.attachment(attachment);
    if (item == null) return SizedBox(width: size, height: size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image(
        image: ResizeImage.resizeIfNeeded((size * 3).round(), null, item.image),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => SizedBox(
          width: size,
          height: size,
          child: NymGlyph('picture', size: size * 0.5),
        ),
      ),
    );
  }
}
