import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;
import 'mixins/provider_feedback.dart';
import '../services/socket_service.dart';
import '../services/socket_listener_registry.dart';
import '../services/api_service.dart';
import '../services/device_info_service.dart';

class AuthProvider extends ChangeNotifier with ProviderFeedback {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
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

  int? get userId => _userId;
  String? get socketId => _socketId;
  String? get nickname => _nickname;
  String? get email => _email;
  String? get avatarUrl => _avatarUrl;
  bool get isLoggedIn => _isLoggedIn;

  Future<void> init() async {
    await _apiService.init();
    if (_apiService.jwtToken != null) {
      try {
        final user = await _apiService.getCurrentUser();
        await _saveUserInfo(user);
        await _connectSocket();
      } catch (_) {
        await _invalidateSession();
      }
    }

    notifyListeners();
  }

  void _handleConnect(dynamic _) {
    _socketId = _socketService.socket?.id;
    notifyListeners();
  }

  void _handleSocketDisconnected(dynamic _) {
    if (_socketId == null) return;
    _socketId = null;
    notifyListeners();
  }

  void _handleLobbyJoined(dynamic _) {
    _socketId = _socketService.socket?.id;
    notifyListeners();
  }

  void _ensureSocketListeners() {
    _socketListeners.on('connect', _handleConnect);
    _socketListeners.on('disconnect', _handleSocketDisconnected);
    _socketListeners.on('connect_error', _handleSocketDisconnected);
    _socketListeners.on('reconnect_error', _handleSocketDisconnected);
    _socketListeners.on('lobby_joined', _handleLobbyJoined);
    _socketListeners.on('auth_error', _handleAuthError);
  }

  /// 핸드셰이크 인증 정보로 소켓을 연결한다. 토큰/닉네임 등은 connection 시점에
  /// 서버로 전달되고, 서버가 인증을 마치면 lobby_joined / auth_error 로 응답한다.
  Future<void> _connectSocket() async {
    if (_nickname == null) return;
    _ensureSocketListeners();
    _socketService.setAuth(await _buildAuthPayload());
    _socketService.connect();
  }

  Future<Map<String, dynamic>> _buildAuthPayload() async {
    final deviceInfo = await DeviceInfoService().getDeviceInfo();
    final payload = <String, dynamic>{
      'nickname': _nickname,
      'avatarUrl': _avatarUrl,
      'deviceInfo': deviceInfo,
    };
    if (_userId != null) {
      payload['userId'] = _userId;
    }
    if (_apiService.jwtToken != null) {
      payload['token'] = _apiService.jwtToken;
    }
    return payload;
  }

  Future<void> _completeLogin(UserInfo user) async {
    // 소켓 auth 가 새 계정으로 설정되기 전에 '로그인됨' 으로 보이면 화면이 먼저 열려
    // 옛(게스트) auth 로 요청을 보낼 수 있다. 소켓 연결을 시작한 뒤에 로그인 상태로 만든다.
    await _saveUserInfo(user, markLoggedIn: false);
    await _connectSocket();
    _isLoggedIn = true;
  }

  Future<void> _runLoginFlow({
    required Future<UserInfo> Function() action,
    required String errorPrefix,
  }) async {
    try {
      startLoading();
      notifyListeners();

      final user = await action();
      await _completeLogin(user);
      notifyListeners();
    } catch (e) {
      // 원문 예외(스택·서버 응답 본문)는 사용자에게 보이지 않게 하고 로그에만 남긴다.
      debugPrint('$errorPrefix: $e');
      final message = _friendlyLoginError(errorPrefix, e);
      if (message != null) setError(message);
    } finally {
      setLoading(false);
      notifyListeners();
    }
  }

  /// 로그인 예외를 사용자용 문구로 바꾼다. 사용자가 직접 취소한 경우는 null(메시지 없음).
  String? _friendlyLoginError(String errorPrefix, Object e) {
    final raw = e.toString().toLowerCase();
    final provider = errorPrefix.replaceAll(' 로그인 실패', '');

    if (raw.contains('cancel') ||
        raw.contains('취소') ||
        raw.contains('sign_in_canceled') ||
        raw.contains('com.apple.authenticationservices.authorizationerror error 1001')) {
      return null;
    }
    if (raw.contains('banned')) {
      return '이용이 제한된 계정이에요. 문의하기로 연락해주세요.';
    }
    if (raw.contains('socketexception') ||
        raw.contains('failed host lookup') ||
        raw.contains('clientexception') ||
        raw.contains('timeoutexception') ||
        raw.contains('시간이 초과') ||
        raw.contains('network')) {
      return '네트워크 연결이 불안정해요. 잠시 후 다시 시도해주세요.';
    }
    if (raw.contains('failed:') && (raw.contains('500') || raw.contains('502') || raw.contains('503'))) {
      return '서버가 잠시 불안정해요. 잠시 후 다시 시도해주세요.';
    }
    return '$provider 로그인에 실패했어요. 잠시 후 다시 시도해주세요.';
  }

