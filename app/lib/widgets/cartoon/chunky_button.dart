import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/candy_theme.dart';

/// 눌리면 아래로 "푹" 꺼지는 두툼한 카툰 버튼.
/// [onPressed] 가 null 이면 회색 비활성 상태.
class ChunkyButton extends StatefulWidget {
  final String? label;
  final Widget? child;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color color;
  final Color textColor;
  final double height;
  final double radius;
  final bool expand;
  final double fontSize;

  const ChunkyButton({
    super.key,
    this.label,
    this.child,
    this.icon,
    required this.onPressed,
    this.color = CandyColors.pink,
    this.textColor = Colors.white,
    this.height = 56,
    this.radius = 18,
    this.expand = true,
    this.fontSize = 18,
  }) : assert(label != null || child != null);

  @override
  State<ChunkyButton> createState() => _ChunkyButtonState();
}

class _ChunkyButtonState extends State<ChunkyButton> {
  bool _down = false;

  static const double _depth = 6;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final face = enabled ? widget.color : const Color(0xFFD9D4E4);
    final base = enabled
        ? CandyColors.deepen(widget.color)
        : const Color(0xFFB9B3C9);
    final fg = enabled ? widget.textColor : Colors.white;
    final shift = _down && enabled ? _depth : 0.0;

    final content =
        widget.child ??
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, color: fg, size: widget.fontSize + 4),
              const SizedBox(width: 8),
            ],
            // 좁은 버튼에서는 글자가 줄어들어 넘치지 않게 한다.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  widget.label!,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: CandyTheme.displayFont,
                    color: fg,
                    fontSize: widget.fontSize,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ),
          ],
        );

    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapCancel: enabled ? () => setState(() => _down = false) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTap: enabled
          ? () {
              HapticFeedback.lightImpact();
              widget.onPressed!();
            }
          : null,
      child: SizedBox(
        height: widget.height + _depth,
        child: Stack(
          children: [
            // 아래 "두께"
            Positioned(
              left: 0,
              right: 0,
              top: _depth,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: base,
                  borderRadius: BorderRadius.circular(widget.radius),
                  border: Border.all(color: CandyColors.ink, width: 3),
                ),
              ),
            ),
            // 윗면
            AnimatedPositioned(
              duration: const Duration(milliseconds: 70),
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              top: shift,
              height: widget.height,
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: face,
                  borderRadius: BorderRadius.circular(widget.radius),
                  border: Border.all(color: CandyColors.ink, width: 3),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 광택 하이라이트
                    Positioned(
                      left: 14,
                      right: 14,
                      top: 5,
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: enabled ? 0.35 : 0.2,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                    content,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return widget.expand ? button : IntrinsicWidth(child: button);
  }
}
