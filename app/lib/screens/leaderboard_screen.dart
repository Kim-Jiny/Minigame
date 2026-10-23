import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ranked_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/candy_theme.dart';
import '../widgets/tier_badge.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

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
      ranked.ensureSocketListeners();
      ranked.getLeaderboard();
      ranked.getMyRank();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('리더보드')),
      body: FloatingBackground(
        child: Consumer2<RankedProvider, AuthProvider>(
          builder: (context, ranked, auth, child) {
            if (ranked.isLoading && ranked.leaderboard.isEmpty) {
              return const Center(
                child: CircularProgressIndicator(color: CandyColors.pink),
              );
            }

            return Column(
              children: [
                if (auth.userId != null && ranked.myRank != null)
                  _buildMyRankCard(ranked, auth),
                Expanded(
                  child: ranked.leaderboard.isEmpty
                      ? _buildEmptyState()
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: ranked.leaderboard.length,
                          itemBuilder: (context, index) {
                            final entry = ranked.leaderboard[index];
                            final isMe = entry.userId == auth.userId;
                            return PopIn(
                              delay: Duration(
                                milliseconds: math.min(index, 8) * 50,
                              ),
                              child: _buildLeaderboardItem(entry, isMe),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMyRankCard(RankedProvider ranked, AuthProvider auth) {
    final stats = ranked.stats;
    if (stats == null) return const SizedBox();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: PopIn(
        child: CartoonCard(
          color: CandyColors.sun,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: CandyColors.ink,
                    width: CandyTheme.outline,
                  ),
                ),
                alignment: Alignment.center,
                child: FittedBox(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      '${ranked.myRank}',
                      style: const TextStyle(
                        color: CandyColors.ink,
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '나의 순위',
                      style: TextStyle(
                        color: CandyColors.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      auth.nickname ?? '나',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: CandyColors.ink,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TierBadge(
                tier: stats.tier,
                tierColor: stats.tierColor,
                elo: stats.elo,
                size: 0.8,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeaderboardItem(LeaderboardEntry entry, bool isMe) {
    final good = entry.winRate >= 50;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: CartoonCard(
        color: isMe ? const Color(0xFFFFE3EE) : Colors.white,
        shadow: 4,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _buildRankBadge(entry.rank),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: CandyColors.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      TierBadgeSmall(
                        tier: entry.tier,
                        tierColor: entry.tierColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${entry.elo} LP | ${entry.wins}승 ${entry.losses}패',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CandyColors.inkSoft,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: good ? CandyColors.mint : CandyColors.pink,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: CandyColors.ink, width: 2),
              ),
              child: Text(
                '${entry.winRate}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRankBadge(int rank) {
    Color bgColor;
    switch (rank) {
      case 1:
        bgColor = CandyColors.sun;
        break;
      case 2:
        bgColor = const Color(0xFFC9D3E3);
        break;
      case 3:
        bgColor = CandyColors.tangerine;
        break;
      default:
        bgColor = CandyColors.cream;
    }

    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        border: Border.all(color: CandyColors.ink, width: 2.5),
      ),
      alignment: Alignment.center,
      child: rank <= 3
          ? const Icon(Icons.emoji_events, color: CandyColors.ink, size: 22)
          : FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                  '$rank',
                  style: const TextStyle(
                    color: CandyColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            DuoMascot(size: 110, mood: MascotMood.sad),
            SizedBox(height: 16),
            Text(
              '아직 랭킹이 텅 비었어요',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: CandyColors.ink,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            SizedBox(height: 6),
            Text(
              '랭크전에 참여하고 1등을 차지해 보세요!',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: CandyColors.inkSoft,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
