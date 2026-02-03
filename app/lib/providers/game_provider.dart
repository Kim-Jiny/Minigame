import 'dart:async';
import 'package:flutter/foundation.dart';
import '../services/socket_service.dart';
import '../models/shop_item.dart';

enum GameStatus {
  idle,
  searching,
  matched,
  playing,
  finished,
}

class GameProvider extends ChangeNotifier {
  final SocketService _socketService = SocketService();

  GameStatus _status = GameStatus.idle;
  String? _roomId;
  String? _opponentNickname;
  String? _opponentAvatarUrl;
  int? _opponentUserId;
  String? _currentTurn;
  List<int?> _board = List.filled(9, null);
  String? _myId;
  String? _winnerId;
  String? _winnerNickname;
  bool _isDraw = false;
  int? _myPlayerIndex;  // 내가 플레이어 0인지 1인지

  // 무한 틱택토용
  List<Map<String, dynamic>> _moveHistory = [];
  int? _removedPosition;

  // 마지막 수 위치
  int? _lastMovePosition;

  // 재경기 관련
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;
  bool _opponentLeft = false;  // 상대가 나갔는지
  bool _isInvitationGame = false;  // 친구 초대 게임인지

  // 턴 타이머 관련
  int? _turnTimeLimit;  // 턴 제한 시간 (밀리초)
  int? _turnStartTime;  // 턴 시작 시간 (서버 타임스탬프)
  int _remainingTime = 0;  // 남은 시간 (초)
  Timer? _countdownTimer;
  String? _timeoutPlayerNickname;  // 타임아웃된 플레이어

  // 하드코어 모드
  bool _isHardcore = false;  // 하드코어 모드 설정
  bool _isHardcoreGame = false;  // 현재 게임이 하드코어인지

  // 무한 모드 (틱택토에서 사용)
  bool _isInfiniteMode = false;  // 무한 모드 설정
  bool _isInfiniteGame = false;  // 현재 게임이 무한 모드인지

  // 연승 정보
  int _myStreak = 0;
  int _opponentStreak = 0;

  // 프로필 설정
  UserProfileSettings? _myProfileSettings;
  UserProfileSettings? _opponentProfileSettings;

  // 생성자에서 리스너 설정
  GameProvider() {
    _setupSocketListeners();
    _listenersInitialized = true;
  }

  // Getters
  GameStatus get status => _status;
  String? get roomId => _roomId;
  String? get opponentNickname => _opponentNickname;
  String? get opponentAvatarUrl => _opponentAvatarUrl;
  int? get opponentUserId => _opponentUserId;
  String? get currentTurn => _currentTurn;
  List<int?> get board => _board;
  bool get isMyTurn => _currentTurn == _myId;
  String? get winnerId => _winnerId;
  String? get winnerNickname => _winnerNickname;
  bool get isDraw => _isDraw;
  bool get isWinner => _winnerId == _myId;
  bool get rematchWaiting => _rematchWaiting;
  bool get opponentWantsRematch => _opponentWantsRematch;
  bool get opponentLeft => _opponentLeft;
  bool get isInvitationGame => _isInvitationGame;
  int get remainingTime => _remainingTime;
  int get turnTimeLimit => (_turnTimeLimit ?? 30000) ~/ 1000;  // 초 단위
  String? get timeoutPlayerNickname => _timeoutPlayerNickname;
  bool get isHardcore => _isHardcore;
  bool get isHardcoreGame => _isHardcoreGame;
  bool get isInfiniteMode => _isInfiniteMode;
  bool get isInfiniteGame => _isInfiniteGame;
  int? get lastMovePosition => _lastMovePosition;
  int get myStreak => _myStreak;
  int get opponentStreak => _opponentStreak;
  UserProfileSettings? get myProfileSettings => _myProfileSettings;
  UserProfileSettings? get opponentProfileSettings => _opponentProfileSettings;

  // 하드코어 모드 설정
  void setHardcoreMode(bool value) {
    _isHardcore = value;
    notifyListeners();
  }

  // 무한 모드 설정
  void setInfiniteMode(bool value) {
    _isInfiniteMode = value;
    notifyListeners();
  }

  // 무한 틱택토용 getters
  int get myPieceCount => _board.where((cell) => cell == _myPlayerIndex).length;
  int get opponentPieceCount {
    if (_myPlayerIndex == null) return 0;
    final opponentIndex = _myPlayerIndex == 0 ? 1 : 0;
    return _board.where((cell) => cell == opponentIndex).length;
  }

  // 다음에 사라질 내 말 위치
  int? get nextToDisappear {
    if (_myPlayerIndex == null || myPieceCount < 3) return null;
    // moveHistory에서 내 가장 오래된 말 찾기
    for (final move in _moveHistory) {
      if (move['player'] == _myPlayerIndex &&
          _board[move['position'] as int] == _myPlayerIndex) {
        return move['position'] as int;
      }
    }
    return null;
  }

