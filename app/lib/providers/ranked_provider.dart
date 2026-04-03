import 'package:flutter/foundation.dart';
import 'mixins/provider_feedback.dart';
import '../services/socket_service.dart';
import '../services/socket_listener_registry.dart';
import '../utils/game_catalog.dart';

// 티어 정보
class TierInfo {
  final String name;
  final String color;

  TierInfo({required this.name, required this.color});

  static const Map<String, TierInfo> tiers = {
    'Iron': TierInfo._internal('Iron', '#5C5C5C'),
    'Bronze': TierInfo._internal('Bronze', '#CD7F32'),
    'Silver': TierInfo._internal('Silver', '#C0C0C0'),
    'Gold': TierInfo._internal('Gold', '#FFD700'),
    'Platinum': TierInfo._internal('Platinum', '#00CED1'),
    'Diamond': TierInfo._internal('Diamond', '#B9F2FF'),
    'Master': TierInfo._internal('Master', '#9B59B6'),
    'Challenger': TierInfo._internal('Challenger', '#FF4500'),
  };

  const TierInfo._internal(this.name, this.color);
}

// 랭크 통계
class RankedStats {
  final int elo;
  final String tier;
  final String tierColor;
  final int wins;
  final int losses;
  final int winStreak;
  final int maxWinStreak;
  final int winRate;
  final int totalGames;

  RankedStats({
    required this.elo,
    required this.tier,
    required this.tierColor,
    required this.wins,
    required this.losses,
    required this.winStreak,
    required this.maxWinStreak,
    required this.winRate,
    required this.totalGames,
  });

  factory RankedStats.fromJson(Map<String, dynamic> json) {
    return RankedStats(
      elo: json['elo'] ?? 1200,
      tier: json['tier'] ?? 'Gold',
      tierColor: json['tierColor'] ?? '#FFD700',
      wins: json['wins'] ?? 0,
      losses: json['losses'] ?? 0,
      winStreak: json['winStreak'] ?? 0,
      maxWinStreak: json['maxWinStreak'] ?? 0,
      winRate: json['winRate'] ?? 0,
      totalGames: json['totalGames'] ?? 0,
    );
  }

  factory RankedStats.empty() {
    return RankedStats(
      elo: 1200,
      tier: 'Gold',
      tierColor: '#FFD700',
      wins: 0,
      losses: 0,
      winStreak: 0,
      maxWinStreak: 0,
      winRate: 0,
      totalGames: 0,
    );
  }
}

// 리더보드 항목
class LeaderboardEntry {
  final int rank;
  final int userId;
  final String nickname;
  final int elo;
  final String tier;
  final String tierColor;
  final int wins;
  final int losses;
  final int winRate;

  LeaderboardEntry({
    required this.rank,
    required this.userId,
    required this.nickname,
    required this.elo,
    required this.tier,
    required this.tierColor,
    required this.wins,
    required this.losses,
    required this.winRate,
  });

  factory LeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return LeaderboardEntry(
      rank: json['rank'] ?? 0,
      userId: json['userId'] ?? 0,
      nickname: json['nickname'] ?? '',
      elo: json['elo'] ?? 1200,
      tier: json['tier'] ?? 'Gold',
      tierColor: json['tierColor'] ?? '#FFD700',
      wins: json['wins'] ?? 0,
      losses: json['losses'] ?? 0,
      winRate: json['winRate'] ?? 0,
    );
  }
}

// 랭크 매치 플레이어 정보
class RankedPlayer {
  final String id;
  final String nickname;
  final int userId;
  final int elo;
  final String tier;
  final String tierColor;

  RankedPlayer({
    required this.id,
    required this.nickname,
    required this.userId,
    required this.elo,
    required this.tier,
    required this.tierColor,
  });

  factory RankedPlayer.fromJson(Map<String, dynamic> json) {
    return RankedPlayer(
      id: json['id'] ?? '',
      nickname: json['nickname'] ?? '',
      userId: json['userId'] ?? 0,
      elo: json['elo'] ?? 1200,
      tier: json['tier'] ?? 'Gold',
      tierColor: json['tierColor'] ?? '#FFD700',
    );
  }
}

// 랭크 게임 결과
class RankedGameResult {
  final String gameType;
  final int? winnerId;

  RankedGameResult({required this.gameType, this.winnerId});

  factory RankedGameResult.fromJson(Map<String, dynamic> json) {
    return RankedGameResult(
      gameType: json['gameType'] ?? '',
      winnerId: json['winnerId'],
    );
  }
}

// 매칭 상태
enum RankedMatchStatus {
  idle,
  searching,
  found,
  playing,
  waitingNextGame,  // 게임 종료 후 다음 게임 대기 중
  finished,
}

