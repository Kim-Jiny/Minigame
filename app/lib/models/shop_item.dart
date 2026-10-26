import 'package:flutter/material.dart';

// 희귀도 정의
enum Rarity {
  common,
  rare,
  epic,
  legendary;

  static Rarity fromString(String value) {
    switch (value) {
      case 'rare':
        return Rarity.rare;
      case 'epic':
        return Rarity.epic;
      case 'legendary':
        return Rarity.legendary;
      default:
        return Rarity.common;
    }
  }

  Color get color {
    switch (this) {
      case Rarity.common:
        return Colors.grey;
      case Rarity.rare:
        return Colors.blue;
      case Rarity.epic:
        return Colors.purple;
      case Rarity.legendary:
        return Colors.orange;
    }
  }

  String get displayName {
    switch (this) {
      case Rarity.common:
        return '일반';
      case Rarity.rare:
        return '레어';
      case Rarity.epic:
        return '에픽';
      case Rarity.legendary:
        return '전설';
    }
  }
}

// 카테고리 정의
enum ShopCategory {
  frame,
  title,
  theme,
  avatar,
  mascot,
  ticket;

  static ShopCategory fromString(String value) {
    switch (value) {
      case 'frame':
        return ShopCategory.frame;
      case 'title':
        return ShopCategory.title;
      case 'theme':
        return ShopCategory.theme;
      case 'avatar':
        return ShopCategory.avatar;
      case 'mascot':
        return ShopCategory.mascot;
      case 'ticket':
        return ShopCategory.ticket;
      default:
        return ShopCategory.frame;
    }
  }

  String get displayName {
    switch (this) {
      case ShopCategory.frame:
        return '프레임';
      case ShopCategory.title:
        return '칭호';
      case ShopCategory.theme:
        return '테마';
      case ShopCategory.avatar:
        return '아바타';
      case ShopCategory.mascot:
        return '마스코트';
      case ShopCategory.ticket:
        return '티켓';
    }
  }

  IconData get icon {
    switch (this) {
      case ShopCategory.frame:
        return Icons.crop_square;
      case ShopCategory.title:
        return Icons.badge;
      case ShopCategory.theme:
        return Icons.palette;
      case ShopCategory.avatar:
        return Icons.face;
      case ShopCategory.mascot:
        return Icons.pets;
      case ShopCategory.ticket:
        return Icons.confirmation_number;
    }
  }
}

// 상점 아이템 모델
class ShopItem {
  final int id;
  final ShopCategory category;
  final String itemKey;
  final String name;
  final String description;
  final int price;
  final int? durationDays;
  final Rarity rarity;
  final Map<String, dynamic> previewData;
  final int sortOrder;
  final bool isActive;
  final bool isDefault;
  // 할인/배지/기간 한정 (구 서버는 보내지 않음 → 기본값)
  final int originalPrice; // price 는 이미 "실제 판매가"
  final int discountPercent; // 0 = 할인 없음
  final DateTime? saleEndsAt;
  final String? badge; // 'new' | 'hot' | 'limited'
  final bool isFeatured;
  final DateTime? availableUntil;

  ShopItem({
    required this.id,
    required this.category,
    required this.itemKey,
    required this.name,
    required this.description,
    required this.price,
    this.durationDays,
    required this.rarity,
    required this.previewData,
    required this.sortOrder,
    required this.isActive,
    required this.isDefault,
    int? originalPrice,
    this.discountPercent = 0,
    this.saleEndsAt,
    this.badge,
    this.isFeatured = false,
    this.availableUntil,
  }) : originalPrice = originalPrice ?? price;

