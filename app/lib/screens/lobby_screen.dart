import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/friend_provider.dart';
import '../widgets/invitation_dialog.dart';
import 'friends_screen.dart';

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
      _setupInvitationListener();
    });
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
    friendProvider.onGameStart = (gameType, roomId) {
      if (mounted) {
        String route = '/game/$gameType';
        if (gameType == 'infinite_tictactoe') {
          route = '/game/infinite_tictactoe';
        } else if (gameType == 'tictactoe') {
          route = '/game/tictactoe';
        }
        Navigator.pushNamed(context, route);
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentIndex == 0 ? '플레이메이트' : '친구'),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          // 프로필/로그아웃
          PopupMenuButton<String>(
            icon: CircleAvatar(
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              child: const Icon(Icons.person, color: Colors.white, size: 20),
            ),
            onSelected: (value) {
              if (value == 'logout') {
                auth.logout();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Text(
                  '안녕하세요, ${auth.nickname}님!',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20),
                    SizedBox(width: 8),
                    Text('로그아웃'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _currentIndex == 0 ? _buildGamesTab() : const FriendsScreen(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        selectedItemColor: Theme.of(context).primaryColor,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.sports_esports),
            activeIcon: Icon(Icons.sports_esports),
            label: '게임',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people_outline),
            activeIcon: Icon(Icons.people),
            label: '친구',
          ),
        ],
      ),
    );
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
            const SizedBox(height: 24),

            Text(
              '게임 선택',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 16),

            // 게임 목록
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                children: [
                  _buildGameCard(
                    context,
                    title: '틱택토',
                    subtitle: '3개 연속 승리',
                    icon: Icons.grid_3x3,
                    color: const Color(0xFF6C5CE7),
                    route: '/game/tictactoe',
                  ),
                  _buildGameCard(
                    context,
                    title: '무한 틱택토',
                    subtitle: '각자 3개까지!',
                    icon: Icons.all_inclusive,
                    color: const Color(0xFF74B9FF),
                    route: '/game/infinite_tictactoe',
                  ),
                  _buildGameCard(
                    context,
                    title: '오목',
                    subtitle: '준비 중',
                    icon: Icons.circle_outlined,
                    color: Colors.grey,
                    route: null,
                    enabled: false,
                  ),
                  _buildGameCard(
                    context,
                    title: '더 많은 게임',
                    subtitle: '곧 추가 예정',
                    icon: Icons.add,
                    color: Colors.grey,
                    route: null,
                    enabled: false,
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
      shadowColor: enabled ? color.withValues(alpha: 0.4) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: InkWell(
        onTap: enabled && route != null
            ? () {
                Navigator.pushNamed(context, route);
              }
            : null,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: enabled
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      color,
                      color.withValues(alpha: 0.8),
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
                  right: -20,
                  top: -20,
                  child: Icon(
                    Icons.star_rounded,
                    size: 80,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                ),
              // 내용
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: enabled
                            ? Colors.white.withValues(alpha: 0.2)
                            : Colors.grey.shade200,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        icon,
                        size: 36,
                        color: enabled ? Colors.white : Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: enabled ? Colors.white : Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: enabled ? Colors.white70 : Colors.grey,
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
