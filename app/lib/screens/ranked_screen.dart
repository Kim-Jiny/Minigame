import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ranked_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/game_provider.dart';
import '../widgets/tier_badge.dart';
import 'leaderboard_screen.dart';
import '../games/tictactoe/tictactoe_screen.dart';
import '../games/infinite_tictactoe/infinite_tictactoe_screen.dart';
import '../games/gomoku/gomoku_screen.dart';
import '../games/reaction/reaction_screen.dart';
import '../games/rps/rps_screen.dart';
import '../games/speedtap/speedtap_screen.dart';
import '../games/sequence/sequence_screen.dart';
import '../games/stroop/stroop_screen.dart';

class RankedScreen extends StatefulWidget {
  const RankedScreen({super.key});

  @override
  State<RankedScreen> createState() => _RankedScreenState();
}

class _RankedScreenState extends State<RankedScreen> {
  int? _lastNavigatedGameIndex;
  bool _isNavigating = false;
  bool _listenerAdded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 위젯이 이미 dispose 되었으면 무시
      if (!mounted) return;

      final ranked = context.read<RankedProvider>();
      ranked.initialize();
      ranked.getMyRank();

      // Provider 변경 리스너 추가
      ranked.addListener(_onRankedProviderChanged);
      _listenerAdded = true;
    });
  }

  @override
  void dispose() {
    // 리스너가 추가되었을 때만 제거
    if (_listenerAdded) {
      try {
        final ranked = context.read<RankedProvider>();
        ranked.removeListener(_onRankedProviderChanged);

        // finished 상태에서 나갈 때 상태 리셋
        if (ranked.matchStatus == RankedMatchStatus.finished) {
          ranked.resetMatchState();
        }
      } catch (_) {}
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
    debugPrint('🎮 [Listener] _lastNavigatedGameIndex=$_lastNavigatedGameIndex');
    debugPrint('🎮 [Listener] _isNavigating=$_isNavigating');
    debugPrint('🎮 [Listener] score=${ranked.score}');

    // waitingNextGame 상태에서는 네비게이션 상태 리셋 (다음 게임 네비게이션 가능하도록)
    // 중요: 여기서 리셋해야 ranked_game_start 이벤트 시 다음 게임으로 이동 가능
    if (ranked.matchStatus == RankedMatchStatus.waitingNextGame) {
      debugPrint('🎮 [Listener] waitingNextGame - resetting navigation state for next game');
      _isNavigating = false;
      // _lastNavigatedGameIndex는 유지하여 같은 게임 중복 네비게이션 방지
    }

    // playing 상태이고 게임이 있고 아직 해당 게임으로 이동하지 않았으면 네비게이션
    final shouldNavigate = ranked.matchStatus == RankedMatchStatus.playing &&
        ranked.currentGame != null &&
        _lastNavigatedGameIndex != ranked.currentGameIndex &&
        !_isNavigating;

    debugPrint('🎮 [Listener] shouldNavigate=$shouldNavigate');
    debugPrint('🎮 [Listener]   - matchStatus == playing: ${ranked.matchStatus == RankedMatchStatus.playing}');
    debugPrint('🎮 [Listener]   - currentGame != null: ${ranked.currentGame != null}');
    debugPrint('🎮 [Listener]   - lastNav != index: ${_lastNavigatedGameIndex != ranked.currentGameIndex}');
    debugPrint('🎮 [Listener]   - !isNavigating: ${!_isNavigating}');

    if (shouldNavigate) {
      debugPrint('🎮 [Listener] *** TRIGGERING NAVIGATION to ${ranked.currentGame} ***');
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
    debugPrint('🎮 [Navigate] _navigateToGameScreen called: gameType=$gameType, gameIndex=$gameIndex');
    debugPrint('🎮 [Navigate] Current state: _isNavigating=$_isNavigating, _lastNavigatedGameIndex=$_lastNavigatedGameIndex');

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

    debugPrint('🎮 [Navigate] ✅ Proceeding with navigation to $gameType (index: $gameIndex)');

    // GameProvider 초기화 및 상태 리셋
    final auth = context.read<AuthProvider>();
    final game = context.read<GameProvider>();
    debugPrint('🎮 [Navigate] auth.socketId=${auth.socketId}');
    debugPrint('🎮 [Navigate] GameProvider current status=${game.status}');

    // 중요: 이전 게임의 상태를 리셋하여 두 번째 게임이 올바르게 시작되도록 함
    game.reset();
    debugPrint('🎮 [Navigate] GameProvider reset called, status now=${game.status}');

    // 중요: 이전 게임 화면의 dispose()에서 off()를 호출해서 리스너가 제거되었을 수 있음
    // 소켓 리스너를 재등록
    game.ensureSocketListeners();
    debugPrint('🎮 [Navigate] GameProvider listeners re-registered');

    if (auth.socketId != null) {
      game.initialize(auth.socketId!);
      debugPrint('🎮 [Navigate] GameProvider initialized');
    } else {
      debugPrint('🎮 [Navigate] ⚠️ auth.socketId is null!');
    }

    Widget gameScreen;
    switch (gameType) {
      case 'tictactoe':
        gameScreen = const TicTacToeScreen(isRanked: true);
        break;
      case 'infinite_tictactoe':
        gameScreen = const InfiniteTicTacToeScreen(isRanked: true);
        break;
      case 'gomoku':
        gameScreen = const GomokuScreen(isRanked: true);
        break;
      case 'reaction':
        gameScreen = const ReactionScreen(isRanked: true);
        break;
      case 'rps':
        gameScreen = const RpsScreen(isRanked: true);
        break;
      case 'speedtap':
        gameScreen = const SpeedTapScreen(isRanked: true);
        break;
      case 'sequence':
        gameScreen = const SequenceScreen(isRanked: true);
        break;
      case 'stroop':
        gameScreen = const StroopScreen(isRanked: true);
        break;
      default:
        debugPrint('🎮 [Navigate] ❌ Unknown game type: $gameType');
        _isNavigating = false;
        return;
    }

    debugPrint('🎮 [Navigate] Calling Navigator.push for $gameType...');
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => gameScreen),
    ).then((_) {
      debugPrint('🎮 [Navigate] ✅ Game screen popped, index was $gameIndex');
      debugPrint('🎮 [Navigate] Resetting _isNavigating to false');
      _isNavigating = false;
      // setState로 UI 갱신
      if (mounted) {
        setState(() {});
        debugPrint('🎮 [Navigate] setState called');
      }
    });
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

  @override
  Widget build(BuildContext context) {
    return Consumer2<RankedProvider, AuthProvider>(
      builder: (context, ranked, auth, child) {
        final canPop = ranked.matchStatus == RankedMatchStatus.idle ||
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
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
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
                      MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
                    );
                  },
                  tooltip: '리더보드',
                ),
              ],
            ),
            body: Builder(
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
        );
      },
    );
  }

  Widget _buildLoginRequired() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              '랭크전을 시작하려면\n로그인이 필요합니다',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
            ),
          ],
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
          _buildRankCard(ranked, stats),
          const SizedBox(height: 16),
          if (stats != null) _buildStatsCard(stats),
          const SizedBox(height: 24),
          _buildMatchButton(ranked),
          const SizedBox(height: 16),
          _buildRulesCard(),
        ],
      ),
    );
  }

  Widget _buildRankCard(RankedProvider ranked, RankedStats? stats) {
    if (stats == null) {
      return Card(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(32),
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).primaryColor,
              Theme.of(context).primaryColor.withValues(alpha: 0.8),
            ],
          ),
        ),
        child: Column(
          children: [
            const Text('나의 랭크', style: TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 12),
            TierBadge(tier: stats.tier, tierColor: stats.tierColor, elo: stats.elo, size: 1.5),
            const SizedBox(height: 16),
            if (ranked.myRank != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '전체 ${ranked.myRank}위',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            const SizedBox(height: 16),
            TierProgressBar(currentElo: stats.elo, currentTier: stats.tier, tierColor: stats.tierColor),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard(RankedStats stats) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('시즌 전적', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem('승리', stats.wins.toString(), Colors.green),
                _buildStatItem('패배', stats.losses.toString(), Colors.red),
                _buildStatItem('승률', '${stats.winRate}%', Colors.blue),
              ],
            ),
            if (stats.winStreak > 0 || stats.maxWinStreak > 0) ...[
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem('현재 연승', stats.winStreak.toString(), Colors.orange),
                  _buildStatItem('최대 연승', stats.maxWinStreak.toString(), Colors.purple),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      ],
    );
  }

  Widget _buildMatchButton(RankedProvider ranked) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => ranked.findRankedMatch(),
        icon: const Icon(Icons.play_arrow),
        label: const Text('랭크 매칭 시작'),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildRulesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: Colors.grey.shade600),
                const SizedBox(width: 8),
                const Text('게임 규칙', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
          Icon(Icons.check_circle, size: 16, color: Colors.green.shade400),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: Colors.grey.shade700))),
        ],
      ),
    );
  }

  Widget _buildSearchingState(RankedProvider ranked) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          const Text('상대를 찾는 중...', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('ELO 범위 내 상대를 매칭합니다', style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 32),
          OutlinedButton(
            onPressed: () => ranked.cancelRankedMatch(),
            child: const Text('매칭 취소'),
          ),
        ],
      ),
    );
  }

  Widget _buildMatchFoundState(RankedProvider ranked) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.group, size: 64, color: Colors.green),
            const SizedBox(height: 16),
            const Text('매칭 성공!', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            if (ranked.players.length >= 2)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildPlayerCard(ranked.players[0]),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('VS', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.red)),
                  ),
                  _buildPlayerCard(ranked.players[1]),
                ],
              ),
            const SizedBox(height: 24),
            const Text('진행할 게임', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: ranked.games.map((game) {
                return Chip(
                  label: Text(ranked.getGameTypeName(game)),
                  backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerCard(RankedPlayer player) {
    return Column(
      children: [
        TierBadgeSmall(tier: player.tier, tierColor: player.tierColor),
        const SizedBox(height: 8),
        Text(player.nickname, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('${player.elo} LP', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      ],
    );
  }

  Widget _buildWaitingNextGameState(RankedProvider ranked, AuthProvider auth) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${ranked.score[0]}', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.blue)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(':', style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
                ),
                Text('${ranked.score[1]}', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.red)),
              ],
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('다음 게임 준비 중...', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (index) {
                final isCompleted = index < ranked.results.length;
                final result = isCompleted ? ranked.results[index] : null;
                final myUserId = auth.userId;
                final didWin = result?.winnerId == myUserId;

                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isCompleted ? (didWin ? Colors.green : Colors.red) : Colors.grey.shade300,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: isCompleted
                        ? Icon(didWin ? Icons.check : Icons.close, color: Colors.white, size: 20)
                        : Text('${index + 1}', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
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
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${ranked.score[0]}', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.blue)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(':', style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
                ),
                Text('${ranked.score[1]}', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.red)),
              ],
            ),
            const SizedBox(height: 24),
            if (ranked.currentGame != null) ...[
              const Text('현재 게임', style: TextStyle(color: Colors.grey)),
              Text(ranked.getGameTypeName(ranked.currentGame!), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              if (ranked.isHardcore)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red),
                  ),
                  child: const Text('하드코어', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
            ],
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('게임 화면으로 이동 중...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildFinishedState(RankedProvider ranked, AuthProvider auth) {
    final isWinner = ranked.matchWinnerId == auth.userId;
    final myStats = isWinner ? ranked.winnerStats : ranked.loserStats;
    final myEloChange = isWinner ? ranked.winnerEloChange : ranked.loserEloChange;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isWinner ? Icons.emoji_events : Icons.sentiment_dissatisfied,
              size: 80,
              color: isWinner ? Colors.amber : Colors.grey,
            ),
            const SizedBox(height: 16),
            Text(
              isWinner ? '승리!' : '패배',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: isWinner ? Colors.green : Colors.red),
            ),
            const SizedBox(height: 8),
            Text('${ranked.matchWinnerNickname} 승리', style: TextStyle(color: Colors.grey.shade600)),
            const SizedBox(height: 24),
            if (myStats != null && myEloChange != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      TierBadge(tier: myStats.tier, tierColor: myStats.tierColor, elo: myStats.elo),
                      const SizedBox(height: 12),
                      Text(
                        myEloChange >= 0 ? '+$myEloChange LP' : '$myEloChange LP',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: myEloChange >= 0 ? Colors.green : Colors.red),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ranked.results.map((result) {
                final didWin = result.winnerId == auth.userId;
                final isDraw = result.winnerId == null;
                return Chip(
                  avatar: Icon(
                    isDraw ? Icons.remove : didWin ? Icons.check : Icons.close,
                    size: 16,
                    color: isDraw ? Colors.grey : didWin ? Colors.green : Colors.red,
                  ),
                  label: Text(ranked.getGameTypeName(result.gameType)),
                  backgroundColor: isDraw ? Colors.grey.shade200 : didWin ? Colors.green.shade100 : Colors.red.shade100,
                );
              }).toList(),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () {
                    ranked.resetMatchState();
                    Navigator.pop(context);
                  },
                  child: const Text('나가기'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: () {
                    ranked.resetMatchState();
                    _lastNavigatedGameIndex = null;
                    _isNavigating = false;
                    ranked.findRankedMatch();
                  },
                  child: const Text('다시 하기'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
