import 'package:flutter/foundation.dart';
import '../services/remote_config_service.dart';

class AppConfig {
  // 서버 URL 설정
  // 디버그 빌드 시 tool/run_dev.sh가 현재 개발 머신의 Wi-Fi IP를 감지해서
  // --dart-define=DEV_SERVER_URL=http://<ip>:3000 으로 주입한다.
  // 주입 값이 없으면 아래 _localServerUrlFallback 으로 폴백 (IDE에서 flutter run을
  // 직접 실행하는 경우 대비).
  static const String _devServerUrlFromEnv =
      String.fromEnvironment('DEV_SERVER_URL');
  static const String _localServerUrlFallback = 'http://172.30.1.99:3000';
  static const String _productionServerUrl = 'https://duo.jiny.shop';  // 프로덕션

  // 원격 설정에서 서버 URL 가져오기
  static String get serverUrl {
    if (kDebugMode) {
      // 디버그 모드: dart-define으로 주입된 값이 있으면 우선 사용
      if (_devServerUrlFromEnv.isNotEmpty) {
        return _devServerUrlFromEnv;
      }
      return _localServerUrlFallback;
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
  static const String gameTypeNumberBattle = 'numberbattle';
  static const String gameTypeCardFlip = 'cardflip';
  static const String gameTypeMathrace = 'mathrace';
}
