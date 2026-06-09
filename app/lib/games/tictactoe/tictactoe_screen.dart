import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../providers/ranked_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';
import '../../utils/game_theme.dart';
import '../common/game_hardcore_toggle.dart';
import '../common/game_intro_view.dart';
import '../common/game_scaffold.dart';
import '../common/game_result_summary.dart';
import '../common/match_status_views.dart';
import '../common/game_duel_header.dart';
import '../common/game_result_action_buttons.dart';
import '../common/game_session_helper.dart';

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
              title: '틱택토',
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

  void _showFriendInviteDialog(BuildContext context, GameProvider game) {
    final friendProvider = context.read<FriendProvider>();
    final onlineFriends = friendProvider.friends.where((f) => f.isOnline).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 핸들
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 헤더
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const Icon(Icons.person_add, color: Colors.blue),
                  const SizedBox(width: 12),
                  const Text(
                    '친구 초대',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (game.isHardcore)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.local_fire_department, size: 16, color: Colors.red.shade400),
                          const SizedBox(width: 4),
                          Text('하드코어', style: TextStyle(fontSize: 12, color: Colors.red.shade400, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 친구 목록
            Flexible(
              child: onlineFriends.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person_off, size: 48, color: Colors.grey.shade400),
                            const SizedBox(height: 16),
                            Text(
                              '온라인 친구가 없습니다',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: onlineFriends.length,
                      itemBuilder: (context, index) {
                        final friend = onlineFriends[index];
                        return ListTile(
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                backgroundColor: Colors.blue.shade100,
                                child: Text(
                                  friend.nickname.isNotEmpty ? friend.nickname[0].toUpperCase() : '?',
                                  style: TextStyle(color: Colors.blue.shade700),
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 2),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          title: Text(friend.nickname, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: friend.memo != null && friend.memo!.isNotEmpty
                              ? Text(friend.memo!, style: TextStyle(color: Colors.grey.shade600, fontSize: 12))
                              : null,
                          trailing: ElevatedButton(
                            onPressed: () {
                              final gameType = game.isInfiniteMode
                                  ? AppConfig.gameTypeInfiniteTicTacToe
                                  : AppConfig.gameTypeTicTacToe;
                              friendProvider.inviteToGame(
                                friend.id,
                                gameType,
                                isHardcore: game.isHardcore,
                              );
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('${friend.nickname}님에게 초대를 보냈습니다!'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: game.isHardcore ? Colors.red : Colors.blue,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                            child: const Text('초대'),
                          ),
                        );
                      },
                    ),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
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
    final accent = game.isHardcore
        ? Colors.red
        : (game.isInfiniteMode ? Colors.purple : theme.primary);
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: accent,
      icon: game.isInfiniteMode ? Icons.all_inclusive : Icons.grid_3x3,
      title: game.isInfiniteMode ? '무한 틱택토' : '틱택토',
      descriptions: [
        game.isInfiniteMode
            ? '각 플레이어는 최대 3개의 말만!\n가장 오래된 말이 사라집니다'
            : '3개를 연속으로 놓으면 승리!',
      ],
      findMatchLabel: _getMatchButtonLabel(game),
      onFindMatch: () => game.findMatch(AppConfig.gameTypeTicTacToe),
      onInviteFriend: () => _showFriendInviteDialog(context, game),
      extra: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
                Icon(Icons.all_inclusive,
                    color: game.isInfiniteMode ? Colors.purple : Colors.grey),
                const SizedBox(width: 8),
                Text('무한모드',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: game.isInfiniteMode ? Colors.purple : Colors.grey.shade600)),
                const SizedBox(width: 8),
                Switch(
                  value: game.isInfiniteMode,
                  onChanged: (value) => game.setInfiniteMode(value),
                  activeThumbColor: Colors.purple,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GameHardcoreToggle(
            value: game.isHardcore,
            onChanged: (v) => game.setHardcoreMode(v),
            durationLabel: '(10초)',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchingView(GameProvider game, GameTheme theme) {
    return GameSearchingView(
      theme: theme,
      isHardcore: game.isHardcore,
      onCancel: () => game.cancelMatch(AppConfig.gameTypeTicTacToe),
    );
  }

  Widget _buildMatchedView(GameProvider game, GameTheme theme) {
    return GameMatchedView(theme: theme, opponentNickname: game.opponentNickname);
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
          GameDuelHeader(
            backgroundColors: [
              (theme.cardGradient.colors.first),
              (theme.cardGradient.colors.last),
            ],
            accentColor: theme.primary,
            centerLabel: '',
            myName: auth.nickname ?? '나',
            opponentName: game.opponentNickname ?? '상대',
            myAvatarUrl: auth.avatarUrl,
            opponentAvatarUrl: game.opponentAvatarUrl,
            myActive: game.isMyTurn,
            opponentActive: !game.isMyTurn,
            myProfileSettings: game.myProfileSettings ?? context.read<ShopProvider>().profileSettings,
            opponentProfileSettings: game.opponentProfileSettings,
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
                      color: game.isMyTurn ? theme.primary : Colors.grey,
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
    return GameBoardTimer(remaining: game.remainingTime);
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
    return GameRankedPreparingView(theme: theme);
  }

  Widget _buildFinishedView(GameProvider game, GameTheme theme) {
    debugPrint('🎮 _buildFinishedView - isInvitationGame: ${game.isInvitationGame}');

    // 랭크전에서는 결과만 표시하고 자동으로 돌아가기
    if (widget.isRanked) {
      GameSessionHelper.scheduleRankedAutoReturn(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
      );
      final isWinner = game.isWinner;
      final isDraw = game.isDraw;
      return GameRankedResultView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: theme.primary,
      isWinner: isWinner,
      isDraw: isDraw,
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
                GameResultActionButtons(
                  accentColor: theme.primary,
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
                    game.findMatch(AppConfig.gameTypeTicTacToe);
                  },
                  onLobbyPressed: () {
                    GameSessionHelper.leaveGameAndReturnToLobby(
                      context: context,
                      socketService: SocketService(),
                      roomId: game.roomId,
                      isRanked: widget.isRanked,
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

    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && game.status == GameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    final isRankedWaiting = widget.isRanked &&
        (game.status == GameStatus.idle ||
            game.status == GameStatus.searching ||
            game.status == GameStatus.matched);

    if (isRankedWaiting) {
      // 랭크전에서는 RankedProvider의 roomId를 사용해야 함
      String? roomId = game.roomId;
      if (widget.isRanked && roomId == null) {
        try {
          roomId = context.read<RankedProvider>().roomId;
        } catch (_) {}
      }
      if (roomId != null) {
        SocketService().emit('leave_room', {'roomId': roomId});
      }
      game.reset();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (game.status == GameStatus.searching) {
      final gameType = game.isInfiniteMode
          ? AppConfig.gameTypeInfiniteTicTacToe
          : AppConfig.gameTypeTicTacToe;
      game.cancelMatch(gameType);
      Navigator.pop(context);
      return;
    }

    final shop = context.read<ShopProvider>();
    final theme = GameTheme.fromProfileSettings(shop.profileSettings);

    // matched 또는 playing 상태면 확인 다이얼로그
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
        content: Text(game.status == GameStatus.matched
            ? '매칭이 완료되었습니다. 나가시겠습니까?'
            : '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.'),
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
