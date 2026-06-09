import 'package:flutter/material.dart';

/// 게임 진입(대기) 화면 공통 위젯.
/// 부드러운 히어로 아이콘 + 제목/설명 + 풀폭 1차 CTA(상대 찾기) + 토널 보조(친구 초대).
/// 게임마다 아이콘·제목·설명만 다르고 배치는 동일하게 통일한다.
class GameIntroView extends StatelessWidget {
  final Gradient backgroundGradient;
  final Color accentColor;

  /// 히어로에 표시할 아이콘. emoji 가 있으면 무시된다.
  final IconData? icon;

  /// 아이콘 대신 이모지(예: 가위바위보)를 쓰고 싶을 때.
  final String? emoji;

  final String title;
  final List<String> descriptions;

  final VoidCallback onFindMatch;
  final VoidCallback onInviteFriend;
  final String findMatchLabel;

  /// 버튼 위에 끼워 넣을 추가 위젯(예: 하드코어 토글).
  final Widget? extra;

  const GameIntroView({
    super.key,
    required this.backgroundGradient,
    required this.accentColor,
    this.icon,
    this.emoji,
    required this.title,
    required this.descriptions,
    required this.onFindMatch,
    required this.onInviteFriend,
    this.findMatchLabel = '상대 찾기',
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(gradient: backgroundGradient),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 히어로
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: accentColor.withValues(alpha: 0.18),
                          blurRadius: 28,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Center(
                      child: emoji != null
                          ? Text(emoji!, style: const TextStyle(fontSize: 44))
                          : Icon(icon, size: 46, color: accentColor),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F2430),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final d in descriptions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        d,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  if (extra != null) ...[
                    const SizedBox(height: 24),
                    extra!,
                  ],
                  const SizedBox(height: 36),
                  // 1차 CTA — 상대 찾기 (풀폭)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: onFindMatch,
                      icon: const Icon(Icons.search_rounded),
                      label: Text(
                        findMatchLabel,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentColor,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 보조 — 친구 초대 (토널)
                  SizedBox(
                    width: double.infinity,
                    child: Material(
                      color: accentColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: onInviteFriend,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.person_add_rounded, size: 20, color: accentColor),
                              const SizedBox(width: 8),
                              Text(
                                '친구 초대',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: accentColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
