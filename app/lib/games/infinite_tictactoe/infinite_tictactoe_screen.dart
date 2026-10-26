import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';
import '../../theme/candy_theme.dart';
import '../../utils/game_theme.dart';
import '../common/game_hardcore_toggle.dart';
import '../common/game_intro_view.dart';
import '../common/game_scaffold.dart';
import '../common/game_result_summary.dart';
import '../common/game_timer_badge.dart';
import '../common/match_status_views.dart';
import '../common/game_duel_header.dart';
import '../common/game_result_action_buttons.dart';
import '../common/game_session_helper.dart';
import '../tictactoe/tictactoe_screen.dart'
    show
        TttBoard,
        TttPieceDots,
        CandyTurnChip,
        CandyNoticeBar,
        BoardFinishedLayout,
        BoardResultPanel;

class InfiniteTicTacToeScreen extends StatefulWidget {
  final bool isRanked;

  const InfiniteTicTacToeScreen({super.key, this.isRanked = false});

  @override
  State<InfiniteTicTacToeScreen> createState() =>
      _InfiniteTicTacToeScreenState();
}

class _InfiniteTicTacToeScreenState extends State<InfiniteTicTacToeScreen> {
  bool _hasScheduledPop = false; // 중복 pop 방지
  bool _wasMyTurn = false; // 내 턴 전환 감지(햅틱)
  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accent => GameTheme.fromProfileSettings(
    context.read<ShopProvider>().profileSettings,
  ).primary;

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
        final myTurnNow = game.status == GameStatus.playing && game.isMyTurn;
        if (myTurnNow && !_wasMyTurn) {
          HapticFeedback.selectionClick();
        }
        _wasMyTurn = myTurnNow;
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
              GameStatus.idle =>
                widget.isRanked
                    ? _buildRankedWaitingView(theme)
                    : _buildIdleView(game, theme),
              GameStatus.searching =>
                widget.isRanked
                    ? _buildRankedWaitingView(theme)
                    : _buildSearchingView(game, theme),
              GameStatus.matched =>
                widget.isRanked
                    ? _buildRankedWaitingView(theme)
                    : _buildMatchedView(game, theme),
              GameStatus.playing => _buildPlayingView(game, theme),
              GameStatus.finished => _buildFinishedView(game, theme),
            },
          ),
        );
      },
    );
  }

  Widget _buildIdleView(GameProvider game, GameTheme theme) {
    final accent = game.isHardcore ? CandyColors.tangerine : theme.primary;
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: accent,
      icon: Icons.all_inclusive,
      title: '무한 틱택토',
      descriptions: const ['각자 3개까지! 4번째부터 가장 오래된 돌이 사라져요'],
      findMatchLabel: game.isHardcore ? '하드코어 상대 찾기' : '상대 찾기',
      onFindMatch: () => game.findMatch(AppConfig.gameTypeInfiniteTicTacToe),
      extra: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: CandyColors.sun,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: CandyColors.ink, width: 2.5),
              boxShadow: const [
                BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.all_inclusive, size: 16, color: CandyColors.ink),
                SizedBox(width: 6),
                Text(
                  '무승부 없음!',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
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
      onCancel: () => game.cancelMatch(AppConfig.gameTypeInfiniteTicTacToe),
    );
  }

  Widget _buildMatchedView(GameProvider game, GameTheme theme) {
    return GameMatchedView(
      theme: theme,
      opponentNickname: game.opponentNickname,
    );
  }

  Widget _buildBoard(GameProvider game, GameTheme theme, bool canPlay) {
    return TttBoard(
      board: game.board,
      canPlay: canPlay,
      accent: theme.primary,
      p0Color: theme.primary,
      p1Color: CandyColors.sky,
      fadingIndex: game.status == GameStatus.playing
          ? game.nextToDisappear
          : null,
      onCellTap: (index) {
        if (index < game.board.length &&
            game.board[index] == null &&
            game.isMyTurn) {
          game.makeMove(index);
        }
      },
    );
  }

  Widget _buildPlayingView(GameProvider game, GameTheme theme) {
    final auth = context.read<AuthProvider>();
    final myIdx = game.myPlayerIndex ?? 0;
    final myColor = myIdx == 0 ? theme.primary : CandyColors.sky;
    final oppColor = myIdx == 0 ? CandyColors.sky : theme.primary;

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // 프로필 & 턴 표시
            GameDuelHeader(
              backgroundColors: [
                theme.cardGradient.colors.first,
                theme.cardGradient.colors.last,
              ],
              accentColor: theme.primary,
              centerLabel: '',
              myName: auth.nickname ?? '나',
              opponentName: game.opponentNickname ?? '상대',
              myAvatarUrl: auth.avatarUrl,
              opponentAvatarUrl: game.opponentAvatarUrl,
              myActive: game.isMyTurn,
              opponentActive: !game.isMyTurn,
              myProfileSettings:
                  game.myProfileSettings ??
                  context.read<ShopProvider>().profileSettings,
              opponentProfileSettings: game.opponentProfileSettings,
              myExtraWidget: _buildPieceCount(game.myPieceCount, myColor),
              opponentExtraWidget: _buildPieceCount(
                game.opponentPieceCount,
                oppColor,
              ),
              centerWidget: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GameTimerBadge(
                      seconds: game.remainingTime,
                      label: '',
                      accentColor: theme.primary,
                      compact: true,
                      showLabel: false,
                      warningThreshold: 5,
                    ),
                    const SizedBox(height: 6),
                    CandyTurnChip(isMine: game.isMyTurn, accent: theme.primary),
                  ],
                ),
              ),
            ),

            // 타임아웃 알림
            if (game.timeoutPlayerNickname != null)
              CandyNoticeBar(
                text: '${game.timeoutPlayerNickname}님 시간 초과! 랜덤 위치에 배치됨',
              ),

            // 게임 보드
            Expanded(child: _buildBoard(game, theme, game.isMyTurn)),
          ],
        ),
      ),
    );
  }

  Widget _buildPieceCount(int pieceCount, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: TttPieceDots(count: pieceCount, color: color),
    );
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

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: SafeArea(
        top: false,
        child: BoardFinishedLayout(
          board: _buildBoard(game, theme, false),
          panel: BoardResultPanel(
            isDraw: false,
            isWinner: game.isWinner,
            accent: theme.primary,
            showRematchWaiting: game.opponentWantsRematch && !game.opponentLeft,
            opponentNickname: game.opponentNickname,
            actions: GameResultActionButtons(
              accentColor: theme.primary,
              opponentLeft: game.opponentLeft,
              rematchWaiting: game.rematchWaiting,
              isInvitationGame: game.isInvitationGame,
              canSendFriendRequest:
                  !game.isInvitationGame &&
                  !game.opponentLeft &&
                  game.opponentUserId != null &&
                  !context.read<FriendProvider>().isFriend(
                    game.opponentUserId!,
                  ),
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
                      context.read<FriendProvider>().sendFriendRequestByUserId(
                        game.opponentUserId!,
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${game.opponentNickname}님에게 친구 요청을 보냈습니다',
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
            ),
          ),
        ),
      ),
    );
  }

  void _showExitDialog(BuildContext context) {
    final game = context.read<GameProvider>();

    // 결과 화면에서는 패배 처리 경고 없이 바로 나가기
    if (game.status == GameStatus.finished) {
      game.leaveGame();
      Navigator.pop(context);
      return;
    }

    if (game.status == GameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.exit_to_app, color: _accent),
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
              backgroundColor: _accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
