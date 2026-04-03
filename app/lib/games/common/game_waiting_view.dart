import 'dart:async';
import 'package:flutter/material.dart';

class GameWaitingView extends StatefulWidget {
  final LinearGradient backgroundGradient;
  final Color accentColor;
  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> statusMessages;

  const GameWaitingView({
    super.key,
    required this.backgroundGradient,
    required this.accentColor,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.statusMessages = const [],
  });

  @override
  State<GameWaitingView> createState() => _GameWaitingViewState();
}

class _GameWaitingViewState extends State<GameWaitingView> {
  Timer? _messageTimer;
  int _messageIndex = 0;

  @override
  void initState() {
    super.initState();
    _startMessageRotation();
  }

  @override
  void didUpdateWidget(covariant GameWaitingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statusMessages.join('|') != widget.statusMessages.join('|')) {
      _messageIndex = 0;
      _startMessageRotation();
    }
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    super.dispose();
  }

  void _startMessageRotation() {
    _messageTimer?.cancel();
    if (widget.statusMessages.length < 2) return;
    _messageTimer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (!mounted) return;
      setState(() {
        _messageIndex = (_messageIndex + 1) % widget.statusMessages.length;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasStatusMessages = widget.statusMessages.isNotEmpty;
    final currentStatus = hasStatusMessages ? widget.statusMessages[_messageIndex] : null;

    return Container(
      decoration: BoxDecoration(gradient: widget.backgroundGradient),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 30),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: widget.accentColor.withValues(alpha: 0.16),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: widget.accentColor.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(widget.icon, color: widget.accentColor, size: 32),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: widget.accentColor,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                    if (currentStatus != null) ...[
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: widget.accentColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: Text(
                            currentStatus,
                            key: ValueKey(currentStatus),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: widget.accentColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
