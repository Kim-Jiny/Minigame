import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart';
import 'providers/auth_provider.dart';
import 'providers/game_provider.dart';
import 'screens/login_screen.dart';
import 'screens/lobby_screen.dart';
import 'games/tictactoe/tictactoe_screen.dart';
import 'games/infinite_tictactoe/infinite_tictactoe_screen.dart';

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
      ],
      child: MaterialApp(
        title: '미니게임 천국',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
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
          return const LobbyScreen();
        }
        return const LoginScreen();
      },
    );
  }
}
