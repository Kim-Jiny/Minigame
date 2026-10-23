import 'dart:async';
import 'package:flutter/material.dart';
import '../services/socket_service.dart';
import '../services/socket_listener_registry.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/duo_logo.dart';
import '../widgets/cartoon/floating_bg.dart';

class ServerLoadingScreen extends StatefulWidget {
  final VoidCallback onConnected;

  const ServerLoadingScreen({super.key, required this.onConnected});

  @override
  State<ServerLoadingScreen> createState() => _ServerLoadingScreenState();
}

class _ServerLoadingScreenState extends State<ServerLoadingScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );
  Timer? _checkTimer;
  int _dots = 0;
  Timer? _dotsTimer;
  int _waitSeconds = 0;
  bool _showSlowMessage = false;
  bool _hasConnected = false;

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
    _socketService.connect();

    debugPrint(
      '🔌 ServerLoadingScreen: 연결 확인 시작, isReady=${_socketService.isReady}',
    );

    // lobby_joined 이벤트도 리스닝 (서버 연결 확인용)
    _socketListeners.on('lobby_joined', (_) {
      debugPrint('🔌 ServerLoadingScreen: lobby_joined 이벤트 수신');
      _onConnected();
    });

    _checkTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      _waitSeconds++;
      debugPrint(
        '🔌 ServerLoadingScreen: 폴링 체크, isConnected=${_socketService.isConnected}',
      );

      // 10회(5초) 후 느린 연결 메시지 표시
      if (_waitSeconds >= 10 && !_showSlowMessage && mounted) {
        setState(() => _showSlowMessage = true);
      }

      if (_socketService.isReady) {
        debugPrint('🔌 ServerLoadingScreen: isReady=true 감지');
        _onConnected();
      }
    });

    // 즉시 한 번 확인
    if (_socketService.isReady) {
      debugPrint('🔌 ServerLoadingScreen: 즉시 연결됨');
      _onConnected();
    }
  }

  void _onConnected() {
    if (_hasConnected) return;
    _hasConnected = true;
    debugPrint('🔌 ServerLoadingScreen: _onConnected 호출, mounted=$mounted');
    _checkTimer?.cancel();
    _socketListeners.offAll();
    if (mounted) {
      widget.onConnected();
    }
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _dotsTimer?.cancel();
    _pulseController.dispose();
    _socketListeners.offAll();
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
      body: FloatingBackground(
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: const DuoLogo(size: 96),
                ),
                const SizedBox(height: 40),
                SizedBox(
                  width: 180,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: const LinearProgressIndicator(
                      minHeight: 10,
                      color: CandyColors.pink,
                      backgroundColor: CandyColors.creamDeep,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _loadingText,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
                const SizedBox(height: 20),
                AnimatedOpacity(
                  opacity: _showSlowMessage ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 500),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 40),
                    child: CartoonCard(
                      radius: 18,
                      shadow: 3,
                      padding: EdgeInsets.all(14),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.hourglass_bottom_rounded,
                            color: CandyColors.tangerine,
                          ),
                          SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              '연결에 시간이 걸리고 있어요.\n잠시만 기다려주세요!',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                fontWeight: FontWeight.w800,
                                color: CandyColors.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
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
