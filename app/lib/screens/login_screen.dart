import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _nicknameController = TextEditingController();
  bool _isLoading = false;
  late AnimationController _animController;
  late Animation<double> _bounceAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    _bounceAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _animController.dispose();
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

    setState(() => _isLoading = true);

    try {
      await context.read<AuthProvider>().loginAsGuest(nickname);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loginWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      await context.read<AuthProvider>().loginWithGoogle();
      _checkError();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loginWithApple() async {
    setState(() => _isLoading = true);
    try {
      await context.read<AuthProvider>().loginWithApple();
      _checkError();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _loginWithKakao() async {
    setState(() => _isLoading = true);
    try {
      await context.read<AuthProvider>().loginWithKakao();
      _checkError();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
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
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFE8E0FF),  // 연한 라벤더
              Color(0xFFE0F4FF),  // 연한 스카이블루
              Color(0xFFFFF8E0),  // 연한 크림
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 40),

                // 로고/타이틀 - 귀여운 애니메이션
                SizedBox(
                  width: 200,
                  height: 150,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      // 배경 장식들 (떠다니는 효과)
                      Positioned(
                        left: 10,
                        top: 20,
                        child: AnimatedBuilder(
                          animation: _animController,
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(0, 5 * _bounceAnimation.value - 2.5),
                              child: Icon(
                                Icons.star_rounded,
                                size: 24,
                                color: const Color(0xFFFDCB6E).withValues(alpha: 0.6),
                              ),
                            );
                          },
                        ),
                      ),
                      Positioned(
                        right: 15,
                        top: 10,
                        child: AnimatedBuilder(
                          animation: _animController,
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(0, -5 * _bounceAnimation.value + 2.5),
                              child: Icon(
                                Icons.cloud_rounded,
                                size: 22,
                                color: const Color(0xFF74B9FF).withValues(alpha: 0.5),
                              ),
                            );
                          },
                        ),
                      ),
                      Positioned(
                        left: 25,
                        bottom: 15,
                        child: AnimatedBuilder(
                          animation: _animController,
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(0, 3 * _bounceAnimation.value - 1.5),
                              child: Icon(
                                Icons.auto_awesome,
                                size: 18,
                                color: const Color(0xFF6C5CE7).withValues(alpha: 0.5),
                              ),
                            );
                          },
                        ),
                      ),
                      Positioned(
                        right: 10,
                        bottom: 25,
                        child: AnimatedBuilder(
                          animation: _animController,
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(0, -4 * _bounceAnimation.value + 2),
                              child: Icon(
                                Icons.circle,
                                size: 14,
                                color: const Color(0xFF00CEC9).withValues(alpha: 0.4),
                              ),
                            );
                          },
                        ),
                      ),
                      // 메인 아이콘
                      Center(
                        child: ScaleTransition(
                          scale: _bounceAnimation,
                          child: Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF6C5CE7), Color(0xFF74B9FF)],
                              ),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF6C5CE7).withValues(alpha: 0.4),
                                  blurRadius: 25,
                                  offset: const Offset(0, 10),
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.sports_esports_rounded,
                              size: 60,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // 앱 이름
                ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [Color(0xFF6C5CE7), Color(0xFF74B9FF)],
                  ).createShader(bounds),
                  child: const Text(
                    '플레이메이트',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '친구와 함께 즐기는 미니게임',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 48),

                // 닉네임 입력 카드
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6C5CE7).withValues(alpha: 0.12),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _nicknameController,
                        decoration: InputDecoration(
                          labelText: '닉네임',
                          hintText: '게임에서 사용할 닉네임',
                          prefixIcon: const Icon(Icons.person_outline_rounded),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFF6C5CE7),
                              width: 2,
                            ),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFF8F9FF),
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _loginAsGuest(),
                      ),
                      const SizedBox(height: 20),

                      // 게스트 로그인 버튼
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _loginAsGuest,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6C5CE7),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 4,
                            shadowColor: const Color(0xFF6C5CE7).withValues(alpha: 0.4),
                          ),
                          child: _isLoading
                              ? const CircularProgressIndicator(color: Colors.white)
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.play_arrow_rounded, size: 28),
                                    SizedBox(width: 8),
                                    Text(
                                      '게임 시작하기',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // 소셜 로그인
                Row(
                  children: [
                    Expanded(child: Divider(color: Colors.grey.shade300)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '또는 소셜 로그인',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Expanded(child: Divider(color: Colors.grey.shade300)),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildSocialButton(
                      icon: Icons.g_mobiledata,
                      color: Colors.red,
                      onTap: _isLoading ? null : _loginWithGoogle,
                      label: 'Google',
                    ),
                    const SizedBox(width: 16),
                    // Apple 로그인은 iOS/macOS에서만 표시
                    if (Platform.isIOS || Platform.isMacOS) ...[
                      _buildSocialButton(
                        icon: Icons.apple,
                        color: Colors.black,
                        onTap: _isLoading ? null : _loginWithApple,
                        label: 'Apple',
                      ),
                      const SizedBox(width: 16),
                    ],
                    _buildSocialButton(
                      icon: Icons.chat_bubble,
                      color: const Color(0xFFFEE500),
                      iconColor: Colors.black87,
                      onTap: _isLoading ? null : _loginWithKakao,
                      label: 'Kakao',
                    ),
                  ],
                ),
                const SizedBox(height: 40),

                // 하단 장식
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.star_rounded, size: 12, color: const Color(0xFFFDCB6E)),
                    const SizedBox(width: 4),
                    Text(
                      '친구와 함께하는 즐거운 게임',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.star_rounded, size: 12, color: const Color(0xFFFDCB6E)),
                  ],
                ),
              ],
            ),
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
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade200),
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.shade100,
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              icon,
              color: iconColor ?? color,
              size: 32,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }
}
