import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stats_provider.dart';
import '../theme/candy_theme.dart';
import '../utils/game_registry.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

class RecentRecordsScreen extends StatefulWidget {
  const RecentRecordsScreen({super.key});

  @override
  State<RecentRecordsScreen> createState() => _RecentRecordsScreenState();
}

class _RecentRecordsScreenState extends State<RecentRecordsScreen> {
  @override
  void initState() {
    super.initState();
    // 화면 열릴 때 데이터 새로고침
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<StatsProvider>().getRecentRecords();
    });
  }

  // 기록을 그룹화 (랭크 매치는 묶음)
  List<dynamic> _groupRecords(List<GameRecord> records) {
    final List<dynamic> grouped = [];
    final Map<String, List<GameRecord>> rankedMatches = {};

    for (final record in records) {
      if (record.isRanked && record.rankedMatchId != null) {
        // 랭크전은 매치 ID로 그룹화
        rankedMatches.putIfAbsent(record.rankedMatchId!, () => []);
        rankedMatches[record.rankedMatchId!]!.add(record);
      } else {
        // 일반 게임은 그대로
        grouped.add(record);
      }
    }

    // 랭크 매치 그룹을 리스트에 추가 (시간순 정렬을 위해)
    for (final entry in rankedMatches.entries) {
      // 게임 인덱스 순으로 정렬
      entry.value.sort(
        (a, b) => (a.rankedGameIndex ?? 0).compareTo(b.rankedGameIndex ?? 0),
      );
      grouped.add(
        _RankedMatchGroup(
          matchId: entry.key,
          games: entry.value,
          createdAt: entry.value.first.createdAt,
        ),
      );
    }

    // 시간순 정렬 (최신 먼저)
    grouped.sort((a, b) {
      final aTime = a is GameRecord
          ? a.createdAt
          : (a as _RankedMatchGroup).createdAt;
      final bTime = b is GameRecord
          ? b.createdAt
          : (b as _RankedMatchGroup).createdAt;
      return bTime.compareTo(aTime);
    });

    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('최근 기록')),
      body: FloatingBackground(
        child: Consumer<StatsProvider>(
          builder: (context, statsProvider, child) {
            final groupedRecords = _groupRecords(statsProvider.recentRecords);

            return RefreshIndicator(
              color: CandyColors.pink,
              onRefresh: () async {
                statsProvider.getRecentRecords();
              },
              child: groupedRecords.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      itemCount: groupedRecords.length,
                      itemBuilder: (context, index) {
                        final item = groupedRecords[index];
                        final Widget card = item is _RankedMatchGroup
                            ? _buildRankedMatchCard(context, item)
                            : _buildRecordCard(context, item as GameRecord);
                        return PopIn(
                          delay: Duration(
                            milliseconds: math.min(index, 8) * 50,
                          ),
                          child: card,
                        );
                      },
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: const Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                DuoMascot(size: 110, mood: MascotMood.sad),
                SizedBox(height: 16),
                Text(
                  '아직 기록이 없어요',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '게임을 플레이하면 기록이 쌓여요!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: CandyColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _resultColor(String result) {
    switch (result) {
      case 'win':
        return CandyColors.mint;
      case 'loss':
        return CandyColors.pink;
      default:
        return const Color(0xFFB9B3C9);
    }
  }

  Widget _pill(String text, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CandyColors.ink, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 랭크 매치 그룹 카드
  Widget _buildRankedMatchCard(BuildContext context, _RankedMatchGroup match) {
    int wins = match.games.where((g) => g.result == 'win').length;
    int losses = match.games.where((g) => g.result == 'loss').length;
    final isOverallWin = wins > losses;
    final isDraw = wins == losses;

    Color resultColor;
    String resultText;
    if (isDraw) {
      resultColor = const Color(0xFFB9B3C9);
      resultText = '무승부';
    } else if (isOverallWin) {
      resultColor = CandyColors.mint;
      resultText = '승리';
    } else {
      resultColor = CandyColors.pink;
      resultText = '패배';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: CartoonCard(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(CandyTheme.radius - 3),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: const BoxDecoration(
                  color: CandyColors.grape,
                  border: Border(
                    bottom: BorderSide(
                      color: CandyColors.ink,
                      width: CandyTheme.outline,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: CandyColors.ink, width: 2),
                      ),
                      child: const Icon(
                        Icons.emoji_events,
                        color: CandyColors.grapeDeep,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '랭크전',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            'vs ${match.games.first.opponentNickname}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _pill('$resultText ($wins-$losses)', resultColor),
                          const SizedBox(height: 4),
                          Text(
                            _formatDateTime(match.createdAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: match.games.asMap().entries.map((entry) {
                    final index = entry.key;
                    final game = entry.value;
                    return _buildRankedGameItem(
                      game,
                      index + 1,
                      index == match.games.length - 1,
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRankedGameItem(GameRecord game, int gameNum, bool isLast) {
    final resultColor = _resultColor(game.result);
    final gameColor = GameRegistry.colorOf(game.gameType);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: CandyColors.creamDeep, width: 2),
              ),
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: resultColor,
              shape: BoxShape.circle,
              border: Border.all(color: CandyColors.ink, width: 2),
            ),
            alignment: Alignment.center,
            child: Text(
              '$gameNum',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Icon(GameRegistry.iconOf(game.gameType), color: gameColor, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              game.gameTypeName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: CandyColors.ink,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _pill(game.resultText, resultColor),
        ],
      ),
    );
  }

  Widget _buildRecordCard(BuildContext context, GameRecord record) {
    IconData resultIcon;
    switch (record.result) {
      case 'win':
        resultIcon = Icons.emoji_events;
        break;
      case 'loss':
        resultIcon = Icons.sentiment_dissatisfied;
        break;
      default:
        resultIcon = Icons.handshake;
    }
    final resultColor = _resultColor(record.result);
    final gameColor = GameRegistry.colorOf(record.gameType);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: CartoonCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: gameColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: CandyColors.ink, width: 2),
              ),
              child: Icon(
                GameRegistry.iconOf(record.gameType),
                color: gameColor,
                size: 28,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.gameTypeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'vs ${record.opponentNickname}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      color: CandyColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatDateTime(record.createdAt),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _pill(record.resultText, resultColor, icon: resultIcon),
                  const SizedBox(height: 8),
                  Text(
                    '+${record.expGained} EXP',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CandyColors.sunDeep,
                      fontWeight: FontWeight.w900,
                      fontSize: 13,
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

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return '방금 전';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}분 전';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}시간 전';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}일 전';
    } else {
      return '${dateTime.year}.${dateTime.month}.${dateTime.day}';
    }
  }
}

// 랭크 매치 그룹 클래스
class _RankedMatchGroup {
  final String matchId;
  final List<GameRecord> games;
  final DateTime createdAt;

  _RankedMatchGroup({
    required this.matchId,
    required this.games,
    required this.createdAt,
  });
}
