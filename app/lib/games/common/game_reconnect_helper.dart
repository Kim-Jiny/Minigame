import 'dart:async';
import 'package:flutter/material.dart';

class GameReconnectHelper {
  static const Duration reconnectGraceDuration = Duration(seconds: 20);

  static void _showTransientBanner({
    required BuildContext context,
    required String message,
    required Color backgroundColor,
  }) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearMaterialBanners()
      ..hideCurrentSnackBar();
    messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: backgroundColor,
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: const Icon(Icons.wifi_tethering_rounded, color: Colors.white),
        actions: const [SizedBox.shrink()],
      ),
    );
    Timer(const Duration(milliseconds: 1800), () {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    });
  }

  static Timer startVisualCountdown({
    required ValueChanged<int> onTick,
    Duration timeout = reconnectGraceDuration,
    VoidCallback? onCompleted,
  }) {
    var remainingSeconds = timeout.inSeconds;
    onTick(remainingSeconds);

    return Timer.periodic(const Duration(seconds: 1), (timer) {
      remainingSeconds--;
      final clampedSeconds = remainingSeconds.clamp(0, timeout.inSeconds);
      onTick(clampedSeconds);

      if (remainingSeconds > 0) {
        return;
      }

      timer.cancel();
      onCompleted?.call();
    });
  }

  static Timer startReconnectTimeout({
    required BuildContext context,
    required VoidCallback onEnterWaiting,
    required VoidCallback onTimeout,
    ValueChanged<int>? onTick,
    Duration timeout = reconnectGraceDuration,
    String failureMessage = '재연결에 실패했습니다',
    bool showFailureSnackBar = true,
  }) {
    onEnterWaiting();
    var remainingSeconds = timeout.inSeconds;
    onTick?.call(remainingSeconds);

    return Timer.periodic(const Duration(seconds: 1), (timer) {
      remainingSeconds--;
      onTick?.call(remainingSeconds.clamp(0, timeout.inSeconds));

      if (remainingSeconds > 0) {
        return;
      }

      timer.cancel();
      if (!context.mounted) return;
      onTimeout();
      if (showFailureSnackBar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(failureMessage),
            backgroundColor: Colors.orange,
          ),
        );
      }
    });
  }

  static void completeReconnect({
    required BuildContext context,
    required VoidCallback onRecovered,
    String successMessage = '연결이 복구되었습니다. 게임을 다시 시작합니다.',
  }) {
    onRecovered();
    _showTransientBanner(
      context: context,
      message: successMessage,
      backgroundColor: const Color(0xFF16A34A),
    );
  }

  static void showOpponentReconnected(BuildContext context) {
    _showTransientBanner(
      context: context,
      message: '상대가 돌아왔습니다. 게임을 다시 이어갑니다.',
      backgroundColor: const Color(0xFF16A34A),
    );
  }

  static Widget buildReconnectOverlay({
    required String title,
    required String message,
    String? resultMessage,
    int? secondsRemaining,
    String countdownLabel = '자동 처리까지',
    Color barrierColor = const Color(0xCC111827),
    Color accentColor = const Color(0xFF2563EB),
  }) {
    return Positioned.fill(
      child: ColoredBox(
        color: barrierColor,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: accentColor,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: accentColor,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: Color(0xFF4B5563),
                          ),
                        ),
                        if (resultMessage != null) ...[
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: accentColor.withValues(alpha: 0.18)),
                            ),
                            child: Text(
                              resultMessage,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: accentColor,
                              ),
                            ),
                          ),
                        ],
                        if (secondsRemaining != null) ...[
                          const SizedBox(height: 18),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F4F6),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  '$secondsRemaining초',
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  countdownLabel,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF6B7280),
                                  ),
                                ),
                              ],
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
        ),
      ),
    );
  }
}
