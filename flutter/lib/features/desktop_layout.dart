import 'package:flutter/widgets.dart';

const double kNarrowMaxWidth = 720;
const double kSidebarWidth = 288;

bool desktopLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width > kNarrowMaxWidth;

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
