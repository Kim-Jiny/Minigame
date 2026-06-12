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
import '../../utils/game_registry.dart';
import '../common/game_rematch_preparing_view.dart';
import '../common/game_intro_view.dart';
import '../common/game_scaffold.dart';
import '../common/game_duel_header.dart';
import '../common/game_event_helper.dart';
import '../common/game_exit_helper.dart';
import '../common/game_reconnect_helper.dart';
import '../common/game_result_action_buttons.dart';
import '../common/game_result_summary.dart';
import '../common/game_screen_transition.dart';
import '../common/game_session_helper.dart';
import 'set_card.dart';

enum SetGameStatus { idle, searching, matched, playing, finished }

class SetScreen extends StatefulWidget {
  final bool isRanked;

  /// 진입 맥락. solo면 혼자 연습(시간 랭킹 도전), versus면 온라인 대결.
  final GameEntryMode entryMode;

  const SetScreen({
    super.key,
    this.isRanked = false,
    this.entryMode = GameEntryMode.versus,
  });

  @override
  State<SetScreen> createState() => _SetScreenState();
}

class _SetScreenState extends State<SetScreen> {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners =
      SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;
  bool _isExitDialogOpen = false;

  SetGameStatus _status = SetGameStatus.idle;

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

  // 3·4인 — 전체 플레이어(인덱스 순서 = 점수 인덱스). 2인은 기존 _opponent* 그대로.
  int _maxPlayers = 2; // 진입화면 인원 선택(2·3·4)
  List<Map<String, dynamic>> _players = []; // match_found 전원 정보
  final Set<int> _leftIndices = {}; // 도중 이탈한 플레이어 인덱스
  bool get _isMulti => _players.length > 2;

  // 무한모드 게임 종료 합의 요청
  bool _endRequestPending = false; // 종료 요청 진행 중(내가 보냈거나 받음)
  int _endAgreed = 0; // 동의 인원
  int _endTotal = 0; // 활성 전체 인원
  bool _endDialogOpen = false; // 동의 다이얼로그 열림 여부

  // 게임 상태
  List<int> _board = []; // 카드 id 목록(12~18)
  List<int> _scores = [0, 0]; // 각자 모은 세트 수
  int _deckRemaining = 0;
  int _scoreToWin = 6;
  final List<int> _selected = []; // 선택한 카드 id(최대 3)
  bool _claimLocked = false; // 클레임 응답 대기/패널티 중 입력 잠금
  bool _lastClaimFailed = false; // 직전 내 클레임 실패(빨강 피드백)
  Timer? _penaltyTimer;
  Timer? _claimWatchdog; // 클레임 응답 유실 시 잠금 해제 안전장치

  // 게임 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  bool _wonByForfeit = false;
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;
  bool _isReconnecting = false;
  bool _isWaitingForReconnect = false;
  Timer? _reconnectTimer;
  Timer? _waitingReconnectTimer;
  int _reconnectSecondsRemaining =
      GameReconnectHelper.reconnectGraceDuration.inSeconds;

  // 타이머
  Timer? _countdownTimer;
  int _remainingSeconds = 120;

  // 무한모드 — 타이머·6점 선취 없이 덱을 끝까지 소진. 진입화면 토글로 선택.
  bool _isInfinite = false;

