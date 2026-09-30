import 'package:flutter/material.dart';

const String kMonoFamily = 'Menlo';
const List<String> kMonoFallback = <String>[
  'SF Mono',
  'Roboto Mono',
  'Droid Sans Mono',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'Courier New',
  'monospace',
];

/// Same palette as the web app.
class NymbotColors {
  static const primary = Color(0xFF00FF00);
  static const primaryLight = Color(0xFF0A7A2F);
  static const secondary = Color(0xFF00D4FF);
  static const secondaryLight = Color(0xFF0077A8);
  static const lightning = Color(0xFFF7931A);
  static const danger = Color(0xFFFF4D5E);

  static const bgDark = Color(0xFF050810);
  static const raisedDark = Color(0xFF0A0E1A);
  static const sunkenDark = Color(0xFF070B14);
  static const textDark = Color(0xFFE8EDF4);

  /// Squared 8px buttons to match Nymchat, not Material 3 stadiums.
  static const buttonRadius = 8.0;

  /// Concentric with the 7px tab at the toolbar's 2px padding.
  static const switchRadius = 10.0;
  static const switchTabRadius = 7.0;

  static const bgTerminal = Color(0xFF000600);
  static const raisedTerminal = Color(0xFF04120A);
  static const sunkenTerminal = Color(0xFF010A04);
  static const textTerminal = Color(0xFFC8FFCF);
  static const secondaryTerminal = Color(0xFF7DFFB0);

  static const bgMidnight = Color(0xFF0B1020);
  static const raisedMidnight = Color(0xFF121A30);
  static const sunkenMidnight = Color(0xFF090D1A);
  static const primaryMidnight = Color(0xFF7AA2FF);
  static const secondaryMidnight = Color(0xFFA78BFA);

  static const bgLight = Color(0xFFF2F4F7);
  static const raisedLight = Color(0xFFFFFFFF);
  static const sunkenLight = Color(0xFFE8EBEF);
  static const textLight = Color(0xFF10151C);
}

enum NymbotPalette { standard, terminal, midnight }

ThemeData nymbotTheme(Brightness brightness,
    {NymbotPalette palette = NymbotPalette.standard, double fontScale = 1}) {
  final dark = brightness == Brightness.dark;
  var accent = dark ? NymbotColors.primary : NymbotColors.primaryLight;
  var second = dark ? NymbotColors.secondary : NymbotColors.secondaryLight;
  var bg = dark ? NymbotColors.bgDark : NymbotColors.bgLight;
  var raised = dark ? NymbotColors.raisedDark : NymbotColors.raisedLight;
  var sunken = dark ? NymbotColors.sunkenDark : NymbotColors.sunkenLight;
  var text = dark ? NymbotColors.textDark : NymbotColors.textLight;

  if (dark && palette == NymbotPalette.terminal) {
    bg = NymbotColors.bgTerminal;
    raised = NymbotColors.raisedTerminal;
    sunken = NymbotColors.sunkenTerminal;
    text = NymbotColors.textTerminal;
    second = NymbotColors.secondaryTerminal;
  } else if (dark && palette == NymbotPalette.midnight) {
    bg = NymbotColors.bgMidnight;
    raised = NymbotColors.raisedMidnight;
    sunken = NymbotColors.sunkenMidnight;
    accent = NymbotColors.primaryMidnight;
    second = NymbotColors.secondaryMidnight;
  }

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(
      primary: accent,
      secondary: second,
      surface: raised,
      error: NymbotColors.danger,
    ),
    dividerColor: text.withValues(alpha: 0.10),
    textTheme: Typography.material2021(platform: TargetPlatform.android)
        .black
        .apply(bodyColor: text, displayColor: text, fontSizeFactor: fontScale),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: text,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: sunken,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: text.withValues(alpha: 0.10)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: text.withValues(alpha: 0.10)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: accent.withValues(alpha: 0.6)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: raised,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
    ),
    // Material 3 draws segmented buttons as stadiums by default.
    segmentedButtonTheme: SegmentedButtonThemeData(style: _buttonStyle),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: _buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: _buttonStyle),
    textButtonTheme: TextButtonThemeData(style: _buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: _buttonStyle),
    dialogTheme: DialogThemeData(backgroundColor: raised, surfaceTintColor: Colors.transparent),
    listTileTheme: ListTileThemeData(iconColor: text.withValues(alpha: 0.6)),
  );
}

extension NymSurfaceTint on ThemeData {
  Color tint(double strength) =>
      dividerColor.withValues(alpha: dividerColor.a * strength);

  Color get lineStrong => colorScheme.primary.withValues(
      alpha: brightness == Brightness.light
          ? 0.3
          : colorScheme.primary == NymbotColors.primaryMidnight
              ? 0.35
              : 0.25);
}

final _buttonStyle = ButtonStyle(
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
  )),
);
