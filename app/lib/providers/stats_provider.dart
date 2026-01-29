import 'package:flutter/foundation.dart';
import '../services/socket_service.dart';

class GameRecord {
  final int id;
  final String gameType;
  final String opponentNickname;
  final String result; // 'win', 'loss', 'draw'
  final int expGained;
  final DateTime createdAt;

  GameRecord({
    required this.id,
    required this.gameType,
    required this.opponentNickname,
    required this.result,
    required this.expGained,
    required this.createdAt,
  });

  factory GameRecord.fromJson(Map<String, dynamic> json) {
    return GameRecord(
      id: json['id'],
      gameType: json['gameType'],
      opponentNickname: json['opponentNickname'] ?? '알 수 없음',
      result: json['result'],
      expGained: json['expGained'] ?? 0,
      createdAt: DateTime.parse(json['createdAt']),
    );
  }

  String get gameTypeName {
    switch (gameType) {
      case 'tictactoe':
        return '틱택토';
      case 'infinite_tictactoe':
        return '무한 틱택토';
      default:
        return gameType;
    }
  }

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

  String get gameTypeName {
    switch (gameType) {
      case 'tictactoe':
        return '틱택토';
      case 'infinite_tictactoe':
        return '무한 틱택토';
      default:
        return gameType;
    }
  }

  double get expProgress => expToNextLevel > 0 ? exp / expToNextLevel : 0;
}

class StatsProvider extends ChangeNotifier {
  final SocketService _socketService = SocketService();

  List<GameStats> _allStats = [];
  List<GameRecord> _recentRecords = [];
  int _mileage = 0;
  bool _isLoading = false;
  String? _error;
  String? _successMessage;
  bool _listenersInitialized = false;

  List<GameStats> get allStats => _allStats;
  List<GameRecord> get recentRecords => _recentRecords;
  int get mileage => _mileage;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;

  void initialize() {
    if (!_listenersInitialized) {
      _setupSocketListeners();
      _listenersInitialized = true;
    }
    getAllStats();
    getMileage();
    getRecentRecords();
  }

  void _setupSocketListeners() {
    // 모든 통계 응답
    _socketService.on('all_stats', (data) {
      _allStats = (data['stats'] as List)
          .map((s) => GameStats.fromJson(s))
          .toList();
      _isLoading = false;
      notifyListeners();
    });

    // 최근 기록 응답
    _socketService.on('recent_records', (data) {
      _recentRecords = (data['records'] as List)
          .map((r) => GameRecord.fromJson(r))
          .toList();
      notifyListeners();
    });

    // 특정 게임 통계 응답
    _socketService.on('game_stats', (data) {
      if (data['stats'] != null) {
        final stats = GameStats.fromJson(data['stats']);
        final index = _allStats.indexWhere((s) => s.gameType == stats.gameType);
        if (index != -1) {
          _allStats[index] = stats;
        } else {
          _allStats.add(stats);
        }
      }
      _isLoading = false;
      notifyListeners();
    });

    // 통계 업데이트 (게임 종료 시)
    _socketService.on('stats_updated', (data) {
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
    _socketService.on('mileage', (data) {
      _mileage = data['mileage'] ?? 0;
      notifyListeners();
    });

    // 광고 보상 결과
    _socketService.on('ad_reward_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _mileage = data['mileage'] ?? _mileage;
        _successMessage = data['message'];
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 승률 초기화 결과
    _socketService.on('reset_stats_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        if (data['stats'] != null) {
          final stats = GameStats.fromJson(data['stats']);
          final index = _allStats.indexWhere((s) => s.gameType == stats.gameType);
          if (index != -1) {
            _allStats[index] = stats;
          }
        }
        _mileage = data['mileage'] ?? _mileage;
        _successMessage = data['message'];
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });
  }

  void getAllStats() {
    _isLoading = true;
    notifyListeners();
    _socketService.emit('get_all_stats', {});
  }

  void getGameStats(String gameType) {
    _isLoading = true;
    notifyListeners();
    _socketService.emit('get_game_stats', {'gameType': gameType});
  }

  void getMileage() {
    _socketService.emit('get_mileage', {});
  }

  void getRecentRecords({int limit = 20}) {
    _socketService.emit('get_recent_records', {'limit': limit});
  }

  void claimAdReward() {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('claim_ad_reward', {});
  }

  void resetStats(String gameType) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
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
    _error = null;
    _successMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _socketService.off('all_stats');
    _socketService.off('game_stats');
    _socketService.off('stats_updated');
    _socketService.off('recent_records');
    _socketService.off('mileage');
    _socketService.off('ad_reward_result');
    _socketService.off('reset_stats_result');
    super.dispose();
  }
}
