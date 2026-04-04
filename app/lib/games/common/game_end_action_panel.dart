import 'package:flutter/material.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      left: false,
      right: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          if (showRematchActions) ...[
            if (opponentWantsRematch && !rematchWaiting) ...[
              if (opponentRequestMessage != null) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: (acceptColor ?? Colors.green).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    opponentRequestMessage!,
                    style: TextStyle(
                      color: acceptColor ?? Colors.green,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onRequestRematch,
                  icon: Icon(rematchIcon),
                  label: Text(acceptRematchLabel),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: acceptColor ?? Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ] else if (rematchWaiting) ...[
              Text(
                waitingText,
                style: TextStyle(color: waitingTextColor ?? Colors.grey),
              ),
              TextButton(
                onPressed: onCancelRematch,
                child: Text(cancelLabel),
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onRequestRematch,
                  icon: Icon(rematchIcon),
                  label: Text(rematchLabel),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: primaryForegroundColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onLeave,
              icon: Icon(leaveIcon),
              label: Text(leaveLabel),
              style: OutlinedButton.styleFrom(
                foregroundColor: leaveForegroundColor,
                side: leaveBorderSide,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
