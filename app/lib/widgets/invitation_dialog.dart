import 'package:flutter/material.dart';
import '../providers/friend_provider.dart';

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
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 게임 아이콘
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFE8E0FF),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.sports_esports,
              size: 48,
              color: Color(0xFF6C5CE7),
            ),
          ),
          const SizedBox(height: 20),

          // 초대 메시지
          const Text(
            '게임 초대',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF6C5CE7),
            ),
          ),
          const SizedBox(height: 12),

          Text(
            '${invitation.inviterNickname}님이',
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFE8E0FF),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              invitation.gameTypeName,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF6C5CE7),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '에 초대했어요!',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 24),

          // 버튼들
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    onDecline();
                    Navigator.pop(context);
                  },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: Colors.grey.shade400),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('다음에요'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    onAccept();
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C5CE7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.play_arrow, size: 18),
                      SizedBox(width: 4),
                      Text('함께하기'),
                    ],
                  ),
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
void showInvitationDialog(
  BuildContext context,
  Invitation invitation,
  VoidCallback onAccept,
  VoidCallback onDecline,
) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => InvitationDialog(
      invitation: invitation,
      onAccept: onAccept,
      onDecline: onDecline,
    ),
  );
}
