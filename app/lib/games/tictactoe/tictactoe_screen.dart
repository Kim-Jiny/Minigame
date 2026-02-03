import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../config/app_config.dart';
import '../../widgets/game_player_profile.dart';
import '../../utils/game_theme.dart';

class TicTacToeScreen extends StatefulWidget {
  final bool isRanked;

  const TicTacToeScreen({super.key, this.isRanked = false});

  @override
  State<TicTacToeScreen> createState() => _TicTacToeScreenState();
}

class _TicTacToeScreenState extends State<TicTacToeScreen> {
  bool _hasScheduledPop = false;  // 중복 pop 방지

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final auth = context.read<AuthProvider>();
      final game = context.read<GameProvider>();

      // 일반 게임 진입 시 이전 게임 상태 리셋
      if (!widget.isRanked) {
        game.reset();
      }

      if (auth.socketId != null) {
        game.initialize(auth.socketId!);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<GameProvider, ShopProvider>(
      builder: (context, game, shop, child) {
        final theme = GameTheme.fromProfileSettings(shop.profileSettings);
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _showExitDialog(context);
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('틱택토'),
              backgroundColor: theme.primary,
              foregroundColor: Colors.white,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _showExitDialog(context),
              ),
            ),
            body: switch (game.status) {
              GameStatus.idle => widget.isRanked ? _buildRankedWaitingView(theme) : _buildIdleView(game, theme),
              GameStatus.searching => widget.isRanked ? _buildRankedWaitingView(theme) : _buildSearchingView(game, theme),
              GameStatus.matched => widget.isRanked ? _buildRankedWaitingView(theme) : _buildMatchedView(game, theme),
              GameStatus.playing => _buildPlayingView(game, theme),
              GameStatus.finished => _buildFinishedView(game, theme),
            },
          ),
        );
      },
    );
  }

  String _getMatchButtonLabel(GameProvider game) {
    if (game.isInfiniteMode && game.isHardcore) {
      return '무한 하드코어 상대 찾기';
    } else if (game.isInfiniteMode) {
      return '무한모드 상대 찾기';
    } else if (game.isHardcore) {
      return '하드코어 상대 찾기';
    }
    return '상대 찾기';
  }

  Widget _buildPieceCounter(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: index < count ? color : Colors.grey.shade300,
                border: Border.all(
                  color: index < count ? color : Colors.grey.shade400,
                  width: 2,
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildIdleView(GameProvider game, GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 하트 아이콘
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.grid_3x3,
                size: 80,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              game.isInfiniteMode ? '무한 틱택토' : '틱택토',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: game.isInfiniteMode ? Colors.purple : theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              game.isInfiniteMode
                  ? '각 플레이어는 최대 3개의 말만!\n가장 오래된 말이 사라집니다'
                  : '3개를 연속으로 놓으면 승리!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 32),
            // 무한 모드 토글
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: game.isInfiniteMode ? Colors.purple.shade50 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: game.isInfiniteMode ? Colors.purple : Colors.grey.shade300,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.all_inclusive,
                    color: game.isInfiniteMode ? Colors.purple : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '무한모드',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: game.isInfiniteMode ? Colors.purple : Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: game.isInfiniteMode,
                    onChanged: (value) => game.setInfiniteMode(value),
                    activeColor: Colors.purple,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
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
              label: Text(_getMatchButtonLabel(game)),
              style: ElevatedButton.styleFrom(
                backgroundColor: game.isHardcore ? Colors.red : (game.isInfiniteMode ? Colors.purple : theme.primary),
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

  Widget _buildSearchingView(GameProvider game, GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                color: theme.primary,
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
                foregroundColor: theme.primary,
                side: BorderSide(color: theme.primary),
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

  Widget _buildMatchedView(GameProvider game, GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.background1,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sports_esports,
                size: 64,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${game.opponentNickname}님과 매칭!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: theme.primary,
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

  Widget _buildPlayingView(GameProvider game, GameTheme theme) {
    final auth = context.read<AuthProvider>();

    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Column(
        children: [
          // 프로필 & 턴 표시
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              gradient: theme.cardGradient,
            ),
            child: Row(
              children: [
                // 내 프로필
                Expanded(
                  child: GamePlayerProfile(
                    name: auth.nickname ?? '나',
                    avatarUrl: auth.avatarUrl,
                    isActive: game.isMyTurn,
                    isMe: true,
                    profileSettings: game.myProfileSettings ?? context.read<ShopProvider>().profileSettings,
                  ),
                ),
                // VS & 타이머
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      _buildTimer(game),
                      const SizedBox(height: 4),
                      Text(
                        game.isMyTurn ? '내 차례' : '상대 차례',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: game.isMyTurn ? theme.primary : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                // 상대 프로필
                Expanded(
                  child: GamePlayerProfile(
                    name: game.opponentNickname ?? '상대',
                    avatarUrl: game.opponentAvatarUrl,
                    isActive: !game.isMyTurn,
                    isMe: false,
                    profileSettings: game.opponentProfileSettings,
                  ),
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

          // 무한모드: 말 개수 표시
          if (game.isInfiniteGame)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildPieceCounter('내 말', game.myPieceCount, theme.primary),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.purple.shade200),
                    ),
                    child: const Text(
                      '무한모드',
                      style: TextStyle(
                        color: Colors.purple,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  _buildPieceCounter('상대 말', game.opponentPieceCount, Colors.red),
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
                  child: _buildBoard(game, auth.socketId, theme),
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

  Widget _buildBoard(GameProvider game, String? myId, GameTheme theme) {
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
                color: theme.secondary,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.primary.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: _buildCellContent(cell, theme),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCellContent(int? cell, GameTheme theme) {
    if (cell == null) {
      return const SizedBox.shrink();
    }

    // 0 = 동그라미 (첫 번째 플레이어), 1 = 세모 (두 번째 플레이어)
    if (cell == 0) {
      return Icon(
        Icons.circle_outlined,
        size: 48,
        color: theme.primary,
      );
    } else {
      return Icon(
        Icons.change_history,
        size: 48,
        color: theme.secondary,
      );
    }
  }

  Widget _buildRankedWaitingView(GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              '게임 준비 중...',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFinishedView(GameProvider game, GameTheme theme) {
    debugPrint('🎮 _buildFinishedView - isInvitationGame: ${game.isInvitationGame}');

    // 랭크전에서는 결과만 표시하고 자동으로 돌아가기
    if (widget.isRanked) {
      if (!_hasScheduledPop) {
        _hasScheduledPop = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) Navigator.pop(context);
          });
        });
      }
      final isWinner = game.isWinner;
      final isDraw = game.isDraw;
      return Container(
        decoration: BoxDecoration(gradient: theme.backgroundGradient),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isDraw ? Icons.handshake : (isWinner ? Icons.emoji_events : Icons.sentiment_dissatisfied),
                size: 80,
                color: isDraw ? Colors.orange : (isWinner ? Colors.amber : Colors.grey),
              ),
              const SizedBox(height: 16),
              Text(
                isDraw ? '무승부!' : (isWinner ? '승리!' : '패배'),
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: isDraw ? Colors.orange : (isWinner ? theme.primary : Colors.grey),
                ),
              ),
              const SizedBox(height: 24),
              const Text('잠시 후 다음 게임...', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    String resultText;
    Color resultColor;
    IconData resultIcon;

    if (game.isDraw) {
      resultText = '무승부!';
      resultColor = Colors.orange;
      resultIcon = Icons.handshake;
    } else if (game.isWinner) {
      resultText = '승리!';
      resultColor = theme.primary;
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
                  child: _buildBoard(game, null, theme),
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
                              : theme.primary,
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
                          foregroundColor: theme.primary,
                          side: BorderSide(color: theme.primary),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                      ),
                    // 친구 요청 버튼 (랜덤 매칭이고 상대가 나가지 않았고 이미 친구가 아닐 때)
                    if (!game.isInvitationGame && !game.opponentLeft && game.opponentUserId != null && !context.read<FriendProvider>().isFriend(game.opponentUserId!))
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

    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && game.status == GameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    final shop = context.read<ShopProvider>();
    final theme = GameTheme.fromProfileSettings(shop.profileSettings);

    // 랭크 게임에서 idle/waiting 상태면 다른 메시지 표시
    final isRankedWaiting = widget.isRanked &&
        (game.status == GameStatus.idle ||
            game.status == GameStatus.searching ||
            game.status == GameStatus.matched);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.exit_to_app, color: theme.primary),
            const SizedBox(width: 8),
            const Text('게임 나가기'),
          ],
        ),
        content: Text(
          isRankedWaiting
              ? '랭크전 진행 중입니다.\n나가시겠습니까?'
              : '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
        ),
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
              backgroundColor: theme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
