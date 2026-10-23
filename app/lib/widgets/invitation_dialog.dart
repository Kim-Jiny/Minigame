import 'package:flutter/material.dart';
import '../providers/friend_provider.dart';
import '../theme/candy_theme.dart';
import 'cartoon/chunky_button.dart';
import 'cartoon/duo_mascot.dart';

class InvitationDialog extends StatelessWidget {
  final Invitation invitation;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const InvitationDialog({
    super.key,
    required this.invitation,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final isHardcore = invitation.isHardcore;
    final primaryColor = isHardcore
        ? const Color(0xFFE5484D)
        : CandyColors.pink;

    return AlertDialog(
      backgroundColor: Colors.white,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DuoMascot(
            size: 92,
            color: primaryColor,
            mood: isHardcore ? MascotMood.cheer : MascotMood.wink,
          ),
          const SizedBox(height: 12),
          Text(
            isHardcore ? '하드코어 초대!' : '게임 초대',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: primaryColor,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${invitation.inviterNickname}님이',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: CandyColors.ink,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: CandyColors.ink, width: 2.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isHardcore) ...[
                  Icon(
                    Icons.local_fire_department,
                    size: 18,
                    color: primaryColor,
                  ),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    invitation.gameTypeName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: primaryColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '에 초대했어요!',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: CandyColors.ink,
            ),
          ),
          if (isHardcore) ...[
            const SizedBox(height: 8),
            const Text(
              '⚡ 턴당 10초!',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: Color(0xFFE5484D),
              ),
            ),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: ChunkyButton(
                  label: '다음에요',
                  color: Colors.white,
                  textColor: CandyColors.ink,
                  height: 46,
                  fontSize: 15,
                  onPressed: () {
                    onDecline();
                    Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ChunkyButton(
                  label: isHardcore ? '도전!' : '함께하기',
                  icon: isHardcore
                      ? Icons.local_fire_department
                      : Icons.play_arrow_rounded,
                  color: primaryColor,
                  height: 46,
                  fontSize: 15,
                  onPressed: () {
                    onAccept();
                    Navigator.pop(context);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// 초대 다이얼로그 표시 함수
Future<T?> showInvitationDialog<T>(
  BuildContext context,
  Invitation invitation,
  VoidCallback onAccept,
  VoidCallback onDecline,
) {
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: (context) => InvitationDialog(
      invitation: invitation,
      onAccept: onAccept,
      onDecline: onDecline,
    ),
  );
}
