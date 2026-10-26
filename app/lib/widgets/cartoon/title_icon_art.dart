import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';

/// 칭호 아이콘 — 서버가 내려주는 이모지 문자열(previewData['icon'])을 키로 삼아
/// 카툰 스타일(굵은 잉크 외곽선 + 플랫 컬러)로 직접 그린다. 모르는 이모지는 텍스트로 대체.
class TitleIconArt extends StatelessWidget {
  final String icon;
  final double size;

  const TitleIconArt({super.key, required this.icon, this.size = 16});

  static bool supports(String icon) => _glyphs.containsKey(_normalize(icon));

  // 변형 선택자(U+FE0F) 유무 차이를 흡수한다.
  static String _normalize(String s) => s.replaceAll('️', '');

  @override
  Widget build(BuildContext context) {
    final glyph = _glyphs[_normalize(icon)];
    if (glyph == null) {
      return Text(icon, style: TextStyle(fontSize: size * 0.9));
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GlyphPainter(glyph)),
    );
  }
}

typedef _Glyph = void Function(_Pen p);

/// 100x100 좌표계를 위젯 크기로 스케일해 그리는 펜.
class _Pen {
  final Canvas canvas;
  final double scale;
  _Pen(this.canvas, this.scale);

  // 작은 크기에서도 외곽선이 사라지지 않도록 최소 두께 보장.
  double get _stroke => math.max(5.0, 1.4 / scale);

  Paint _fill(Color c) => Paint()..color = c;
  Paint get _line => Paint()
    ..color = CandyColors.ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = _stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;

  void path(Path p, Color fill) {
    canvas.drawPath(p, _fill(fill));
    canvas.drawPath(p, _line);
  }

  void circle(Offset c, double r, Color fill) {
    canvas.drawCircle(c, r, _fill(fill));
    canvas.drawCircle(c, r, _line);
  }

  void rrect(Rect r, double rad, Color fill) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(rad));
    canvas.drawRRect(rr, _fill(fill));
    canvas.drawRRect(rr, _line);
  }

  void stroke(Path p, {double? width, Color? color}) {
    canvas.drawPath(
      p,
      _line
        ..strokeWidth = width ?? _stroke
        ..color = color ?? CandyColors.ink,
    );
  }

  Path poly(List<Offset> pts) {
    final p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final o in pts.skip(1)) {
      p.lineTo(o.dx, o.dy);
    }
    return p..close();
  }

  Path star(Offset c, double outer, double inner, {int points = 5, double rot = -math.pi / 2}) {
    final pts = <Offset>[];
    for (var i = 0; i < points * 2; i++) {
      final r = i.isEven ? outer : inner;
      final a = rot + i * math.pi / points;
      pts.add(Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a)));
    }
    return poly(pts);
  }
}

class _GlyphPainter extends CustomPainter {
  final _Glyph glyph;
  _GlyphPainter(this.glyph);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 100;
    canvas.save();
    canvas.scale(s);
    glyph(_Pen(canvas, s));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph;
}

const _gold = Color(0xFFFFC93C);
const _goldDeep = Color(0xFFF0A500);
const _white = Colors.white;

Offset _o(double x, double y) => Offset(x, y);

void _crown(_Pen p) {
  p.path(
    p.poly([_o(10, 78), _o(10, 30), _o(32, 52), _o(50, 22), _o(68, 52), _o(90, 30), _o(90, 78)]),
    _gold,
  );
  p.rrect(const Rect.fromLTWH(10, 72, 80, 14), 5, _goldDeep);
  p.circle(_o(10, 30), 7, const Color(0xFFFF6B9D));
  p.circle(_o(50, 22), 7, const Color(0xFF4DB8FF));
  p.circle(_o(90, 30), 7, const Color(0xFFFF6B9D));
}

