import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'i18n/i18n.dart';
import 'nym_glyph.dart';

const double kDuoRailWidth = 56;
const double kDuoRailItemHeight = 44;
const double kDuoRailMaxTextScale = 1.3;
const double kDuoOuterStripBottom = 157;
const double kDuoInnerClusterBottom = 112;
const double kDuoLiveActivityGrowth = 35;
const double kDuoStatusBelowRegion = 87;
const double kDuoRailGap = 8;

final ValueNotifier<List<Rect>?> duoReportedRegions = ValueNotifier(null);

const MethodChannel _duoRegionsChannel = MethodChannel('ai.nymbot/duo_regions');

List<Rect>? duoParseRegions(Object? raw) {
  if (raw is! List) return null;
  return [
    for (final e in raw)
      if (e is List &&
          e.length == 4 &&
          e.every((v) => v is num && v.isFinite) &&
          (e[2] as num) > 0 &&
          (e[3] as num) > 0)
        Rect.fromLTWH((e[0] as num).toDouble(), (e[1] as num).toDouble(),
            (e[2] as num).toDouble(), (e[3] as num).toDouble()),
  ];
}

void duoListenToBridge() {
  if (defaultTargetPlatform != TargetPlatform.iOS) return;
  _duoRegionsChannel.setMethodCallHandler((call) async {
    if (call.method == 'regions') {
      duoReportedRegions.value = duoParseRegions(call.arguments);
    }
  });
  _duoRegionsChannel.invokeMethod<Object?>('current').then((raw) {
    final rects = duoParseRegions(raw);
    if (rects != null) duoReportedRegions.value = rects;
  }, onError: (Object _) {});
}

double _duoBareBottom(Size size) =>
    size.width < 600 ? kDuoOuterStripBottom : kDuoInnerClusterBottom;

List<Rect> duoMergeReported(
    List<Rect> fallback, List<Rect>? reported, Size size) {
  if (reported == null || reported.isEmpty) return fallback;
  final bare = _duoBareBottom(size);
  return [
    for (final f in fallback)
      _duoReportedOver(f, reported, bare, size.height) ?? f,
  ];
}

Rect? _duoReportedOver(
    Rect fallback, List<Rect> reported, double bare, double height) {
  double? bottom;
  for (final r in reported) {
    if (r.right > fallback.left &&
        r.left < fallback.right &&
        r.top < fallback.bottom) {
      bottom = math.max(bottom ?? 0, r.bottom);
    }
  }
  if (bottom == null) return null;
  final reach = bottom >= bare
      ? bottom
      : math.max(bare, bottom + kDuoStatusBelowRegion);
  return Rect.fromLTRB(
      fallback.left, fallback.top, fallback.right, math.min(height, reach));
}

class _DuoReported extends InheritedNotifier<ValueNotifier<List<Rect>?>> {
  const _DuoReported({required super.notifier, required super.child});
}

class DuoRegions extends InheritedWidget {
  const DuoRegions({super.key, required this.rects, required super.child});

  final List<Rect> rects;

  static List<Rect> of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DuoRegions>();
    if (scope != null) return scope.rects;
    final size = MediaQuery.sizeOf(context);
    final reported = context
            .dependOnInheritedWidgetOfExactType<_DuoReported>()
            ?.notifier
            ?.value ??
        duoReportedRegions.value;
    return duoMergeReported(
        fromInsets(size, MediaQuery.viewPaddingOf(context), defaultTargetPlatform),
        reported,
        size);
  }

  static List<Rect> fromInsets(
      Size size, EdgeInsets viewPadding, TargetPlatform platform) {
    if (platform != TargetPlatform.iOS) return const [];
    if (viewPadding.right - viewPadding.left < 40 || size.isEmpty) {
      return const [];
    }
    final bottom =
        math.min(size.height, _duoBareBottom(size) + kDuoLiveActivityGrowth);
    return [
      Rect.fromLTRB(size.width - viewPadding.right, 0, size.width, bottom),
    ];
  }

  @override
  bool updateShouldNotify(DuoRegions oldWidget) =>
      !listEquals(oldWidget.rects, rects);
}

