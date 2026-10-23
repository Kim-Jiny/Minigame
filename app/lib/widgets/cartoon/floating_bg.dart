import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';

/// 크림색 배경 위에 점·동그라미·별이 천천히 떠다니는 카툰 배경.
class FloatingBackground extends StatefulWidget {
  final Widget child;
  const FloatingBackground({super.key, required this.child});

  @override
  State<FloatingBackground> createState() => _FloatingBackgroundState();
}

class _FloatingBackgroundState extends State<FloatingBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: CandyColors.cream),
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) => CustomPaint(painter: _BgPainter(_c.value)),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _BgPainter extends CustomPainter {
  final double t;
  _BgPainter(this.t);

  static const _colors = [
    CandyColors.pink,
    CandyColors.sky,
    CandyColors.sun,
    CandyColors.mint,
    CandyColors.grape,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    for (var i = 0; i < 16; i++) {
      final baseX = rnd.nextDouble();
      final baseY = rnd.nextDouble();
      final r = 5 + rnd.nextDouble() * 9;
      final speed = 1 + rnd.nextInt(2);
      final phase = rnd.nextDouble() * math.pi * 2;
      final x =
          (baseX + math.sin(t * math.pi * 2 * speed + phase) * 0.03) *
          size.width;
      final y = ((baseY - t * speed) % 1.0) * size.height;
      final color = _colors[i % _colors.length].withValues(alpha: 0.22);
      final p = Paint()..color = color;
      switch (i % 3) {
        case 0:
          canvas.drawCircle(Offset(x, y), r, p);
        case 1:
          canvas.drawCircle(
            Offset(x, y),
            r,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3,
          );
        default:
          _star(canvas, Offset(x, y), r + 3, p, t * math.pi * 2 + phase);
      }
    }
  }

  void _star(Canvas canvas, Offset c, double r, Paint p, double rot) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final rad = i.isEven ? r : r * 0.45;
      final a = rot + i * math.pi / 4;
      final pt = Offset(c.dx + math.cos(a) * rad, c.dy + math.sin(a) * rad);
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(path..close(), p);
  }

  @override
  bool shouldRepaint(_BgPainter old) => old.t != t;
}
