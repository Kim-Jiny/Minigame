import 'package:flutter/foundation.dart';
import 'mixins/provider_feedback.dart';
import '../services/socket_service.dart';
import '../services/socket_listener_registry.dart';
import '../utils/game_catalog.dart';

class GameRecord {
  final int id;
  final String gameType;
  final String opponentNickname;
  final String result; // 'win', 'loss', 'draw'
  final int expGained;
  final DateTime createdAt;
  final bool isRanked;
  final String? rankedMatchId;
  final int? rankedGameIndex;

  GameRecord({
    required this.id,
    required this.gameType,
    required this.opponentNickname,
    required this.result,
    required this.expGained,
    required this.createdAt,
    this.isRanked = false,
    this.rankedMatchId,
    this.rankedGameIndex,
  });

  factory GameRecord.fromJson(Map<String, dynamic> json) {
    return GameRecord(
      id: json['id'],
      gameType: json['gameType'],
      opponentNickname: json['opponentNickname'] ?? '알 수 없음',
      result: json['result'],
      expGained: json['expGained'] ?? 0,
      createdAt: DateTime.parse(json['createdAt']),
      isRanked: json['isRanked'] ?? false,
      rankedMatchId: json['rankedMatchId'],
      rankedGameIndex: json['rankedGameIndex'],
    );
  }

  String get gameTypeName => GameCatalog.nameFor(gameType);

  String get resultText {
    switch (result) {
      case 'win':
        return '승리';
      case 'loss':
        return '패배';
      case 'draw':
        return '무승부';
      default:
        return result;
    }
  }
}

class GameStats {
  final String gameType;
  final int wins;
  final int losses;
  final int draws;
  final int level;
  final int exp;
  final int winRate;
  final int totalGames;
  final int expToNextLevel;

  GameStats({
    required this.gameType,
    required this.wins,
    required this.losses,
    required this.draws,
    required this.level,
    required this.exp,
    required this.winRate,
    required this.totalGames,
    required this.expToNextLevel,
  });

  factory GameStats.fromJson(Map<String, dynamic> json) {
    return GameStats(
      gameType: json['gameType'],
      wins: json['wins'] ?? 0,
      losses: json['losses'] ?? 0,
      draws: json['draws'] ?? 0,
      level: json['level'] ?? 1,
      exp: json['exp'] ?? 0,
      winRate: json['winRate'] ?? 0,
      totalGames: json['totalGames'] ?? 0,
      expToNextLevel: json['expToNextLevel'] ?? 100,
    );
  }

  String get gameTypeName => GameCatalog.nameFor(gameType);

  double get expProgress => expToNextLevel > 0 ? exp / expToNextLevel : 0;
}

