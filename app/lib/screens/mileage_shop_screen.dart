import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stats_provider.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

class MileageShopScreen extends StatelessWidget {
  const MileageShopScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('코인 샵')),
      body: Consumer<StatsProvider>(
        builder: (context, statsProvider, child) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (statsProvider.error != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(statsProvider.error!),
                  backgroundColor: Colors.red,
                ),
              );
              statsProvider.clearMessages();
            }
            if (statsProvider.successMessage != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(statsProvider.successMessage!),
                  backgroundColor: Colors.green,
                ),
              );
              statsProvider.clearMessages();
            }
          });

          return FloatingBackground(
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PopIn(child: _buildHeaderBanner(context, statsProvider)),
                    const SizedBox(height: 16),
                    PopIn(
                      delay: const Duration(milliseconds: 80),
                      child: _buildQuickActions(context, statsProvider),
                    ),
                    const SizedBox(height: 20),
                    _buildSectionTitle('코인 획득'),
                    const SizedBox(height: 12),
                    PopIn(
                      delay: const Duration(milliseconds: 160),
                      child: _buildEarnCard(context, statsProvider),
                    ),
                    const SizedBox(height: 22),
                    _buildSectionTitle('상점 아이템'),
                    const SizedBox(height: 12),
                    _buildShopGrid(context, statsProvider),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _coin({double size = 56}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: CandyColors.sun,
        border: Border.all(color: CandyColors.ink, width: CandyTheme.outline),
      ),
      child: Icon(
        Icons.monetization_on_rounded,
        color: CandyColors.sunDeep,
        size: size * 0.62,
      ),
    );
  }

  Widget _buildHeaderBanner(BuildContext context, StatsProvider statsProvider) {
    return CartoonCard(
      color: CandyColors.sun,
      child: Row(
        children: [
          _coin(size: 64),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '보유 코인',
                  style: TextStyle(
                    color: CandyColors.ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: statsProvider.mileage.toDouble()),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${v.round()}',
                      style: const TextStyle(
                        color: CandyColors.ink,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                const Text(
                  '게임에서 승리하거나 광고로 코인을 모아보세요',
                  style: TextStyle(
                    color: CandyColors.ink,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildSeasonBadge(),
        ],
      ),
    );
  }

  Widget _buildSeasonBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: CandyColors.mint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CandyColors.ink, width: 2.5),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt_rounded, color: CandyColors.ink, size: 16),
          SizedBox(width: 2),
          Text(
            'BONUS',
            style: TextStyle(
              color: CandyColors.ink,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(BuildContext context, StatsProvider statsProvider) {
    return Row(
      children: [
        Expanded(
          child: _buildQuickButton(
            label: '코인 상자',
            sub: '오늘 한 번',
            icon: Icons.card_giftcard_rounded,
            color: CandyColors.mint,
            onTap: statsProvider.isLoading ? null : statsProvider.claimAdReward,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildQuickButton(
            label: '랭크 보상',
            sub: '이번 주',
            icon: Icons.emoji_events_rounded,
            color: CandyColors.pink,
            onTap: null,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickButton({
    required String label,
    required String sub,
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: CartoonCard(
        onTap: onTap,
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CandyColors.ink,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CandyColors.inkSoft,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEarnCard(BuildContext context, StatsProvider statsProvider) {
    return CartoonCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: CandyColors.pink,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: CandyColors.ink, width: 2.5),
            ),
            child: const Icon(
              Icons.play_arrow_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '광고 시청',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                    fontSize: 15,
                  ),
                ),
                Text(
                  '짧은 광고로 코인을 받으세요',
                  style: TextStyle(
                    color: CandyColors.inkSoft,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ChunkyButton(
            onPressed: statsProvider.isLoading
                ? null
                : () {
                    statsProvider.claimAdReward();
                  },
            icon: Icons.add_rounded,
            label: '+10',
            color: CandyColors.sun,
            textColor: CandyColors.ink,
            height: 44,
            radius: 14,
            fontSize: 15,
            expand: false,
          ),
        ],
      ),
    );
  }

  Widget _buildShopGrid(BuildContext context, StatsProvider statsProvider) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 520;
        final cardWidth = isWide
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: cardWidth,
              child: PopIn(
                delay: const Duration(milliseconds: 240),
                child: _buildShopTile(
                  context,
                  icon: Icons.refresh_rounded,
                  title: '승률 초기화권',
                  description: '게임 승률을 초기화합니다 (레벨 유지)',
                  price: 100,
                  accent: CandyColors.sky,
                  enabled: true,
                  onTap: () =>
                      _showResetGameSelectDialog(context, statsProvider),
                ),
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: PopIn(
                delay: const Duration(milliseconds: 320),
                child: _buildShopTile(
                  context,
                  icon: Icons.color_lens_rounded,
                  title: '프로필 테마',
                  description: '준비 중',
                  price: 200,
                  accent: CandyColors.grape,
                  enabled: false,
                  onTap: () {},
                ),
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: PopIn(
                delay: const Duration(milliseconds: 400),
                child: _buildShopTile(
                  context,
                  icon: Icons.shield_moon_rounded,
                  title: '패배 삭제권',
                  description: '최근 1패를 기록에서 제거',
                  price: 50,
                  accent: CandyColors.mint,
                  enabled: true,
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('구매 기능 준비 중입니다.')),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildShopTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required int price,
    required Color accent,
    required VoidCallback onTap,
    required bool enabled,
  }) {
    return CartoonCard(
      color: enabled ? Colors.white : const Color(0xFFEFEAF7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: enabled ? accent : const Color(0xFFD9D4E4),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: CandyColors.ink, width: 2.5),
                ),
                child: Icon(icon, color: Colors.white, size: 26),
              ),
              const Spacer(),
              _priceChip(price: price, enabled: enabled),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: enabled ? CandyColors.ink : CandyColors.inkSoft,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: const TextStyle(
              color: CandyColors.inkSoft,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          ChunkyButton(
            onPressed: enabled ? onTap : null,
            label: enabled ? '구매' : '잠김',
            icon: enabled ? null : Icons.lock_rounded,
            color: CandyColors.sun,
            textColor: CandyColors.ink,
            height: 46,
            radius: 14,
            fontSize: 15,
          ),
        ],
      ),
    );
  }

  Widget _priceChip({required int price, required bool enabled}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: enabled ? CandyColors.sun : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: CandyColors.ink, width: 2.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.monetization_on_rounded,
            size: 16,
            color: enabled ? CandyColors.sunDeep : CandyColors.inkSoft,
          ),
          const SizedBox(width: 4),
          Text(
            '$price',
            style: const TextStyle(
              color: CandyColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 20,
          decoration: BoxDecoration(
            color: CandyColors.pink,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: CandyColors.ink, width: 2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
        ),
      ],
    );
  }

  void _showResetGameSelectDialog(
    BuildContext context,
    StatsProvider statsProvider,
  ) {
    final gameTypes = [
      {
        'type': 'tictactoe',
        'name': '틱택토',
        'icon': Icons.grid_3x3,
        'color': const Color(0xFFFF6B9D),
      },
      {
        'type': 'infinite_tictactoe',
        'name': '무한 틱택토',
        'icon': Icons.all_inclusive,
        'color': const Color(0xFF74B9FF),
      },
      {
        'type': 'gomoku',
        'name': '오목',
        'icon': Icons.circle_outlined,
        'color': const Color(0xFF2D3436),
      },
      {
        'type': 'reaction',
        'name': '반응속도',
        'icon': Icons.flash_on,
        'color': const Color(0xFFE17055),
      },
      {
        'type': 'rps',
        'name': '가위바위보',
        'icon': Icons.front_hand,
        'color': const Color(0xFF9B59B6),
      },
      {
        'type': 'speedtap',
        'name': '스피드탭',
        'icon': Icons.touch_app,
        'color': const Color(0xFF00CEC9),
      },
      {
        'type': 'sequence',
        'name': '순서 기억',
        'icon': Icons.psychology,
        'color': const Color(0xFFE056FD),
      },
      {
        'type': 'stroop',
        'name': '스트룹',
        'icon': Icons.palette,
        'color': const Color(0xFF00CEC9),
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: CandyColors.cream,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: CandyColors.ink, width: 3),
              left: BorderSide(color: CandyColors.ink, width: 3),
              right: BorderSide(color: CandyColors.ink, width: 3),
            ),
          ),
          padding: const EdgeInsets.all(24),
          child: ListView(
            controller: scrollController,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: CandyColors.ink,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '승률 초기화',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '어떤 게임의 승률을 초기화할까요?',
                style: const TextStyle(
                  color: CandyColors.inkSoft,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              ...gameTypes.map(
                (game) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: CartoonCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    shadow: 3,
                    onTap: () {
                      Navigator.pop(context);
                      _confirmReset(
                        context,
                        statsProvider,
                        game['type'] as String,
                        game['name'] as String,
                      );
                    },
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: game['color'] as Color,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: CandyColors.ink,
                              width: 2.5,
                            ),
                          ),
                          child: Icon(
                            game['icon'] as IconData,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            game['name'] as String,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: CandyColors.ink,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: CandyColors.ink,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmReset(
    BuildContext context,
    StatsProvider statsProvider,
    String gameType,
    String gameName,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$gameName의 승률을 초기화할까요?'),
            const SizedBox(height: 8),
            Text(
              '100 마일리지가 차감됩니다.',
              style: TextStyle(
                color: CandyColors.inkSoft,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              statsProvider.resetStats(gameType);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: CandyColors.sun,
              foregroundColor: CandyColors.ink,
            ),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
  }
}