Rect? duoOuterStrip(List<Rect> rects, Size size) {
  if (size.width >= 600 || size.height <= size.width) return null;
  for (final r in rects) {
    if (r.left > size.width * 0.6 && r.top < 80 && r.height > r.width) {
      return r;
    }
  }
  return null;
}

double duoClearance(Rect box, List<Rect> rects) {
  var need = 0.0;
  for (final o in rects) {
    if (o.top < box.bottom &&
        o.bottom > box.top &&
        o.left < box.right &&
        o.right > box.left) {
      need = math.max(need, box.right - o.left);
    }
  }
  return need;
}

class DuoClear extends StatefulWidget {
  const DuoClear({super.key, required this.child});

  final Widget child;

  @override
  State<DuoClear> createState() => _DuoClearState();
}

class _DuoClearState extends State<DuoClear> {
  double _pad = 0;
  bool _armed = false;
  List<Rect> _rects = const [];

  void _arm() {
    if (_armed) return;
    _armed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _armed = false;
      _measure();
    });
  }

  void _measure() {
    if (!mounted || _rects.isEmpty) return;
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      final need =
          duoClearance(box.localToGlobal(Offset.zero) & box.size, _rects);
      if ((need - _pad).abs() > 0.5) setState(() => _pad = need);
    }
    _arm();
  }

  @override
  Widget build(BuildContext context) {
    _rects = DuoRegions.of(context);
    MediaQuery.sizeOf(context);
    if (_rects.isEmpty) {
      _pad = 0;
    } else {
      _arm();
    }
    return Padding(
      padding: EdgeInsets.only(right: _pad),
      child: widget.child,
    );
  }
}

class DuoRailFrame extends StatelessWidget {
  const DuoRailFrame({
    super.key,
    required this.strip,
    required this.rail,
    required this.child,
  });

  final Rect? strip;
  final WidgetBuilder rail;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final s = strip;
    final column =
        s == null ? 0.0 : math.max(kDuoRailWidth, media.size.width - s.left);
    final inset = s == null ? 0.0 : math.max(0.0, (s.width - kDuoRailWidth) / 2);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: MediaQuery(
            data: s == null
                ? media
                : media
                    .removePadding(removeRight: true)
                    .removeViewPadding(removeRight: true),
            child: child,
          ),
        ),
        SizedBox(
          key: const ValueKey('duo-rail-column'),
          width: column,
          child: s == null
              ? null
              : Material(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Padding(
                    padding: EdgeInsets.only(top: s.bottom + kDuoRailGap, left: inset),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: kDuoRailWidth,
                        child: rail(context),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class DuoRail extends StatelessWidget {
  const DuoRail({super.key, required this.children, this.pinned});

  final List<Widget> children;
  final Widget? pinned;

  static Widget _slot(Widget child) => child is DuoRailDivider
      ? Center(child: child)
      : Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
                minHeight: kDuoRailItemHeight, minWidth: kDuoRailWidth),
            child: Center(child: child),
          ),
        );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = 8.0 + math.max(media.viewInsets.bottom, media.padding.bottom);
    final end = pinned;
    final list = ListView(
      key: end == null ? const ValueKey('duo-rail') : null,
      padding: EdgeInsets.only(bottom: end == null ? bottom : 0),
      children: [for (final child in children) _slot(child)],
    );
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kDuoRailMaxTextScale,
      child: FocusTraversalGroup(
        child: end == null
            ? list
            : Column(
                key: const ValueKey('duo-rail'),
                children: [
                  Expanded(child: list),
                  _slot(end),
                  SizedBox(height: bottom),
                ],
              ),
      ),
    );
  }
}