  factory ShopItem.fromJson(Map<String, dynamic> json) {
    return ShopItem(
      id: json['id'],
      category: ShopCategory.fromString(json['category']),
      itemKey: json['itemKey'] ?? json['item_key'] ?? '',
      name: json['name'] ?? '',
      description: json['description'] ?? '',
      price: json['price'] ?? 0,
      durationDays: json['durationDays'] ?? json['duration_days'],
      rarity: Rarity.fromString(json['rarity'] ?? 'common'),
      previewData: json['previewData'] ?? json['preview_data'] ?? {},
      sortOrder: json['sortOrder'] ?? json['sort_order'] ?? 0,
      isActive: json['isActive'] ?? json['is_active'] ?? true,
      isDefault: json['isDefault'] ?? json['is_default'] ?? false,
      originalPrice: _asInt(json['originalPrice']),
      discountPercent: _asInt(json['discountPercent']) ?? 0,
      saleEndsAt: _asDate(json['saleEndsAt']),
      badge: json['badge'] is String ? json['badge'] : null,
      isFeatured: json['isFeatured'] == true,
      availableUntil: _asDate(json['availableUntil']),
    );
  }

  static int? _asInt(dynamic v) => v is num ? v.toInt() : null;
  static DateTime? _asDate(dynamic v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  /// 할인 중인가(할인 종료 시각이 지났으면 아님).
  bool get isOnSale =>
      discountPercent > 0 &&
      originalPrice > price &&
      (saleEndsAt == null || saleEndsAt!.isAfter(DateTime.now()));

  /// 기간 한정 판매 중 남은 시간 (없으면 null).
  Duration? get availableLeft => availableUntil?.difference(DateTime.now());

  // 마스코트 관련 헬퍼
  Color? get mascotSkinColor {
    if (category != ShopCategory.mascot) return null;
    final c = previewData['skinColor'];
    return c is String ? _colorFromHex(c) : null;
  }

  String? get mascotAccessory {
    final a = previewData['accessory'];
    return a is String && a != 'none' ? a : null;
  }

  // 프레임 관련 헬퍼
  Color? get borderColor {
    if (category != ShopCategory.frame) return null;
    final color = previewData['borderColor'];
    if (color == null) return Colors.grey;
    if (color == 'rainbow') return null; // 특수 처리
    return _colorFromHex(color);
  }

  Color? get glowColor {
    if (category != ShopCategory.frame) return null;
    final color = previewData['glowColor'];
    if (color == null) return null;
    return _colorFromHex(color);
  }

  String? get animation => previewData['animation'];

  bool get isRainbow => previewData['borderColor'] == 'rainbow';

  // 칭호 관련 헬퍼
  Color? get textColor {
    if (category != ShopCategory.title) return null;
    final color = previewData['textColor'];
    if (color == null) return Colors.grey;
    return _colorFromHex(color);
  }

  String? get titleIcon => previewData['icon'];

  List<Color>? get titleGradient {
    if (category != ShopCategory.title) return null;
    final gradientData = previewData['gradient'];
    if (gradientData == null) return null;
    return (gradientData as List).map((c) => _colorFromHex(c)).toList();
  }

  // 테마 관련 헬퍼
  List<Color>? get gradientColors {
    if (category != ShopCategory.theme) return null;
    final colors = previewData['gradientColors'];
    if (colors == null) return null;
    return (colors as List).map((c) => _colorFromHex(c)).toList();
  }

  String? get particleType => previewData['particleType'];

  // 티켓 관련 헬퍼
  String? get ticketIcon => previewData['icon'];
  String? get ticketEffect => previewData['effect'];

  // 아바타 관련 헬퍼
  String? get avatarEmoji => previewData['emoji'];
  Color? get avatarBgColor {
    if (category != ShopCategory.avatar) return null;
    final color = previewData['bgColor'];
    if (color == null) return Colors.grey.shade200;
    return _colorFromHex(color);
  }

  // 헬퍼 메소드
  static Color _colorFromHex(String hex) {
    final buffer = StringBuffer();
    if (hex.length == 6 || hex.length == 7) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }
}

// 유저 보유 아이템 모델
class UserItem {
  final int id;
  final int userId;
  final int itemId;
  final DateTime purchasedAt;
  final DateTime? expiresAt;
  final ShopItem? item;
  final bool serverExpiringSoon;

  UserItem({
    required this.id,
    required this.userId,
    required this.itemId,
    required this.purchasedAt,
    this.expiresAt,
    this.item,
    this.serverExpiringSoon = false,
  });

