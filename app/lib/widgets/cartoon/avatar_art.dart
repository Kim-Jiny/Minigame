import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';

/// 그려서 만든 아바타 초상화. [itemKey] 별 종(種) 스펙 표 하나로 얼굴을 그린다.
/// 모르는 키는 예전 방식(배경색 + [emoji] 텍스트)으로 돌려 서버가 emoji 만 보내도 깨지지 않는다.
class AvatarArt extends StatelessWidget {
  final String itemKey;
  final double size;
  final Color? bgColor;

  /// 스펙이 없는 키일 때 쓰는 예전 이모지.
  final String? emoji;

  /// true 면 원형, false 면 둥근 사각형 타일.
  final bool circle;

  /// 바깥 잉크 아웃라인을 그릴지(이미 테두리를 두른 곳에서는 끈다).
  final bool outline;

  const AvatarArt({
    super.key,
    required this.itemKey,
    this.size = 48,
    this.bgColor,
    this.emoji,
    this.circle = true,
    this.outline = true,
  });

  static bool hasArt(String key) => _specs.containsKey(key);

  @override
  Widget build(BuildContext context) {
    final bg = bgColor ?? const Color(0xFFE9E4F5);
    final spec = _specs[itemKey];
    if (spec == null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(size * 0.26),
          border: outline
              ? Border.all(color: CandyColors.ink, width: size >= 60 ? 3 : 2)
              : null,
        ),
        child: Text(emoji ?? '👤', style: TextStyle(fontSize: size * 0.52)),
      );
    }
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _AvatarPainter(spec, bg, circle, outline),
      ),
    );
  }
}

enum _Ear { none, round, pointy, long, floppy, tufts }

enum _Eye { dot, big, happy, closed, owl, alien, robot, tall }

enum _Nose { none, dot, tri, big, beak, hook, nostrils }

enum _Mouth { smile, grin, cat, tongue, o, teeth, flat, evil, smirk, none }

enum _Shape { round, ghost, square }

enum _Mk {
  mane,
  unicornMane,
  angelWings,
  flameWings,
  fin,
  shoulders,
  antennaAlien,
  antennaRobot,
  sideBolts,
  stripes,
  panda,
  lower,
  faceMask,
  headCap,
  dogSpot,
  eyeDiscs,
  whiskers,
  buckteeth,
  mustache,
  brows,
  gills,
  horns,
  devilHorns,
  horn,
  crest,
  halo,
  crown,
  shades,
  noCheeks,
}

class _Spec {
  final Color head;
  final Color? muzzle;
  final Color? lower;
  final Color? earIn;
  final Color? earOut;
  final Color accent;
  final _Ear ear;
  final _Eye eye;
  final _Nose nose;
  final _Mouth mouth;
  final _Shape shape;
  final Set<_Mk> marks;
  const _Spec(
    this.head, {
    this.muzzle,
    this.lower,
    this.earIn,
    this.earOut,
    this.accent = const Color(0xFFFFD23F),
    this.ear = _Ear.none,
    this.eye = _Eye.dot,
    this.nose = _Nose.none,
    this.mouth = _Mouth.smile,
    this.shape = _Shape.round,
    this.marks = const {},
  });
}

const _pinkIn = Color(0xFFFFB3C7);
const _white = Colors.white;

