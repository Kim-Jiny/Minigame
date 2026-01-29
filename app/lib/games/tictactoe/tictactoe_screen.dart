import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.grid_3x3,
            size: 100,
            color: Colors.blue,
          ),
          const SizedBox(height: 24),
          const Text(
            '틱택토',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '3개를 연속으로 놓으면 승리!',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 48),
          ElevatedButton.icon(
            onPressed: () {
              game.findMatch(AppConfig.gameTypeTicTacToe);
            },
            icon: const Icon(Icons.search),
            label: const Text('상대 찾기'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 32,
                vertical: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchingView(GameProvider game) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          const Text(
            '상대를 찾는 중...',
            style: TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 48),
          OutlinedButton(
            onPressed: () {
              game.cancelMatch(AppConfig.gameTypeTicTacToe);
            },
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  Widget _buildMatchedView(GameProvider game) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_circle,
            size: 64,
            color: Colors.green,
          ),
          const SizedBox(height: 16),
          Text(
            '${game.opponentNickname}님과 매칭!',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('게임이 곧 시작됩니다...'),
        ],
      ),
    );
  }

  Widget _buildPlayingView(GameProvider game) {
    final auth = context.read<AuthProvider>();

    return Column(
      children: [
        // 상태 표시
        Container(
          padding: const EdgeInsets.all(16),
          color: game.isMyTurn ? Colors.green.shade100 : Colors.grey.shade200,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                game.isMyTurn ? '내 차례' : '상대 차례',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: game.isMyTurn ? Colors.green : Colors.grey,
                ),
              ),
              Text(
                'vs ${game.opponentNickname}',
                style: const TextStyle(fontSize: 16),
              ),
            ],
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
    );
  }

  Widget _buildBoard(GameProvider game, String? myId) {
    // 내가 플레이어 0인지 1인지 확인
    // 서버에서 players 배열 순서로 결정됨

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
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
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.blue.shade200,
                width: 2,
              ),
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

    // 0 = X (첫 번째 플레이어), 1 = O (두 번째 플레이어)
    if (cell == 0) {
      return const Icon(
        Icons.close,
        size: 48,
        color: Colors.red,
      );
    } else {
      return const Icon(
        Icons.circle_outlined,
        size: 48,
        color: Colors.blue,
      );
    }
  }

  Widget _buildFinishedView(GameProvider game) {
    String resultText;
    Color resultColor;
    IconData resultIcon;

    if (game.isDraw) {
      resultText = '무승부!';
      resultColor = Colors.orange;
      resultIcon = Icons.handshake;
    } else if (game.isWinner) {
      resultText = '승리!';
      resultColor = Colors.green;
      resultIcon = Icons.emoji_events;
    } else {
      resultText = '패배...';
      resultColor = Colors.red;
      resultIcon = Icons.sentiment_dissatisfied;
    }

    return Column(
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
          color: resultColor.withValues(alpha: 0.1),
          child: Column(
            children: [
              Icon(resultIcon, size: 64, color: resultColor),
              const SizedBox(height: 8),
              Text(
                resultText,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: resultColor,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () {
                      game.reset();
                      game.findMatch(AppConfig.gameTypeTicTacToe);
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('다시 찾기'),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: () {
                      game.reset();
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.exit_to_app),
                    label: const Text('로비로'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
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
        title: const Text('게임 나가기'),
        content: const Text('정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              game.leaveGame();
              Navigator.pop(context); // 다이얼로그 닫기
              Navigator.pop(context); // 게임 화면 나가기
            },
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
