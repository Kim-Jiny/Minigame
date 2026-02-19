import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/friend_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/game_provider.dart';
import '../providers/stats_provider.dart';
import '../services/remote_config_service.dart';
import '../services/socket_service.dart';
import '../widgets/invitation_dialog.dart';
import 'friends_screen.dart';
import 'profile_screen.dart';
import 'maintenance_screen.dart';
import 'ranked_screen.dart';

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  int _currentIndex = 0;
  String? _lastProcessedInvitationRoomId; // 중복 초대 게임 처리 방지

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Provider 초기화
      final auth = context.read<AuthProvider>();
      context.read<FriendProvider>().initialize();
      context.read<StatsProvider>().initialize();
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
    final configService = context.read<RemoteConfigService>();
    configService.addListener(_onConfigChanged);
  }

  void _onConfigChanged() {
    // 서버 URL 변경 시 소켓 재연결
    SocketService().checkAndReconnect();
  }

  @override
  void dispose() {
    // 설정 변경 리스너 제거
    context.read<RemoteConfigService>().removeListener(_onConfigChanged);
    super.dispose();
  }

  void _setupInvitationListener() {
    final friendProvider = context.read<FriendProvider>();

    // 초대 받았을 때
    friendProvider.onInvitationReceived = (invitation) {
      if (mounted) {
        showInvitationDialog(
          context,
          invitation,
          () {
            friendProvider.acceptInvitation(invitation.id);
          },
          () {
            friendProvider.declineInvitation(invitation.id);
          },
        );
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
        final isBoardGame = gameType == 'tictactoe' ||
                            gameType == 'infinite_tictactoe' ||
                            gameType == 'gomoku';

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
          String route = '/game/$gameType';
          if (gameType == 'infinite_tictactoe') {
            route = '/game/infinite_tictactoe';
          } else if (gameType == 'tictactoe') {
            route = '/game/tictactoe';
          } else if (gameType == 'gomoku') {
            route = '/game/gomoku';
          } else if (gameType == 'reaction') {
            route = '/game/reaction';
          } else if (gameType == 'rps') {
            route = '/game/rps';
          } else if (gameType == 'speedtap') {
            route = '/game/speedtap';
          } else if (gameType == 'sequence') {
            route = '/game/sequence';
          } else if (gameType == 'stroop') {
            route = '/game/stroop';
          } else if (gameType == 'hexagon') {
            route = '/game/hexagon';
          }
          Navigator.pushNamed(context, route);
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
          body: _buildBody(),
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
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 환영 메시지
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.sports_esports,
                      color: Theme.of(context).primaryColor,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '함께 즐겨요!',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '친구와 함께 재미있는 게임을 해보세요',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 랭크전 버튼
            _buildRankedCard(context),
            const SizedBox(height: 16),

            // 게임 목록
            Expanded(
              child: ListView(
                children: [
                  // 빠른 게임 섹션
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
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.85,
                    children: [
                      _buildGameCard(
                        context,
                        title: '틱택토',
                        subtitle: '3연속',
                        icon: Icons.grid_3x3,
                        color: const Color(0xFF6C5CE7),
                        route: '/game/tictactoe',
                      ),
                      _buildGameCard(
                        context,
                        title: '반응속도',
                        subtitle: '터치!',
                        icon: Icons.flash_on,
                        color: const Color(0xFFE17055),
                        route: '/game/reaction',
                      ),
                      _buildGameCard(
                        context,
                        title: '가위바위보',
                        subtitle: '3판2선',
                        icon: Icons.front_hand,
                        color: const Color(0xFF9B59B6),
                        route: '/game/rps',
                      ),
                      _buildGameCard(
                        context,
                        title: '스피드탭',
                        subtitle: '빠르게!',
                        icon: Icons.touch_app,
                        color: const Color(0xFF00CEC9),
                        route: '/game/speedtap',
                      ),
                      _buildGameCard(
                        context,
                        title: '순서 기억',
                        subtitle: '기억력!',
                        icon: Icons.psychology,
                        color: const Color(0xFFE056FD),
                        route: '/game/sequence',
                      ),
                      _buildGameCard(
                        context,
                        title: '스트룹',
                        subtitle: '색깔!',
                        icon: Icons.palette,
                        color: const Color(0xFF00CEC9),
                        route: '/game/stroop',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // 전략 게임 섹션
                  _buildSectionHeader(
                    icon: Icons.psychology_alt,
                    title: '전략 게임',
                    subtitle: '10~20분',
                    color: const Color(0xFF636E72),
                  ),
                  const SizedBox(height: 8),
                  _buildLargeGameCard(
                    context,
                    title: '오목',
                    subtitle: '5개를 연속으로 놓으면 승리',
                    icon: Icons.circle_outlined,
                    color: const Color(0xFF636E72),
                    route: '/game/gomoku',
                  ),
                  const SizedBox(height: 20),

                  // 두뇌 게임 섹션
                  _buildSectionHeader(
                    icon: Icons.extension,
                    title: '두뇌 게임',
                    subtitle: '5~15분',
                    color: const Color(0xFF2D3436),
                  ),
                  const SizedBox(height: 8),
                  _buildLargeGameCard(
                    context,
                    title: '헥사곤',
                    subtitle: '숫자를 외우고 합을 맞춰라!',
                    icon: Icons.hexagon_outlined,
                    color: const Color(0xFF2D3436),
                    route: '/game/hexagon',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRankedCard(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RankedScreen()),
          );
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFFF4500),
                Color(0xFFFF6347),
              ],
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.emoji_events,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '랭크전',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Bo3 | ELO 기반 매칭',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: Colors.white,
                size: 28,
              ),
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
    return Card(
      elevation: enabled ? 4 : 1,
      shadowColor: enabled ? color.withValues(alpha: 0.3) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        onTap: enabled && route != null
            ? () {
                Navigator.pushNamed(context, route);
              }
            : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: enabled
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      color.withValues(alpha: 0.85),
                      color,
                    ],
                  )
                : null,
            color: enabled ? null : Colors.grey.shade100,
          ),
          child: Stack(
            children: [
              // 배경 장식
              if (enabled)
                Positioned(
                  right: -10,
                  top: -10,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                ),
              // 내용
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: enabled
                            ? Colors.white.withValues(alpha: 0.25)
                            : Colors.grey.shade200,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        icon,
                        size: 24,
                        color: enabled ? Colors.white : Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: enabled ? Colors.white : Colors.grey,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: enabled
                            ? Colors.white.withValues(alpha: 0.8)
                            : Colors.grey,
                      ),
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

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade800,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            subtitle,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
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
  }) {
    return Card(
      elevation: 4,
      shadowColor: color.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color.withValues(alpha: 0.85),
              color,
            ],
          ),
        ),
        child: InkWell(
          onTap: route != null
              ? () {
                  Navigator.pushNamed(context, route);
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 28,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Colors.white.withValues(alpha: 0.8),
                size: 28,
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}
