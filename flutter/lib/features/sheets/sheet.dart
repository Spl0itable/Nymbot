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
      builder: builder,
    );
