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
import '../../utils/game_registry.dart';
import '../../widgets/game_player_profile.dart';
import '../common/game_end_action_panel.dart';
import '../common/game_scaffold.dart';
import '../common/match_status_views.dart';
import '../common/game_reconnect_helper.dart';

enum PyramidGameStatus {
  idle,
  searching,
  matched,
  playing,
  buzzing,
  roundEnd,
  finished,
}

/// 피라미드 카드 데이터
class PyramidCard {
  final int position; // 0-9
  final int row;      // 0-3
  final int col;      // 0~row
  final String operator; // +, -, *
  final int value;       // 1-9

  PyramidCard({
    required this.position,
    required this.row,
    required this.col,
    required this.operator,
    required this.value,
  });

  String get displayText {
    final op = operator == '*' ? '\u00D7' : operator;
    return '$op$value';
  }
}

/// 부모-자식 관계 매핑
const Map<int, List<int>> childrenMap = {
  0: [1, 2],
  1: [3, 4],
  2: [4, 5],
  3: [6, 7],
  4: [7, 8],
  5: [8, 9],
};

class PyramidScreen extends StatefulWidget {
  /// 진입 맥락. 혼자하기 → 랭킹 도전/보기만, 둘이하기 → 대전/친구초대만.
  final GameEntryMode entryMode;

  const PyramidScreen({super.key, this.entryMode = GameEntryMode.versus});

  @override
  State<PyramidScreen> createState() => _PyramidScreenState();
}

