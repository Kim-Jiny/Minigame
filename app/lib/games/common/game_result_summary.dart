import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';
import '../../widgets/cartoon/confetti_burst.dart';
import '../../widgets/cartoon/duo_mascot.dart';
import '../../widgets/cartoon/pop_in.dart';

/// 랭크전 종료 시 잠깐 보여주는 결과 화면(승/패/무 + 자동 복귀 안내).
/// 모든 랭크 지원 게임이 동일하게 사용한다. (자동 복귀 예약은 각 게임에서 호출)
class GameRankedResultView extends StatelessWidget {
  final Gradient backgroundGradient;
  final Color accentColor;
  final bool isWinner;
  final bool isDraw;

  /// 결과 문구 아래 추가로 표시할 위젯(예: 점수). 없으면 생략.
  final Widget? extra;

  const GameRankedResultView({
    super.key,
    required this.backgroundGradient,
    required this.accentColor,
    required this.isWinner,
    required this.isDraw,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDraw
        ? CandyColors.tangerine
        : (isWinner ? accentColor : CandyColors.inkSoft);
    return Container(
      decoration: BoxDecoration(gradient: backgroundGradient),
      child: Stack(
        children: [
          if (isWinner && !isDraw)
            const Positioned.fill(child: ConfettiBurst()),
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PopIn(
                  child: DuoMascot(
                    size: 130,
                    color: isWinner && !isDraw ? accentColor : CandyColors.sky,
                    mood: isDraw
                        ? MascotMood.wink
                        : (isWinner ? MascotMood.cheer : MascotMood.sad),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isDraw ? '무승부!' : (isWinner ? '승리!' : '패배'),
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    color: color,
                    letterSpacing: -0.5,
                  ),
                ),
                if (extra != null) ...[const SizedBox(height: 8), extra!],
                const SizedBox(height: 24),
                const Text(
                  '잠시 후 다음 게임...',
                  style: TextStyle(
                    color: CandyColors.inkSoft,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class GameResultHero extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;

  const GameResultHero({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final won =
        icon == Icons.emoji_events_rounded || icon == Icons.emoji_events;
    final draw = icon == Icons.handshake_rounded || icon == Icons.handshake;
    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (won)
              const Positioned(
                left: -160,
                right: -160,
                top: -40,
                height: 460,
                child: ConfettiBurst(),
              ),
            PopIn(
              child: DuoMascot(
                size: 124,
                color: won ? color : CandyColors.sky,
                mood: won
                    ? MascotMood.cheer
                    : (draw ? MascotMood.wink : MascotMood.sad),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          title,
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
            color: won ? color : CandyColors.ink,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w700,
              color: CandyColors.inkSoft,
            ),
          ),
        ],
      ],
    );
  }
}

class GameResultStatusPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final Color? backgroundColor;
  final Color? borderColor;

  const GameResultStatusPill({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
    this.backgroundColor,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor ?? CandyColors.ink, width: 2.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class GameResultMatchupRow extends StatelessWidget {
  final String leftLabel;
  final String leftValue;
  final String rightLabel;
  final String rightValue;
  final Color accentColor;

  const GameResultMatchupRow({
    super.key,
    required this.leftLabel,
    required this.leftValue,
    required this.rightLabel,
    required this.rightValue,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 아주 좁은 화면에서만 세로로 쌓는다(대부분 기기는 가로 유지).
        final useVerticalLayout = constraints.maxWidth < 250;

        final leftCard = _MetricCard(
          label: leftLabel,
          value: leftValue,
          accentColor: accentColor,
          highlighted: true,
        );
        final rightCard = _MetricCard(
          label: rightLabel,
          value: rightValue,
          accentColor: accentColor,
          highlighted: false,
        );
        final separator = Text(
          useVerticalLayout ? 'VS' : ':',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: CandyColors.inkSoft,
          ),
        );

        if (useVerticalLayout) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 180, child: leftCard),
              const SizedBox(height: 12),
              separator,
              const SizedBox(height: 12),
              SizedBox(width: 180, child: rightCard),
            ],
          );
        }

        // 카드가 남는 폭을 균등 분배(Expanded)해 작은 기기에서도 한 줄에 들어간다.
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Row(
              children: [
                Expanded(child: leftCard),
                const SizedBox(width: 12),
                separator,
                const SizedBox(width: 12),
                Expanded(child: rightCard),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final Color accentColor;
  final bool highlighted;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.accentColor,
    required this.highlighted,
  });

  @override
  Widget build(BuildContext context) {
    return CartoonCard(
      color: highlighted ? accentColor.withValues(alpha: 0.12) : Colors.white,
      radius: 20,
      shadow: 4,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      child: Column(
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: highlighted ? accentColor : CandyColors.inkSoft,
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: highlighted ? accentColor : CandyColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
