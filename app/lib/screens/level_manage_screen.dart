import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stats_provider.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

class LevelManageScreen extends StatelessWidget {
  const LevelManageScreen({super.key});

  static const List<_GameMeta> _allGames = [
    _GameMeta('tictactoe', '틱택토', Icons.grid_3x3, Color(0xFFFF6B9D)),
    _GameMeta(
      'infinite_tictactoe',
      '무한 틱택토',
      Icons.all_inclusive,
      Color(0xFF74B9FF),
    ),
    _GameMeta('gomoku', '오목', Icons.circle_outlined, Color(0xFF2D3436)),
    _GameMeta('reaction', '반응속도', Icons.flash_on, Color(0xFFE17055)),
    _GameMeta('rps', '가위바위보', Icons.front_hand, Color(0xFF9B59B6)),
    _GameMeta('speedtap', '스피드탭', Icons.touch_app, Color(0xFF16A085)),
    _GameMeta('sequence', '순서 기억', Icons.memory, Color(0xFF00B894)),
    _GameMeta('stroop', '스트룹', Icons.palette, Color(0xFFE84393)),
    _GameMeta('hexagon', '헥사곤', Icons.hexagon_outlined, Color(0xFFF39C12)),
    _GameMeta('pyramid', '수식피라미드', Icons.change_history, Color(0xFFE67E22)),
    _GameMeta('hunmin', '훈민정음', Icons.translate, Color(0xFF1E88E5)),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('내 레벨')),
      body: FloatingBackground(
        child: Consumer<StatsProvider>(
          builder: (context, statsProvider, _) {
            return RefreshIndicator(
              color: CandyColors.pink,
              onRefresh: () async => statsProvider.getAllStats(),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final maxContentWidth = width >= 1300
                      ? 1120.0
                      : double.infinity;
                  final horizontalPadding = width >= 900 ? 24.0 : 16.0;

                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxContentWidth),
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          16,
                          horizontalPadding,
                          24,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            PopIn(
                              child: _buildSummaryCard(context, statsProvider),
                            ),
                            const SizedBox(height: 22),
                            _buildSectionHeader(statsProvider),
                            const SizedBox(height: 12),
                            _buildGameGrid(context, statsProvider),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
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

    return CartoonCard(
      color: CandyColors.grape,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '통합 진행도',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              'Lv. $totalLevel',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 38,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: CandyColors.ink, width: 2.5),
            ),
            child: Row(
              children: [
                _summaryMetric('플레이', '$playedGames/${_allGames.length}'),
                _summaryMetric('총 게임', '$totalGames'),
                _summaryMetric('승률', '$winRate%'),
                _summaryMetric('달성', '$completion%'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryMetric(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(
                color: CandyColors.ink,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: CandyColors.inkSoft,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(StatsProvider statsProvider) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          '게임별 레벨',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: CandyColors.ink,
          ),
        ),
        if (statsProvider.isLoading)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: CandyColors.pink,
            ),
          ),
      ],
    );
  }

  Widget _buildGameGrid(BuildContext context, StatsProvider statsProvider) {
    final statsMap = {for (final s in statsProvider.allStats) s.gameType: s};

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1180
            ? 4
            : width >= 860
            ? 3
            : width >= 560
            ? 2
            : 1;
        final itemWidth = (width - (columns - 1) * 14) / columns;

        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (int i = 0; i < _allGames.length; i++)
              SizedBox(
                width: itemWidth,
                child: PopIn(
                  delay: Duration(milliseconds: math.min(i, 8) * 50),
                  child: _buildGameCard(
                    _allGames[i],
                    statsMap[_allGames[i].type],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildGameCard(_GameMeta meta, GameStats? stats) {
    final played =
        stats != null &&
        (stats.totalGames > 0 || stats.level > 1 || stats.exp > 0);
    final level = stats?.level ?? 0;
    final wins = stats?.wins ?? 0;
    final losses = stats?.losses ?? 0;
    final draws = stats?.draws ?? 0;
    final totalGames = stats?.totalGames ?? 0;
    final winRate = stats?.winRate ?? 0;
    final exp = stats?.exp ?? 0;
    final expToNext = stats?.expToNextLevel ?? 100;
    final expProgress = (stats?.expProgress ?? 0.0).clamp(0.0, 1.0);

    return CartoonCard(
      shadow: 4,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: meta.color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: CandyColors.ink, width: 2),
                ),
                child: Icon(meta.icon, color: meta.color, size: 24),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  meta.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: played ? CandyColors.sun : CandyColors.cream,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: CandyColors.ink, width: 2),
                ),
                child: Text(
                  played ? 'Lv.$level' : '미플레이',
                  style: const TextStyle(
                    color: CandyColors.ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 14,
            decoration: BoxDecoration(
              color: CandyColors.cream,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: CandyColors.ink, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: played ? expProgress : 0,
                  heightFactor: 1,
                  child: ColoredBox(color: meta.color),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            played ? '$exp / $expToNext EXP' : '플레이 후 EXP 누적',
            style: const TextStyle(
              color: CandyColors.inkSoft,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _miniStat('승', wins, CandyColors.mintDeep),
              _miniStat('패', losses, CandyColors.pinkDeep),
              _miniStat('무', draws, CandyColors.inkSoft),
              _miniStat(
                '승률',
                played ? winRate : 0,
                CandyColors.skyDeep,
                suffix: '%',
              ),
              _miniStat('총', totalGames, CandyColors.ink),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, int value, Color color, {String suffix = ''}) {
    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$value$suffix',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: CandyColors.inkSoft,
            ),
          ),
        ],
      ),
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
