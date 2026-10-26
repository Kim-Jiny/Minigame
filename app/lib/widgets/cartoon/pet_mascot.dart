import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'duo_mascot.dart';

/// 게임 화면 프로필 옆에서 펫처럼 움직이는 마스코트.
/// - 평소: 둥실둥실 떠다니며 살짝 기울어진다.
/// - [active] 가 켜지는 순간(내 차례 등): 통통 점프하며 신난 표정.
/// - 탭하면 점프 + 신난 표정(귀여움 상호작용).
class PetMascot extends StatefulWidget {
  final double size;
  final Color color;
  final String? accessory;
  final bool active;

  /// 아바타가 오른쪽에 있으면 오른쪽을 보게(좌우 반전) 한다.
  final bool faceLeft;

  const PetMascot({
    super.key,
    this.size = 32,
    required this.color,
    this.accessory,
    this.active = false,
    this.faceLeft = false,
  });

  @override
  State<PetMascot> createState() => _PetMascotState();
}

class _PetMascotState extends State<PetMascot> with TickerProviderStateMixin {
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();
  late final AnimationController _hop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  bool _excited = false;

  @override
  void didUpdateWidget(PetMascot old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _jump();
  }

  void _jump() {
    if (!mounted) return;
    setState(() => _excited = true);
    _hop.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _excited = widget.active);
    });
  }

  @override
  void dispose() {
    _idle.dispose();
    _hop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mood = (_excited || widget.active) ? MascotMood.cheer : MascotMood.happy;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        _jump();
      },
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_idle, _hop]),
          builder: (_, child) {
            final float = math.sin(_idle.value * math.pi * 2) * widget.size * 0.05;
            final tilt = math.sin(_idle.value * math.pi * 2 + 1.2) * 0.07;
            // 점프: 위로 솟았다가 탄성 있게 착지.
            final h = _hop.value;
            final jump = h == 0
                ? 0.0
                : -math.sin(h * math.pi) * widget.size * 0.55 * (1 - h * 0.35);
            final squash = h == 0 ? 1.0 : 1 + math.sin(h * math.pi * 3) * 0.06 * (1 - h);
            return Transform.translate(
              offset: Offset(0, float + jump),
              child: Transform.rotate(
                angle: tilt,
                child: Transform(
                  alignment: Alignment.bottomCenter,
                  transform: Matrix4.diagonal3Values(
                    widget.faceLeft ? -squash : squash,
                    2 - squash,
                    1,
                  ),
                  child: child,
                ),
              ),
            );
          },
          child: DuoMascot(
            size: widget.size,
            color: widget.color,
            accessory: widget.accessory,
            mood: mood,
          ),
        ),
      ),
    );
  }
}
