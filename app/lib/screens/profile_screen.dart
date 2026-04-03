import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/stats_provider.dart';
import '../providers/shop_provider.dart';
import '../services/api_service.dart';
import 'shop_screen.dart';
import 'level_manage_screen.dart';
import 'recent_records_screen.dart';
import 'leaderboard_screen.dart';
import 'inquiry_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  int _unreadInquiryCount = 0;

  @override
  void initState() {
    super.initState();
    _loadUnreadCount();
  }

  Future<void> _loadUnreadCount() async {
    try {
      final count = await ApiService().getUnreadInquiryCount();
      if (mounted) {
        setState(() => _unreadInquiryCount = count);
      }
    } catch (_) {
      // API 실패 시 무시 (뱃지가 표시되지 않을 뿐)
    }
  }

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

    return Consumer2<StatsProvider, ShopProvider>(
      builder: (context, statsProvider, shopProvider, child) {
        // 통합 레벨 계산
        int totalLevel = 0;
        for (var stats in statsProvider.allStats) {
          totalLevel += stats.level;
        }

        final profileSettings = shopProvider.profileSettings;
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final maxContentWidth = width >= 1300 ? 1100.0 : double.infinity;
            final isTablet = width >= 900;
            final itemWidth = isTablet ? (maxContentWidth >= width ? (width - 44) / 2 : (maxContentWidth - 44) / 2) : double.infinity;

            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxContentWidth),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(isTablet ? 22 : 16, 16, isTablet ? 22 : 16, 20),
                  child: Column(
                    children: [
                      _buildProfileCard(context, auth, totalLevel, profileSettings),
                      const SizedBox(height: 20),
                      _buildMenuWrap(
                        itemWidth: itemWidth,
                        children: [
                          _buildMenuItem(
                            context,
                            icon: Icons.monetization_on,
                            iconColor: Colors.amber.shade600,
                            title: '코인 샵',
                            subtitle: '${statsProvider.mileage} 코인 보유',
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const ShopScreen()),
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
                          _buildMenuItem(
                            context,
                            icon: Icons.leaderboard,
                            iconColor: const Color(0xFFFF4500),
                            title: '랭킹 보기',
                            subtitle: '랭크전 리더보드',
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 12),
                      _buildMenuWrap(
                        itemWidth: itemWidth,
                        children: [
                          _buildMenuItem(
                            context,
                            icon: Icons.mail_outline,
                            iconColor: Colors.blue,
                            title: '문의하기',
                            subtitle: '버그 신고, 건의사항',
                            badge: _unreadInquiryCount,
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const InquiryScreen()),
                              );
                              _loadUnreadCount();
                            },
                          ),
                          _buildMenuItem(
                            context,
                            icon: Icons.logout,
                            iconColor: Colors.orange,
                            title: '로그아웃',
                            onTap: () {
                              _showLogoutDialog(context, auth);
                            },
                          ),
                          _buildMenuItem(
                            context,
                            icon: Icons.delete_forever,
                            iconColor: Colors.red,
                            title: '회원 탈퇴',
                            subtitle: '모든 데이터가 삭제됩니다',
                            onTap: () {
                              _showDeleteAccountDialog(context, auth);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMenuWrap({required double itemWidth, required List<Widget> children}) {
    return Wrap(
      spacing: 12,
      runSpacing: 0,
      children: children
          .map(
            (item) => SizedBox(
              width: itemWidth,
              child: item,
            ),
          )
          .toList(),
    );
  }

  Widget _buildProfileCard(BuildContext context, AuthProvider auth, int totalLevel, dynamic profileSettings) {
    // 테마 색상 결정
    List<Color> themeColors = [
      Theme.of(context).primaryColor,
      Theme.of(context).primaryColor.withValues(alpha: 0.7),
    ];

    if (profileSettings?.activeTheme != null) {
      final gradientColors = profileSettings.activeTheme.gradientColors;
      if (gradientColors != null && gradientColors.length >= 2) {
        themeColors = gradientColors;
      }
    }

    // 프레임 스타일 결정
    Color? frameColor;
    Color? glowColor;
    bool isRainbow = false;

    if (profileSettings?.activeFrame != null) {
      final frame = profileSettings.activeFrame;
      frameColor = frame.borderColor;
      glowColor = frame.glowColor;
      isRainbow = frame.isRainbow;
    }

    // 칭호 정보
    String? titleText;
    String? titleIcon;
    Color? titleColor;
    List<Color>? titleGradient;

    if (profileSettings?.activeTitle != null) {
      final title = profileSettings.activeTitle;
      titleText = title.name;
      titleIcon = title.titleIcon;
      titleColor = title.textColor;
      titleGradient = title.titleGradient;
    }

    // 아바타 정보
    String? avatarEmoji;
    Color? avatarBgColor;

    final activeAvatar = profileSettings?.activeAvatar;
    if (activeAvatar != null) {
      avatarEmoji = activeAvatar.avatarEmoji;
      avatarBgColor = activeAvatar.avatarBgColor;
    }

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
            colors: themeColors,
          ),
        ),
        child: Column(
          children: [
            // 프레임이 적용된 아바타
            _buildFramedAvatar(frameColor, glowColor, isRainbow, avatarEmoji, avatarBgColor),
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

            // 칭호
            if (titleText != null) ...[
              const SizedBox(height: 4),
              _buildTitleWidget(titleText, titleIcon, titleColor, titleGradient),
            ] else if (auth.email != null) ...[
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

  Widget _buildFramedAvatar(Color? frameColor, Color? glowColor, bool isRainbow, String? avatarEmoji, Color? avatarBgColor) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: glowColor != null
            ? [
                BoxShadow(
                  color: glowColor.withValues(alpha: 0.6),
                  blurRadius: 12,
                  spreadRadius: 4,
                ),
              ]
            : null,
      ),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isRainbow
              ? const SweepGradient(
                  colors: [
                    Colors.red,
                    Colors.orange,
                    Colors.yellow,
                    Colors.green,
                    Colors.blue,
                    Colors.purple,
                    Colors.red,
                  ],
                )
              : null,
          border: !isRainbow && frameColor != null
              ? Border.all(color: frameColor, width: 4)
              : !isRainbow
                  ? Border.all(color: Colors.white.withValues(alpha: 0.3), width: 2)
                  : null,
        ),
        child: CircleAvatar(
          radius: 40,
          backgroundColor: avatarBgColor ?? Colors.white.withValues(alpha: 0.2),
          child: avatarEmoji != null
              ? Text(avatarEmoji, style: const TextStyle(fontSize: 48))
              : const Icon(Icons.person, size: 40, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildTitleWidget(String title, String? icon, Color? textColor, List<Color>? gradient) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Text(icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 4),
        ],
        ShaderMask(
          shaderCallback: (bounds) {
            if (gradient != null && gradient.length >= 2) {
              return LinearGradient(colors: gradient).createShader(bounds);
            }
            final color = textColor ?? Colors.white70;
            return LinearGradient(colors: [color, color]).createShader(bounds);
          },
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    int badge = 0,
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
        title: Row(
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (badge > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
        subtitle: subtitle != null
            ? Text(subtitle, style: TextStyle(color: Colors.grey.shade600, fontSize: 13))
            : null,
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
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

  void _showDeleteAccountDialog(BuildContext context, AuthProvider auth) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning, color: Colors.red),
            SizedBox(width: 8),
            Text('회원 탈퇴'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '정말 탈퇴하시겠습니까?',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            SizedBox(height: 12),
            Text('탈퇴 시 다음 데이터가 모두 삭제됩니다:'),
            SizedBox(height: 8),
            Text('• 게임 전적 및 레벨'),
            Text('• 보유 코인 및 구매 아이템'),
            Text('• 친구 목록'),
            Text('• 랭크 정보'),
            SizedBox(height: 12),
            Text(
              '삭제된 데이터는 복구할 수 없습니다.',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              _confirmDeleteAccount(context, auth);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('탈퇴하기'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context, AuthProvider auth) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('최종 확인'),
        content: const Text('정말로 회원 탈퇴를 진행하시겠습니까?\n이 작업은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);

              // 로딩 표시
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => const Center(
                  child: CircularProgressIndicator(),
                ),
              );

              final success = await auth.deleteAccount();

              if (context.mounted) {
                Navigator.pop(context); // 로딩 닫기

                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('회원 탈퇴가 완료되었습니다.')),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(auth.error ?? '회원 탈퇴에 실패했습니다.')),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('탈퇴 확인'),
          ),
        ],
      ),
    );
  }
}
