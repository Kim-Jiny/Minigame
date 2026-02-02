import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ranked_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/tier_badge.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ranked = context.read<RankedProvider>();
      ranked.getLeaderboard();
      ranked.getMyRank();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('리더보드'),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Consumer2<RankedProvider, AuthProvider>(
        builder: (context, ranked, auth, child) {
          if (ranked.isLoading && ranked.leaderboard.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          return Column(
            children: [
              // 내 순위 (고정)
              if (auth.userId != null && ranked.myRank != null)
                _buildMyRankCard(ranked, auth),

              // 리더보드 목록
              Expanded(
                child: ranked.leaderboard.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: ranked.leaderboard.length,
                        itemBuilder: (context, index) {
                          final entry = ranked.leaderboard[index];
                          final isMe = entry.userId == auth.userId;
                          return _buildLeaderboardItem(entry, isMe);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMyRankCard(RankedProvider ranked, AuthProvider auth) {
    final stats = ranked.stats;
    if (stats == null) return const SizedBox();

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).primaryColor,
            Theme.of(context).primaryColor.withValues(alpha: 0.8),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).primaryColor.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // 순위
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '${ranked.myRank}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),

          // 정보
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '나의 순위',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
                Text(
                  auth.nickname ?? '나',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),

          // 티어 뱃지
          TierBadge(
            tier: stats.tier,
            tierColor: stats.tierColor,
            elo: stats.elo,
            size: 0.8,
          ),
        ],
      ),
    );
  }

  Widget _buildLeaderboardItem(LeaderboardEntry entry, bool isMe) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isMe
            ? Theme.of(context).primaryColor.withValues(alpha: 0.1)
            : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: isMe
            ? Border.all(color: Theme.of(context).primaryColor, width: 2)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: _buildRankBadge(entry.rank),
        title: Row(
          children: [
            Expanded(
              child: Text(
                entry.nickname,
                style: TextStyle(
                  fontWeight: isMe ? FontWeight.bold : FontWeight.w600,
                ),
              ),
            ),
            TierBadgeSmall(
              tier: entry.tier,
              tierColor: entry.tierColor,
            ),
          ],
        ),
        subtitle: Text(
          '${entry.elo} LP | ${entry.wins}승 ${entry.losses}패',
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 12,
          ),
        ),
        trailing: Text(
          '${entry.winRate}%',
          style: TextStyle(
            color: entry.winRate >= 50 ? Colors.green : Colors.red,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildRankBadge(int rank) {
    Color bgColor;
    Color textColor;
    IconData? icon;

    switch (rank) {
      case 1:
        bgColor = const Color(0xFFFFD700);
        textColor = Colors.white;
        icon = Icons.emoji_events;
        break;
      case 2:
        bgColor = const Color(0xFFC0C0C0);
        textColor = Colors.white;
        icon = Icons.emoji_events;
        break;
      case 3:
        bgColor = const Color(0xFFCD7F32);
        textColor = Colors.white;
        icon = Icons.emoji_events;
        break;
      default:
        bgColor = Colors.grey.shade200;
        textColor = Colors.grey.shade700;
        icon = null;
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: icon != null
            ? Icon(icon, color: textColor, size: 20)
            : Text(
                '$rank',
                style: TextStyle(
                  color: textColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.leaderboard_outlined,
            size: 64,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          Text(
            '아직 랭킹 데이터가 없습니다',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '랭크전에 참여해보세요!',
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
