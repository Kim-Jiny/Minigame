import 'package:flutter/foundation.dart';
import '../services/remote_config_service.dart';

class AppConfig {
  // 서버 URL 설정
  static const String _localServerUrl = 'http://172.30.1.66:3000';  // 로컬 개발용
  static const String _productionServerUrl = 'https://minigame-server-jfep.onrender.com';  // 프로덕션

  // 기본 서버 URL (Debug면 로컬, Release면 프로덕션)
  static String get _defaultServerUrl => kDebugMode ? _localServerUrl : _productionServerUrl;

  // 원격 설정에서 서버 URL 가져오기
  static String get serverUrl {
    final remoteConfig = RemoteConfigService();
    if (kDebugMode) {
      // 디버그 모드: debug_api_base_url 사용, 없으면 로컬 서버
      return remoteConfig.config?.debugApiBaseUrl ?? _localServerUrl;
    }
    return remoteConfig.config?.apiBaseUrl ?? _productionServerUrl;
  }

  // 게임 타입 상수
  static const String gameTypeTicTacToe = 'tictactoe';
  static const String gameTypeInfiniteTicTacToe = 'infinite_tictactoe';
  static const String gameTypeGomoku = 'gomoku';
  static const String gameTypeReaction = 'reaction';
  static const String gameTypeRps = 'rps';
  static const String gameTypeSpeedTap = 'speedtap';
  static const String gameTypeSequence = 'sequence';
  static const String gameTypeStroop = 'stroop';
}