  Future<void> _invalidateSession() async {
    await _clearLocalSession();
    await _apiService.clearToken();
  }

  Future<void> _handleAuthError(dynamic data) async {
    debugPrint('Socket auth error: $data');
    await _invalidateSession();
    notifyListeners();
  }

  Future<void> _saveUserInfo(UserInfo user, {bool markLoggedIn = true}) async {
    _userId = user.id;
    _nickname = user.nickname;
    _email = user.email;
    _avatarUrl = user.avatarUrl;
    if (markLoggedIn) _isLoggedIn = true;

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

  Future<void> _clearLocalSession() async {
    _userId = null;
    _nickname = null;
    _email = null;
    _avatarUrl = null;
    _socketId = null;
    _isLoggedIn = false;

    _socketService.disconnect();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('nickname');
    await prefs.remove('user_id');
    await prefs.remove('email');
    await prefs.remove('avatar_url');
  }

  Future<void> _signOutSocialProviders() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}

    try {
      await kakao.UserApi.instance.logout();
    } catch (_) {}
  }

  // Google 로그인
  Future<void> loginWithGoogle() async {
    await _runLoginFlow(
      errorPrefix: 'Google 로그인 실패',
      action: () async {
        debugPrint('Google 로그인 시작: signIn()');
        final googleUser = await _googleSignIn
            .signIn()
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw Exception(
                'Google 로그인 응답 시간이 초과되었습니다. '
                'Android SHA-1 또는 Google Play 서명 설정을 확인해주세요.',
              ),
            );
        if (googleUser == null) {
          throw Exception('로그인이 취소되었습니다');
        }

        debugPrint('Google 로그인 성공: account=${googleUser.email}');
        debugPrint('Google 토큰 요청: authentication');
        final googleAuth = await googleUser.authentication.timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw Exception(
            'Google 토큰을 가져오는 중 시간이 초과되었습니다. '
            'Google Cloud/Firebase OAuth 설정을 확인해주세요.',
          ),
        );
        final idToken = googleAuth.idToken;
        if (idToken == null) {
          throw Exception('Google ID 토큰을 받지 못했습니다. Web client ID 설정을 확인해주세요.');
        }

        debugPrint('Google 토큰 수신 완료: backend login');
        final response = await _apiService.loginWithGoogle(idToken);
        return response.user;
      },
    );
  }

  // Apple 로그인
  Future<void> loginWithApple() async {
    await _runLoginFlow(
      errorPrefix: 'Apple 로그인 실패',
      action: () async {
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
        return response.user;
      },
    );
  }

  // Kakao 로그인
  Future<void> loginWithKakao() async {
    await _runLoginFlow(
      errorPrefix: '카카오 로그인 실패',
      action: () async {
        final isKakaoTalkInstalled = await kakao.isKakaoTalkInstalled();
        final token = await (isKakaoTalkInstalled
            ? kakao.UserApi.instance.loginWithKakaoTalk()
            : kakao.UserApi.instance.loginWithKakaoAccount());
        final response = await _apiService.loginWithKakao(token.accessToken);
        return response.user;
      },
    );
  }

  // 게스트 로그인 (개발용)
  Future<void> loginAsGuest(String nickname) async {
    // 심사용 테스트 계정
    if (nickname == 'appletest12') {
      await _runLoginFlow(
        errorPrefix: '테스트 로그인 실패',
        action: () async {
          final response = await _apiService.loginWithTest(nickname);
          return response.user;
        },
      );
      return;
    }

    clearFeedback();
    _nickname = nickname;
    _isLoggedIn = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nickname', nickname);

    await _connectSocket();
    notifyListeners();
  }

  // 닉네임 변경 (API 호출)
  Future<bool> updateNickname(String newNickname) async {
    try {
      startLoading();
      notifyListeners();

      final user = await _apiService.updateNickname(newNickname);

      _nickname = user.nickname;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nickname', user.nickname);

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('닉네임 변경 실패: $e');
      setError('닉네임을 바꾸지 못했어요. 잠시 후 다시 시도해주세요.');
      debugPrint(error);
      return false;
    } finally {
      setLoading(false);
      notifyListeners();
    }
  }

  // 닉네임 로컬 업데이트 (상점에서 구매 후 사용)
  Future<void> setNickname(String newNickname) async {
    _nickname = newNickname;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nickname', newNickname);
    notifyListeners();
  }

  Future<void> logout() async {
    await _clearLocalSession();
    notifyListeners();

    await _apiService.clearToken();
    await _signOutSocialProviders();
  }

  // 회원 탈퇴
  Future<bool> deleteAccount() async {
    try {
      startLoading();
      notifyListeners();

      await _apiService.deleteAccount();
      await _clearLocalSession();
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      await _signOutSocialProviders();

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('회원 탈퇴 실패: $e');
      setError('회원 탈퇴에 실패했어요. 잠시 후 다시 시도해주세요.');
      debugPrint(error);
      return false;
    } finally {
      setLoading(false);
      notifyListeners();
    }
  }
}