class _PyramidScreenState extends State<PyramidScreen> with TickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);

  // 게임 상태
  PyramidGameStatus _status = PyramidGameStatus.idle;
  // ignore: unused_field
  bool _isInvitationGame = false;
  bool _isSolo = false;
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
  List<PyramidCard> _cards = [];
  int _targetNumber = 0;
  int _currentRound = 0;
  List<int> _scores = [0, 0];
  List<List<int>> _validPaths = [];
  List<int> _myAnswerPath = []; // 내가 맞춘 정답 경로

  // 선택 상태
  List<int> _selectedSequence = []; // 버저 후 선택한 카드 인덱스 순서
  int? _buzzingPlayerIndex;

  // 타이머
  Timer? _idleTimer;
  Timer? _buzzTimer;
  int _idleRemaining = 60;
  int _buzzRemaining = 15;

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

      _initFromGameProvider();
      _setupSocketListeners();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _socketListeners.offAll();
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
          _status = PyramidGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🔺 PyramidScreen: GameProvider 초기화 실패: $e');
    }
  }

  void _setupSocketListeners() {
    // 소켓 재연결 감지: 게임 중이었으면 재연결 대기
    _socketListeners.on('connect', (_) {
      final isInGame = _status != PyramidGameStatus.idle &&
          _status != PyramidGameStatus.finished &&
          _status != PyramidGameStatus.searching;
      if (isInGame && _roomId != null) {
        _reconnectTimer?.cancel();
        _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
          context: context,
          onEnterWaiting: () => setState(() => _isReconnecting = true),
          onTimeout: () {
            _idleTimer?.cancel();
            _buzzTimer?.cancel();
            setState(() {
              _isReconnecting = false;
              _status = PyramidGameStatus.finished;
              _opponentLeft = true;
            });
          },
        );
      }
    });

    // 재연결 시 게임 상태 복원
    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'pyramid') return;
      _reconnectTimer?.cancel();

      // 소켓 ID 업데이트 (재연결로 변경됨)
      _myId = _socketService.socket?.id;

      final cardsData = data['cards'] as List<dynamic>? ?? [];
      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      final roundState = data['roundState'] as String? ?? 'playing';

      _cards = cardsData.map((c) => PyramidCard(
        position: (c['position'] as num).toInt(),
        row: (c['row'] as num).toInt(),
        col: (c['col'] as num).toInt(),
        operator: c['operator'] as String,
        value: (c['value'] as num).toInt(),
      )).toList();
      _targetNumber = (data['targetNumber'] as num?)?.toInt() ?? 0;
      _currentRound = (data['round'] as num?)?.toInt() ?? 0;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? 0;
      _roomId = data['roomId'] as String?;
      _selectedSequence = [];

      final validPathsData = data['validPaths'] as List<dynamic>?;
      if (validPathsData != null) {
        _validPaths = validPathsData.map((p) =>
          (p as List<dynamic>).map((v) => (v as num).toInt()).toList()
        ).toList();
      }

      _buzzingPlayerIndex = data['buzzingPlayer'] != null
          ? (data['buzzingPlayer'] as num).toInt()
          : null;

      // 타이머 초기화
      _idleTimer?.cancel();
      _buzzTimer?.cancel();

      // 라운드 상태에 따라 게임 상태 복원
      switch (roundState) {
        case 'playing':
          _startIdleTimer();
          _status = PyramidGameStatus.playing;
          break;
        case 'buzzing':
          if (_buzzingPlayerIndex == _myPlayerIndex) {
            _startBuzzTimer();
          }
          _status = PyramidGameStatus.buzzing;
          break;
        default:
          _startIdleTimer();
          _status = PyramidGameStatus.playing;
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
      setState(() => _status = PyramidGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      debugPrint('🔺 pyramid match_found 수신: roomId=${data['roomId']}');
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
      setState(() => _status = PyramidGameStatus.matched);
    });

    _socketListeners.on('pyramid_solo_ready', (data) {
      _roomId = data['roomId'] as String?;
    });

    _socketListeners.on('pyramid_rankings', (data) {
      final list = data['rankings'] as List<dynamic>? ?? [];
      setState(() {
        _rankings = list.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      });
    });

    _socketListeners.on('game_start', (data) {
      debugPrint('🔺 pyramid game_start 수신: $data');
      if (data['players'] != null) {
        final players = data['players'] as List<dynamic>;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) {
          _myPlayerIndex = updatedIndex;
        }
      }
      setState(() {
        _isSolo = data['isSolo'] as bool? ?? false;
        _scores = _isSolo ? [0] : [0, 0];
        _currentRound = 0;
        _opponentLeft = false;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _winnerId = null;
        _isDraw = false;
      });
    });

    _socketListeners.on('pyramid_round_start', (data) {
      debugPrint('🔺 pyramid_round_start 수신: round=${data['round']}, target=${data['targetNumber']}');
      final cardsData = data['cards'] as List<dynamic>;
      _cards = cardsData.map((c) => PyramidCard(
        position: (c['position'] as num).toInt(),
        row: (c['row'] as num).toInt(),
        col: (c['col'] as num).toInt(),
        operator: c['operator'] as String,
        value: (c['value'] as num).toInt(),
      )).toList();
      _targetNumber = (data['targetNumber'] as num).toInt();
      _currentRound = (data['round'] as num).toInt();
      _selectedSequence = [];
      _buzzingPlayerIndex = null;
      _skipAvailable = false;
      _mySkipVoted = false;
      _opponentSkipVoted = false;

      final validPathsData = data['validPaths'] as List<dynamic>?;
      if (validPathsData != null) {
        _validPaths = validPathsData.map((p) =>
          (p as List<dynamic>).map((v) => (v as num).toInt()).toList()
        ).toList();
      }

      final scoreData = data['scores'] as List<dynamic>?;
      if (scoreData != null) {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
      }

      _startIdleTimer();
      setState(() => _status = PyramidGameStatus.playing);
    });

    _socketListeners.on('pyramid_skip_available', (_) {
      setState(() => _skipAvailable = true);
    });

    _socketListeners.on('pyramid_skip_voted', (_) {
      setState(() => _opponentSkipVoted = true);
    });

    _socketListeners.on('pyramid_buzz', (data) {
      _buzzingPlayerIndex = (data['playerIndex'] as num).toInt();
      _idleTimer?.cancel();
      // 버저 누르면 스킵 상태 초기화
      _skipAvailable = false;
      _mySkipVoted = false;
      _opponentSkipVoted = false;

      if (_buzzingPlayerIndex == _myPlayerIndex) {
        _startBuzzTimer();
      }

      setState(() => _status = PyramidGameStatus.buzzing);
    });

    _socketListeners.on('pyramid_answer_result', (data) {
      final correct = data['correct'] as bool;
      final playerIdx = (data['playerIndex'] as num).toInt();
      final nickname = data['playerNickname'] as String? ?? '';

      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();

      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;
      if (correct && playerIdx == _myPlayerIndex) {
        _myAnswerPath = List.from(_selectedSequence);
      }
      _selectedSequence = [];

      if (correct) {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '정답! (+1)'
            : '$nickname: 정답! (+1)';
        _lastResultColor = playerIdx == _myPlayerIndex
            ? Colors.green
            : Colors.orange;
      } else {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '오답! (-1)'
            : '$nickname: 오답 (-1)';
        _lastResultColor = Colors.red;
      }
      _resultAnimController.forward(from: 0);

      // 정답이면 라운드 종료 이벤트가 올 것이므로 playing 유지
      if (!correct) {
        setState(() => _status = PyramidGameStatus.playing);
        _startIdleTimer();
      } else {
        setState(() {});
      }
    });

    _socketListeners.on('pyramid_buzz_timeout', (data) {
      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;
      _selectedSequence = [];

      _lastResultMessage = '시간 초과! (-1)';
      _lastResultColor = Colors.red;
      _resultAnimController.forward(from: 0);

      setState(() => _status = PyramidGameStatus.playing);
      _startIdleTimer();
    });

    _socketListeners.on('pyramid_round_end', (data) {
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;

      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();

      final validPathsData = data['validPaths'] as List<dynamic>?;
      if (validPathsData != null) {
        _validPaths = validPathsData.map((p) =>
          (p as List<dynamic>).map((v) => (v as num).toInt()).toList()
        ).toList();
        // 내가 맞춘 경로를 맨 앞으로 (보드에서 하이라이트됨)
        if (_myAnswerPath.isNotEmpty) {
          _validPaths.removeWhere((p) =>
            p.length == _myAnswerPath.length &&
            List.generate(p.length, (i) => p[i] == _myAnswerPath[i]).every((v) => v));
          _validPaths.insert(0, _myAnswerPath);
          _myAnswerPath = [];
        }
      }

      final cardsData = data['cards'] as List<dynamic>?;
      if (cardsData != null) {
        _cards = cardsData.map((c) => PyramidCard(
          position: (c['position'] as num).toInt(),
          row: (c['row'] as num).toInt(),
          col: (c['col'] as num).toInt(),
          operator: c['operator'] as String,
          value: (c['value'] as num).toInt(),
        )).toList();
      }

      // 시각적으로 같은 수식(순열만 다른 경로, 동일 value+operator 카드로 인한
      // 같은 문자열 등)은 하나만 남긴다. 카드 정보가 이미 업데이트된 이 시점에
      // 실행해야 _pathToString이 현재 라운드 기준으로 키를 만든다.
      if (_validPaths.isNotEmpty && _cards.isNotEmpty) {
        final seen = <String>{};
        _validPaths = _validPaths.where((p) => seen.add(_pathToString(p))).toList();
      }

      setState(() => _status = PyramidGameStatus.roundEnd);
    });

    _socketListeners.on('game_end', (data) {
      if (_status == PyramidGameStatus.finished ||
          _status == PyramidGameStatus.idle ||
          _status == PyramidGameStatus.searching) {
        return;
      }
      _idleTimer?.cancel();
      _buzzTimer?.cancel();

      final scoreData = data['scores'] as List<dynamic>?;
      if (scoreData != null) {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
      }

      setState(() {
        _status = PyramidGameStatus.finished;
        _winnerId = data['winner'] as String?;
        _isDraw = data['isDraw'] as bool? ?? false;
      });
    });

    _socketListeners.on('opponent_left', (_) {
      if (_status == PyramidGameStatus.idle ||
          _status == PyramidGameStatus.searching ||
          _status == PyramidGameStatus.finished) {
        return;
      }
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      setState(() {
        _status = PyramidGameStatus.finished;
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

    _socketListeners.on('error', (data) {
      final message = data['message'] as String? ?? '';
      if (message.contains('room') && message.contains('invalid')) {
        _handleRoomInvalid();
      }
    });
  }

  // 타이머
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
    _buzzRemaining = 15;
    _buzzTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_buzzRemaining > 0) {
        setState(() => _buzzRemaining--);
      } else {
        timer.cancel();
      }
    });
  }

  // 액션
  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypePyramid,
    });
    setState(() => _status = PyramidGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypePyramid,
    });
    setState(() => _status = PyramidGameStatus.idle);
  }

  void _startSolo() {
    _socketService.emit('pyramid_solo_start', {});
    _isSolo = true;
    setState(() => _status = PyramidGameStatus.matched);
  }

  void _endSoloChallenge() {
    if (_roomId == null) return;
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    _socketService.emit('pyramid_solo_end', {'roomId': _roomId});
    setState(() {
      _status = PyramidGameStatus.finished;
    });
  }

  void _fetchRankings() {
    _socketService.emit('pyramid_get_rankings', {'limit': 20});
  }

  void _buzz() {
    if (_status != PyramidGameStatus.playing || _roomId == null) return;
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'buzz'},
    });
  }

  void _submitAnswer() {
    if (_status != PyramidGameStatus.buzzing || _roomId == null) return;
    if (_selectedSequence.length != 3) return;
    if (_buzzingPlayerIndex != _myPlayerIndex) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {
        'type': 'answer',
        'sequence': _selectedSequence,
      },
    });
  }

  /// 카드가 현재 선택 가능한지
  bool _isCardSelectable(int cardIdx) {
    // 이미 선택했으면 불가
    if (_selectedSequence.contains(cardIdx)) return false;

    // 모든 카드 자유롭게 선택 가능
    return true;
  }

  void _toggleCardSelection(int cardIdx) {
    if (_status != PyramidGameStatus.buzzing) return;
    if (_buzzingPlayerIndex != _myPlayerIndex) return;

    setState(() {
      if (_selectedSequence.isNotEmpty && _selectedSequence.last == cardIdx) {
        // 마지막 선택 취소 (되돌리기)
        _selectedSequence.removeLast();
      } else if (!_selectedSequence.contains(cardIdx) &&
                 _isCardSelectable(cardIdx) &&
                 _selectedSequence.length < 3) {
        _selectedSequence.add(cardIdx);
      }
    });
  }


  void _skipRound() {
    if (_roomId == null || _mySkipVoted) return;
    _socketService.emit('pyramid_skip_round', {'roomId': _roomId});
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

  void _handleRoomInvalid() {
    setState(() {
      _status = PyramidGameStatus.idle;
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
          canPop: _status == PyramidGameStatus.idle || _status == PyramidGameStatus.finished,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _showExitDialog(theme);
            }
          },
          child: Scaffold(
            backgroundColor: theme.background2,
            appBar: gameAppBar(
              title: '수식피라미드',
              backgroundColor: const Color(0xFFE67E22),
              boldTitle: true,
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
      case PyramidGameStatus.idle:
        return _buildIdleView(theme);
      case PyramidGameStatus.searching:
        return _buildSearchingView(theme);
      case PyramidGameStatus.matched:
        return _buildMatchedView(theme);
      case PyramidGameStatus.playing:
      case PyramidGameStatus.buzzing:
        return _buildPlayingView(theme);
      case PyramidGameStatus.roundEnd:
        return _buildRoundEndView(theme);
      case PyramidGameStatus.finished:
        return _buildFinishedView(theme);
    }
  }

  // ==================== IDLE ====================
  Widget _buildIdleView(GameTheme theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.change_history, size: 80, color: Color(0xFFE67E22)),
          const SizedBox(height: 16),
          const Text('수식피라미드', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFFE67E22))),
          const SizedBox(height: 12),
          Text(
            '카드를 골라 목표 숫자를 맞춰라!',
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
                _ruleRow('1.', '피라미드에서 아래줄부터 카드 선택'),
                _ruleRow('2.', '정확히 3장을 골라 조합!'),
                _ruleRow('3.', '첫 카드 = 시작값, 이후 연산 적용'),
                _ruleRow('4.', '결과가 타겟 넘버와 같으면 정답!'),
                _ruleRow('5.', '버저를 누르고 15초 내 답변'),
                _ruleRow('\u2B55', '정답 +1점 / 오답 -1점'),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 혼자하기로 진입 → 랭킹 도전 + 솔로 랭킹 보기
          if (widget.entryMode == GameEntryMode.solo) ...[
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
          // 둘이하기로 진입 → 대전 + 친구 초대
          if (widget.entryMode == GameEntryMode.versus)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _findMatch,
                    icon: const Icon(Icons.people),
                    label: const Text('대전 (2인)', style: TextStyle(fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE67E22),
                      foregroundColor: Colors.white,
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
                    foregroundColor: const Color(0xFFE67E22),
                    side: const BorderSide(color: Color(0xFFE67E22)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ],
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
    return GameSoloSearchingView(accentColor: const Color(0xFFE67E22), onCancel: _cancelMatch);
  }

  // ==================== MATCHED ====================
  Widget _buildMatchedView(GameTheme theme) {
    return GameSoloMatchedView(accentColor: const Color(0xFFE67E22), opponentNickname: _opponentNickname, isSolo: _isSolo);
  }

  // ==================== PLAYING / BUZZING ====================
  Widget _buildPlayingView(GameTheme theme) {
    final iAmBuzzing = _status == PyramidGameStatus.buzzing && _buzzingPlayerIndex == _myPlayerIndex;
    final otherBuzzing = _status == PyramidGameStatus.buzzing && _buzzingPlayerIndex != _myPlayerIndex;

    return Column(
      children: [
        _buildHeader(theme),
        // 타겟 넘버
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFE67E22),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '\uD83C\uDFAF Target: $_targetNumber',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
        ),
        // 타이머
        if (_status == PyramidGameStatus.playing)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('$_idleRemaining초',
              style: TextStyle(fontSize: 16, color: _idleRemaining <= 10 ? Colors.red : Colors.grey[600])),
          ),
        if (_status == PyramidGameStatus.buzzing)
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
        // 피라미드 보드
        Expanded(child: _buildPyramidBoard(theme)),
        // 액션바
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
          if (iAmBuzzing) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 되돌리기 버튼
                if (_selectedSequence.isNotEmpty)
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _selectedSequence.removeLast();
                      });
                    },
                    icon: const Icon(Icons.undo, size: 28),
                    color: Colors.grey[700],
                  ),
                const SizedBox(width: 8),
                // 선택 수
                Text(
                  '${_selectedSequence.length}/3장',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[700]),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _selectedSequence.length == 3 ? _submitAnswer : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
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
            // 4-state UI:
            //  - 아무도 안 누름: "라운드 넘기기"
            //  - 상대만 누름: "상대가 넘기기 요청" (탭해서 동의 가능)
            //  - 나만 누름: "상대방 대기 중..." (비활성)
            //  - 둘 다 누름: "라운드 넘기는 중..." (비활성)
            if (_skipAvailable && !_isSolo) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _mySkipVoted ? null : _skipRound,
                  icon: Icon(
                    _mySkipVoted
                        ? Icons.check
                        : (_opponentSkipVoted ? Icons.notification_important : Icons.skip_next),
                  ),
                  label: Text(
                    _mySkipVoted
                        ? (_opponentSkipVoted ? '라운드 넘기는 중...' : '상대방 대기 중...')
                        : (_opponentSkipVoted ? '상대가 넘기기 요청' : '라운드 넘기기'),
                    style: const TextStyle(fontSize: 16),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        (!_mySkipVoted && _opponentSkipVoted) ? Colors.orange : null,
                    side: (!_mySkipVoted && _opponentSkipVoted)
                        ? const BorderSide(color: Colors.orange, width: 2)
                        : null,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ],
          if (otherBuzzing && !_isSolo)
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
    final maxRounds = _isSolo ? 10 : 3;
    return Column(
      children: [
        _buildHeader(theme),
        const SizedBox(height: 16),
        Text('라운드 $_currentRound/$maxRounds 종료',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFFE67E22))),
        const SizedBox(height: 8),
        Text('타겟: $_targetNumber',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey[700])),
        const SizedBox(height: 4),
        Text('정답 경로: ${_validPaths.length}개',
          style: TextStyle(fontSize: 14, color: Colors.grey[600])),
        const SizedBox(height: 8),
        Expanded(child: _buildPyramidBoard(theme, showPaths: true)),
        // 정답 경로 표시
        if (_validPaths.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            constraints: const BoxConstraints(maxHeight: 100),
            child: ListView(
              shrinkWrap: true,
              children: _validPaths.take(3).map((path) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    _pathToString(path),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                );
              }).toList(),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('다음 라운드 준비 중...', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
        ),
      ],
    );
  }

  String _pathToString(List<int> path) {
    if (path.isEmpty || _cards.isEmpty) return '';
    final buf = StringBuffer();
    final first = _cards[path[0]];
    buf.write('${first.value}');
    num current = first.value;

    for (int i = 1; i < path.length; i++) {
      final card = _cards[path[i]];
      final op = card.operator == '*' ? '\u00D7' : card.operator;
      switch (card.operator) {
        case '+': current = current + card.value; break;
        case '-': current = current - card.value; break;
        case '*': current = current * card.value; break;
      }
      buf.write(' $op${card.value}');
    }
    buf.write(' = $current');
    return buf.toString();
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
                style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Color(0xFFE67E22))),
            ] else if (_opponentLeft) ...[
              const Icon(Icons.emoji_events, size: 64, color: Colors.amber),
              const SizedBox(height: 16),
              const Text('승리!', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFFE67E22))),
              const Text('상대방이 나갔습니다', style: TextStyle(fontSize: 16, color: Colors.grey)),
            ] else if (_isDraw) ...[
              const Icon(Icons.handshake, size: 64, color: Colors.blue),
              const SizedBox(height: 16),
              const Text('무승부', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.blue)),
            ] else if (isWinner) ...[
              const Icon(Icons.emoji_events, size: 64, color: Colors.amber),
              const SizedBox(height: 16),
              const Text('승리!', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFFE67E22))),
            ] else ...[
              Icon(Icons.sentiment_dissatisfied, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text('패배', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.grey[600])),
            ],
            const SizedBox(height: 16),
            if (!isSoloDone && _scores.length >= 2)
              Text('${_scores[_myPlayerIndex]} : ${_scores[_myPlayerIndex == 0 ? 1 : 0]}',
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFFE67E22))),
            const SizedBox(height: 32),
            GameEndActionPanel(
              showRematchActions: !isSoloDone && !_opponentLeft,
              opponentWantsRematch: _opponentWantsRematch,
              rematchWaiting: _rematchWaiting,
              primaryColor: const Color(0xFFE67E22),
              primaryForegroundColor: Colors.white,
              onRequestRematch: _requestRematch,
              onCancelRematch: _cancelRematch,
              onLeave: _leaveGame,
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
    final maxRounds = _isSolo ? 10 : 3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.white.withValues(alpha: 0.9),
      child: Row(
        children: [
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
          Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE67E22).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('R$_currentRound/$maxRounds',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFE67E22))),
              ),
              const SizedBox(height: 4),
              Text(
                _isSolo
                    ? '${_scores.isNotEmpty ? _scores[0] : 0}점'
                    : '${_scores.isNotEmpty ? _scores[_myPlayerIndex] : 0} : ${_scores.length > 1 ? _scores[_myPlayerIndex == 0 ? 1 : 0] : 0}',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFFE67E22)),
              ),
            ],
          ),
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
    return Column(
      children: [
        GamePlayerProfile(
          name: name,
          avatarUrl: avatarUrl,
          isActive: _buzzingPlayerIndex == playerIndex,
          isMe: isMe,
          profileSettings: profileSettings,
          activeColor: const Color(0xFFE67E22),
        ),
      ],
    );
  }

  // ==================== PYRAMID BOARD ====================
  Widget _buildPyramidBoard(GameTheme theme, {bool showPaths = false}) {
    if (_cards.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - 32;
        final availableHeight = constraints.maxHeight - 16;

        // 육각형 크기: 4열(맨 아래)이 들어가야 함
        final hexSize = min(availableWidth / 5.0, availableHeight / 5.0);
        // 콘텐츠 실제 크기 (4열 기준)
        final contentWidth = 3 * hexSize * 1.1 + hexSize;
        final contentHeight = 3 * hexSize * 1.05 + hexSize;

        return Center(
          child: SizedBox(
            width: contentWidth,
            height: contentHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                for (final card in _cards)
                  _buildPyramidCard(
                    theme, card, hexSize, showPaths,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPyramidCard(GameTheme theme, PyramidCard card, double hexSize, bool showPaths) {
    // 피라미드 배치: 각 행의 중앙 정렬
    final maxCols = 4; // Row 3 has 4 cards
    final rowSize = card.row + 1;
    final offset = (maxCols - rowSize) / 2.0;
    final x = (offset + card.col) * hexSize * 1.1;
    final y = card.row * hexSize * 1.05;

    final isSelected = _selectedSequence.contains(card.position);
    final selectionOrder = _selectedSequence.indexOf(card.position);
    final canSelect = _status == PyramidGameStatus.buzzing &&
        _buzzingPlayerIndex == _myPlayerIndex &&
        _isCardSelectable(card.position);
    final isLastSelected = _selectedSequence.isNotEmpty && _selectedSequence.last == card.position;

    // 정답 경로 하이라이트 (라운드 종료 시)
    final isInPath = showPaths && _validPaths.isNotEmpty && _validPaths.first.contains(card.position);

    Color bgColor;
    Color borderColor;
    double borderW;

    if (isSelected) {
      bgColor = const Color(0xFFE67E22).withValues(alpha: 0.3);
      borderColor = const Color(0xFFE67E22);
      borderW = 3;
    } else if (isInPath) {
      bgColor = Colors.green.withValues(alpha: 0.2);
      borderColor = Colors.green;
      borderW = 2.5;
    } else if (canSelect) {
      bgColor = Colors.white;
      borderColor = const Color(0xFFE67E22).withValues(alpha: 0.5);
      borderW = 2;
    } else {
      bgColor = Colors.grey[200]!;
      borderColor = Colors.grey[400]!;
      borderW = 1;
    }

    return Positioned(
      left: x,
      top: y,
      child: GestureDetector(
        onTap: () {
          if (isLastSelected) {
            _toggleCardSelection(card.position);
          } else if (canSelect) {
            _toggleCardSelection(card.position);
          }
        },
        child: SizedBox(
          width: hexSize,
          height: hexSize,
          child: CustomPaint(
            painter: _HexagonPainter(
              fillColor: bgColor,
              borderColor: borderColor,
              borderWidth: borderW,
              shadowColor: isSelected
                  ? const Color(0xFFE67E22).withValues(alpha: 0.3)
                  : Colors.black.withValues(alpha: 0.1),
            ),
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    card.displayText,
                    style: TextStyle(
                      fontSize: hexSize * 0.28,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? const Color(0xFFE67E22) : Colors.black87,
                    ),
                  ),
                  // 선택 순서 번호
                  if (isSelected && selectionOrder >= 0)
                    Positioned(
                      top: hexSize * 0.12,
                      right: hexSize * 0.12,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE67E22),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${selectionOrder + 1}',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ),
                ],
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
                      const Icon(Icons.leaderboard, color: Color(0xFFE67E22)),
                      const SizedBox(width: 8),
                      const Text('솔로 랭킹', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFFE67E22))),
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
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE67E22)),
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
                    const Icon(Icons.person_add, color: Color(0xFFE67E22)),
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
                                  backgroundColor: const Color(0xFFE67E22).withValues(alpha: 0.2),
                                  child: Text(
                                    friend.nickname.isNotEmpty ? friend.nickname[0].toUpperCase() : '?',
                                    style: const TextStyle(color: Color(0xFFE67E22)),
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
                                  friendProvider.inviteToGame(friend.id, AppConfig.gameTypePyramid, isHardcore: false);
                                  Navigator.pop(dialogContext);
                                  ScaffoldMessenger.of(context).clearSnackBars();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('${friend.nickname}님에게 초대를 보냈습니다!'), backgroundColor: Colors.green),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFE67E22), foregroundColor: Colors.white,
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
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _showExitDialog(GameTheme theme) {
    if (_status == PyramidGameStatus.idle || _status == PyramidGameStatus.finished) {
      Navigator.pop(context);
      return;
    }
    if (_status == PyramidGameStatus.searching) {
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

/// 육각형 카드 페인터
class _HexagonPainter extends CustomPainter {
  final Color fillColor;
  final Color borderColor;
  final double borderWidth;
  final Color shadowColor;

  _HexagonPainter({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
    required this.shadowColor,
  });

  Path _hexPath(Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;
    // Flat-top hexagon: 6 vertices
    final r = min(w, h) / 2 * 0.95;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (pi / 180) * (60 * i - 30);
      final x = cx + r * cos(angle);
      final y = cy + r * sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _hexPath(size);

    // Shadow
    final shadowPaint = Paint()
      ..color = shadowColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawPath(path.shift(const Offset(0, 2)), shadowPaint);

    // Fill
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // Border
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _HexagonPainter oldDelegate) {
    return fillColor != oldDelegate.fillColor ||
        borderColor != oldDelegate.borderColor ||
        borderWidth != oldDelegate.borderWidth ||
        shadowColor != oldDelegate.shadowColor;
  }

  @override
  bool hitTest(Offset position) {
    // Only respond to taps inside the hexagon
    return true;
  }
}
