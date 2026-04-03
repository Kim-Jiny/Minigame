import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_config.dart';
import '../../providers/auth_provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/socket_service.dart';
import '../../services/socket_listener_registry.dart';
import '../../models/shop_item.dart';
import '../../utils/game_theme.dart';
import '../../widgets/game_player_profile.dart';
import '../common/game_end_action_panel.dart';
import '../common/game_reconnect_helper.dart';

enum HexagonGameStatus {
  idle,
  searching,
  matched,
  memorizing,
  playing,
  buzzing,
  roundEnd,
  finished,
}

/// 헥사곤 셀 데이터
class HexCell {
  final int index;
  final int number;
  final String letter;

  HexCell({required this.index, required this.number, required this.letter});
}

/// 찾은 조합
class FoundCombo {
  final List<int> cells;
  final String letters;
  final int playerIndex;

  FoundCombo({required this.cells, required this.letters, required this.playerIndex});
}

class HexagonCellPainter extends CustomPainter {
  final Color fillColor;
  final Color borderColor;
  final double borderWidth;

  HexagonCellPainter({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.5, 0)
      ..lineTo(size.width, size.height * 0.25)
      ..lineTo(size.width, size.height * 0.75)
      ..lineTo(size.width * 0.5, size.height)
      ..lineTo(0, size.height * 0.75)
      ..lineTo(0, size.height * 0.25)
      ..close();

    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant HexagonCellPainter oldDelegate) {
    return oldDelegate.fillColor != fillColor ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.borderWidth != borderWidth;
  }
}

class HexagonScreen extends StatefulWidget {
  const HexagonScreen({super.key});

  @override
  State<HexagonScreen> createState() => _HexagonScreenState();
}

