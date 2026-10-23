import 'package:flutter/material.dart';
import '../services/remote_config_service.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';

class MaintenanceScreen extends StatelessWidget {
  final RemoteConfigService configService;
  final VoidCallback? onRetry;

  const MaintenanceScreen({
    super.key,
    required this.configService,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final maintenance = configService.maintenanceInfo;
    final endTimeFormatted = configService.getMaintenanceEndTimeFormatted();

    return Scaffold(
      body: FloatingBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const DuoMascot(
                    size: 130,
                    color: CandyColors.tangerine,
                    mood: MascotMood.sad,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '서버 점검 중',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: CandyColors.ink,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    maintenance?.message ?? '서버 점검 중입니다.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.5,
                      fontWeight: FontWeight.w700,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (endTimeFormatted.isNotEmpty)
                    CartoonCard(
                      radius: 18,
                      shadow: 4,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 12,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            '예상 종료 시간',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: CandyColors.inkSoft,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            endTimeFormatted,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              color: CandyColors.tangerine,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 36),
                  if (onRetry != null)
                    ChunkyButton(
                      label: '다시 확인',
                      icon: Icons.refresh_rounded,
                      color: CandyColors.tangerine,
                      expand: false,
                      onPressed: onRetry,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 서버 연결 실패 화면 (점검 정보 없이 연결만 실패한 경우)
class ConnectionFailedScreen extends StatelessWidget {
  final VoidCallback? onRetry;

  const ConnectionFailedScreen({super.key, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FloatingBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const DuoMascot(
                    size: 130,
                    color: CandyColors.sky,
                    mood: MascotMood.sad,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '연결 실패',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: CandyColors.ink,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '서버에 연결할 수 없어요.\n네트워크 연결을 확인해주세요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.5,
                      fontWeight: FontWeight.w700,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                  const SizedBox(height: 36),
                  if (onRetry != null)
                    ChunkyButton(
                      label: '다시 시도',
                      icon: Icons.refresh_rounded,
                      expand: false,
                      onPressed: onRetry,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
