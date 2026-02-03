import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  String? _jwtToken;

  String? get jwtToken => _jwtToken;

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
      Uri.parse('${AppConfig.serverUrl}/api/auth/google'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'idToken': idToken}),
    );

    if (response.statusCode != 200) {
      throw Exception('Google login failed: ${response.body}');
    }

    final data = jsonDecode(response.body);
    await _saveToken(data['token']);

    return AuthResponse.fromJson(data);
  }

  Future<AuthResponse> loginWithApple(
    String idToken, {
    Map<String, dynamic>? user,
  }) async {
    final response = await http.post(
      Uri.parse('${AppConfig.serverUrl}/api/auth/apple'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'idToken': idToken,
        'user': user,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Apple login failed: ${response.body}');
    }

    final data = jsonDecode(response.body);
    await _saveToken(data['token']);

    return AuthResponse.fromJson(data);
  }

  Future<AuthResponse> loginWithKakao(String accessToken) async {
    final response = await http.post(
      Uri.parse('${AppConfig.serverUrl}/api/auth/kakao'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'accessToken': accessToken}),
    );

    if (response.statusCode != 200) {
      throw Exception('Kakao login failed: ${response.body}');
    }

    final data = jsonDecode(response.body);
    await _saveToken(data['token']);

    return AuthResponse.fromJson(data);
  }

  Future<UserInfo> updateNickname(String nickname) async {
    if (_jwtToken == null) {
      throw Exception('Not authenticated');
    }

    final response = await http.put(
      Uri.parse('${AppConfig.serverUrl}/api/auth/nickname'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_jwtToken',
      },
      body: jsonEncode({'nickname': nickname}),
    );

    if (response.statusCode != 200) {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to update nickname');
    }

    final data = jsonDecode(response.body);
    return UserInfo.fromJson(data['user']);
  }

  Future<void> deleteAccount() async {
    if (_jwtToken == null) {
      throw Exception('Not authenticated');
    }

    final response = await http.delete(
      Uri.parse('${AppConfig.serverUrl}/api/auth/account'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_jwtToken',
      },
    );

    if (response.statusCode != 200) {
      final data = jsonDecode(response.body);
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
    if (_jwtToken == null) {
      throw Exception('Not authenticated');
    }

    final response = await http.post(
      Uri.parse('${AppConfig.serverUrl}/api/inquiry'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_jwtToken',
      },
      body: jsonEncode({
        'category': category,
        'title': title,
        'content': content,
      }),
    );

    if (response.statusCode != 200) {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to submit inquiry');
    }

    return jsonDecode(response.body);
  }

  // 내 문의 목록 조회
  Future<List<Map<String, dynamic>>> getMyInquiries() async {
    if (_jwtToken == null) {
      throw Exception('Not authenticated');
    }

    final response = await http.get(
      Uri.parse('${AppConfig.serverUrl}/api/inquiry'),
      headers: {
        'Authorization': 'Bearer $_jwtToken',
      },
    );

    if (response.statusCode != 200) {
      final data = jsonDecode(response.body);
      throw Exception(data['error'] ?? 'Failed to get inquiries');
    }

    final data = jsonDecode(response.body);
    return List<Map<String, dynamic>>.from(data['inquiries']);
  }

  // 읽지 않은 답변 수 조회
  Future<int> getUnreadInquiryCount() async {
    if (_jwtToken == null) {
      return 0;
    }

    try {
      final response = await http.get(
        Uri.parse('${AppConfig.serverUrl}/api/inquiry/unread-count'),
        headers: {
          'Authorization': 'Bearer $_jwtToken',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
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
        Uri.parse('${AppConfig.serverUrl}/api/inquiry/$inquiryId/read'),
        headers: {
          'Authorization': 'Bearer $_jwtToken',
        },
      );
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
