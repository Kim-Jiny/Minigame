import 'package:flutter/material.dart';

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
    return Container(
      decoration: BoxDecoration(gradient: backgroundGradient),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isDraw
                  ? Icons.handshake
                  : (isWinner ? Icons.emoji_events : Icons.sentiment_dissatisfied),
              size: 80,
              color: isDraw
                  ? Colors.orange
                  : (isWinner ? Colors.amber : Colors.grey),
            ),
            const SizedBox(height: 16),
            Text(
              isDraw ? '무승부!' : (isWinner ? '승리!' : '패배'),
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: isDraw
                    ? Colors.orange
                    : (isWinner ? accentColor : Colors.grey),
              ),
            ),
            if (extra != null) ...[
              const SizedBox(height: 8),
              extra!,
            ],
            const SizedBox(height: 24),
            const Text('잠시 후 다음 게임...', style: TextStyle(color: Colors.grey)),
          ],
        ),
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
    return Column(
      children: [
        Container(
          width: 112,
          height: 112,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.10),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.12),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Icon(icon, size: 56, color: color),
        ),
        const SizedBox(height: 22),
        Text(
          title,
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: color,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 10),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: Color(0xFF6B7280),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: backgroundColor ?? color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: borderColor ?? color.withValues(alpha: 0.14),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
            ),
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
        final useVerticalLayout = constraints.maxWidth < 340;

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
            color: Color(0xFFC2C7CF),
          ),
        );

        if (useVerticalLayout) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              leftCard,
              const SizedBox(height: 12),
              separator,
              const SizedBox(height: 12),
              rightCard,
            ],
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(child: leftCard),
            const SizedBox(width: 18),
            separator,
            const SizedBox(width: 18),
            Flexible(child: rightCard),
          ],
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
    return Container(
      width: 124,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: highlighted ? accentColor.withValues(alpha: 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: highlighted
              ? accentColor.withValues(alpha: 0.22)
              : const Color(0xFFECEDF1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF9AA1AC),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: highlighted ? accentColor : const Color(0xFF1A1D23),
            ),
          ),
        ],
      ),
    );
  }
}
