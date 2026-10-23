import 'package:flutter/material.dart';

/// 캔디 카툰 디자인 시스템의 색상 토큰.
/// 두꺼운 잉크색 아웃라인 + 밝은 파스텔 면이 기본 문법이다.
class CandyColors {
  const CandyColors._();

  static const ink = Color(0xFF3A2D5C); // 아웃라인·본문 텍스트
  static const inkSoft = Color(0xFF7D7399); // 보조 텍스트
  static const cream = Color(0xFFFFF7E8); // 앱 배경
  static const creamDeep = Color(0xFFFFEBC8);

  static const pink = Color(0xFFFF6B9D); // primary
  static const pinkDeep = Color(0xFFD94F80);
  static const sky = Color(0xFF4DB8FF);
  static const skyDeep = Color(0xFF2D8FD6);
  static const sun = Color(0xFFFFD23F);
  static const sunDeep = Color(0xFFE0A800);
  static const mint = Color(0xFF3DDBB0);
  static const mintDeep = Color(0xFF1FAF89);
  static const grape = Color(0xFF9B7BFF);
  static const grapeDeep = Color(0xFF7655E0);
  static const tangerine = Color(0xFFFF9A3D);

  /// 면 색상 → 아래쪽 "두께" 그림자 색(같은 계열의 어두운 톤).
  static Color deepen(Color c, [double amount = 0.18]) {
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness - amount).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation + 0.05).clamp(0.0, 1.0))
        .toColor();
  }
}

class CandyTheme {
  const CandyTheme._();

  /// 제목·버튼·점수 같은 "게임 느낌" 텍스트용 폰트(주아체). 본문은 시스템 폰트를 유지한다.
  static const String displayFont = 'Jua';

  static const double outline = 3;
  static const double radius = 20;

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: CandyColors.pink,
      primary: CandyColors.pink,
      secondary: CandyColors.sky,
      tertiary: CandyColors.sun,
      surface: Colors.white,
      onSurface: CandyColors.ink,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      primaryColor: CandyColors.pink,
      scaffoldBackgroundColor: CandyColors.cream,
      textTheme: ThemeData.light().textTheme.apply(
        bodyColor: CandyColors.ink,
        displayColor: CandyColors.ink,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: CandyColors.pink,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: CandyTheme.displayFont,
          fontSize: 21,
          fontWeight: FontWeight.w900,
          color: Colors.white,
          letterSpacing: -0.3,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: CandyColors.pink,
          foregroundColor: Colors.white,
          elevation: 0,
          textStyle: const TextStyle(fontWeight: FontWeight.w900),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: CandyColors.ink, width: 2.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: CandyColors.ink,
          side: const BorderSide(color: CandyColors.ink, width: 2.5),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: CandyColors.ink, width: 2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: CandyColors.ink, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: CandyColors.pink, width: 3),
        ),
        prefixIconColor: CandyColors.pink,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CandyTheme.radius),
          side: const BorderSide(color: CandyColors.ink, width: 2.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: CandyColors.ink, width: 3),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: CandyColors.ink, width: 2),
        ),
      ),
    );
  }
}
