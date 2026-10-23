import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';

class GameTimerBadge extends StatelessWidget {
  final int seconds;
  final String label;
  final Color accentColor;
  final bool compact;
  final int warningThreshold;
  final bool showLabel;

  const GameTimerBadge({
    super.key,
    required this.seconds,
    required this.label,
    required this.accentColor,
    this.compact = false,
    this.warningThreshold = 3,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final isWarning = seconds <= warningThreshold;
    final foreground = isWarning ? const Color(0xFFE5484D) : accentColor;

    final badge = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 20,
        vertical: compact ? 7 : 10,
      ),
      decoration: BoxDecoration(
        color: isWarning ? const Color(0xFFFFE9EA) : Colors.white,
        borderRadius: BorderRadius.circular(compact ? 20 : 24),
        border: Border.all(color: CandyColors.ink, width: 2.5),
        boxShadow: const [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_rounded, color: foreground, size: compact ? 20 : 24),
          const SizedBox(width: 8),
          Text(
            '$seconds초',
            style: TextStyle(
              fontSize: compact ? 18 : 24,
              fontWeight: FontWeight.w900,
              color: foreground,
            ),
          ),
          if (showLabel) ...[
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: compact ? 12 : 13,
                fontWeight: FontWeight.w800,
                color: CandyColors.inkSoft,
              ),
            ),
          ],
        ],
      ),
    );

    // 경고 구간에는 매초 통통 뛴다.
    if (!isWarning) return badge;
    return TweenAnimationBuilder<double>(
      key: ValueKey(seconds),
      tween: Tween(begin: 1.18, end: 1.0),
      duration: const Duration(milliseconds: 350),
      curve: Curves.elasticOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: badge,
    );
  }
}
