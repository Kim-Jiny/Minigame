import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../config/app_config.dart';

class InfiniteTicTacToeScreen extends StatefulWidget {
  const InfiniteTicTacToeScreen({super.key});

  @override
  State<InfiniteTicTacToeScreen> createState() => _InfiniteTicTacToeScreenState();
}

class _InfiniteTicTacToeScreenState extends State<InfiniteTicTacToeScreen> {
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
          title: const Text('무한 틱택토'),
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
            Icons.all_inclusive,
            size: 100,
            color: Colors.purple,
          ),
          const SizedBox(height: 24),
          const Text(
            '무한 틱택토',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '각자 3개까지! 4번째부터 가장 오래된 돌이 사라져요',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.purple.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '무승부 없음!',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.purple,
              ),
            ),
          ),
          const SizedBox(height: 48),
          ElevatedButton.icon(
            onPressed: () {
              game.findMatch(AppConfig.gameTypeInfiniteTicTacToe);
            },
            icon: const Icon(Icons.search),
            label: const Text('상대 찾기'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple,
              foregroundColor: Colors.white,
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
          const CircularProgressIndicator(color: Colors.purple),
          const SizedBox(height: 24),
          const Text(
            '상대를 찾는 중...',
            style: TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 48),
          OutlinedButton(
            onPressed: () {
              game.cancelMatch(AppConfig.gameTypeInfiniteTicTacToe);
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
    return Column(
      children: [
        // 상태 표시
        Container(
          padding: const EdgeInsets.all(16),
          color: game.isMyTurn ? Colors.purple.shade100 : Colors.grey.shade200,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                game.isMyTurn ? '내 차례' : '상대 차례',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: game.isMyTurn ? Colors.purple : Colors.grey,
                ),
              ),
              Text(
                'vs ${game.opponentNickname}',
                style: const TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),

        // 말 개수 표시
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildPieceCounter('나', game.myPieceCount, Colors.red),
              _buildPieceCounter('상대', game.opponentPieceCount, Colors.blue),
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
                child: _buildBoard(game),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPieceCounter(String label, int count, Color color) {
    return Row(
      children: [
        Text('$label: ', style: const TextStyle(fontSize: 14)),
        ...List.generate(3, (index) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Icon(
              index < count ? Icons.circle : Icons.circle_outlined,
              size: 20,
              color: index < count ? color : Colors.grey.shade300,
            ),
          );
        }),
      ],
    );
  }

  Widget _buildBoard(GameProvider game) {
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
        final isNextToDisappear = game.nextToDisappear == index;

        return GestureDetector(
          onTap: () {
            if (cell == null && game.isMyTurn) {
              game.makeMove(index);
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              color: isNextToDisappear
                  ? Colors.orange.shade100
                  : Colors.purple.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isNextToDisappear
                    ? Colors.orange
                    : Colors.purple.shade200,
                width: isNextToDisappear ? 3 : 2,
              ),
            ),
            child: Stack(
              children: [
                Center(child: _buildCellContent(cell)),
                if (isNextToDisappear)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Icon(
                      Icons.timer,
                      size: 16,
                      color: Colors.orange.shade700,
                    ),
                  ),
              ],
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
    // 무한 틱택토는 무승부 없음
    final isWinner = game.isWinner;
    final resultText = isWinner ? '승리!' : '패배...';
    final resultColor = isWinner ? Colors.green : Colors.red;
    final resultIcon = isWinner ? Icons.emoji_events : Icons.sentiment_dissatisfied;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                margin: const EdgeInsets.all(24),
                child: _buildBoard(game),
              ),
            ),
          ),
        ),

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
                      game.findMatch(AppConfig.gameTypeInfiniteTicTacToe);
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('다시 찾기'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purple,
                      foregroundColor: Colors.white,
                    ),
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
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
