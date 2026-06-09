import 'package:flutter/material.dart';
import '../../utils/game_theme.dart';

/// 일반 매칭에서 상대를 찾는 중 화면. 보드 게임(틱택토·무한틱택토·오목) 공통.
class GameSearchingView extends StatelessWidget {
  final GameTheme theme;
  final bool isHardcore;
  final VoidCallback onCancel;

  const GameSearchingView({
    super.key,
    required this.theme,
    required this.isHardcore,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                color: theme.primary,
                strokeWidth: 4,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              isHardcore ? '하드코어 상대를 찾는 중...' : '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 18,
                color: isHardcore ? Colors.red.shade700 : Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 8),
            if (isHardcore)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_fire_department, size: 16, color: Colors.red),
                    const SizedBox(width: 4),
                    Text(
                      '하드코어 모드 (10초)',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.red.shade700,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.auto_awesome, size: 16, color: const Color(0xFFFDCB6E)),
                  const SizedBox(width: 4),
                  Text(
                    '상대를 기다리는 중',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade500,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.auto_awesome, size: 16, color: const Color(0xFFFDCB6E)),
                ],
              ),
            const SizedBox(height: 48),
            OutlinedButton(
              onPressed: onCancel,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.primary,
                side: BorderSide(color: theme.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: const Text('취소'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 매칭 성사 — 상대와 만났을 때의 짧은 전환 화면.
class GameMatchedView extends StatelessWidget {
  final GameTheme theme;
  final String? opponentNickname;

  const GameMatchedView({
    super.key,
    required this.theme,
    required this.opponentNickname,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.background1,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sports_esports,
                size: 64,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$opponentNickname님과 매칭!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '게임이 곧 시작됩니다...',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

/// 보드 게임(틱택토·무한틱택토·오목)의 턴 제한시간 타이머 뱃지.
class GameBoardTimer extends StatelessWidget {
  final int remaining;

  const GameBoardTimer({super.key, required this.remaining});

  @override
  Widget build(BuildContext context) {
    final isLow = remaining <= 10;
    final isCritical = remaining <= 5;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isCritical
            ? Colors.red.shade100
            : isLow
                ? Colors.orange.shade100
                : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isCritical
              ? Colors.red
              : isLow
                  ? Colors.orange
                  : Colors.grey.shade300,
          width: isCritical ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer,
            size: 18,
            color: isCritical
                ? Colors.red
                : isLow
                    ? Colors.orange
                    : Colors.grey.shade600,
          ),
          const SizedBox(width: 4),
          Text(
            '$remaining초',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isCritical
                  ? Colors.red
                  : isLow
                      ? Colors.orange
                      : Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }
}

/// 솔로 지원 게임(헥사곤·수식피라미드)의 상대 찾는 중 화면.
/// 보드용 GameSearchingView보다 단순하며 accent 색만 다르다.
class GameSoloSearchingView extends StatelessWidget {
  final Color accentColor;
  final VoidCallback onCancel;

  const GameSoloSearchingView({
    super.key,
    required this.accentColor,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: accentColor),
          const SizedBox(height: 24),
          Text('상대를 찾는 중...',
              style: TextStyle(fontSize: 18, color: accentColor)),
          const SizedBox(height: 24),
          TextButton(
            onPressed: onCancel,
            child: const Text('취소', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }
}

/// 솔로 지원 게임의 매칭 성사 전환 화면. 솔로면 '랭킹 도전 준비', 대전이면 '게임 시작 준비'.
class GameSoloMatchedView extends StatelessWidget {
  final Color accentColor;
  final String? opponentNickname;
  final bool isSolo;

  const GameSoloMatchedView({
    super.key,
    required this.accentColor,
    required this.opponentNickname,
    required this.isSolo,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (opponentNickname != null) ...[
            Text(opponentNickname!,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: accentColor)),
            const SizedBox(height: 8),
          ],
          Text(
            isSolo ? '랭킹 도전 준비 중...' : '게임 시작 준비 중...',
            style: TextStyle(fontSize: 18, color: accentColor),
          ),
          const SizedBox(height: 16),
          CircularProgressIndicator(color: accentColor),
        ],
      ),
    );
  }
}

/// 랭크전 게임 준비 중 화면.
class GameRankedPreparingView extends StatelessWidget {
  final GameTheme theme;

  const GameRankedPreparingView({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              '게임 준비 중...',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}