  // 솔로(혼자 연습) — 덱 소진까지 걸린 시간으로 랭킹 도전.
  bool _isSolo = false;
  Timer? _soloStopwatch; // 경과시간 표시 갱신용 틱
  final Stopwatch _soloClock = Stopwatch(); // 벽시계 기반 경과(틱 누락에도 정확)
  int _soloElapsedMs = 0; // 표시용 경과(클라 측정)
  int? _soloResultMs; // 서버가 확정한 최종 시간(랭킹 기준)
  int _soloSetsFound = 0;
  List<Map<String, dynamic>> _rankings = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      _myId = auth.socketId;
      _myNickname = auth.nickname;
      _myAvatarUrl = auth.avatarUrl;
      _setupSocketListeners();
      _initFromGameProvider();
    });
  }

  void _initFromGameProvider() {
    try {
      final game = context.read<GameProvider>();
      final isActiveInvitation = game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched ||
              game.status == GameStatus.playing);
      if (isActiveInvitation) {
        setState(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = SetGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🃏 SetScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _penaltyTimer?.cancel();
    _claimWatchdog?.cancel();
    _soloStopwatch?.cancel();
    _socketListeners.offAll();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != SetGameStatus.idle &&
      _status != SetGameStatus.searching &&
      _status != SetGameStatus.finished;

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    _remainingSeconds = seconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
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
      _stopCountdown();
      _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
        context: context,
        showFailureSnackBar: false,
        onEnterWaiting: () => setState(() {
          _isReconnecting = true;
          _isWaitingForReconnect = false;
          _reconnectSecondsRemaining =
              GameReconnectHelper.reconnectGraceDuration.inSeconds;
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
              _stopCountdown();
              _reset();
            },
          );
        },
      );
    });

    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = SetGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = (data['players'] as List)
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
      final opponent = players
          .cast<Map<String, dynamic>?>()
          .firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me =
          players.firstWhere((p) => p['id'] == _myId, orElse: () => <String, dynamic>{});
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = SetGameStatus.matched;
        _roomId = data['roomId'];
        _players = players; // 인덱스 순서 = 점수 인덱스
        _leftIndices.clear();
        // 2인 표시용(기존 GameDuelHeader 경로)
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        if (opponent['profileSettings'] != null) {
          _opponentProfileSettings =
              UserProfileSettings.fromJson(opponent['profileSettings']);
        }
        if (me['profileSettings'] != null) {
          _myProfileSettings = UserProfileSettings.fromJson(me['profileSettings']);
        }
      });
    });

    _socketListeners.on('set_player_left', (data) {
      final idx = (data['playerIndex'] as num?)?.toInt();
      if (idx == null) return;
      setState(() => _leftIndices.add(idx));
    });

    // 무한모드 종료 합의 — 다른 사람이 종료를 요청 → 동의 다이얼로그.
    _socketListeners.on('set_end_requested', (data) {
      final nickname = (data['nickname'] as String?) ?? '상대';
      setState(() => _endRequestPending = true);
      _showEndRequestDialog(nickname);
    });

    _socketListeners.on('set_end_progress', (data) {
      setState(() {
        _endRequestPending = true;
        _endAgreed = (data['agreed'] as num?)?.toInt() ?? _endAgreed;
        _endTotal = (data['total'] as num?)?.toInt() ?? _endTotal;
      });
    });

    _socketListeners.on('set_end_cancelled', (data) {
      _dismissEndRequestDialog();
      setState(() {
        _endRequestPending = false;
        _endAgreed = 0;
        _endTotal = 0;
      });
      if (mounted) {
        final by = (data['nickname'] as String?) ?? '상대';
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$by님이 종료 요청을 거절했어요')),
        );
      }
    });

    _socketListeners.on('game_start', (data) {
      if (data['gameType'] != 'set') return;
      if (data['players'] != null) {
        final players = data['players'] as List;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) _myPlayerIndex = updatedIndex;
      }
      if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
      setState(() {
        _status = SetGameStatus.playing;
        _board = [];
        _scores = [0, 0];
        _deckRemaining = 0; // 재경기 시 이전 게임의 남은 카드 수 잔상 방지
        _scoreToWin = 6;
        _selected.clear();
        _claimLocked = false;
        _lastClaimFailed = false;
        _winnerId = null;
        _isDraw = false;
        _opponentLeft = false;
        _wonByForfeit = false;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
      });
    });

    _socketListeners.on('set_start', (data) {
      final infinite = data['infinite'] == true;
      final solo = data['solo'] == true;
      final duration = (data['duration'] as num?)?.toInt() ?? 120000;
      setState(() {
        _status = SetGameStatus.playing;
        _isInfinite = infinite;
        _isSolo = solo;
        _board = List<int>.from(data['board'] ?? []);
        _scores = List<int>.from(data['scores'] ?? [0, 0]);
        _deckRemaining = (data['deckRemaining'] as num?)?.toInt() ?? 0;
        _scoreToWin = (data['scoreToWin'] as num?)?.toInt() ?? 6;
        _selected.clear();
        _claimLocked = false;
        _lastClaimFailed = false;
        _isWaitingForReconnect = false;
        // 새 게임 시작 시 종료 합의 상태 초기화.
        _endRequestPending = false;
        _endAgreed = 0;
        _endTotal = 0;
      });
      // 솔로는 경과시간 카운트업, 무한/솔로는 카운트다운 없음.
      if (solo) {
        _stopCountdown();
        _startSoloStopwatch();
      } else if (infinite) {
        _stopCountdown();
      } else {
        _startCountdown((duration / 1000).ceil());
      }
    });

    _socketListeners.on('set_claimed', (data) {
      _penaltyTimer?.cancel();
      _claimWatchdog?.cancel();
      setState(() {
        _board = List<int>.from(data['board'] ?? _board);
        _scores = List<int>.from(data['scores'] ?? _scores);
        _deckRemaining = (data['deckRemaining'] as num?)?.toInt() ?? _deckRemaining;
        _selected.clear();
        _claimLocked = false;
        _lastClaimFailed = false;
      });
    });

    _socketListeners.on('set_claim_rejected', (data) {
      // 점수 동기화(오답 -1 반영) — 양쪽 플레이어 모두
      if (data['scores'] != null) {
        setState(() => _scores = List<int>.from(data['scores']));
      }
      final playerIndex = (data['playerIndex'] as num?)?.toInt();
      if (playerIndex != _myPlayerIndex) return;
      _claimWatchdog?.cancel();
      // 내 잘못(오답/잘못된 입력)일 때만 빨강+잠금.
      // 상대가 먼저 가져가서 실패(not_on_board)/게임종료는 조용히 선택만 해제.
      final reason = data['reason'] as String?;
      final isMyFault = reason == 'not_a_set' || reason == 'bad_input';
      if (!isMyFault) {
        setState(() {
          _selected.clear();
          _claimLocked = false;
          _lastClaimFailed = false;
        });
        return;
      }
      setState(() {
        _lastClaimFailed = reason == 'not_a_set';
        _claimLocked = true;
      });
      _penaltyTimer?.cancel();
      _penaltyTimer = Timer(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        setState(() {
          _selected.clear();
          _claimLocked = false;
          _lastClaimFailed = false;
        });
      });
    });

    _socketListeners.on('set_timeout', (data) {
      _stopCountdown();
      setState(() {
        _scores = List<int>.from(data['scores'] ?? _scores);
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('set_resumed', (data) {
      final infinite = data['infinite'] == true;
      final duration = (data['duration'] as num?)?.toInt() ?? 120000;
      setState(() {
        _status = SetGameStatus.playing;
        _isInfinite = infinite;
        _board = List<int>.from(data['board'] ?? _board);
        _scores = List<int>.from(data['scores'] ?? _scores);
        _deckRemaining = (data['deckRemaining'] as num?)?.toInt() ?? _deckRemaining;
        _selected.clear();
        _claimLocked = false;
        _lastClaimFailed = false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      if (infinite) {
        _stopCountdown();
      } else {
        _startCountdown((duration / 1000).ceil());
      }
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'set') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      final infinite = data['infinite'] == true;
      final remainingMs = (data['remainingTimeMs'] as num?)?.toInt() ?? 120000;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _isInfinite = infinite;
        _board = List<int>.from(data['board'] ?? _board);
        _scores = List<int>.from(data['scores'] ?? _scores);
        _deckRemaining = (data['deckRemaining'] as num?)?.toInt() ?? _deckRemaining;
        _scoreToWin = (data['scoreToWin'] as num?)?.toInt() ?? _scoreToWin;
        _selected.clear();
        _claimLocked = false;
        _lastClaimFailed = false;
        _status = SetGameStatus.playing;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      if (infinite) {
        _stopCountdown();
      } else {
        _startCountdown((remainingMs / 1000).ceil());
      }
      GameReconnectHelper.completeReconnect(context: context, onRecovered: () {});
    });

    _socketListeners.on('reconnect_failed', (_) {
      _reconnectTimer?.cancel();
      GameSessionHelper.handleReconnectTimeout(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
        beforeNavigate: () {
          _stopCountdown();
          _reset();
        },
        message: '20초 안에 연결을 복구하지 못해 게임에서 제외되었습니다.',
      );
    });

    _socketListeners.on('opponent_disconnected', (_) {
      if (!_isGameActive) return;
      _stopCountdown();
      setState(() {
        _reconnectSecondsRemaining =
            GameReconnectHelper.reconnectGraceDuration.inSeconds;
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
      if (_status == SetGameStatus.finished) return;
      _stopCountdown();
      _stopSoloStopwatch();
      _dismissEndRequestDialog();
      setState(() {
        _endRequestPending = false;
        _status = SetGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        if (data['scores'] != null) {
          _scores = List<int>.from(data['scores']);
        }
        // 솔로 결과: 서버 확정 시간 + 찾은 세트 수.
        if (data['isSolo'] == true) {
          _isSolo = true;
          _soloResultMs = (data['timeMs'] as num?)?.toInt();
          _soloSetsFound = (data['setsFound'] as num?)?.toInt() ?? _scores[0];
        }
      });
      // 솔로 도전 직후 최신 랭킹 갱신.
      if (data['isSolo'] == true) _fetchRankings();
      _waitingReconnectTimer?.cancel();
    });

    _socketListeners.on('set_solo_ready', (data) {
      setState(() {
        _roomId = data['roomId'] as String?;
        _isSolo = true;
        _myPlayerIndex = 0;
        _status = SetGameStatus.matched;
      });
    });

    _socketListeners.on('set_rankings', (data) {
      final list = data['rankings'] as List<dynamic>? ?? [];
      setState(() {
        _rankings =
            list.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      });
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == SetGameStatus.idle || _status == SetGameStatus.searching) {
        return;
      }
      if (_status == SetGameStatus.finished) {
        setState(() {
          _opponentLeft = true;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
        });
        return;
      }
      if (_isExitDialogOpen && mounted) {
        Navigator.of(context).pop();
        _isExitDialogOpen = false;
      }
      setState(() {
        _status = SetGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
        _wonByForfeit = true;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
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
      onRematchWaiting: (waiting) => setState(() => _rematchWaiting = waiting),
      onOpponentRematchChanged: (wantsRematch) =>
          setState(() => _opponentWantsRematch = wantsRematch),
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
    );
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeSet,
      'isHardcore': false,
      'isInfinite': _isInfinite,
      'maxPlayers': _maxPlayers,
    });
    setState(() => _status = SetGameStatus.searching);
  }

  // ---- 솔로(혼자 연습) ----
  void _startSolo() {
    _socketService.emit('set_solo_start', {});
    setState(() {
      _isSolo = true;
      _soloResultMs = null;
      _soloElapsedMs = 0;
      _status = SetGameStatus.matched;
    });
  }

  void _fetchRankings() {
    _socketService.emit('set_get_rankings', {'limit': 20});
  }

  void _startSoloStopwatch() {
    _soloStopwatch?.cancel();
    _soloElapsedMs = 0;
    _soloClock
      ..reset()
      ..start();
    // 누적(+=100)이 아니라 매 틱마다 벽시계 경과를 읽어 표시 → 렌더링이 무거워
    // 틱이 밀리거나 누락돼도 시간이 짧게 표시되지 않는다.
    _soloStopwatch = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() => _soloElapsedMs = _soloClock.elapsedMilliseconds);
    });
  }

  void _stopSoloStopwatch() {
    _soloStopwatch?.cancel();
    _soloStopwatch = null;
    _soloClock.stop();
  }

  /// ms → "분:초.십분의일" (예: 1:23.4). 1분 미만은 "초.십분의일".
  static String _formatTime(int ms) {
    final totalTenths = (ms / 100).round();
    final tenths = totalTenths % 10;
    final totalSec = totalTenths ~/ 10;
    final sec = totalSec % 60;
    final min = totalSec ~/ 60;
    if (min > 0) {
      return '$min:${sec.toString().padLeft(2, '0')}.$tenths';
    }
    return '$sec.$tenths초';
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeSet,
      'isHardcore': false,
      'isInfinite': _isInfinite,
      'maxPlayers': _maxPlayers,
    });
    setState(() => _status = SetGameStatus.idle);
  }

  // ---- 무한모드 게임 종료 합의 ----
  void _requestEnd() {
    if (_roomId == null || _endRequestPending) return;
    _socketService.emit('set_request_end', {'roomId': _roomId});
    setState(() {
      _endRequestPending = true; // 요청자는 자동 동의
      _endAgreed = 1;
      _endTotal = _isMulti ? (_players.length - _leftIndices.length) : 2;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('종료 요청을 보냈어요 — 모두 동의하면 종료됩니다')),
      );
    }
  }

  void _showEndRequestDialog(String requester) {
    if (_endDialogOpen || !mounted) return;
    _endDialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('게임 종료 요청'),
        content: Text('$requester님이 게임 종료를 요청했어요.\n지금 점수로 종료하는 데 동의하시겠어요?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _endDialogOpen = false;
              _socketService.emit('set_end_vote', {'roomId': _roomId, 'agree': false});
            },
            child: const Text('거절'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _endDialogOpen = false;
              _socketService.emit('set_end_vote', {'roomId': _roomId, 'agree': true});
            },
            child: const Text('동의'),
          ),
        ],
      ),
    ).then((_) => _endDialogOpen = false);
  }

  void _dismissEndRequestDialog() {
    if (_endDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      _endDialogOpen = false;
    }
  }

  void _onCardTap(int cardId) {
    if (_status != SetGameStatus.playing || _claimLocked) return;
    setState(() {
      _lastClaimFailed = false;
      if (_selected.contains(cardId)) {
        _selected.remove(cardId);
      } else if (_selected.length < 3) {
        _selected.add(cardId);
      }
    });
    if (_selected.length == 3) _claim();
  }

  void _claim() {
    if (_roomId == null || _selected.length != 3) return;
    _claimLocked = true; // 응답까지 추가 입력 방지
    // 응답(set_claimed/set_claim_rejected) 유실 시 영구 잠금 방지용 워치독
    _claimWatchdog?.cancel();
    _claimWatchdog = Timer(const Duration(seconds: 2), () {
      if (!mounted || !_claimLocked) return;
      setState(() {
        _claimLocked = false;
        _selected.clear();
        _lastClaimFailed = false;
      });
    });
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'claim', 'cards': List<int>.from(_selected)},
    });
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
    _waitingReconnectTimer?.cancel();
    _penaltyTimer?.cancel();
    setState(() {
      _status = SetGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _board = [];
      _scores = [0, 0];
      _selected.clear();
      _claimLocked = false;
      _lastClaimFailed = false;
      _winnerId = null;
      _isDraw = false;
      _opponentLeft = false;
      _wonByForfeit = false;
      _rematchWaiting = false;
      _opponentWantsRematch = false;
      _isInvitationGame = false;
      _isReconnecting = false;
      _isWaitingForReconnect = false;
      // 솔로/멀티 상태도 초기화(다음 매칭 전 잔상 방지). _maxPlayers는 사용자 선택 유지.
      _isSolo = false;
      _players = [];
      _leftIndices.clear();
      _endRequestPending = false;
      _endAgreed = 0;
      _endTotal = 0;
    });
    _dismissEndRequestDialog();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ShopProvider>(
      builder: (context, shop, child) {
        final theme = GameTheme.fromProfileSettings(shop.profileSettings);
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _showExitDialog(theme);
          },
          child: Scaffold(
            appBar: gameAppBar(
              title: 'Set',
              backgroundColor: theme.primary,
              onBack: () => _showExitDialog(theme),
              actions: _endRequestActions(),
            ),
            body: Stack(
              children: [
                GameScreenTransition(
                  transitionKey: _status.name,
                  child: _buildBody(theme),
                ),
                ...GameReconnectHelper.buildStandardOverlays(
                  isReconnecting: _isReconnecting,
                  isWaitingForReconnect: _isWaitingForReconnect,
                  secondsRemaining: _reconnectSecondsRemaining,
                  accentColor: theme.primary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 무한모드 대결 플레이 중에만 우측 상단에 '게임 종료 요청' 버튼/대기 표시.
  List<Widget>? _endRequestActions() {
    final canShow =
        _status == SetGameStatus.playing && _isInfinite && !_isSolo;
    if (!canShow) return null;
    if (_endRequestPending) {
      return [
        Center(
          child: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Text(
              '동의 대기 $_endAgreed/$_endTotal',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ),
      ];
    }
    return [
      TextButton.icon(
        onPressed: _requestEnd,
        icon: const Icon(Icons.flag_rounded, size: 18, color: Colors.white),
        label: const Text('종료 요청',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
    ];
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      SetGameStatus.idle => _buildIdleView(theme),
      SetGameStatus.searching => _buildSearchingView(theme),
      SetGameStatus.matched => _buildMatchedView(theme),
      SetGameStatus.playing => _buildPlayingView(theme),
      SetGameStatus.finished => _buildFinishedView(theme),
    };
  }

  Widget _buildIdleView(GameTheme theme) {
    // 혼자 연습으로 진입 → 시간 랭킹 도전 + 랭킹 보기.
    if (widget.entryMode == GameEntryMode.solo) {
      return GameIntroView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: theme.primary,
        icon: Icons.style_rounded,
        title: 'Set 솔로',
        descriptions: const [
          '4속성이 모두 같거나 모두 다른 카드 3장!',
          '덱 81장을 모두 비우는 데 걸린 시간으로 랭킹 도전',
        ],
        extra: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              _fetchRankings();
              _showRankingSheet(theme);
            },
            icon: const Icon(Icons.leaderboard_rounded),
            label: const Text('솔로 랭킹 보기'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.primary,
              side: BorderSide(color: theme.primary.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
        findMatchLabel: '랭킹 도전 시작',
        onFindMatch: _startSolo,
      );
    }
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: theme.primary,
      icon: Icons.style_rounded,
      title: 'Set',
      descriptions: _isInfinite
          ? const [
              '4속성이 모두 같거나 모두 다른 카드 3장!',
              '타이머 없이 덱을 끝까지 · 더 많이 모은 쪽 승리',
            ]
          : const [
              '4속성이 모두 같거나 모두 다른 카드 3장!',
              '먼저 6세트 승리 · 틀리면 -1점 (120초)',
            ],
      extra: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SetPlayerCountSelector(
            value: _maxPlayers,
            accent: theme.primary,
            onChanged: (n) => setState(() => _maxPlayers = n),
          ),
          const SizedBox(height: 12),
          _SetInfiniteToggle(
            value: _isInfinite,
            accent: theme.primary,
            onChanged: (v) => setState(() => _isInfinite = v),
          ),
        ],
      ),
      // 3·4인은 친구 초대 미지원(랜덤 매칭 전용) — 2인일 때만 초대 버튼 노출.
      onFindMatch: _findMatch,
      onInviteFriend:
          _maxPlayers == 2 ? () => _showFriendInviteDialog(context) : null,
    );
  }

  Widget _buildSearchingView(GameTheme theme) {
    final accent = theme.primary;
    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: accent),
            const SizedBox(height: 24),
            Text('상대를 찾는 중...',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold, color: accent)),
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

  Widget _buildMatchedView(GameTheme theme) {
    final accent = theme.primary;
    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(Icons.sports_esports, size: 64, color: accent),
            ),
            const SizedBox(height: 16),
            Text(
                _isSolo
                    ? '랭킹 도전 준비!'
                    : _isMulti
                        ? '${_players.length}명 매칭 완료!'
                        : '$_opponentNickname님과 매칭!',
                style: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.bold, color: accent)),
            const SizedBox(height: 8),
            Text('게임이 곧 시작됩니다...',
                style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayingView(GameTheme theme) {
    final accent = theme.primary;

    // 솔로(시간 랭킹): 상대 없이 경과시간·찾은 세트·남은 카드만 표시.
    if (_isSolo) {
      return Container(
        decoration: BoxDecoration(gradient: theme.backgroundGradient),
        child: Column(
          children: [
            _buildSoloHeader(accent),
            Expanded(child: _buildBoard(accent)),
          ],
        ),
      );
    }

    // 3·4인: 전원 점수 보드 + 중앙 타이머/덱.
    if (_isMulti) {
      return Container(
        decoration: BoxDecoration(gradient: theme.backgroundGradient),
        child: Column(
          children: [
            _buildMultiHeader(accent),
            Expanded(child: _buildBoard(accent)),
          ],
        ),
      );
    }

    final myScore = _scores.length > _myPlayerIndex ? _scores[_myPlayerIndex] : 0;
    final opScore = _scores.length > (1 - _myPlayerIndex) ? _scores[1 - _myPlayerIndex] : 0;

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Column(
        children: [
          GameDuelHeader(
            backgroundColors: const [Colors.white, Colors.white],
            accentColor: accent,
            centerLabel: _isInfinite ? '$_deckRemaining' : '$_remainingSeconds',
            centerSubtitle: _isInfinite ? '남은 카드' : '남은 시간',
            myName: _myNickname ?? '나',
            opponentName: _opponentNickname ?? '상대',
            myAvatarUrl: _myAvatarUrl,
            opponentAvatarUrl: _opponentAvatarUrl,
            myActive: true,
            opponentActive: true,
            myProfileSettings: _myProfileSettings,
            opponentProfileSettings: _opponentProfileSettings,
            myExtraWidget: GameHeaderScorePill(
                score: myScore, color: accent, margin: const EdgeInsets.only(top: 4)),
            opponentExtraWidget: GameHeaderScorePill(
                score: opScore,
                color: Colors.grey.shade500,
                margin: const EdgeInsets.only(top: 4)),
          ),
          // 진행 안내
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '세트 3장 선택 · 남은 카드 $_deckRemaining장',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBoard(accent)),
        ],
      ),
    );
  }

  // 3·4인 공용 보드 헤더: 중앙에 타이머/남은카드, 그 아래 전원 점수 칩.
  Widget _buildMultiHeader(Color accent) {
    return SafeArea(
      bottom: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          children: [
            Text(
              _isInfinite ? '남은 카드 $_deckRemaining장' : '$_remainingSeconds초',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w800, color: accent),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(_players.length, (i) {
                final p = _players[i];
                final isMe = i == _myPlayerIndex;
                final left = _leftIndices.contains(i);
                final score = i < _scores.length ? _scores[i] : 0;
                final name = (p['nickname'] as String?) ?? '?';
                return Expanded(
                  child: Opacity(
                    opacity: left ? 0.4 : 1,
                    child: Column(
                      children: [
                        Text(
                          isMe ? '나' : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                isMe ? FontWeight.w800 : FontWeight.w600,
                            color: isMe ? accent : Colors.grey.shade600,
                            decoration:
                                left ? TextDecoration.lineThrough : null,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isMe
                                ? accent
                                : accent.withValues(alpha: 0.10),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '$score',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: isMe ? Colors.white : accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  // 3·4인 결과 순위표.
  Widget _buildMultiFinishedView(GameTheme theme) {
    final accent = theme.primary;
    int scoreOf(int i) => i < _scores.length ? _scores[i] : 0;
    bool isLeft(int i) => _leftIndices.contains(i);
    // 서버와 동일하게 이탈자는 승자·등수 후보에서 제외한다.
    // 활성 플레이어만 점수로 정렬·등수를 매기고, 이탈자는 맨 아래에 둔다.
    final active = [
      for (var i = 0; i < _players.length; i++)
        if (!isLeft(i)) i
    ]..sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));
    final leftList = [
      for (var i = 0; i < _players.length; i++)
        if (isLeft(i)) i
    ];
    final order = [...active, ...leftList];
    // 등수: 나보다 점수 높은 '활성' 인원 수 +1 → 동점은 같은 등수(공동 N등).
    int rankOf(int i) => 1 + active.where((j) => scoreOf(j) > scoreOf(i)).length;

    final myScore = scoreOf(_myPlayerIndex);
    final iAmActive = !isLeft(_myPlayerIndex);
    final myRank =
        iAmActive ? rankOf(_myPlayerIndex) : order.indexOf(_myPlayerIndex) + 1;
    final topScore = active.isNotEmpty ? scoreOf(active.first) : 0;
    final topCount = active.where((i) => scoreOf(i) == topScore).length;
    final iAmTop = iAmActive && myScore == topScore;
    final isSoleWinner = iAmTop && topCount == 1; // 단독 1등
    final isTopDraw = iAmTop && topCount > 1; // 공동 1등(무승부)

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GameResultHero(
                icon: isSoleWinner
                    ? Icons.emoji_events_rounded
                    : isTopDraw
                        ? Icons.handshake_rounded
                        : Icons.flag_rounded,
                color: isSoleWinner
                    ? accent
                    : isTopDraw
                        ? const Color(0xFFEA8A00)
                        : Colors.grey,
                title: isSoleWinner
                    ? '승리!'
                    : isTopDraw
                        ? '무승부!'
                        : '$myRank등',
                subtitle: isTopDraw
                    ? '${_players.length}명 중 공동 1등 · $myScore세트'
                    : '${_players.length}명 중 $myRank등 · $myScore세트',
              ),
              const SizedBox(height: 22),
              ...List.generate(order.length, (pos) {
                final i = order[pos];
                final p = _players[i];
                final isMe = i == _myPlayerIndex;
                final left = isLeft(i);
                final score = scoreOf(i);
                final r = left ? -1 : rankOf(i); // 이탈자는 등수 없음
                final medal = ['🥇', '🥈', '🥉'];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isMe ? accent.withValues(alpha: 0.10) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isMe
                          ? accent.withValues(alpha: 0.4)
                          : const Color(0xFFEDEDF2),
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child: Text(
                          left ? '–' : (r <= 3 ? medal[r - 1] : '$r'),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isMe ? '나' : ((p['nickname'] as String?) ?? '?'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                isMe ? FontWeight.w800 : FontWeight.w600,
                            color: isMe ? accent : const Color(0xFF1F2430),
                            decoration:
                                left ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      if (left)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text('이탈',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade400)),
                        ),
                      Text('$score세트',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: accent)),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    _leaveGame();
                    _findMatch();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('다시 매칭'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () {
                  _leaveGame();
                  Navigator.pop(context);
                },
                child:
                    Text('로비로', style: TextStyle(color: Colors.grey.shade600)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSoloHeader(Color accent) {
    Widget stat(IconData icon, String label, String value, Color color) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500)),
        ],
      );
    }

    return SafeArea(
      bottom: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 10, 14, 2),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            stat(Icons.timer_rounded, '경과 시간',
                _formatTime(_soloElapsedMs), accent),
            stat(Icons.check_circle_rounded, '찾은 세트',
                '${_scores.isNotEmpty ? _scores[0] : 0}', Colors.grey.shade700),
            stat(Icons.style_rounded, '남은 카드', '$_deckRemaining',
                Colors.grey.shade700),
          ],
        ),
      ),
    );
  }

  Widget _buildBoard(Color accent) {
    const cols = 3;
    const spacing = 10.0;
    // 안드로이드 시스템 네비게이션 바와 겹치지 않도록 하단 인셋만큼 비운다.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final padding = EdgeInsets.fromLTRB(14, 6, 14, 14 + bottomInset);
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = _board.length;
        if (count == 0) return const SizedBox.shrink();
        // 행 수에 맞춰 카드 종횡비를 계산 → 스크롤 없이 한 화면에 모두 표시.
        final rows = (count / cols).ceil();
        final availW = constraints.maxWidth - padding.horizontal;
        final availH = constraints.maxHeight - padding.vertical;
        final cardW = (availW - spacing * (cols - 1)) / cols;
        final cardH = (availH - spacing * (rows - 1)) / rows;
        final aspect = (cardH > 0 && cardW > 0) ? cardW / cardH : 0.74;
        return GridView.builder(
          padding: padding,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: aspect,
          ),
          itemCount: count,
          itemBuilder: (context, index) {
            final id = _board[index];
            final selected = _selected.contains(id);
            return SetCard(
              cardId: id,
              selected: selected,
              failed: selected && _lastClaimFailed,
              accent: accent,
              onTap: () => _onCardTap(id),
            );
          },
        );
      },
    );
  }

  Widget _buildFinishedView(GameTheme theme) {
    if (_rematchWaiting) {
      return GameRematchPreparingView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: theme.primary,
        onCancel: _cancelRematch,
      );
    }
    final isWinner = _winnerId == _myId;
    final accent = theme.primary;

    if (widget.isRanked) {
      GameSessionHelper.scheduleRankedAutoReturn(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
      );
      return GameRankedResultView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: accent,
        isWinner: isWinner,
        isDraw: _isDraw,
      );
    }

    // 솔로(시간 랭킹) 결과
    if (_isSolo) {
      final ms = _soloResultMs ?? _soloElapsedMs;
      return Container(
        decoration: BoxDecoration(gradient: theme.backgroundGradient),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GameResultHero(
                  icon: Icons.timer_rounded,
                  color: accent,
                  title: _formatTime(ms),
                  subtitle: '덱을 모두 비웠어요 · $_soloSetsFound세트',
                ),
                const SizedBox(height: 14),
                GameResultStatusPill(
                  icon: Icons.leaderboard_rounded,
                  text: '랭킹에 기록되었어요',
                  color: accent,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _status = SetGameStatus.idle;
                        _roomId = null;
                        _soloResultMs = null;
                      });
                      _startSolo();
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('다시 도전'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      _fetchRankings();
                      _showRankingSheet(theme);
                    },
                    icon: const Icon(Icons.leaderboard_rounded),
                    label: const Text('솔로 랭킹 보기'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accent,
                      side: BorderSide(color: accent.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('로비로',
                      style: TextStyle(color: Colors.grey.shade600)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 3·4인 결과: 전원 점수 순위표.
    if (_isMulti) {
      return _buildMultiFinishedView(theme);
    }

    String resultText;
    Color resultColor;
    IconData resultIcon;
    if (_wonByForfeit) {
      resultText = '승리!';
      resultColor = accent;
      resultIcon = Icons.emoji_events;
    } else if (_isDraw) {
      resultText = '무승부!';
      resultColor = Colors.orange;
      resultIcon = Icons.handshake;
    } else if (isWinner) {
      resultText = '승리!';
      resultColor = accent;
      resultIcon = Icons.emoji_events;
    } else {
      resultText = '아쉬워요...';
      resultColor = Colors.grey;
      resultIcon = Icons.sentiment_dissatisfied;
    }

    final myScore = _scores.length > _myPlayerIndex ? _scores[_myPlayerIndex] : 0;
    final opScore = _scores.length > (1 - _myPlayerIndex) ? _scores[1 - _myPlayerIndex] : 0;

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
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
                    ? '같은 수의 세트를 모았어요.'
                    : (isWinner ? '더 많은 세트를 찾았어요!' : '다음엔 패턴을 더 빠르게 찾아봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '$myScore세트',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '$opScore세트',
                accentColor: resultColor,
              ),
              const SizedBox(height: 24),
              if (_opponentWantsRematch && !_opponentLeft)
                GameResultStatusPill(
                  icon: Icons.hourglass_top_rounded,
                  text: '$_opponentNickname님이 재경기 대기 중',
                  color: const Color(0xFF15803D),
                ),
              GameResultActionButtons(
                accentColor: accent,
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
                  _leaveGame();
                  Navigator.pop(context);
                },
                onFriendRequestPressed: _opponentUserId == null
                    ? null
                    : () {
                        context
                            .read<FriendProvider>()
                            .sendFriendRequestByUserId(_opponentUserId!);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('$_opponentNickname님에게 친구 요청을 보냈습니다'),
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

  void _showRankingSheet(GameTheme theme) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                  child: Row(
                    children: [
                      Icon(Icons.leaderboard_rounded, color: theme.primary),
                      const SizedBox(width: 8),
                      Text('Set 솔로 랭킹',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: theme.primary)),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _rankings.isEmpty
                      ? Center(
                          child: Text('아직 기록이 없어요. 첫 기록을 세워보세요!',
                              style: TextStyle(color: Colors.grey.shade500)),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _rankings.length,
                          itemBuilder: (_, index) {
                            final r = _rankings[index];
                            final nickname = r['nickname'] as String? ?? '???';
                            final timeMs =
                                (r['time_ms'] as num?)?.toInt() ?? 0;
                            final setsFound =
                                (r['sets_found'] as num?)?.toInt() ?? 0;
                            final isTop3 = index < 3;
                            final badgeColor = isTop3
                                ? [
                                    const Color(0xFFFFC107),
                                    const Color(0xFFB0BEC5),
                                    const Color(0xFFBCAAA4),
                                  ][index]
                                : Colors.grey.shade200;
                            return ListTile(
                              leading: Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                    color: badgeColor, shape: BoxShape.circle),
                                child: Text('${index + 1}',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: isTop3
                                            ? Colors.white
                                            : Colors.grey.shade600)),
                              ),
                              title: Text(nickname,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text('$setsFound세트',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade500)),
                              trailing: Text(
                                _formatTime(timeMs),
                                style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: theme.primary),
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
          final onlineFriends =
              friendProvider.friends.where((f) => f.isOnline).toList();
          return Container(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(dialogContext).size.height * 0.6),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2)),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(Icons.person_add, color: theme.primary),
                      const SizedBox(width: 12),
                      const Text('친구 초대',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: onlineFriends.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(40),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.person_off,
                                    size: 48, color: Colors.grey.shade400),
                                const SizedBox(height: 16),
                                Text('온라인 친구가 없습니다',
                                    style: TextStyle(color: Colors.grey.shade600)),
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
                              leading: CircleAvatar(
                                backgroundColor: theme.primary.withValues(alpha: 0.2),
                                child: Text(
                                  friend.nickname.isNotEmpty
                                      ? friend.nickname[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(color: theme.primary),
                                ),
                              ),
                              title: Text(friend.nickname,
                                  style:
                                      const TextStyle(fontWeight: FontWeight.w600)),
                              trailing: ElevatedButton(
                                onPressed: () {
                                  friendProvider.inviteToGame(
                                    friend.id,
                                    AppConfig.gameTypeSet,
                                    isHardcore: false,
                                  );
                                  Navigator.pop(dialogContext);
                                  ScaffoldMessenger.of(context).clearSnackBars();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          '${friend.nickname}님에게 초대를 보냈습니다!'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: theme.primary,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('초대'),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showExitDialog(GameTheme theme) {
    if (!widget.isRanked && _status == SetGameStatus.idle) {
      Navigator.pop(context);
      return;
    }
    final isRankedWaiting = widget.isRanked &&
        (_status == SetGameStatus.idle ||
            _status == SetGameStatus.searching ||
            _status == SetGameStatus.matched);
    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }
    if (_status == SetGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }
    _isExitDialogOpen = true;
    showGameExitDialog(
      context: context,
      accentColor: theme.primary,
      message: '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
      onExit: _leaveGame,
    ).then((_) => _isExitDialogOpen = false);
  }
}

/// SET 진입 화면의 인원 선택(2·3·4인). 3·4인은 같은 공용 보드에서 다 같이 경쟁한다.
class _SetPlayerCountSelector extends StatelessWidget {
  final int value;
  final Color accent;
  final ValueChanged<int> onChanged;

  const _SetPlayerCountSelector({
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [2, 3, 4].map((n) {
          final selected = value == n;
          return GestureDetector(
            onTap: () => onChanged(n),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$n인',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: selected ? Colors.white : Colors.grey.shade600,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// SET 진입 화면의 무한모드 토글. 켜지면 타이머·6점 선취 없이
/// 덱을 끝까지 소진하는 변형으로 매칭한다(별도 큐).
class _SetInfiniteToggle extends StatelessWidget {
  final bool value;
  final Color accent;
  final ValueChanged<bool> onChanged;

  const _SetInfiniteToggle({
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: value ? accent.withValues(alpha: 0.12) : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: value ? accent.withValues(alpha: 0.5) : Colors.grey.shade300,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.all_inclusive_rounded,
                color: value ? accent : Colors.grey,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                '무한모드',
                style: TextStyle(
                  color: value ? accent : Colors.grey.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: accent,
                activeTrackColor: accent.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
        if (value)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '덱 81장을 끝까지 · 더 많이 모은 쪽 승리',
              style: TextStyle(
                fontSize: 12,
                color: accent,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }
}
