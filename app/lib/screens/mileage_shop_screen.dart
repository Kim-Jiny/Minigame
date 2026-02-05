import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stats_provider.dart';

class MileageShopScreen extends StatelessWidget {
  const MileageShopScreen({super.key});

  static const Color _bgTop = Color(0xFF111827);
  static const Color _bgBottom = Color(0xFF0B1022);
  static const Color _gold = Color(0xFFF7C948);
  static const Color _goldDeep = Color(0xFFD9A441);
  static const Color _panel = Color(0xFF1B2238);
  static const Color _panelAlt = Color(0xFF24304F);
  static const Color _accent = Color(0xFF6C5CE7);
  static const Color _teal = Color(0xFF00D2D3);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('코인 샵'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Consumer<StatsProvider>(
        builder: (context, statsProvider, child) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (statsProvider.error != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(statsProvider.error!), backgroundColor: Colors.red),
              );
              statsProvider.clearMessages();
            }
            if (statsProvider.successMessage != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(statsProvider.successMessage!), backgroundColor: Colors.green),
              );
              statsProvider.clearMessages();
            }
          });

          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [_bgTop, _bgBottom],
              ),
            ),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeaderBanner(context, statsProvider),
                    const SizedBox(height: 16),
                    _buildQuickActions(context, statsProvider),
                    const SizedBox(height: 18),
                    _buildSectionTitle('코인 획득'),
                    const SizedBox(height: 12),
                    _buildEarnCard(context, statsProvider),
                    const SizedBox(height: 20),
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

  Widget _buildHeaderBanner(BuildContext context, StatsProvider statsProvider) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [_panel, _panelAlt],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [_gold, _goldDeep],
              ),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.35),
                  blurRadius: 14,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.monetization_on, color: Color(0xFF3A2A00), size: 34),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '보유 코인',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${statsProvider.mileage}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '게임에서 승리하거나 광고로 코인을 모아보세요',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          _buildSeasonBadge(),
        ],
      ),
    );
  }

  Widget _buildSeasonBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_teal, Color(0xFF20E3B2)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          Icon(Icons.bolt, color: Color(0xFF062B2C), size: 16),
          SizedBox(width: 6),
          Text(
            'BONUS',
            style: TextStyle(color: Color(0xFF062B2C), fontSize: 11, letterSpacing: 1.0),
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
            icon: Icons.card_giftcard,
            color: _teal,
            onTap: statsProvider.isLoading ? null : statsProvider.claimAdReward,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildQuickButton(
            label: '랭크 보상',
            sub: '이번 주',
            icon: Icons.emoji_events,
            color: _accent,
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: _panel,
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEarnCard(BuildContext context, StatsProvider statsProvider) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: _panel,
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.play_circle_filled, color: _accent),
        ),
        title: const Text('광고 시청', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        subtitle: Text(
          '짧은 광고로 코인을 받으세요',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
        ),
        trailing: ElevatedButton.icon(
          onPressed: statsProvider.isLoading
              ? null
              : () {
                  statsProvider.claimAdReward();
                },
          style: ElevatedButton.styleFrom(
            backgroundColor: _gold,
            foregroundColor: const Color(0xFF3A2A00),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('+10'),
        ),
      ),
    );
  }

  Widget _buildShopGrid(BuildContext context, StatsProvider statsProvider) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 520;
        final cardWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: cardWidth,
              child: _buildShopTile(
                context,
                icon: Icons.refresh,
                title: '승률 초기화권',
                description: '게임 승률을 초기화합니다 (레벨 유지)',
                price: 100,
                enabled: true,
                onTap: () => _showResetGameSelectDialog(context, statsProvider),
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _buildShopTile(
                context,
                icon: Icons.color_lens,
                title: '프로필 테마',
                description: '준비 중',
                price: 200,
                enabled: false,
                onTap: () {},
              ),
            ),
            SizedBox(
              width: cardWidth,
              child: _buildShopTile(
                context,
                icon: Icons.shield_moon,
                title: '패배 삭제권',
                description: '최근 1패를 기록에서 제거',
                price: 50,
                enabled: true,
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('구매 기능 준비 중입니다.')),
                  );
                },
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
    required VoidCallback onTap,
    required bool enabled,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: enabled ? _panelAlt : _panel,
          border: Border.all(color: Colors.white.withValues(alpha: enabled ? 0.08 : 0.04)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: enabled ? _accent.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: enabled ? _accent : Colors.white.withValues(alpha: 0.4)),
                ),
                const Spacer(),
                _priceChip(price: price, enabled: enabled),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white.withValues(alpha: 0.5),
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              style: TextStyle(
                color: enabled ? Colors.white.withValues(alpha: 0.65) : Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: enabled ? onTap : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: enabled ? _gold : Colors.white.withValues(alpha: 0.15),
                  foregroundColor: enabled ? const Color(0xFF3A2A00) : Colors.white.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(enabled ? '구매' : '잠김'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _priceChip({required int price, required bool enabled}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: enabled ? _gold.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: enabled ? _gold.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.monetization_on, size: 14, color: enabled ? _gold : Colors.white.withValues(alpha: 0.4)),
          const SizedBox(width: 4),
          Text(
            '$price',
            style: TextStyle(
              color: enabled ? _gold : Colors.white.withValues(alpha: 0.5),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: Colors.white.withValues(alpha: 0.9),
        letterSpacing: 0.4,
      ),
    );
  }

  void _showResetGameSelectDialog(BuildContext context, StatsProvider statsProvider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('승률 초기화'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('어떤 게임의 승률을 초기화할까요?'),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.grid_3x3, color: Color(0xFF6C5CE7)),
              title: const Text('틱택토'),
              onTap: () {
                Navigator.pop(context);
                _confirmReset(context, statsProvider, 'tictactoe', '틱택토');
              },
            ),
            ListTile(
              leading: const Icon(Icons.all_inclusive, color: Color(0xFF74B9FF)),
              title: const Text('무한 틱택토'),
              onTap: () {
                Navigator.pop(context);
                _confirmReset(context, statsProvider, 'infinite_tictactoe', '무한 틱택토');
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  void _confirmReset(BuildContext context, StatsProvider statsProvider, String gameType, String gameName) {
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
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
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
              backgroundColor: Colors.amber.shade600,
              foregroundColor: Colors.white,
            ),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
  }
}
