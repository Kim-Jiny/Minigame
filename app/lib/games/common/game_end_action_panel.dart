import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';
import '../../widgets/cartoon/chunky_button.dart';

class GameEndActionPanel extends StatelessWidget {
  final bool showRematchActions;
  final bool opponentWantsRematch;
  final bool rematchWaiting;
  final Color primaryColor;
  final Color primaryForegroundColor;
  final VoidCallback onRequestRematch;
  final VoidCallback onCancelRematch;
  final VoidCallback onLeave;
  final String rematchLabel;
  final String acceptRematchLabel;
  final String waitingText;
  final String cancelLabel;
  final String leaveLabel;
  final String? opponentRequestMessage;
  final IconData rematchIcon;
  final IconData leaveIcon;
  final Color? acceptColor;
  final Color? waitingTextColor;
  final Color? leaveForegroundColor;
  final BorderSide? leaveBorderSide;

  /// 상대가 나가 재대결이 불가능한 경우 안내를 표시한다.
  final bool opponentLeft;

  const GameEndActionPanel({
    super.key,
    required this.showRematchActions,
    required this.opponentWantsRematch,
    required this.rematchWaiting,
    required this.primaryColor,
    required this.primaryForegroundColor,
    required this.onRequestRematch,
    required this.onCancelRematch,
    required this.onLeave,
    required this.rematchLabel,
    required this.acceptRematchLabel,
    required this.waitingText,
    required this.cancelLabel,
    required this.leaveLabel,
    this.opponentRequestMessage,
    this.rematchIcon = Icons.replay,
    this.leaveIcon = Icons.home,
    this.acceptColor,
    this.waitingTextColor,
    this.leaveForegroundColor,
    this.leaveBorderSide,
    this.opponentLeft = false,
  });

  @override
  Widget build(BuildContext context) {
    final accept = acceptColor ?? CandyColors.mint;
    return SafeArea(
      top: false,
      left: false,
      right: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          if (opponentLeft)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: CandyColors.creamDeep,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: CandyColors.ink, width: 2),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 18, color: CandyColors.inkSoft),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '상대방이 떠났어요',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: CandyColors.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (showRematchActions) ...[
            if (opponentWantsRematch && !rematchWaiting) ...[
              if (opponentRequestMessage != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: accept.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: CandyColors.ink, width: 2),
                  ),
                  child: Text(
                    opponentRequestMessage!,
                    style: const TextStyle(
                      color: CandyColors.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ChunkyButton(
                label: acceptRematchLabel,
                icon: rematchIcon,
                color: accept,
                height: 54,
                fontSize: 17,
                onPressed: onRequestRematch,
              ),
            ] else if (rematchWaiting) ...[
              Text(
                waitingText,
                style: TextStyle(
                  color: waitingTextColor ?? CandyColors.inkSoft,
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextButton(onPressed: onCancelRematch, child: Text(cancelLabel)),
            ] else
              ChunkyButton(
                label: rematchLabel,
                icon: rematchIcon,
                color: primaryColor,
                textColor: primaryForegroundColor,
                height: 54,
                fontSize: 17,
                onPressed: onRequestRematch,
              ),
            const SizedBox(height: 8),
          ],
          ChunkyButton(
            label: leaveLabel,
            icon: leaveIcon,
            color: Colors.white,
            textColor: leaveForegroundColor ?? CandyColors.ink,
            height: 48,
            fontSize: 15,
            onPressed: onLeave,
          ),
        ],
      ),
    );
  }
}
