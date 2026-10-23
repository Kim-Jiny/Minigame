import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';

/// Set 카드 한 장. id(0~80)에서 4속성을 디코드해 도형을 그린다.
///  number = (id ~/ 27) % 3  (0,1,2 → 1,2,3개)
///  shape  = (id ~/ 9)  % 3  (0 다이아 / 1 타원 / 2 물결)
///  fill   = (id ~/ 3)  % 3  (0 채움 / 1 빗금 / 2 외곽선)
///  color  = id % 3          (0 빨강 / 1 초록 / 2 보라)
///
/// 캔디 카툰 스타일: 두꺼운 잉크 아웃라인 + 단단한 그림자.
/// 선택 = 들어올리며 살짝 커짐 / 오답 = 좌우 흔들림 + 빨강 / 세트 성공 = 통통 + 반짝.
class SetCard extends StatefulWidget {
  final int cardId;
  final bool selected;
  final bool failed;
  final bool matched; // 누군가 세트로 집어 노란색으로 강조 중
  final Color accent;
  final VoidCallback onTap;

  const SetCard({
    super.key,
    required this.cardId,
    required this.selected,
    required this.failed,
    this.matched = false,
    required this.accent,
    required this.onTap,
  });

  @override
  State<SetCard> createState() => _SetCardState();
}

