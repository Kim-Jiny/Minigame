import 'package:flutter/material.dart';
import '../models/shop_item.dart';

/// 게임 화면에서 사용할 테마 색상
class GameTheme {
  final Color primary;
  final Color secondary;
  final Color background1;
  final Color background2;
  final Color textOnPrimary;

  const GameTheme({
    required this.primary,
    required this.secondary,
    required this.background1,
    required this.background2,
    this.textOnPrimary = Colors.white,
  });

  /// 기본 테마 (보라색)
  static const defaultTheme = GameTheme(
    primary: Color(0xFF6C5CE7),
    secondary: Color(0xFFA29BFE),
    background1: Color(0xFFE8E0FF),
    background2: Color(0xFFF5F0FF),
  );

  /// UserProfileSettings에서 테마 생성
  static GameTheme fromProfileSettings(UserProfileSettings? settings) {
    if (settings == null) return defaultTheme;

    // activeTheme이 있으면 그 색상 사용
    final themeColors = settings.getThemeColors();
    if (themeColors != null) {
      final primary = themeColors.$1;
      final secondary = themeColors.$2;
      return GameTheme(
        primary: primary,
        secondary: secondary,
        background1: _lighten(primary, 0.85),
        background2: _lighten(primary, 0.92),
        textOnPrimary: _getContrastColor(primary),
      );
    }

    return defaultTheme;
  }

  /// 색상을 밝게 만들기
  static Color _lighten(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl.withLightness((hsl.lightness + (1 - hsl.lightness) * amount).clamp(0.0, 1.0)).toColor();
  }

  /// 대비 색상 계산 (밝은 배경이면 어두운 텍스트)
  static Color _getContrastColor(Color color) {
    final luminance = color.computeLuminance();
    return luminance > 0.5 ? Colors.black87 : Colors.white;
  }

  /// 배경 — 절제된 중립 서피스(브랜드 컬러는 아주 옅은 틴트로만).
  /// 프리미엄 앱 느낌을 위해 게임마다 배경을 강하게 물들이지 않는다.
  LinearGradient get backgroundGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [primary.withValues(alpha: 0.045), const Color(0xFFFAFBFC)],
  );

  /// 페이지 기본 서피스 색(스캐폴드 배경 등).
  static const Color surface = Color(0xFFF5F6F8);

  /// 카드 그라데이션
  LinearGradient get cardGradient => LinearGradient(
    colors: [background1, background2],
  );
}
