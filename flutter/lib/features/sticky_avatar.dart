import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class StickyAvatarScope extends StatelessWidget {
  const StickyAvatarScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        RenderStickyAvatar.refreshAll();
        return false;
      },
      child: child,
    );
  }
}

class StickyAvatar extends SingleChildRenderObjectWidget {
  const StickyAvatar({
    super.key,
    required this.group,
    this.first = true,
    this.last = true,
    this.inset = 6,
    required Widget super.child,
  });

  final Object group;
  final bool first;
  final bool last;
  final double inset;

  @override
  RenderStickyAvatar createRenderObject(BuildContext context) => RenderStickyAvatar(
        group: group,
        first: first,
        last: last,
        inset: inset,
        scrollable: Scrollable.maybeOf(context),
        sticky: !(MediaQuery.maybeDisableAnimationsOf(context) ?? false),
      );

  @override
  void updateRenderObject(BuildContext context, RenderStickyAvatar renderObject) {
    renderObject
      ..group = group
      ..first = first
      ..last = last
      ..inset = inset
      ..scrollable = Scrollable.maybeOf(context)
      ..sticky = !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }
}

class RenderStickyAvatar extends RenderProxyBox {
  RenderStickyAvatar({
    required Object group,
    required bool first,
    required bool last,
    required double inset,
    ScrollableState? scrollable,
    bool sticky = true,
  })  : _group = group,
        _sticky = sticky,
        _first = first,
        _last = last,
        _inset = inset,
        _scrollable = scrollable;

  static final Set<RenderStickyAvatar> _attached = {};
  static final Expando<Map<Object, Set<RenderStickyAvatar>>> _groups = Expando();

  static void refreshAll() {
    for (final r in _attached) {
      r.markNeedsPaint();
    }
  }

  Object _group;
  bool _first;
  bool _last;
  double _inset;
  bool _sticky;
  ScrollableState? _scrollable;
  ScrollPosition? _position;
  double? _avatarTop;

  bool get paintsAvatar => _avatarTop != null;

  set group(Object value) {
    if (value == _group) return;
    _leave();
    _group = value;
    _join();
  }

  set first(bool value) {
    if (value == _first) return;
    _first = value;
    _touchGroup();
  }

  set last(bool value) {
    if (value == _last) return;
    _last = value;
    _touchGroup();
  }

  set inset(double value) {
    if (value == _inset) return;
    _inset = value;
    _touchGroup();
  }

  set sticky(bool value) {
    if (value == _sticky) return;
    _sticky = value;
    _touchGroup();
  }

  set scrollable(ScrollableState? value) {
    if (value == _scrollable) return;
    _leave();
    _scrollable = value;
    _join();
  }

  @override
  bool get isRepaintBoundary => true;

  Set<RenderStickyAvatar>? get _members {
    final s = _scrollable;
    if (s == null) return null;
    return _groups[s]?[_group];
  }

  void _touchGroup() {
    final members = _members;
    if (members == null) {
      markNeedsPaint();
      return;
    }
    for (final m in members) {
      m.markNeedsPaint();
    }
  }

  void _join() {
    if (!attached) return;
    _attached.add(this);
    final s = _scrollable;
    if (s != null) {
      final map = _groups[s] ??= {};
      map.putIfAbsent(_group, () => {}).add(this);
      _position = s.position..addListener(markNeedsPaint);
    }
    _touchGroup();
  }

  void _leave() {
    _position?.removeListener(markNeedsPaint);
    _position = null;
    _attached.remove(this);
    final s = _scrollable;
    if (s == null) return;
    final map = _groups[s];
    final members = map?[_group];
    if (members == null) return;
    members.remove(this);
    if (members.isEmpty) {
      map!.remove(_group);
    } else {
      for (final m in members) {
        m.markNeedsPaint();
      }
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _join();
  }

  @override
  void detach() {
    _leave();
    super.detach();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final c = child;
    if (c == null) return constraints.smallest;
    return constraints.constrain(c.getDryLayout(constraints.loosen()));
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
    } else {
      c.layout(constraints.loosen(), parentUsesSize: true);
      size = constraints.constrain(c.size);
    }
    _touchGroup();
  }

  RenderBox? get _viewport {
    final s = _scrollable;
    if (s == null || !s.mounted) return null;
    if (s.position.axis != Axis.vertical) return null;
    final box = s.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box;
  }

  double? _topIn(RenderBox viewport) {
    if (!attached || !hasSize) return null;
    return MatrixUtils.transformPoint(getTransformTo(viewport), Offset.zero).dy;
  }

  double? _resolveTop() {
    final c = child;
    if (c == null || !c.hasSize) return null;
    final height = c.size.height;
    final resting = size.height - height;
    if (!_sticky) return _first ? 0 : null;
    final viewport = _viewport;
    final members = _members;
    if (viewport == null || members == null) return resting;
    final tops = <RenderStickyAvatar, double>{};
    for (final m in members) {
      final top = m._topIn(viewport);
      if (top != null) tops[m] = top;
    }
    final own = tops[this];
    if (own == null) return resting;
    var groupTop = double.negativeInfinity;
    var groupBottom = double.infinity;
    for (final e in tops.entries) {
      if (e.key._first) groupTop = e.value;
      if (e.key._last) groupBottom = e.value + e.key.size.height;
    }
    var y = viewport.size.height - _inset - height;
    if (y < groupTop) y = groupTop;
    if (y > groupBottom - height) y = groupBottom - height;
    RenderStickyAvatar? host;
    double? hostTop;
    RenderStickyAvatar? highest;
    double? highestTop;
    for (final e in tops.entries) {
      if (highestTop == null || e.value < highestTop) {
        highest = e.key;
        highestTop = e.value;
      }
      if (e.value <= y && (hostTop == null || e.value > hostTop)) {
        host = e.key;
        hostTop = e.value;
      }
    }
    host ??= highest;
    if (!identical(host, this)) return null;
    return y - own;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = child;
    _avatarTop = _resolveTop();
    final top = _avatarTop;
    if (c == null || top == null) return;
    context.paintChild(c, offset.translate(0, top));
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translate(0.0, _avatarTop ?? size.height - child.size.height);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => false;

  @override
  bool hitTestSelf(Offset position) => false;
}