class _SetCardState extends State<SetCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );
  bool _down = false;

  static const List<Color> _palette = [
    Color(0xFFE5484D), // red
    Color(0xFF1FAF89), // green
    Color(0xFF7655E0), // purple
  ];

  @override
  void didUpdateWidget(covariant SetCard old) {
    super.didUpdateWidget(old);
    if ((!old.failed && widget.failed) || (!old.matched && widget.matched)) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.cardId;
    final number = (id ~/ 27) % 3 + 1;
    final shape = (id ~/ 9) % 3;
    final fill = (id ~/ 3) % 3;
    final color = _palette[id % 3];

    final selected = widget.selected;
    final failed = widget.failed;
    final matched = widget.matched;

    final Color face = matched
        ? const Color(0xFFFFF0A8)
        : failed
        ? const Color(0xFFFFDDE0)
        : selected
        ? Color.lerp(widget.accent, Colors.white, 0.82)!
        : Colors.white;
    final lifted = selected || matched;
    final shadowDy = _down ? 1.0 : (lifted ? 6.0 : 4.0);

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: face,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CandyColors.ink, width: 3),
        boxShadow: [
          if (matched)
            BoxShadow(
              color: CandyColors.sun.withValues(alpha: 0.8),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          BoxShadow(color: CandyColors.ink, offset: Offset(0, shadowDy)),
        ],
      ),
      child: CustomPaint(
        painter: _SetSymbolPainter(
          number: number,
          shape: shape,
          fill: fill,
          color: color,
        ),
        child: const SizedBox.expand(),
      ),
    );

    // 선택: 위로 들리며 커짐, 누르는 순간: 눌려서 납작해짐.
    card = AnimatedSlide(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutBack,
      offset: lifted && !_down ? const Offset(0, -0.025) : Offset.zero,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        scale: _down ? 0.94 : (lifted ? 1.05 : 1.0),
        child: card,
      ),
    );

    // 상태 배지(선택 체크 / 세트 성공 별)
    final badge = matched
        ? Icons.star_rounded
        : (selected && !failed ? Icons.check_rounded : null);

    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            final t = _c.value;
            double dx = 0;
            double scale = 1.0;
            if (failed && _c.isAnimating) {
              dx = math.sin(t * math.pi * 7) * 7 * (1 - t);
            }
            if (matched && _c.isAnimating) {
              scale =
                  0.9 +
                  0.1 * Curves.elasticOut.transform(t) +
                  0.05 * math.sin(t * math.pi);
            }
            return Transform.translate(
              offset: Offset(dx, 0),
              child: Transform.scale(
                scale: scale,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(child: child!),
                    if (matched && t < 1) ..._sparkles(t),
                  ],
                ),
              ),
            );
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: card),
              if (badge != null)
                Positioned(
                  top: -5,
                  right: -5,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: matched ? CandyColors.sun : widget.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: CandyColors.ink, width: 2),
                    ),
                    child: Icon(
                      badge,
                      size: 14,
                      color: matched ? CandyColors.ink : Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 세트 성공 시 카드 중심에서 퍼지는 반짝이.
  List<Widget> _sparkles(double t) {
    final out = <Widget>[];
    final r = Curves.easeOutCubic.transform(t);
    for (int i = 0; i < 6; i++) {
      final ang = (math.pi * 2 / 6) * i + 0.4;
      out.add(
        Positioned.fill(
          child: IgnorePointer(
            child: Align(
              alignment: Alignment.center,
              child: Transform.translate(
                offset: Offset(
                  math.cos(ang) * (20 + 46 * r),
                  math.sin(ang) * (20 + 46 * r),
                ),
                child: Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0),
                  child: Icon(
                    Icons.star_rounded,
                    size: 14 + 6 * (1 - t),
                    color: i.isEven ? CandyColors.sun : CandyColors.pink,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return out;
  }
}

class _SetSymbolPainter extends CustomPainter {
  final int number;
  final int shape;
  final int fill;
  final Color color;

  _SetSymbolPainter({
    required this.number,
    required this.shape,
    required this.fill,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final symW = size.width * 0.84;
    const gap = 6.0;
    // 카드 높이에 항상 들어가도록 심볼 높이를 맞춘다(1~3개).
    final symH = ((size.height - (number - 1) * gap) / number).clamp(8.0, 38.0);
    final totalH = number * symH + (number - 1) * gap;
    double y = (size.height - totalH) / 2;
    final x = (size.width - symW) / 2;

    for (int i = 0; i < number; i++) {
      final rect = Rect.fromLTWH(x, y, symW, symH);
      final path = _shapePath(rect);
      _paintShape(canvas, path, rect);
      y += symH + gap;
    }
  }

  Path _shapePath(Rect r) {
    final path = Path();
    switch (shape) {
      case 0: // 다이아몬드
        path.moveTo(r.center.dx, r.top);
        path.lineTo(r.right, r.center.dy);
        path.lineTo(r.center.dx, r.bottom);
        path.lineTo(r.left, r.center.dy);
        path.close();
        break;
      case 1: // 타원(캡슐)
        path.addRRect(
          RRect.fromRectAndRadius(r, Radius.circular(r.height / 2)),
        );
        break;
      default: // 물결(squiggle)
        final w = r.width, h = r.height, x = r.left, ty = r.top;
        final midTop = ty + h * 0.20;
        final midBot = ty + h * 0.80;
        path.moveTo(x, ty + h * 0.5);
        path.cubicTo(
          x + w * 0.15,
          midTop - h * 0.18,
          x + w * 0.35,
          midTop + h * 0.12,
          x + w * 0.5,
          midTop,
        );
        path.cubicTo(
          x + w * 0.7,
          midTop - h * 0.14,
          x + w * 0.85,
          midTop + h * 0.16,
          x + w,
          ty + h * 0.42,
        );
        path.lineTo(x + w, ty + h * 0.58);
        path.cubicTo(
          x + w * 0.85,
          midBot + h * 0.18,
          x + w * 0.65,
          midBot - h * 0.12,
          x + w * 0.5,
          midBot,
        );
        path.cubicTo(
          x + w * 0.3,
          midBot + h * 0.14,
          x + w * 0.15,
          midBot - h * 0.16,
          x,
          ty + h * 0.58,
        );
        path.close();
    }
    return path;
  }

  void _paintShape(Canvas canvas, Path path, Rect r) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    if (fill == 0) {
      // 채움
      canvas.drawPath(path, Paint()..color = color);
    } else if (fill == 1) {
      // 빗금 — 도형 안에 가로선
      canvas.save();
      canvas.clipPath(path);
      final line = Paint()
        ..color = color
        ..strokeWidth = 1.6;
      for (double ly = r.top; ly <= r.bottom; ly += 4.2) {
        canvas.drawLine(Offset(r.left, ly), Offset(r.right, ly), line);
      }
      canvas.restore();
      canvas.drawPath(path, stroke);
    } else {
      // 외곽선만
      canvas.drawPath(path, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _SetSymbolPainter old) =>
      old.number != number ||
      old.shape != shape ||
      old.fill != fill ||
      old.color != color;
}
