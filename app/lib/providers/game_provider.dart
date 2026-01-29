import 'package:flutter/foundation.dart';
import '../services/socket_service.dart';

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

  // Getters
  GameStatus get status => _status;
  String? get roomId => _roomId;
  String? get opponentNickname => _opponentNickname;
  String? get currentTurn => _currentTurn;
  List<int?> get board => _board;
  bool get isMyTurn => _currentTurn == _myId;
  String? get winnerId => _winnerId;
  String? get winnerNickname => _winnerNickname;
  bool get isDraw => _isDraw;
  bool get isWinner => _winnerId == _myId;

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
    _setupSocketListeners();
  }

  void _setupSocketListeners() {
    _socketService.on('waiting_for_match', (data) {
      _status = GameStatus.searching;
      notifyListeners();
    });

    _socketService.on('match_found', (data) {
      _status = GameStatus.matched;
      _roomId = data['roomId'];
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
      _opponentNickname = opponent['nickname'];

      // 내 플레이어 인덱스 저장
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      notifyListeners();
    });

    _socketService.on('game_start', (data) {
      _status = GameStatus.playing;
      _currentTurn = data['currentTurn'];
      _board = List<int?>.from(data['board']);
      _winnerId = null;
      _winnerNickname = null;
      _isDraw = false;
      _moveHistory = [];
      _removedPosition = null;
      notifyListeners();
    });

    _socketService.on('game_update', (data) {
      _board = List<int?>.from(data['board']);
      _currentTurn = data['currentTurn'];

      // 무한 틱택토용 데이터
      if (data['moveHistory'] != null) {
        _moveHistory = List<Map<String, dynamic>>.from(
          (data['moveHistory'] as List).map((m) => Map<String, dynamic>.from(m))
        );
      }
      if (data['removedPosition'] != null) {
        _removedPosition = data['removedPosition'];
      }

      notifyListeners();
    });

    _socketService.on('game_end', (data) {
      _status = GameStatus.finished;
      _board = List<int?>.from(data['board']);
      _winnerId = data['winner'];
      _winnerNickname = data['winnerNickname'];
      _isDraw = data['isDraw'] ?? false;
      notifyListeners();
    });

    _socketService.on('opponent_left', (data) {
      _status = GameStatus.finished;
      _winnerId = _myId; // 상대가 나가면 승리
      notifyListeners();
    });

    _socketService.on('error', (data) {
      debugPrint('Game error: ${data['message']}');
    });
  }

  void findMatch(String gameType) {
    _socketService.emit('find_match', {'gameType': gameType});
  }

  void cancelMatch(String gameType) {
    _socketService.emit('cancel_match', {'gameType': gameType});
    _status = GameStatus.idle;
    notifyListeners();
  }

  void makeMove(int position) {
    if (_status != GameStatus.playing || !isMyTurn) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'position': position},
    });
  }

  void requestRematch() {
    _socketService.emit('rematch_request', {'roomId': _roomId});
  }

  void acceptRematch() {
    _socketService.emit('rematch_accept', {'roomId': _roomId});
  }

  void leaveGame() {
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    reset();
  }

  void reset() {
    _status = GameStatus.idle;
    _roomId = null;
    _opponentNickname = null;
    _currentTurn = null;
    _board = List.filled(9, null);
    _winnerId = null;
    _winnerNickname = null;
    _isDraw = false;
    _myPlayerIndex = null;
    _moveHistory = [];
    _removedPosition = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _socketService.off('waiting_for_match');
    _socketService.off('match_found');
    _socketService.off('game_start');
    _socketService.off('game_update');
    _socketService.off('game_end');
    _socketService.off('opponent_left');
    _socketService.off('error');
    super.dispose();
  }
}