class _HexagonScreenState extends State<HexagonScreen> with TickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);

  // 게임 상태
  HexagonGameStatus _status = HexagonGameStatus.idle;
  bool _isSolo = false;
  // ignore: unused_field
  bool _isInvitationGame = false;

  // 랭킹
  List<Map<String, dynamic>> _rankings = [];

  // 플레이어 정보
  String? _myId;
  String? _myNickname;
  String? _myAvatarUrl;
  int _myPlayerIndex = 0;
  String? _opponentNickname;
  String? _opponentAvatarUrl;
  UserProfileSettings? _myProfileSettings;
  UserProfileSettings? _opponentProfileSettings;

  // 방 정보
  String? _roomId;

  // 게임 데이터
  List<HexCell> _board = [];
  List<String> _letters = [];
  int _targetNumber = 0;
  int _currentRound = 0;
  int _totalCombinations = 0;
  int _remainingCombinations = 0;
  List<int> _scores = [0, 0];
  List<FoundCombo> _foundCombinations = [];

  // 선택 상태
  List<int> _selectedCells = [];
  int? _buzzingPlayerIndex;

  // 타이머
  Timer? _memorizeTimer;
  Timer? _idleTimer;
  Timer? _buzzTimer;
  int _memorizeRemaining = 30;
  int _idleRemaining = 60;
  int _buzzRemaining = 10;

  // 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;

  // 재연결
  bool _isReconnecting = false;
  Timer? _reconnectTimer;

  // 라운드 스킵
  bool _skipAvailable = false;
  bool _mySkipVoted = false;
  bool _opponentSkipVoted = false;

  // 리매치
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;

  // 애니메이션
  late AnimationController _resultAnimController;
  String? _lastResultMessage;
  Color? _lastResultColor;

  @override
  void initState() {
    super.initState();
    _resultAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      _myId = auth.socketId;
      _myNickname = auth.nickname;
      _myAvatarUrl = auth.avatarUrl;
      _myPlayerIndex = 0;

      final shopProvider = context.read<ShopProvider>();
      _myProfileSettings = shopProvider.profileSettings;

      // 초대 게임 체크
      _initFromGameProvider();

      _setupSocketListeners();
      _fetchRankings();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _socketListeners.offAll();
    _memorizeTimer?.cancel();
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    _reconnectTimer?.cancel();
    _resultAnimController.dispose();
    super.dispose();
  }

  void _initFromGameProvider() {
    try {
      final game = context.read<GameProvider>();
      final isActiveInvitation = game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched || game.status == GameStatus.playing);
      if (isActiveInvitation) {
        setState(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _isInvitationGame = true;
          _status = HexagonGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 HexagonScreen: GameProvider 초기화 실패: $e');
    }
  }

  void _setupSocketListeners() {
    // 소켓 재연결 감지: 게임 중이었으면 재연결 대기
    _socketListeners.on('connect', (_) {
      final isInGame = _status != HexagonGameStatus.idle &&
          _status != HexagonGameStatus.finished &&
          _status != HexagonGameStatus.searching;
      if (isInGame && _roomId != null) {
        if (!_isSolo) {
          _reconnectTimer?.cancel();
          _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
            context: context,
            onEnterWaiting: () => setState(() => _isReconnecting = true),
            onTimeout: () {
              _memorizeTimer?.cancel();
              _idleTimer?.cancel();
              _buzzTimer?.cancel();
              setState(() {
                _isReconnecting = false;
                _status = HexagonGameStatus.finished;
                _opponentLeft = true;
              });
            },
          );
        } else {
          // 솔로 모드: 즉시 종료
          _memorizeTimer?.cancel();
          _idleTimer?.cancel();
          _buzzTimer?.cancel();
          setState(() {
            _status = HexagonGameStatus.finished;
            _opponentLeft = true;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('연결이 끊겨 게임이 종료되었습니다'), backgroundColor: Colors.orange),
            );
          }
        }
      }
    });

    // 재연결 시 게임 상태 복원
    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'hexagon') return;
      _reconnectTimer?.cancel();

      // 소켓 ID 업데이트 (재연결로 변경됨)
      _myId = _socketService.socket?.id;

      final boardData = data['board'] as List<dynamic>? ?? [];
      final lettersData = data['letters'] as List<dynamic>? ?? [];
      final foundData = data['foundCombinations'] as List<dynamic>? ?? [];
      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      final roundState = data['roundState'] as String? ?? 'playing';

      _board = boardData.asMap().entries.map((e) => HexCell(
        index: e.key,
        number: (e.value['number'] as num).toInt(),
        letter: e.value['letter'] as String,
      )).toList();
      _letters = lettersData.map((l) => l as String).toList();
      _targetNumber = (data['targetNumber'] as num?)?.toInt() ?? 0;
      _currentRound = (data['round'] as num?)?.toInt() ?? 0;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _totalCombinations = (data['totalCombinations'] as num?)?.toInt() ?? 0;
      _remainingCombinations = (data['remainingCombinations'] as num?)?.toInt() ?? 0;
      _isSolo = data['isSolo'] as bool? ?? false;
      _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? 0;
      _roomId = data['roomId'] as String?;
      _selectedCells = [];

      _foundCombinations = foundData.map((fc) => FoundCombo(
        cells: (fc['cells'] as List<dynamic>).map((c) => (c as num).toInt()).toList(),
        letters: fc['letters'] as String,
        playerIndex: (fc['playerIndex'] as num).toInt(),
      )).toList();

      _buzzingPlayerIndex = data['buzzingPlayer'] != null
          ? (data['buzzingPlayer'] as num).toInt()
          : null;

      // 타이머 초기화
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();

      // 라운드 상태에 따라 게임 상태 복원
      switch (roundState) {
        case 'memorizing':
          _startMemorizeTimer();
          _status = HexagonGameStatus.memorizing;
          break;
        case 'playing':
          _startIdleTimer();
          _status = HexagonGameStatus.playing;
          break;
        case 'buzzing':
          if (_buzzingPlayerIndex == _myPlayerIndex) {
            _startBuzzTimer();
          }
          _status = HexagonGameStatus.buzzing;
          break;
        default:
          _startIdleTimer();
          _status = HexagonGameStatus.playing;
      }

      GameReconnectHelper.completeReconnect(
        context: context,
        onRecovered: () => setState(() => _isReconnecting = false),
      );
    });

    // 상대방 재연결 알림
    _socketListeners.on('opponent_reconnected', (_) {
      GameReconnectHelper.showOpponentReconnected(context);
    });

    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = HexagonGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List<dynamic>;
      _roomId = data['roomId'] as String?;
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);
      if (_myPlayerIndex == -1) _myPlayerIndex = 0;
      final opponentIdx = _myPlayerIndex == 0 ? 1 : 0;
      if (opponentIdx < players.length) {
        _opponentNickname = players[opponentIdx]['nickname'] as String?;
        _opponentAvatarUrl = players[opponentIdx]['avatarUrl'] as String?;
        final profileSettings = players[opponentIdx]['profileSettings'];
        if (profileSettings != null) {
          _opponentProfileSettings = UserProfileSettings.fromJson(profileSettings);
        }
      }
      setState(() => _status = HexagonGameStatus.matched);
    });

    _socketListeners.on('game_start', (data) {
      setState(() {
        _scores = [0, 0];
        _currentRound = 0;
        _foundCombinations = [];
        _isSolo = data['isSolo'] == true;
      });
    });

    _socketListeners.on('hexagon_solo_ready', (data) {
      _roomId = data['roomId'] as String?;
    });

    _socketListeners.on('hexagon_round_start', (data) {
      final boardData = data['board'] as List<dynamic>;
      _board = boardData.asMap().entries.map((e) => HexCell(
        index: e.key,
        number: (e.value['number'] as num).toInt(),
        letter: e.value['letter'] as String,
      )).toList();
      _targetNumber = (data['targetNumber'] as num).toInt();
      _currentRound = (data['round'] as num).toInt();
      _totalCombinations = (data['totalCombinations'] as num).toInt();
      _remainingCombinations = _totalCombinations;
      _foundCombinations = [];
      _selectedCells = [];
      _buzzingPlayerIndex = null;
      _skipAvailable = false;
      _mySkipVoted = false;
      _opponentSkipVoted = false;

      final scoreData = data['scores'] as List<dynamic>?;
      if (scoreData != null) {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
      }

      _startMemorizeTimer();
      setState(() => _status = HexagonGameStatus.memorizing);
    });

    _socketListeners.on('hexagon_play_start', (data) {
      final lettersData = data['letters'] as List<dynamic>;
      _letters = lettersData.map((l) => l as String).toList();
      _selectedCells = [];

      _memorizeTimer?.cancel();
      _startIdleTimer();
      setState(() => _status = HexagonGameStatus.playing);
    });

    _socketListeners.on('hexagon_skip_available', (_) {
      setState(() => _skipAvailable = true);
    });

    _socketListeners.on('hexagon_skip_voted', (_) {
      setState(() => _opponentSkipVoted = true);
    });

    _socketListeners.on('hexagon_buzz', (data) {
      _buzzingPlayerIndex = (data['playerIndex'] as num).toInt();
      _idleTimer?.cancel();
      // 버저 누르면 스킵 상태 초기화
      _skipAvailable = false;
      _mySkipVoted = false;
      _opponentSkipVoted = false;

      if (_buzzingPlayerIndex == _myPlayerIndex) {
        _startBuzzTimer();
      }

      setState(() => _status = HexagonGameStatus.buzzing);
    });

    _socketListeners.on('hexagon_answer_result', (data) {
      final correct = data['correct'] as bool;
      final letters = data['letters'] as String? ?? '';
      final playerIdx = (data['playerIndex'] as num).toInt();
      final nickname = data['playerNickname'] as String? ?? '';
      final alreadyFound = data['alreadyFound'] as bool? ?? false;

      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _remainingCombinations = (data['remainingCombinations'] as num).toInt();

      // 찾은 조합 업데이트
      final foundData = data['foundCombinations'] as List<dynamic>?;
      if (foundData != null) {
        _foundCombinations = foundData.map((fc) => FoundCombo(
          cells: (fc['cells'] as List<dynamic>).map((c) => (c as num).toInt()).toList(),
          letters: fc['letters'] as String,
          playerIndex: (fc['playerIndex'] as num).toInt(),
        )).toList();
      }

      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;
      _selectedCells = [];

      // 결과 메시지
      if (correct) {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '정답! $letters (+1)'
            : '$nickname: $letters (+1)';
        _lastResultColor = playerIdx == _myPlayerIndex
            ? Colors.green
            : Colors.orange;
      } else if (alreadyFound) {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '이미 찾은 조합! (-1)'
            : '$nickname: 이미 찾은 조합 (-1)';
        _lastResultColor = Colors.red;
      } else {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '오답! (-1)'
            : '$nickname: 오답 (-1)';
        _lastResultColor = Colors.red;
      }
      _resultAnimController.forward(from: 0);

      setState(() => _status = HexagonGameStatus.playing);
      _startIdleTimer();
    });

    _socketListeners.on('hexagon_buzz_timeout', (data) {
      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;
      _selectedCells = [];

      _lastResultMessage = '시간 초과! (-1)';
      _lastResultColor = Colors.red;
      _resultAnimController.forward(from: 0);

      setState(() => _status = HexagonGameStatus.playing);
      _startIdleTimer();
    });

    _socketListeners.on('hexagon_round_end', (data) {
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;

      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();

      final foundData = data['foundCombinations'] as List<dynamic>?;
      if (foundData != null) {
        _foundCombinations = foundData.map((fc) => FoundCombo(
          cells: (fc['cells'] as List<dynamic>).map((c) => (c as num).toInt()).toList(),
          letters: fc['letters'] as String,
          playerIndex: (fc['playerIndex'] as num).toInt(),
        )).toList();
      }

      // 보드 데이터 복원 (라운드 종료 시 숫자 보여주기)
      final boardData = data['board'] as List<dynamic>?;
      if (boardData != null) {
        _board = boardData.asMap().entries.map((e) => HexCell(
          index: e.key,
          number: (e.value['number'] as num).toInt(),
          letter: e.value['letter'] as String,
        )).toList();
      }

      setState(() => _status = HexagonGameStatus.roundEnd);
    });

    _socketListeners.on('game_end', (data) {
      if (_status == HexagonGameStatus.finished ||
          _status == HexagonGameStatus.idle ||
          _status == HexagonGameStatus.searching) {
        return;
      }
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();

      final scoreData = data['scores'] as List<dynamic>?;
      if (scoreData != null) {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
      }

      setState(() {
        _status = HexagonGameStatus.finished;
        _winnerId = data['winner'] as String?;
        _isDraw = data['isDraw'] as bool? ?? false;
      });
    });

    _socketListeners.on('opponent_left', (_) {
      if (_status == HexagonGameStatus.idle ||
          _status == HexagonGameStatus.searching ||
          _status == HexagonGameStatus.finished) {
        return;
      }
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      setState(() {
        _status = HexagonGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('상대방이 나갔습니다'), backgroundColor: Colors.orange),
        );
      }
    });

    _socketListeners.on('rematch_waiting', (data) {
      setState(() => _rematchWaiting = data['waiting'] as bool? ?? true);
    });

    _socketListeners.on('rematch_requested', (_) {
      setState(() => _opponentWantsRematch = true);
    });

    _socketListeners.on('rematch_cancelled', (_) {
      setState(() => _opponentWantsRematch = false);
    });

    _socketListeners.on('hexagon_rankings', (data) {
      final rankingsData = data['rankings'] as List<dynamic>? ?? [];
      setState(() {
        _rankings = rankingsData.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      });
    });

    _socketListeners.on('error', (data) {
      final message = data['message'] as String? ?? '';
      if (message.contains('room') && message.contains('invalid')) {
        _handleRoomInvalid();
      }
    });
  }

  // 타이머들
  void _startMemorizeTimer() {
    _memorizeTimer?.cancel();
    _memorizeRemaining = 30;
    _memorizeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_memorizeRemaining > 0) {
        setState(() => _memorizeRemaining--);
      } else {
        timer.cancel();
      }
    });
  }

  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleRemaining = 60;
    _idleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_idleRemaining > 0) {
        setState(() => _idleRemaining--);
      } else {
        timer.cancel();
      }
    });
  }

  void _startBuzzTimer() {
    _buzzTimer?.cancel();
    _buzzRemaining = 10;
    _buzzTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_buzzRemaining > 0) {
        setState(() => _buzzRemaining--);
      } else {
        timer.cancel();
      }
    });
  }

  // 액션들
  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeHexagon,
    });
    setState(() => _status = HexagonGameStatus.searching);
  }

  void _startSolo() {
    _socketService.emit('hexagon_solo_start', {});
    _isSolo = true;
    setState(() => _status = HexagonGameStatus.matched);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeHexagon,
    });
    setState(() => _status = HexagonGameStatus.idle);
  }

  void _buzz() {
    if (_status != HexagonGameStatus.playing || _roomId == null) return;
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'buzz'},
    });
  }

  void _submitAnswer() {
    if (_status != HexagonGameStatus.buzzing || _roomId == null) return;
    if (_selectedCells.length != 3) return;
    if (_buzzingPlayerIndex != _myPlayerIndex) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {
        'type': 'answer',
        'cellIndices': _selectedCells,
      },
    });
  }

  void _toggleCellSelection(int index) {
    if (_status != HexagonGameStatus.buzzing) return;
    if (_buzzingPlayerIndex != _myPlayerIndex) return;

    setState(() {
      if (_selectedCells.contains(index)) {
        _selectedCells.remove(index);
      } else if (_selectedCells.length < 3) {
        _selectedCells.add(index);
      }
    });
  }

  void _skipRound() {
    if (_roomId == null || _mySkipVoted) return;
    _socketService.emit('hexagon_skip_round', {'roomId': _roomId});
    setState(() => _mySkipVoted = true);
  }

  void _requestRematch() {
    if (_roomId == null) return;
    _socketService.emit('rematch_request', {'roomId': _roomId});
  }

  void _cancelRematch() {
    if (_roomId == null) return;
    _socketService.emit('rematch_cancel', {'roomId': _roomId});
    setState(() => _rematchWaiting = false);
  }

  void _endSoloChallenge() {
    if (_roomId == null) return;
    _memorizeTimer?.cancel();
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    _socketService.emit('hexagon_solo_end', {'roomId': _roomId});
    // game_end 이벤트를 기다리지 않고 바로 finished 상태로 전환
    setState(() {
      _status = HexagonGameStatus.finished;
    });
  }

  void _fetchRankings() {
    _socketService.emit('hexagon_get_rankings', {'limit': 20});
  }

  void _handleRoomInvalid() {
    setState(() {
      _status = HexagonGameStatus.idle;
      _roomId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ShopProvider>(
      builder: (context, shopProvider, _) {
        final theme = shopProvider.profileSettings != null
            ? GameTheme.fromProfileSettings(shopProvider.profileSettings)
            : GameTheme.defaultTheme;

        return PopScope(
          canPop: _status == HexagonGameStatus.idle || _status == HexagonGameStatus.finished,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _showExitDialog(theme);
            }
          },
          child: Scaffold(
            backgroundColor: theme.background2,
            appBar: AppBar(
              title: const Text('헥사곤', style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: theme.primary,
              foregroundColor: theme.textOnPrimary,
              elevation: 0,
            ),
            body: Container(
              decoration: BoxDecoration(gradient: theme.backgroundGradient),
              child: SafeArea(
                child: Stack(
                  children: [
                    _buildBody(theme),
                    if (_isReconnecting)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(color: Colors.white),
                              SizedBox(height: 16),
                              Text('재연결 중...', style: TextStyle(color: Colors.white, fontSize: 18)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(GameTheme theme) {
    switch (_status) {
      case HexagonGameStatus.idle:
        return _buildIdleView(theme);
      case HexagonGameStatus.searching:
        return _buildSearchingView(theme);
      case HexagonGameStatus.matched:
        return _buildMatchedView(theme);
      case HexagonGameStatus.memorizing:
        return _buildMemorizingView(theme);
      case HexagonGameStatus.playing:
      case HexagonGameStatus.buzzing:
        return _buildPlayingView(theme);
      case HexagonGameStatus.roundEnd:
        return _buildRoundEndView(theme);
      case HexagonGameStatus.finished:
        return _buildFinishedView(theme);
    }
  }

  // ==================== IDLE ====================
  Widget _buildIdleView(GameTheme theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(Icons.hexagon_outlined, size: 80, color: theme.primary),
          const SizedBox(height: 16),
          Text('헥사곤', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: theme.primary)),
          const SizedBox(height: 12),
          Text(
            '숫자를 외우고, 합이 맞는 3칸을 찾아라!',
            style: TextStyle(fontSize: 16, color: Colors.grey[700]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ruleRow('1.', '19칸 보드의 숫자를 30초간 암기'),
                _ruleRow('2.', '뒤집힌 후 타겟 넘버가 제시'),
                _ruleRow('3.', '일직선 3칸의 합 = 타겟을 찾으세요'),
                _ruleRow('4.', '버저를 누르고 10초 내 답변'),
                _ruleRow('⭕', '정답 +1점 / 오답 -1점'),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 솔로 모드
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _startSolo,
              icon: const Icon(Icons.person),
              label: const Text('랭킹 도전 (솔로)', style: TextStyle(fontSize: 18)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2D3436),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 대전 모드
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _findMatch,
                  icon: const Icon(Icons.people),
                  label: const Text('대전 (2인)', style: TextStyle(fontSize: 18)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primary,
                    foregroundColor: theme.textOnPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _showFriendInviteDialog(context),
                icon: const Icon(Icons.person_add, size: 20),
                label: const Text('친구 초대'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.primary,
                  side: BorderSide(color: theme.primary),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // 랭킹 보기 버튼
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _showRankingSheet(theme),
              icon: const Icon(Icons.leaderboard),
              label: const Text('솔로 랭킹 보기', style: TextStyle(fontSize: 16)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ruleRow(String num, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 28, child: Text(num, style: const TextStyle(fontWeight: FontWeight.bold))),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }

  // ==================== SEARCHING ====================
  Widget _buildSearchingView(GameTheme theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: theme.primary),
          const SizedBox(height: 24),
          Text('상대를 찾는 중...', style: TextStyle(fontSize: 18, color: theme.primary)),
          const SizedBox(height: 24),
          TextButton(
            onPressed: _cancelMatch,
            child: const Text('취소', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  // ==================== MATCHED ====================
  Widget _buildMatchedView(GameTheme theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_opponentNickname != null) ...[
            Text(_opponentNickname!, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: theme.primary)),
            const SizedBox(height: 8),
          ],
          if (_isSolo)
            Text('랭킹 도전 준비 중...', style: TextStyle(fontSize: 18, color: theme.primary))
          else
            Text('게임 시작 준비 중...', style: TextStyle(fontSize: 18, color: theme.primary)),
          const SizedBox(height: 16),
          CircularProgressIndicator(color: theme.primary),
        ],
      ),
    );
  }

  // ==================== MEMORIZING ====================
  Widget _buildMemorizingView(GameTheme theme) {
    return Column(
      children: [
        _buildHeader(theme),
        // 타이머
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Text('숫자를 외우세요!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.primary)),
              const SizedBox(height: 4),
              Text('$_memorizeRemaining초', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: _memorizeRemaining <= 5 ? Colors.red : theme.primary)),
            ],
          ),
        ),
        // 보드 (숫자 보이기)
        Expanded(child: _buildHexBoard(theme, showNumbers: true)),
      ],
    );
  }

  // ==================== PLAYING / BUZZING ====================
  Widget _buildPlayingView(GameTheme theme) {
    final iAmBuzzing = _status == HexagonGameStatus.buzzing && _buzzingPlayerIndex == _myPlayerIndex;
    final otherBuzzing = _status == HexagonGameStatus.buzzing && _buzzingPlayerIndex != _myPlayerIndex;

    return Column(
      children: [
        _buildHeader(theme),
        // 타겟 넘버 + 남은 조합
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('타겟: $_targetNumber', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.textOnPrimary)),
              ),
              const SizedBox(width: 12),
              Text('남은 조합: $_remainingCombinations/$_totalCombinations',
                style: TextStyle(fontSize: 14, color: Colors.grey[600])),
            ],
          ),
        ),
        // 타이머
        if (_status == HexagonGameStatus.playing)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('$_idleRemaining초',
              style: TextStyle(fontSize: 16, color: _idleRemaining <= 10 ? Colors.red : Colors.grey[600])),
          ),
        if (_status == HexagonGameStatus.buzzing)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              iAmBuzzing ? '답변하세요! $_buzzRemaining초' : '${_getPlayerNickname(_buzzingPlayerIndex ?? 0)}이(가) 답변 중...',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                color: iAmBuzzing ? Colors.orange : Colors.blue),
            ),
          ),
        // 결과 메시지
        if (_lastResultMessage != null)
          AnimatedBuilder(
            animation: _resultAnimController,
            builder: (_, child) {
              final opacity = 1.0 - _resultAnimController.value;
              return Opacity(
                opacity: opacity,
                child: Text(_lastResultMessage!,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _lastResultColor)),
              );
            },
          ),
        // 보드 (알파벳)
        Expanded(child: _buildHexBoard(theme, showNumbers: false)),
        // 하단 액션
        _buildActionBar(theme, iAmBuzzing, otherBuzzing),
      ],
    );
  }

  Widget _buildActionBar(GameTheme theme, bool iAmBuzzing, bool otherBuzzing) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 8, offset: const Offset(0, -2))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 선택된 셀 표시
          if (iAmBuzzing) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < 3; i++)
                  Container(
                    width: 48,
                    height: 48,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: i < _selectedCells.length
                          ? theme.primary.withValues(alpha: 0.2)
                          : Colors.grey[200],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: theme.primary, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      i < _selectedCells.length ? _letters[_selectedCells[i]] : '?',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.primary),
                    ),
                  ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _selectedCells.length == 3 ? _submitAnswer : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                  child: const Text('제출', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
          if (!iAmBuzzing && !otherBuzzing) ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _buzz,
                icon: const Icon(Icons.notifications_active, size: 28),
                label: const Text('버저!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
            // 20초 무활동 시 라운드 넘기기 버튼
            if (_skipAvailable && !_isSolo) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _mySkipVoted ? null : _skipRound,
                  icon: Icon(_mySkipVoted ? Icons.check : Icons.skip_next),
                  label: Text(
                    _mySkipVoted
                        ? (_opponentSkipVoted ? '라운드 넘기는 중...' : '상대방 대기 중...')
                        : '라운드 넘기기',
                    style: const TextStyle(fontSize: 16),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ],
          if (otherBuzzing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('상대방이 답변 중...', style: TextStyle(fontSize: 16, color: Colors.grey)),
            ),
        ],
      ),
    );
  }

  // ==================== ROUND END ====================
  Widget _buildRoundEndView(GameTheme theme) {
    return Column(
      children: [
        _buildHeader(theme),
        const SizedBox(height: 16),
        Text('라운드 $_currentRound 종료', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: theme.primary)),
        const SizedBox(height: 8),
        Text('찾은 조합: ${_foundCombinations.length}/$_totalCombinations',
          style: TextStyle(fontSize: 16, color: Colors.grey[700])),
        const SizedBox(height: 8),
        // 보드 (숫자 다시 보이기)
        Expanded(child: _buildHexBoard(theme, showNumbers: true)),
        // 찾은 조합 리스트
        if (_foundCombinations.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('찾은 조합:', style: TextStyle(fontWeight: FontWeight.bold)),
                Wrap(
                  spacing: 8,
                  children: _foundCombinations.map((fc) {
                    final isMe = fc.playerIndex == _myPlayerIndex;
                    return Chip(
                      label: Text(fc.letters, style: TextStyle(color: isMe ? Colors.white : Colors.black)),
                      backgroundColor: isMe ? theme.primary : Colors.grey[300],
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('다음 라운드 준비 중...', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
        ),
      ],
    );
  }

  // ==================== FINISHED ====================
  Widget _buildFinishedView(GameTheme theme) {
    final isWinner = _winnerId == _myId;
    final isSoloDone = _isSolo;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isSoloDone) ...[
              const Icon(Icons.emoji_events, size: 64, color: Colors.amber),
              const SizedBox(height: 16),
              Text('최종 점수', style: TextStyle(fontSize: 20, color: Colors.grey[700])),
              Text('${_scores.isNotEmpty ? _scores[0] : 0}점',
                style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: theme.primary)),
            ] else if (_opponentLeft) ...[
              Icon(Icons.emoji_events, size: 64, color: Colors.amber),
              const SizedBox(height: 16),
              Text('승리!', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: theme.primary)),
              const Text('상대방이 나갔습니다', style: TextStyle(fontSize: 16, color: Colors.grey)),
            ] else if (_isDraw) ...[
              const Icon(Icons.handshake, size: 64, color: Colors.blue),
              const SizedBox(height: 16),
              Text('무승부', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.blue)),
            ] else if (isWinner) ...[
              const Icon(Icons.emoji_events, size: 64, color: Colors.amber),
              const SizedBox(height: 16),
              Text('승리!', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: theme.primary)),
            ] else ...[
              Icon(Icons.sentiment_dissatisfied, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text('패배', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.grey[600])),
            ],
            const SizedBox(height: 16),
            if (!isSoloDone && _scores.length >= 2)
              Text('${_scores[_myPlayerIndex]} : ${_scores[_myPlayerIndex == 0 ? 1 : 0]}',
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: theme.primary)),
            const SizedBox(height: 32),
            // 찾은 조합 표시
            if (_foundCombinations.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    const Text('찾은 조합', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    // 내 조합
                    if (_foundCombinations.where((fc) => fc.playerIndex == _myPlayerIndex).isNotEmpty) ...[
                      Text(_myNickname ?? '나', style: TextStyle(fontWeight: FontWeight.bold, color: theme.primary)),
                      Wrap(
                        spacing: 6,
                        children: _foundCombinations
                            .where((fc) => fc.playerIndex == _myPlayerIndex)
                            .map((fc) => Chip(
                              label: Text(fc.letters, style: const TextStyle(color: Colors.white)),
                              backgroundColor: theme.primary,
                              visualDensity: VisualDensity.compact,
                            ))
                            .toList(),
                      ),
                    ],
                    // 상대 조합 (2인 모드)
                    if (!_isSolo && _foundCombinations.where((fc) => fc.playerIndex != _myPlayerIndex).isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(_opponentNickname ?? '상대', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                      Wrap(
                        spacing: 6,
                        children: _foundCombinations
                            .where((fc) => fc.playerIndex != _myPlayerIndex)
                            .map((fc) => Chip(
                              label: Text(fc.letters),
                              backgroundColor: Colors.grey[300],
                              visualDensity: VisualDensity.compact,
                            ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            GameEndActionPanel(
              showRematchActions: !_isSolo && !_opponentLeft,
              opponentWantsRematch: _opponentWantsRematch,
              rematchWaiting: _rematchWaiting,
              primaryColor: theme.primary,
              primaryForegroundColor: theme.textOnPrimary,
              onRequestRematch: _requestRematch,
              onCancelRematch: _cancelRematch,
              onLeave: () => Navigator.pop(context),
              rematchLabel: '재대결',
              acceptRematchLabel: '재대결 수락',
              waitingText: '상대방 응답 대기 중...',
              cancelLabel: '취소',
              leaveLabel: '로비로',
              leaveIcon: Icons.home,
            ),
          ],
        ),
      ),
    );
  }

  // ==================== HEADER ====================
  Widget _buildHeader(GameTheme theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.white.withValues(alpha: 0.9),
      child: Row(
        children: [
          // 나
          Expanded(
            child: _buildPlayerColumn(
              theme,
              _myNickname ?? '나',
              _myAvatarUrl,
              true,
              _myPlayerIndex,
              _myProfileSettings,
            ),
          ),
          // 중앙 정보
          Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('R$_currentRound', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: theme.primary)),
              ),
              const SizedBox(height: 4),
              Text(
                _isSolo ? '${_scores.isNotEmpty ? _scores[0] : 0}점' : '${_scores.isNotEmpty ? _scores[_myPlayerIndex] : 0} : ${_scores.length > 1 ? _scores[_myPlayerIndex == 0 ? 1 : 0] : 0}',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.primary),
              ),
            ],
          ),
          // 상대
          if (!_isSolo)
            Expanded(
              child: _buildPlayerColumn(
                theme,
                _opponentNickname ?? '상대',
                _opponentAvatarUrl,
                false,
                _myPlayerIndex == 0 ? 1 : 0,
                _opponentProfileSettings,
              ),
            )
          else
            const Expanded(child: SizedBox()),
        ],
      ),
    );
  }

  Widget _buildPlayerColumn(GameTheme theme, String name, String? avatarUrl, bool isMe, int playerIndex, UserProfileSettings? profileSettings) {
    final myFoundCombos = _foundCombinations.where((fc) => fc.playerIndex == playerIndex).toList();

    return Column(
      children: [
        GamePlayerProfile(
          name: name,
          avatarUrl: avatarUrl,
          isActive: _buzzingPlayerIndex == playerIndex,
          isMe: isMe,
          profileSettings: profileSettings,
          activeColor: theme.primary,
        ),
        // 찾은 조합 표시
        if (myFoundCombos.isNotEmpty)
          Wrap(
            spacing: 2,
            children: myFoundCombos.map((fc) =>
              Text(fc.letters, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                color: isMe ? theme.primary : Colors.grey[600])),
            ).toList(),
          ),
      ],
    );
  }

  // ==================== HEX BOARD ====================
  Widget _buildHexBoard(GameTheme theme, {required bool showNumbers}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - 24;
        final availableHeight = constraints.maxHeight - 16;
        // 셀 크기 계산: 5열이 들어가야 함
        final cellSize = min(availableWidth / 6.2, availableHeight / 6.2);
        final hexWidth = cellSize * 0.95;
        final hexHeight = cellSize * 1.1;

        // 행별 셀 수
        const rowSizes = [3, 4, 5, 4, 3];
        const rowStarts = [0, 3, 7, 12, 16];

        return Center(
          child: SizedBox(
            width: hexWidth * 5 + 24,
            height: hexHeight * 4.35 + 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                for (int row = 0; row < 5; row++)
                  for (int col = 0; col < rowSizes[row]; col++)
                    _buildHexCell(
                      theme,
                      rowStarts[row] + col,
                      row,
                      col,
                      rowSizes[row],
                      hexWidth,
                      hexHeight,
                      showNumbers,
                    ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHexCell(GameTheme theme, int index, int row, int col, int rowSize, double hexWidth, double hexHeight, bool showNumbers) {
    // 위치 계산
    final maxCols = 5;
    final offset = (maxCols - rowSize) / 2.0;
    final x = (offset + col) * hexWidth * 0.98 + 12;
    final y = row * hexHeight * 0.78 + 12;

    final isSelected = _selectedCells.contains(index);
    final foundByMe = _foundCombinations.any(
      (fc) => fc.cells.contains(index) && fc.playerIndex == _myPlayerIndex,
    );
    final foundByOpponent = _foundCombinations.any(
      (fc) => fc.cells.contains(index) && fc.playerIndex != _myPlayerIndex,
    );
    final canTap = _status == HexagonGameStatus.buzzing && _buzzingPlayerIndex == _myPlayerIndex;

    Color bgColor;
    if (isSelected) {
      bgColor = theme.primary.withValues(alpha: 0.4);
    } else if (foundByMe) {
      bgColor = theme.primary.withValues(alpha: 0.15);
    } else if (foundByOpponent) {
      bgColor = Colors.grey.withValues(alpha: 0.15);
    } else {
      bgColor = Colors.white;
    }

    String displayText;
    if (showNumbers && index < _board.length) {
      // 암기 단계는 숫자만 노출
      displayText = '${_board[index].number}';
    } else if (!showNumbers && index < _letters.length) {
      displayText = _letters[index];
    } else {
      displayText = '';
    }

    return Positioned(
      left: x,
      top: y,
      child: GestureDetector(
        onTap: canTap ? () => _toggleCellSelection(index) : null,
        child: SizedBox(
          width: hexWidth * 0.9,
          height: hexHeight * 0.9,
          child: CustomPaint(
            painter: HexagonCellPainter(
              fillColor: bgColor,
              borderColor: isSelected ? theme.primary : Colors.grey[500]!,
              borderWidth: isSelected ? 3 : 1.6,
            ),
            child: Center(
              child: Text(
                displayText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: showNumbers ? hexWidth * 0.23 : hexWidth * 0.3,
                  fontWeight: FontWeight.bold,
                  color: showNumbers ? Colors.black87 : theme.primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== HELPERS ====================
  String _getPlayerNickname(int playerIndex) {
    if (playerIndex == _myPlayerIndex) return _myNickname ?? '나';
    return _opponentNickname ?? '상대';
  }

  void _showRankingSheet(GameTheme theme) {
    _fetchRankings();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.leaderboard, color: theme.primary),
                      const SizedBox(width: 8),
                      Text('솔로 랭킹', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: theme.primary)),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _rankings.isEmpty
                      ? const Center(child: Text('아직 기록이 없습니다', style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: _rankings.length,
                          itemBuilder: (_, index) {
                            final r = _rankings[index];
                            final nickname = r['nickname'] as String? ?? '???';
                            final score = r['score'] as int? ?? 0;
                            final isTop3 = index < 3;
                            return ListTile(
                              leading: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: isTop3
                                      ? [Colors.amber, Colors.grey[400]!, Colors.brown[300]!][index]
                                      : Colors.grey[200],
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isTop3 ? Colors.white : Colors.grey[600],
                                  ),
                                ),
                              ),
                              title: Text(nickname, style: const TextStyle(fontWeight: FontWeight.w600)),
                              trailing: Text(
                                '$score점',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: theme.primary),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showFriendInviteDialog(BuildContext context) {
    context.read<FriendProvider>().getFriends();
    final shop = context.read<ShopProvider>();
    final theme = GameTheme.fromProfileSettings(shop.profileSettings);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (dialogContext) => Consumer<FriendProvider>(
        builder: (context, friendProvider, child) {
          final onlineFriends = friendProvider.friends.where((f) => f.isOnline).toList();
          return Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(dialogContext).size.height * 0.6),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(children: [
                    Icon(Icons.person_add, color: theme.primary),
                    const SizedBox(width: 12),
                    const Text('친구 초대', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ]),
                ),
                const Divider(height: 1),
                Flexible(
                  child: onlineFriends.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(40),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.person_off, size: 48, color: Colors.grey.shade400),
                              const SizedBox(height: 16),
                              Text('온라인 친구가 없습니다', style: TextStyle(color: Colors.grey.shade600)),
                            ]),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: onlineFriends.length,
                          itemBuilder: (context, index) {
                            final friend = onlineFriends[index];
                            return ListTile(
                              leading: Stack(children: [
                                CircleAvatar(
                                  backgroundColor: theme.primary.withValues(alpha: 0.2),
                                  child: Text(
                                    friend.nickname.isNotEmpty ? friend.nickname[0].toUpperCase() : '?',
                                    style: TextStyle(color: theme.primary),
                                  ),
                                ),
                                Positioned(
                                  right: 0, bottom: 0,
                                  child: Container(
                                    width: 12, height: 12,
                                    decoration: BoxDecoration(
                                      color: Colors.green, shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2),
                                    ),
                                  ),
                                ),
                              ]),
                              title: Text(friend.nickname, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: friend.memo != null && friend.memo!.isNotEmpty
                                  ? Text(friend.memo!, style: TextStyle(color: Colors.grey.shade600, fontSize: 12))
                                  : null,
                              trailing: ElevatedButton(
                                onPressed: () {
                                  friendProvider.inviteToGame(friend.id, AppConfig.gameTypeHexagon, isHardcore: false);
                                  Navigator.pop(dialogContext);
                                  ScaffoldMessenger.of(context).clearSnackBars();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('${friend.nickname}님에게 초대를 보냈습니다!'), backgroundColor: Colors.green),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: theme.primary, foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                ),
                                child: const Text('초대'),
                              ),
                            );
                          },
                        ),
                ),
                SizedBox(height: MediaQuery.of(dialogContext).padding.bottom + 16),
              ],
            ),
          );
        },
      ),
    );
  }

  void _leaveGame() {
    if (_roomId != null) {
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    Navigator.pop(context);
  }

  void _showExitDialog(GameTheme theme) {
    if (_status == HexagonGameStatus.idle || _status == HexagonGameStatus.finished) {
      Navigator.pop(context);
      return;
    }
    if (_status == HexagonGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }
    final isSoloInGame = _isSolo && _roomId != null;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isSoloInGame ? '도전 종료' : '게임 나가기'),
        content: Text(isSoloInGame
            ? '여기까지의 기록을 저장하고 종료하시겠습니까?'
            : '진행 중인 게임을 포기하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (isSoloInGame) {
                _endSoloChallenge();
              } else {
                _leaveGame();
              }
            },
            child: Text(
              isSoloInGame ? '종료' : '나가기',
              style: TextStyle(color: isSoloInGame ? Colors.orange : Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}