const Map<String, _Spec> _specs = {
  'avatar_default': _Spec(
    Color(0xFFC9C3E6),
    marks: {_Mk.shoulders},
  ),
  'avatar_smile': _Spec(
    Color(0xFFFFD23F),
    eye: _Eye.happy,
    mouth: _Mouth.grin,
  ),
  'avatar_cool': _Spec(
    Color(0xFFFFD23F),
    mouth: _Mouth.smirk,
    marks: {_Mk.shades},
  ),
  'avatar_cat': _Spec(
    Color(0xFFFFB866),
    ear: _Ear.pointy,
    earIn: _pinkIn,
    muzzle: Color(0xFFFFF1DC),
    nose: _Nose.tri,
    mouth: _Mouth.cat,
    marks: {_Mk.whiskers},
  ),
  'avatar_dog': _Spec(
    Color(0xFFE0B27A),
    ear: _Ear.floppy,
    earOut: Color(0xFF8A5A2B),
    muzzle: Color(0xFFFFEFD2),
    nose: _Nose.big,
    mouth: _Mouth.tongue,
    marks: {_Mk.dogSpot},
  ),
  'avatar_bear': _Spec(
    Color(0xFFA9744F),
    ear: _Ear.round,
    earIn: Color(0xFFE8C9A0),
    muzzle: Color(0xFFE8C9A0),
    nose: _Nose.dot,
  ),
  'avatar_monkey': _Spec(
    Color(0xFF8B5E3C),
    ear: _Ear.round,
    earIn: Color(0xFFF2CFA5),
    lower: Color(0xFFF2CFA5),
    nose: _Nose.nostrils,
    mouth: _Mouth.grin,
    marks: {_Mk.faceMask},
  ),
  'avatar_fox': _Spec(
    Color(0xFFFF8A3D),
    ear: _Ear.pointy,
    earIn: CandyColors.ink,
    lower: _white,
    nose: _Nose.dot,
    marks: {_Mk.lower},
  ),
  'avatar_lion': _Spec(
    Color(0xFFFFC04D),
    accent: Color(0xFFB86A2E),
    ear: _Ear.round,
    earIn: Color(0xFFFFE2A8),
    muzzle: Color(0xFFFFF1CF),
    nose: _Nose.tri,
    mouth: _Mouth.cat,
    marks: {_Mk.mane},
  ),
  'avatar_panda': _Spec(
    _white,
    ear: _Ear.round,
    earIn: Color(0xFF2B2340),
    earOut: Color(0xFF2B2340),
    eye: _Eye.big,
    nose: _Nose.dot,
    marks: {_Mk.panda},
  ),
  'avatar_rabbit': _Spec(
    _white,
    ear: _Ear.long,
    earIn: _pinkIn,
    nose: _Nose.tri,
    mouth: _Mouth.cat,
    marks: {_Mk.buckteeth},
  ),
  'avatar_tiger': _Spec(
    Color(0xFFFF9A3D),
    ear: _Ear.round,
    earIn: _white,
    muzzle: _white,
    nose: _Nose.tri,
    mouth: _Mouth.cat,
    marks: {_Mk.stripes, _Mk.whiskers},
  ),
  'avatar_owl': _Spec(
    Color(0xFFB07A4E),
    ear: _Ear.tufts,
    eye: _Eye.owl,
    nose: _Nose.beak,
    mouth: _Mouth.none,
    marks: {_Mk.eyeDiscs},
  ),
  'avatar_penguin': _Spec(
    Color(0xFF3B4A6B),
    lower: _white,
    nose: _Nose.beak,
    mouth: _Mouth.none,
    marks: {_Mk.lower, _Mk.noCheeks},
  ),
  'avatar_koala': _Spec(
    Color(0xFFA8B0BC),
    ear: _Ear.round,
    earIn: _white,
    nose: _Nose.big,
    mouth: _Mouth.none,
  ),
  'avatar_dragon': _Spec(
    Color(0xFF4CC38A),
    accent: Color(0xFFFFD23F),
    ear: _Ear.pointy,
    earIn: Color(0xFF2E9E69),
    muzzle: Color(0xFFB7F0CF),
    nose: _Nose.nostrils,
    mouth: _Mouth.teeth,
    marks: {_Mk.horns},
  ),
  'avatar_unicorn': _Spec(
    Color(0xFFFFF0FA),
    accent: Color(0xFFFF8FD0),
    ear: _Ear.pointy,
    earIn: _pinkIn,
    nose: _Nose.nostrils,
    mouth: _Mouth.smile,
    marks: {_Mk.unicornMane, _Mk.horn},
  ),
  'avatar_phoenix': _Spec(
    Color(0xFFFF6A3D),
    nose: _Nose.beak,
    mouth: _Mouth.none,
    marks: {_Mk.flameWings, _Mk.crest},
  ),
  'avatar_shark': _Spec(
    Color(0xFF6FA8D6),
    lower: _white,
    mouth: _Mouth.teeth,
    marks: {_Mk.fin, _Mk.lower, _Mk.gills, _Mk.noCheeks},
  ),
  'avatar_eagle': _Spec(
    Color(0xFF8A5A3B),
    nose: _Nose.hook,
    mouth: _Mouth.none,
    marks: {_Mk.headCap, _Mk.brows, _Mk.noCheeks},
  ),
  'avatar_wolf': _Spec(
    Color(0xFF9AA3B5),
    ear: _Ear.pointy,
    earIn: Color(0xFF4B4A66),
    lower: Color(0xFFE8ECF3),
    nose: _Nose.big,
    mouth: _Mouth.smirk,
    marks: {_Mk.lower},
  ),
  'avatar_alien': _Spec(
    Color(0xFF8EE36B),
    eye: _Eye.alien,
    mouth: _Mouth.o,
    marks: {_Mk.antennaAlien, _Mk.noCheeks},
  ),
  'avatar_robot': _Spec(
    Color(0xFFB8C7D9),
    shape: _Shape.square,
    eye: _Eye.robot,
    mouth: _Mouth.flat,
    marks: {_Mk.antennaRobot, _Mk.sideBolts},
  ),
  'avatar_ghost': _Spec(
    _white,
    shape: _Shape.ghost,
    eye: _Eye.tall,
    mouth: _Mouth.o,
  ),
  'avatar_devil': _Spec(
    Color(0xFFE5484D),
    mouth: _Mouth.evil,
    marks: {_Mk.devilHorns, _Mk.brows},
  ),
  'avatar_angel': _Spec(
    Color(0xFFFFE3C8),
    eye: _Eye.closed,
    marks: {_Mk.angelWings, _Mk.halo},
  ),
  'avatar_crown': _Spec(
    Color(0xFFFFD9A8),
    ear: _Ear.round,
    earIn: Color(0xFFFFB98A),
    nose: _Nose.dot,
    mouth: _Mouth.smile,
    marks: {_Mk.crown, _Mk.mustache},
  ),
};