  void initialize(String myId) {
    _myId = myId;
  }

  bool _listenersInitialized = false;

  /// 다른 게임 화면의 dispose()에서 off()를 호출해서 리스너가 제거될 수 있음
  /// 이 메서드를 호출하여 리스너를 재등록
  void ensureSocketListeners() {
    debugPrint('🎮 [GameProvider] ensureSocketListeners called, initialized: $_listenersInitialized');
    if (!_listenersInitialized) {
      _setupSocketListeners();
      _listenersInitialized = true;
    }
  }

  void _setupSocketListeners() {
    // 기존 리스너 제거 후 다시 등록
    _removeSocketListeners();
    // 소켓 연결 시 myId 자동 설정
    _socketService.on('lobby_joined', (_) {
      _myId = _socketService.socket?.id;
    });

    _socketService.on('waiting_for_match', (data) {
      debugPrint('🎮 [GameProvider] waiting_for_match received: $data');
      _status = GameStatus.searching;
      notifyListeners();
    });

    _socketService.on('match_found', (data) {
      debugPrint('🎮 match_found 전체 데이터: $data');

      // 초대 게임이고 이미 playing 상태면서 roomId가 설정되어 있으면 무시
      if (data['isInvitation'] == true && _status == GameStatus.playing && _roomId != null) {
        debugPrint('🎮 match_found 무시: 초대 게임이 이미 초기화됨 (roomId=$_roomId)');
        return;
      }

      _status = GameStatus.matched;
      _roomId = data['roomId'];
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _opponentNickname = opponent['nickname'];
      _opponentAvatarUrl = opponent['avatarUrl'];
      _opponentUserId = opponent['userId'];

      // 내 플레이어 인덱스 저장
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      // 친구 초대 게임인지 확인
      _isInvitationGame = data['isInvitation'] == true;
      _isHardcoreGame = data['isHardcore'] == true;
      _isInfiniteGame = data['isInfinite'] == true;

      // 연승 정보 (players 배열에서 추출)
      _myStreak = me != null ? (me['streak'] ?? 0) : 0;
      _opponentStreak = opponent['streak'] ?? 0;

      // 프로필 설정 (players 배열에서 추출)
      if (me != null && me['profileSettings'] != null) {
        _myProfileSettings = UserProfileSettings.fromJson(me['profileSettings']);
      }
      if (opponent['profileSettings'] != null) {
        _opponentProfileSettings = UserProfileSettings.fromJson(opponent['profileSettings']);
      }

      // 초대 게임인 경우 서버에 roomId 설정 알림 (disconnect 처리용)
      if (_isInvitationGame && _roomId != null) {
        _socketService.emit('set_room_id', {'roomId': _roomId});
        debugPrint('🎮 set_room_id emitted: $_roomId');
      }

      debugPrint('🎮 match_found - isInvitation: ${data['isInvitation']}, isHardcore: ${data['isHardcore']}, roomId: $_roomId, myStreak: $_myStreak, opponentStreak: $_opponentStreak');

      notifyListeners();
    });

    _socketService.on('game_start', (data) {
      debugPrint('🎮 game_start 데이터: $data');
      _status = GameStatus.playing;
      _currentTurn = data['currentTurn'];
      // board가 있는 게임만 처리 (틱택토, 오목 등)
      if (data['board'] != null) {
        _board = List<int?>.from(data['board']);
      }
      _winnerId = null;
      _winnerNickname = null;
      _isDraw = false;
      _moveHistory = [];
      _removedPosition = null;
      _timeoutPlayerNickname = null;
      // 재경기 상태 초기화
      _rematchWaiting = false;
      _opponentWantsRematch = false;
      _opponentLeft = false;
      // 턴 타이머 시작
      _turnTimeLimit = data['turnTimeLimit'];
      _turnStartTime = data['turnStartTime'];
      if (_turnTimeLimit != null) {
        _startCountdownTimer();
      }
      debugPrint('🎮 game_start 후 상태: status=$_status, currentTurn=$_currentTurn, myId=$_myId');
      notifyListeners();
    });

    _socketService.on('game_update', (data) {
      _board = List<int?>.from(data['board']);
      _currentTurn = data['currentTurn'];
      _timeoutPlayerNickname = null;  // 타임아웃 알림 초기화

      // 마지막 수 위치 저장
      if (data['lastMove'] != null) {
        _lastMovePosition = data['lastMove'];
      }

      // 무한 틱택토용 데이터
      if (data['moveHistory'] != null) {
        _moveHistory = List<Map<String, dynamic>>.from(
          (data['moveHistory'] as List).map((m) => Map<String, dynamic>.from(m))
        );
      }
      if (data['removedPosition'] != null) {
        _removedPosition = data['removedPosition'];
      }

      // 턴 타이머 재시작
      if (data['turnTimeLimit'] != null) {
        _turnTimeLimit = data['turnTimeLimit'];
        _turnStartTime = data['turnStartTime'];
        _startCountdownTimer();
      }

      notifyListeners();
    });

    _socketService.on('game_end', (data) {
      _status = GameStatus.finished;
      // board가 있는 게임만 처리 (틱택토, 오목 등)
      if (data['board'] != null) {
        _board = List<int?>.from(data['board']);
      }
      _winnerId = data['winner'];
      _winnerNickname = data['winnerNickname'];
      _isDraw = data['isDraw'] ?? false;
      _stopCountdownTimer();
      notifyListeners();
    });

    _socketService.on('opponent_left', (data) {
      _status = GameStatus.finished;
      _winnerId = _myId; // 상대가 나가면 승리
      _rematchWaiting = false;
      _opponentWantsRematch = false;
      _opponentLeft = true;  // 상대가 나감
      _stopCountdownTimer();
      notifyListeners();
    });

    // 턴 타임아웃
    _socketService.on('turn_timeout', (data) {
      _timeoutPlayerNickname = data['playerNickname'];
      notifyListeners();
    });

    // 재경기 관련 리스너
    _socketService.on('rematch_waiting', (data) {
      _rematchWaiting = data['waiting'] ?? false;
      notifyListeners();
    });

    _socketService.on('rematch_requested', (data) {
      _opponentWantsRematch = true;
      notifyListeners();
    });

    _socketService.on('rematch_cancelled', (data) {
      _opponentWantsRematch = false;
      notifyListeners();
    });

    _socketService.on('error', (data) {
      debugPrint('Game error: ${data['message']}');
    });
  }

