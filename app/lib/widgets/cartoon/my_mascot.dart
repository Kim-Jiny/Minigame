import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/shop_provider.dart';
import '../../theme/candy_theme.dart';
import 'duo_mascot.dart';

/// 내가 장착한 마스코트 스킨(색 + 액세서리)으로 그린 [DuoMascot]. 장착이 없으면 기본 마스코트.
class MyMascot extends StatelessWidget {
  final double size;
  final MascotMood mood;
  final bool animate;

  const MyMascot({
    super.key,
    this.size = 96,
    this.mood = MascotMood.happy,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    final info = context.select<ShopProvider, (Color, String?)?>(
      (p) => p.profileSettings?.getMascotInfo(),
    );
    return DuoMascot(
      size: size,
      mood: mood,
      animate: animate,
      color: info?.$1 ?? CandyColors.pink,
      accessory: info?.$2,
    );
  }
}