const _ink = CandyColors.ink;

class _AvatarPainter extends CustomPainter {
  final _Spec spec;
  final Color bg;
  final bool circle;
  final bool outline;
  _AvatarPainter(this.spec, this.bg, this.circle, this.outline);

  // 한 번 만들어 재사용하는 페인트(그리는 동안 새 Paint 를 만들지 않는다).
  final Paint _fill = Paint();
  final Paint _line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _hi = Paint()..color = Colors.white;
  late Canvas _c;
  double _lw = 3;

  void _shape(Path p, Color col, {bool line = true}) {
    _fill.color = col;
    _c.drawPath(p, _fill);
    if (line) {
      _line
        ..color = _ink
        ..strokeWidth = _lw;
      _c.drawPath(p, _line);
    }
  }

  void _oval(double cx, double cy, double w, double h, Color col,
      {bool line = true, double rot = 0}) {
    final p = Path()
      ..addOval(Rect.fromCenter(center: Offset.zero, width: w, height: h));
    _c.save();
    _c.translate(cx, cy);
    if (rot != 0) _c.rotate(rot);
    _shape(p, col, line: line);
    _c.restore();
  }

  Path _poly(List<double> xy, {bool mirror = false}) {
    final p = Path();
    for (var i = 0; i < xy.length; i += 2) {
      final x = mirror ? 100 - xy[i] : xy[i];
      i == 0 ? p.moveTo(x, xy[i + 1]) : p.lineTo(x, xy[i + 1]);
    }
    return p..close();
  }

  void _both(List<double> xy, Color col, {bool line = true}) {
    _shape(_poly(xy), col, line: line);
    _shape(_poly(xy, mirror: true), col, line: line);
  }

  void _stroke(Path p, Color col, double w) {
    _line
      ..color = col
      ..strokeWidth = w;
    _c.drawPath(p, _line);
  }

