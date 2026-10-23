import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';

class GameStagePanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color accentColor;
  final Widget? content;
  final EdgeInsetsGeometry margin;
  final bool compact;

  const GameStagePanel({
    super.key,
    required this.icon,
    required this.title,
    required this.accentColor,
    this.subtitle,
    this.content,
    this.margin = const EdgeInsets.symmetric(horizontal: 24),
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: CartoonCard(
        radius: 28,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 20 : 24,
          vertical: compact ? 20 : 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: compact ? 56 : 64,
              height: compact ? 56 : 64,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.16),
                shape: BoxShape.circle,
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
              child: Icon(icon, size: compact ? 28 : 32, color: accentColor),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: compact ? 24 : 28,
                fontWeight: FontWeight.w900,
                color: accentColor,
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
            if (content != null) ...[const SizedBox(height: 18), content!],
          ],
        ),
      ),
    );
  }
}
