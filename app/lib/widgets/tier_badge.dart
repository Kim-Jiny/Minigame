import 'package:flutter/material.dart';
import '../theme/candy_theme.dart';

class TierBadge extends StatelessWidget {
  final String tier;
  final String tierColor;
  final int elo;
  final bool showElo;
  final double size;

  const TierBadge({
    super.key,
    required this.tier,
    required this.tierColor,
    this.elo = 0,
    this.showElo = true,
    this.size = 1.0,
  });

  Color get _tierColor {
    try {
      return Color(int.parse(tierColor.replaceFirst('#', '0xFF')));
    } catch (_) {
      return CandyColors.inkSoft;
    }
  }

  IconData get _tierIcon {
    switch (tier) {
      case 'Iron':
        return Icons.shield_outlined;
      case 'Bronze':
        return Icons.shield;
      case 'Silver':
        return Icons.shield;
      case 'Gold':
        return Icons.shield;
      case 'Platinum':
        return Icons.diamond_outlined;
      case 'Diamond':
        return Icons.diamond;
      case 'Master':
        return Icons.military_tech;
      case 'Challenger':
        return Icons.emoji_events;
      default:
        return Icons.shield_outlined;
    }
  }

  String get _tierName {
    switch (tier) {
      case 'Iron':
        return '아이언';
      case 'Bronze':
        return '브론즈';
      case 'Silver':
        return '실버';
      case 'Gold':
        return '골드';
      case 'Platinum':
        return '플래티넘';
      case 'Diamond':
        return '다이아몬드';
      case 'Master':
        return '마스터';
      case 'Challenger':
        return '챌린저';
      default:
        return tier;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _tierColor;
    final medal = 34 * size;
    return Container(
      padding: EdgeInsets.fromLTRB(5 * size, 5 * size, 14 * size, 5 * size),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(40 * size),
        border: Border.all(color: CandyColors.ink, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: CandyColors.ink,
            offset: Offset(0, 3 * size.clamp(0.7, 1.6)),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: medal,
            height: medal,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c,
              border: Border.all(color: CandyColors.ink, width: 2.5),
            ),
            child: Icon(_tierIcon, color: Colors.white, size: 20 * size),
          ),
          SizedBox(width: 8 * size),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _tierName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: CandyColors.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 14 * size,
                  ),
                ),
                if (showElo)
                  Text(
                    '$elo LP',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: CandyColors.inkSoft,
                      fontWeight: FontWeight.w800,
                      fontSize: 11 * size,
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

class TierBadgeSmall extends StatelessWidget {
  final String tier;
  final String tierColor;

  const TierBadgeSmall({
    super.key,
    required this.tier,
    required this.tierColor,
  });

  Color get _tierColor {
    try {
      return Color(int.parse(tierColor.replaceFirst('#', '0xFF')));
    } catch (_) {
      return CandyColors.inkSoft;
    }
  }

  IconData get _tierIcon {
    switch (tier) {
      case 'Iron':
        return Icons.shield_outlined;
      case 'Bronze':
        return Icons.shield;
      case 'Silver':
        return Icons.shield;
      case 'Gold':
        return Icons.shield;
      case 'Platinum':
        return Icons.diamond_outlined;
      case 'Diamond':
        return Icons.diamond;
      case 'Master':
        return Icons.military_tech;
      case 'Challenger':
        return Icons.emoji_events;
      default:
        return Icons.shield_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: _tierColor,
        shape: BoxShape.circle,
        border: Border.all(color: CandyColors.ink, width: 2.5),
      ),
      child: Icon(_tierIcon, color: Colors.white, size: 18),
    );
  }
}

class TierProgressBar extends StatelessWidget {
  final int currentElo;
  final String currentTier;
  final String tierColor;

  const TierProgressBar({
    super.key,
    required this.currentElo,
    required this.currentTier,
    required this.tierColor,
  });

  Color get _tierColor {
    try {
      return Color(int.parse(tierColor.replaceFirst('#', '0xFF')));
    } catch (_) {
      return CandyColors.inkSoft;
    }
  }

  // 티어 범위 반환
  (int min, int max) get _tierRange {
    switch (currentTier) {
      case 'Iron':
        return (0, 799);
      case 'Bronze':
        return (800, 999);
      case 'Silver':
        return (1000, 1199);
      case 'Gold':
        return (1200, 1399);
      case 'Platinum':
        return (1400, 1599);
      case 'Diamond':
        return (1600, 1799);
      case 'Master':
        return (1800, 1999);
      case 'Challenger':
        return (2000, 9999);
      default:
        return (0, 799);
    }
  }

  double get _progress {
    final (min, max) = _tierRange;
    if (currentTier == 'Challenger') {
      return 1.0; // 챌린저는 항상 풀
    }
    final range = max - min + 1;
    final current = currentElo - min;
    return (current / range).clamp(0.0, 1.0);
  }

  String get _nextTier {
    switch (currentTier) {
      case 'Iron':
        return 'Bronze';
      case 'Bronze':
        return 'Silver';
      case 'Silver':
        return 'Gold';
      case 'Gold':
        return 'Platinum';
      case 'Platinum':
        return 'Diamond';
      case 'Diamond':
        return 'Master';
      case 'Master':
        return 'Challenger';
      case 'Challenger':
        return '';
      default:
        return '';
    }
  }

  int get _eloToNext {
    final (_, max) = _tierRange;
    if (currentTier == 'Challenger') return 0;
    return max - currentElo + 1;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: _progress),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => Container(
            height: 20,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CandyColors.ink, width: 2.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: v.clamp(0.0, 1.0),
                  heightFactor: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: _tierColor,
                      border: v > 0.02
                          ? const Border(
                              right: BorderSide(
                                color: CandyColors.ink,
                                width: 2.5,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        if (_nextTier.isNotEmpty)
          Text(
            '다음 티어까지 $_eloToNext LP',
            style: const TextStyle(
              color: CandyColors.inkSoft,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          )
        else
          Text(
            '최고 티어 달성!',
            style: TextStyle(
              color: CandyColors.deepen(_tierColor),
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
      ],
    );
  }
}
