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
import 'mode_games_screen.dart';

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
      color: const Color(0xFFF7F7FB),
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
                    const SizedBox(height: 28),
                    _buildModeCard(PlayMode.duo, emphasized: true),
                    const SizedBox(height: 14),
                    _buildModeCard(PlayMode.solo),
                    const SizedBox(height: 14),
                    _buildModeCard(PlayMode.multi, locked: true),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGreeting(String nickname) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '안녕하세요,',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            color: Colors.grey.shade500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '$nickname님',
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: Color(0xFF1F2430),
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '오늘은 어떤 방식으로 즐겨볼까요?',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildModeCard(
    PlayMode mode, {
    bool emphasized = false,
    bool locked = false,
  }) {
    final count = GameRegistry.countForMode(mode);
    final meta = locked ? '준비 중' : '$count개 게임 · ${mode.tagline}';

    if (locked) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F1F5),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE7E7EC)),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.grey.shade300.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(mode.icon, color: Colors.grey.shade500, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mode.title,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.grey.shade500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_rounded, size: 13, color: Colors.grey.shade500),
                  const SizedBox(width: 4),
                  Text(
                    '준비 중',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final color = mode.color;
    return Material(
      color: emphasized ? color : Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ModeGamesScreen(mode: mode)),
          );
        },
        child: Ink(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: emphasized ? color : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: emphasized
                ? null
                : Border.all(color: const Color(0xFFEDEDF2)),
            boxShadow: [
              BoxShadow(
                color: emphasized
                    ? color.withValues(alpha: 0.28)
                    : Colors.black.withValues(alpha: 0.03),
                blurRadius: emphasized ? 22 : 12,
                offset: Offset(0, emphasized ? 10 : 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: emphasized
                      ? Colors.white.withValues(alpha: 0.2)
                      : color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(
                  mode.icon,
                  color: emphasized ? Colors.white : color,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.title,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: emphasized ? Colors.white : const Color(0xFF1F2430),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: emphasized
                            ? Colors.white.withValues(alpha: 0.85)
                            : Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: emphasized
                    ? Colors.white.withValues(alpha: 0.9)
                    : Colors.grey.shade300,
                size: 26,
              ),
            ],
          ),
        ),
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

}
