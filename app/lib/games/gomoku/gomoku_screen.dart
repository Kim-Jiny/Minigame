import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../providers/ranked_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';
import '../../theme/candy_theme.dart';
import '../../utils/game_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';
import '../../widgets/cartoon/chunky_button.dart';
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
        CandyPulse,
        CandyTurnChip,
        CandyNoticeBar,
        BoardFinishedLayout,
        BoardResultPanel,
        showGameInviteSheet;

class GomokuScreen extends StatefulWidget {
  final bool isRanked;

  const GomokuScreen({super.key, this.isRanked = false});

  @override
  State<GomokuScreen> createState() => _GomokuScreenState();
}

class _GomokuScreenState extends State<GomokuScreen> {
  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accent => GameTheme.fromProfileSettings(
    context.read<ShopProvider>().profileSettings,
  ).primary;
  // 보드 크기
  static const int boardSize = 15;
  static const int totalCells = boardSize * boardSize;

  // 줌/스크롤 컨트롤러
  final TransformationController _transformationController =
      TransformationController();

  bool _hasScheduledPop = false; // 중복 pop 방지
  int? _previewPosition; // 미리보기 중인 셀 인덱스
  bool _wasMyTurn = false; // 내 턴 변경 감지용

  void _resetBoardZoom() {
    _transformationController.value = Matrix4.identity();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final auth = context.read<AuthProvider>();
      final game = context.read<GameProvider>();

      // 소켓 리스너 재등록 (다른 화면에서 제거되었을 수 있음)
      game.ensureSocketListeners();

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
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<GameProvider, ShopProvider>(
      builder: (context, game, shop, child) {
        final theme = GameTheme.fromProfileSettings(shop.profileSettings);

        // 내 턴이 되었을 때 진동
        if (game.status == GameStatus.playing && game.isMyTurn && !_wasMyTurn) {
          HapticFeedback.mediumImpact();
        }
        _wasMyTurn = game.isMyTurn;

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _showExitDialog(context);
          },
          child: Scaffold(
            appBar: gameAppBar(
              title: '오목',
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

  void _showFriendInviteDialog(BuildContext context, GameProvider game) {
    showGameInviteSheet(
      context: context,
      accent: game.isHardcore ? CandyColors.tangerine : _accent,
      gameType: AppConfig.gameTypeGomoku,
      isHardcore: game.isHardcore,
    );
  }

  Widget _buildIdleView(GameProvider game, GameTheme theme) {
    final accent = game.isHardcore ? CandyColors.tangerine : theme.primary;
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: accent,
      icon: Icons.circle_outlined,
      title: '오목',
      descriptions: const ['5개를 연속으로 놓으면 승리!'],
      findMatchLabel: game.isHardcore ? '하드코어 상대 찾기' : '상대 찾기',
      onFindMatch: () => game.findMatch(AppConfig.gameTypeGomoku),
      onInviteFriend: () => _showFriendInviteDialog(context, game),
      extra: GameHardcoreToggle(
        value: game.isHardcore,
        onChanged: (v) => game.setHardcoreMode(v),
        durationLabel: '(10초)',
      ),
    );
  }

  Widget _buildSearchingView(GameProvider game, GameTheme theme) {
    return GameSearchingView(
      theme: theme,
      isHardcore: game.isHardcore,
      onCancel: () => game.cancelMatch(AppConfig.gameTypeGomoku),
    );
  }

  Widget _buildMatchedView(GameProvider game, GameTheme theme) {
    return GameMatchedView(
      theme: theme,
      opponentNickname: game.opponentNickname,
    );
  }

  Widget _buildPlayingView(GameProvider game, GameTheme theme) {
    final auth = context.read<AuthProvider>();

    // 상대 턴이면 미리보기 자동 초기화
    if (!game.isMyTurn) {
      _previewPosition = null;
    }

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Column(
        children: [
          // 프로필 & 턴 표시
          GameDuelHeader(
            backgroundColors: [
              theme.cardGradient.colors.first,
              theme.cardGradient.colors.last,
            ],
            accentColor: _accent,
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
            centerWidget: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildTimer(game),
                  const SizedBox(height: 6),
                  CandyTurnChip(isMine: game.isMyTurn, accent: _accent),
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
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildBoard(game)),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: SafeArea(
                    top: false,
                    left: false,
                    child: Semantics(
                      button: true,
                      label: '보드 위치 초기화',
                      child: CartoonCard(
                        radius: 14,
                        shadow: 4,
                        padding: const EdgeInsets.all(9),
                        onTap: _resetBoardZoom,
                        child: Icon(
                          Icons.center_focus_strong_rounded,
                          color: theme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 착수 확인/취소 버튼
          if (_previewPosition != null && game.isMyTurn) _buildConfirmBar(game),
        ],
      ),
    );
  }

  Widget _buildTimer(GameProvider game) {
    return GameTimerBadge(
      seconds: game.remainingTime,
      label: '',
      accentColor: _accent,
      compact: true,
      showLabel: false,
      warningThreshold: 5,
    );
  }

  Widget _buildBoard(GameProvider game) {
    final screenWidth = MediaQuery.of(context).size.width;
    const pad = 12.0;
    final cellSize = math.max(8.0, (screenWidth - pad * 2) / boardSize);
    final boardPx = cellSize * boardSize;
    final stoneSize = cellSize * 0.82;
    final finished = game.status == GameStatus.finished;
    final winCells = finished && !game.isDraw
        ? _gomokuWinCells(game.board)
        : const <int>{};
    final canPreview = game.status == GameStatus.playing && game.isMyTurn;

    return InteractiveViewer(
      transformationController: _transformationController,
      minScale: 0.5,
      maxScale: 3.0,
      constrained: false,
      child: Padding(
        padding: const EdgeInsets.all(pad),
        child: Container(
          width: boardPx,
          height: boardPx,
          decoration: BoxDecoration(
            color: const Color(0xFFFFE2A8), // 캔디 우드
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [
              BoxShadow(color: CandyColors.ink, offset: Offset(0, 5)),
            ],
          ),
          // 테두리는 레이아웃에 영향을 주지 않도록 foreground 로 그린다
          // (그리드와 선 위치가 어긋나지 않게).
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: CandyColors.ink, width: 3),
          ),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: GomokuBoardPainter(
                boardSize: boardSize,
                cellSize: cellSize,
              ),
              child: GridView.builder(
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: boardSize,
                ),
                itemCount: totalCells,
                itemBuilder: (context, index) {
                  final cell = game.board.length > index
                      ? game.board[index]
                      : null;
                  final isLastMove = game.lastMovePosition == index;
                  final isPreview =
                      canPreview && cell == null && _previewPosition == index;

                  Widget? child;
                  if (isPreview) {
                    child = _buildPreviewStone(game, stoneSize);
                  } else if (cell != null) {
                    child = _GomokuStone(
                      key: ValueKey('stone-$index-$cell'),
                      size: stoneSize,
                      isBlack: cell == 0,
                      isLast: isLastMove,
                      isWin: winCells.contains(index),
                    );
                  }

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (cell == null && game.isMyTurn) {
                        HapticFeedback.selectionClick();
                        setState(() => _previewPosition = index);
                      }
                    },
                    child: Center(child: child),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewStone(GameProvider game, double stoneSize) {
    final isBlack = game.myPlayerIndex == 0;

    return CandyPulse(
      duration: const Duration(milliseconds: 600),
      builder: (_, t, child) =>
          Transform.scale(scale: 0.9 + 0.12 * t, child: child),
      child: SizedBox(
        width: stoneSize,
        height: stoneSize,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (isBlack ? CandyColors.ink : Colors.white).withValues(
              alpha: 0.55,
            ),
            border: Border.all(color: CandyColors.sky, width: 3),
          ),
        ),
      ),
    );
  }

  Widget _buildConfirmBar(GameProvider game) {
    final row = _previewPosition! ~/ boardSize + 1;
    final col = _previewPosition! % boardSize + 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: CandyColors.ink, width: 3)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            SizedBox(
              width: 92,
              child: ChunkyButton(
                label: '취소',
                color: Colors.white,
                textColor: CandyColors.ink,
                height: 46,
                radius: 16,
                fontSize: 15,
                onPressed: () => setState(() => _previewPosition = null),
              ),
            ),
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '($row, $col)',
                    style: const TextStyle(
                      fontSize: 15,
                      color: CandyColors.inkSoft,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 156,
              child: ChunkyButton(
                label: '착수 확인',
                icon: Icons.check_rounded,
                color: _accent,
                height: 46,
                radius: 16,
                fontSize: 15,
                onPressed: () {
                  final pos = _previewPosition;
                  if (pos == null) return;
                  setState(() => _previewPosition = null);
                  game.makeMove(pos);
                },
              ),
            ),
          ],
        ),
      ),
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
      final isDraw = game.isDraw;
      return GameRankedResultView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: theme.primary,
        isWinner: isWinner,
        isDraw: isDraw,
      );
    }

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: SafeArea(
        top: false,
        child: BoardFinishedLayout(
          // 최종 보드 상태 (승리 5목 강조)
          board: _buildBoard(game),
          panel: BoardResultPanel(
            isDraw: game.isDraw,
            isWinner: game.isWinner,
            accent: _accent,
            showRematchWaiting: game.opponentWantsRematch && !game.opponentLeft,
            opponentNickname: game.opponentNickname,
            actions: GameResultActionButtons(
              accentColor: _accent,
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
                game.findMatch(AppConfig.gameTypeGomoku);
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

    // idle 상태면 바로 나가기
    if (!widget.isRanked && game.status == GameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    final isRankedWaiting =
        widget.isRanked &&
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

    // searching 상태면 매칭 취소
    if (game.status == GameStatus.searching) {
      game.cancelMatch(AppConfig.gameTypeGomoku);
      Navigator.pop(context);
      return;
    }

    // matched 또는 playing 상태면 확인 다이얼로그
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
        content: Text(
          game.status == GameStatus.matched
              ? '매칭이 완료되었습니다. 나가시겠습니까?'
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

/// 5목 이상이 이어진 칸들의 인덱스 집합(없으면 빈 집합).
Set<int> _gomokuWinCells(List<int?> board) {
  const n = _GomokuScreenState.boardSize;
  const dirs = [
    [0, 1],
    [1, 0],
    [1, 1],
    [1, -1],
  ];
  if (board.length < n * n) return const {};
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      final v = board[r * n + c];
      if (v == null) continue;
      for (final d in dirs) {
        final pr = r - d[0];
        final pc = c - d[1];
        if (pr >= 0 && pr < n && pc >= 0 && pc < n && board[pr * n + pc] == v) {
          continue; // 줄의 시작점이 아님
        }
        final run = <int>[];
        var rr = r;
        var cc = c;
        while (rr >= 0 &&
            rr < n &&
            cc >= 0 &&
            cc < n &&
            board[rr * n + cc] == v) {
          run.add(rr * n + cc);
          rr += d[0];
          cc += d[1];
        }
        if (run.length >= 5) return run.toSet();
      }
    }
  }
  return const {};
}

/// 바둑돌. 흑 = 잉크색, 백 = 흰색 + 굵은 외곽선.
/// 마지막 수는 통통 튀며 놓이고 분홍 점이 찍히며, 승리 5목은 노란 링이 맥동한다.
class _GomokuStone extends StatelessWidget {
  final double size;
  final bool isBlack;
  final bool isLast;
  final bool isWin;

  const _GomokuStone({
    super.key,
    required this.size,
    required this.isBlack,
    required this.isLast,
    required this.isWin,
  });

  @override
  Widget build(BuildContext context) {
    Widget stone = SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isBlack ? CandyColors.ink : Colors.white,
          border: Border.all(color: CandyColors.ink, width: 1.8),
          boxShadow: const [
            BoxShadow(color: Color(0x553A2D5C), offset: Offset(0, 1.5)),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: const Alignment(-0.4, -0.45),
              child: Container(
                width: size * 0.26,
                height: size * 0.14,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: isBlack ? 0.35 : 0.0),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
            if (isLast)
              Container(
                width: size * 0.26,
                height: size * 0.26,
                decoration: const BoxDecoration(
                  color: CandyColors.pink,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );

    if (isWin) {
      stone = CandyPulse(
        duration: const Duration(milliseconds: 520),
        child: stone,
        builder: (_, t, child) => Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Container(
              width: size * (1.0 + 0.4 * t),
              height: size * (1.0 + 0.4 * t),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: CandyColors.sun.withValues(alpha: 1 - 0.5 * t),
                  width: 3,
                ),
              ),
            ),
            Transform.scale(scale: 1 + 0.08 * t, child: child),
          ],
        ),
      );
    }

    if (isLast) {
      // 놓일 때 위에서 톡 떨어지며 튕긴다.
      stone = TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 500),
        curve: Curves.elasticOut,
        builder: (_, t, child) => Opacity(
          opacity: math.min(1.0, t * 4).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * -12),
            child: Transform.scale(scale: t.clamp(0.0, 1.5), child: child),
          ),
        ),
        child: stone,
      );
    }
    return stone;
  }
}

