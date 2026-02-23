import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';
import 'providers/auth_provider.dart';
import 'providers/game_provider.dart';
import 'providers/friend_provider.dart';
import 'providers/stats_provider.dart';
import 'providers/shop_provider.dart';
import 'providers/ranked_provider.dart';
import 'services/remote_config_service.dart';
import 'screens/login_screen.dart';
import 'screens/lobby_screen.dart';
import 'screens/maintenance_screen.dart';
import 'screens/server_loading_screen.dart';
import 'services/socket_service.dart';
import 'services/ad_service.dart';
import 'games/tictactoe/tictactoe_screen.dart';
import 'games/infinite_tictactoe/infinite_tictactoe_screen.dart';
import 'games/gomoku/gomoku_screen.dart';
import 'games/reaction/reaction_screen.dart';
import 'games/rps/rps_screen.dart';
import 'games/speedtap/speedtap_screen.dart';
import 'games/sequence/sequence_screen.dart';
import 'games/stroop/stroop_screen.dart';
import 'games/hexagon/hexagon_screen.dart';
import 'games/pyramid/pyramid_screen.dart';
import 'games/hunmin/hunmin_screen.dart';

// 앱 테마 색상 정의
class AppColors {
  static const primary = Color(0xFF6C5CE7);       // 파스텔 퍼플
  static const secondary = Color(0xFF74B9FF);     // 파스텔 블루
  static const accent = Color(0xFFFDCB6E);        // 파스텔 옐로우
  static const background = Color(0xFFF8F9FF);    // 연한 라벤더 배경
  static const mint = Color(0xFF00CEC9);          // 민트
  static const coral = Color(0xFFFF7675);         // 코랄
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Kakao SDK 초기화
  KakaoSdk.init(nativeAppKey: 'd690b18448f3f27fb7b2025b484b223a');

  // 원격 설정 초기화
  await RemoteConfigService().initialize();

  // AdMob 초기화
  AdService().initialize();

  runApp(const MinigameApp());
}

class MinigameApp extends StatelessWidget {
  const MinigameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: RemoteConfigService()),
        ChangeNotifierProvider(create: (_) => AuthProvider()..init()),
        ChangeNotifierProvider(create: (_) => GameProvider()),
        ChangeNotifierProvider(create: (_) => FriendProvider()),
        ChangeNotifierProvider(create: (_) => StatsProvider()),
        ChangeNotifierProvider(create: (_) => ShopProvider()),
        ChangeNotifierProvider(create: (_) => RankedProvider()),
      ],
      child: MaterialApp(
        title: '우리만의 게임',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.primary,
            primary: AppColors.primary,
            secondary: AppColors.secondary,
            surface: Colors.white,
          ),
          primaryColor: AppColors.primary,
          scaffoldBackgroundColor: Colors.white,
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.primary, width: 2),
            ),
            prefixIconColor: AppColors.primary,
          ),
          cardTheme: CardThemeData(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          bottomNavigationBarTheme: const BottomNavigationBarThemeData(
            selectedItemColor: AppColors.primary,
            unselectedItemColor: Colors.grey,
          ),
        ),
        builder: (context, child) {
          // 안드로이드에서 텍스트 크기 축소 (85%)
          if (Platform.isAndroid) {
            final scale = MediaQuery.of(context).textScaler.scale(1.0) * 0.85;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
              ),
              child: child!,
            );
          }
          return child!;
        },
        home: const AuthWrapper(),
        routes: {
          '/login': (context) => const LoginScreen(),
          '/lobby': (context) => const LobbyScreen(),
          '/game/tictactoe': (context) => const TicTacToeScreen(),
          '/game/infinite_tictactoe': (context) => const InfiniteTicTacToeScreen(),
          '/game/gomoku': (context) => const GomokuScreen(),
          '/game/reaction': (context) => const ReactionScreen(),
          '/game/rps': (context) => const RpsScreen(),
          '/game/speedtap': (context) => const SpeedTapScreen(),
          '/game/sequence': (context) => const SequenceScreen(),
          '/game/stroop': (context) => const StroopScreen(),
          '/game/hexagon': (context) => const HexagonScreen(),
          '/game/pyramid': (context) => const PyramidScreen(),
          '/game/hunmin': (context) => const HunminScreen(),
        },
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  bool _serverConnected = false;
  final SocketService _socketService = SocketService();
  DateTime? _pausedAt;
  bool _providersInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed && _serverConnected) {
      // 소켓 연결 확인 및 재연결 (SocketService가 알아서 처리)
      _socketService.connect();

      // 30초 이상 백그라운드에 있었으면 연결 상태 체크
      final pausedDuration = _pausedAt != null
          ? DateTime.now().difference(_pausedAt!).inSeconds
          : 0;

      if (pausedDuration >= 30) {
        // 3초 후 연결 상태 체크
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && !_socketService.isConnected) {
            setState(() => _serverConnected = false);
          }
        });
      }
      _pausedAt = null;
    }
  }

  void _onServerConnected() {
    if (mounted) {
      setState(() => _serverConnected = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<RemoteConfigService, AuthProvider>(
      builder: (context, configService, auth, child) {
        // 점검 모드 확인
        if (configService.isUnderMaintenance) {
          return MaintenanceScreen(
            configService: configService,
            onRetry: () => configService.refresh(),
          );
        }

        if (auth.isLoggedIn) {
          // FriendProvider, StatsProvider, ShopProvider 초기화
          if (!_providersInitialized) {
            _providersInitialized = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              context.read<FriendProvider>().initialize();
              context.read<StatsProvider>().initialize();
              context.read<ShopProvider>().initialize();
            });
          }

          // 서버 연결 대기
          if (!_serverConnected) {
            return ServerLoadingScreen(onConnected: _onServerConnected);
          }

          return const LobbyScreen();
        }
        _providersInitialized = false;
        return const LoginScreen();
      },
    );
  }
}
