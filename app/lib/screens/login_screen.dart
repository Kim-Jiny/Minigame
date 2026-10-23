import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/duo_logo.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nicknameController = TextEditingController();

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _loginAsGuest() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('닉네임을 입력해주세요')),
      );
      return;
    }

    await context.read<AuthProvider>().loginAsGuest(nickname);
    _checkError();
  }

  Future<void> _loginWithGoogle() async {
    await context.read<AuthProvider>().loginWithGoogle();
    _checkError();
  }

  Future<void> _loginWithApple() async {
    await context.read<AuthProvider>().loginWithApple();
    _checkError();
  }

  Future<void> _loginWithKakao() async {
    await context.read<AuthProvider>().loginWithKakao();
    _checkError();
  }

  void _checkError() {
    final error = context.read<AuthProvider>().error;
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = context.watch<AuthProvider>().isLoading;

    return Scaffold(
      body: FloatingBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 24),
                      const PopIn(child: DuoLogo(size: 92)),
                      const SizedBox(height: 8),
                      const Text(
                        '친구와 함께 즐기는 미니게임',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: CandyColors.inkSoft,
                        ),
                      ),
                      const SizedBox(height: 32),
                      PopIn(
                        delay: const Duration(milliseconds: 200),
                        child: CartoonCard(
                          radius: 26,
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            children: [
                              TextField(
                                controller: _nicknameController,
                                style: const TextStyle(fontWeight: FontWeight.w800),
                                decoration: const InputDecoration(
                                  labelText: '닉네임',
                                  hintText: '게임에서 사용할 닉네임',
                                  prefixIcon: Icon(Icons.person_outline_rounded),
                                ),
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) => _loginAsGuest(),
                              ),
                              const SizedBox(height: 18),
                              ChunkyButton(
                                label: isLoading ? '들어가는 중...' : '게임 시작하기',
                                icon: Icons.play_arrow_rounded,
                                onPressed: isLoading ? null : _loginAsGuest,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      const Row(
                        children: [
                          Expanded(child: Divider(color: CandyColors.ink, thickness: 2)),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 14),
                            child: Text(
                              '또는 소셜 로그인',
                              style: TextStyle(
                                color: CandyColors.inkSoft,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Expanded(child: Divider(color: CandyColors.ink, thickness: 2)),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildSocialButton(
                            icon: Icons.g_mobiledata,
                            color: Colors.red,
                            onTap: isLoading ? null : _loginWithGoogle,
                            label: 'Google',
                          ),
                          const SizedBox(width: 16),
                          // Apple 로그인은 iOS/macOS에서만 표시
                          if (Platform.isIOS || Platform.isMacOS) ...[
                            _buildSocialButton(
                              icon: Icons.apple,
                              color: Colors.black,
                              onTap: isLoading ? null : _loginWithApple,
                              label: 'Apple',
                            ),
                            const SizedBox(width: 16),
                          ],
                          _buildSocialButton(
                            icon: Icons.chat_bubble,
                            color: const Color(0xFFFEE500),
                            iconColor: Colors.black87,
                            onTap: isLoading ? null : _loginWithKakao,
                            label: 'Kakao',
                          ),
                        ],
                      ),
                      SizedBox(height: MediaQuery.of(context).padding.bottom + 32),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSocialButton({
    required IconData icon,
    required Color color,
    Color? iconColor,
    required VoidCallback? onTap,
    required String label,
  }) {
    return Column(
      children: [
        SizedBox(
          width: 68,
          child: ChunkyButton(
            color: color == const Color(0xFFFEE500) ? color : Colors.white,
            height: 58,
            radius: 18,
            onPressed: onTap,
            child: Icon(icon, color: iconColor ?? color, size: 32),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: CandyColors.inkSoft,
          ),
        ),
      ],
    );
  }
}
