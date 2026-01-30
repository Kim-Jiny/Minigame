import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../config/app_config.dart';

class TicTacToeScreen extends StatefulWidget {
  const TicTacToeScreen({super.key});

  @override
  State<TicTacToeScreen> createState() => _TicTacToeScreenState();
}

class _TicTacToeScreenState extends State<TicTacToeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      final game = context.read<GameProvider>();

      if (auth.socketId != null) {
        game.initialize(auth.socketId!);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitDialog(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('틱택토'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _showExitDialog(context),
          ),
        ),
        body: Consumer<GameProvider>(
          builder: (context, game, child) {
            return switch (game.status) {
              GameStatus.idle => _buildIdleView(game),
              GameStatus.searching => _buildSearchingView(game),
              GameStatus.matched => _buildMatchedView(game),
              GameStatus.playing => _buildPlayingView(game),
              GameStatus.finished => _buildFinishedView(game),
            };
          },
        ),
      ),
    );
  }

  Widget _buildIdleView(GameProvider game) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF6C5CE7).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 하트 아이콘
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF6C5CE7).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.grid_3x3,
                size: 80,
                color: Color(0xFF6C5CE7),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '틱택토',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Color(0xFF6C5CE7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '3개를 연속으로 놓으면 승리!',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 32),
            // 하드코어 모드 토글
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: game.isHardcore ? Colors.red.shade50 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: game.isHardcore ? Colors.red : Colors.grey.shade300,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.local_fire_department,
                    color: game.isHardcore ? Colors.red : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '하드코어',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: game.isHardcore ? Colors.red : Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '(10초)',
                    style: TextStyle(
                      fontSize: 12,
                      color: game.isHardcore ? Colors.red.shade400 : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: game.isHardcore,
                    onChanged: (value) => game.setHardcoreMode(value),
                    activeColor: Colors.red,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                game.findMatch(AppConfig.gameTypeTicTacToe);
              },
              icon: const Icon(Icons.search),
              label: Text(game.isHardcore ? '하드코어 상대 찾기' : '상대 찾기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: game.isHardcore ? Colors.red : const Color(0xFF6C5CE7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchingView(GameProvider game) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF6C5CE7).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                color: Color(0xFF6C5CE7),
                strokeWidth: 4,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              game.isHardcore ? '하드코어 상대를 찾는 중...' : '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 18,
                color: game.isHardcore ? Colors.red.shade700 : Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 8),
            if (game.isHardcore)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_fire_department, size: 16, color: Colors.red),
                    const SizedBox(width: 4),
                    Text(
                      '하드코어 모드 (10초)',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.red.shade700,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.auto_awesome, size: 16, color: const Color(0xFFFDCB6E)),
                  const SizedBox(width: 4),
                  Text(
                    '상대를 기다리는 중',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade500,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.auto_awesome, size: 16, color: const Color(0xFFFDCB6E)),
                ],
              ),
            const SizedBox(height: 48),
            OutlinedButton(
              onPressed: () {
                game.cancelMatch(AppConfig.gameTypeTicTacToe);
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF6C5CE7),
                side: const BorderSide(color: Color(0xFF6C5CE7)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              child: const Text('취소'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMatchedView(GameProvider game) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF6C5CE7).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFFE8E0FF),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.sports_esports,
                size: 64,
                color: Color(0xFF6C5CE7),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${game.opponentNickname}님과 매칭!',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF6C5CE7),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '게임이 곧 시작됩니다...',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayingView(GameProvider game) {
    final auth = context.read<AuthProvider>();

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF6C5CE7).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Column(
        children: [
          // 상태 표시
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: game.isMyTurn
                  ? const Color(0xFFE8E0FF)
                  : Colors.grey.shade100,
              border: Border(
                bottom: BorderSide(
                  color: game.isMyTurn
                      ? const Color(0xFF6C5CE7)
                      : Colors.grey.shade300,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      game.isMyTurn ? Icons.sports_esports : Icons.sports_esports_outlined,
                      color: game.isMyTurn
                          ? const Color(0xFF6C5CE7)
                          : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      game.isMyTurn ? '내 차례' : '상대 차례',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: game.isMyTurn
                            ? const Color(0xFF6C5CE7)
                            : Colors.grey,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    // 타이머 표시
                    _buildTimer(game),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'vs ${game.opponentNickname}',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 타임아웃 알림
          if (game.timeoutPlayerNickname != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: Colors.orange.shade100,
              child: Text(
                '${game.timeoutPlayerNickname}님 시간 초과! 랜덤 위치에 배치됨',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.orange.shade800,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),

          // 게임 보드
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  margin: const EdgeInsets.all(24),
                  child: _buildBoard(game, auth.socketId),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimer(GameProvider game) {
    final remaining = game.remainingTime;
    final isLow = remaining <= 10;
    final isCritical = remaining <= 5;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isCritical
            ? Colors.red.shade100
            : isLow
                ? Colors.orange.shade100
                : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isCritical
              ? Colors.red
              : isLow
                  ? Colors.orange
                  : Colors.grey.shade300,
          width: isCritical ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer,
            size: 18,
            color: isCritical
                ? Colors.red
                : isLow
                    ? Colors.orange
                    : Colors.grey.shade600,
          ),
          const SizedBox(width: 4),
          Text(
            '${remaining}초',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isCritical
                  ? Colors.red
                  : isLow
                      ? Colors.orange
                      : Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBoard(GameProvider game, String? myId) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: 9,
      itemBuilder: (context, index) {
        final cell = game.board[index];

        return GestureDetector(
          onTap: () {
            if (cell == null && game.isMyTurn) {
              game.makeMove(index);
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF74B9FF),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF6C5CE7).withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: _buildCellContent(cell),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCellContent(int? cell) {
    if (cell == null) {
      return const SizedBox.shrink();
    }

    // 0 = 동그라미 (첫 번째 플레이어), 1 = 세모 (두 번째 플레이어)
    if (cell == 0) {
      return const Icon(
        Icons.circle_outlined,
        size: 48,
        color: Color(0xFF6C5CE7),
      );
    } else {
      return const Icon(
        Icons.change_history,
        size: 48,
        color: Color(0xFF00CEC9),
      );
    }
  }

  Widget _buildFinishedView(GameProvider game) {
    debugPrint('🎮 _buildFinishedView - isInvitationGame: ${game.isInvitationGame}');

    String resultText;
    Color resultColor;
    IconData resultIcon;

    if (game.isDraw) {
      resultText = '무승부!';
      resultColor = Colors.orange;
      resultIcon = Icons.handshake;
    } else if (game.isWinner) {
      resultText = '승리!';
      resultColor = const Color(0xFF6C5CE7);
      resultIcon = Icons.emoji_events;
    } else {
      resultText = '아쉬워요...';
      resultColor = Colors.grey;
      resultIcon = Icons.sentiment_dissatisfied;
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            resultColor.withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Column(
        children: [
          // 최종 보드 상태
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  margin: const EdgeInsets.all(24),
                  child: _buildBoard(game, null),
                ),
              ),
            ),
          ),

          // 결과
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: resultColor.withValues(alpha: 0.1),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: resultColor.withValues(alpha: 0.3),
                        blurRadius: 20,
                      ),
                    ],
                  ),
                  child: Icon(resultIcon, size: 48, color: resultColor),
                ),
                const SizedBox(height: 16),
                Text(
                  resultText,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: resultColor,
                  ),
                ),
                // 상대가 나갔을 때 표시
                if (game.opponentLeft)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.exit_to_app, size: 16, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Text(
                          '상대방이 나갔습니다',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                // 상대방 재경기 요청 표시
                if (game.opponentWantsRematch && !game.opponentLeft)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.hourglass_top, size: 16, color: Colors.green.shade700),
                        const SizedBox(width: 8),
                        Text(
                          '${game.opponentNickname}님이 대기 중...',
                          style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // 재경기 버튼 (상대가 나가지 않았을 때만 표시)
                    if (!game.opponentLeft)
                      ElevatedButton.icon(
                        onPressed: game.rematchWaiting
                            ? () => game.cancelRematch()
                            : () => game.requestRematch(),
                        icon: Icon(game.rematchWaiting ? Icons.hourglass_top : Icons.replay),
                        label: Text(game.rematchWaiting ? '대기 중...' : '재경기'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: game.rematchWaiting
                              ? Colors.orange
                              : const Color(0xFF6C5CE7),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                      ),
                    // 다시 찾기 버튼 (친구 초대 게임이 아닐 때만)
                    if (!game.isInvitationGame)
                      OutlinedButton.icon(
                        onPressed: () {
                          game.leaveGame();
                          game.findMatch(AppConfig.gameTypeTicTacToe);
                        },
                        icon: const Icon(Icons.search),
                        label: const Text('다시 찾기'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF6C5CE7),
                          side: const BorderSide(color: Color(0xFF6C5CE7)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                      ),
                    // 친구 요청 버튼 (랜덤 매칭이고 상대가 나가지 않았을 때)
                    if (!game.isInvitationGame && !game.opponentLeft && game.opponentUserId != null)
                      OutlinedButton.icon(
                        onPressed: () {
                          context.read<FriendProvider>().sendFriendRequestByUserId(game.opponentUserId!);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${game.opponentNickname}님에게 친구 요청을 보냈습니다'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.person_add),
                        label: const Text('친구 요청'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.green,
                          side: const BorderSide(color: Colors.green),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                      ),
                    // 로비로 버튼
                    OutlinedButton.icon(
                      onPressed: () {
                        game.leaveGame();
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.home),
                      label: const Text('로비'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey,
                        side: BorderSide(color: Colors.grey.shade400),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showExitDialog(BuildContext context) {
    final game = context.read<GameProvider>();

    if (game.status == GameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.exit_to_app, color: Color(0xFF6C5CE7)),
            SizedBox(width: 8),
            Text('게임 나가기'),
          ],
        ),
        content: const Text('정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              game.leaveGame();
              Navigator.pop(context);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C5CE7),
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
