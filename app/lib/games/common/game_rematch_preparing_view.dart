import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/duo_mascot.dart';

/// 재대결 대기/시작 중에 이전 판 결과 대신 보여주는 "준비 중" 화면.
/// 결과 화면이 전환 애니메이션 중 잠깐 노출되는 것을 막는다.
class GameRematchPreparingView extends StatelessWidget {
  final Gradient backgroundGradient;
  final Color accentColor;
  final VoidCallback? onCancel;

  const GameRematchPreparingView({
    super.key,
    required this.backgroundGradient,
    required this.accentColor,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(gradient: backgroundGradient),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DuoMascot(size: 110, color: accentColor, mood: MascotMood.cheer),
              const SizedBox(height: 14),
              const Text(
                '재대결 준비 중',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '곧 새 게임이 시작됩니다.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: CandyColors.inkSoft,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 140,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 8,
                    color: accentColor,
                    backgroundColor: accentColor.withValues(alpha: 0.18),
                  ),
                ),
              ),
              if (onCancel != null) ...[
                const SizedBox(height: 24),
                ChunkyButton(
                  label: '취소',
                  color: Colors.white,
                  textColor: CandyColors.ink,
                  height: 44,
                  fontSize: 15,
                  expand: false,
                  onPressed: onCancel,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
