import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';
import '../../models/shop_item.dart';
import '../../widgets/game_player_profile.dart';

class GameDuelHeader extends StatelessWidget {
  final List<Color> backgroundColors;
  final Color accentColor;
  final String centerLabel;
  final String? centerSubtitle;
  final String myName;
  final String opponentName;
  final String? myAvatarUrl;
  final String? opponentAvatarUrl;
  final bool myActive;
  final bool opponentActive;
  final UserProfileSettings? myProfileSettings;
  final UserProfileSettings? opponentProfileSettings;
  final Widget? myExtraWidget;
  final Widget? opponentExtraWidget;
  final Widget? centerWidget;

  const GameDuelHeader({
    super.key,
    required this.backgroundColors,
    required this.accentColor,
    required this.centerLabel,
    this.centerSubtitle,
    required this.myName,
    required this.opponentName,
    this.myAvatarUrl,
    this.opponentAvatarUrl,
    required this.myActive,
    required this.opponentActive,
    this.myProfileSettings,
    this.opponentProfileSettings,
    this.myExtraWidget,
    this.opponentExtraWidget,
    this.centerWidget,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: CartoonCard(
        radius: 24,
        shadow: 4,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: GamePlayerProfile(
                name: myName,
                avatarUrl: myAvatarUrl,
                isActive: myActive,
                isMe: true,
                profileSettings: myProfileSettings,
                activeColor: accentColor,
                extraWidget: myExtraWidget,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child:
                  centerWidget ??
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: CandyColors.ink, width: 2),
                        ),
                        child: Text(
                          centerLabel,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: accentColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        centerSubtitle ?? 'VS',
                        style: TextStyle(
                          fontSize: centerSubtitle != null ? 11 : 14,
                          fontWeight: FontWeight.w900,
                          color: CandyColors.inkSoft,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
            ),
            Expanded(
              child: GamePlayerProfile(
                name: opponentName,
                avatarUrl: opponentAvatarUrl,
                isActive: opponentActive,
                isMe: false,
                profileSettings: opponentProfileSettings,
                activeColor: accentColor,
                extraWidget: opponentExtraWidget,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GameHeaderScorePill extends StatelessWidget {
  final int score;
  final Color color;
  final EdgeInsetsGeometry? margin;

  const GameHeaderScorePill({
    super.key,
    required this.score,
    required this.color,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(score),
      tween: Tween(begin: 1.45, end: 1.0),
      duration: const Duration(milliseconds: 420),
      curve: Curves.elasticOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: Container(
        margin: margin,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CandyColors.ink, width: 2),
        ),
        child: Text(
          '$score',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class GameHeaderStatusPill extends StatelessWidget {
  final String text;
  final Color color;
  final EdgeInsetsGeometry? margin;

  const GameHeaderStatusPill({
    super.key,
    required this.text,
    required this.color,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: CandyColors.ink, width: 1.5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class GameHeaderStarTrack extends StatelessWidget {
  final int total;
  final int active;
  final Color activeColor;

  const GameHeaderStarTrack({
    super.key,
    required this.total,
    required this.active,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (index) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Icon(
            index < active ? Icons.star_rounded : Icons.star_border_rounded,
            size: 14,
            color: index < active ? activeColor : const Color(0xFFD9D2EA),
          ),
        );
      }),
    );
  }
}