// 바둑판 그리드 라인을 그리는 CustomPainter
class GomokuBoardPainter extends CustomPainter {
  final int boardSize;
  final double cellSize;

  GomokuBoardPainter({required this.boardSize, required this.cellSize});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = CandyColors.ink.withValues(alpha: 0.55)
      ..strokeWidth = 1.2;

    // 가로선
    for (int i = 0; i < boardSize; i++) {
      final y = cellSize * i + cellSize / 2;
      canvas.drawLine(
        Offset(cellSize / 2, y),
        Offset(size.width - cellSize / 2, y),
        paint,
      );
    }

    // 세로선
    for (int i = 0; i < boardSize; i++) {
      final x = cellSize * i + cellSize / 2;
      canvas.drawLine(
        Offset(x, cellSize / 2),
        Offset(x, size.height - cellSize / 2),
        paint,
      );
    }

    // 화점(별 위치) 그리기 - 15x15 보드용
    final starPoints = [
      [3, 3],
      [3, 7],
      [3, 11],
      [7, 3],
      [7, 7],
      [7, 11],
      [11, 3],
      [11, 7],
      [11, 11],
    ];

    final starPaint = Paint()
      ..color = CandyColors.ink
      ..style = PaintingStyle.fill;

    for (final point in starPoints) {
      final x = cellSize * point[1] + cellSize / 2;
      final y = cellSize * point[0] + cellSize / 2;
      canvas.drawCircle(Offset(x, y), cellSize * 0.11, starPaint);
    }
  }

  @override
  bool shouldRepaint(covariant GomokuBoardPainter old) =>
      old.cellSize != cellSize || old.boardSize != boardSize;
}