class RankedProvider extends ChangeNotifier with ProviderFeedback {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);

  // 상태
  RankedStats? _stats = RankedStats.empty(); // 초기값으로 기본 stats 사용
  List<LeaderboardEntry> _leaderboard = [];
  int? _myRank;
  bool _listenersInitialized = false;

  // 매칭 상태
  RankedMatchStatus _matchStatus = RankedMatchStatus.idle;
  String? _roomId;
  List<String> _games = [];
  int _currentGameIndex = 0;
  String? _currentGame;
  bool _isHardcore = false;
  List<RankedPlayer> _players = [];
  List<RankedGameResult> _results = [];
  List<int> _score = [0, 0];

  // 매치 결과
  int? _matchWinnerId;
  String? _matchWinnerNickname;
  RankedStats? _winnerStats;
  RankedStats? _loserStats;
  int? _winnerEloChange;
  int? _loserEloChange;

  // Getters
  RankedStats? get stats => _stats;
  List<LeaderboardEntry> get leaderboard => _leaderboard;
  int? get myRank => _myRank;

  RankedMatchStatus get matchStatus => _matchStatus;
  String? get roomId => _roomId;
  List<String> get games => _games;
  int get currentGameIndex => _currentGameIndex;
  String? get currentGame => _currentGame;
  bool get isHardcore => _isHardcore;
  List<RankedPlayer> get players => _players;
  List<RankedGameResult> get results => _results;
  List<int> get score => _score;

  int? get matchWinnerId => _matchWinnerId;
  String? get matchWinnerNickname => _matchWinnerNickname;
  RankedStats? get winnerStats => _winnerStats;
  RankedStats? get loserStats => _loserStats;
  int? get winnerEloChange => _winnerEloChange;
  int? get loserEloChange => _loserEloChange;

  void initialize() {
    // 소켓 리스너 재등록 (연결이 끊겼다 재연결된 경우 대비)
    ensureSocketListeners();

    // 화면 진입 시 상태 정리
    if (_matchStatus == RankedMatchStatus.searching) {
      // 매칭 중이면 취소 요청
      _socketService.emit('cancel_ranked_match', {});
      _matchStatus = RankedMatchStatus.idle;
      notifyListeners();
    } else if (_matchStatus == RankedMatchStatus.finished) {
      // 이전 게임 결과 화면 상태면 리셋
      resetMatchState();
    }
    getRankedStats();
  }

  // 소켓 리스너 재등록 (연결 상태 변경 후 필요)
  void ensureSocketListeners() {
    debugPrint('🎮 [RankedProvider] ensureSocketListeners called, initialized: $_listenersInitialized');
    if (_listenersInitialized) return;
    _setupSocketListeners();
    _listenersInitialized = true;
  }

  void _setupSocketListeners() {
    // 로비 재입장 시 데이터 동기화
    _socketListeners.on('lobby_joined', (_) {
      getRankedStats();
      getMyRank();
    });

    // 랭크 통계 응답
    _socketListeners.on('ranked_stats', (data) {
      if (data['stats'] != null) {
        _stats = RankedStats.fromJson(data['stats']);
      } else {
        // 서버에서 stats가 없는 경우 기본값 사용
        _stats = RankedStats.empty();
      }
      setLoading(false);
      notifyListeners();
    });

    // 리더보드 응답
    _socketListeners.on('leaderboard', (data) {
      _leaderboard = (data['leaderboard'] as List?)
              ?.map((e) => LeaderboardEntry.fromJson(e))
              .toList() ??
          [];
      setLoading(false);
      notifyListeners();
    });

    // 내 순위 응답
    _socketListeners.on('my_rank', (data) {
      _myRank = data['rank'];
      notifyListeners();
    });

    // 매칭 대기 중
    _socketListeners.on('waiting_for_ranked_match', (data) {
      _matchStatus = RankedMatchStatus.searching;
      notifyListeners();
    });

    // 매칭 취소됨
    _socketListeners.on('ranked_match_cancelled', (data) {
      _matchStatus = RankedMatchStatus.idle;
      notifyListeners();
    });

    // 매칭 성공
    _socketListeners.on('ranked_match_found', (data) {
      _matchStatus = RankedMatchStatus.found;
      _roomId = data['roomId'];
      _games = List<String>.from(data['games'] ?? []);
      _currentGameIndex = data['currentGameIndex'] ?? 0;
      _currentGame = data['currentGame'];
      _isHardcore = data['isHardcore'] ?? false;
      _players = (data['players'] as List?)
              ?.map((e) => RankedPlayer.fromJson(e))
              .toList() ??
          [];
      _results = [];
      _score = [0, 0];
      notifyListeners();
    });

    // 랭크 게임 시작
    _socketListeners.on('ranked_game_start', (data) {
      debugPrint('🎮 [RankedProvider] ranked_game_start received: $data');
      debugPrint('🎮 [RankedProvider] BEFORE - status: $_matchStatus, gameIndex: $_currentGameIndex, currentGame: $_currentGame');
      _matchStatus = RankedMatchStatus.playing;
      _currentGameIndex = data['gameIndex'] ?? 0;
      _currentGame = data['gameType'];
      _isHardcore = data['isHardcore'] ?? false;
      if (data['results'] != null) {
        _results = (data['results'] as List)
            .map((e) => RankedGameResult.fromJson(e))
            .toList();
      }
      debugPrint('🎮 [RankedProvider] AFTER - status: $_matchStatus, gameIndex: $_currentGameIndex, currentGame: $_currentGame');
      debugPrint('🎮 [RankedProvider] Calling notifyListeners()...');
      notifyListeners();
      debugPrint('🎮 [RankedProvider] notifyListeners() called');
    });

    // 랭크 개별 게임 종료
    _socketListeners.on('ranked_game_end', (data) {
      debugPrint('🎮 [RankedProvider] ranked_game_end received: $data');
      debugPrint('🎮 [RankedProvider] BEFORE - status: $_matchStatus, score: $_score');
      if (data['results'] != null) {
        _results = (data['results'] as List)
            .map((e) => RankedGameResult.fromJson(e))
            .toList();
      }
      if (data['score'] != null) {
        _score = List<int>.from(data['score']);
      }
      // Bo3가 끝나지 않았으면 다음 게임 대기 상태로
      // 2승 이상인 경우 ranked_match_end가 올 것이므로 여기서는 waitingNextGame으로 설정
      if (_score[0] < 2 && _score[1] < 2) {
        _matchStatus = RankedMatchStatus.waitingNextGame;
        _currentGame = null;  // 다음 게임 시작 전까지 null로 설정
        debugPrint('🎮 [RankedProvider] Setting to waitingNextGame, score: ${_score[0]}-${_score[1]}');
      }
      debugPrint('🎮 [RankedProvider] AFTER - status: $_matchStatus, currentGame: $_currentGame');
      notifyListeners();
    });

    // 랭크 매치 종료
    _socketListeners.on('ranked_match_end', (data) {
      _matchStatus = RankedMatchStatus.finished;
      _matchWinnerId = data['winnerId'];
      _matchWinnerNickname = data['winnerNickname'];
      if (data['winnerStats'] != null) {
        _winnerStats = RankedStats.fromJson(data['winnerStats']);
      }
      if (data['loserStats'] != null) {
        _loserStats = RankedStats.fromJson(data['loserStats']);
      }
      _winnerEloChange = data['winnerEloChange'];
      _loserEloChange = data['loserEloChange'];

      // 내 통계 갱신
      getRankedStats();
      notifyListeners();
    });
  }

  // 랭크 통계 조회
  void getRankedStats() {
    setLoading(true);
    notifyListeners();
    _socketService.emit('get_ranked_stats', {});

    // 3초 후에도 응답이 없으면 기본값 사용
    Future.delayed(const Duration(seconds: 3), () {
      if (isLoading && _stats == null) {
        _stats = RankedStats.empty();
        setLoading(false);
        notifyListeners();
      }
    });
  }

  // 리더보드 조회
  void getLeaderboard({int limit = 100, int offset = 0}) {
    setLoading(true);
    notifyListeners();
    _socketService.emit('get_leaderboard', {'limit': limit, 'offset': offset});
  }

  // 내 순위 조회
  void getMyRank() {
    _socketService.emit('get_my_rank', {});
  }

  // 랭크 매칭 시작
  void findRankedMatch() {
    _matchStatus = RankedMatchStatus.searching;
    clearFeedback();
    notifyListeners();
    _socketService.emit('find_ranked_match', {});
  }

  // 랭크 매칭 취소
  void cancelRankedMatch() {
    _socketService.emit('cancel_ranked_match', {});
    _matchStatus = RankedMatchStatus.idle;
    notifyListeners();
  }

  // 상태 초기화
  void resetMatchState() {
    _matchStatus = RankedMatchStatus.idle;
    _roomId = null;
    _games = [];
    _currentGameIndex = 0;
    _currentGame = null;
    _isHardcore = false;
    _players = [];
    _results = [];
    _score = [0, 0];
    _matchWinnerId = null;
    _matchWinnerNickname = null;
    _winnerStats = null;
    _loserStats = null;
    _winnerEloChange = null;
    _loserEloChange = null;
    notifyListeners();
  }

  // 게임 타입 한글 이름
  String getGameTypeName(String gameType) {
    return GameCatalog.nameFor(gameType);
  }

  @override
  void dispose() {
    _socketListeners.offAll();
    super.dispose();
  }
}
