import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;
import '../services/socket_service.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  final SocketService _socketService = SocketService();
  final ApiService _apiService = ApiService();
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    serverClientId: '78188753964-2seg33bne8kp65o2h6ts7e99fji52dg6.apps.googleusercontent.com',
  );

  int? _userId;
  String? _nickname;
  String? _email;
  String? _avatarUrl;
  String? _socketId;
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _error;

  int? get userId => _userId;
  String? get socketId => _socketId;
  String? get nickname => _nickname;
  String? get email => _email;
  String? get avatarUrl => _avatarUrl;
  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> init() async {
    await _apiService.init();
    final prefs = await SharedPreferences.getInstance();
    _nickname = prefs.getString('nickname');
    _userId = prefs.getInt('user_id');
    _email = prefs.getString('email');
    _avatarUrl = prefs.getString('avatar_url');
    _isLoggedIn = _nickname != null && _apiService.jwtToken != null;

    if (_isLoggedIn) {
      _connectSocket();
    }

    notifyListeners();
  }

  void _connectSocket() {
    _socketService.connect();

    _socketService.on('connect', (_) {
      _socketService.emit('join_lobby', {
        'nickname': _nickname,
        'userId': _userId,
      });
      _socketId = _socketService.socket?.id;
      notifyListeners();
    });

    _socketService.on('lobby_joined', (_) {
      _socketId = _socketService.socket?.id;
      notifyListeners();
    });

    if (_socketService.isConnected) {
      _socketService.emit('join_lobby', {
        'nickname': _nickname,
        'userId': _userId,
      });
      _socketId = _socketService.socket?.id;
    }
  }

  Future<void> _saveUserInfo(UserInfo user) async {
    _userId = user.id;
    _nickname = user.nickname;
    _email = user.email;
    _avatarUrl = user.avatarUrl;
    _isLoggedIn = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('user_id', user.id);
    await prefs.setString('nickname', user.nickname);
    if (user.email != null) {
      await prefs.setString('email', user.email!);
    }
    if (user.avatarUrl != null) {
      await prefs.setString('avatar_url', user.avatarUrl!);
    }
  }

  // Google 로그인
  Future<void> loginWithGoogle() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        _isLoading = false;
        notifyListeners();
        return;
      }

      final googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;

      if (idToken == null) {
        throw Exception('Failed to get Google ID token');
      }

      final response = await _apiService.loginWithGoogle(idToken);
      await _saveUserInfo(response.user);

      _connectSocket();
      notifyListeners();
    } catch (e) {
      _error = 'Google 로그인 실패: $e';
      debugPrint(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Apple 로그인
  Future<void> loginWithApple() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      // Apple Sign In은 iOS/macOS에서만 지원
      if (!Platform.isIOS && !Platform.isMacOS) {
        throw Exception('Apple Sign In is only available on iOS/macOS');
      }

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      final idToken = credential.identityToken;
      if (idToken == null) {
        throw Exception('Failed to get Apple ID token');
      }

      // Apple은 최초 로그인시에만 사용자 정보 제공
      Map<String, dynamic>? userInfo;
      if (credential.givenName != null || credential.familyName != null) {
        userInfo = {
          'name': {
            'firstName': credential.givenName,
            'lastName': credential.familyName,
          },
          'email': credential.email,
        };
      }

      final response = await _apiService.loginWithApple(idToken, user: userInfo);
      await _saveUserInfo(response.user);

      _connectSocket();
      notifyListeners();
    } catch (e) {
      _error = 'Apple 로그인 실패: $e';
      debugPrint(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Kakao 로그인
  Future<void> loginWithKakao() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      kakao.OAuthToken token;

      // 카카오톡 앱이 설치되어 있으면 앱으로 로그인, 아니면 웹으로 로그인
      if (await kakao.isKakaoTalkInstalled()) {
        token = await kakao.UserApi.instance.loginWithKakaoTalk();
      } else {
        token = await kakao.UserApi.instance.loginWithKakaoAccount();
      }

      final accessToken = token.accessToken;

      final response = await _apiService.loginWithKakao(accessToken);
      await _saveUserInfo(response.user);

      _connectSocket();
      notifyListeners();
    } catch (e) {
      _error = '카카오 로그인 실패: $e';
      debugPrint(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // 게스트 로그인 (개발용)
  Future<void> loginAsGuest(String nickname) async {
    _nickname = nickname;
    _isLoggedIn = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nickname', nickname);

    _connectSocket();
    notifyListeners();
  }

  // 닉네임 변경
  Future<bool> updateNickname(String newNickname) async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final user = await _apiService.updateNickname(newNickname);

      _nickname = user.nickname;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nickname', user.nickname);

      notifyListeners();
      return true;
    } catch (e) {
      _error = '닉네임 변경 실패: $e';
      debugPrint(_error);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    // 먼저 상태 변경 (UI 즉시 업데이트)
    _userId = null;
    _nickname = null;
    _email = null;
    _avatarUrl = null;
    _socketId = null;
    _isLoggedIn = false;
    notifyListeners();

    // 소켓 연결 해제
    _socketService.disconnect();

    // SharedPreferences 정리
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('nickname');
    await prefs.remove('user_id');
    await prefs.remove('email');
    await prefs.remove('avatar_url');

    await _apiService.clearToken();

    // 소셜 로그인 로그아웃 (백그라운드에서 처리)
    try {
      await _googleSignIn.signOut();
    } catch (_) {}

    try {
      await kakao.UserApi.instance.logout();
    } catch (_) {}
  }
}
