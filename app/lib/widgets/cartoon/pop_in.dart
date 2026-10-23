import 'dart:async';
import 'package:flutter/material.dart';

/// 지연 후 통통 튀며 등장(스케일 + 페이드 + 살짝 위로). 리스트 순차 등장에 쓴다.
class PopIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;

  const PopIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 520),
  });

  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _timer = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.elasticOut.transform(_c.value.clamp(0.0, 1.0));
        final fade = Curves.easeOut.transform((_c.value * 2).clamp(0.0, 1.0));
        return Opacity(
          opacity: fade,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 24),
            child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
          ),
        );
      },
    );
  }
}
