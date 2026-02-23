import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stats_provider.dart';

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
      entry.value.sort((a, b) => (a.rankedGameIndex ?? 0).compareTo(b.rankedGameIndex ?? 0));
      grouped.add(_RankedMatchGroup(
        matchId: entry.key,
        games: entry.value,
        createdAt: entry.value.first.createdAt,
      ));
    }

    // 시간순 정렬 (최신 먼저)
    grouped.sort((a, b) {
      final aTime = a is GameRecord ? a.createdAt : (a as _RankedMatchGroup).createdAt;
      final bTime = b is GameRecord ? b.createdAt : (b as _RankedMatchGroup).createdAt;
      return bTime.compareTo(aTime);
    });

    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('최근 기록'),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Consumer<StatsProvider>(
        builder: (context, statsProvider, child) {
          final groupedRecords = _groupRecords(statsProvider.recentRecords);

          return RefreshIndicator(
            onRefresh: () async {
              statsProvider.getRecentRecords();
            },
            child: groupedRecords.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: groupedRecords.length,
                    itemBuilder: (context, index) {
                      final item = groupedRecords[index];
                      if (item is _RankedMatchGroup) {
                        return _buildRankedMatchCard(context, item);
                      } else {
                        return _buildRecordCard(context, item as GameRecord);
                      }
                    },
                  ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_outlined, size: 80, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            '아직 기록이 없어요',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '게임을 플레이하면 기록이 쌓여요!',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade400,
            ),
          ),
        ],
      ),
    );
  }

  // 랭크 매치 그룹 카드
  Widget _buildRankedMatchCard(BuildContext context, _RankedMatchGroup match) {
    // 전체 승패 계산
    int wins = match.games.where((g) => g.result == 'win').length;
    int losses = match.games.where((g) => g.result == 'loss').length;
    final isOverallWin = wins > losses;
    final isDraw = wins == losses;

    Color resultColor;
    String resultText;
    if (isDraw) {
      resultColor = Colors.grey;
      resultText = '무승부';
    } else if (isOverallWin) {
      resultColor = Colors.green;
      resultText = '승리';
    } else {
      resultColor = Colors.red;
      resultText = '패배';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border(
            left: BorderSide(color: Colors.purple, width: 4),
          ),
        ),
        child: Column(
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.1),
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.purple.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.emoji_events,
                      color: Colors.purple,
                      size: 24,
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
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: Colors.purple,
                          ),
                        ),
                        Text(
                          'vs ${match.games.first.opponentNickname}',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: resultColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '$resultText ($wins-$losses)',
                          style: TextStyle(
                            color: resultColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatDateTime(match.createdAt),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // 개별 게임 목록
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: match.games.asMap().entries.map((entry) {
                  final index = entry.key;
                  final game = entry.value;
                  return _buildRankedGameItem(game, index + 1, index == match.games.length - 1);
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRankedGameItem(GameRecord game, int gameNum, bool isLast) {
    final isWin = game.result == 'win';
    final isDraw = game.result == 'draw';
    final resultColor = isDraw ? Colors.grey : (isWin ? Colors.green : Colors.red);

    final gameColor = switch (game.gameType) {
      'tictactoe' => const Color(0xFF6C5CE7),
      'infinite_tictactoe' => const Color(0xFF74B9FF),
      'gomoku' => const Color(0xFF2D3436),
      'reaction' => const Color(0xFFE17055),
      'rps' => const Color(0xFF9B59B6),
      'speedtap' => const Color(0xFF00CEC9),
      'sequence' => const Color(0xFFE056FD),
      'stroop' => const Color(0xFF00CEC9),
      'hexagon' => const Color(0xFF0984E3),
      'pyramid' => const Color(0xFFE67E22),
      _ => const Color(0xFF74B9FF),
    };

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          // 게임 번호
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: resultColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$gameNum',
                style: TextStyle(
                  color: resultColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 게임 아이콘
          Icon(
            switch (game.gameType) {
              'tictactoe' => Icons.grid_3x3,
              'infinite_tictactoe' => Icons.all_inclusive,
              'gomoku' => Icons.circle_outlined,
              'reaction' => Icons.flash_on,
              'rps' => Icons.front_hand,
              'speedtap' => Icons.touch_app,
              'sequence' => Icons.psychology,
              'stroop' => Icons.palette,
              'hexagon' => Icons.hexagon,
              'pyramid' => Icons.change_history,
              _ => Icons.sports_esports,
            },
            color: gameColor,
            size: 20,
          ),
          const SizedBox(width: 8),
          // 게임 이름
          Expanded(
            child: Text(
              game.gameTypeName,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          // 결과
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: resultColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              game.resultText,
              style: TextStyle(
                color: resultColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(BuildContext context, GameRecord record) {
    Color resultColor;
    IconData resultIcon;
    Color resultBgColor;

    switch (record.result) {
      case 'win':
        resultColor = Colors.green;
        resultIcon = Icons.emoji_events;
        resultBgColor = Colors.green.shade50;
        break;
      case 'loss':
        resultColor = Colors.red;
        resultIcon = Icons.sentiment_dissatisfied;
        resultBgColor = Colors.red.shade50;
        break;
      default:
        resultColor = Colors.grey;
        resultIcon = Icons.handshake;
        resultBgColor = Colors.grey.shade100;
    }

    final gameColor = switch (record.gameType) {
      'tictactoe' => const Color(0xFF6C5CE7),
      'infinite_tictactoe' => const Color(0xFF74B9FF),
      'gomoku' => const Color(0xFF2D3436),
      'reaction' => const Color(0xFFE17055),
      'rps' => const Color(0xFF9B59B6),
      'speedtap' => const Color(0xFF00CEC9),
      'sequence' => const Color(0xFFE056FD),
      'stroop' => const Color(0xFF00CEC9),
      'hexagon' => const Color(0xFF0984E3),
      'pyramid' => const Color(0xFFE67E22),
      _ => const Color(0xFF74B9FF),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border(
            left: BorderSide(color: resultColor, width: 4),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 게임 아이콘
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: gameColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  switch (record.gameType) {
                    'tictactoe' => Icons.grid_3x3,
                    'infinite_tictactoe' => Icons.all_inclusive,
                    'gomoku' => Icons.circle_outlined,
                    'reaction' => Icons.flash_on,
                    'rps' => Icons.front_hand,
                    'speedtap' => Icons.touch_app,
                    'sequence' => Icons.psychology,
                    'stroop' => Icons.palette,
                    _ => Icons.sports_esports,
                  },
                  color: gameColor,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),

              // 정보
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.gameTypeName,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'vs ${record.opponentNickname}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDateTime(record.createdAt),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),

              // 결과
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: resultBgColor,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(resultIcon, color: resultColor, size: 18),
                        const SizedBox(width: 4),
                        Text(
                          record.resultText,
                          style: TextStyle(
                            color: resultColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 14, color: Colors.amber.shade700),
                      Text(
                        '${record.expGained} EXP',
                        style: TextStyle(
                          color: Colors.amber.shade700,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
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
