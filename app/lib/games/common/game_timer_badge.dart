import 'package:flutter/material.dart';

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
    final foreground = isWarning ? const Color(0xFFDC2626) : accentColor;
    final background = isWarning
        ? const Color(0xFFFEF2F2)
        : accentColor.withValues(alpha: compact ? 0.08 : 0.12);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 20,
        vertical: compact ? 8 : 11,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(compact ? 20 : 24),
        border: Border.all(
          color: foreground.withValues(alpha: isWarning ? 0.24 : 0.18),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: foreground.withValues(alpha: compact ? 0.08 : 0.14),
            blurRadius: compact ? 10 : 16,
            offset: const Offset(0, 6),
          ),
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
              fontWeight: FontWeight.w800,
              color: foreground,
            ),
          ),
          if (showLabel) ...[
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: compact ? 12 : 13,
                fontWeight: FontWeight.w600,
                color: foreground.withValues(alpha: 0.8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
