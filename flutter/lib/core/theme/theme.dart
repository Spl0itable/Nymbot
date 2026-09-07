import 'package:flutter/material.dart';

/// The same palette as the web app, so the two read as one product.
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

  /// A button is squared off, not a pill. Material 3's default is a stadium;
  /// Nymchat draws its own controls at 8px, and this is the same chat, so the
  /// two have to agree. The toolbar's tier switch is the one exception — see
  /// [switchRadius].
  static const buttonRadius = 8.0;

  /// A 10px track around a 7px tab: concentric at the toolbar's 2px padding,
  /// which is what stops the track reading as a sticker behind the tab. Same
  /// pair Nymchat uses.
  static const switchRadius = 10.0;
  static const switchTabRadius = 7.0;

  static const bgLight = Color(0xFFF2F4F7);
  static const raisedLight = Color(0xFFFFFFFF);
  static const sunkenLight = Color(0xFFE8EBEF);
  static const textLight = Color(0xFF10151C);
}

ThemeData nymbotTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final accent = dark ? NymbotColors.primary : NymbotColors.primaryLight;
  final second = dark ? NymbotColors.secondary : NymbotColors.secondaryLight;
  final bg = dark ? NymbotColors.bgDark : NymbotColors.bgLight;
  final raised = dark ? NymbotColors.raisedDark : NymbotColors.raisedLight;
  final sunken = dark ? NymbotColors.sunkenDark : NymbotColors.sunkenLight;
  final text = dark ? NymbotColors.textDark : NymbotColors.textLight;

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
        .apply(bodyColor: text, displayColor: text),
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
    // A segmented button is a stadium by default in Material 3, which is the
    // one control that would still read as a pill next to the toolbar.
    segmentedButtonTheme: SegmentedButtonThemeData(style: _buttonStyle),
    // Material 3 already draws a chip at 8; pinned so the two cannot drift.
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

final _buttonStyle = ButtonStyle(
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(NymbotColors.buttonRadius),
  )),
);
