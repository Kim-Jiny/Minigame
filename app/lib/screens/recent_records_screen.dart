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
          return RefreshIndicator(
            onRefresh: () async {
              statsProvider.getRecentRecords();
            },
            child: statsProvider.recentRecords.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: statsProvider.recentRecords.length,
                    itemBuilder: (context, index) {
                      return _buildRecordCard(context, statsProvider.recentRecords[index]);
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