  factory UserItem.fromJson(Map<String, dynamic> json) {
    return UserItem(
      id: json['id'],
      userId: json['userId'] ?? json['user_id'],
      itemId: json['itemId'] ?? json['item_id'],
      purchasedAt: DateTime.parse(json['purchasedAt'] ?? json['purchased_at']),
      expiresAt: json['expiresAt'] != null || json['expires_at'] != null
          ? DateTime.parse(json['expiresAt'] ?? json['expires_at'])
          : null,
      item: json['item'] != null ? ShopItem.fromJson(json['item']) : null,
      serverExpiringSoon: json['isExpiringSoon'] == true,
    );
  }

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  /// 영구 보유(만료 없음)인가.
  bool get isPermanent => expiresAt == null;

  /// 만료 3일 이하(서버 플래그 또는 직접 계산).
  bool get isExpiringSoon {
    if (expiresAt == null || isExpired) return false;
    return serverExpiringSoon ||
        expiresAt!.difference(DateTime.now()) <= const Duration(days: 3);
  }

  /// 카드용 짧은 남은 기간: 'D-12' / '3일 남음'은 expiresInText.
  String get shortLeftText {
    if (expiresAt == null) return '영구';
    final diff = expiresAt!.difference(DateTime.now());
    if (diff.isNegative) return '만료됨';
    if (isExpiringSoon) return '곧 만료!';
    return 'D-${diff.inDays + 1}';
  }

  String get expiresInText {
    if (expiresAt == null) return '영구';
    final diff = expiresAt!.difference(DateTime.now());
    if (diff.isNegative) return '만료됨';
    if (diff.inDays > 0) return '${diff.inDays}일 남음';
    if (diff.inHours > 0) return '${diff.inHours}시간 남음';
    return '${diff.inMinutes}분 남음';
  }
}

// 유저 프로필 설정 모델
class UserProfileSettings {
  final int userId;
  final int? activeFrameId;
  final int? activeTitleId;
  final int? activeThemeId;
  final int? activeAvatarId;
  final int? activeMascotId;
  final ShopItem? activeFrame;
  final ShopItem? activeTitle;
  final ShopItem? activeTheme;
  final ShopItem? activeAvatar;
  final ShopItem? activeMascot;
  // flat 구조에서 직접 받는 필드들
  final String? activeFrameKey;
  final String? activeFrameName;
  final String? activeFrameRarity;
  final Map<String, dynamic>? activeFramePreviewData;
  final String? activeTitleKey;
  final String? activeTitleName;
  final String? activeTitleRarity;
  final Map<String, dynamic>? activeTitlePreviewData;
  final String? activeThemeKey;
  final String? activeThemeName;
  final String? activeThemeRarity;
  final Map<String, dynamic>? activeThemePreviewData;
  final String? activeAvatarKey;
  final String? activeAvatarName;
  final String? activeAvatarRarity;
  final Map<String, dynamic>? activeAvatarPreviewData;
  final String? activeMascotKey;
  final String? activeMascotName;
  final String? activeMascotRarity;
  final Map<String, dynamic>? activeMascotPreviewData;

  UserProfileSettings({
    required this.userId,
    this.activeFrameId,
    this.activeTitleId,
    this.activeThemeId,
    this.activeAvatarId,
    this.activeMascotId,
    this.activeFrame,
    this.activeTitle,
    this.activeTheme,
    this.activeAvatar,
    this.activeMascot,
    this.activeFrameKey,
    this.activeFrameName,
    this.activeFrameRarity,
    this.activeFramePreviewData,
    this.activeTitleKey,
    this.activeTitleName,
    this.activeTitleRarity,
    this.activeTitlePreviewData,
    this.activeThemeKey,
    this.activeThemeName,
    this.activeThemeRarity,
    this.activeThemePreviewData,
    this.activeAvatarKey,
    this.activeAvatarName,
    this.activeAvatarRarity,
    this.activeAvatarPreviewData,
    this.activeMascotKey,
    this.activeMascotName,
    this.activeMascotRarity,
    this.activeMascotPreviewData,
  });

