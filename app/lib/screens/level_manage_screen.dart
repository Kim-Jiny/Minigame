import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stats_provider.dart';

class LevelManageScreen extends StatelessWidget {
  const LevelManageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 레벨'),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Consumer<StatsProvider>(
        builder: (context, statsProvider, child) {
          return RefreshIndicator(
            onRefresh: () async {
              statsProvider.getAllStats();
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 총 레벨 요약
                  _buildTotalLevelCard(context, statsProvider),
                  const SizedBox(height: 24),

                  // 게임별 상세
                  Text(
                    '게임별 레벨',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (statsProvider.allStats.isEmpty)
                    _buildEmptyState()
                  else
                    ...statsProvider.allStats.map((stats) =>
                      _buildGameStatsCard(context, stats)
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTotalLevelCard(BuildContext context, StatsProvider statsProvider) {
    int totalLevel = 0;
    int totalWins = 0;
    int totalLosses = 0;
    int totalGames = 0;

    for (var stats in statsProvider.allStats) {
      totalLevel += stats.level;
      totalWins += stats.wins;
      totalLosses += stats.losses;
      totalGames += stats.totalGames;
    }

    final overallWinRate = totalGames > 0 ? (totalWins / totalGames * 100).round() : 0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              Theme.of(context).primaryColor,
              Theme.of(context).primaryColor.withValues(alpha: 0.7),
            ],
          ),
        ),
        child: Column(
          children: [
            const Text(
              '통합 레벨',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              'Lv. $totalLevel',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildSummaryItem('총 게임', '$totalGames'),
                _buildSummaryItem('승리', '$totalWins'),
                _buildSummaryItem('승률', '$overallWinRate%'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            Icon(Icons.sports_esports_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              '아직 게임 기록이 없어요',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              '게임을 플레이하면 레벨이 올라요!',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGameStatsCard(BuildContext context, GameStats stats) {
    final Color gameColor = stats.gameType == 'tictactoe'
        ? const Color(0xFF6C5CE7)
        : const Color(0xFF74B9FF);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 헤더
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: gameColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    stats.gameType == 'tictactoe' ? Icons.grid_3x3 : Icons.all_inclusive,
                    color: gameColor,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stats.gameTypeName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: gameColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Lv.${stats.level}',
                          style: TextStyle(
                            color: gameColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 승률
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${stats.winRate}%',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: gameColor,
                      ),
                    ),
                    Text(
                      '승률',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 경험치 바
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '다음 레벨까지',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    Text(
                      '${stats.exp} / ${stats.expToNextLevel} EXP',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: stats.expProgress,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation<Color>(gameColor),
                    minHeight: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 전적
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(child: _buildStatColumn('승', stats.wins, Colors.green)),
                  Container(width: 1, height: 40, color: Colors.grey.shade300),
                  Expanded(child: _buildStatColumn('패', stats.losses, Colors.red)),
                  Container(width: 1, height: 40, color: Colors.grey.shade300),
                  Expanded(child: _buildStatColumn('무', stats.draws, Colors.grey)),
                  Container(width: 1, height: 40, color: Colors.grey.shade300),
                  Expanded(child: _buildStatColumn('총', stats.totalGames, gameColor)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatColumn(String label, int value, Color color) {
    return Column(
      children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}
