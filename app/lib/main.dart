import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';
import 'navigation/game_routes.dart';
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
import 'services/socket_listener_registry.dart';
import 'services/ad_service.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

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
  final remoteConfigService = RemoteConfigService();

  // Kakao SDK 초기화
  KakaoSdk.init(nativeAppKey: 'd690b18448f3f27fb7b2025b484b223a');

  // 원격 설정 초기화
  await remoteConfigService.initialize();

  runApp(MinigameApp(remoteConfigService: remoteConfigService));

  // 첫 프레임 렌더 후(앱이 포그라운드 활성 상태)에 ATT 권한 요청 → AdMob 초기화.
  // iOS ATT 프롬프트는 앱이 active 상태여야 표시되므로 runApp 이후로 미룬다.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    AdService().initialize();
  });
}

class MinigameApp extends StatelessWidget {
  final RemoteConfigService remoteConfigService;

  const MinigameApp({
    super.key,
    required this.remoteConfigService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: remoteConfigService),
        ChangeNotifierProvider(create: (_) => AuthProvider()..init()),
        ChangeNotifierProvider(create: (_) => GameProvider()),
        ChangeNotifierProvider(create: (_) => FriendProvider()),
        ChangeNotifierProvider(create: (_) => StatsProvider()),
        ChangeNotifierProvider(create: (_) => ShopProvider()),
        ChangeNotifierProvider(create: (_) => RankedProvider()),
      ],
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
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
          ...GameRoutes.buildNamedRoutes(),
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
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
  DateTime? _pausedAt;
  bool _providersInitialized = false;
  bool _userProvidersCleared = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _socketListeners.on('lobby_joined', (_) {
      if (mounted) {
        setState(() => _serverConnected = true);
      }
    });
    _socketListeners.on('disconnect', (_) {
      if (mounted) {
        setState(() => _serverConnected = false);
      }
    });
    _socketListeners.on('auth_error', (_) {
      if (mounted) {
        setState(() => _serverConnected = false);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _socketListeners.offAll();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final auth = context.read<AuthProvider>();
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed && auth.isLoggedIn) {
      // 로그인 상태면 항상 소켓 재확인
      _socketService.connect();

      final pausedDuration = _pausedAt != null
          ? DateTime.now().difference(_pausedAt!).inSeconds
          : 0;

      final reconnectCheckDelay = pausedDuration >= 30 ? 3 : 1;
      Future.delayed(Duration(seconds: reconnectCheckDelay), () {
        if (mounted && auth.isLoggedIn && !_socketService.isReady) {
          setState(() => _serverConnected = false);
        }
      });
      _pausedAt = null;
    }
  }

  void _onServerConnected() {
    if (mounted) {
      setState(() => _serverConnected = true);
    }
  }

  void _collapseToRootIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = appNavigatorKey.currentState;
      if (navigator == null || !navigator.mounted) return;
      navigator.popUntil((route) => route.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) {
    const lobbyScreen = LobbyScreen();

    return Consumer3<RemoteConfigService, AuthProvider, GameProvider>(
      child: lobbyScreen,
      builder: (context, configService, auth, game, child) {
        final isHandlingGameReconnect =
            auth.isLoggedIn &&
            !_serverConnected &&
            (game.status == GameStatus.searching ||
                game.status == GameStatus.matched ||
                game.status == GameStatus.playing);
        final shouldShowBlockingRoot =
            configService.isUnderMaintenance ||
            !auth.isLoggedIn ||
            (auth.isLoggedIn && !_serverConnected && !isHandlingGameReconnect);

        if (shouldShowBlockingRoot) {
          _collapseToRootIfNeeded();
        }

        // 점검 모드 확인
        if (configService.isUnderMaintenance) {
          return MaintenanceScreen(
            configService: configService,
            onRetry: () => configService.refresh(),
          );
        }

        if (auth.isLoggedIn) {
          _userProvidersCleared = false;
          // 로그인 유저 전용 Provider는 인증 유저일 때만 초기화
          if (auth.userId != null && !_providersInitialized) {
            _providersInitialized = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              context.read<FriendProvider>().initialize();
              context.read<StatsProvider>().initialize();
              context.read<ShopProvider>().initialize();
            });
          }

          // 서버 연결 대기
          if (!_serverConnected) {
            if (isHandlingGameReconnect) {
              return child!;
            }
            return ServerLoadingScreen(onConnected: _onServerConnected);
          }

          return child!;
        }
        _providersInitialized = false;
        if (!_userProvidersCleared) {
          _userProvidersCleared = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            context.read<FriendProvider>().resetState();
            context.read<StatsProvider>().resetState();
            context.read<ShopProvider>().resetState();
          });
        }
        return const LoginScreen();
      },
    );
  }
}
