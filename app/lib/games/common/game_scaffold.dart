import 'package:flutter/material.dart';

/// 게임 화면 공통 앱바. 제목 + 색 + 뒤로가기(종료) 핸들러를 받아
/// 모든 게임에서 동일한 모양(플랫)으로 통일한다.
/// foregroundColor 미지정 시 배경 명도에 따라 자동 대비(밝으면 다크, 어두우면 흰색).
PreferredSizeWidget gameAppBar({
  required String title,
  required Color backgroundColor,
  VoidCallback? onBack,
  Color? foregroundColor,
  bool boldTitle = false,
  List<Widget>? actions,
}) {
  final fg = foregroundColor ??
      (backgroundColor.computeLuminance() > 0.5
          ? const Color(0xFF1A1D23)
          : Colors.white);
  return AppBar(
    title: Text(
      title,
      style: boldTitle ? const TextStyle(fontWeight: FontWeight.bold) : null,
    ),
    backgroundColor: backgroundColor,
    foregroundColor: fg,
    elevation: 0,
    leading: onBack == null
        ? null
        : IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: onBack,
          ),
    actions: actions,
  );
}
