import 'package:flutter/material.dart';
import '../../widgets/cartoon/chunky_button.dart';

/// 결과 화면 하단 액션. 가장 우선되는 1개를 풀폭 1차 CTA로,
/// 나머지는 토널 보조 버튼으로 묶어 시선 위계를 만든다.
class GameResultActionButtons extends StatelessWidget {
  final Color accentColor;
  final bool opponentLeft;
  final bool rematchWaiting;
  final bool isInvitationGame;
  final bool canSendFriendRequest;
  final Color? rematchWaitingColor;
  final VoidCallback onRematchPressed;
  final VoidCallback onSearchAgainPressed;
  final VoidCallback onLobbyPressed;
  final VoidCallback? onFriendRequestPressed;

  const GameResultActionButtons({
    super.key,
    required this.accentColor,
    required this.opponentLeft,
    required this.rematchWaiting,
    required this.isInvitationGame,
    required this.canSendFriendRequest,
    this.rematchWaitingColor,
    required this.onRematchPressed,
    required this.onSearchAgainPressed,
    required this.onLobbyPressed,
    this.onFriendRequestPressed,
  });

  @override
  Widget build(BuildContext context) {
    // 우선순위 순으로 가능한 액션을 모은다. 첫 번째가 1차 CTA.
    final actions = <_ResultAction>[
      if (!opponentLeft)
        _ResultAction(
          label: rematchWaiting ? '대기 중...' : '재경기',
          icon: rematchWaiting
              ? Icons.hourglass_top_rounded
              : Icons.replay_rounded,
          onPressed: onRematchPressed,
          color: rematchWaiting
              ? (rematchWaitingColor ?? Colors.orange)
              : accentColor,
        ),
      if (!isInvitationGame)
        _ResultAction(
          label: '다시 찾기',
          icon: Icons.search_rounded,
          onPressed: onSearchAgainPressed,
          color: accentColor,
        ),
      if (canSendFriendRequest && onFriendRequestPressed != null)
        _ResultAction(
          label: '친구 요청',
          icon: Icons.person_add_rounded,
          onPressed: onFriendRequestPressed!,
          color: const Color(0xFF16A34A),
        ),
      _ResultAction(
        label: '로비',
        icon: Icons.home_rounded,
        onPressed: onLobbyPressed,
        color: const Color(0xFF64748B),
      ),
    ];

    final primary = actions.first;
    final secondary = actions.skip(1).toList();

    return SafeArea(
      top: false,
      left: false,
      right: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 상대가 나가 재대결이 불가능한 경우 안내
          if (opponentLeft) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F2F4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: Colors.grey.shade500,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '상대방이 떠났어요',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // 1차 CTA — 풀폭 필드 버튼
          ChunkyButton(
            label: primary.label,
            icon: primary.icon,
            color: primary.color,
            onPressed: primary.onPressed,
          ),
          if (secondary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                for (var i = 0; i < secondary.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: ChunkyButton(
                      label: secondary[i].label,
                      icon: secondary[i].icon,
                      color: secondary[i].color,
                      height: 46,
                      radius: 15,
                      fontSize: 14,
                      onPressed: secondary[i].onPressed,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ResultAction {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  const _ResultAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.color,
  });
}
