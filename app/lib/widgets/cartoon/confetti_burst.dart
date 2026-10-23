import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';

/// 한 번 터지는 컨페티. 위로 솟았다가 중력으로 떨어지며 사라진다. 터치는 통과시킨다.
class ConfettiBurst extends StatefulWidget {
  final int count;
  final Duration duration;
  const ConfettiBurst({
    super.key,
    this.count = 46,
    this.duration = const Duration(milliseconds: 2600),
  });

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..forward();
  late final List<_Piece> _pieces = () {
    final rnd = math.Random();
    const colors = [
      CandyColors.pink,
      CandyColors.sky,
      CandyColors.sun,
      CandyColors.mint,
      CandyColors.grape,
      CandyColors.tangerine,
    ];
    return List.generate(widget.count, (_) {
      final angle = -math.pi / 2 + (rnd.nextDouble() - 0.5) * math.pi * 0.95;
      final speed = 380 + rnd.nextDouble() * 520;
      return _Piece(
        vx: math.cos(angle) * speed,
        vy: math.sin(angle) * speed,
        size: 6 + rnd.nextDouble() * 7,
        color: colors[rnd.nextInt(colors.length)],
        spin: (rnd.nextDouble() - 0.5) * 14,
        round: rnd.nextBool(),
      );
    });
  }();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            size: Size.infinite,
            painter: _ConfettiPainter(
              _pieces,
              _c.value,
              widget.duration.inMilliseconds / 1000,
            ),
          ),
        ),
      ),
    );
  }
}

class _Piece {
  final double vx, vy, size, spin;
  final Color color;
  final bool round;
  const _Piece({
    required this.vx,
    required this.vy,
    required this.size,
    required this.color,
    required this.spin,
    required this.round,
  });
}

class _ConfettiPainter extends CustomPainter {
  final List<_Piece> pieces;
  final double t; // 0..1
  final double seconds;
  _ConfettiPainter(this.pieces, this.t, this.seconds);

  @override
  void paint(Canvas canvas, Size size) {
    final time = t * seconds;
    final origin = Offset(size.width / 2, size.height * 0.3);
    const gravity = 900.0;
    final fade = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3);
    for (final p in pieces) {
      final pos =
          origin +
          Offset(
            p.vx * time * 0.55,
            p.vy * time * 0.55 + 0.5 * gravity * time * time * 0.55,
          );
      final paint = Paint()
        ..color = p.color.withValues(alpha: fade.clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.spin * time);
      if (p.round) {
        canvas.drawCircle(Offset.zero, p.size / 2, paint);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: p.size,
              height: p.size * 0.6,
            ),
            const Radius.circular(2),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
