import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../providers/ranked_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';
import '../../widgets/game_player_profile.dart';
import '../../utils/game_theme.dart';

class GomokuScreen extends StatefulWidget {
  final bool isRanked;

  const GomokuScreen({super.key, this.isRanked = false});

  @override
  State<GomokuScreen> createState() => _GomokuScreenState();
}

class _GomokuScreenState extends State<GomokuScreen> {
  // 보드 크기
  static const int boardSize = 15;
  static const int totalCells = boardSize * boardSize;

  // 줌/스크롤 컨트롤러
  final TransformationController _transformationController =
      TransformationController();

  bool _hasScheduledPop = false;  // 중복 pop 방지

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
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _showExitDialog(context);
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('오목'),
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

  void _showFriendInviteDialog(BuildContext context, GameProvider game) {
    final friendProvider = context.read<FriendProvider>();
    final onlineFriends = friendProvider.friends.where((f) => f.isOnline).toList();
    final shop = context.read<ShopProvider>();
    final theme = GameTheme.fromProfileSettings(shop.profileSettings);

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
                  Icon(Icons.person_add, color: theme.primary),
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
                                backgroundColor: theme.primary.withValues(alpha: 0.2),
                                child: Text(
                                  friend.nickname.isNotEmpty ? friend.nickname[0].toUpperCase() : '?',
                                  style: TextStyle(color: theme.primary),
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
                              friendProvider.inviteToGame(
                                friend.id,
                                AppConfig.gameTypeGomoku,
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
                              backgroundColor: game.isHardcore ? Colors.red : theme.primary,
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

  Widget _buildIdleView(GameProvider game, GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 오목 아이콘
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.circle_outlined,
                size: 80,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '오목',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '5개를 연속으로 놓으면 승리!',
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
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () {
                    debugPrint('🎯 [Gomoku] 상대 찾기 버튼 클릭');
                    debugPrint('🎯 [Gomoku] 현재 상태: ${game.status}');
                    game.findMatch(AppConfig.gameTypeGomoku);
                  },
                  icon: const Icon(Icons.search),
                  label: Text(game.isHardcore ? '하드코어 상대 찾기' : '상대 찾기'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: game.isHardcore ? Colors.red : theme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => _showFriendInviteDialog(context, game),
                  icon: const Icon(Icons.person_add),
                  label: const Text('친구 초대'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: game.isHardcore ? Colors.red : theme.primary,
                    side: BorderSide(
                      color: game.isHardcore ? Colors.red : theme.primary,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
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
                game.cancelMatch(AppConfig.gameTypeGomoku);
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
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF2D3436).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Column(
        children: [
          // 프로필 & 턴 표시
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFDFE6E9), Color(0xFFF0F0F0)],
              ),
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
                    activeColor: const Color(0xFF2D3436),
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
                          color: game.isMyTurn ? const Color(0xFF2D3436) : Colors.grey,
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
                    activeColor: const Color(0xFF2D3436),
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

          // 게임 보드
          Expanded(
            child: _buildBoard(game),
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

  Widget _buildBoard(GameProvider game) {
    final screenWidth = MediaQuery.of(context).size.width;
    final cellSize = screenWidth / boardSize;

    return InteractiveViewer(
      transformationController: _transformationController,
      minScale: 0.5,
      maxScale: 3.0,
      constrained: false,
      child: Container(
        width: cellSize * boardSize,
        height: cellSize * boardSize,
        decoration: BoxDecoration(
          color: const Color(0xFFDEB887), // 바둑판 색상
          border: Border.all(color: Colors.brown.shade700, width: 2),
        ),
        child: CustomPaint(
          painter: GomokuBoardPainter(
            boardSize: boardSize,
            cellSize: cellSize,
          ),
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: boardSize,
            ),
            itemCount: totalCells,
            itemBuilder: (context, index) {
              final cell = game.board.length > index ? game.board[index] : null;
              final isLastMove = game.lastMovePosition == index;

              return GestureDetector(
                onTap: () {
                  if (cell == null && game.isMyTurn) {
                    game.makeMove(index);
                  }
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: isLastMove
                        ? Border.all(color: Colors.red, width: 2)
                        : null,
                  ),
                  child: Center(
                    child: _buildStone(cell),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStone(int? cell) {
    if (cell == null) {
      return const SizedBox.shrink();
    }

    // 0 = 흑돌 (첫 번째 플레이어), 1 = 백돌 (두 번째 플레이어)
    final screenWidth = MediaQuery.of(context).size.width;
    final stoneSize = (screenWidth / boardSize) * 0.8;

    return Container(
      width: stoneSize,
      height: stoneSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: cell == 0 ? Colors.black : Colors.white,
        border: Border.all(
          color: cell == 0 ? Colors.grey.shade800 : Colors.grey.shade400,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 2,
            offset: const Offset(1, 1),
          ),
        ],
      ),
    );
  }

  Widget _buildRankedWaitingView(GameTheme theme) {
    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('게임 준비 중...', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildFinishedView(GameProvider game, GameTheme theme) {
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
      resultColor = const Color(0xFF2D3436);
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
            child: _buildBoard(game),
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
                              : const Color(0xFF2D3436),
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
                          game.findMatch(AppConfig.gameTypeGomoku);
                        },
                        icon: const Icon(Icons.search),
                        label: const Text('다시 찾기'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF2D3436),
                          side: const BorderSide(color: Color(0xFF2D3436)),
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

    // idle 상태면 바로 나가기
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
        title: const Row(
          children: [
            Icon(Icons.exit_to_app, color: Color(0xFF2D3436)),
            SizedBox(width: 8),
            Text('게임 나가기'),
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
              backgroundColor: const Color(0xFF2D3436),
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}

// 바둑판 그리드 라인을 그리는 CustomPainter
class GomokuBoardPainter extends CustomPainter {
  final int boardSize;
  final double cellSize;

  GomokuBoardPainter({
    required this.boardSize,
    required this.cellSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.brown.shade700
      ..strokeWidth = 1.0;

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
      [3, 3], [3, 7], [3, 11],
      [7, 3], [7, 7], [7, 11],
      [11, 3], [11, 7], [11, 11],
    ];

    final starPaint = Paint()
      ..color = Colors.brown.shade800
      ..style = PaintingStyle.fill;

    for (final point in starPoints) {
      final x = cellSize * point[1] + cellSize / 2;
      final y = cellSize * point[0] + cellSize / 2;
      canvas.drawCircle(Offset(x, y), cellSize * 0.1, starPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
