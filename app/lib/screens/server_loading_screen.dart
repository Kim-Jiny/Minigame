import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/socket_service.dart';
import '../main.dart';

class ServerLoadingScreen extends StatefulWidget {
  final VoidCallback onConnected;

  const ServerLoadingScreen({super.key, required this.onConnected});

  @override
  State<ServerLoadingScreen> createState() => _ServerLoadingScreenState();
}

class _ServerLoadingScreenState extends State<ServerLoadingScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  Timer? _checkTimer;
  int _dots = 0;
  Timer? _dotsTimer;
  int _waitSeconds = 0;
  bool _showSlowMessage = false;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // 점 애니메이션
    _dotsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() => _dots = (_dots + 1) % 4);
      }
    });

    // 서버 연결 확인
    _startConnectionCheck();
  }

  void _startConnectionCheck() {
    _waitSeconds = 0;
    _showSlowMessage = false;

    debugPrint('🔌 ServerLoadingScreen: 연결 확인 시작, isConnected=${_socketService.isConnected}');

    // connect 이벤트 리스닝
    _socketService.on('connect', (_) {
      debugPrint('🔌 ServerLoadingScreen: connect 이벤트 수신');
      _onConnected();
    });

    // lobby_joined 이벤트도 리스닝 (서버 연결 확인용)
    _socketService.on('lobby_joined', (_) {
      debugPrint('🔌 ServerLoadingScreen: lobby_joined 이벤트 수신');
      _onConnected();
    });

    _checkTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      _waitSeconds++;
      debugPrint('🔌 ServerLoadingScreen: 폴링 체크, isConnected=${_socketService.isConnected}');

      // 10회(5초) 후 느린 연결 메시지 표시
      if (_waitSeconds >= 10 && !_showSlowMessage && mounted) {
        setState(() => _showSlowMessage = true);
      }

      if (_socketService.isConnected) {
        debugPrint('🔌 ServerLoadingScreen: isConnected=true 감지');
        _onConnected();
      }
    });

    // 즉시 한 번 확인
    if (_socketService.isConnected) {
      debugPrint('🔌 ServerLoadingScreen: 즉시 연결됨');
      _onConnected();
    }
  }

  void _onConnected() {
    debugPrint('🔌 ServerLoadingScreen: _onConnected 호출, mounted=$mounted');
    _checkTimer?.cancel();
    _socketService.off('connect');
    _socketService.off('lobby_joined');
    if (mounted) {
      widget.onConnected();
    }
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _dotsTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  String get _loadingText {
    final dots = '.' * _dots;
    final spaces = ' ' * (3 - _dots);
    return '서버 연결 중$dots$spaces';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.primary,
              Color(0xFF8B7CF7),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 로고/아이콘
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.games_rounded,
                      size: 60,
                      color: AppColors.primary,
                    ),
                  ),
                ),

                const SizedBox(height: 48),

                // 앱 이름
                const Text(
                  '듀오아레나',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 2,
                  ),
                ),

                const SizedBox(height: 48),

                // 로딩 인디케이터
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    strokeWidth: 3,
                  ),
                ),

                const SizedBox(height: 24),

                // 로딩 텍스트
                Text(
                  _loadingText,
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.white,
                    fontFamily: 'monospace',
                  ),
                ),

                const SizedBox(height: 16),

                // 느린 연결 메시지
                AnimatedOpacity(
                  opacity: _showSlowMessage ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 500),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 40),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Column(
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: Colors.white70,
                          size: 24,
                        ),
                        SizedBox(height: 8),
                        Text(
                          '연결에 시간이 걸리고 있습니다.\n잠시만 기다려주세요...',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white70,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
