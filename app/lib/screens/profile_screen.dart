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
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

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
    if (context.read<AuthProvider>().userId != null) {
      _loadUnreadCount();
    }
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
      return FloatingBackground(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DuoMascot(size: 110, mood: MascotMood.sad),
                const SizedBox(height: 16),
                const Text(
                  '프로필 기능을 사용하려면\n소셜 로그인이 필요해요',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
                const SizedBox(height: 24),
                ChunkyButton(
                  onPressed: () => auth.logout(),
                  icon: Icons.login,
                  label: '다시 로그인',
                ),
              ],
            ),
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
        return FloatingBackground(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final maxContentWidth = width >= 1300 ? 1100.0 : double.infinity;
              final isTablet = width >= 900;
              final itemWidth = isTablet
                  ? (maxContentWidth >= width
                        ? (width - 44) / 2
                        : (maxContentWidth - 44) / 2)
                  : double.infinity;

              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxContentWidth),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      isTablet ? 22 : 16,
                      16,
                      isTablet ? 22 : 16,
                      20,
                    ),
                    child: Column(
                      children: [
                        PopIn(
                          child: _buildProfileCard(
                            context,
                            auth,
                            totalLevel,
                            profileSettings,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _buildMenuWrap(
                          itemWidth: itemWidth,
                          children: [
                            _buildMenuItem(
                              context,
                              icon: Icons.monetization_on,
                              iconColor: CandyColors.sun,
                              title: '코인 샵',
                              subtitle: '${statsProvider.mileage} 코인 보유',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const ShopScreen(),
                                  ),
                                );
                              },
                            ),
                            _buildMenuItem(
                              context,
                              icon: Icons.military_tech,
                              iconColor: CandyColors.pink,
                              title: '내 레벨',
                              subtitle: '게임별 레벨과 전적 확인',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const LevelManageScreen(),
                                  ),
                                );
                              },
                            ),
                            _buildMenuItem(
                              context,
                              icon: Icons.history,
                              iconColor: CandyColors.mint,
                              title: '최근 기록',
                              subtitle:
                                  '${statsProvider.recentRecords.length}개의 기록',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const RecentRecordsScreen(),
                                  ),
                                );
                              },
                            ),
                            _buildMenuItem(
                              context,
                              icon: Icons.leaderboard,
                              iconColor: CandyColors.tangerine,
                              title: '랭킹 보기',
                              subtitle: '랭크전 리더보드',
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const LeaderboardScreen(),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _buildMenuWrap(
                          itemWidth: itemWidth,
                          children: [
                            _buildMenuItem(
                              context,
                              icon: Icons.mail_outline,
                              iconColor: CandyColors.sky,
                              title: '문의하기',
                              subtitle: '버그 신고, 건의사항',
                              badge: _unreadInquiryCount,
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const InquiryScreen(),
                                  ),
                                );
                                _loadUnreadCount();
                              },
                            ),
                            _buildMenuItem(
                              context,
                              icon: Icons.logout,
                              iconColor: CandyColors.grape,
                              title: '로그아웃',
                              onTap: () {
                                _showLogoutDialog(context, auth);
                              },
                            ),
                            _buildMenuItem(
                              context,
                              icon: Icons.delete_forever,
                              iconColor: CandyColors.pinkDeep,
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
          ),
        );
      },
    );
  }

  Widget _buildMenuWrap({
    required double itemWidth,
    required List<Widget> children,
  }) {
    return Wrap(
      spacing: 12,
      runSpacing: 0,
      children: [
        for (int i = 0; i < children.length; i++)
          SizedBox(
            width: itemWidth,
            child: PopIn(
              delay: Duration(milliseconds: 80 + i * 50),
              child: children[i],
            ),
          ),
      ],
    );
  }

  Widget _buildProfileCard(
    BuildContext context,
    AuthProvider auth,
    int totalLevel,
    dynamic profileSettings,
  ) {
    // 테마 색상 결정
    List<Color> themeColors = [CandyColors.pink, CandyColors.grape];

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

    return CartoonCard(
      padding: EdgeInsets.zero,
      shadow: 6,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CandyTheme.radius - 3),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: themeColors,
          ),
        ),
        child: Column(
          children: [
            // 프레임이 적용된 아바타
            _buildFramedAvatar(
              frameColor,
              glowColor,
              isRainbow,
              avatarEmoji,
              avatarBgColor,
            ),
            const SizedBox(height: 14),

            // 닉네임
            Text(
              auth.nickname ?? '사용자',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w900,
                shadows: [Shadow(color: CandyColors.ink, offset: Offset(0, 2))],
              ),
            ),

            // 칭호
            if (titleText != null) ...[
              const SizedBox(height: 4),
              _buildTitleWidget(
                titleText,
                titleIcon,
                titleColor,
                titleGradient,
              ),
            ] else if (auth.email != null) ...[
              const SizedBox(height: 4),
              Text(
                auth.email!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 14),

            // 레벨 뱃지
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: CandyColors.sun,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.military_tech,
                    color: CandyColors.ink,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '통합 레벨 $totalLevel',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: CandyColors.ink,
                        fontWeight: FontWeight.w900,
                      ),
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

  Widget _buildFramedAvatar(
    Color? frameColor,
    Color? glowColor,
    bool isRainbow,
    String? avatarEmoji,
    Color? avatarBgColor,
  ) {
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
              ? Border.all(color: CandyColors.ink, width: 3)
              : null,
        ),
        child: CircleAvatar(
          radius: 40,
          backgroundColor:
              avatarBgColor ?? Colors.white.withValues(alpha: 0.35),
          child: avatarEmoji != null
              ? Text(avatarEmoji, style: const TextStyle(fontSize: 48))
              : const Icon(Icons.person, size: 40, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildTitleWidget(
    String title,
    String? icon,
    Color? textColor,
    List<Color>? gradient,
  ) {
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CartoonCard(
        onTap: onTap,
        shadow: 4,
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: iconColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            color: CandyColors.ink,
                          ),
                        ),
                      ),
                      if (badge > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: CandyColors.pink,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: CandyColors.ink,
                              width: 2,
                            ),
                          ),
                          child: Text(
                            badge > 99 ? '99+' : '$badge',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: CandyColors.inkSoft,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: CandyColors.ink),
          ],
        ),
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
          ChunkyButton(
            onPressed: () {
              Navigator.pop(context);
              auth.logout();
            },
            color: CandyColors.pink,
            height: 44,
            fontSize: 15,
            expand: false,
            label: '로그아웃',
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
            Icon(Icons.warning_rounded, color: CandyColors.pinkDeep),
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
              style: TextStyle(
                color: CandyColors.pinkDeep,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ChunkyButton(
            onPressed: () async {
              Navigator.pop(context);
              _confirmDeleteAccount(context, auth);
            },
            color: CandyColors.pink,
            height: 44,
            fontSize: 15,
            expand: false,
            label: '탈퇴하기',
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
          ChunkyButton(
            color: CandyColors.pink,
            height: 44,
            fontSize: 15,
            expand: false,
            label: '탈퇴 확인',
            onPressed: () async {
              Navigator.pop(context);

              // 로딩 표시
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) =>
                    const Center(child: CircularProgressIndicator()),
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
          ),
        ],
      ),
    );
  }
}
