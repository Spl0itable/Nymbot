import 'package:flutter/material.dart';

import 'core/theme/theme.dart';
import 'features/gate_screen.dart';
import 'features/home_screen.dart';
import 'features/i18n/i18n.dart';
import 'models/workspace.dart';
import 'state/app_controller.dart';
import 'features/i18n/language_select.dart';

/// Hands the one controller down without a state-management package: every
/// screen listens to the same [ChangeNotifier].
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child})
      : super(notifier: controller);

  /// Subscribes: the caller rebuilds whenever the controller notifies.
  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Reads without subscribing. Safe in `initState`, where registering a
  /// dependency is not.
  static AppController read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<AppScope>()!.widget
              as AppScope)
          .notifier!;
}

class NymbotApp extends StatelessWidget {
  const NymbotApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _app(context),
      ),
    );
  }

  Widget _app(BuildContext context) {
    final settings = controller.settings;
    final palette = switch (settings.theme) {
      ChatTheme.terminal => NymbotPalette.terminal,
      ChatTheme.midnight => NymbotPalette.midnight,
      _ => NymbotPalette.standard,
    };
    final mode = switch (settings.theme) {
      ChatTheme.light => ThemeMode.light,
      ChatTheme.dark || ChatTheme.terminal || ChatTheme.midnight => ThemeMode.dark,
      ChatTheme.system => ThemeMode.system,
    };

    return MaterialApp(
        title: 'Nymbot',
        debugShowCheckedModeBanner: false,
        theme: nymbotTheme(Brightness.light, fontScale: settings.fontScale),
        darkTheme: nymbotTheme(Brightness.dark,
            palette: palette, fontScale: settings.fontScale),
        themeMode: mode,
        // The packs are plain strings with no locale machinery behind them, so
        // the writing direction is set here rather than inferred from a Locale
        // the app never declares.
        builder: (context, child) => Directionality(
          textDirection: I18n.isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const _Root(),
      );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _entered = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.languageChosen && !app.signedIn && I18n.available.isNotEmpty) {
      return LanguageSelectScreen(onDone: () => setState(() {}));
    }
    if (!app.signedIn) return const GateScreen();
    if (!_entered) {
      _entered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => app.enter());
    }
    return const HomeScreen();
  }
}
