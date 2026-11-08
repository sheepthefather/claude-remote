import 'package:flutter/material.dart';

class AppTheme {
  static const pine = Color(0xFF2B6455);
  static const pineLight = Color(0xFF75BFA9);
  static const lightBg = Color(0xFFF8F9F5);
  static const lightSurface2 = Color(0xFFF0F2EC);
  static const lightSurface3 = Color(0xFFE4E7DF);
  static const ink = Color(0xFF191C17);
  static const darkBg = Color(0xFF171B16);
  static const darkSurface2 = Color(0xFF1E231D);
  static const darkSurface3 = Color(0xFF272D26);
  static const darkInk = Color(0xFFE9ECE3);
  static const amber = Color(0xFF8D5C16);
  static const amberLight = Color(0xFFD6A05B);
  static const danger = Color(0xFF9B3B2C);
  static const dangerLight = Color(0xFFE08A78);
  static const codeBg = Color(0xFF171A16);
  static const codeFg = Color(0xFFE4E8DD);
  static const codeMuted = Color(0xFF8F978A);
  static const codeLine = Color(0xFF2C312A);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: pine,
      brightness: Brightness.light,
    ).copyWith(
      primary: pine,
      onPrimary: const Color(0xFFF6FFFB),
      primaryContainer: const Color(0xFFDBE8E2),
      onPrimaryContainer: pine,
      secondary: amber,
      onSecondary: const Color(0xFFF5EAD7),
      surface: lightBg,
      onSurface: ink,
      surfaceContainerHigh: lightSurface2,
      surfaceContainerHighest: lightSurface3,
      outline: const Color(0xFFC1C6BA),
      outlineVariant: const Color(0xFFD7DAD2),
      error: danger,
      onError: const Color(0xFFF6E2DD),
      errorContainer: const Color(0xFFF6E2DD),
      onErrorContainer: danger,
    );
    return _base(scheme, lightBg);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: pineLight,
      brightness: Brightness.dark,
    ).copyWith(
      primary: pineLight,
      onPrimary: const Color(0xFF0D1713),
      primaryContainer: const Color(0xFF1D332C),
      onPrimaryContainer: pineLight,
      secondary: amberLight,
      onSecondary: const Color(0xFF2A2419),
      surface: darkBg,
      onSurface: darkInk,
      surfaceContainerHigh: darkSurface2,
      surfaceContainerHighest: darkSurface3,
      outline: const Color(0xFF3C4338),
      outlineVariant: const Color(0xFF2C322A),
      error: dangerLight,
      onError: const Color(0xFF2D1F1C),
      errorContainer: const Color(0xFF2D1F1C),
      onErrorContainer: dangerLight,
    );
    return _base(scheme, darkBg);
  }

  static ThemeData _base(ColorScheme scheme, Color background) => ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        appBarTheme: AppBarTheme(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: scheme.onSurface,
            fontSize: 19,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
          iconTheme: IconThemeData(color: scheme.onSurface),
        ),
        drawerTheme: DrawerThemeData(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(right: Radius.circular(26)),
          ),
        ),
        bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: scheme.onSurface,
          contentTextStyle: TextStyle(color: scheme.surface, fontSize: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          thickness: 1,
          space: 1,
        ),
        cardTheme: CardThemeData(
          color: scheme.surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerHigh,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: scheme.primary, width: 1.4),
          ),
          hintStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.45)),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: scheme.surfaceContainerHigh,
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
          labelStyle: TextStyle(color: scheme.onSurface, fontSize: 12),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 46),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 46),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      );
}
