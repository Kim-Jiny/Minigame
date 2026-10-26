import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';

enum MascotMood { happy, cheer, wink, sad }

/// 듀오 마스코트(둥글둥글 젤리 친구). 숨쉬기 + 눈 깜빡임이 자동 재생된다.
class DuoMascot extends StatefulWidget {
  final double size;
  final Color color;
  final MascotMood mood;
  final bool animate;

  /// 몸 위에 얹는 액세서리(ribbon|sunglasses|headphones|cap|wizard|flower|party|crown|halo|horns). null/none 이면 없음.
  final String? accessory;

  const DuoMascot({
    super.key,
    this.size = 96,
    this.color = CandyColors.pink,
    this.mood = MascotMood.happy,
    this.animate = true,
    this.accessory,
  });

  @override
  State<DuoMascot> createState() => _DuoMascotState();
}

class _DuoMascotState extends State<DuoMascot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _MascotPainter(
            widget.color,
            widget.mood,
            _c.value,
            widget.accessory,
          ),
        ),
      ),
    );
  }
}

class _MascotPainter extends CustomPainter {
  final Color color;
  final MascotMood mood;
  final double t;
  final String? accessory;
  _MascotPainter(this.color, this.mood, this.t, [this.accessory]);

  Paint get _line => Paint()
    ..color = CandyColors.ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size s) {
    final u = s.width / 100;
    final breathe = math.sin(t * math.pi * 2);
    final bounce = mood == MascotMood.cheer
        ? -math.sin(t * math.pi * 8).abs() * 6 * u
        : 0.0;
    canvas.save();
    canvas.translate(0, bounce);
    // 숨쉬기: 아래 중심 스쿼시/스트레치
    canvas.translate(50 * u, 92 * u);
    canvas.scale(1 - breathe * 0.015, 1 + breathe * 0.03);
    canvas.translate(-50 * u, -92 * u);

    // 그림자
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(50 * u, 94 * u),
        width: 58 * u,
        height: 8 * u,
      ),
      Paint()..color = CandyColors.ink.withValues(alpha: 0.15),
    );

    // 귀
    for (final dx in [-1.0, 1.0]) {
      final ear = Rect.fromCenter(
        center: Offset((50 + dx * 24) * u, 20 * u),
        width: 22 * u,
        height: 26 * u,
      );
      canvas.save();
      canvas.translate(ear.center.dx, ear.center.dy);
      canvas.rotate(dx * 0.35);
      final r = Rect.fromCenter(
        center: Offset.zero,
        width: ear.width,
        height: ear.height,
      );
      canvas.drawOval(r, Paint()..color = color);
      canvas.drawOval(r, _line);
      canvas.drawOval(
        r.deflate(5 * u),
        Paint()..color = Colors.white.withValues(alpha: 0.5),
      );
      canvas.restore();
    }

    // 몸
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(10 * u, 24 * u, 80 * u, 68 * u),
      Radius.elliptical(40 * u, 34 * u),
    );
    canvas.drawRRect(body, Paint()..color = color);
    // 배
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(50 * u, 76 * u),
        width: 44 * u,
        height: 26 * u,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.45),
    );
    // 하이라이트
    canvas.drawArc(
      Rect.fromLTWH(18 * u, 30 * u, 28 * u, 24 * u),
      math.pi * 1.05,
      math.pi * 0.5,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 * u
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawRRect(body, _line);

    // 볼터치
    final blush = Paint()
      ..color = const Color(0xFFFF4D7D).withValues(alpha: 0.35);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(26 * u, 62 * u),
        width: 14 * u,
        height: 8 * u,
      ),
      blush,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(74 * u, 62 * u),
        width: 14 * u,
        height: 8 * u,
      ),
      blush,
    );

    // 눈 (깜빡임: 주기의 일부 구간에서 닫힘)
    final blink = (t > 0.62 && t < 0.67) || (t > 0.72 && t < 0.76);
    for (final dx in [-1.0, 1.0]) {
      final c = Offset((50 + dx * 17) * u, 52 * u);
      final winkClosed = mood == MascotMood.wink && dx > 0;
      if (blink || winkClosed || mood == MascotMood.cheer) {
        final p = Path()
          ..moveTo(c.dx - 7 * u, c.dy + (mood == MascotMood.cheer ? 2 * u : 0))
          ..quadraticBezierTo(
            c.dx,
            c.dy - (mood == MascotMood.cheer ? 9 * u : -2 * u),
            c.dx + 7 * u,
            c.dy + (mood == MascotMood.cheer ? 2 * u : 0),
          );
        canvas.drawPath(p, _line);
      } else {
        final eye = Rect.fromCenter(center: c, width: 12 * u, height: 16 * u);
        canvas.drawOval(eye, Paint()..color = CandyColors.ink);
        canvas.drawCircle(
          c.translate(-2.2 * u, -3.5 * u),
          2.8 * u,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          c.translate(2 * u, 3 * u),
          1.4 * u,
          Paint()..color = Colors.white,
        );
      }
    }

    // 입
    final m = Offset(50 * u, 66 * u);
    switch (mood) {
      case MascotMood.sad:
        canvas.drawPath(
          Path()
            ..moveTo(m.dx - 6 * u, m.dy + 4 * u)
            ..quadraticBezierTo(m.dx, m.dy - 3 * u, m.dx + 6 * u, m.dy + 4 * u),
          _line,
        );
      case MascotMood.cheer:
        final mouth = Path()
          ..moveTo(m.dx - 9 * u, m.dy - 3 * u)
          ..quadraticBezierTo(m.dx, m.dy + 18 * u, m.dx + 9 * u, m.dy - 3 * u)
          ..close();
        canvas.drawPath(mouth, Paint()..color = const Color(0xFF7A2A4A));
        canvas.drawPath(mouth, _line);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(m.dx, m.dy + 6 * u),
            width: 8 * u,
            height: 5 * u,
          ),
          Paint()..color = const Color(0xFFFF8FB1),
        );
      default:
        canvas.drawPath(
          Path()
            ..moveTo(m.dx - 7 * u, m.dy)
            ..quadraticBezierTo(m.dx, m.dy + 9 * u, m.dx + 7 * u, m.dy),
          _line,
        );
    }

    // 발
    for (final dx in [-1.0, 1.0]) {
      final f = Rect.fromCenter(
        center: Offset((50 + dx * 20) * u, 91 * u),
        width: 18 * u,
        height: 10 * u,
      );
      canvas.drawOval(f, Paint()..color = CandyColors.deepen(color, 0.08));
      canvas.drawOval(f, _line);
    }
    if (accessory != null) _paintAccessory(canvas, u);
    canvas.restore();
  }

  void _shape(Canvas canvas, Path p, Color col, double u) {
    canvas.drawPath(p, Paint()..color = col);
    canvas.drawPath(p, _line);
  }

  Path _poly(double u, List<double> xy) {
    final p = Path();
    for (var i = 0; i < xy.length; i += 2) {
      i == 0
          ? p.moveTo(xy[i] * u, xy[i + 1] * u)
          : p.lineTo(xy[i] * u, xy[i + 1] * u);
    }
    return p..close();
  }

  Rect _r(double u, double l, double t, double w, double h) =>
      Rect.fromLTWH(l * u, t * u, w * u, h * u);

  void _paintAccessory(Canvas canvas, double u) {
    switch (accessory) {
      case 'ribbon':
        const c = Color(0xFFFF4D7D);
        _shape(canvas, _poly(u, [66, 22, 82, 12, 82, 32]), c, u);
        _shape(canvas, _poly(u, [66, 22, 50, 12, 50, 32]), c, u);
        canvas.drawCircle(Offset(66 * u, 22 * u), 5 * u, Paint()..color = const Color(0xFFFFB3C7));
        canvas.drawCircle(Offset(66 * u, 22 * u), 5 * u, _line);
      case 'sunglasses':
        for (final x in [33.0, 67.0]) {
          final r = RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x * u, 52 * u), width: 24 * u, height: 16 * u),
            Radius.circular(6 * u),
          );
          canvas.drawRRect(r, Paint()..color = CandyColors.ink);
          canvas.drawRRect(r, _line);
          canvas.drawLine(
            Offset((x - 7) * u, 48 * u),
            Offset((x - 2) * u, 48 * u),
            Paint()
              ..color = Colors.white.withValues(alpha: 0.8)
              ..strokeWidth = 2.4 * u
              ..strokeCap = StrokeCap.round,
          );
        }
        canvas.drawLine(Offset(45 * u, 52 * u), Offset(55 * u, 52 * u), _line);
      case 'headphones':
        final band = Path()
          ..moveTo(12 * u, 50 * u)
          ..quadraticBezierTo(50 * u, -8 * u, 88 * u, 50 * u);
        canvas.drawPath(
          band,
          Paint()
            ..color = CandyColors.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8 * u
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawPath(
          band,
          Paint()
            ..color = CandyColors.sky
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.4 * u
            ..strokeCap = StrokeCap.round,
        );
        for (final x in [4.0, 84.0]) {
          final r = RRect.fromRectAndRadius(_r(u, x, 42, 12, 24), Radius.circular(5 * u));
          canvas.drawRRect(r, Paint()..color = CandyColors.sky);
          canvas.drawRRect(r, _line);
        }
      case 'cap':
        final dome = Path()
          ..moveTo(22 * u, 32 * u)
          ..quadraticBezierTo(24 * u, 6 * u, 52 * u, 8 * u)
          ..quadraticBezierTo(78 * u, 10 * u, 80 * u, 32 * u)
          ..close();
        _shape(canvas, dome, CandyColors.sky, u);
        final brim = Path()
          ..moveTo(60 * u, 30 * u)
          ..quadraticBezierTo(90 * u, 26 * u, 96 * u, 36 * u)
          ..quadraticBezierTo(74 * u, 38 * u, 56 * u, 34 * u)
          ..close();
        _shape(canvas, brim, CandyColors.skyDeep, u);
        canvas.drawCircle(Offset(51 * u, 8 * u), 3 * u, Paint()..color = CandyColors.skyDeep);
      case 'wizard':
        _shape(canvas, _poly(u, [30, 30, 52, 0, 72, 30]), CandyColors.grape, u);
        canvas.drawOval(_r(u, 22, 26, 58, 12), Paint()..color = CandyColors.grapeDeep);
        canvas.drawOval(_r(u, 22, 26, 58, 12), _line);
        canvas.drawCircle(Offset(52 * u, 17 * u), 3.4 * u, Paint()..color = CandyColors.sun);
      case 'flower':
        final ctr = Offset(30 * u, 22 * u);
        for (var i = 0; i < 5; i++) {
          final a = i * math.pi * 2 / 5;
          final o = ctr + Offset(math.cos(a), math.sin(a)) * 7 * u;
          canvas.drawCircle(o, 5.4 * u, Paint()..color = const Color(0xFFFFB3C7));
          canvas.drawCircle(o, 5.4 * u, _line..strokeWidth = 2.2 * u);
        }
        canvas.drawCircle(ctr, 4.4 * u, Paint()..color = CandyColors.sun);
        canvas.drawCircle(ctr, 4.4 * u, _line);
      case 'party':
        canvas.save();
        canvas.translate(50 * u, 28 * u);
        canvas.rotate(0.22);
        canvas.translate(-50 * u, -28 * u);
        _shape(canvas, _poly(u, [36, 30, 50, -2, 64, 30]), CandyColors.pink, u);
        canvas.drawLine(Offset(41 * u, 20 * u), Offset(59 * u, 24 * u), Paint()..color = CandyColors.sun..strokeWidth = 3.4 * u);
        canvas.drawCircle(Offset(50 * u, -1 * u), 4 * u, Paint()..color = CandyColors.sun);
        canvas.drawCircle(Offset(50 * u, -1 * u), 4 * u, _line);
        canvas.restore();
      case 'crown':
        final crown = Path()
          ..moveTo(30 * u, 30 * u)
          ..lineTo(28 * u, 8 * u)
          ..lineTo(40 * u, 19 * u)
          ..lineTo(50 * u, 4 * u)
          ..lineTo(60 * u, 19 * u)
          ..lineTo(72 * u, 8 * u)
          ..lineTo(70 * u, 30 * u)
          ..close();
        _shape(canvas, crown, CandyColors.sun, u);
        canvas.drawCircle(Offset(50 * u, 23 * u), 3 * u, Paint()..color = CandyColors.pink);
      case 'halo':
        final ring = Rect.fromCenter(center: Offset(50 * u, 8 * u), width: 38 * u, height: 12 * u);
        canvas.drawOval(
          ring,
          Paint()
            ..color = CandyColors.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8 * u,
        );
        canvas.drawOval(
          ring,
          Paint()
            ..color = CandyColors.sun
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.6 * u,
        );
      case 'horns':
        const c = Color(0xFFE5484D);
        _shape(canvas, _poly(u, [26, 32, 18, 6, 40, 26]), c, u);
        _shape(canvas, _poly(u, [74, 32, 82, 6, 60, 26]), c, u);
    }
  }

  @override
  bool shouldRepaint(_MascotPainter old) =>
      old.t != t ||
      old.color != color ||
      old.mood != mood ||
      old.accessory != accessory;
}
