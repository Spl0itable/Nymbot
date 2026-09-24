import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme/theme.dart';
import 'features/gate_screen.dart';
import 'features/home_screen.dart';
import 'features/i18n/i18n.dart';
import 'features/signer_wait.dart';
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
  const NymbotApp({super.key, required this.controller, this.navigatorKey});

  final AppController controller;

  /// Null in the shipped app. The screenshot harness passes one so it can open
  /// the app's own sheets from outside the widget tree.
  final GlobalKey<NavigatorState>? navigatorKey;

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
    final palette = paletteFor(settings);
    final mode = themeModeFor(settings);

    return MaterialApp(
        title: 'Nymbot',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        scrollBehavior: const NymScrollBehavior(),
        theme: nymbotTheme(Brightness.light),
        darkTheme: nymbotTheme(Brightness.dark, palette: palette),
        themeMode: mode,
        themeAnimationDuration: settings.reduceMotion
            ? Duration.zero
            : kThemeAnimationDuration,
        locale: appLocale(),
        supportedLocales: appLocales(),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => appFrame(
            context,
            SignerWait(waiting: controller.identity.waiting, child: child),
            settings),
        home: const _Root(),
      );
  }
}

Widget appFrame(BuildContext context, Widget? child, AppSettings settings) {
  final media = MediaQuery.of(context);
  final scale = settings.fontScale <= 0 ? 1.0 : settings.fontScale;
  return MediaQuery(
    data: media.copyWith(
      disableAnimations: media.disableAnimations || settings.reduceMotion,
      textScaler: scale == 1
          ? media.textScaler
          : TextScaler.linear(media.textScaler.scale(14) / 14 * scale),
    ),
    child: Directionality(
      textDirection: I18n.isRtl ? TextDirection.rtl : TextDirection.ltr,
      child: child ?? const SizedBox.shrink(),
    ),
  );
}

Locale _localeOf(String code) {
  final parts = code.split(RegExp('[-_]'));
  return parts.length > 1 && parts[1].isNotEmpty
      ? Locale(parts[0], parts[1].toUpperCase())
      : Locale(parts[0]);
}

bool _materialSpeaks(Locale locale) =>
    GlobalMaterialLocalizations.delegate.isSupported(locale) &&
    GlobalCupertinoLocalizations.delegate.isSupported(locale);

List<Locale> appLocales() => [
      const Locale('en'),
      for (final option in I18n.available)
        if (option.code != 'en' && _materialSpeaks(_localeOf(option.code)))
          _localeOf(option.code),
    ];

Locale appLocale() {
  final locale = _localeOf(I18n.lang);
  return _materialSpeaks(locale) ? locale : const Locale('en');
}

NymbotPalette paletteFor(AppSettings settings) => switch (settings.theme) {
      ChatTheme.terminal => NymbotPalette.terminal,
      ChatTheme.midnight => NymbotPalette.midnight,
      _ => NymbotPalette.standard,
    };

ThemeMode themeModeFor(AppSettings settings) => switch (settings.theme) {
      ChatTheme.light => ThemeMode.light,
      ChatTheme.dark || ChatTheme.terminal || ChatTheme.midnight => ThemeMode.dark,
      ChatTheme.system => ThemeMode.system,
    };

class NymScrollBehavior extends MaterialScrollBehavior {
  const NymScrollBehavior();

  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
          BuildContext context) =>
      ScrollViewKeyboardDismissBehavior.onDrag;
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