class DuoRailDivider extends StatelessWidget {
  const DuoRailDivider({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 32,
        height: 5,
        child: Divider(height: 5),
      );
}

class DuoRailButton extends StatelessWidget {
  const DuoRailButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.semanticsLabel,
    this.toggled,
    this.caption,
    this.badge,
    this.dimmed = false,
  });

  final Widget icon;
  final String label;
  final String? semanticsLabel;
  final VoidCallback? onTap;
  final bool? toggled;
  final String? caption;
  final String? badge;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final on = toggled ?? false;
    final accent = theme.colorScheme.secondary;
    Widget face = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            IconTheme.merge(
              data: IconThemeData(color: on ? accent : null, size: 20),
              child: icon,
            ),
            if (badge != null)
              Positioned(
                right: -10,
                top: -6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                        fontSize: 10,
                        height: 1.4,
                        color: theme.colorScheme.onPrimary),
                  ),
                ),
              ),
          ],
        ),
        if (caption != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(fontSize: 10, color: theme.hintColor),
            ),
          ),
      ],
    );
    if (dimmed) face = Opacity(opacity: 0.45, child: face);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        toggled: toggled,
        label: semanticsLabel ?? label,
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 48,
            constraints: const BoxConstraints(minHeight: kDuoRailItemHeight),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? accent.withValues(alpha: 0.16) : null,
              borderRadius: BorderRadius.circular(12),
              border: toggled == null
                  ? null
                  : Border.all(
                      color: on
                          ? accent.withValues(alpha: 0.6)
                          : theme.dividerColor),
            ),
            child: face,
          ),
        ),
      ),
    );
  }
}

String shortCredit(num? value) {
  if (value == null) return '…';
  final n = value.toDouble();
  final sign = n < 0 ? '-' : '';
  final a = n.abs();
  String scaled(double v, String unit) {
    final tenths = (v * 10).floor() / 10;
    final body = v < 10
        ? (tenths == tenths.roundToDouble()
            ? tenths.toStringAsFixed(0)
            : tenths.toStringAsFixed(1))
        : v.floor().toString();
    return '$sign$body$unit';
  }

  if (a >= 1e9) return scaled(a / 1e9, 'B');
  if (a >= 1e6) return scaled(a / 1e6, 'M');
  if (a >= 1e3) return scaled(a / 1e3, 'k');
  if (a >= 10 || a == a.roundToDouble()) return '$sign${a.floor()}';
  return '$sign${(a * 10).floor() / 10}';
}

class DuoSheetEntry {
  DuoSheetEntry(this.close);

  final VoidCallback close;
}

class DuoSheets extends ChangeNotifier {
  final List<DuoSheetEntry> _entries = [];
  bool _pending = false;

  List<DuoSheetEntry> get value => List.unmodifiable(_entries);

  void add(DuoSheetEntry entry) {
    if (_entries.contains(entry)) return;
    _entries.add(entry);
    _schedule();
  }

  void remove(DuoSheetEntry entry) {
    if (_entries.remove(entry)) _schedule();
  }

  void _schedule() {
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}

final DuoSheets duoSheets = DuoSheets();

class DuoSheetMark extends StatefulWidget {
  const DuoSheetMark({super.key, required this.child});

  final Widget child;

  @override
  State<DuoSheetMark> createState() => _DuoSheetMarkState();
}

class _DuoSheetMarkState extends State<DuoSheetMark> {
  late final DuoSheetEntry _entry = DuoSheetEntry(_close);

  void _close() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    Navigator.of(context).maybePop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (ModalRoute.of(context)?.isActive ?? true) {
      duoSheets.add(_entry);
    } else {
      duoSheets.remove(_entry);
    }
  }

