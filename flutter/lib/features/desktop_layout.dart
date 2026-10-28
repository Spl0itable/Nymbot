import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

const double kNarrowMaxWidth = 720;
const double kSidebarWidth = 288;

bool desktopLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width > kNarrowMaxWidth;

MouseTracker get mouseTracker => RendererBinding.instance.mouseTracker;

bool _mouseSeen = false;

bool pointerIsMouse(TargetPlatform platform, {required bool mouseSeen}) =>
    mouseSeen ||
    switch (platform) {
      TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
      _ => false,
    };

bool mousePointer() {
  if (!_mouseSeen && mouseTracker.mouseIsConnected) _mouseSeen = true;
  return pointerIsMouse(defaultTargetPlatform, mouseSeen: _mouseSeen);
}

@visibleForTesting
void forgetMouse() => _mouseSeen = false;

double paneWidth(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_PaneWidth>()?.width ??
    MediaQuery.sizeOf(context).width;

class PaneWidthScope extends StatelessWidget {
  const PaneWidthScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => _PaneWidth(
          width: box.hasBoundedWidth ? box.maxWidth : MediaQuery.sizeOf(context).width,
          child: child,
        ),
      );
}

class _PaneWidth extends InheritedWidget {
  const _PaneWidth({required this.width, required super.child});

  final double width;

  @override
  bool updateShouldNotify(_PaneWidth old) => old.width != width;
}