  factory UserProfileSettings.fromJson(Map<String, dynamic> json) {
    return UserProfileSettings(
      userId: json['userId'] ?? json['user_id'] ?? 0,
      activeFrameId: json['activeFrameId'] ?? json['active_frame_id'],
      activeTitleId: json['activeTitleId'] ?? json['active_title_id'],
      activeThemeId: json['activeThemeId'] ?? json['active_theme_id'],
      activeAvatarId: json['activeAvatarId'] ?? json['active_avatar_id'],
      activeMascotId: json['activeMascotId'] ?? json['active_mascot_id'],
      activeFrame: json['activeFrame'] != null
          ? ShopItem.fromJson(json['activeFrame'])
          : null,
      activeTitle: json['activeTitle'] != null
          ? ShopItem.fromJson(json['activeTitle'])
          : null,
      activeTheme: json['activeTheme'] != null
          ? ShopItem.fromJson(json['activeTheme'])
          : null,
      activeAvatar: json['activeAvatar'] != null
          ? ShopItem.fromJson(json['activeAvatar'])
          : null,
      activeMascot: json['activeMascot'] != null
          ? ShopItem.fromJson(json['activeMascot'])
          : null,
      // flat 구조 지원
      activeFrameKey: json['activeFrameKey'],
      activeFrameName: json['activeFrameName'],
      activeFrameRarity: json['activeFrameRarity'],
      activeFramePreviewData: json['activeFramePreviewData'] != null
          ? Map<String, dynamic>.from(json['activeFramePreviewData'])
          : null,
      activeTitleKey: json['activeTitleKey'],
      activeTitleName: json['activeTitleName'],
      activeTitleRarity: json['activeTitleRarity'],
      activeTitlePreviewData: json['activeTitlePreviewData'] != null
          ? Map<String, dynamic>.from(json['activeTitlePreviewData'])
          : null,
      activeThemeKey: json['activeThemeKey'],
      activeThemeName: json['activeThemeName'],
      activeThemeRarity: json['activeThemeRarity'],
      activeThemePreviewData: json['activeThemePreviewData'] != null
          ? Map<String, dynamic>.from(json['activeThemePreviewData'])
          : null,
      activeAvatarKey: json['activeAvatarKey'],
      activeAvatarName: json['activeAvatarName'],
      activeAvatarRarity: json['activeAvatarRarity'],
      activeAvatarPreviewData: json['activeAvatarPreviewData'] != null
          ? Map<String, dynamic>.from(json['activeAvatarPreviewData'])
          : null,
      activeMascotKey: json['activeMascotKey'],
      activeMascotName: json['activeMascotName'],
      activeMascotRarity: json['activeMascotRarity'],
      activeMascotPreviewData: json['activeMascotPreviewData'] != null
          ? Map<String, dynamic>.from(json['activeMascotPreviewData'])
          : null,
    );
  }

  // 기본값
  factory UserProfileSettings.empty(int userId) {
    return UserProfileSettings(userId: userId);
  }

  // 프레임 색상 가져오기 (flat 구조 또는 nested 구조 모두 지원)
  (Color, Color)? getFrameColors() {
    // nested 구조 우선 - ShopItem의 borderColor와 glowColor 사용
    if (activeFrame != null) {
      final borderColor = activeFrame!.borderColor;
      final glowColor = activeFrame!.glowColor ?? borderColor;
      if (borderColor != null && glowColor != null) {
        return (borderColor, glowColor);
      }
    }
    // flat 구조 - previewData에서 직접 추출
    if (activeFramePreviewData != null) {
      final borderColorStr = activeFramePreviewData!['borderColor'] as String?;
      final glowColorStr = activeFramePreviewData!['glowColor'] as String?;
      if (borderColorStr != null && borderColorStr != 'rainbow') {
        final borderColor = _colorFromHex(borderColorStr);
        final glowColor = glowColorStr != null ? _colorFromHex(glowColorStr) : borderColor;
        return (borderColor, glowColor);
      }
    }
    return null;
  }

  // 레인보우 프레임 여부 확인
  bool isRainbowFrame() {
    // nested 구조 확인
    if (activeFrame != null && activeFrame!.isRainbow) {
      return true;
    }
    // flat 구조 확인
    if (activeFramePreviewData != null) {
      final borderColorStr = activeFramePreviewData!['borderColor'] as String?;
      return borderColorStr == 'rainbow';
    }
    return false;
  }

