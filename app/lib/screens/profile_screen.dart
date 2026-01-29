import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/stats_provider.dart';
import 'mileage_shop_screen.dart';
import 'level_manage_screen.dart';
import 'recent_records_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    // 게스트 로그인인 경우
    if (auth.userId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text(
                '프로필 기능을 사용하려면\n소셜 로그인이 필요합니다',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => auth.logout(),
                icon: const Icon(Icons.login),
                label: const Text('다시 로그인'),
              ),
            ],
          ),
        ),
      );
    }

    return Consumer<StatsProvider>(
      builder: (context, statsProvider, child) {
        // 통합 레벨 계산
        int totalLevel = 0;
        for (var stats in statsProvider.allStats) {
          totalLevel += stats.level;
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // 프로필 카드
              _buildProfileCard(context, auth, totalLevel),
              const SizedBox(height: 24),

              // 메뉴 목록
              _buildMenuItem(
                context,
                icon: Icons.monetization_on,
                iconColor: Colors.amber.shade600,
                title: '마일리지 샵',
                subtitle: '${statsProvider.mileage} 마일리지 보유',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MileageShopScreen()),
                  );
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.military_tech,
                iconColor: Theme.of(context).primaryColor,
                title: '내 레벨',
                subtitle: '게임별 레벨과 전적 확인',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LevelManageScreen()),
                  );
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.history,
                iconColor: Colors.teal,
                title: '최근 기록',
                subtitle: '${statsProvider.recentRecords.length}개의 기록',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RecentRecordsScreen()),
                  );
                },
              ),

              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),

              // 계정 관련
              _buildMenuItem(
                context,
                icon: Icons.edit,
                iconColor: Colors.grey,
                title: '닉네임 변경',
                onTap: () {
                  _showChangeNicknameDialog(context, auth);
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.logout,
                iconColor: Colors.red,
                title: '로그아웃',
                onTap: () {
                  _showLogoutDialog(context, auth);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProfileCard(BuildContext context, AuthProvider auth, int totalLevel) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).primaryColor,
              Theme.of(context).primaryColor.withValues(alpha: 0.7),
            ],
          ),
        ),
        child: Column(
          children: [
            // 아바타
            CircleAvatar(
              radius: 40,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              backgroundImage: auth.avatarUrl != null ? NetworkImage(auth.avatarUrl!) : null,
              child: auth.avatarUrl == null
                  ? const Icon(Icons.person, size: 40, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 16),

            // 닉네임
            Text(
              auth.nickname ?? '사용자',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (auth.email != null) ...[
              const SizedBox(height: 4),
              Text(
                auth.email!,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
            const SizedBox(height: 16),

            // 레벨 뱃지
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.military_tech, color: Colors.amber, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '통합 레벨 $totalLevel',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: iconColor),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle != null
            ? Text(subtitle, style: TextStyle(color: Colors.grey.shade600, fontSize: 13))
            : null,
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      ),
    );
  }

  void _showChangeNicknameDialog(BuildContext context, AuthProvider auth) {
    final controller = TextEditingController(text: auth.nickname);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('닉네임 변경'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '새 닉네임',
            hintText: '2-20자 입력',
            border: OutlineInputBorder(),
          ),
          maxLength: 20,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newNickname = controller.text.trim();
              if (newNickname.length < 2) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('닉네임은 2자 이상이어야 합니다')),
                );
                return;
              }

              Navigator.pop(context);
              final success = await auth.updateNickname(newNickname);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success ? '닉네임이 변경되었습니다' : '닉네임 변경에 실패했습니다'),
                  ),
                );
              }
            },
            child: const Text('변경'),
          ),
        ],
      ),
    );
  }

  void _showLogoutDialog(BuildContext context, AuthProvider auth) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text('정말 로그아웃 하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              auth.logout();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );
  }
}
