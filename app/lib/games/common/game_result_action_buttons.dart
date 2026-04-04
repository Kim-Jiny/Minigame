import 'package:flutter/material.dart';

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
    final primaryStyle = ElevatedButton.styleFrom(
      backgroundColor: rematchWaiting
          ? (rematchWaitingColor ?? Colors.orange)
          : accentColor,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      elevation: 0,
    );
    final outlineStyle = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    );

    return SafeArea(
      top: false,
      left: false,
      right: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: [
          if (!opponentLeft)
            ElevatedButton.icon(
              onPressed: onRematchPressed,
              icon: Icon(rematchWaiting ? Icons.hourglass_top : Icons.replay),
              label: Text(rematchWaiting ? '대기 중...' : '재경기'),
              style: primaryStyle,
            ),
          if (!isInvitationGame)
            OutlinedButton.icon(
              onPressed: onSearchAgainPressed,
              icon: const Icon(Icons.search),
              label: const Text('다시 찾기'),
              style: outlineStyle.copyWith(
                foregroundColor: WidgetStatePropertyAll(accentColor),
                side: WidgetStatePropertyAll(BorderSide(color: accentColor.withValues(alpha: 0.55))),
                backgroundColor: const WidgetStatePropertyAll(Colors.white),
              ),
            ),
          if (canSendFriendRequest && onFriendRequestPressed != null)
            OutlinedButton.icon(
              onPressed: onFriendRequestPressed,
              icon: const Icon(Icons.person_add),
              label: const Text('친구 요청'),
              style: outlineStyle.copyWith(
                foregroundColor: const WidgetStatePropertyAll(Color(0xFF15803D)),
                side: const WidgetStatePropertyAll(BorderSide(color: Color(0xFF86EFAC))),
                backgroundColor: const WidgetStatePropertyAll(Color(0xFFF0FDF4)),
              ),
            ),
          OutlinedButton.icon(
            onPressed: onLobbyPressed,
            icon: const Icon(Icons.home),
            label: const Text('로비'),
            style: outlineStyle.copyWith(
              foregroundColor: const WidgetStatePropertyAll(Color(0xFF4B5563)),
              side: const WidgetStatePropertyAll(BorderSide(color: Color(0xFFD1D5DB))),
              backgroundColor: const WidgetStatePropertyAll(Color(0xFFF9FAFB)),
            ),
          ),
        ],
      ),
    );
  }
}
