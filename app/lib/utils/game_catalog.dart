class GameCatalog {
  const GameCatalog._();

  static const Map<String, String> _names = {
    'tictactoe': '틱택토',
    'infinite_tictactoe': '무한 틱택토',
    'gomoku': '오목',
    'reaction': '반응속도',
    'rps': '가위바위보',
    'speedtap': '스피드탭',
    'sequence': '순서 기억',
    'stroop': '스트룹',
    'hexagon': '헥사곤',
    'pyramid': '수식피라미드',
    'hunmin': '훈민정음',
    'numberbattle': '숫자배틀',
    'cardflip': '카드 뒤집기',
    'mathrace': '사칙연산',
  };

  static const Map<String, String> _routes = {
    'tictactoe': '/game/tictactoe',
    'infinite_tictactoe': '/game/infinite_tictactoe',
    'gomoku': '/game/gomoku',
    'reaction': '/game/reaction',
    'rps': '/game/rps',
    'speedtap': '/game/speedtap',
    'sequence': '/game/sequence',
    'stroop': '/game/stroop',
    'hexagon': '/game/hexagon',
    'pyramid': '/game/pyramid',
    'hunmin': '/game/hunmin',
    'numberbattle': '/game/numberbattle',
    'cardflip': '/game/cardflip',
    'mathrace': '/game/mathrace',
  };

  static const Set<String> _boardGames = {
    'tictactoe',
    'infinite_tictactoe',
    'gomoku',
  };

  static String nameFor(String gameType) => _names[gameType] ?? gameType;

  static String routeFor(String gameType) => _routes[gameType] ?? '/game/$gameType';

  static bool isBoardGame(String gameType) => _boardGames.contains(gameType);
}
