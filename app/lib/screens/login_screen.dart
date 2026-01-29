import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nicknameController = TextEditingController();
  bool _isLoading = false;

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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 로고/타이틀
              const Icon(
                Icons.games,
                size: 80,
                color: Colors.deepPurple,
              ),
              const SizedBox(height: 16),
              const Text(
                '미니게임 천국',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '친구와 함께 즐기는 미니게임',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 48),

              // 닉네임 입력
              TextField(
                controller: _nicknameController,
                decoration: InputDecoration(
                  labelText: '닉네임',
                  hintText: '게임에서 사용할 닉네임',
                  prefixIcon: const Icon(Icons.person),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _loginAsGuest(),
              ),
              const SizedBox(height: 24),

              // 게스트 로그인 버튼
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _loginAsGuest,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          '게스트로 시작',
                          style: TextStyle(fontSize: 16),
                        ),
                ),
              ),
              const SizedBox(height: 32),

              // 소셜 로그인
              const Text(
                '소셜 로그인',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildSocialButton(
                    icon: Icons.g_mobiledata,
                    color: Colors.red,
                    onTap: _isLoading ? null : _loginWithGoogle,
                  ),
                  const SizedBox(width: 16),
                  // Apple 로그인은 iOS/macOS에서만 표시
                  if (Platform.isIOS || Platform.isMacOS) ...[
                    _buildSocialButton(
                      icon: Icons.apple,
                      color: Colors.black,
                      onTap: _isLoading ? null : _loginWithApple,
                    ),
                    const SizedBox(width: 16),
                  ],
                  _buildSocialButton(
                    icon: Icons.chat_bubble,
                    color: Colors.yellow.shade700,
                    onTap: _isLoading ? null : _loginWithKakao,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSocialButton({
    required IconData icon,
    required Color color,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Icon(icon, color: color, size: 28),
      ),
    );
  }
}
