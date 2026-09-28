import 'package:flutter/material.dart';

Future<T?> showNymSheet<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool isScrollControlled = true,
}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => KeyboardInset(child: Builder(builder: builder)),
    );

Future<T?> showNymDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) =>
    showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (context) => KeyboardInset(child: Builder(builder: builder)),
    );

EdgeInsets textAreaScrollPadding(BuildContext context, int lines) =>
    EdgeInsets.fromLTRB(20, 20, 20,
        36 + MediaQuery.textScalerOf(context).scale(24) * (lines - 1));

class KeyboardInset extends StatelessWidget {
  const KeyboardInset({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: child,
      ),
    );
  }
}
