import 'package:flutter/material.dart';

abstract final class PenninoColors {
  static const leather = Color(0xff15191d);
  static const leatherRaised = Color(0xff20262b);
  static const leatherInset = Color(0xff0d1013);
  static const gold = Color(0xffd7a842);
  static const paleGold = Color(0xfff0d38a);
  static const steel = Color(0xffaeb5bc);
  static const ink = Color(0xfff5f0e5);
}

ThemeData buildPenninoTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: PenninoColors.gold,
        onPrimary: PenninoColors.leatherInset,
        primaryContainer: Color(0xff5b461c),
        onPrimaryContainer: PenninoColors.paleGold,
        secondary: PenninoColors.steel,
        onSecondary: PenninoColors.leatherInset,
        surface: PenninoColors.leather,
        onSurface: PenninoColors.ink,
        surfaceContainerLowest: PenninoColors.leatherInset,
        surfaceContainerLow: Color(0xff191e22),
        surfaceContainer: PenninoColors.leatherRaised,
        surfaceContainerHigh: Color(0xff2a3035),
        outline: Color(0xff6d675d),
        outlineVariant: Color(0xff3f4346),
      ),
      scaffoldBackgroundColor: PenninoColors.leather,
      dividerColor: const Color(0xff4a443b),
      appBarTheme: const AppBarTheme(
        backgroundColor: PenninoColors.leatherRaised,
        foregroundColor: PenninoColors.paleGold,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black,
        elevation: 5,
        titleTextStyle: TextStyle(
          color: PenninoColors.ink,
          fontSize: 21,
          fontWeight: FontWeight.w600,
          letterSpacing: .2,
        ),
      ),
      cardTheme: CardThemeData(
        color: PenninoColors.leatherRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shadowColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xff4b4740)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: PenninoColors.leatherRaised,
        selectedColor: const Color(0xff5b461c),
        checkmarkColor: PenninoColors.paleGold,
        side: const BorderSide(color: Color(0xff575149)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        labelStyle: const TextStyle(color: PenninoColors.ink),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: PenninoColors.gold,
        foregroundColor: PenninoColors.leatherInset,
        elevation: 6,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: PenninoColors.leatherRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xff5a544b)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: PenninoColors.leatherInset,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: Color(0xff5a544b)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(
            color: PenninoColors.gold,
            width: 1.4,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: PenninoColors.paleGold,
        ),
      ),
    );
