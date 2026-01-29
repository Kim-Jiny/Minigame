class AppConfig {
  // 개발 환경: 맥의 로컬 IP (같은 WiFi 네트워크에서 접근 가능)
  // 실제 배포시 맥미니 서버 IP로 변경
  static const String serverUrl = 'http://172.30.1.66:3000';

  // 게임 타입 상수
  static const String gameTypeTicTacToe = 'tictactoe';
  static const String gameTypeInfiniteTicTacToe = 'infinite_tictactoe';
}
