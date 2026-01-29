import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';
import 'providers/auth_provider.dart';
import 'providers/game_provider.dart';
import 'providers/friend_provider.dart';
import 'screens/login_screen.dart';
import 'screens/lobby_screen.dart';
import 'games/tictactoe/tictactoe_screen.dart';
import 'games/infinite_tictactoe/infinite_tictactoe_screen.dart';

// 앱 테마 색상 정의
class AppColors {
  static const primary = Color(0xFF6C5CE7);       // 파스텔 퍼플
  static const secondary = Color(0xFF74B9FF);     // 파스텔 블루
  static const accent = Color(0xFFFDCB6E);        // 파스텔 옐로우
  static const background = Color(0xFFF8F9FF);    // 연한 라벤더 배경
  static const mint = Color(0xFF00CEC9);          // 민트
  static const coral = Color(0xFFFF7675);         // 코랄
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Kakao SDK 초기화
  KakaoSdk.init(nativeAppKey: 'd690b18448f3f27fb7b2025b484b223a');

  runApp(const MinigameApp());
}

class MinigameApp extends StatelessWidget {
  const MinigameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()..init()),
        ChangeNotifierProvider(create: (_) => GameProvider()),
        ChangeNotifierProvider(create: (_) => FriendProvider()),
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
        home: const AuthWrapper(),
        routes: {
          '/login': (context) => const LoginScreen(),
          '/lobby': (context) => const LobbyScreen(),
          '/game/tictactoe': (context) => const TicTacToeScreen(),
          '/game/infinite_tictactoe': (context) => const InfiniteTicTacToeScreen(),
        },
      ),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, child) {
        if (auth.isLoggedIn) {
          // FriendProvider 초기화
          WidgetsBinding.instance.addPostFrameCallback((_) {
            context.read<FriendProvider>().initialize();
          });
          return const LobbyScreen();
        }
        return const LoginScreen();
      },
    );
  }
}
