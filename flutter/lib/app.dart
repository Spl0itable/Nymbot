import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme/theme.dart';
import 'features/ai_consent.dart';
import 'features/duo_rail.dart';
import 'features/gate_screen.dart';
import 'features/home_screen.dart';
import 'features/i18n/i18n.dart';
import 'features/signer_wait.dart';
import 'models/workspace.dart';
import 'services/nostr/signer_links.dart';
import 'state/app_controller.dart';
import 'features/i18n/language_select.dart';

/// Hands the one controller down; every screen listens to the same [ChangeNotifier].
class AppScope extends InheritedWidget {
  const AppScope({super.key, required AppController controller, required super.child})
      : notifier = controller;

  final AppController notifier;

  /// Subscribes the caller to rebuilds.
  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier;

  static AppController watch(
      BuildContext context, List<Object?> Function(AppController app) pick) {
    final scope = context.getElementForInheritedWidgetOfExactType<AppScope>()!;
    final app = (scope.widget as AppScope).notifier;
    context.dependOnInheritedElement(scope, aspect: _AppPick(pick, pick(app)));
    return app;
  }

  /// Reads without subscribing; safe in `initState`.
  static AppController read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<AppScope>()!.widget
              as AppScope)
          .notifier;

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      !identical(oldWidget.notifier, notifier);

  @override
  InheritedElement createElement() => _AppScopeElement(this);
}

class _AppPick {
  const _AppPick(this.pick, this.seen);
  final List<Object?> Function(AppController app) pick;
  final List<Object?> seen;
}

class _AppScopeElement extends InheritedElement {
  _AppScopeElement(AppScope super.widget);

  static final Object _all = Object();
  bool _dirty = false;

  AppController get _app => (widget as AppScope).notifier;

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    _app.addListener(_changed);
  }

  @override
  void update(AppScope newWidget) {
    final old = _app;
    if (!identical(old, newWidget.notifier)) {
      old.removeListener(_changed);
      newWidget.notifier.addListener(_changed);
    }
    super.update(newWidget);
  }

  @override
  void unmount() {
    _app.removeListener(_changed);
    super.unmount();
  }

  void _changed() {
    _dirty = true;
    markNeedsBuild();
  }

  @override
  Widget build() {
    if (_dirty) {
      _dirty = false;
      notifyClients(widget as AppScope);
    }
    return super.build();
  }

  @override
  void updateDependencies(Element dependent, Object? aspect) {
    final had = getDependencies(dependent);
    if (aspect is! _AppPick) {
      setDependencies(dependent, _all);
      return;
    }
    if (identical(had, _all)) return;
    setDependencies(dependent, <_AppPick>[
      if (had is List<_AppPick>)
        for (final p in had)
          if (!identical(p.pick, aspect.pick)) p,
      aspect,
    ]);
  }

  @override
  void notifyDependent(AppScope oldWidget, Element dependent) {
    final had = getDependencies(dependent);
    if (had is List<_AppPick> && identical(oldWidget.notifier, _app)) {
      final app = _app;
      if (!had.any((p) => !listEquals(p.pick(app), p.seen))) return;
    }
    dependent.didChangeDependencies();
  }
}

List<Object?> _appPick(AppController app) =>
    [app.settings, app.settingsRev, app.identity.waiting];

class NymbotApp extends StatelessWidget {
  const NymbotApp({super.key, required this.controller, this.navigatorKey});

  final AppController controller;

  /// Null in the shipped app; the screenshot harness uses it to open sheets.
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      child: Builder(builder: (context) {
        AppScope.watch(context, _appPick);
        return _app(context);
      }),
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
            SignerWait(
                waiting: controller.identity.waiting,
                authUrl: signerAuthUrl,
                child: child),
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
      child: DuoSheetRailHost(child: child ?? const SizedBox.shrink()),
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
    return AiConsentGate(
      pubkey: app.identity.pubkey,
      builder: (context) {
        if (!_entered) {
          _entered = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => app.enter());
        }
        return const HomeScreen();
      },
    );
  }
}