  // 카운트다운 타이머 시작
  void _startCountdownTimer() {
    _stopCountdownTimer();

    if (_turnTimeLimit == null) return;

    // 턴 시작 시간을 현재 시간으로 설정 (서버-클라이언트 시간 차이 문제 해결)
    // 서버에서 turnStartTime이 오면 그 시점부터 경과 시간을 계산하되,
    // 네트워크 지연으로 인해 이미 시간이 많이 지났다면 현재 시간 기준으로 시작
    int remaining;
    if (_turnStartTime != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final elapsed = now - _turnStartTime!;
      remaining = _turnTimeLimit! - elapsed;
      // 네트워크 지연 등으로 이미 음수이면 전체 시간으로 시작
      if (remaining < 0 || remaining > _turnTimeLimit!) {
        remaining = _turnTimeLimit!;
      }
    } else {
      remaining = _turnTimeLimit!;
    }

    _remainingTime = (remaining / 1000).ceil();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingTime > 0) {
        _remainingTime--;
        notifyListeners();
      } else {
        timer.cancel();
      }
    });
  }

  // 카운트다운 타이머 정지
  void _stopCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  // 초대 게임 상태 직접 설정 (match_found/game_start 이벤트 대신 사용)
  void initializeInvitationGame({
    required String roomId,
    required List<dynamic> players,
    required String currentTurn,
    required List<dynamic> board,
    int? turnTimeLimit,
    int? turnStartTime,
  }) {
    debugPrint('🎮 initializeInvitationGame called');
    debugPrint('🎮 roomId: $roomId, currentTurn: $currentTurn');
    debugPrint('🎮 players: $players');

    _roomId = roomId;
    _myId = _socketService.socket?.id;

    final opponent = players.firstWhere((p) => p['id'] != _myId);
    final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
    _opponentNickname = opponent['nickname'];
    _opponentAvatarUrl = opponent['avatarUrl'];
    _opponentUserId = opponent['userId'];
    _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);
    _isInvitationGame = true;

    // 프로필 설정
    if (me != null && me['profileSettings'] != null) {
      _myProfileSettings = UserProfileSettings.fromJson(me['profileSettings']);
    }
    if (opponent['profileSettings'] != null) {
      _opponentProfileSettings = UserProfileSettings.fromJson(opponent['profileSettings']);
    }

    _status = GameStatus.playing;
    _currentTurn = currentTurn;
    _board = List<int?>.from(board);
    _winnerId = null;
    _winnerNickname = null;
    _isDraw = false;
    _moveHistory = [];
    _removedPosition = null;
    _rematchWaiting = false;
    _opponentWantsRematch = false;
    _opponentLeft = false;
    _timeoutPlayerNickname = null;

    // 턴 타이머 시작
    _turnTimeLimit = turnTimeLimit;
    _turnStartTime = turnStartTime;
    if (_turnTimeLimit != null && _turnStartTime != null) {
      _startCountdownTimer();
    }

    // 서버에 roomId 설정 알림 (disconnect 처리용)
    _socketService.emit('set_room_id', {'roomId': _roomId});
    debugPrint('🎮 set_room_id emitted: $_roomId');

    debugPrint('🎮 initializeInvitationGame complete: status=$_status, isMyTurn=$isMyTurn, roomId=$_roomId');
    notifyListeners();
  }

  // 비보드 게임(reaction, rps, speedtap, sequence, stroop)용 초대 게임 초기화
  void initializeNonBoardInvitationGame({
    required String roomId,
    required List<dynamic> players,
  }) {
    debugPrint('🎮 initializeNonBoardInvitationGame called');
    debugPrint('🎮 roomId: $roomId');
    debugPrint('🎮 players: $players');

    _roomId = roomId;
    _myId = _socketService.socket?.id;

    final opponent = players.firstWhere((p) => p['id'] != _myId);
    final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
    _opponentNickname = opponent['nickname'];
    _opponentAvatarUrl = opponent['avatarUrl'];
    _opponentUserId = opponent['userId'];
    _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);
    _isInvitationGame = true;

    // 프로필 설정
    if (me != null && me['profileSettings'] != null) {
      _myProfileSettings = UserProfileSettings.fromJson(me['profileSettings']);
    }
    if (opponent['profileSettings'] != null) {
      _opponentProfileSettings = UserProfileSettings.fromJson(opponent['profileSettings']);
    }

    _status = GameStatus.matched;  // 비보드 게임은 match_found/game_start에서 playing으로 변경

    // 서버에 roomId 설정 알림 (disconnect 처리용)
    _socketService.emit('set_room_id', {'roomId': _roomId});
    debugPrint('🎮 set_room_id emitted: $_roomId');

    debugPrint('🎮 initializeNonBoardInvitationGame complete: status=$_status, roomId=$_roomId');
    notifyListeners();
  }

  void findMatch(String gameType) {
    debugPrint('🎮 [GameProvider] findMatch called: gameType=$gameType, isHardcore=$_isHardcore, isInfinite=$_isInfiniteMode');
    debugPrint('🎮 [GameProvider] socket connected: ${_socketService.socket?.connected}');
    _socketService.emit('find_match', {
      'gameType': gameType,
      'isHardcore': _isHardcore,
      'isInfinite': _isInfiniteMode,
    });
  }

  void cancelMatch(String gameType) {
    _socketService.emit('cancel_match', {
      'gameType': gameType,
      'isHardcore': _isHardcore,
      'isInfinite': _isInfiniteMode,
    });
    _status = GameStatus.idle;
    notifyListeners();
  }

  void makeMove(int position) {
    if (_status != GameStatus.playing || !isMyTurn) return;

    if (_roomId == null) {
      debugPrint('🚨 makeMove error: _roomId is null! status=$_status, myId=$_myId');
      return;
    }

    debugPrint('🎮 makeMove: position=$position, roomId=$_roomId');
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'position': position},
    });
  }

  void requestRematch() {
    _socketService.emit('rematch_request', {'roomId': _roomId});
  }

  void cancelRematch() {
    _socketService.emit('rematch_cancel', {'roomId': _roomId});
    _rematchWaiting = false;
    notifyListeners();
  }

  void leaveGame() {
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    reset();
  }

  void reset() {
    _stopCountdownTimer();
    _status = GameStatus.idle;
    _roomId = null;
    _opponentNickname = null;
    _opponentAvatarUrl = null;
    _opponentUserId = null;
    _currentTurn = null;
    _board = List.filled(9, null);
    _winnerId = null;
    _winnerNickname = null;
    _isDraw = false;
    _myPlayerIndex = null;
    _moveHistory = [];
    _removedPosition = null;
    _lastMovePosition = null;
    _rematchWaiting = false;
    _opponentWantsRematch = false;
    _opponentLeft = false;
    _isInvitationGame = false;
    _isHardcoreGame = false;
    _isInfiniteGame = false;
    _turnTimeLimit = null;
    _turnStartTime = null;
    _remainingTime = 0;
    _timeoutPlayerNickname = null;
    _myStreak = 0;
    _opponentStreak = 0;
    notifyListeners();
  }

  void _removeSocketListeners() {
    _socketService.off('lobby_joined');
    _socketService.off('waiting_for_match');
    _socketService.off('match_found');
    _socketService.off('game_start');
    _socketService.off('game_update');
    _socketService.off('game_end');
    _socketService.off('opponent_left');
    _socketService.off('turn_timeout');
    _socketService.off('rematch_waiting');
    _socketService.off('rematch_requested');
    _socketService.off('rematch_cancelled');
    _socketService.off('error');
  }

  @override
  void dispose() {
    _stopCountdownTimer();
    _removeSocketListeners();
    _listenersInitialized = false;
    super.dispose();
  }
}