/// 이모지(변형 선택자 제거) → 그리기 함수.
final Map<String, _Glyph> _glyphs = {
  // 🏆 트로피
  '🏆': (p) {
    final cup = Path()
      ..moveTo(26, 14)
      ..lineTo(74, 14)
      ..lineTo(70, 50)
      ..quadraticBezierTo(66, 66, 50, 66)
      ..quadraticBezierTo(34, 66, 30, 50)
      ..close();
    p.stroke(Path()..moveTo(26, 24)..quadraticBezierTo(4, 24, 14, 44)..quadraticBezierTo(20, 52, 30, 50), width: 7);
    p.stroke(Path()..moveTo(74, 24)..quadraticBezierTo(96, 24, 86, 44)..quadraticBezierTo(80, 52, 70, 50), width: 7);
    p.path(cup, _gold);
    p.rrect(const Rect.fromLTWH(44, 64, 12, 14), 2, _goldDeep);
    p.rrect(const Rect.fromLTWH(28, 76, 44, 14), 5, _goldDeep);
    p.path(p.star(_o(50, 38), 13, 5.5), _white);
  },
  // 🍀 클로버
  '🍀': (p) {
    const g = Color(0xFF5BD18B);
    p.stroke(Path()..moveTo(50, 52)..quadraticBezierTo(58, 76, 70, 92), width: 7);
    for (final c in [_o(34, 34), _o(66, 34), _o(34, 64), _o(66, 64)]) {
      p.circle(c, 20, g);
    }
    p.circle(_o(50, 49), 9, const Color(0xFF3FB874));
  },
  // 💪 팔뚝
  '💪': (p) {
    final arm = Path()
      ..moveTo(12, 70)
      ..quadraticBezierTo(8, 40, 36, 42)
      ..quadraticBezierTo(42, 14, 66, 22)
      ..quadraticBezierTo(92, 30, 84, 56)
      ..quadraticBezierTo(80, 74, 56, 76)
      ..lineTo(34, 88)
      ..quadraticBezierTo(14, 92, 12, 70)
      ..close();
    p.path(arm, const Color(0xFFFFB86B));
    p.stroke(Path()..moveTo(48, 42)..quadraticBezierTo(60, 38, 68, 48), width: 4);
  },
  // 🧭 나침반
  '🧭': (p) {
    p.circle(_o(50, 50), 40, _white);
    p.circle(_o(50, 50), 31, const Color(0xFFD7F0FF));
    p.path(p.poly([_o(50, 20), _o(60, 50), _o(40, 50)]), const Color(0xFFFF5A5F));
    p.path(p.poly([_o(50, 80), _o(60, 50), _o(40, 50)]), CandyColors.inkSoft);
    p.circle(_o(50, 50), 5, _gold);
  },
  // 💭 생각 말풍선
  '💭': (p) {
    p.circle(_o(34, 40), 22, _white);
    p.circle(_o(58, 30), 24, _white);
    p.circle(_o(76, 46), 18, _white);
    p.rrect(const Rect.fromLTWH(26, 40, 52, 24), 12, _white);
    p.circle(_o(24, 76), 7, _white);
    p.circle(_o(10, 90), 4.5, _white);
  },
  // ⭐ 별
  '⭐': (p) => p.path(p.star(_o(50, 54), 44, 19), _gold),
  // 🌟 반짝이는 별
  '🌟': (p) {
    p.path(p.star(_o(50, 52), 42, 18), _gold);
    p.path(p.star(_o(50, 52), 20, 9), _white);
    p.stroke(Path()..moveTo(88, 12)..lineTo(88, 26)..moveTo(81, 19)..lineTo(95, 19), width: 4);
    p.stroke(Path()..moveTo(12, 78)..lineTo(12, 90)..moveTo(6, 84)..lineTo(18, 84), width: 4);
  },
  // 🧠 두뇌
  '🧠': (p) {
    const pink = Color(0xFFFF9EC0);
    p.circle(_o(36, 40), 24, pink);
    p.circle(_o(64, 40), 24, pink);
    p.circle(_o(30, 62), 20, pink);
    p.circle(_o(70, 62), 20, pink);
    p.rrect(const Rect.fromLTWH(30, 44, 40, 34), 14, pink);
    p.stroke(Path()..moveTo(50, 20)..quadraticBezierTo(44, 50, 50, 80), width: 4);
    p.stroke(Path()..moveTo(26, 44)..quadraticBezierTo(36, 50, 42, 44)..moveTo(74, 44)..quadraticBezierTo(64, 50, 58, 44), width: 4);
  },
  // ⚡ 번개
  '⚡': (p) => p.path(
        p.poly([_o(58, 6), _o(20, 56), _o(46, 56), _o(38, 94), _o(80, 40), _o(54, 40)]),
        _gold,
      ),
  // 🛡️ 방패
  '🛡': (p) {
    final sh = Path()
      ..moveTo(50, 8)
      ..lineTo(88, 20)
      ..quadraticBezierTo(90, 62, 50, 92)
      ..quadraticBezierTo(10, 62, 12, 20)
      ..close();
    p.path(sh, const Color(0xFF4DB8FF));
    p.path(
      Path()
        ..moveTo(50, 20)
        ..lineTo(76, 28)
        ..quadraticBezierTo(76, 58, 50, 80)
        ..close(),
      const Color(0xFF8FD3FF),
    );
    p.path(p.star(_o(50, 46), 14, 6), _white);
  },
  // 🎯 과녁
  '🎯': (p) {
    p.circle(_o(50, 50), 42, _white);
    p.circle(_o(50, 50), 31, const Color(0xFFFF5A5F));
    p.circle(_o(50, 50), 20, _white);
    p.circle(_o(50, 50), 10, const Color(0xFFFF5A5F));
    p.stroke(Path()..moveTo(52, 48)..lineTo(88, 12), width: 6);
    p.path(p.poly([_o(86, 6), _o(94, 20), _o(80, 14)]), _gold);
  },
  // 🎓 졸업모자
  '🎓': (p) {
    p.path(p.poly([_o(50, 18), _o(96, 40), _o(50, 62), _o(4, 40)]), CandyColors.ink);
    p.path(
      Path()
        ..moveTo(24, 52)
        ..lineTo(24, 72)
        ..quadraticBezierTo(50, 90, 76, 72)
        ..lineTo(76, 52)
        ..lineTo(50, 64)
        ..close(),
      const Color(0xFF7B5CFF),
    );
    p.stroke(Path()..moveTo(90, 44)..lineTo(90, 70), width: 5);
    p.circle(_o(90, 74), 6, _gold);
  },
  // ⚔️ 교차한 검
  '⚔': (p) {
    for (final flip in [1.0, -1.0]) {
      double x(double v) => flip > 0 ? v : 100 - v;
      p.path(
        p.poly([_o(x(14), 10), _o(x(26), 8), _o(x(78), 62), _o(x(66), 74)]),
        const Color(0xFFDDE6F0),
      );
      p.stroke(Path()..moveTo(x(60), 56)..lineTo(x(84), 80), width: 8, color: _goldDeep);
      p.circle(_o(x(88), 88), 6, _gold);
    }
  },
  // 🗡️ 단검
  '🗡': (p) {
    p.path(p.poly([_o(86, 10), _o(90, 14), _o(40, 64), _o(34, 58)]), const Color(0xFFDDE6F0));
    p.stroke(Path()..moveTo(26, 46)..lineTo(54, 74), width: 9, color: _goldDeep);
    p.stroke(Path()..moveTo(34, 66)..lineTo(14, 86), width: 8, color: const Color(0xFF8B5A2B));
    p.circle(_o(12, 88), 6, _gold);
  },
  // 👑 왕관
  '👑': _crown,
  // 💎 보석
  '💎': (p) {
    p.path(p.poly([_o(26, 14), _o(74, 14), _o(94, 38), _o(50, 90), _o(6, 38)]), const Color(0xFF4DD0E1));
    p.path(p.poly([_o(26, 14), _o(38, 38), _o(50, 14)]), const Color(0xFFB2EBF2));
    p.path(p.poly([_o(74, 14), _o(62, 38), _o(50, 14)]), const Color(0xFF80DEEA));
    p.stroke(Path()..moveTo(6, 38)..lineTo(94, 38)..moveTo(38, 38)..lineTo(50, 90)..moveTo(62, 38)..lineTo(50, 90), width: 4);
  },
  // 🌑 그믐달/달
  '🌑': (p) {
    p.circle(_o(50, 50), 40, const Color(0xFF4A3F78));
    p.circle(_o(36, 38), 8, const Color(0xFF3A2D5C));
    p.circle(_o(62, 62), 11, const Color(0xFF3A2D5C));
    p.circle(_o(66, 32), 5, const Color(0xFF3A2D5C));
  },
  // 🔥 불꽃
  '🔥': (p) {
    final f = Path()
      ..moveTo(52, 6)
      ..quadraticBezierTo(60, 34, 80, 46)
      ..quadraticBezierTo(96, 62, 82, 80)
      ..quadraticBezierTo(70, 94, 50, 94)
      ..quadraticBezierTo(24, 94, 16, 74)
      ..quadraticBezierTo(10, 56, 28, 40)
      ..quadraticBezierTo(30, 52, 38, 54)
      ..quadraticBezierTo(34, 28, 52, 6)
      ..close();
    p.path(f, const Color(0xFFFF7A3D));
    p.path(
      Path()
        ..moveTo(52, 50)
        ..quadraticBezierTo(70, 66, 62, 82)
        ..quadraticBezierTo(56, 90, 48, 88)
        ..quadraticBezierTo(34, 84, 36, 70)
        ..quadraticBezierTo(38, 60, 52, 50)
        ..close(),
      _gold,
    );
  },
  // 🔮 수정구슬
  '🔮': (p) {
    p.path(
      Path()
        ..moveTo(24, 84)
        ..lineTo(76, 84)
        ..lineTo(68, 68)
        ..lineTo(32, 68)
        ..close(),
      const Color(0xFF8B5A2B),
    );
    p.circle(_o(50, 42), 34, const Color(0xFFB388FF));
    p.circle(_o(38, 30), 8, _white);
    p.stroke(Path()..moveTo(60, 58)..quadraticBezierTo(70, 50, 72, 40), width: 4, color: const Color(0xFFE1D0FF));
  },
  // 👼 천사
  '👼': (p) {
    p.path(
      Path()..moveTo(30, 52)..quadraticBezierTo(2, 38, 8, 66)..quadraticBezierTo(18, 72, 34, 66)..close(),
      _white,
    );
    p.path(
      Path()..moveTo(70, 52)..quadraticBezierTo(98, 38, 92, 66)..quadraticBezierTo(82, 72, 66, 66)..close(),
      _white,
    );
    p.circle(_o(50, 56), 24, const Color(0xFFFFD9B5));
    p.circle(_o(42, 56), 3, CandyColors.ink);
    p.circle(_o(58, 56), 3, CandyColors.ink);
    p.canvas.drawOval(const Rect.fromLTWH(30, 10, 40, 14), Paint()..color = _gold);
    p.canvas.drawOval(
      const Rect.fromLTWH(30, 10, 40, 14),
      Paint()
        ..color = CandyColors.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );
  },
  // ⚜️ 백합 문장
  '⚜': (p) {
    const c = _gold;
    p.path(Path()..moveTo(50, 8)..quadraticBezierTo(70, 28, 60, 54)..lineTo(40, 54)..quadraticBezierTo(30, 28, 50, 8)..close(), c);
    p.path(Path()..moveTo(36, 50)..quadraticBezierTo(8, 30, 10, 58)..quadraticBezierTo(20, 70, 42, 62)..close(), c);
    p.path(Path()..moveTo(64, 50)..quadraticBezierTo(92, 30, 90, 58)..quadraticBezierTo(80, 70, 58, 62)..close(), c);
    p.rrect(const Rect.fromLTWH(26, 62, 48, 10), 4, _goldDeep);
    p.path(Path()..moveTo(40, 72)..lineTo(60, 72)..lineTo(66, 94)..lineTo(34, 94)..close(), c);
  },
  // ♾️ 무한대
  '♾': (p) {
    final lo = Path()
      ..moveTo(50, 50)
      ..cubicTo(36, 24, 8, 26, 8, 50)
      ..cubicTo(8, 74, 36, 76, 50, 50)
      ..cubicTo(64, 24, 92, 26, 92, 50)
      ..cubicTo(92, 74, 64, 76, 50, 50);
    p.stroke(lo, width: 20);
    p.stroke(lo, width: 11, color: const Color(0xFF2EC4A6));
  },
};
