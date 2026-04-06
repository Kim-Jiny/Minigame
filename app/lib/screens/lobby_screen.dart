import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/friend_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/game_provider.dart';
import '../services/remote_config_service.dart';
import '../services/socket_service.dart';
import '../games/common/game_screen_transition.dart';
import '../utils/game_catalog.dart';
import '../widgets/invitation_dialog.dart';
import 'friends_screen.dart';
import 'profile_screen.dart';
import 'maintenance_screen.dart';
import 'ranked_screen.dart';

class _LobbyGameEntry {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String route;
  final String? badge;

  const _LobbyGameEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.route,
    this.badge,
  });
}

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
  static const List<_LobbyGameEntry> _quickGames = [
    _LobbyGameEntry(
      title: '틱택토',
      subtitle: '3연속',
      icon: Icons.grid_3x3,
      color: Color(0xFF6C5CE7),
      route: '/game/tictactoe',
    ),
    _LobbyGameEntry(
      title: '반응속도',
      subtitle: '터치!',
      icon: Icons.flash_on,
      color: Color(0xFFE17055),
      route: '/game/reaction',
    ),
    _LobbyGameEntry(
      title: '가위바위보',
      subtitle: '3판2선',
      icon: Icons.front_hand,
      color: Color(0xFF9B59B6),
      route: '/game/rps',
    ),
    _LobbyGameEntry(
      title: '스피드탭',
      subtitle: '빠르게!',
      icon: Icons.touch_app,
      color: Color(0xFF00CEC9),
      route: '/game/speedtap',
    ),
    _LobbyGameEntry(
      title: '순서 기억',
      subtitle: '기억력!',
      icon: Icons.psychology,
      color: Color(0xFFE056FD),
      route: '/game/sequence',
    ),
    _LobbyGameEntry(
      title: '스트룹',
      subtitle: '색깔!',
      icon: Icons.palette,
      color: Color(0xFF00CEC9),
      route: '/game/stroop',
    ),
    _LobbyGameEntry(
      title: '숫자배틀',
      subtitle: '1→25!',
      icon: Icons.grid_on,
      color: Color(0xFFFF6B6B),
      route: '/game/numberbattle',
    ),
    _LobbyGameEntry(
      title: '사칙연산',
      subtitle: '스피드!',
      icon: Icons.calculate,
      color: Color(0xFFE74C3C),
      route: '/game/mathrace',
    ),
  ];

  static const List<_LobbyGameEntry> _featuredGames = [
    _LobbyGameEntry(
      title: '오목',
      subtitle: '5개를 연속으로 놓으면 승리',
      icon: Icons.circle_outlined,
      color: Color(0xFF636E72),
      route: '/game/gomoku',
    ),
    _LobbyGameEntry(
      title: '헥사곤',
      subtitle: '숫자를 외우고 합을 맞춰라!',
      icon: Icons.hexagon_outlined,
      color: Color(0xFF2D3436),
      route: '/game/hexagon',
      badge: '1인 가능',
    ),
    _LobbyGameEntry(
      title: '수식피라미드',
      subtitle: '카드를 골라 목표 숫자를 맞춰라!',
      icon: Icons.change_history,
      color: Color(0xFFE67E22),
      route: '/game/pyramid',
      badge: '1인 가능',
    ),
    _LobbyGameEntry(
      title: '훈민정음',
      subtitle: '초성 단어 배틀! 3판 2선승',
      icon: Icons.translate,
      color: Color(0xFF1E88E5),
      route: '/game/hunmin',
    ),
    _LobbyGameEntry(
      title: '카드 뒤집기',
      subtitle: '짝 맞추기! 기억력 대결',
      icon: Icons.style,
      color: Color(0xFF6C5CE7),
      route: '/game/cardflip',
    ),
  ];

  int _currentIndex = 0;
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
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.orange,
          ),
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
      debugPrint('🎮 onGameStart: gameType=$gameType, roomId=$roomId, shouldNavigate=$shouldNavigate, mounted=$mounted');

      // 중복 처리 방지: 같은 roomId로 이미 처리된 경우 스킵
      if (_lastProcessedInvitationRoomId == roomId) {
        debugPrint('🎮 onGameStart: 이미 처리된 roomId, 스킵');
        return;
      }
      _lastProcessedInvitationRoomId = roomId;

      if (mounted) {
        final gameProvider = context.read<GameProvider>();

        // 이미 게임이 진행 중이면 스킵 (중복 이벤트 처리 방지)
        if (gameProvider.roomId == roomId && gameProvider.status == GameStatus.playing) {
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
            debugPrint('🎮 onGameStart: currentTurn or board is null, skipping initializeInvitationGame');
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
            title: Text(_currentIndex == 0 ? '듀오아레나' : _currentIndex == 1 ? '친구' : '프로필'),
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          body: Consumer<GameProvider>(
            builder: (context, gameProvider, child) {
              final showFullNotice = gameProvider.hasLobbyNotice && _currentIndex == 0;
              final showCompactNotice = gameProvider.hasLobbyNotice && _currentIndex != 0;
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
            selectedItemColor: Theme.of(context).primaryColor,
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
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Theme.of(context).primaryColor.withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final horizontalPadding = width >= 900 ? 24.0 : 16.0;
          final contentMaxWidth = width >= 1300 ? 1180.0 : double.infinity;
          final quickColumns = _getQuickGameColumns(width);
          final quickGameAspectRatio = _getQuickGameAspectRatio(width);

          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  16,
                  horizontalPadding,
                  24 + MediaQuery.of(context).padding.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeroCard(context, auth.nickname ?? '플레이어'),
                    const SizedBox(height: 18),
                    _buildRankedCard(context),
                    const SizedBox(height: 20),
                    _buildSectionHeader(
                      icon: Icons.bolt,
                      title: '빠른 게임',
                      subtitle: '1~3분',
                      color: Colors.orange,
                    ),
                    const SizedBox(height: 8),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: quickColumns,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: quickGameAspectRatio,
                      children: _quickGames
                          .map((game) => _buildGameCard(
                                context,
                                title: game.title,
                                subtitle: game.subtitle,
                                icon: game.icon,
                                color: game.color,
                                route: game.route,
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 20),
                    _buildSectionHeader(
                      icon: Icons.psychology_alt,
                      title: '전략 게임',
                      subtitle: '10~20분',
                      color: const Color(0xFF636E72),
                    ),
                    const SizedBox(height: 8),
                    _buildLargeGameCard(
                      context,
                      title: _featuredGames[0].title,
                      subtitle: _featuredGames[0].subtitle,
                      icon: _featuredGames[0].icon,
                      color: _featuredGames[0].color,
                      route: _featuredGames[0].route,
                    ),
                    const SizedBox(height: 20),
                    _buildSectionHeader(
                      icon: Icons.extension,
                      title: '두뇌 게임',
                      subtitle: '5~15분',
                      color: const Color(0xFF2D3436),
                    ),
                    const SizedBox(height: 8),
                    _buildLargeGameCard(
                      context,
                      title: _featuredGames[1].title,
                      subtitle: _featuredGames[1].subtitle,
                      icon: _featuredGames[1].icon,
                      color: _featuredGames[1].color,
                      route: _featuredGames[1].route,
                      badge: _featuredGames[1].badge,
                    ),
                    const SizedBox(height: 8),
                    _buildLargeGameCard(
                      context,
                      title: _featuredGames[2].title,
                      subtitle: _featuredGames[2].subtitle,
                      icon: _featuredGames[2].icon,
                      color: _featuredGames[2].color,
                      route: _featuredGames[2].route,
                      badge: _featuredGames[2].badge,
                    ),
                    const SizedBox(height: 8),
                    _buildLargeGameCard(
                      context,
                      title: _featuredGames[4].title,
                      subtitle: _featuredGames[4].subtitle,
                      icon: _featuredGames[4].icon,
                      color: _featuredGames[4].color,
                      route: _featuredGames[4].route,
                    ),
                    const SizedBox(height: 20),
                    _buildSectionHeader(
                      icon: Icons.translate,
                      title: '단어 게임',
                      subtitle: '3~5분',
                      color: const Color(0xFF1E88E5),
                    ),
                    const SizedBox(height: 8),
                    _buildLargeGameCard(
                      context,
                      title: _featuredGames[3].title,
                      subtitle: _featuredGames[3].subtitle,
                      icon: _featuredGames[3].icon,
                      color: _featuredGames[3].color,
                      route: _featuredGames[3].route,
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

  Widget _buildLobbyNoticeCard(GameProvider gameProvider) {
    final style = switch (gameProvider.lobbyNoticeTone) {
      LobbyNoticeTone.success => const _LobbyNoticeStyle(Color(0xFF16A34A), Icons.check_circle_rounded),
      LobbyNoticeTone.warning => const _LobbyNoticeStyle(Color(0xFFEA580C), Icons.info_rounded),
      LobbyNoticeTone.info => const _LobbyNoticeStyle(Color(0xFF2563EB), Icons.notifications_active_rounded),
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
      LobbyNoticeTone.success => const _LobbyNoticeStyle(Color(0xFF16A34A), Icons.check_circle_rounded),
      LobbyNoticeTone.warning => const _LobbyNoticeStyle(Color(0xFFEA580C), Icons.info_rounded),
      LobbyNoticeTone.info => const _LobbyNoticeStyle(Color(0xFF2563EB), Icons.notifications_active_rounded),
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

  int _getQuickGameColumns(double width) {
    if (width >= 1200) return 5;
    if (width >= 900) return 4;
    if (width >= 700) return 3;
    return 2;
  }

  double _getQuickGameAspectRatio(double width) {
    if (width >= 1200) return 1.08;
    if (width >= 900) return 1.0;
    if (width >= 700) return 0.92;
    return 1.02;
  }

  Widget _buildHeroCard(BuildContext context, String nickname) {
    final primary = Theme.of(context).primaryColor;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primary,
            primary.withValues(alpha: 0.84),
            const Color(0xFF111827),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.22),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bolt_rounded, color: Colors.white, size: 16),
                    SizedBox(width: 6),
                    Text(
                      '실시간 듀얼 아레나',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                child: Text(
                  '빠른 게임 ${_quickGames.length}개',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            '$nickname님, 바로 한 판 어때요?',
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '짧고 강한 실시간 대결부터 천천히 생각하는 전략 게임까지, 지금 분위기에 맞는 모드를 골라 시작할 수 있어요.',
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: Colors.white.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: const [
              _HeroMetric(label: '빠른 게임', value: '1~3분'),
              _HeroMetric(label: '전략 게임', value: '10~20분'),
              _HeroMetric(label: '1인 플레이', value: '2개 지원'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRankedCard(BuildContext context) {
    return _buildPromoCard(
      title: '랭크전',
      subtitle: 'Bo3 | ELO 기반 매칭',
      icon: Icons.emoji_events_rounded,
      color: const Color(0xFFEA580C),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const RankedScreen()),
        );
      },
    );
  }

  Widget _buildPromoCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          height: 110,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color,
                color.withValues(alpha: 0.86),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGameCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    String? route,
    bool enabled = true,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled && route != null ? () => _openRoute(route) : null,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: enabled
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      color,
                      color.withValues(alpha: 0.86),
                    ],
                  )
                : null,
            color: enabled ? null : const Color(0xFFF3F4F6),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.2),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              if (enabled) ...[
                Positioned(
                  right: -12,
                  top: -12,
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  bottom: 14,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: enabled
                            ? Colors.white.withValues(alpha: 0.18)
                            : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        icon,
                        size: 24,
                        color: enabled ? Colors.white : Colors.grey,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: enabled ? Colors.white : Colors.grey.shade700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? Colors.white.withValues(alpha: 0.8)
                            : Colors.grey.shade500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text(
                          enabled ? '바로 시작' : '준비 중',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: enabled
                                ? Colors.white.withValues(alpha: 0.9)
                                : Colors.grey.shade500,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          Icons.arrow_outward_rounded,
                          size: 16,
                          color: enabled
                              ? Colors.white.withValues(alpha: 0.9)
                              : Colors.grey.shade500,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openRoute(String route) {
    Navigator.pushNamed(context, route);
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade900,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Text(
            '추천',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLargeGameCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    String? route,
    String? badge,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: route != null ? () => _openRoute(route) : null,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color,
                color.withValues(alpha: 0.88),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.2),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(
                  icon,
                  size: 30,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        if (badge != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                            ),
                            child: Text(
                              badge,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.82),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  final String label;
  final String value;

  const _HeroMetric({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