  // 칭호 그라디언트 가져오기
  (Color, Color)? getTitleGradient() {
    // nested 구조 우선 - ShopItem의 titleGradient 사용
    if (activeTitle != null) {
      final gradient = activeTitle!.titleGradient;
      if (gradient != null && gradient.length >= 2) {
        return (gradient[0], gradient[1]);
      }
      // 그라디언트 없으면 textColor 사용
      final textColor = activeTitle!.textColor;
      if (textColor != null) {
        return (textColor, textColor);
      }
    }
    // flat 구조 - previewData에서 직접 추출
    if (activeTitlePreviewData != null) {
      final gradient = activeTitlePreviewData!['gradient'] as List?;
      if (gradient != null && gradient.length >= 2) {
        return (
          _colorFromHex(gradient[0] as String),
          _colorFromHex(gradient[1] as String),
        );
      }
      final textColorStr = activeTitlePreviewData!['textColor'] as String?;
      if (textColorStr != null) {
        final textColor = _colorFromHex(textColorStr);
        return (textColor, textColor);
      }
    }
    return null;
  }

  // 테마 색상 가져오기
  (Color, Color)? getThemeColors() {
    // nested 구조 우선 - ShopItem의 gradientColors 사용
    if (activeTheme != null) {
      final colors = activeTheme!.gradientColors;
      if (colors != null && colors.length >= 2) {
        return (colors[0], colors[1]);
      }
    }
    // flat 구조 - previewData에서 직접 추출
    if (activeThemePreviewData != null) {
      final colors = activeThemePreviewData!['gradientColors'] as List?;
      if (colors != null && colors.length >= 2) {
        return (
          _colorFromHex(colors[0] as String),
          _colorFromHex(colors[1] as String),
        );
      }
    }
    return null;
  }

  // 아바타 정보 가져오기 (emoji, bgColor)
  (String, Color)? getAvatarInfo() {
    // nested 구조 우선 - ShopItem의 avatarEmoji 사용
    if (activeAvatar != null) {
      final emoji = activeAvatar!.avatarEmoji;
      final bgColor = activeAvatar!.avatarBgColor ?? Colors.grey.shade200;
      if (emoji != null) {
        return (emoji, bgColor);
      }
    }
    // flat 구조 - previewData에서 직접 추출
    if (activeAvatarPreviewData != null) {
      final emoji = activeAvatarPreviewData!['emoji'] as String?;
      final bgColorStr = activeAvatarPreviewData!['bgColor'] as String?;
      if (emoji != null) {
        final bgColor = bgColorStr != null ? _colorFromHex(bgColorStr) : Colors.grey.shade200;
        return (emoji, bgColor);
      }
    }
    return null;
  }

  /// 그린 아바타용 정보. key 는 itemKey, emoji 는 구 서버/미지원 키 대비 폴백.
  ({String key, String? emoji, Color bg})? getAvatarArt() {
    final bgDefault = Colors.grey.shade200;
    if (activeAvatar != null) {
      return (
        key: activeAvatar!.itemKey,
        emoji: activeAvatar!.avatarEmoji,
        bg: activeAvatar!.avatarBgColor ?? bgDefault,
      );
    }
    final key = activeAvatarKey;
    final pd = activeAvatarPreviewData;
    if (key != null || pd?['emoji'] != null) {
      final bgStr = pd?['bgColor'] as String?;
      return (
        key: key ?? '',
        emoji: pd?['emoji'] as String?,
        bg: bgStr != null ? _colorFromHex(bgStr) : bgDefault,
      );
    }
    return null;
  }

  /// 마스코트 스킨 (색, 액세서리). 장착 없으면 null.
  (Color, String?)? getMascotInfo() {
    final pd = activeMascot?.previewData ?? activeMascotPreviewData;
    if (pd == null) return null;
    final c = pd['skinColor'];
    final a = pd['accessory'];
    if (c is! String) return null;
    return (_colorFromHex(c), a is String && a != 'none' ? a : null);
  }

  // 색상 변환 헬퍼
  static Color _colorFromHex(String hex) {
    final buffer = StringBuffer();
    if (hex.length == 6 || hex.length == 7) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  }
}
