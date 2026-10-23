import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';
import '../../utils/game_theme.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/duo_mascot.dart';
import '../../widgets/cartoon/pop_in.dart';

/// 점 세 개가 순서대로 통통 뛰는 "찾는 중" 인디케이터.
class _BouncingDots extends StatefulWidget {
  final Color color;
  const _BouncingDots({required this.color});

  @override
  State<_BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<_BouncingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final t = ((_c.value - i * 0.16) % 1.0).clamp(0.0, 1.0);
          final lift = t < 0.35 ? -10 * (1 - (t / 0.35 - 1).abs()) : 0.0;
          return Container(
            width: 12,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            transform: Matrix4.translationValues(0, lift, 0),
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              border: Border.all(color: CandyColors.ink, width: 2),
            ),
          );
        }),
      ),
    );
  }
}

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
    final color = isHardcore ? const Color(0xFFE5484D) : theme.primary;
    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DuoMascot(size: 120, color: color),
              const SizedBox(height: 20),
              Text(
                isHardcore ? '하드코어 상대를 찾는 중' : '상대를 찾는 중',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
              ),
              const SizedBox(height: 14),
              _BouncingDots(color: color),
              const SizedBox(height: 14),
              if (isHardcore)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFE9EA),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: CandyColors.ink, width: 2),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.local_fire_department,
                        size: 16,
                        color: Color(0xFFE5484D),
                      ),
                      SizedBox(width: 4),
                      Text(
                        '하드코어 모드 (10초)',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFFE5484D),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                )
              else
                const Text(
                  '곧 누군가 나타날 거예요!',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: CandyColors.inkSoft,
                  ),
                ),
              const SizedBox(height: 40),
              ChunkyButton(
                label: '취소',
                color: Colors.white,
                textColor: CandyColors.ink,
                height: 46,
                fontSize: 16,
                expand: false,
                onPressed: onCancel,
              ),
            ],
          ),
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
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PopIn(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DuoMascot(
                    size: 92,
                    color: theme.primary,
                    mood: MascotMood.cheer,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      'VS',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: CandyColors.ink,
                      ),
                    ),
                  ),
                  const DuoMascot(
                    size: 92,
                    color: CandyColors.sky,
                    mood: MascotMood.wink,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '$opponentNickname님과 매칭!',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '게임이 곧 시작됩니다...',
              style: TextStyle(
                color: CandyColors.inkSoft,
                fontWeight: FontWeight.w700,
              ),
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
    final fg = isCritical
        ? const Color(0xFFE5484D)
        : isLow
        ? CandyColors.tangerine
        : CandyColors.ink;

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: isCritical
            ? const Color(0xFFFFE9EA)
            : isLow
            ? const Color(0xFFFFF0DC)
            : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: CandyColors.ink, width: 2.5),
        boxShadow: const [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_rounded, size: 18, color: fg),
          const SizedBox(width: 4),
          Text(
            '$remaining초',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: fg,
            ),
          ),
        ],
      ),
    );
    if (!isCritical) return badge;
    return TweenAnimationBuilder<double>(
      key: ValueKey(remaining),
      tween: Tween(begin: 1.2, end: 1.0),
      duration: const Duration(milliseconds: 350),
      curve: Curves.elasticOut,
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: badge,
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
          DuoMascot(size: 110, color: accentColor),
          const SizedBox(height: 18),
          const Text(
            '상대를 찾는 중',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
          const SizedBox(height: 14),
          _BouncingDots(color: accentColor),
          const SizedBox(height: 32),
          ChunkyButton(
            label: '취소',
            color: Colors.white,
            textColor: CandyColors.ink,
            height: 46,
            fontSize: 16,
            expand: false,
            onPressed: onCancel,
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
          PopIn(
            child: DuoMascot(
              size: 100,
              color: accentColor,
              mood: MascotMood.cheer,
            ),
          ),
          const SizedBox(height: 16),
          if (opponentNickname != null) ...[
            Text(
              opponentNickname!,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: accentColor,
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            isSolo ? '랭킹 도전 준비 중...' : '게임 시작 준비 중...',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: CandyColors.inkSoft,
            ),
          ),
          const SizedBox(height: 16),
          _BouncingDots(color: accentColor),
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
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DuoMascot(size: 100, color: theme.primary),
            const SizedBox(height: 16),
            const Text(
              '게임 준비 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
            const SizedBox(height: 12),
            _BouncingDots(color: theme.primary),
          ],
        ),
      ),
    );
  }
}
