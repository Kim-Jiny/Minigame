import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../navigation/game_routes.dart';
import '../providers/ranked_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/game_provider.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/confetti_burst.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';
import '../widgets/tier_badge.dart';
import 'leaderboard_screen.dart';

class RankedScreen extends StatefulWidget {
  const RankedScreen({super.key});

  @override
  State<RankedScreen> createState() => _RankedScreenState();
}

class _RankedScreenState extends State<RankedScreen> {
  int? _lastNavigatedGameIndex;
  bool _isNavigating = false;
  RankedProvider? _rankedProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 위젯이 이미 dispose 되었으면 무시
      if (!mounted) return;

      _rankedProvider = context.read<RankedProvider>();
      _rankedProvider!.initialize();
      _rankedProvider!.getMyRank();

      // Provider 변경 리스너 추가
      _rankedProvider!.addListener(_onRankedProviderChanged);
    });
  }

  @override
  void dispose() {
    // 리스너가 추가되었을 때만 제거
    if (_rankedProvider != null) {
      _rankedProvider!.removeListener(_onRankedProviderChanged);

      // finished 상태에서 나갈 때 상태 리셋
      if (_rankedProvider!.matchStatus == RankedMatchStatus.finished) {
        _rankedProvider!.resetMatchState();
      }
    }
    super.dispose();
  }

  void _onRankedProviderChanged() {
    if (!mounted) {
      debugPrint('🎮 [Listener] Widget not mounted, skipping');
      return;
    }

    final ranked = context.read<RankedProvider>();

    debugPrint('🎮 [Listener] ==============================');
    debugPrint('🎮 [Listener] status=${ranked.matchStatus}');
    debugPrint('🎮 [Listener] currentGame=${ranked.currentGame}');
    debugPrint('🎮 [Listener] currentGameIndex=${ranked.currentGameIndex}');
    debugPrint(
      '🎮 [Listener] _lastNavigatedGameIndex=$_lastNavigatedGameIndex',
    );
    debugPrint('🎮 [Listener] _isNavigating=$_isNavigating');
    debugPrint('🎮 [Listener] score=${ranked.score}');

    // waitingNextGame 상태에서는 네비게이션 상태 리셋 (다음 게임 네비게이션 가능하도록)
    // 중요: 여기서 리셋해야 ranked_game_start 이벤트 시 다음 게임으로 이동 가능
    if (ranked.matchStatus == RankedMatchStatus.waitingNextGame) {
      debugPrint(
        '🎮 [Listener] waitingNextGame - resetting navigation state for next game',
      );
      _isNavigating = false;
      // _lastNavigatedGameIndex는 유지하여 같은 게임 중복 네비게이션 방지
    }

    // playing 상태이고 게임이 있고 아직 해당 게임으로 이동하지 않았으면 네비게이션
    final shouldNavigate =
        ranked.matchStatus == RankedMatchStatus.playing &&
        ranked.currentGame != null &&
        _lastNavigatedGameIndex != ranked.currentGameIndex &&
        !_isNavigating;

    debugPrint('🎮 [Listener] shouldNavigate=$shouldNavigate');
    debugPrint(
      '🎮 [Listener]   - matchStatus == playing: ${ranked.matchStatus == RankedMatchStatus.playing}',
    );
    debugPrint(
      '🎮 [Listener]   - currentGame != null: ${ranked.currentGame != null}',
    );
    debugPrint(
      '🎮 [Listener]   - lastNav != index: ${_lastNavigatedGameIndex != ranked.currentGameIndex}',
    );
    debugPrint('🎮 [Listener]   - !isNavigating: ${!_isNavigating}');

    if (shouldNavigate) {
      debugPrint(
        '🎮 [Listener] *** TRIGGERING NAVIGATION to ${ranked.currentGame} ***',
      );
      _navigateToGameScreen(ranked.currentGame!, ranked.currentGameIndex);
    }

    // idle, searching, found 상태면 네비게이션 상태 리셋
    if (ranked.matchStatus == RankedMatchStatus.idle ||
        ranked.matchStatus == RankedMatchStatus.searching ||
        ranked.matchStatus == RankedMatchStatus.found) {
      debugPrint('🎮 [Listener] Resetting navigation state');
      _lastNavigatedGameIndex = null;
      _isNavigating = false;
    }
    debugPrint('🎮 [Listener] ==============================');
  }

  void _navigateToGameScreen(String gameType, int gameIndex) {
    debugPrint(
      '🎮 [Navigate] _navigateToGameScreen called: gameType=$gameType, gameIndex=$gameIndex',
    );
    debugPrint(
      '🎮 [Navigate] Current state: _isNavigating=$_isNavigating, _lastNavigatedGameIndex=$_lastNavigatedGameIndex',
    );

    if (_isNavigating) {
      debugPrint('🎮 [Navigate] ❌ Already navigating, skip');
      return;
    }
    if (_lastNavigatedGameIndex == gameIndex) {
      debugPrint('🎮 [Navigate] ❌ Already navigated to index $gameIndex, skip');
      return;
    }

    _isNavigating = true;
    _lastNavigatedGameIndex = gameIndex;

    debugPrint(
      '🎮 [Navigate] ✅ Proceeding with navigation to $gameType (index: $gameIndex)',
    );

    // GameProvider 초기화 및 상태 리셋
    final auth = context.read<AuthProvider>();
    final game = context.read<GameProvider>();
    debugPrint('🎮 [Navigate] auth.socketId=${auth.socketId}');
    debugPrint('🎮 [Navigate] GameProvider current status=${game.status}');

    // 중요: 이전 게임의 상태를 리셋하여 두 번째 게임이 올바르게 시작되도록 함
    game.reset();
    debugPrint(
      '🎮 [Navigate] GameProvider reset called, status now=${game.status}',
    );

    // 중요: 이전 게임 화면의 dispose()에서 off()를 호출해서 리스너가 제거되었을 수 있음
    // 소켓 리스너를 재등록
    game.ensureSocketListeners();
    debugPrint('🎮 [Navigate] GameProvider listeners re-registered');

    if (auth.socketId == null) {
      // 소켓 미연결 상태에서 진입하면 GameProvider가 초기화되지 않아
      // 게임 화면이 빈 상태로 떠버린다. 에러를 보여주고 안전하게 복귀.
      debugPrint('🎮 [Navigate] ⚠️ auth.socketId is null - abort navigation');
      _isNavigating = false;
      _lastNavigatedGameIndex = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('서버 연결이 끊겼습니다. 다시 시도해주세요.')),
        );
      }
      return;
    }

    game.initialize(auth.socketId!);
    debugPrint('🎮 [Navigate] GameProvider initialized');

    final gameScreen = GameRoutes.buildGameScreen(gameType, isRanked: true);
    if (gameScreen == null) {
      debugPrint('🎮 [Navigate] ❌ Unknown game type: $gameType');
      _isNavigating = false;
      return;
    }

    debugPrint('🎮 [Navigate] Calling Navigator.push for $gameType...');
    Navigator.push(context, MaterialPageRoute(builder: (_) => gameScreen)).then(
      (_) {
        debugPrint('🎮 [Navigate] ✅ Game screen popped, index was $gameIndex');
        debugPrint('🎮 [Navigate] Resetting _isNavigating to false');
        _isNavigating = false;
        // setState로 UI 갱신
        if (mounted) {
          setState(() {});
          debugPrint('🎮 [Navigate] setState called');
        }
      },
    );
    debugPrint('🎮 [Navigate] Navigator.push called (navigation in progress)');
  }

  void _showExitDialog(BuildContext context, RankedProvider ranked) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('랭크전 나가기'),
        content: const Text('매칭을 취소하고 나가시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              ranked.cancelRankedMatch();
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }

  Color _tierC(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', '0xFF')));
    } catch (_) {
      return CandyColors.grape;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<RankedProvider, AuthProvider>(
      builder: (context, ranked, auth, child) {
        final canPop =
            ranked.matchStatus == RankedMatchStatus.idle ||
            ranked.matchStatus == RankedMatchStatus.finished;

        return PopScope(
          canPop: canPop,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _showExitDialog(context, ranked);
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('랭크전'),
              leading: canPop
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => _showExitDialog(context, ranked),
                    ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.leaderboard),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LeaderboardScreen(),
                      ),
                    );
                  },
                  tooltip: '리더보드',
                ),
              ],
            ),
            body: FloatingBackground(
              child: Builder(
                builder: (context) {
                  if (auth.userId == null) {
                    return _buildLoginRequired();
                  }

                  switch (ranked.matchStatus) {
                    case RankedMatchStatus.idle:
                      return _buildIdleState(ranked);
                    case RankedMatchStatus.searching:
                      return _buildSearchingState(ranked);
                    case RankedMatchStatus.found:
                      return _buildMatchFoundState(ranked);
                    case RankedMatchStatus.playing:
                      return _buildPlayingState(ranked, auth);
                    case RankedMatchStatus.waitingNextGame:
                      return _buildWaitingNextGameState(ranked, auth);
                    case RankedMatchStatus.finished:
                      return _buildFinishedState(ranked, auth);
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoginRequired() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: PopIn(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const DuoMascot(size: 110, mood: MascotMood.sad),
              const SizedBox(height: 16),
              CartoonCard(
                child: const Text(
                  '랭크전을 시작하려면\n로그인이 필요합니다',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdleState(RankedProvider ranked) {
    final stats = ranked.stats;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          PopIn(child: _buildRankCard(ranked, stats)),
          const SizedBox(height: 16),
          if (stats != null)
            PopIn(
              delay: const Duration(milliseconds: 100),
              child: _buildStatsCard(stats),
            ),
          const SizedBox(height: 20),
          PopIn(
            delay: const Duration(milliseconds: 200),
            child: _buildMatchButton(ranked),
          ),
          const SizedBox(height: 16),
          PopIn(
            delay: const Duration(milliseconds: 300),
            child: _buildRulesCard(),
          ),
        ],
      ),
    );
  }

  Widget _buildRankCard(RankedProvider ranked, RankedStats? stats) {
    if (stats == null) {
      return CartoonCard(
        child: const SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              DuoMascot(size: 80, mood: MascotMood.wink),
              SizedBox(height: 8),
              Text(
                '랭크 정보를 불러오는 중...',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: CandyColors.inkSoft,
                ),
              ),
              SizedBox(height: 12),
              CircularProgressIndicator(color: CandyColors.pink),
            ],
          ),
        ),
      );
    }

    final tc = _tierC(stats.tierColor);
    return CartoonCard(
      color: CandyColors.sun,
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            Row(
              children: [
                DuoMascot(size: 84, color: tc, mood: MascotMood.cheer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '나의 랭크',
                        style: TextStyle(
                          color: CandyColors.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: TierBadge(
                            tier: stats.tier,
                            tierColor: stats.tierColor,
                            elo: stats.elo,
                            size: 1.4,
                          ),
                        ),
                      ),
                      if (ranked.myRank != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: CandyColors.ink,
                              width: CandyTheme.outline - 0.5,
                            ),
                          ),
                          child: Text(
                            '전체 ${ranked.myRank}위',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: CandyColors.ink,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
              child: TierProgressBar(
                currentElo: stats.elo,
                currentTier: stats.tier,
                tierColor: stats.tierColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard(RankedStats stats) {
    return CartoonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '시즌 전적',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 16,
              color: CandyColors.ink,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildStatItem(
                  '승리',
                  stats.wins.toString(),
                  CandyColors.mint,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildStatItem(
                  '패배',
                  stats.losses.toString(),
                  CandyColors.pink,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildStatItem(
                  '승률',
                  '${stats.winRate}%',
                  CandyColors.sky,
                ),
              ),
            ],
          ),
          if (stats.winStreak > 0 || stats.maxWinStreak > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    '현재 연승',
                    stats.winStreak.toString(),
                    CandyColors.tangerine,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatItem(
                    '최대 연승',
                    stats.maxWinStreak.toString(),
                    CandyColors.grape,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CandyColors.ink, width: 2.5),
      ),
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: CandyColors.inkSoft,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMatchButton(RankedProvider ranked) {
    return ChunkyButton(
      onPressed: () => ranked.findRankedMatch(),
      icon: Icons.play_arrow_rounded,
      label: '랭크 매칭 시작',
      height: 64,
      fontSize: 20,
    );
  }

  Widget _buildRulesCard() {
    return CartoonCard(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.info_rounded, color: CandyColors.sky),
                SizedBox(width: 8),
                Text(
                  '게임 규칙',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: CandyColors.ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildRuleItem('Bo3 형식 (3판 2선승)'),
            _buildRuleItem('8개 게임 중 랜덤 3개 진행'),
            _buildRuleItem('틱택토/순서기억/스트룹은 하드코어 모드'),
            _buildRuleItem('ELO 기반 매칭 및 랭킹'),
          ],
        ),
      ),
    );
  }

  Widget _buildRuleItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: CandyColors.mintDeep,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: CandyColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchingState(RankedProvider ranked) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const DuoMascot(size: 130, mood: MascotMood.wink),
            const SizedBox(height: 20),
            const CircularProgressIndicator(color: CandyColors.pink),
            const SizedBox(height: 20),
            const Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'ELO 범위 내 상대를 매칭합니다',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: CandyColors.inkSoft,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 28),
            ChunkyButton(
              onPressed: () => ranked.cancelRankedMatch(),
              label: '매칭 취소',
              color: Colors.white,
              textColor: CandyColors.ink,
              height: 52,
              fontSize: 16,
              expand: false,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMatchFoundState(RankedProvider ranked) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const PopIn(child: DuoMascot(size: 100, mood: MascotMood.cheer)),
            const SizedBox(height: 8),
            const Text(
              '매칭 성공!',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
            const SizedBox(height: 20),
            if (ranked.players.length >= 2)
              Row(
                children: [
                  Expanded(
                    child: PopIn(
                      child: _buildPlayerCard(
                        ranked.players[0],
                        CandyColors.sky,
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'VS',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: CandyColors.pinkDeep,
                      ),
                    ),
                  ),
                  Expanded(
                    child: PopIn(
                      delay: const Duration(milliseconds: 150),
                      child: _buildPlayerCard(
                        ranked.players[1],
                        CandyColors.pink,
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 24),
            const Text(
              '진행할 게임',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: ranked.games.map((game) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: CandyColors.sun,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: CandyColors.ink, width: 2.5),
                  ),
                  child: Text(
                    ranked.getGameTypeName(game),
                    style: const TextStyle(
                      color: CandyColors.ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerCard(RankedPlayer player, Color color) {
    return CartoonCard(
      color: color.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            TierBadgeSmall(tier: player.tier, tierColor: player.tierColor),
            const SizedBox(height: 8),
            Text(
              player.nickname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
            Text(
              '${player.elo} LP',
              style: const TextStyle(
                color: CandyColors.inkSoft,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreBoard(RankedProvider ranked) {
    Widget cell(String v, Color c) => Expanded(
      child: CartoonCard(
        color: c,
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              v,
              style: const TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          cell('${ranked.score[0]}', CandyColors.sky),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              ':',
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
          ),
          cell('${ranked.score[1]}', CandyColors.pink),
        ],
      ),
    );
  }

  Widget _buildWaitingNextGameState(RankedProvider ranked, AuthProvider auth) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildScoreBoard(ranked),
            const SizedBox(height: 24),
            const DuoMascot(size: 90, mood: MascotMood.wink),
            const SizedBox(height: 12),
            const CircularProgressIndicator(color: CandyColors.pink),
            const SizedBox(height: 16),
            const Text(
              '다음 게임 준비 중...',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (index) {
                final isCompleted = index < ranked.results.length;
                final result = isCompleted ? ranked.results[index] : null;
                final myUserId = auth.userId;
                final didWin = result?.winnerId == myUserId;

                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 5),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isCompleted
                        ? (didWin ? CandyColors.mint : CandyColors.pink)
                        : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: CandyColors.ink, width: 2.5),
                  ),
                  child: Center(
                    child: isCompleted
                        ? Icon(
                            didWin ? Icons.check : Icons.close,
                            color: Colors.white,
                            size: 22,
                          )
                        : Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: CandyColors.inkSoft,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayingState(RankedProvider ranked, AuthProvider auth) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildScoreBoard(ranked),
            const SizedBox(height: 24),
            if (ranked.currentGame != null) ...[
              const Text(
                '현재 게임',
                style: TextStyle(
                  color: CandyColors.inkSoft,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  ranked.getGameTypeName(ranked.currentGame!),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
              ),
              if (ranked.isHardcore)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: CandyColors.pink,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: CandyColors.ink, width: 2.5),
                  ),
                  child: const Text(
                    '하드코어',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 24),
            const CircularProgressIndicator(color: CandyColors.pink),
            const SizedBox(height: 16),
            const Text(
              '게임 화면으로 이동 중...',
              style: TextStyle(
                color: CandyColors.inkSoft,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFinishedState(RankedProvider ranked, AuthProvider auth) {
    final isWinner = ranked.matchWinnerId == auth.userId;
    final myStats = isWinner ? ranked.winnerStats : ranked.loserStats;
    final myEloChange = isWinner
        ? ranked.winnerEloChange
        : ranked.loserEloChange;

    return Stack(
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PopIn(
                  child: DuoMascot(
                    size: 110,
                    color: isWinner ? CandyColors.pink : CandyColors.inkSoft,
                    mood: isWinner ? MascotMood.cheer : MascotMood.sad,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isWinner ? '승리!' : '패배',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    color: isWinner
                        ? CandyColors.mintDeep
                        : CandyColors.pinkDeep,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${ranked.matchWinnerNickname} 승리',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: CandyColors.inkSoft,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 20),
                if (myStats != null && myEloChange != null)
                  PopIn(
                    delay: const Duration(milliseconds: 200),
                    child: CartoonCard(
                      color: CandyColors.sun,
                      child: Column(
                        children: [
                          TierBadge(
                            tier: myStats.tier,
                            tierColor: myStats.tierColor,
                            elo: myStats.elo,
                          ),
                          const SizedBox(height: 12),
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: myEloChange.toDouble()),
                            duration: const Duration(milliseconds: 900),
                            curve: Curves.easeOutCubic,
                            builder: (context, v, _) {
                              final n = v.round();
                              return Text(
                                n >= 0 ? '+$n LP' : '$n LP',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w900,
                                  color: myEloChange >= 0
                                      ? CandyColors.mintDeep
                                      : CandyColors.pinkDeep,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: ranked.results.map((result) {
                    final didWin = result.winnerId == auth.userId;
                    final isDraw = result.winnerId == null;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isDraw
                            ? Colors.white
                            : didWin
                            ? CandyColors.mint.withValues(alpha: 0.4)
                            : CandyColors.pink.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: CandyColors.ink, width: 2.5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isDraw
                                ? Icons.remove
                                : didWin
                                ? Icons.check
                                : Icons.close,
                            size: 16,
                            color: CandyColors.ink,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              ranked.getGameTypeName(result.gameType),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: CandyColors.ink,
                                fontWeight: FontWeight.w900,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: ChunkyButton(
                        onPressed: () {
                          ranked.resetMatchState();
                          Navigator.pop(context);
                        },
                        label: '나가기',
                        color: Colors.white,
                        textColor: CandyColors.ink,
                        height: 54,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ChunkyButton(
                        onPressed: () {
                          ranked.resetMatchState();
                          _lastNavigatedGameIndex = null;
                          _isNavigating = false;
                          ranked.findRankedMatch();
                        },
                        label: '다시 하기',
                        height: 54,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (isWinner) const Positioned.fill(child: ConfettiBurst()),
      ],
    );
  }
}
