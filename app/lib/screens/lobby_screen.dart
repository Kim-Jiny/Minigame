import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/friend_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/game_provider.dart';
import '../services/remote_config_service.dart';
import '../services/socket_service.dart';
import '../games/common/game_screen_transition.dart';
import '../utils/game_catalog.dart';
import '../utils/game_registry.dart';
import '../widgets/invitation_dialog.dart';
import 'friends_screen.dart';
import 'profile_screen.dart';
import 'maintenance_screen.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/my_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';
import 'ranked_screen.dart';
import '../widgets/game_launch_sheet.dart';

class _LobbyNoticeStyle {
  final Color color;
  final IconData icon;

  const _LobbyNoticeStyle(this.color, this.icon);
}

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  static const _quickStartGames = {
    'tictactoe', 'gomoku', 'rps', 'reaction',
    'speedtap', 'numberbattle', 'mathrace', 'arrowdash',
    'stroop', 'sequence', 'timing', 'cardflip', 'infinite_tictactoe',
  };

  int _currentIndex = 0;
  GameEntryMode _mode = GameEntryMode.versus;
  String? _lastProcessedInvitationRoomId; // 중복 초대 게임 처리 방지
  int? _openInvitationDialogId;
  RemoteConfigService? _configService;
  FriendProvider? _friendProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();

      // GameProvider도 미리 초기화 (초대 게임 이벤트를 놓치지 않도록)
      if (auth.socketId != null) {
        context.read<GameProvider>().initialize(auth.socketId!);
      }
      _setupInvitationListener();
      _setupConfigChangeListener();
    });
  }

  void _setupConfigChangeListener() {
    // 원격 설정 변경 감지하여 소켓 재연결
    _configService = context.read<RemoteConfigService>();
    _configService!.addListener(_onConfigChanged);
  }

  void _onConfigChanged() {
    // 서버 URL 변경 시 소켓 재연결
    SocketService().checkAndReconnect();
  }

  @override
  void dispose() {
    // 설정 변경 리스너 제거
    _configService?.removeListener(_onConfigChanged);
    // 콜백 정리 (메모리 릭 방지)
    if (_friendProvider != null) {
      _friendProvider!.onInvitationReceived = null;
      _friendProvider!.onInvitationExpired = null;
      _friendProvider!.onInviteFailed = null;
      _friendProvider!.onGameStart = null;
    }
    super.dispose();
  }

  void _setupInvitationListener() {
    _friendProvider = context.read<FriendProvider>();
    final friendProvider = _friendProvider!;

    // 초대 받았을 때
    friendProvider.onInvitationReceived = (invitation) {
      if (mounted && _openInvitationDialogId != invitation.id) {
        _openInvitationDialogId = invitation.id;
        showInvitationDialog(
          context,
          invitation,
          () {
            friendProvider.acceptInvitation(invitation.id);
          },
          () {
            friendProvider.declineInvitation(invitation.id);
          },
        ).whenComplete(() {
          if (mounted && _openInvitationDialogId == invitation.id) {
            _openInvitationDialogId = null;
          }
        });
      }
    };

    // 초대 만료
    friendProvider.onInvitationExpired = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.orange),
        );
      }
    };

    // 초대 실패 (오프라인, 게임 중 등)
    friendProvider.onInviteFailed = (message, reason) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: reason == 'busy' ? Colors.orange : Colors.red,
          ),
        );
      }
    };

    // 게임 시작 (초대 수락 후)
    friendProvider.onGameStart = (gameType, roomId, gameState, shouldNavigate) {
      debugPrint(
        '🎮 onGameStart: gameType=$gameType, roomId=$roomId, shouldNavigate=$shouldNavigate, mounted=$mounted',
      );

      // 중복 처리 방지: 같은 roomId로 이미 처리된 경우 스킵
      if (_lastProcessedInvitationRoomId == roomId) {
        debugPrint('🎮 onGameStart: 이미 처리된 roomId, 스킵');
        return;
      }
      _lastProcessedInvitationRoomId = roomId;

      if (mounted) {
        final gameProvider = context.read<GameProvider>();

        // 이미 게임이 진행 중이면 스킵 (중복 이벤트 처리 방지)
        if (gameProvider.roomId == roomId &&
            gameProvider.status == GameStatus.playing) {
          debugPrint('🎮 onGameStart: 이미 해당 roomId로 게임 진행 중, 스킵');
          return;
        }

        // 턴제 게임인 경우만 initializeInvitationGame 호출 (currentTurn, board 필요)
        final isBoardGame = GameCatalog.isBoardGame(gameType);

        if (gameState != null && isBoardGame) {
          final currentTurn = gameState['currentTurn'] as String?;
          final board = gameState['board'] as List<dynamic>?;

          if (currentTurn != null && board != null) {
            gameProvider.initializeInvitationGame(
              roomId: roomId,
              players: gameState['players'] as List<dynamic>,
              currentTurn: currentTurn,
              board: board,
              turnTimeLimit: gameState['turnTimeLimit'] as int?,
              turnStartTime: gameState['turnStartTime'] as int?,
            );
          } else {
            debugPrint(
              '🎮 onGameStart: currentTurn or board is null, skipping initializeInvitationGame',
            );
          }
        } else if (gameState != null && !isBoardGame) {
          // 비보드 게임의 경우: roomId와 기본 정보만 설정
          gameProvider.initializeNonBoardInvitationGame(
            roomId: roomId,
            players: gameState['players'] as List<dynamic>,
          );
        }

        // 초대자는 이미 게임 화면에 있으므로 네비게이션 스킵
        if (shouldNavigate) {
          Navigator.pushNamed(context, GameCatalog.routeFor(gameType));
        }
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<RemoteConfigService, FriendProvider>(
      builder: (context, configService, friendProvider, child) {
        // 점검 모드 확인
        if (configService.isUnderMaintenance) {
          return MaintenanceScreen(
            configService: configService,
            onRetry: () => configService.refresh(),
          );
        }

        final unreadCount = friendProvider.totalUnreadCount;
        debugPrint('🔔 LobbyScreen build: unreadCount = $unreadCount');

        return Scaffold(
          appBar: AppBar(
            title: Text(
              _currentIndex == 0
                  ? '듀오 아레나'
                  : _currentIndex == 1
                  ? '친구'
                  : '프로필',
            ),
            shape: const Border(
              bottom: BorderSide(
                color: CandyColors.ink,
                width: CandyTheme.outline,
              ),
            ),
          ),
          body: Consumer<GameProvider>(
            builder: (context, gameProvider, child) {
              final showFullNotice =
                  gameProvider.hasLobbyNotice && _currentIndex == 0;
              final showCompactNotice =
                  gameProvider.hasLobbyNotice && _currentIndex != 0;
              return Column(
                children: [
                  if (showFullNotice)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: _buildLobbyNoticeCard(gameProvider),
                    ),
                  if (showCompactNotice)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: _buildCompactLobbyNoticeBar(gameProvider),
                    ),
                  Expanded(
                    child: GameScreenTransition(
                      transitionKey: _currentIndex,
                      beginOffset: const Offset(0.02, 0),
                      child: _buildBody(),
                    ),
                  ),
                ],
              );
            },
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            type: BottomNavigationBarType.fixed,
            backgroundColor: Colors.white,
            selectedItemColor: CandyColors.pink,
            unselectedItemColor: CandyColors.inkSoft,
            selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w900),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
            items: [
              const BottomNavigationBarItem(
                icon: Icon(Icons.sports_esports_outlined),
                activeIcon: Icon(Icons.sports_esports),
                label: '게임',
              ),
              BottomNavigationBarItem(
                icon: Badge(
                  isLabelVisible: unreadCount > 0,
                  label: Text(
                    unreadCount > 99 ? '99+' : unreadCount.toString(),
                    style: const TextStyle(fontSize: 10),
                  ),
                  child: const Icon(Icons.people_outline),
                ),
                activeIcon: Badge(
                  isLabelVisible: unreadCount > 0,
                  label: Text(
                    unreadCount > 99 ? '99+' : unreadCount.toString(),
                    style: const TextStyle(fontSize: 10),
                  ),
                  child: const Icon(Icons.people),
                ),
                label: '친구',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.person_outline),
                activeIcon: Icon(Icons.person),
                label: '프로필',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    switch (_currentIndex) {
      case 0:
        return _buildGamesTab();
      case 1:
        return const FriendsScreen();
      case 2:
        return const ProfileScreen();
      default:
        return _buildGamesTab();
    }
  }

  Widget _buildGamesTab() {
    final auth = context.watch<AuthProvider>();
    final games = GameRegistry.forEntry(_mode);
    return FloatingBackground(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final horizontalPadding = width >= 720 ? 24.0 : 20.0;
          final contentMaxWidth = width >= 720 ? 640.0 : double.infinity;

          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  20,
                  horizontalPadding,
                  28 + MediaQuery.of(context).padding.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildGreeting(auth.nickname ?? '플레이어'),
                    const SizedBox(height: 18),
                    PopIn(
                      delay: const Duration(milliseconds: 120),
                      child: _buildQuickStart(),
                    ),
                    const SizedBox(height: 18),
                    _buildModeToggle(),
                    if (_mode == GameEntryMode.versus) ...[
                      const SizedBox(height: 14),
                      _buildRankedCard(),
                    ],
                    const SizedBox(height: 16),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: games.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 14,
                            crossAxisSpacing: 14,
                            childAspectRatio: 1.08,
                          ),
                      itemBuilder: (_, i) => PopIn(
                        delay: Duration(milliseconds: 40 * i),
                        child: _buildGameTile(games[i]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 아무 대전 게임이나 골라 바로 매칭을 시작한다.
  Widget _buildQuickStart() {
    return CartoonCard(
      color: CandyColors.pink,
      radius: 26,
      padding: const EdgeInsets.all(18),
      onTap: () {
        // 상대가 바로 잡히도록 매칭 봇이 지원하는 게임만 후보로 한다.
        // 서버 botService.ts 의 SUPPORTED_GAMES 와 같게 유지할 것.
        final pool = GameRegistry.forEntry(GameEntryMode.versus)
            .where((g) => _quickStartGames.contains(g.id))
            .toList();
        final game = pool[math.Random().nextInt(pool.length)];
        openGame(context, game, GameEntryMode.versus, autoStart: true);
      },
      child: const Row(
        children: [
          Icon(Icons.bolt_rounded, color: Colors.white, size: 40),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '빠른 시작',
                  style: TextStyle(
                    fontFamily: CandyTheme.displayFont,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '아무 게임이나 바로 매칭!',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 34),
        ],
      ),
    );
  }

  Widget _buildModeToggle() {
    Widget seg(GameEntryMode m) {
      final selected = _mode == m;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_mode != m) setState(() => _mode = m);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: selected ? m.color : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: selected
                  ? Border.all(color: CandyColors.ink, width: 2.5)
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  m.icon,
                  size: 20,
                  color: selected ? Colors.white : CandyColors.inkSoft,
                ),
                const SizedBox(width: 6),
                Text(
                  m == GameEntryMode.versus ? '대전' : '혼자',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: selected ? Colors.white : CandyColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return CartoonCard(
      radius: 20,
      shadow: 3,
      padding: const EdgeInsets.all(5),
      child: Row(
        children: [seg(GameEntryMode.versus), seg(GameEntryMode.solo)],
      ),
    );
  }

  Widget _buildRankedCard() {
    return CartoonCard(
      color: CandyColors.tangerine,
      radius: 22,
      shadow: 4,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RankedScreen()),
      ),
      child: const Row(
        children: [
          Icon(Icons.emoji_events_rounded, color: Colors.white, size: 30),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              '랭크전 · Bo3 ELO 매칭',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          Icon(Icons.arrow_forward_rounded, color: Colors.white),
        ],
      ),
    );
  }

  Widget _buildGameTile(GameMeta game) {
    return CartoonCard(
      radius: 22,
      shadow: 4,
      padding: const EdgeInsets.all(12),
      onTap: () => showGameLaunchSheet(context, game, _mode),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: game.color,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: CandyColors.ink, width: 2.5),
            ),
            child: Icon(game.icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 8),
          Text(
            game.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            game.tempo.duration,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: CandyColors.inkSoft,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGreeting(String nickname) {
    return Row(
      children: [
        const MyMascot(size: 84, mood: MascotMood.cheer),
        const SizedBox(width: 12),
        Expanded(
          child: CartoonCard(
            color: Colors.white,
            radius: 22,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$nickname님!',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: CandyTheme.displayFont,
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  '오늘은 뭐하고 놀까요?',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: CandyColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLobbyNoticeCard(GameProvider gameProvider) {
    final style = switch (gameProvider.lobbyNoticeTone) {
      LobbyNoticeTone.success => const _LobbyNoticeStyle(
        Color(0xFF16A34A),
        Icons.check_circle_rounded,
      ),
      LobbyNoticeTone.warning => const _LobbyNoticeStyle(
        Color(0xFFEA580C),
        Icons.info_rounded,
      ),
      LobbyNoticeTone.info => const _LobbyNoticeStyle(
        Color(0xFF2563EB),
        Icons.notifications_active_rounded,
      ),
    };

    return Dismissible(
      key: const ValueKey('lobby_notice'),
      direction: DismissDirection.up,
      onDismissed: (_) => context.read<GameProvider>().clearLobbyNotice(),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: style.color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: style.color.withValues(alpha: 0.18)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: style.color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(style.icon, color: style.color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    gameProvider.lobbyNoticeTitle ?? '안내',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: style.color,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    gameProvider.lobbyNoticeMessage ?? '',
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: Color(0xFF374151),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => context.read<GameProvider>().clearLobbyNotice(),
              icon: const Icon(Icons.close_rounded),
              color: Colors.grey.shade600,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactLobbyNoticeBar(GameProvider gameProvider) {
    final style = switch (gameProvider.lobbyNoticeTone) {
      LobbyNoticeTone.success => const _LobbyNoticeStyle(
        Color(0xFF16A34A),
        Icons.check_circle_rounded,
      ),
      LobbyNoticeTone.warning => const _LobbyNoticeStyle(
        Color(0xFFEA580C),
        Icons.info_rounded,
      ),
      LobbyNoticeTone.info => const _LobbyNoticeStyle(
        Color(0xFF2563EB),
        Icons.notifications_active_rounded,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: style.color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(style.icon, color: style.color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              gameProvider.lobbyNoticeTitle ?? '안내',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: style.color,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _currentIndex = 0),
            child: const Text('게임 탭에서 보기'),
          ),
        ],
      ),
    );
  }
}
