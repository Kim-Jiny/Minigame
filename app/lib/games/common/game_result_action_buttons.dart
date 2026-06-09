import 'package:flutter/material.dart';

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
          icon: rematchWaiting ? Icons.hourglass_top_rounded : Icons.replay_rounded,
          onPressed: onRematchPressed,
          color: rematchWaiting ? (rematchWaitingColor ?? Colors.orange) : accentColor,
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
                  Icon(Icons.info_outline_rounded,
                      size: 18, color: Colors.grey.shade500),
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
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: primary.onPressed,
              icon: Icon(primary.icon),
              label: Text(
                primary.label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: primary.color,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                elevation: 0,
              ),
            ),
          ),
          if (secondary.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                for (var i = 0; i < secondary.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: _TonalButton(action: secondary[i])),
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

/// 보조 액션 — 색을 옅게 깐 토널 버튼(테두리 없음)으로 부드럽게.
class _TonalButton extends StatelessWidget {
  final _ResultAction action;

  const _TonalButton({required this.action});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: action.color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: action.onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(action.icon, size: 18, color: action.color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: action.color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