class StatsProvider extends ChangeNotifier with ProviderFeedback {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);

  List<GameStats> _allStats = [];
  List<GameRecord> _recentRecords = [];
  int _mileage = 0;
  int _currentStreak = 0;
  int _lastCoinsEarned = 0;
  bool _lastStreakBonus = false;
  bool _listenersInitialized = false;

  // 광고 상태
  int _adRemaining = 0;
  int _adDailyLimit = 7;
  int _adRewardCoins = 50;
  bool _adEnabled = true;
  bool _hasFetchedInitialData = false;

  List<GameStats> get allStats => _allStats;
  List<GameRecord> get recentRecords => _recentRecords;
  int get mileage => _mileage;
  int get coins => _mileage; // alias for mileage
  int get currentStreak => _currentStreak;
  int get lastCoinsEarned => _lastCoinsEarned;
  bool get lastStreakBonus => _lastStreakBonus;
  int get adRemaining => _adRemaining;
  int get adDailyLimit => _adDailyLimit;
  int get adRewardCoins => _adRewardCoins;
  bool get adEnabled => _adEnabled;
  bool get hasFetchedInitialData => _hasFetchedInitialData;

  void initialize() {
    if (!_listenersInitialized) {
      _setupSocketListeners();
      _listenersInitialized = true;
    }
    if (_socketService.isReady) {
      refreshAll();
    }
  }

  void refreshAll() {
    _hasFetchedInitialData = true;
    getAllStats();
    getMileage();
    getRecentRecords();
    getAdStatus();
  }

  void _setupSocketListeners() {
    // 로비 재입장 시 데이터 동기화
    _socketListeners.on('lobby_joined', (_) {
      refreshAll();
    });

    // 모든 통계 응답
    _socketListeners.on('all_stats', (data) {
      _allStats = (data['stats'] as List)
          .map((s) => GameStats.fromJson(s))
          .toList();
      setLoading(false);
      notifyListeners();
    });

    // 최근 기록 응답
    _socketListeners.on('recent_records', (data) {
      _recentRecords = (data['records'] as List)
          .map((r) => GameRecord.fromJson(r))
          .toList();
      notifyListeners();
    });

    // 특정 게임 통계 응답
    _socketListeners.on('game_stats', (data) {
      if (data['stats'] != null) {
        final stats = GameStats.fromJson(data['stats']);
        final index = _allStats.indexWhere((s) => s.gameType == stats.gameType);
        if (index != -1) {
          _allStats[index] = stats;
        } else {
          _allStats.add(stats);
        }
      }
      setLoading(false);
      notifyListeners();
    });

    // 통계 업데이트 (게임 종료 시)
    _socketListeners.on('stats_updated', (data) {
      if (data['stats'] != null) {
        final stats = GameStats.fromJson(data['stats']);
        final index = _allStats.indexWhere((s) => s.gameType == stats.gameType);
        if (index != -1) {
          _allStats[index] = stats;
        } else {
          _allStats.add(stats);
        }
        notifyListeners();
      }
    });

    // 마일리지 응답
    _socketListeners.on('mileage', (data) {
      _mileage = data['mileage'] ?? 0;
      notifyListeners();
    });

    // 코인/연승 업데이트 (게임 종료 시)
    _socketListeners.on('coins_updated', (data) {
      _mileage = data['coins'] ?? _mileage;
      _lastCoinsEarned = data['earned'] ?? 0;
      _currentStreak = data['streak'] ?? 0;
      _lastStreakBonus = data['streakBonus'] ?? false;
      notifyListeners();
    });

    // 광고 보상 결과
    _socketListeners.on('ad_reward_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        _mileage = data['mileage'] ?? _mileage;
        if (data['remaining'] != null) {
          _adRemaining = data['remaining'];
        }
        setSuccess(data['message']);
      } else {
        if (data['remaining'] != null) {
          _adRemaining = data['remaining'];
        }
        setError(data['message']);
      }
      notifyListeners();
    });

    // 광고 상태 응답
    _socketListeners.on('ad_status', (data) {
      _adRemaining = data['remaining'] ?? 0;
      _adDailyLimit = data['dailyLimit'] ?? 7;
      _adRewardCoins = data['rewardCoins'] ?? 50;
      _adEnabled = data['enabled'] ?? true;
      notifyListeners();
    });

    // 승률 초기화 결과
    _socketListeners.on('reset_stats_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        if (data['stats'] != null) {
          final stats = GameStats.fromJson(data['stats']);
          final index = _allStats.indexWhere((s) => s.gameType == stats.gameType);
          if (index != -1) {
            _allStats[index] = stats;
          }
        }
        _mileage = data['mileage'] ?? _mileage;
        setSuccess(data['message']);
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });
  }

  void getAllStats() {
    setLoading(true);
    notifyListeners();
    _socketService.emit('get_all_stats', {});
  }

  void getGameStats(String gameType) {
    setLoading(true);
    notifyListeners();
    _socketService.emit('get_game_stats', {'gameType': gameType});
  }

  void getMileage() {
    _socketService.emit('get_mileage', {});
  }

  void getAdStatus() {
    _socketService.emit('get_ad_status', {});
  }

  void getRecentRecords({int limit = 20}) {
    _socketService.emit('get_recent_records', {'limit': limit});
  }

  void claimAdReward() {
    startLoading();
    notifyListeners();
    _socketService.emit('claim_ad_reward', {});
  }

  void resetStats(String gameType) {
    startLoading();
    notifyListeners();
    _socketService.emit('reset_stats', {'gameType': gameType});
  }

  GameStats? getStatsForGame(String gameType) {
    try {
      return _allStats.firstWhere((s) => s.gameType == gameType);
    } catch (_) {
      return null;
    }
  }

  void clearMessages() {
    clearFeedback();
    notifyListeners();
  }

  void resetState() {
    _allStats = [];
    _recentRecords = [];
    _mileage = 0;
    _currentStreak = 0;
    _lastCoinsEarned = 0;
    _lastStreakBonus = false;
    _adRemaining = 0;
    _adDailyLimit = 7;
    _adRewardCoins = 50;
    _adEnabled = true;
    _hasFetchedInitialData = false;
    clearFeedback();
    notifyListeners();
  }

  @override
  void dispose() {
    _socketListeners.offAll();
    super.dispose();
  }
}
