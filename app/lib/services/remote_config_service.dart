import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class MaintenanceInfo {
  final bool enabled;
  final DateTime? endTime;
  final String message;

  MaintenanceInfo({
    required this.enabled,
    this.endTime,
    required this.message,
  });

  factory MaintenanceInfo.fromJson(Map<String, dynamic> json) {
    return MaintenanceInfo(
      enabled: json['enabled'] ?? false,
      endTime: json['end_time'] != null
          ? DateTime.tryParse(json['end_time'])
          : null,
      message: json['message'] ?? '서버 점검 중입니다.',
    );
  }
}

class AdConfig {
  final int mileage;
  final int dailyLimit;
  final bool bannerEnable;
  final bool rewardEnable;

  AdConfig({
    required this.mileage,
    required this.dailyLimit,
    required this.bannerEnable,
    required this.rewardEnable,
  });

  factory AdConfig.fromJson(Map<String, dynamic> json) {
    return AdConfig(
      mileage: json['mileage'] ?? 50,
      dailyLimit: json['daily_limit'] ?? 7,
      bannerEnable: json['banner_enable'] ?? true,
      rewardEnable: json['reward_enable'] ?? true,
    );
  }
}

class RemoteConfig {
  final String apiBaseUrl;
  final String webBaseUrl;
  final MaintenanceInfo maintenance;
  final AdConfig ad;

  RemoteConfig({
    required this.apiBaseUrl,
    required this.webBaseUrl,
    required this.maintenance,
    required this.ad,
  });

  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    return RemoteConfig(
      apiBaseUrl: json['api_base_url'] ?? 'https://minigame-server-jfep.onrender.com',
      webBaseUrl: json['web_base_url'] ?? 'https://minigame-server-jfep.onrender.com',
      maintenance: MaintenanceInfo.fromJson(json['maintenance'] ?? {}),
      ad: AdConfig.fromJson(json['ad'] ?? {}),
    );
  }
}

class RemoteConfigService extends ChangeNotifier {
  static final RemoteConfigService _instance = RemoteConfigService._internal();
  factory RemoteConfigService() => _instance;
  RemoteConfigService._internal();

  static const String _configUrl =
      'https://raw.githubusercontent.com/Kim-Jiny/Minigame/refs/heads/main/notice/notice.json';

  static const Duration _refreshInterval = Duration(minutes: 5);

  RemoteConfig? _config;
  Timer? _refreshTimer;
  bool _isLoading = false;
  String? _error;
  bool _fetchFailed = false;

  RemoteConfig? get config => _config;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get fetchFailed => _fetchFailed;

  String get serverUrl => _config?.apiBaseUrl ?? 'https://minigame-server-jfep.onrender.com';
  bool get isUnderMaintenance => _config?.maintenance.enabled ?? false;
  MaintenanceInfo? get maintenanceInfo => _config?.maintenance;
  AdConfig? get adConfig => _config?.ad;

  /// 서비스 초기화 및 설정 가져오기 시작
  Future<void> initialize() async {
    await fetchConfig();
    _startPeriodicRefresh();
  }

  /// 원격 설정 가져오기
  Future<void> fetchConfig() async {
    if (_isLoading) return;

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // 캐시 우회를 위해 타임스탬프 추가
      final cacheBuster = DateTime.now().millisecondsSinceEpoch;
      final urlWithCacheBuster = '$_configUrl?t=$cacheBuster';

      final response = await http.get(Uri.parse(urlWithCacheBuster))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final newConfig = RemoteConfig.fromJson(json);

        // URL이 변경되었는지 확인
        final urlChanged = _config?.apiBaseUrl != newConfig.apiBaseUrl;

        _config = newConfig;
        _fetchFailed = false;
        _error = null;

        if (urlChanged) {
          print('🔄 Server URL changed to: ${newConfig.apiBaseUrl}');
        }

        print('✅ Remote config fetched successfully');
      } else {
        throw Exception('Failed to fetch config: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ Failed to fetch remote config: $e');
      _error = e.toString();
      _fetchFailed = true;

      // 설정을 가져오지 못했을 때 기본값 사용
      _config ??= RemoteConfig.fromJson({});
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 주기적 새로고침 시작
  void _startPeriodicRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      fetchConfig();
    });
  }

  /// 강제 새로고침
  Future<void> refresh() async {
    await fetchConfig();
  }

  /// 서비스 정리
  @override
  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    super.dispose();
  }

  /// 점검 종료 시간 포맷팅
  String getMaintenanceEndTimeFormatted() {
    final endTime = _config?.maintenance.endTime;
    if (endTime == null) return '';

    final month = endTime.month;
    final day = endTime.day;
    final hour = endTime.hour;
    final minute = endTime.minute.toString().padLeft(2, '0');

    return '$month월 $day일 $hour시 $minute분';
  }
}
