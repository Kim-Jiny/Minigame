import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';
import '../../utils/game_theme.dart';
import '../common/game_scaffold.dart';
import '../common/game_result_summary.dart';
import '../common/match_status_views.dart';
import '../common/game_duel_header.dart';
import '../common/game_result_action_buttons.dart';
import '../common/game_session_helper.dart';

class InfiniteTicTacToeScreen extends StatefulWidget {
  final bool isRanked;

  const InfiniteTicTacToeScreen({super.key, this.isRanked = false});

  @override
  State<InfiniteTicTacToeScreen> createState() => _InfiniteTicTacToeScreenState();
}

class _InfiniteTicTacToeScreenState extends State<InfiniteTicTacToeScreen> {
  bool _hasScheduledPop = false;  // 중복 pop 방지

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final auth = context.read<AuthProvider>();
      final game = context.read<GameProvider>();

      // 초대 게임으로 이미 playing 상태면 리셋하지 않음
      if (!widget.isRanked && game.status != GameStatus.playing) {
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
            appBar: gameAppBar(
              title: '무한 틱택토',
              backgroundColor: theme.primary,
              onBack: () => _showExitDialog(context),
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

  Widget _buildIdleView(GameProvider game, GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.all_inclusive,
                size: 80,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '무한 틱택토',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '각자 3개까지! 4번째부터 가장 오래된 돌이 사라져요',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: theme.background1,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.all_inclusive, size: 16, color: theme.primary),
                  const SizedBox(width: 4),
                  Text(
                    '무승부 없음!',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: theme.primary,
                    ),
                  ),
                ],
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
                    activeThumbColor: Colors.red,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                game.findMatch(AppConfig.gameTypeInfiniteTicTacToe);
              },
              icon: const Icon(Icons.search),
              label: Text(game.isHardcore ? '하드코어 상대 찾기' : '상대 찾기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: game.isHardcore ? Colors.red : theme.primary,
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
    return GameSearchingView(
      theme: theme,
      isHardcore: game.isHardcore,
      onCancel: () => game.cancelMatch(AppConfig.gameTypeInfiniteTicTacToe),
    );
  }

  Widget _buildMatchedView(GameProvider game, GameTheme theme) {
    return GameMatchedView(theme: theme, opponentNickname: game.opponentNickname);
  }

  Widget _buildPlayingView(GameProvider game, GameTheme theme) {
    final auth = context.read<AuthProvider>();

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF74B9FF).withValues(alpha: 0.15),
            Colors.white,
          ],
        ),
      ),
      child: Column(
        children: [
          // 프로필 & 턴 표시
          GameDuelHeader(
            backgroundColors: const [Color(0xFFE0F0FF), Color(0xFFF0F8FF)],
            accentColor: const Color(0xFF00B894),
            centerLabel: '',
            myName: auth.nickname ?? '나',
            opponentName: game.opponentNickname ?? '상대',
            myAvatarUrl: auth.avatarUrl,
            opponentAvatarUrl: game.opponentAvatarUrl,
            myActive: game.isMyTurn,
            opponentActive: !game.isMyTurn,
            myProfileSettings: game.myProfileSettings ?? context.read<ShopProvider>().profileSettings,
            opponentProfileSettings: game.opponentProfileSettings,
            myExtraWidget: _buildPieceCount(game.myPieceCount, true),
            opponentExtraWidget: _buildPieceCount(game.opponentPieceCount, false),
            centerWidget: Padding(
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
                      color: game.isMyTurn ? const Color(0xFF00B894) : Colors.grey,
                    ),
                  ),
                ],
              ),
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
                  child: _buildBoard(game),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPieceCount(int pieceCount, bool isMe) {
    final color = isMe ? const Color(0xFF6C5CE7) : const Color(0xFFFFB74D);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (index) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Icon(
              index < pieceCount ? Icons.circle : Icons.circle_outlined,
              size: 12,
              color: index < pieceCount ? color : Colors.grey.shade300,
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTimer(GameProvider game) {
    return GameBoardTimer(remaining: game.remainingTime);
  }

  Widget _buildBoard(GameProvider game) {
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
                  ? Colors.orange.shade50
                  : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isNextToDisappear
                    ? Colors.orange
                    : const Color(0xFF74B9FF),
                width: isNextToDisappear ? 3 : 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: isNextToDisappear
                      ? Colors.orange.withValues(alpha: 0.3)
                      : const Color(0xFF74B9FF).withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Stack(
              children: [
                Center(child: _buildCellContent(cell)),
                if (isNextToDisappear)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.timer,
                        size: 14,
                        color: Colors.orange.shade700,
                      ),
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

  Widget _buildRankedWaitingView(GameTheme theme) {
    return GameRankedPreparingView(theme: theme);
  }

  Widget _buildFinishedView(GameProvider game, GameTheme theme) {
    // 랭크전에서는 결과만 표시하고 자동으로 돌아가기
    if (widget.isRanked) {
      GameSessionHelper.scheduleRankedAutoReturn(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
      );
      final isWinner = game.isWinner;
      return GameRankedResultView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: theme.primary,
        isWinner: isWinner,
        isDraw: false,
      );
    }

    final isWinner = game.isWinner;
    final resultText = isWinner ? '승리!' : '아쉬워요...';
    final resultColor = isWinner ? theme.primary : Colors.grey;
    final resultIcon = isWinner ? Icons.emoji_events : Icons.sentiment_dissatisfied;

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
                const SizedBox(height: 16),
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
                // 상대방이 재경기를 원할 때 표시
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
                          style: TextStyle(
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                GameResultActionButtons(
                  accentColor: const Color(0xFF74B9FF),
                  rematchWaitingColor: Colors.grey.shade400,
                  opponentLeft: game.opponentLeft,
                  rematchWaiting: game.rematchWaiting,
                  isInvitationGame: game.isInvitationGame,
                  canSendFriendRequest: !game.isInvitationGame &&
                      !game.opponentLeft &&
                      game.opponentUserId != null &&
                      !context.read<FriendProvider>().isFriend(game.opponentUserId!),
                  onRematchPressed: game.rematchWaiting
                      ? () => game.cancelRematch()
                      : () => game.requestRematch(),
                  onSearchAgainPressed: () {
                    game.leaveGame();
                    game.findMatch(AppConfig.gameTypeInfiniteTicTacToe);
                  },
                  onLobbyPressed: () {
                    GameSessionHelper.leaveGameAndReturnToLobby(
                      context: context,
                      socketService: SocketService(),
                      roomId: game.roomId,
                      isRanked: false,
                      resetState: game.reset,
                    );
                  },
                  onFriendRequestPressed: game.opponentUserId == null
                      ? null
                      : () {
                          context.read<FriendProvider>().sendFriendRequestByUserId(game.opponentUserId!);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${game.opponentNickname}님에게 친구 요청을 보냈습니다'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
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
            Icon(Icons.exit_to_app, color: Color(0xFF74B9FF)),
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
              backgroundColor: const Color(0xFF74B9FF),
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
