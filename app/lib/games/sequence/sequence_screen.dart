import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/socket_service.dart';
import '../../services/socket_listener_registry.dart';
import '../../config/app_config.dart';
import '../../models/shop_item.dart';
import '../../utils/game_theme.dart';
import '../common/game_hardcore_toggle.dart';
import '../common/game_intro_view.dart';
import '../common/game_duel_header.dart';
import '../common/game_event_helper.dart';
import '../common/game_scaffold.dart';
import '../common/game_exit_helper.dart';
import '../common/game_reconnect_helper.dart';
import '../common/game_result_action_buttons.dart';
import '../common/game_result_summary.dart';
import '../common/game_screen_transition.dart';
import '../common/game_session_helper.dart';
import '../common/game_stage_panel.dart';
import '../common/game_timer_badge.dart';
import '../common/game_waiting_view.dart';

enum SequenceGameStatus {
  idle,
  searching,
  matched,
  showing, // 시퀀스 보여주는 중
  playing, // 입력 대기 중
  waiting, // 상대 입력 대기 중
  finished,
}

class SequenceScreen extends StatefulWidget {
  final bool isRanked;

  const SequenceScreen({super.key, this.isRanked = false});

  @override
  State<SequenceScreen> createState() => _SequenceScreenState();
}

class _SequenceScreenState extends State<SequenceScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;  // 중복 pop 방지
  bool _isExitDialogOpen = false;  // 나가기 다이얼로그 열림 상태

  SequenceGameStatus _status = SequenceGameStatus.idle;

  String? _roomId;
  String? _myId;
  String? _myNickname;
  String? _myAvatarUrl;
  String? _opponentNickname;
  String? _opponentAvatarUrl;
  int? _opponentUserId;
  bool _isInvitationGame = false;
  int _myPlayerIndex = 0;
  UserProfileSettings? _myProfileSettings;
  UserProfileSettings? _opponentProfileSettings;

  int _gridSize = 9; // 3x3
  List<int> _sequence = [];
  int _currentLevel = 0;
  int _showingIndex = -1; // 현재 보여주고 있는 시퀀스 인덱스
  int _showDelay = 600;
  bool _isHardcore = false; // 하드코어 모드

  List<int> _myInputs = [];
  bool _myFailed = false;
  bool _opponentFailed = false;
  int _myMaxLevel = 0;
  int _opponentMaxLevel = 0;

  // 게임 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;
  bool _isReconnecting = false;
  bool _isWaitingForReconnect = false;
  bool _isResyncingPhase = false;
  Timer? _reconnectTimer;
  Timer? _waitingReconnectTimer;
  int _reconnectSecondsRemaining = GameReconnectHelper.reconnectGraceDuration.inSeconds;

  // 타이머
  int _timeLimit = 0; // ms
  int _remainingSeconds = 0;
  Timer? _countdownTimer;

  // 애니메이션
  Timer? _showTimer;
  int? _lastInputPosition;
  bool? _lastInputCorrect;
  Timer? _feedbackTimer;
  int _sequencePlaybackToken = 0;

  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      _myId = auth.socketId;
      _myNickname = auth.nickname;
      _myAvatarUrl = auth.avatarUrl;
      _setupSocketListeners();

      // 초대 게임인 경우 GameProvider에서 초기 상태 가져오기
      _initFromGameProvider();
    });
  }

  void _initFromGameProvider() {
    try {
      final game = context.read<GameProvider>();
      debugPrint('🎮 SequenceScreen _initFromGameProvider: isInvitation=${game.isInvitationGame}, roomId=${game.roomId}, opponentNickname=${game.opponentNickname}, status=${game.status}');
      final isActiveInvitation = game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched || game.status == GameStatus.playing);
      if (isActiveInvitation) {
        debugPrint('🎮 SequenceScreen: 초대 게임 초기화 from GameProvider');
        setState(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = SequenceGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 SequenceScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _feedbackTimer?.cancel();
    _countdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _animController.dispose();
    _socketListeners.offAll();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != SequenceGameStatus.idle &&
      _status != SequenceGameStatus.searching &&
      _status != SequenceGameStatus.finished;

  void _startCountdown([int? overrideTimeLimitMs]) {
    _countdownTimer?.cancel();
    final countdownMs = overrideTimeLimitMs ?? _timeLimit;
    _remainingSeconds = (countdownMs / 1000).ceil();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_remainingSeconds > 0) {
        setState(() => _remainingSeconds--);
      } else {
        timer.cancel();
      }
    });
  }

  void _stopCountdown() {
    _countdownTimer?.cancel();
  }

  void _cancelSequencePlayback() {
    _sequencePlaybackToken++;
    _showTimer?.cancel();
  }

  void _startWaitingReconnectCountdown() {
    _waitingReconnectTimer?.cancel();
    _waitingReconnectTimer = GameReconnectHelper.startVisualCountdown(
      onTick: (seconds) {
        if (!mounted || !_isWaitingForReconnect) return;
        setState(() => _reconnectSecondsRemaining = seconds);
      },
    );
  }

  void _setupSocketListeners() {
    _socketListeners.on('connect', (_) {
      _myId = _socketService.socket?.id;
      if (!_isGameActive || _roomId == null) return;
      _reconnectTimer?.cancel();
      _waitingReconnectTimer?.cancel();
      _cancelSequencePlayback();
      _stopCountdown();
      _feedbackTimer?.cancel();
      _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
        context: context,
        showFailureSnackBar: false,
        onEnterWaiting: () => setState(() {
          _isReconnecting = true;
          _isWaitingForReconnect = false;
          _reconnectSecondsRemaining = GameReconnectHelper.reconnectGraceDuration.inSeconds;
        }),
        onTick: (seconds) {
          if (!mounted) return;
          setState(() => _reconnectSecondsRemaining = seconds);
        },
        onTimeout: () {
          GameSessionHelper.handleReconnectTimeout(
            context: context,
            mounted: mounted,
            hasScheduledPop: _hasScheduledPop,
            markScheduledPop: () => _hasScheduledPop = true,
            beforeNavigate: () {
              _cancelSequencePlayback();
              _countdownTimer?.cancel();
              _feedbackTimer?.cancel();
              _reset();
            },
          );
        },
      );
    });

    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = SequenceGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.cast<Map<String, dynamic>?>().firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = SequenceGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        // 프로필 설정 파싱
        if (opponent['profileSettings'] != null) {
          _opponentProfileSettings = UserProfileSettings.fromJson(opponent['profileSettings']);
        }
        if (me != null && me['profileSettings'] != null) {
          _myProfileSettings = UserProfileSettings.fromJson(me['profileSettings']);
        }
      });
    });

    _socketListeners.on('game_start', (data) {
      debugPrint('🎮 game_start received: $data');
      debugPrint('🎮 gameType: ${data['gameType']}');
      if (data['gameType'] == 'sequence') {
        if (data['players'] != null) {
          final players = data['players'] as List;
          final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
          if (updatedIndex != -1) {
            _myPlayerIndex = updatedIndex;
          }
        }
        // finished 상태에서 재경기 요청 안 했으면 무시
        if (_status == SequenceGameStatus.finished && !_rematchWaiting) {
          debugPrint('game_start ignored: not waiting for rematch');
          return;
        }
        // 게임 시작 시 모든 SnackBar 제거 (중복 알림 방지)
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
        }
        debugPrint('🎮 Starting sequence game!');
        setState(() {
          _gridSize = data['gridSize'] ?? 9;
          _sequence = List<int>.from(data['sequence'] ?? []);
          _currentLevel = data['level'] ?? _sequence.length;
          _showDelay = data['showDelay'] ?? 600;
          _timeLimit = data['timeLimit'] ?? 9000;
          _remainingSeconds = (_timeLimit / 1000).ceil();
          _isHardcore = data['isHardcore'] ?? false;
          _myInputs = [];
          _myFailed = false;
          _opponentFailed = false;
          _myMaxLevel = 0;
          _opponentMaxLevel = 0;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
          _isReconnecting = false;
          _isWaitingForReconnect = false;
        });
        _showSequence();
      }
    });

    _socketListeners.on('sequence_show', (data) {
      final isReconnectResume = data['isReconnectResume'] == true;
      setState(() {
        _sequence = List<int>.from(data['sequence']);
        _currentLevel = data['level'];
        _showDelay = data['showDelay'] ?? 600;
        _timeLimit = data['timeLimit'] ?? 9000;
        _remainingSeconds = (_timeLimit / 1000).ceil();
        _myInputs = [];
        _isWaitingForReconnect = false;
      });
      if (isReconnectResume) {
        _cancelSequencePlayback();
        _stopCountdown();
        setState(() {
          _status = SequenceGameStatus.showing;
          _showingIndex = -1;
          _isResyncingPhase = true;
        });
      } else {
        _showSequence();
      }
    });

    _socketListeners.on('sequence_timeout', (data) {
      final playerIndex = data['playerIndex'] as int;
      if (playerIndex == _myPlayerIndex) {
        _stopCountdown();
        setState(() {
          _myFailed = true;
          _status = SequenceGameStatus.waiting;
        });
      } else {
        setState(() => _opponentFailed = true);
      }
    });

    _socketListeners.on('sequence_input', (data) {
      final playerIndex = data['playerIndex'] as int;
      final failed = data['failed'] as bool;

      if (playerIndex != _myPlayerIndex) {
        // 상대방 입력
        if (failed) {
          setState(() => _opponentFailed = true);
        }
      }
    });

    _socketListeners.on('sequence_round_complete', (data) {
      // 둘 다 성공 - 다음 라운드 대기
      setState(() {
        _myMaxLevel = _currentLevel;
        _status = SequenceGameStatus.waiting;
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('sequence_round_resumed', (data) {
      _cancelSequencePlayback();
      final sequence = List<int>.from(data['sequence'] ?? _sequence);
      final playerInputs = List<List<int>>.from(
        (data['playerInputs'] as List<dynamic>? ?? const [])
            .map((item) => List<int>.from(item as List<dynamic>)),
      );
      final playerFailed = List<bool>.from(data['playerFailed'] ?? [_myFailed, _opponentFailed]);
      final playerMaxLevels = List<int>.from(data['playerMaxLevels'] ?? [_myMaxLevel, _opponentMaxLevel]);
      final phase = data['phase'] as String? ?? 'playing';

      final myInputs = playerInputs.length > _myPlayerIndex
          ? playerInputs[_myPlayerIndex]
          : _myInputs;
      final opponentIndex = _myPlayerIndex == 0 ? 1 : 0;
      final myFailed = playerFailed.length > _myPlayerIndex
          ? playerFailed[_myPlayerIndex]
          : _myFailed;
      final opponentFailed = playerFailed.length > opponentIndex
          ? playerFailed[opponentIndex]
          : _opponentFailed;
      final remainingTimeMs = (data['remainingTimeMs'] as num?)?.toInt() ?? (data['timeLimit'] as num?)?.toInt() ?? _timeLimit;

      setState(() {
        _sequence = sequence;
        _currentLevel = data['level'] ?? _currentLevel;
        _timeLimit = data['timeLimit'] ?? _timeLimit;
        _remainingSeconds = (remainingTimeMs / 1000).ceil();
        _myInputs = myInputs;
        _myFailed = myFailed;
        _opponentFailed = opponentFailed;
        _myMaxLevel = playerMaxLevels.length > _myPlayerIndex
            ? playerMaxLevels[_myPlayerIndex]
            : _myMaxLevel;
        _opponentMaxLevel = playerMaxLevels.length > opponentIndex
            ? playerMaxLevels[opponentIndex]
            : _opponentMaxLevel;
        _status = phase == 'waiting'
            ? SequenceGameStatus.waiting
            : (myFailed ? SequenceGameStatus.waiting : SequenceGameStatus.playing);
        _isWaitingForReconnect = false;
        _isReconnecting = false;
        _isResyncingPhase = false;
      });
      if (phase == 'playing' && !myFailed) {
        _startCountdown(remainingTimeMs);
      } else {
        _stopCountdown();
      }
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'sequence') return;
      _reconnectTimer?.cancel();
      _cancelSequencePlayback();
      _myId = _socketService.socket?.id;
      final remainingTimeMs = (data['remainingTimeMs'] as num?)?.toInt() ?? (data['timeLimit'] as num?)?.toInt() ?? _timeLimit;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _gridSize = (data['gridSize'] as num?)?.toInt() ?? _gridSize;
        _sequence = List<int>.from(data['sequence'] ?? _sequence);
        _currentLevel = (data['level'] as num?)?.toInt() ?? _currentLevel;
        _showDelay = (data['showDelay'] as num?)?.toInt() ?? _showDelay;
        _timeLimit = (data['timeLimit'] as num?)?.toInt() ?? _timeLimit;
        _remainingSeconds = (remainingTimeMs / 1000).ceil();
        _isHardcore = data['isHardcore'] == true;
        _myInputs = List<int>.from(data['myInputs'] ?? _myInputs);
        _myFailed = data['myFailed'] == true;
        _opponentFailed = data['opponentFailed'] == true;
        _myMaxLevel = (data['myMaxLevel'] as num?)?.toInt() ?? _myMaxLevel;
        _opponentMaxLevel = (data['opponentMaxLevel'] as num?)?.toInt() ?? _opponentMaxLevel;
        final phase = data['phase'] as String? ?? 'playing';
        _status = switch (phase) {
          'showing' => SequenceGameStatus.showing,
          'waiting' => SequenceGameStatus.waiting,
          _ => (_myFailed ? SequenceGameStatus.waiting : SequenceGameStatus.playing),
        };
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        _isResyncingPhase = phase == 'showing';
      });
      final phase = data['phase'] as String? ?? 'playing';
      if (phase == 'playing' && _status == SequenceGameStatus.playing) {
        _startCountdown(remainingTimeMs);
      } else {
        _stopCountdown();
      }
      GameReconnectHelper.completeReconnect(
        context: context,
        onRecovered: () {},
      );
    });

    _socketListeners.on('reconnect_failed', (_) {
      _reconnectTimer?.cancel();
      GameSessionHelper.handleReconnectTimeout(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
        beforeNavigate: () {
          _cancelSequencePlayback();
          _stopCountdown();
          _feedbackTimer?.cancel();
          _reset();
        },
        message: '20초 안에 연결을 복구하지 못해 게임에서 제외되었습니다.',
      );
    });

    _socketListeners.on('opponent_disconnected', (_) {
      if (!_isGameActive) return;
      _cancelSequencePlayback();
      _stopCountdown();
      _feedbackTimer?.cancel();
      setState(() {
        _reconnectSecondsRemaining = GameReconnectHelper.reconnectGraceDuration.inSeconds;
        _isWaitingForReconnect = true;
        _isReconnecting = false;
      });
      _startWaitingReconnectCountdown();
    });

    _socketListeners.on('opponent_reconnected', (_) {
      if (!_isGameActive) return;
      _waitingReconnectTimer?.cancel();
      setState(() => _isWaitingForReconnect = false);
      GameReconnectHelper.showOpponentReconnected(context);
    });

    _socketListeners.on('game_end', (data) {
      if (_status == SequenceGameStatus.finished) return;
      _cancelSequencePlayback();
      _stopCountdown();
      setState(() {
        _status = SequenceGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        _isResyncingPhase = false;
        if (data['maxLevels'] != null) {
          final maxLevels = List<int>.from(data['maxLevels']);
          _myMaxLevel = maxLevels[_myPlayerIndex];
          _opponentMaxLevel = maxLevels[1 - _myPlayerIndex];
        } else {
          _myMaxLevel = data['player${_myPlayerIndex}Level'] ?? 0;
          _opponentMaxLevel = data['player${1 - _myPlayerIndex}Level'] ?? 0;
        }
      });
      _waitingReconnectTimer?.cancel();
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == SequenceGameStatus.idle ||
          _status == SequenceGameStatus.searching ||
          _status == SequenceGameStatus.finished) {
        return;
      }
      // 나가기 다이얼로그가 열려있으면 먼저 닫기
      if (_isExitDialogOpen && mounted) {
        Navigator.of(context).pop();
        _isExitDialogOpen = false;
      }
      setState(() {
        _status = SequenceGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        _isResyncingPhase = false;
      });
      _waitingReconnectTimer?.cancel();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.isRanked
              ? '상대가 나가서 게임이 종료되었습니다. 승리!'
              : '상대방이 나갔습니다.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    });

    GameEventHelper.registerRematchHandlers(
      registry: _socketListeners,
      onRematchWaiting: (waiting) {
        setState(() => _rematchWaiting = waiting);
      },
      onOpponentRematchChanged: (wantsRematch) {
        setState(() => _opponentWantsRematch = wantsRematch);
      },
    );

    GameEventHelper.registerInvalidRoomHandler(
      registry: _socketListeners,
      onInvalidRoom: _handleRoomInvalid,
    );
  }

  void _handleRoomInvalid() {
    GameSessionHelper.handleInvalidRoom(
      context: context,
      mounted: mounted,
      hasScheduledPop: _hasScheduledPop,
      markScheduledPop: () => _hasScheduledPop = true,
      beforeNavigate: () {
        _cancelSequencePlayback();
        _countdownTimer?.cancel();
        _feedbackTimer?.cancel();
      },
    );
  }


  void _showSequence() {
    final playbackToken = ++_sequencePlaybackToken;
    debugPrint('🎮 _showSequence called! sequence: $_sequence');
    setState(() {
      _status = SequenceGameStatus.showing;
      _showingIndex = -1;
    });
    debugPrint('🎮 Status changed to showing');

    int index = 0;
    final int gapDuration = _isHardcore ? 100 : 180; // 하드코어는 gap도 짧게
    _showTimer?.cancel();

    void showNext() {
      if (!mounted || playbackToken != _sequencePlaybackToken) return;

      if (index < _sequence.length) {
        // 칸 켜기
        setState(() => _showingIndex = index);

        // showDelay 후 칸 끄기
        Future.delayed(Duration(milliseconds: _showDelay), () {
          if (!mounted || playbackToken != _sequencePlaybackToken) return;
          setState(() => _showingIndex = -1);

          // gap 후 다음 칸
          Future.delayed(Duration(milliseconds: gapDuration), () {
            if (!mounted || playbackToken != _sequencePlaybackToken) return;
            index++;
            showNext();
          });
        });
      } else {
        // 시퀀스 다 보여준 후 입력 모드
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && playbackToken == _sequencePlaybackToken) {
            setState(() {
              _showingIndex = -1;
              _status = SequenceGameStatus.playing;
            });
            _startCountdown();
          }
        });
      }
    }

    // 첫 번째 시작
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || playbackToken != _sequencePlaybackToken) return;
      showNext();
    });
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeSequence,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = SequenceGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeSequence,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = SequenceGameStatus.idle);
  }

  void _onCellTap(int position) {
    if (_status != SequenceGameStatus.playing || _myFailed || _roomId == null) {
      return;
    }

    final inputIndex = _myInputs.length;
    final expectedPosition = _sequence[inputIndex];
    final isCorrect = position == expectedPosition;

    setState(() {
      _myInputs.add(position);
      _lastInputPosition = position;
      _lastInputCorrect = isCorrect;
    });

    // 피드백 타이머
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _lastInputPosition = null;
          _lastInputCorrect = null;
        });
      }
    });

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'position': position},
    });

    if (!isCorrect) {
      _stopCountdown();
      setState(() {
        _myFailed = true;
        _myMaxLevel = _currentLevel - 1;
        _status = SequenceGameStatus.waiting;
      });
    } else if (_myInputs.length == _sequence.length) {
      // 현재 레벨 완료
      _stopCountdown();
      setState(() {
        _myMaxLevel = _currentLevel;
        _status = SequenceGameStatus.waiting;
      });
    }
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

  void _leaveGame() {
    GameSessionHelper.leaveGame(
      context: context,
      socketService: _socketService,
      roomId: _roomId,
      isRanked: widget.isRanked,
      resetState: _reset,
    );
  }

  void _reset() {
    _showTimer?.cancel();
    _feedbackTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    setState(() {
      _status = SequenceGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _sequence = [];
      _currentLevel = 0;
      _myInputs = [];
      _myFailed = false;
      _opponentFailed = false;
      _winnerId = null;
      _isDraw = false;
      _opponentLeft = false;
      _rematchWaiting = false;
      _opponentWantsRematch = false;
      _isInvitationGame = false;
      _isReconnecting = false;
      _isWaitingForReconnect = false;
      _isResyncingPhase = false;
    });
  }

  GameTheme get _theme => GameTheme.fromProfileSettings(
      context.read<ShopProvider>().profileSettings);

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitDialog();
      },
      child: Scaffold(
        appBar: gameAppBar(
          title: '순서 기억하기',
          backgroundColor: theme.primary,
          onBack: _showExitDialog,
        ),
        body: Stack(
          children: [
            GameScreenTransition(
              transitionKey: '${_status.name}-$_currentLevel-${_myInputs.length}-$_myFailed-$_opponentFailed-$_isResyncingPhase',
              child: _buildBody(),
            ),
            if (_isReconnecting)
              GameReconnectHelper.buildReconnectOverlay(
                title: '재연결 중...',
                message: '네트워크 연결을 다시 붙이는 중입니다.',
                resultMessage: '20초 안에 돌아오지 못하면 이 게임은 패배로 종료됩니다.',
                secondsRemaining: _reconnectSecondsRemaining,
                countdownLabel: '패배 처리까지',
                accentColor: _theme.primary,
              ),
            if (_isWaitingForReconnect)
              GameReconnectHelper.buildReconnectOverlay(
                title: '상대 재연결 대기 중',
                message: _isResyncingPhase
                    ? '게임 상태를 다시 맞추는 중입니다.'
                    : '상대 연결이 끊겨 게임을 잠시 멈췄습니다.',
                resultMessage: _isResyncingPhase
                    ? '동기화가 끝나면 현재 단계부터 자연스럽게 이어집니다.'
                    : '20초 안에 돌아오지 않으면 자동 승리로 처리됩니다.',
                secondsRemaining: _reconnectSecondsRemaining,
                countdownLabel: _isResyncingPhase ? '동기화 진행 중' : '자동 승리까지',
                accentColor: _theme.primary,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRankedWaitingView() {
    return GameWaitingView(
      backgroundGradient: _theme.backgroundGradient,
      accentColor: _theme.primary,
      icon: Icons.psychology,
      title: '순서 기억 준비 중',
      subtitle: '라운드 정보와 난이도를 맞추고 있습니다.',
      statusMessages: const [
        '시퀀스 길이와 난이도를 불러오고 있습니다.',
        '입력 시간을 계산하고 있습니다.',
        '상대와 진행 상태를 맞추고 있습니다.',
      ],
    );
  }

  Widget _buildBody() {
    return switch (_status) {
      SequenceGameStatus.idle => widget.isRanked ? _buildRankedWaitingView() : _buildIdleView(),
      SequenceGameStatus.searching => widget.isRanked ? _buildRankedWaitingView() : _buildSearchingView(),
      SequenceGameStatus.matched => widget.isRanked ? _buildRankedWaitingView() : _buildMatchedView(),
      SequenceGameStatus.showing => _buildShowingView(),
      SequenceGameStatus.playing => _buildPlayingView(),
      SequenceGameStatus.waiting => _buildWaitingView(),
      SequenceGameStatus.finished => _buildFinishedView(),
    };
  }

  void _showFriendInviteDialog(BuildContext context) {
    // 친구 목록 새로고침
    context.read<FriendProvider>().getFriends();

    final theme = _theme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (dialogContext) => Consumer<FriendProvider>(
        builder: (context, friendProvider, child) {
          final onlineFriends = friendProvider.friends.where((f) => f.isOnline).toList();

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.6,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 핸들
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 헤더
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(Icons.person_add, color: _isHardcore ? Colors.red : theme.primary),
                      const SizedBox(width: 12),
                      const Text(
                        '친구 초대',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      if (_isHardcore)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.local_fire_department, size: 16, color: Colors.red.shade400),
                              const SizedBox(width: 4),
                              Text('하드코어', style: TextStyle(fontSize: 12, color: Colors.red.shade400, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // 친구 목록
                Flexible(
                  child: onlineFriends.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(40),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.person_off, size: 48, color: Colors.grey.shade400),
                                const SizedBox(height: 16),
                                Text(
                                  '온라인 친구가 없습니다',
                                  style: TextStyle(color: Colors.grey.shade600),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: onlineFriends.length,
                          itemBuilder: (context, index) {
                            final friend = onlineFriends[index];
                            return ListTile(
                              leading: Stack(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: (_isHardcore ? Colors.red : theme.primary).withValues(alpha: 0.2),
                                    child: Text(
                                      friend.nickname.isNotEmpty ? friend.nickname[0].toUpperCase() : '?',
                                      style: TextStyle(color: _isHardcore ? Colors.red : theme.primary),
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: Colors.green,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 2),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              title: Text(friend.nickname, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: friend.memo != null && friend.memo!.isNotEmpty
                                  ? Text(friend.memo!, style: TextStyle(color: Colors.grey.shade600, fontSize: 12))
                                  : null,
                              trailing: ElevatedButton(
                                onPressed: () {
                                  friendProvider.inviteToGame(
                                    friend.id,
                                    AppConfig.gameTypeSequence,
                                    isHardcore: _isHardcore,
                                  );
                                  Navigator.pop(dialogContext);
                                  // 기존 SnackBar 제거 후 새 알림 표시 (중복 방지)
                                  ScaffoldMessenger.of(context).clearSnackBars();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('${friend.nickname}님에게 초대를 보냈습니다!'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _isHardcore ? Colors.red : theme.primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
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

  Widget _buildIdleView() {
    final accent = _isHardcore ? Colors.red : _theme.primary;
    return GameIntroView(
      backgroundGradient: _theme.backgroundGradient,
      accentColor: accent,
      icon: Icons.psychology,
      title: '순서 기억하기',
      descriptions: const ['깜빡이는 순서를 기억하세요!', '더 많이 기억한 사람이 승리!'],
      findMatchLabel: _isHardcore ? '하드코어 상대 찾기' : '상대 찾기',
      onFindMatch: _findMatch,
      onInviteFriend: () => _showFriendInviteDialog(context),
      extra: GameHardcoreToggle(
        value: _isHardcore,
        onChanged: (v) => setState(() => _isHardcore = v),
        activeHint: '2배 빠른 속도!',
      ),
    );
  }

  Widget _buildSearchingView() {
    final theme = _theme;
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: theme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 48),
            OutlinedButton(
              onPressed: _cancelMatch,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey,
                side: BorderSide(color: Colors.grey.shade400),
              ),
              child: const Text('취소'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMatchedView() {
    final theme = _theme;
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.background1,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sports_esports,
                size: 64,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '게임이 곧 시작됩니다...',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShowingView() {
    final theme = _theme;
    final totalSeconds = (_timeLimit / 1000).ceil();
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: theme.backgroundGradient,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 타이머 미리보기 (카운트다운 전)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.timer,
                        size: 20,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$totalSeconds초',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '순서를 기억하세요!',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: theme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                _buildGrid(enabled: false),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayingView() {
    final theme = _theme;
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: theme.backgroundGradient,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 타이머 표시
                GameTimerBadge(
                  seconds: _remainingSeconds,
                  label: '입력 남은 시간',
                  accentColor: _theme.primary,
                  compact: true,
                ),
                const SizedBox(height: 16),
                Text(
                  '순서대로 터치! (${_myInputs.length}/${_sequence.length})',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: theme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                _buildGrid(enabled: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWaitingView() {
    final message = _myFailed ? '틀렸습니다! 상대를 기다리는 중...' : '완료! 상대를 기다리는 중...';
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  (_myFailed ? Colors.red : Colors.green).withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
            child: Center(
              child: GameStagePanel(
                icon: _myFailed ? Icons.close_rounded : Icons.check_circle_rounded,
                title: _myFailed ? '입력 종료' : '입력 완료',
                subtitle: message,
                accentColor: _myFailed ? Colors.red : Colors.green,
                content: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                    color: _theme.primary,
                    strokeWidth: 3,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return GameDuelHeader(
      backgroundColors: const [Color(0xFFF3E5F5), Color(0xFFFCE4EC)],
      accentColor: _theme.primary,
      centerLabel: 'Lv.$_currentLevel',
      centerSubtitle: _isHardcore ? '하드코어' : (_gridSize == 16 ? '4x4 패턴' : '3x3 패턴'),
      myName: _myNickname ?? '나',
      opponentName: _opponentNickname ?? '상대',
      myAvatarUrl: _myAvatarUrl,
      opponentAvatarUrl: _opponentAvatarUrl,
      myActive: !_myFailed,
      opponentActive: !_opponentFailed,
      myProfileSettings: _myProfileSettings,
      opponentProfileSettings: _opponentProfileSettings,
      myExtraWidget: _buildStatusWidget(_myFailed),
      opponentExtraWidget: _buildStatusWidget(_opponentFailed),
    );
  }

  Widget _buildStatusWidget(bool failed) {
    if (!failed) return const SizedBox.shrink();
    return const GameHeaderStatusPill(
      text: 'OUT',
      color: Colors.red,
      margin: EdgeInsets.only(top: 4),
    );
  }

  Widget _buildGrid({required bool enabled}) {
    // gridSize: 9 = 3x3, 16 = 4x4
    final gridDimension = _gridSize == 16 ? 4 : 3;
    final cellSize = MediaQuery.of(context).size.width / (gridDimension + 1.5);

    return Center(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: _theme.primary.withValues(alpha: 0.2),
              blurRadius: 20,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(gridDimension, (row) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(gridDimension, (col) {
                final position = row * gridDimension + col;
                return _buildCell(
                  position,
                  cellSize,
                  enabled: enabled,
                );
              }),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildCell(int position, double size, {required bool enabled}) {
    final isShowing =
        _showingIndex >= 0 && _sequence[_showingIndex] == position;
    final isLastInput = _lastInputPosition == position;
    final isCorrectInput = isLastInput && _lastInputCorrect == true;
    final isWrongInput = isLastInput && _lastInputCorrect == false;
    final alreadyInput = _myInputs.contains(position) && !isLastInput;

    Color cellColor = Colors.grey.shade200;
    if (isShowing) {
      cellColor = _theme.primary;
    } else if (isCorrectInput) {
      cellColor = Colors.green;
    } else if (isWrongInput) {
      cellColor = Colors.red;
    } else if (alreadyInput) {
      cellColor = _theme.primary.withValues(alpha: 0.3);
    }

    return GestureDetector(
      onTap: enabled ? () => _onCellTap(position) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size - 8,
        height: size - 8,
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: cellColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: isShowing
              ? [
                  BoxShadow(
                    color: _theme.primary.withValues(alpha: 0.5),
                    blurRadius: 15,
                    spreadRadius: 2,
                  )
                ]
              : null,
        ),
        child: Center(
          child: isShowing
              ? const Icon(Icons.star, color: Colors.white, size: 32)
              : null,
        ),
      ),
    );
  }

  Widget _buildFinishedView() {
    final isWinner = _winnerId == _myId;

    // 랭크전에서는 결과만 표시하고 자동으로 돌아가기
    if (widget.isRanked) {
      GameSessionHelper.scheduleRankedAutoReturn(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
      );
      return GameRankedResultView(
        backgroundGradient: _theme.backgroundGradient,
        accentColor: _theme.primary,
        isWinner: isWinner,
        isDraw: _isDraw,
      );
    }

    String resultText;
    Color resultColor;
    IconData resultIcon;

    if (_isDraw) {
      resultText = '무승부!';
      resultColor = Colors.orange;
      resultIcon = Icons.handshake;
    } else if (isWinner) {
      resultText = '승리!';
      resultColor = _theme.primary;
      resultIcon = Icons.emoji_events;
    } else {
      resultText = '아쉬워요...';
      resultColor = Colors.grey;
      resultIcon = Icons.sentiment_dissatisfied;
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            resultColor.withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
            GameResultHero(
              icon: resultIcon,
              color: resultColor,
              title: resultText,
              subtitle: _isDraw
                  ? '기억력 대결이 끝까지 팽팽했어요.'
                  : (isWinner ? '더 높은 단계까지 침착하게 도달했어요.' : '다음 판은 초반 패턴부터 더 단단하게 기억해봐요.'),
            ),
            const SizedBox(height: 22),
            GameResultMatchupRow(
              leftLabel: '나',
              leftValue: 'Lv.$_myMaxLevel',
              rightLabel: _opponentNickname ?? '상대',
              rightValue: 'Lv.$_opponentMaxLevel',
              accentColor: resultColor,
            ),
            const SizedBox(height: 24),
            if (_opponentLeft)
              const GameResultStatusPill(
                icon: Icons.exit_to_app_rounded,
                text: '상대방이 나가서 경기 종료',
                color: Color(0xFF6B7280),
              ),
            if (_opponentWantsRematch && !_opponentLeft)
              GameResultStatusPill(
                icon: Icons.hourglass_top_rounded,
                text: '$_opponentNickname님이 재경기 대기 중',
                color: const Color(0xFF15803D),
              ),
            GameResultActionButtons(
              accentColor: _theme.primary,
              opponentLeft: _opponentLeft,
              rematchWaiting: _rematchWaiting,
              isInvitationGame: _isInvitationGame,
              canSendFriendRequest: !_isInvitationGame &&
                  !_opponentLeft &&
                  _opponentUserId != null &&
                  !context.read<FriendProvider>().isFriend(_opponentUserId!),
              onRematchPressed: _rematchWaiting ? _cancelRematch : _requestRematch,
              onSearchAgainPressed: () {
                _leaveGame();
                _findMatch();
              },
              onLobbyPressed: () {
                GameSessionHelper.leaveGameAndReturnToLobby(
                  context: context,
                  socketService: _socketService,
                  roomId: _roomId,
                  isRanked: widget.isRanked,
                  resetState: _reset,
                );
              },
              onFriendRequestPressed: _opponentUserId == null
                  ? null
                  : () {
                      context.read<FriendProvider>().sendFriendRequestByUserId(_opponentUserId!);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('$_opponentNickname님에게 친구 요청을 보냈습니다'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
            ),
          ],
        ),
      ),
      ),
    );
  }

  void _showExitDialog() {
    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && _status == SequenceGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting = widget.isRanked &&
        (_status == SequenceGameStatus.idle ||
            _status == SequenceGameStatus.searching ||
            _status == SequenceGameStatus.matched);

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (_status == SequenceGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }

    _isExitDialogOpen = true;
    showGameExitDialog(
      context: context,
      accentColor: _theme.primary,
      message: isRankedWaiting
          ? '랭크전 진행 중입니다.\n나가시겠습니까?'
          : '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
      onExit: _leaveGame,
    ).then((_) => _isExitDialogOpen = false);
  }
}
