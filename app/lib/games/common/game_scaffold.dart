import 'package:flutter/material.dart';

/// 게임 화면 공통 앱바. 제목 + 색 + 뒤로가기(종료) 핸들러를 받아
/// 모든 게임에서 동일한 모양(플랫, 흰 전경)으로 통일한다.
PreferredSizeWidget gameAppBar({
  required String title,
  required Color backgroundColor,
  VoidCallback? onBack,
  Color foregroundColor = Colors.white,
  bool boldTitle = false,
  List<Widget>? actions,
}) {
  return AppBar(
    title: Text(
      title,
      style: boldTitle ? const TextStyle(fontWeight: FontWeight.bold) : null,
    ),
    backgroundColor: backgroundColor,
    foregroundColor: foregroundColor,
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
