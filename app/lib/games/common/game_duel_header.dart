import 'package:flutter/material.dart';
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
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: backgroundColors),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
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
            child: centerWidget ??
                Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Text(
                        centerLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: backgroundColors.last.computeLuminance() > 0.4
                              ? const Color(0xFF111827)
                              : Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (centerSubtitle != null)
                      Text(
                        centerSubtitle!,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.88),
                          letterSpacing: 0.2,
                        ),
                      )
                    else
                      Text(
                        'VS',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: Colors.white.withValues(alpha: 0.92),
                          letterSpacing: 0.6,
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
    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$score',
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: Colors.white,
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
            color: index < active ? activeColor : Colors.grey.shade300,
          ),
        );
      }),
    );
  }
}
