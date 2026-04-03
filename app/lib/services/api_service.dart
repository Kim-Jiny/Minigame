import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  static const _timeout = Duration(seconds: 10);

  String? _jwtToken;

  String? get jwtToken => _jwtToken;

  Uri _buildUri(String path) => Uri.parse('${AppConfig.serverUrl}$path');

  Map<String, String> _headers({bool authenticated = false}) {
    if (!authenticated) {
      return {'Content-Type': 'application/json'};
    }

    if (_jwtToken == null) {
      throw Exception('Not authenticated');
    }

    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_jwtToken',
    };
  }

  Map<String, dynamic> _decodeJsonResponse(http.Response response) {
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _jwtToken = prefs.getString('jwt_token');
  }

  Future<void> _saveToken(String token) async {
    _jwtToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('jwt_token', token);
  }

  Future<void> clearToken() async {
    _jwtToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
  }

  Future<AuthResponse> loginWithGoogle(String idToken) async {
    final response = await http.post(
      _buildUri('/api/auth/google'),
      headers: _headers(),
      body: jsonEncode({'idToken': idToken}),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Google login failed: ${response.body}');
    }

    final data = _decodeJsonResponse(response);
    await _saveToken(data['token']);

    return AuthResponse.fromJson(data);
  }

  Future<AuthResponse> loginWithApple(
    String idToken, {
    Map<String, dynamic>? user,
  }) async {
    final response = await http.post(
      _buildUri('/api/auth/apple'),
      headers: _headers(),
      body: jsonEncode({
        'idToken': idToken,
        'user': user,
      }),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Apple login failed: ${response.body}');
    }

    final data = _decodeJsonResponse(response);
    await _saveToken(data['token']);

    return AuthResponse.fromJson(data);
  }

  Future<AuthResponse> loginWithKakao(String accessToken) async {
    final response = await http.post(
      _buildUri('/api/auth/kakao'),
      headers: _headers(),
      body: jsonEncode({'accessToken': accessToken}),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Kakao login failed: ${response.body}');
    }

    final data = _decodeJsonResponse(response);
    await _saveToken(data['token']);

    return AuthResponse.fromJson(data);
  }

  Future<AuthResponse> loginWithTest(String nickname) async {
    final response = await http.post(
      _buildUri('/api/auth/test'),
      headers: _headers(),
      body: jsonEncode({'nickname': nickname}),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('Test login failed: ${response.body}');
    }

    final data = _decodeJsonResponse(response);
    await _saveToken(data['token']);

    return AuthResponse.fromJson(data);
  }

  Future<UserInfo> getCurrentUser() async {
    final response = await http.get(
      _buildUri('/api/auth/me'),
      headers: _headers(authenticated: true),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      final data = _decodeJsonResponse(response);
      throw Exception(data['error'] ?? 'Failed to fetch current user');
    }

    final data = _decodeJsonResponse(response);
    return UserInfo.fromJson(data['user']);
  }

  Future<UserInfo> updateNickname(String nickname) async {
    final response = await http.put(
      _buildUri('/api/auth/nickname'),
      headers: _headers(authenticated: true),
      body: jsonEncode({'nickname': nickname}),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      final data = _decodeJsonResponse(response);
      throw Exception(data['error'] ?? 'Failed to update nickname');
    }

    final data = _decodeJsonResponse(response);
    return UserInfo.fromJson(data['user']);
  }

  Future<void> deleteAccount() async {
    final response = await http.delete(
      _buildUri('/api/auth/account'),
      headers: _headers(authenticated: true),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      final data = _decodeJsonResponse(response);
      throw Exception(data['error'] ?? 'Failed to delete account');
    }

    await clearToken();
  }

  // 문의 등록
  Future<Map<String, dynamic>> submitInquiry({
    required String category,
    required String title,
    required String content,
  }) async {
    final response = await http.post(
      _buildUri('/api/inquiry'),
      headers: _headers(authenticated: true),
      body: jsonEncode({
        'category': category,
        'title': title,
        'content': content,
      }),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      final data = _decodeJsonResponse(response);
      throw Exception(data['error'] ?? 'Failed to submit inquiry');
    }

    return _decodeJsonResponse(response);
  }

  // 내 문의 목록 조회
  Future<List<Map<String, dynamic>>> getMyInquiries() async {
    final response = await http.get(
      _buildUri('/api/inquiry'),
      headers: _headers(authenticated: true),
    ).timeout(_timeout);

    if (response.statusCode != 200) {
      final data = _decodeJsonResponse(response);
      throw Exception(data['error'] ?? 'Failed to get inquiries');
    }

    final data = _decodeJsonResponse(response);
    return List<Map<String, dynamic>>.from(data['inquiries']);
  }

  // 읽지 않은 답변 수 조회
  Future<int> getUnreadInquiryCount() async {
    if (_jwtToken == null) {
      return 0;
    }

    try {
      final response = await http.get(
        _buildUri('/api/inquiry/unread-count'),
        headers: _headers(authenticated: true),
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final data = _decodeJsonResponse(response);
        return data['count'] ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  // 문의 읽음 처리
  Future<void> markInquiryAsRead(int inquiryId) async {
    if (_jwtToken == null) return;

    try {
      await http.put(
        _buildUri('/api/inquiry/$inquiryId/read'),
        headers: _headers(authenticated: true),
      ).timeout(_timeout);
    } catch (_) {}
  }
}

class AuthResponse {
  final String token;
  final UserInfo user;

  AuthResponse({required this.token, required this.user});

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    return AuthResponse(
      token: json['token'],
      user: UserInfo.fromJson(json['user']),
    );
  }
}

class UserInfo {
  final int id;
  final String nickname;
  final String? email;
  final String? avatarUrl;

  UserInfo({
    required this.id,
    required this.nickname,
    this.email,
    this.avatarUrl,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      id: json['id'],
      nickname: json['nickname'],
      email: json['email'],
      avatarUrl: json['avatarUrl'],
    );
  }
}
