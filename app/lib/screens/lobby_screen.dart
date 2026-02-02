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

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  int _currentIndex = 0;

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

    // 게임 시작 (초대 수락 후)
    friendProvider.onGameStart = (gameType, roomId, gameState) {
      if (mounted) {
        // 게임 상태가 포함되어 있으면 직접 초기화 (이벤트 리스너 타이밍 문제 방지)
        if (gameState != null) {
          final gameProvider = context.read<GameProvider>();
          gameProvider.initializeInvitationGame(
            roomId: roomId,
            players: gameState['players'] as List<dynamic>,
            currentTurn: gameState['currentTurn'] as String,
            board: gameState['board'] as List<dynamic>,
            turnTimeLimit: gameState['turnTimeLimit'] as int?,
            turnStartTime: gameState['turnStartTime'] as int?,
          );
        }

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
        }
        Navigator.pushNamed(context, route);
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
            title: Text(_currentIndex == 0 ? '플레이메이트' : _currentIndex == 1 ? '친구' : '프로필'),
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

            // 게임 목록
            Expanded(
              child: GridView.count(
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
                    title: '무한 틱택토',
                    subtitle: '3개씩!',
                    icon: Icons.all_inclusive,
                    color: const Color(0xFF00B894),
                    route: '/game/infinite_tictactoe',
                  ),
                  _buildGameCard(
                    context,
                    title: '오목',
                    subtitle: '5연속',
                    icon: Icons.circle_outlined,
                    color: const Color(0xFF636E72),
                    route: '/game/gomoku',
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
                ],
              ),
            ),
          ],
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
}