  void _seg(double x1, double y1, double x2, double y2, {double? w, Color col = _ink}) {
    _stroke(Path()..moveTo(x1, y1)..lineTo(x2, y2), col, w ?? _lw * 0.6);
  }

  Path _headPath() {
    switch (spec.shape) {
      case _Shape.square:
        return Path()
          ..addRRect(RRect.fromRectAndRadius(
              const Rect.fromLTWH(17, 26, 66, 58), const Radius.circular(13)));
      case _Shape.ghost:
        final p = Path()
          ..moveTo(20, 84)
          ..lineTo(20, 48)
          ..arcTo(const Rect.fromLTWH(20, 18, 60, 60), math.pi, math.pi, false)
          ..lineTo(80, 84);
        for (var i = 0; i < 3; i++) {
          final x = 80.0 - 20 * i;
          p.quadraticBezierTo(x - 10, 96, x - 20, 84);
        }
        return p..close();
      case _Shape.round:
        return Path()..addOval(const Rect.fromLTWH(16, 25, 68, 60));
    }
  }

  void _flame(double x, double y, double h, double w, double rot, Color col) {
    _c.save();
    _c.translate(x, y);
    _c.rotate(rot);
    final p = Path()
      ..moveTo(-w, 0)
      ..quadraticBezierTo(-w, -h * 0.5, 0, -h)
      ..quadraticBezierTo(w, -h * 0.5, w, 0)
      ..close();
    _shape(p, col);
    _c.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 100;
    _c = canvas;
    _lw = (3.0 * u).clamp(1.5, 4.0) / u;
    canvas.scale(u, u);
    final tile = circle
        ? (Path()..addOval(const Rect.fromLTWH(0, 0, 100, 100)))
        : (Path()
            ..addRRect(RRect.fromRectAndRadius(
                const Rect.fromLTWH(0, 0, 100, 100), const Radius.circular(26))));
    canvas.save();
    canvas.clipPath(tile);
    _fill.color = bg;
    canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), _fill);
    // 은은한 바닥 광택
    _oval(50, 100, 90, 40, Colors.white.withValues(alpha: 0.25), line: false);

    final m = spec.marks;
    final head = spec.head;
    _back(m);
    _ears(head);

    final hp = _headPath();
    _fill.color = head;
    canvas.drawPath(hp, _fill);
    canvas.save();
    canvas.clipPath(hp);
    _clipped(m, hp);
    canvas.restore();
    _line
      ..color = _ink
      ..strokeWidth = _lw;
    canvas.drawPath(hp, _line);
    // 머리 하이라이트
    _stroke(
      Path()..addArc(const Rect.fromLTWH(24, 31, 26, 20), math.pi * 1.05, math.pi * 0.5),
      Colors.white.withValues(alpha: 0.6),
      _lw * 1.1,
    );

    if (spec.muzzle != null) {
      _oval(50, 69, 30, 22, spec.muzzle!);
    }
    if (!m.contains(_Mk.noCheeks)) {
      final blush = const Color(0xFFFF4D7D).withValues(alpha: 0.38);
      _oval(26, 65, 12, 7, blush, line: false);
      _oval(74, 65, 12, 7, blush, line: false);
    }
    _eyes(m);
    _nose();
    _mouth();
    _front(m);
    canvas.restore();

    if (outline) {
      final sw = _lw * 1.1;
      _line
        ..color = _ink
        ..strokeWidth = sw;
      final r = Rect.fromLTWH(sw / 2, sw / 2, 100 - sw, 100 - sw);
      canvas.drawPath(
        circle
            ? (Path()..addOval(r))
            : (Path()..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(26)))),
        _line,
      );
    }
  }

  // 머리 뒤에 깔리는 요소
  void _back(Set<_Mk> m) {
    if (m.contains(_Mk.shoulders)) {
      _oval(50, 100, 78, 38, CandyColors.deepen(spec.head, 0.12));
    }
    if (m.contains(_Mk.mane)) {
      final pts = <Offset>[
        for (var i = 0; i < 10; i++)
          Offset(50 + 29 * math.cos(i * math.pi / 5), 55 + 29 * math.sin(i * math.pi / 5)),
      ];
      // 외곽선을 먼저 깔고 면으로 덮어 한 덩어리 갈기로 보이게 한다.
      for (final o in pts) {
        _line
          ..color = _ink
          ..strokeWidth = _lw * 2;
        _c.drawCircle(o, 13, _line);
      }
      for (final o in pts) {
        _fill.color = spec.accent;
        _c.drawCircle(o, 13, _fill);
      }
      _fill.color = spec.accent;
      _c.drawCircle(const Offset(50, 55), 30, _fill);
    }
    if (m.contains(_Mk.unicornMane)) {
      const cols = [Color(0xFFFF8FD0), Color(0xFFB79BFF), Color(0xFF7FD6FF)];
      const pts = [Offset(18, 34), Offset(12, 52), Offset(16, 70), Offset(50, 22)];
      for (final o in pts) {
        _line
          ..color = _ink
          ..strokeWidth = _lw * 2;
        _c.drawCircle(o, 10, _line);
      }
      for (var i = 0; i < pts.length; i++) {
        _fill.color = cols[i % 3];
        _c.drawCircle(pts[i], 10, _fill);
      }
    }
    if (m.contains(_Mk.angelWings)) {
      _oval(12, 50, 24, 38, _white, rot: -0.5);
      _oval(88, 50, 24, 38, _white, rot: 0.5);
    }
    if (m.contains(_Mk.flameWings)) {
      _flame(22, 66, 40, 11, -0.9, const Color(0xFFFFA63D));
      _flame(78, 66, 40, 11, 0.9, const Color(0xFFFFA63D));
      _flame(18, 60, 26, 7, -1.1, const Color(0xFFFFD23F));
      _flame(82, 60, 26, 7, 1.1, const Color(0xFFFFD23F));
    }
    if (m.contains(_Mk.fin)) {
      _shape(_poly([36, 34, 52, 2, 64, 34]), const Color(0xFF4F86B8));
    }
    if (m.contains(_Mk.antennaAlien)) {
      for (final s in [-1.0, 1.0]) {
        _seg(50 + s * 14, 30, 50 + s * 20, 10, w: _lw * 0.8);
        _oval(50 + s * 21, 8, 9, 9, const Color(0xFFFFE066));
      }
    }
    if (m.contains(_Mk.antennaRobot)) {
      _seg(50, 28, 50, 11, w: _lw * 0.8);
      _oval(50, 9, 9, 9, const Color(0xFFFF5470));
    }
    if (m.contains(_Mk.sideBolts)) {
      for (final x in [8.0, 82.0]) {
        _shape(
          Path()..addRRect(RRect.fromRectAndRadius(
              Rect.fromLTWH(x, 46, 10, 20), const Radius.circular(4))),
          const Color(0xFF8FA3BA),
        );
      }
    }
  }

  void _ears(Color head) {
    final out = spec.earOut ?? head;
    final inn = spec.earIn ?? CandyColors.deepen(head, 0.1);
    switch (spec.ear) {
      case _Ear.none:
        break;
      case _Ear.round:
        for (final x in [24.0, 76.0]) {
          _oval(x, 31, 22, 22, out);
          _oval(x, 31, 11, 11, inn, line: false);
        }
      case _Ear.pointy:
        _both([17, 46, 20, 10, 46, 30], out);
        _both([24, 38, 25, 20, 38, 31], inn, line: false);
      case _Ear.long:
        for (final x in [36.0, 64.0]) {
          _oval(x, 14, 16, 44, out);
          _oval(x, 15, 7, 32, inn, line: false);
        }
      case _Ear.floppy:
        _oval(14, 50, 18, 36, out, rot: 0.25);
        _oval(86, 50, 18, 36, out, rot: -0.25);
      case _Ear.tufts:
        _both([20, 40, 16, 12, 42, 30], out);
    }
  }

  // 머리 모양으로 잘리는 무늬
  void _clipped(Set<_Mk> m, Path hp) {
    if (m.contains(_Mk.lower)) {
      _oval(50, 80, 62, 34, spec.lower!, line: false);
    }
    if (m.contains(_Mk.faceMask)) {
      final c = spec.lower!;
      _oval(40, 56, 26, 26, c, line: false);
      _oval(60, 56, 26, 26, c, line: false);
      _oval(50, 70, 32, 24, c, line: false);
    }
    if (m.contains(_Mk.headCap)) {
      _oval(50, 34, 74, 46, _white, line: false);
    }
    if (m.contains(_Mk.dogSpot)) {
      _oval(66, 51, 22, 24, const Color(0xFF8A5A2B), line: false, rot: 0.3);
    }
    if (m.contains(_Mk.panda)) {
      const patch = Color(0xFF2B2340);
      _oval(34, 53, 17, 22, patch, line: false, rot: 0.45);
      _oval(66, 53, 17, 22, patch, line: false, rot: -0.45);
    }
    if (m.contains(_Mk.stripes)) {
      const s = Color(0xFF3A2D5C);
      _shape(_poly([46, 24, 54, 24, 50, 42]), s, line: false);
      _shape(_poly([34, 25, 42, 27, 40, 38]), s, line: false);
      _shape(_poly([66, 25, 58, 27, 60, 38]), s, line: false);
      _both([14, 54, 28, 58, 14, 62], s, line: false);
      _both([14, 66, 27, 68, 15, 74], s, line: false);
    }
    if (m.contains(_Mk.eyeDiscs)) {
      _oval(36, 52, 27, 27, _white);
      _oval(64, 52, 27, 27, _white);
    }
  }

  void _eyes(Set<_Mk> m) {
    const lx = 36.0, rx = 64.0;
    if (m.contains(_Mk.shades)) return;
    final hi = _hi;
    switch (spec.eye) {
      case _Eye.dot:
      case _Eye.big:
        final big = spec.eye == _Eye.big;
        final w = big ? 11.0 : 9.0, h = big ? 15.0 : 12.0;
        final panda = m.contains(_Mk.panda);
        for (final x in [lx, rx]) {
          _fill.color = panda ? const Color(0xFF2B2340) : _ink;
          _c.drawOval(Rect.fromCenter(center: Offset(x, 53), width: w, height: h), _fill);
          _c.drawCircle(Offset(x - 1.8, 49.5), big ? 3.2 : 2.6, hi);
          _c.drawCircle(Offset(x + 1.8, 56.5), 1.3, hi);
        }
      case _Eye.happy:
        for (final x in [lx, rx]) {
          _stroke(
            Path()
              ..moveTo(x - 6, 55)
              ..quadraticBezierTo(x, 46, x + 6, 55),
            _ink,
            _lw,
          );
        }
      case _Eye.closed:
        for (final x in [lx, rx]) {
          _stroke(
            Path()
              ..moveTo(x - 6, 52)
              ..quadraticBezierTo(x, 58, x + 6, 52),
            _ink,
            _lw,
          );
        }
      case _Eye.owl:
        for (final x in [lx, rx]) {
          _fill.color = _ink;
          _c.drawOval(Rect.fromCenter(center: Offset(x, 53), width: 12, height: 14), _fill);
          _c.drawCircle(Offset(x - 2, 49.5), 3, hi);
        }
      case _Eye.alien:
        for (final s in [-1.0, 1.0]) {
          _oval(50 + s * 15, 55, 16, 22, _ink, line: false, rot: s * 0.45);
          _c.drawCircle(Offset(50 + s * 15 - 2, 50), 3, hi);
        }
      case _Eye.robot:
        for (final x in [lx, rx]) {
          _shape(
            Path()..addRRect(RRect.fromRectAndRadius(
                Rect.fromCenter(center: Offset(x, 53), width: 14, height: 14),
                const Radius.circular(4))),
            const Color(0xFF5BE0FF),
          );
          _c.drawCircle(Offset(x - 2, 50), 2.4, hi);
        }
      case _Eye.tall:
        for (final x in [lx, rx]) {
          _fill.color = _ink;
          _c.drawOval(Rect.fromCenter(center: Offset(x, 54), width: 9, height: 15), _fill);
          _c.drawCircle(Offset(x - 1.5, 50.5), 2.2, hi);
        }
    }
  }

  void _nose() {
    switch (spec.nose) {
      case _Nose.none:
        break;
      case _Nose.dot:
        _oval(50, 62, 9, 6, _ink, line: false);
      case _Nose.tri:
        _shape(_poly([45, 60, 55, 60, 50, 66]), const Color(0xFFFF7A9C));
      case _Nose.big:
        _oval(50, 61, 15, 11, const Color(0xFF4A4458), line: false);
        _oval(47, 59, 4, 3, _white.withValues(alpha: 0.7), line: false);
      case _Nose.beak:
        _shape(_poly([43, 60, 57, 60, 50, 71]), const Color(0xFFFFB02E));
      case _Nose.hook:
        _shape(
          Path()
            ..moveTo(39, 58)
            ..quadraticBezierTo(50, 54, 61, 58)
            ..quadraticBezierTo(60, 74, 50, 80)
            ..quadraticBezierTo(41, 72, 39, 58)
            ..close(),
          const Color(0xFFFFC93C),
        );
      case _Nose.nostrils:
        _oval(45, 66, 3.5, 4, _ink, line: false);
        _oval(55, 66, 3.5, 4, _ink, line: false);
    }
  }

  void _mouth() {
    const dark = Color(0xFF7A2A4A);
    final lw = _lw;
    switch (spec.mouth) {
      case _Mouth.none:
        break;
      case _Mouth.smile:
        _stroke(Path()..moveTo(43, 70)..quadraticBezierTo(50, 77, 57, 70), _ink, lw);
      case _Mouth.smirk:
        _stroke(Path()..moveTo(42, 71)..quadraticBezierTo(53, 77, 60, 67), _ink, lw);
      case _Mouth.cat:
        _stroke(
          Path()
            ..moveTo(50, 66)
            ..lineTo(50, 69)
            ..moveTo(50, 69)
            ..quadraticBezierTo(46, 74, 42, 70)
            ..moveTo(50, 69)
            ..quadraticBezierTo(54, 74, 58, 70),
          _ink,
          lw * 0.8,
        );
      case _Mouth.grin:
        final p = Path()
          ..moveTo(38, 66)
          ..quadraticBezierTo(50, 88, 62, 66)
          ..close();
        _shape(p, dark);
        _oval(50, 76, 10, 6, const Color(0xFFFF8FB1), line: false);
      case _Mouth.tongue:
        _oval(50, 75, 9, 10, const Color(0xFFFF8FB1));
        _stroke(Path()..moveTo(42, 69)..quadraticBezierTo(50, 77, 58, 69), _ink, lw);
      case _Mouth.o:
        _oval(50, 71, 7, 9, dark);
      case _Mouth.teeth:
        final p = Path()
          ..moveTo(35, 66)
          ..quadraticBezierTo(50, 86, 65, 66)
          ..close();
        _shape(p, dark);
        for (var i = 0; i < 4; i++) {
          final x = 38.5 + i * 6.8;
          _shape(_poly([x, 67, x + 5, 67, x + 2.5, 72.5]), _white, line: false);
        }
        _stroke(p, _ink, lw);
      case _Mouth.flat:
        _shape(
          Path()..addRRect(RRect.fromRectAndRadius(
              const Rect.fromLTWH(38, 66, 24, 10), const Radius.circular(3))),
          _white,
        );
        for (final x in [44.0, 50.0, 56.0]) {
          _seg(x, 66, x, 76, w: _lw * 0.4);
        }
      case _Mouth.evil:
        final p = Path()
          ..moveTo(35, 66)
          ..quadraticBezierTo(50, 88, 65, 66)
          ..close();
        _shape(p, dark);
        _shape(_poly([40, 67, 45, 67, 42.5, 73]), _white, line: false);
        _shape(_poly([55, 67, 60, 67, 57.5, 73]), _white, line: false);
        _stroke(p, _ink, lw);
    }
  }

  // 얼굴 앞에 얹는 요소
  void _front(Set<_Mk> m) {
    if (m.contains(_Mk.whiskers)) {
      for (final s in [-1.0, 1.0]) {
        _seg(50 + s * 20, 66, 50 + s * 42, 60, w: _lw * 0.5);
        _seg(50 + s * 20, 70, 50 + s * 43, 71, w: _lw * 0.5);
      }
    }
    if (m.contains(_Mk.buckteeth)) {
      for (final x in [45.5, 50.5]) {
        _shape(
          Path()..addRRect(RRect.fromRectAndRadius(
              Rect.fromLTWH(x, 71, 5, 8), const Radius.circular(1.5))),
          _white,
        );
      }
    }
    if (m.contains(_Mk.mustache)) {
      _oval(42, 70, 16, 9, _white, rot: 0.3);
      _oval(58, 70, 16, 9, _white, rot: -0.3);
    }
    if (m.contains(_Mk.brows)) {
      for (final s in [-1.0, 1.0]) {
        _seg(50 + s * 22, 42, 50 + s * 7, 48, w: _lw * 1.1);
      }
    }
    if (m.contains(_Mk.gills)) {
      for (final s in [-1.0, 1.0]) {
        for (var i = 0; i < 3; i++) {
          _seg(50 + s * 31, 54 + i * 6, 50 + s * 27, 57 + i * 6, w: _lw * 0.5);
        }
      }
    }
    if (m.contains(_Mk.horns)) {
      _both([26, 32, 20, 8, 38, 27], spec.accent);
    }
    if (m.contains(_Mk.devilHorns)) {
      _both([26, 34, 17, 6, 40, 28], const Color(0xFFB3262B));
    }
    if (m.contains(_Mk.horn)) {
      _shape(_poly([43, 28, 50, 0, 57, 28]), const Color(0xFFFFD23F));
      _seg(45, 20, 54, 17, w: _lw * 0.5);
      _seg(44, 25, 56, 22, w: _lw * 0.5);
    }
    if (m.contains(_Mk.crest)) {
      _flame(38, 32, 22, 7, -0.2, const Color(0xFFFFA63D));
      _flame(62, 32, 22, 7, 0.2, const Color(0xFFFFA63D));
      _flame(50, 30, 30, 9, 0, const Color(0xFFFFD23F));
    }
    if (m.contains(_Mk.halo)) {
      final ring = Path()..addOval(const Rect.fromLTWH(32, 9, 36, 12));
      _stroke(ring, _ink, _lw * 2.6);
      _stroke(ring, const Color(0xFFFFD23F), _lw * 1.2);
    }
    if (m.contains(_Mk.crown)) {
      final p = Path()
        ..moveTo(29, 32)
        ..lineTo(28, 10)
        ..lineTo(40, 21)
        ..lineTo(50, 6)
        ..lineTo(60, 21)
        ..lineTo(72, 10)
        ..lineTo(71, 32)
        ..close();
      _shape(p, const Color(0xFFFFD23F));
      _c.drawCircle(const Offset(50, 24), 3, _fill..color = const Color(0xFFFF5470));
      _c.drawCircle(const Offset(38, 28), 2.4, _fill..color = const Color(0xFF4DB8FF));
      _c.drawCircle(const Offset(62, 28), 2.4, _fill..color = const Color(0xFF3DDBB0));
    }
    if (m.contains(_Mk.shades)) {
      for (final x in [36.0, 64.0]) {
        _shape(
          Path()..addRRect(RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(x, 53), width: 24, height: 15),
              const Radius.circular(6))),
          _ink,
        );
        _seg(x - 7, 49, x - 2, 49, w: _lw * 0.6, col: _white.withValues(alpha: 0.8));
      }
      _seg(48, 52, 52, 52, w: _lw);
    }
  }

  @override
  bool shouldRepaint(_AvatarPainter old) =>
      old.spec != spec ||
      old.bg != bg ||
      old.circle != circle ||
      old.outline != outline;
}
