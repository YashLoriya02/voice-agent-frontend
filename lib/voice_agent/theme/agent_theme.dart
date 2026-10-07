import 'package:flutter/material.dart';

class AgentTheme {
  static const background = Color(0xFF02050A);
  static const surface = Color(0xFF07111F);
  static const stroke = Color(0xFF17345F);
  static const blue = Color(0xFF2F6BFF);
  static const cyan = Color(0xFF00C8FF);
  static const green = Color(0xFF53E6B1);
  static const text = Color(0xFFF5F8FF);
  static const muted = Color(0xFF8296B5);

  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      primary: cyan,
      secondary: blue,
      surface: surface,
      onSurface: text,
      onPrimary: background,
      error: Color(0xFFFF8796),
    ),
    fontFamily: 'Roboto',
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: surface,
      contentTextStyle: TextStyle(color: text),
      behavior: SnackBarBehavior.floating,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: cyan),
    ),
  );
}

class AgentBackdrop extends StatelessWidget {
  const AgentBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF071426), AgentTheme.background, Color(0xFF03151C)],
        stops: [0, .6, 1],
      ),
    ),
    child: child,
  );
}
