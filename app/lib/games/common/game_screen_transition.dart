import 'package:flutter/material.dart';

class GameScreenTransition extends StatelessWidget {
  final Widget child;
  final Object transitionKey;
  final Duration duration;
  final Offset beginOffset;

  const GameScreenTransition({
    super.key,
    required this.child,
    required this.transitionKey,
    this.duration = const Duration(milliseconds: 260),
    this.beginOffset = const Offset(0, 0.04),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        final offsetAnimation = Tween<Offset>(
          begin: beginOffset,
          end: Offset.zero,
        ).animate(curved);

        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: offsetAnimation,
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<Object>(transitionKey),
        child: child,
      ),
    );
  }
}