  @override
  void dispose() {
    duoSheets.remove(_entry);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class DuoSheetRailHost extends StatefulWidget {
  const DuoSheetRailHost({super.key, required this.child});

  final Widget child;

  @override
  State<DuoSheetRailHost> createState() => _DuoSheetRailHostState();
}

class _DuoSheetRailHostState extends State<DuoSheetRailHost> {
  final FocusNode _rail = FocusNode(
      debugLabel: 'duo-sheet-rail', skipTraversal: true, canRequestFocus: false);
  late final OverlayEntry _entry =
      OverlayEntry(builder: (context) => _DuoSheetRail(host: _rail));
  late final Map<Type, Action<Intent>> _tabs = {
    NextFocusIntent: _DuoSheetNextFocus(this),
    PreviousFocusIntent: _DuoSheetPreviousFocus(this),
  };
  FocusScopeNode? _content;

  bool? _tab(bool forward) {
    final node = primaryFocus;
    if (node == null || node.context == null) return null;
    final rail = [
      for (final n in _rail.traversalDescendants)
        if (n is! FocusScopeNode && n.context != null) n
    ]..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    if (rail.isEmpty) return null;
    if (node.ancestors.contains(_rail)) {
      final next = rail.indexOf(node) + (forward ? 1 : -1);
      if (next >= 0 && next < rail.length) {
        FocusTraversalPolicy.defaultTraversalRequestFocusCallback(rail[next]);
        return true;
      }
      final scope = _content;
      if (scope == null || scope.context == null || !scope.canRequestFocus) {
        return null;
      }
      final policy = FocusTraversalGroup.maybeOfNode(scope);
      final target = forward
          ? policy?.findFirstFocus(scope, ignoreCurrentFocus: true)
          : policy?.findLastFocus(scope, ignoreCurrentFocus: true);
      if (target == null || target == scope) return null;
      FocusTraversalPolicy.defaultTraversalRequestFocusCallback(target);
      return true;
    }
    final policy = FocusTraversalGroup.maybeOfNode(node);
    final edge = forward
        ? policy?.findLastFocus(node, ignoreCurrentFocus: true)
        : policy?.findFirstFocus(node, ignoreCurrentFocus: true);
    if (edge != node || node.nearestScope == null) return null;
    _content = node.nearestScope;
    FocusTraversalPolicy.defaultTraversalRequestFocusCallback(
        forward ? rail.first : rail.last);
    return true;
  }

  @override
  void dispose() {
    _rail.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    duoListenToBridge();
  }

  @override
  Widget build(BuildContext context) => _DuoReported(
        notifier: duoReportedRegions,
        child: Actions(
          actions: _tabs,
          child: Stack(
            fit: StackFit.passthrough,
            textDirection: TextDirection.ltr,
            children: [
              widget.child,
              Positioned.fill(child: Overlay(initialEntries: [_entry])),
            ],
          ),
        ),
      );
}

class _DuoSheetNextFocus extends NextFocusAction {
  _DuoSheetNextFocus(this.host);

  final _DuoSheetRailHostState host;

  @override
  bool invoke(NextFocusIntent intent) => host._tab(true) ?? super.invoke(intent);
}

class _DuoSheetPreviousFocus extends PreviousFocusAction {
  _DuoSheetPreviousFocus(this.host);

  final _DuoSheetRailHostState host;

  @override
  bool invoke(PreviousFocusIntent intent) =>
      host._tab(false) ?? super.invoke(intent);
}

class _DuoSheetRail extends StatelessWidget {
  const _DuoSheetRail({required this.host});

  final FocusNode host;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final strip = duoOuterStrip(DuoRegions.of(context), media.size);
    return ListenableBuilder(
      listenable: duoSheets,
      builder: (context, _) {
        final sheets = duoSheets.value;
        if (strip == null || sheets.isEmpty) return const SizedBox.shrink();
        final column = math.max(kDuoRailWidth, media.size.width - strip.left);
        final inset = math.max(0.0, (strip.width - kDuoRailWidth) / 2);
        return Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            key: const ValueKey('duo-sheet-rail'),
            width: column,
            height: media.size.height,
            child: Focus(
              focusNode: host,
              child: Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Padding(
                  padding: EdgeInsets.only(top: strip.bottom + kDuoRailGap, left: inset),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: kDuoRailWidth,
                      child: DuoRail(children: [
                        DuoRailButton(
                          key: const ValueKey('duo-sheet-close'),
                          icon: const NymGlyph('close', size: 20),
                          label: t('Close'),
                          onTap: sheets.last.close,
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
