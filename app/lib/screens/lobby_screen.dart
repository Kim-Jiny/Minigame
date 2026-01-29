import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../config/app_config.dart';

class LobbyScreen extends StatelessWidget {
  const LobbyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('미니게임 천국'),
        actions: [
          // 프로필/로그아웃
          PopupMenuButton<String>(
            icon: const CircleAvatar(
              child: Icon(Icons.person),
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
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '게임 선택',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
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
                    color: Colors.blue,
                    route: '/game/tictactoe',
                  ),
                  _buildGameCard(
                    context,
                    title: '무한 틱택토',
                    subtitle: '각자 3개까지!',
                    icon: Icons.all_inclusive,
                    color: Colors.purple,
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
                      color.withValues(alpha: 0.8),
                      color,
                    ],
                  )
                : null,
            color: enabled ? null : Colors.grey.shade200,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 48,
                color: enabled ? Colors.white : Colors.grey,
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: enabled ? Colors.white : Colors.grey,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 14,
                  color: enabled ? Colors.white70 : Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
