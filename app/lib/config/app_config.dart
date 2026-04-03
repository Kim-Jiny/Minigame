import 'package:flutter/foundation.dart';
import '../services/remote_config_service.dart';

class AppConfig {
  // 서버 URL 설정
  static const String _localServerUrl = 'http://172.30.1.99:3000';  // 로컬 개발용
  static const String _productionServerUrl = 'https://duo.jiny.shop';  // 프로덕션

  // 원격 설정에서 서버 URL 가져오기
  static String get serverUrl {
    if (kDebugMode) {
      // 디버그 모드: 항상 로컬 서버 사용
      return _localServerUrl;
    }
    final remoteConfig = RemoteConfigService();
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
  static const String gameTypeHexagon = 'hexagon';
  static const String gameTypePyramid = 'pyramid';
  static const String gameTypeHunmin = 'hunmin';
}
