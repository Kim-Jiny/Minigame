import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stats_provider.dart';

class MileageShopScreen extends StatelessWidget {
  const MileageShopScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('마일리지 샵'),
        backgroundColor: Colors.amber.shade600,
        foregroundColor: Colors.white,
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

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 내 마일리지
                _buildMileageCard(context, statsProvider),
                const SizedBox(height: 24),

                // 마일리지 획득
                Text(
                  '마일리지 획득',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade800,
                  ),
                ),
                const SizedBox(height: 12),
                _buildEarnCard(context, statsProvider),
                const SizedBox(height: 24),

                // 상점
                Text(
                  '상점',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade800,
                  ),
                ),
                const SizedBox(height: 12),
                _buildShopItem(
                  context,
                  icon: Icons.refresh,
                  title: '승률 초기화권',
                  description: '게임 승률을 초기화합니다 (레벨 유지)',
                  price: 100,
                  onTap: () {
                    _showResetGameSelectDialog(context, statsProvider);
                  },
                ),
                // 추가 아이템은 나중에
                _buildShopItem(
                  context,
                  icon: Icons.color_lens,
                  title: '프로필 테마',
                  description: '준비 중',
                  price: 200,
                  enabled: false,
                  onTap: () {},
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMileageCard(BuildContext context, StatsProvider statsProvider) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [Colors.amber.shade600, Colors.amber.shade400],
          ),
        ),
        child: Column(
          children: [
            const Icon(Icons.monetization_on, color: Colors.white, size: 48),
            const SizedBox(height: 8),
            const Text(
              '내 마일리지',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              '${statsProvider.mileage}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 40,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEarnCard(BuildContext context, StatsProvider statsProvider) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.blue.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.play_circle_filled, color: Colors.blue.shade700),
        ),
        title: const Text('광고 시청', style: TextStyle(fontWeight: FontWeight.bold)),
        subtitle: const Text('광고를 보고 마일리지를 받으세요'),
        trailing: ElevatedButton(
          onPressed: statsProvider.isLoading
              ? null
              : () {
                  statsProvider.claimAdReward();
                },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.amber.shade600,
            foregroundColor: Colors.white,
          ),
          child: const Text('+10'),
        ),
      ),
    );
  }

  Widget _buildShopItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
    required int price,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        enabled: enabled,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: enabled ? Colors.purple.shade100 : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: enabled ? Colors.purple.shade700 : Colors.grey),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: enabled ? null : Colors.grey,
          ),
        ),
        subtitle: Text(
          description,
          style: TextStyle(color: enabled ? null : Colors.grey),
        ),
        trailing: OutlinedButton.icon(
          onPressed: enabled ? onTap : null,
          icon: const Icon(Icons.monetization_on, size: 16),
          label: Text('$price'),
          style: OutlinedButton.styleFrom(
            foregroundColor: enabled ? Colors.amber.shade700 : Colors.grey,
          ),
        ),
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
