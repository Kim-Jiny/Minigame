import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/candy_theme.dart';

/// 굵은 아웃라인 + 하드 섀도우 카드. [onTap] 이 있으면 눌림 애니메이션이 붙는다.
class CartoonCard extends StatefulWidget {
  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final double shadow;

  const CartoonCard({
    super.key,
    required this.child,
    this.color = Colors.white,
    this.padding = const EdgeInsets.all(16),
    this.radius = CandyTheme.radius,
    this.onTap,
    this.shadow = 5,
  });

  @override
  State<CartoonCard> createState() => _CartoonCardState();
}

class _CartoonCardState extends State<CartoonCard> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    final offset = _down ? 1.0 : widget.shadow;
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOut,
      margin: EdgeInsets.only(top: widget.shadow - offset, bottom: offset),
      padding: widget.padding,
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(color: CandyColors.ink, width: CandyTheme.outline),
        boxShadow: [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, offset)),
        ],
      ),
      child: widget.child,
    );
    if (!tappable) return card;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap!();
      },
      child: card,
    );
  }
}
