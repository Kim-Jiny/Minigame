import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';
import 'duo_mascot.dart';

/// 로고: 마스코트 둘(핑크·스카이)이 마주 보고 아래에 워드마크.
class DuoLogo extends StatelessWidget {
  final double size;
  final bool showWordmark;
  const DuoLogo({super.key, this.size = 72, this.showWordmark = true});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DuoMascot(
              size: size,
              color: CandyColors.pink,
              mood: MascotMood.wink,
            ),
            SizedBox(width: size * 0.06),
            DuoMascot(
              size: size,
              color: CandyColors.sky,
              mood: MascotMood.happy,
            ),
          ],
        ),
        if (showWordmark) ...[
          SizedBox(height: size * 0.12),
          Stack(
            children: [
              Text(
                '듀오 아레나',
                style: _style(size).copyWith(
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = size * 0.16
                    ..strokeJoin = StrokeJoin.round
                    ..color = CandyColors.ink,
                ),
              ),
              Text(
                '듀오 아레나',
                style: _style(size).copyWith(color: CandyColors.sun),
              ),
            ],
          ),
        ],
      ],
    );
  }

  TextStyle _style(double s) => TextStyle(
    fontSize: s * 0.46,
    fontWeight: FontWeight.w900,
    letterSpacing: -0.5,
  );
}
