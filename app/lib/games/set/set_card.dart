import 'package:flutter/material.dart';

/// Set 카드 한 장. id(0~80)에서 4속성을 디코드해 도형을 그린다.
///  number = (id ~/ 27) % 3  (0,1,2 → 1,2,3개)
///  shape  = (id ~/ 9)  % 3  (0 다이아 / 1 타원 / 2 물결)
///  fill   = (id ~/ 3)  % 3  (0 채움 / 1 빗금 / 2 외곽선)
///  color  = id % 3          (0 빨강 / 1 초록 / 2 보라)
class SetCard extends StatelessWidget {
  final int cardId;
  final bool selected;
  final bool failed;
  final Color accent;
  final VoidCallback onTap;

  const SetCard({
    super.key,
    required this.cardId,
    required this.selected,
    required this.failed,
    required this.accent,
    required this.onTap,
  });

  static const List<Color> _palette = [
    Color(0xFFE53935), // red
    Color(0xFF1FA85A), // green
    Color(0xFF7C4DFF), // purple
  ];

  @override
  Widget build(BuildContext context) {
    final number = (cardId ~/ 27) % 3 + 1;
    final shape = (cardId ~/ 9) % 3;
    final fill = (cardId ~/ 3) % 3;
    final color = _palette[cardId % 3];

    final Color borderColor = failed
        ? const Color(0xFFE53935)
        : selected
            ? accent
            : const Color(0xFFE7E8EC);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: failed ? const Color(0xFFFDECEC) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: borderColor,
            width: (selected || failed) ? 2.4 : 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: selected
                  ? accent.withValues(alpha: 0.16)
                  : Colors.black.withValues(alpha: 0.03),
              blurRadius: selected ? 14 : 8,
              offset: const Offset(0, 4),
            ),
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
      ),
    );
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
    final symH = (size.height * 0.26).clamp(10.0, 40.0);
    const gap = 8.0;
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
        path.cubicTo(x + w * 0.15, midTop - h * 0.18, x + w * 0.35,
            midTop + h * 0.12, x + w * 0.5, midTop);
        path.cubicTo(x + w * 0.7, midTop - h * 0.14, x + w * 0.85,
            midTop + h * 0.16, x + w, ty + h * 0.42);
        path.lineTo(x + w, ty + h * 0.58);
        path.cubicTo(x + w * 0.85, midBot + h * 0.18, x + w * 0.65,
            midBot - h * 0.12, x + w * 0.5, midBot);
        path.cubicTo(x + w * 0.3, midBot + h * 0.14, x + w * 0.15,
            midBot - h * 0.16, x, ty + h * 0.58);
        path.close();
    }
    return path;
  }

  void _paintShape(Canvas canvas, Path path, Rect r) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
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
