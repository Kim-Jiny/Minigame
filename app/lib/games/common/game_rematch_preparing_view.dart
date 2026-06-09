import 'package:flutter/material.dart';

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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 30),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFFECEDF1)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 28,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.refresh_rounded, color: accentColor, size: 32),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: accentColor,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '재대결 준비 중',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1F2430),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '곧 새 게임이 시작됩니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              if (onCancel != null) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: onCancel,
                  child: Text(
                    '취소',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
