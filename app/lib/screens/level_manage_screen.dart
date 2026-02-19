import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stats_provider.dart';

class LevelManageScreen extends StatelessWidget {
  const LevelManageScreen({super.key});

  static const List<_GameMeta> _allGames = [
    _GameMeta('tictactoe', '틱택토', Icons.grid_3x3, Color(0xFF6C5CE7)),
    _GameMeta('infinite_tictactoe', '무한 틱택토', Icons.all_inclusive, Color(0xFF74B9FF)),
    _GameMeta('gomoku', '오목', Icons.circle_outlined, Color(0xFF2D3436)),
    _GameMeta('reaction', '반응속도', Icons.flash_on, Color(0xFFE17055)),
    _GameMeta('rps', '가위바위보', Icons.front_hand, Color(0xFF9B59B6)),
    _GameMeta('speedtap', '스피드탭', Icons.touch_app, Color(0xFF16A085)),
    _GameMeta('sequence', '순서 기억', Icons.memory, Color(0xFF00B894)),
    _GameMeta('stroop', '스트룹', Icons.palette, Color(0xFFE84393)),
    _GameMeta('hexagon', '헥사곤', Icons.hexagon_outlined, Color(0xFFF39C12)),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 레벨'),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Consumer<StatsProvider>(
        builder: (context, statsProvider, _) {
          return RefreshIndicator(
            onRefresh: () async => statsProvider.getAllStats(),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummaryCard(context, statsProvider),
                  const SizedBox(height: 20),
                  _buildSectionHeader(statsProvider),
                  const SizedBox(height: 12),
                  _buildGameGrid(context, statsProvider),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, StatsProvider statsProvider) {
    final statsMap = {for (final s in statsProvider.allStats) s.gameType: s};
    int totalLevel = 0;
    int totalWins = 0;
    int totalGames = 0;
    int playedGames = 0;

    for (final meta in _allGames) {
      final stats = statsMap[meta.type];
      if (stats != null) {
        totalLevel += stats.level;
        totalWins += stats.wins;
        totalGames += stats.totalGames;
        if (stats.totalGames > 0) playedGames++;
      }
    }

    final winRate = totalGames > 0 ? (totalWins / totalGames * 100).round() : 0;
    final completion = ((playedGames / _allGames.length) * 100).round();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [
            Theme.of(context).primaryColor,
            Theme.of(context).primaryColor.withValues(alpha: 0.75),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).primaryColor.withValues(alpha: 0.3),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('통합 진행도', style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 8),
          Text(
            'Lv. $totalLevel',
            style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _summaryMetric('플레이', '$playedGames/${_allGames.length}'),
              _summaryMetric('총 게임', '$totalGames'),
              _summaryMetric('승률', '$winRate%'),
              _summaryMetric('달성', '$completion%'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryMetric(String label, String value) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ],
    );
  }

  Widget _buildSectionHeader(StatsProvider statsProvider) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('게임별 레벨', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (statsProvider.isLoading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildGameGrid(BuildContext context, StatsProvider statsProvider) {
    final statsMap = {for (final s in statsProvider.allStats) s.gameType: s};

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 620;
        final itemWidth = isWide ? (constraints.maxWidth - 12) / 2 : constraints.maxWidth;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _allGames.map((meta) {
            final stats = statsMap[meta.type];
            return SizedBox(
              width: itemWidth,
              child: _buildGameCard(meta, stats),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildGameCard(_GameMeta meta, GameStats? stats) {
    final played = stats != null && stats.totalGames > 0;
    final level = stats?.level ?? 0;
    final wins = stats?.wins ?? 0;
    final losses = stats?.losses ?? 0;
    final draws = stats?.draws ?? 0;
    final totalGames = stats?.totalGames ?? 0;
    final winRate = stats?.winRate ?? 0;
    final exp = stats?.exp ?? 0;
    final expToNext = stats?.expToNextLevel ?? 100;
    final expProgress = stats?.expProgress ?? 0.0;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: meta.color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(meta.icon, color: meta.color, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  meta.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: played ? meta.color.withValues(alpha: 0.12) : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  played ? 'Lv.$level' : '미플레이',
                  style: TextStyle(
                    color: played ? meta.color : Colors.grey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: played ? expProgress : 0,
              minHeight: 10,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(meta.color),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            played ? '$exp / $expToNext EXP' : '플레이 후 EXP 누적',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _miniStat('승', wins, Colors.green),
              _miniStat('패', losses, Colors.red),
              _miniStat('무', draws, Colors.grey),
              _miniStat('승률', played ? winRate : 0, meta.color, suffix: '%'),
              _miniStat('총', totalGames, Colors.black87),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, int value, Color color, {String suffix = ''}) {
    return Column(
      children: [
        Text(
          '$value$suffix',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
    );
  }
}

class _GameMeta {
  final String type;
  final String name;
  final IconData icon;
  final Color color;

  const _GameMeta(this.type, this.name, this.icon, this.color);
}
