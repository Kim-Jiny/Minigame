import 'package:flutter/material.dart';

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
          width: 118,
          height: 118,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.14),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.2),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Icon(icon, size: 60, color: color),
        ),
        const SizedBox(height: 24),
        Text(
          title,
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
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
          backgroundColor: accentColor,
          foregroundColor: Colors.white,
        );
        final rightCard = _MetricCard(
          label: rightLabel,
          value: rightValue,
          backgroundColor: const Color(0xFFF3F4F6),
          foregroundColor: const Color(0xFF111827),
        );
        final separator = Text(
          useVerticalLayout ? 'VS' : ':',
          style: TextStyle(
            fontSize: useVerticalLayout ? 18 : 32,
            fontWeight: FontWeight.w900,
            color: accentColor.withValues(alpha: 0.8),
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
  final Color backgroundColor;
  final Color foregroundColor;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 116,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: backgroundColor.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: foregroundColor.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: foregroundColor,
            ),
          ),
        ],
      ),
    );
  }
}
