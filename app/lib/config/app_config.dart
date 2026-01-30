import '../services/remote_config_service.dart';

class AppConfig {
  // 기본 서버 URL (원격 설정을 가져오기 전에 사용)
  static const String _defaultServerUrl = 'http://172.30.1.66:3000';

  // 원격 설정에서 서버 URL 가져오기
  static String get serverUrl {
    final remoteConfig = RemoteConfigService();
    return remoteConfig.config?.apiBaseUrl ?? _defaultServerUrl;
  }

  // 게임 타입 상수
  static const String gameTypeTicTacToe = 'tictactoe';
  static const String gameTypeInfiniteTicTacToe = 'infinite_tictactoe';
  static const String gameTypeGomoku = 'gomoku';
}
