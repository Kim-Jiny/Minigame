import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/socket_service.dart';
import '../../services/socket_listener_registry.dart';
import '../../config/app_config.dart';
import '../../models/shop_item.dart';
import '../../theme/candy_theme.dart';
import '../../utils/game_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';
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
import '../common/game_stage_panel.dart';
import '../common/game_timer_badge.dart';
import '../common/game_waiting_view.dart';
import '../common/match_status_views.dart';
import '../tictactoe/tictactoe_screen.dart'
    show CandyPulse, showGameInviteSheet;

enum SpeedTapGameStatus { idle, searching, matched, playing, finished }

class SpeedTapScreen extends StatefulWidget {
  final bool isRanked;

  const SpeedTapScreen({super.key, this.isRanked = false});

  @override
  State<SpeedTapScreen> createState() => _SpeedTapScreenState();
}

class _SpeedTapScreenState extends State<SpeedTapScreen> {
  final SocketService _socketService = SocketService();
  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accent => GameTheme.fromProfileSettings(
    context.read<ShopProvider>().profileSettings,
  ).primary;
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );
  bool _hasScheduledPop = false; // 중복 pop 방지
  bool _isExitDialogOpen = false; // 나가기 다이얼로그 열림 상태

  SpeedTapGameStatus _status = SpeedTapGameStatus.idle;

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

  int _currentRound = 0;
  List<int> _roundScores = [0, 0]; // 라운드 승리 수
  List<int> _taps = [0, 0]; // 현재 라운드 탭 수
  bool _roundInProgress = false;

  // 라운드 결과
  int? _lastPlayer0Taps;
  int? _lastPlayer1Taps;
  int? _lastWinnerIndex;
  bool _lastIsDraw = false;

  // 게임 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
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
  int _remainingSeconds = 10;
  int _preRoundCountdown = 0; // 3-2-1 카운트다운
  Timer? _startCountdownTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
      debugPrint(
        '🎮 SpeedTapScreen _initFromGameProvider: isInvitation=${game.isInvitationGame}, roomId=${game.roomId}, opponentNickname=${game.opponentNickname}, status=${game.status}',
      );
      final isActiveInvitation =
          game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched ||
              game.status == GameStatus.playing);
      if (isActiveInvitation) {
        debugPrint('🎮 SpeedTapScreen: 초대 게임 초기화 from GameProvider');
        _set(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = SpeedTapGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 SpeedTapScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _startCountdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _socketListeners.offAll();
    super.dispose();
  }

  /// 소켓 콜백/타이머 등 비동기 경로에서 안전하게 쓰는 setState (dispose 이후 호출 방지).
  void _set(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  int _tapsOf(int index) =>
      (index >= 0 && index < _taps.length) ? _taps[index] : 0;

  int _roundWinsOf(int index) =>
      (index >= 0 && index < _roundScores.length) ? _roundScores[index] : 0;

  bool get _isGameActive =>
      _status != SpeedTapGameStatus.idle &&
      _status != SpeedTapGameStatus.searching &&
      _status != SpeedTapGameStatus.finished;

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    _remainingSeconds = seconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_remainingSeconds > 0) {
        _set(() => _remainingSeconds--);
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
        _set(() => _reconnectSecondsRemaining = seconds);
      },
    );
  }

  void _runStartCountdown(int from) {
    _startCountdownTimer?.cancel();
    _preRoundCountdown = from;
    HapticFeedback.selectionClick();
    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_preRoundCountdown > 1) {
        HapticFeedback.selectionClick();
        _set(() => _preRoundCountdown--);
      } else {
        timer.cancel();
        _set(() => _preRoundCountdown = 0);
      }
    });
  }

  void _setupSocketListeners() {
    _socketListeners.on('connect', (_) {
      _myId = _socketService.socket?.id;
      if (!_isGameActive || _roomId == null) return;
      _reconnectTimer?.cancel();
      _waitingReconnectTimer?.cancel();
      _stopCountdown();
      _startCountdownTimer?.cancel();
      _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
        context: context,
        showFailureSnackBar: false,
        onEnterWaiting: () => _set(() {
          _isReconnecting = true;
          _isWaitingForReconnect = false;
          _reconnectSecondsRemaining =
              GameReconnectHelper.reconnectGraceDuration.inSeconds;
        }),
        onTick: (seconds) {
          if (!mounted) return;
          _set(() => _reconnectSecondsRemaining = seconds);
        },
        onTimeout: () {
          GameSessionHelper.handleReconnectTimeout(
            context: context,
            mounted: mounted,
            hasScheduledPop: _hasScheduledPop,
            markScheduledPop: () => _hasScheduledPop = true,
            beforeNavigate: () {
              _stopCountdown();
              _startCountdownTimer?.cancel();
              _reset();
            },
          );
        },
      );
    });

    _socketListeners.on('waiting_for_match', (_) {
      _set(() => _status = SpeedTapGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.cast<Map<String, dynamic>?>().firstWhere(
        (p) => p!['id'] != _myId,
        orElse: () => null,
      );
      if (opponent == null) return;
      final me = players.firstWhere(
        (p) => p['id'] == _myId,
        orElse: () => null,
      );
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      _set(() {
        _status = SpeedTapGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        // 프로필 설정 파싱
        if (opponent['profileSettings'] != null) {
          _opponentProfileSettings = UserProfileSettings.fromJson(
            opponent['profileSettings'],
          );
        }
        if (me != null && me['profileSettings'] != null) {
          _myProfileSettings = UserProfileSettings.fromJson(
            me['profileSettings'],
          );
        }
      });
    });

    _socketListeners.on('game_start', (data) {
      if (data['gameType'] == 'speedtap') {
        if (data['players'] != null) {
          final players = data['players'] as List;
          final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
          if (updatedIndex != -1) {
            _myPlayerIndex = updatedIndex;
          }
        }
        // finished 상태에서 재경기 요청 안 했으면 무시
        if (_status == SpeedTapGameStatus.finished && !_rematchWaiting) {
          debugPrint('🎮 game_start ignored: not waiting for rematch');
          return;
        }
        // 게임 시작 시 모든 SnackBar 제거 (중복 알림 방지)
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
        }
        _set(() {
          _status = SpeedTapGameStatus.playing;
          _remainingSeconds = 10; // 재경기 시 이전 게임의 남은 시간 잔상 방지
          _currentRound = 0;
          _roundScores = [0, 0];
          _taps = [0, 0];
          _roundInProgress = false;
          // 이전 라운드 결과 리셋
          _lastPlayer0Taps = null;
          _lastPlayer1Taps = null;
          _lastWinnerIndex = null;
          _lastIsDraw = false;
          // 재경기 상태 리셋
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
        });
      }
    });

    _socketListeners.on('speedtap_countdown', (data) {
      final countdown = data['countdown'] as int? ?? 3;
      _set(() {
        _status = SpeedTapGameStatus.playing;
        _currentRound = data['round'];
        _roundScores = List<int>.from(data['roundScores']);
        _taps = [0, 0];
        _roundInProgress = false;
        _lastPlayer0Taps = null;
        _lastPlayer1Taps = null;
        _lastWinnerIndex = null;
        _lastIsDraw = false;
        _isWaitingForReconnect = false;
      });
      _runStartCountdown(countdown);
    });

    _socketListeners.on('speedtap_round_start', (data) {
      HapticFeedback.mediumImpact();
      final duration = data['duration'] as int? ?? 10000;
      _set(() {
        _status = SpeedTapGameStatus.playing;
        _currentRound = data['round'];
        _roundScores = List<int>.from(data['roundScores']);
        _taps = [0, 0];
        _roundInProgress = true;
        _preRoundCountdown = 0; // 카운트다운 종료
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
    });

    _socketListeners.on('speedtap_round_resumed', (data) {
      final duration = data['duration'] as int? ?? 10000;
      _startCountdownTimer?.cancel();
      _set(() {
        _status = SpeedTapGameStatus.playing;
        _currentRound = data['round'];
        _roundScores = List<int>.from(data['roundScores']);
        _taps = List<int>.from(data['taps'] ?? [0, 0]);
        _roundInProgress = true;
        _preRoundCountdown = 0;
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
    });

    _socketListeners.on('speedtap_tap', (data) {
      _set(() {
        _taps = List<int>.from(data['taps']);
      });
    });

    _socketListeners.on('speedtap_round_result', (data) {
      _stopCountdown();
      _set(() {
        _roundInProgress = false;
        _lastPlayer0Taps = data['player0Taps'];
        _lastPlayer1Taps = data['player1Taps'];
        _lastWinnerIndex = data['roundWinner'];
        _lastIsDraw = data['isDraw'] ?? false;
        _roundScores = List<int>.from(data['roundScores']);
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'speedtap') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      _startCountdownTimer?.cancel();
      _set(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex =
            (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _currentRound = (data['round'] as num?)?.toInt() ?? _currentRound;
        _roundScores = List<int>.from(data['roundScores'] ?? _roundScores);
        _taps = List<int>.from(data['taps'] ?? _taps);
        _roundInProgress = data['roundInProgress'] == true;
        _status = SpeedTapGameStatus.playing;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
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
          _stopCountdown();
          _startCountdownTimer?.cancel();
          _reset();
        },
        message: '20초 안에 연결을 복구하지 못해 게임에서 제외되었습니다.',
      );
    });

    _socketListeners.on('opponent_disconnected', (_) {
      if (!_isGameActive) return;
      _stopCountdown();
      _startCountdownTimer?.cancel();
      _set(() {
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
      _set(() => _isWaitingForReconnect = false);
      GameReconnectHelper.showOpponentReconnected(context);
    });

    _socketListeners.on('game_end', (data) {
      if (_status == SpeedTapGameStatus.finished) return;
      _stopCountdown();
      _set(() {
        _status = SpeedTapGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        if (data['roundScores'] != null) {
          _roundScores = List<int>.from(data['roundScores']);
        }
      });
      _waitingReconnectTimer?.cancel();
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == SpeedTapGameStatus.idle ||
          _status == SpeedTapGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == SpeedTapGameStatus.finished) {
        _set(() {
          _opponentLeft = true;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
        });
        return;
      }
      // 나가기 다이얼로그가 열려있으면 먼저 닫기
      if (_isExitDialogOpen && mounted) {
        Navigator.of(context).pop();
        _isExitDialogOpen = false;
      }
      _set(() {
        _status = SpeedTapGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      _waitingReconnectTimer?.cancel();
      // 즉시 알림 표시
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isRanked ? '상대가 나가서 게임이 종료되었습니다. 승리!' : '상대방이 나갔습니다.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    });

    GameEventHelper.registerRematchHandlers(
      registry: _socketListeners,
      onRematchWaiting: (waiting) {
        _set(() => _rematchWaiting = waiting);
      },
      onOpponentRematchChanged: (wantsRematch) {
        _set(() => _opponentWantsRematch = wantsRematch);
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
    );
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeSpeedTap,
      'isHardcore': false,
    });
    _set(() => _status = SpeedTapGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeSpeedTap,
      'isHardcore': false,
    });
    _set(() => _status = SpeedTapGameStatus.idle);
  }

  /// 탭이 실제로 전송되면 true (연출용 리플 표시 여부 판단).
  bool _tap() {
    if (!_roundInProgress || _roomId == null) return false;

    HapticFeedback.lightImpact();

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'tap'},
    });
    return true;
  }

  void _requestRematch() {
    if (_roomId == null) return;
    _socketService.emit('rematch_request', {'roomId': _roomId});
  }

  void _cancelRematch() {
    if (_roomId == null) return;
    _socketService.emit('rematch_cancel', {'roomId': _roomId});
    _set(() => _rematchWaiting = false);
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
    _set(() {
      _status = SpeedTapGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _currentRound = 0;
      _roundScores = [0, 0];
      _taps = [0, 0];
      _winnerId = null;
      _isDraw = false;
      _opponentLeft = false;
      _rematchWaiting = false;
      _opponentWantsRematch = false;
      _isInvitationGame = false;
      _isReconnecting = false;
      _isWaitingForReconnect = false;
    });
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
              title: '스피드 탭',
              backgroundColor: theme.primary,
              onBack: () => _showExitDialog(theme),
            ),
            body: Stack(
              children: [
                GameScreenTransition(
                  transitionKey:
                      '${_status.name}-$_currentRound-$_preRoundCountdown-$_roundInProgress-${_lastWinnerIndex ?? -1}-$_lastIsDraw',
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

  Widget _buildRankedWaitingView(GameTheme theme) {
    return GameWaitingView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: theme.primary,
      icon: Icons.touch_app,
      title: '스피드탭 준비 중',
      subtitle: '라운드와 점수판을 맞추고 있습니다.',
      statusMessages: const [
        '탭 카운트와 라운드 수를 맞추고 있습니다.',
        '시작 카운트다운을 준비하고 있습니다.',
        '상대의 입력 상태를 확인하고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      SpeedTapGameStatus.idle =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildIdleView(theme),
      SpeedTapGameStatus.searching =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildSearchingView(theme),
      SpeedTapGameStatus.matched =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildMatchedView(theme),
      SpeedTapGameStatus.playing => _buildPlayingView(theme),
      SpeedTapGameStatus.finished => _buildFinishedView(theme),
    };
  }

  void _showFriendInviteDialog(BuildContext context) {
    final theme = GameTheme.fromProfileSettings(
      context.read<ShopProvider>().profileSettings,
    );
    showGameInviteSheet(
      context: context,
      accent: theme.primary,
      gameType: AppConfig.gameTypeSpeedTap,
      refresh: true, // 친구 목록 새로고침
    );
  }

  Widget _buildIdleView(GameTheme theme) {
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: theme.primary,
      icon: Icons.touch_app,
      title: '스피드 탭',
      descriptions: const ['10초 동안 빠르게 터치!', '3라운드 중 2라운드 승리!'],
      onFindMatch: _findMatch,
      onInviteFriend: () => _showFriendInviteDialog(context),
    );
  }

  Widget _buildSearchingView(GameTheme theme) {
    return GameSearchingView(
      theme: theme,
      isHardcore: false,
      onCancel: _cancelMatch,
    );
  }

  Widget _buildMatchedView(GameTheme theme) {
    return GameMatchedView(theme: theme, opponentNickname: _opponentNickname);
  }

  Widget _buildPlayingView(GameTheme theme) {
    final bool showResult = _lastPlayer0Taps != null && !_roundInProgress;

    return Column(
      children: [
        // 프로필 & 점수판
        GameDuelHeader(
          backgroundColors: [
            theme.cardGradient.colors.first,
            theme.cardGradient.colors.last,
          ],
          accentColor: _accent,
          centerLabel: 'R$_currentRound',
          centerSubtitle: '3라운드 대결',
          myName: _myNickname ?? '나',
          opponentName: _opponentNickname ?? '상대',
          myAvatarUrl: _myAvatarUrl,
          opponentAvatarUrl: _opponentAvatarUrl,
          myActive: true,
          opponentActive: false,
          myProfileSettings: _myProfileSettings,
          opponentProfileSettings: _opponentProfileSettings,
          myExtraWidget: _buildTapScoreWidget(
            _tapsOf(_myPlayerIndex),
            _roundWinsOf(_myPlayerIndex),
            true,
          ),
          opponentExtraWidget: _buildTapScoreWidget(
            _tapsOf(1 - _myPlayerIndex),
            _roundWinsOf(1 - _myPlayerIndex),
            false,
          ),
        ),

        // 게임 영역
        Expanded(
          child: _preRoundCountdown > 0
              ? _buildCountdownView(theme)
              : (showResult ? _buildResultView(theme) : _buildTapView(theme)),
        ),
      ],
    );
  }

  Widget _buildTapScoreWidget(int tapCount, int roundWins, bool isMe) {
    return Column(
      children: [
        GameHeaderScorePill(
          score: tapCount,
          color: isMe ? _accent : CandyColors.inkSoft,
        ),
        const SizedBox(height: 2),
        GameHeaderStarTrack(
          total: 2,
          active: roundWins,
          activeColor: CandyColors.sunDeep,
        ),
      ],
    );
  }

  /// 탭/카운트다운 화면 배경: 액센트 계열 파스텔 그라데이션.
  BoxDecoration _stageBackground() {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(_accent, Colors.white, 0.7)!,
          Color.lerp(_accent, Colors.white, 0.3)!,
        ],
      ),
    );
  }

  Widget _buildCountdownView(GameTheme theme) {
    return Container(
      decoration: _stageBackground(),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                '준비!',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
              ),
              const SizedBox(height: 22),
              // 숫자가 바뀔 때마다 탄성 있게 튀어나온다.
              TweenAnimationBuilder<double>(
                key: ValueKey(_preRoundCountdown),
                tween: Tween(begin: 0.2, end: 1.0),
                duration: const Duration(milliseconds: 700),
                curve: Curves.elasticOut,
                builder: (_, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Container(
                  width: 144,
                  height: 144,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: CandyColors.ink, width: 4),
                    boxShadow: const [
                      BoxShadow(color: CandyColors.ink, offset: Offset(0, 8)),
                    ],
                  ),
                  child: Text(
                    '$_preRoundCountdown',
                    style: const TextStyle(
                      fontSize: 84,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      shadows: [
                        Shadow(color: CandyColors.ink, offset: Offset(0, 4)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 26),
              const Text(
                '터치 준비하세요!',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: CandyColors.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTapView(GameTheme theme) {
    final myTaps = _tapsOf(_myPlayerIndex);
    return _TapZone(
      decoration: _stageBackground(),
      onTap: _tap,
      builder: (pressed) {
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 타이머
                  GameTimerBadge(
                    seconds: _remainingSeconds,
                    label: '탭 남은 시간',
                    accentColor: _accent,
                    showLabel: false,
                  ),
                  const SizedBox(height: 18),
                  // 내 탭 수: 올라갈 때마다 팝
                  TweenAnimationBuilder<double>(
                    key: ValueKey(myTaps),
                    tween: Tween(begin: myTaps == 0 ? 1.0 : 1.4, end: 1.0),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.elasticOut,
                    builder: (_, scale, child) =>
                        Transform.scale(scale: scale, child: child),
                    child: CartoonCard(
                      radius: 22,
                      shadow: 4,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 26,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '$myTaps',
                            style: const TextStyle(
                              fontSize: 54,
                              fontWeight: FontWeight.w900,
                              color: CandyColors.ink,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            '탭',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: CandyColors.inkSoft,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  // 탭 패드: 눌리면 푹 꺼진다. 평소엔 숨 쉬듯 두근거린다.
                  CandyPulse(
                    duration: const Duration(milliseconds: 650),
                    builder: (_, t, child) => Transform.scale(
                      scale: pressed ? 0.93 : 1.0 + 0.035 * t,
                      child: child,
                    ),
                    child: Container(
                      width: 210,
                      height: 210,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: CandyColors.ink, width: 4),
                        boxShadow: [
                          BoxShadow(
                            color: CandyColors.ink,
                            offset: Offset(0, pressed ? 2 : 9),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.touch_app_rounded,
                        size: 100,
                        color: _accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    '터치!',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      shadows: [
                        Shadow(color: CandyColors.ink, offset: Offset(0, 3)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildResultView(GameTheme theme) {
    final myTaps = _myPlayerIndex == 0 ? _lastPlayer0Taps : _lastPlayer1Taps;
    final opponentTaps = _myPlayerIndex == 0
        ? _lastPlayer1Taps
        : _lastPlayer0Taps;
    final isMyWin = _lastWinnerIndex == _myPlayerIndex;
    final isOpponentWin = _lastWinnerIndex == (1 - _myPlayerIndex);
    final stateColor = _lastIsDraw
        ? CandyColors.sunDeep
        : (isMyWin ? CandyColors.mintDeep : CandyColors.pinkDeep);

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GameStagePanel(
                      icon: _lastIsDraw
                          ? Icons.handshake_rounded
                          : (isMyWin
                                ? Icons.flash_on_rounded
                                : Icons.timer_off_rounded),
                      title: _lastIsDraw
                          ? '무승부!'
                          : (isMyWin ? '라운드 승리!' : '라운드 패배'),
                      subtitle: '탭 수를 집계했고, 다음 라운드로 넘어갈 준비를 하고 있어요.',
                      accentColor: stateColor,
                      compact: true,
                    ),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _TapCountCard(
                              label: '나',
                              count: myTaps ?? 0,
                              highlight: isMyWin && !_lastIsDraw,
                              delayMs: 100,
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(
                              top: 30,
                              left: 8,
                              right: 8,
                            ),
                            child: Text(
                              ':',
                              style: TextStyle(
                                fontSize: 40,
                                fontWeight: FontWeight.w900,
                                color: CandyColors.ink,
                              ),
                            ),
                          ),
                          Expanded(
                            child: _TapCountCard(
                              label: _opponentNickname ?? '상대',
                              count: opponentTaps ?? 0,
                              highlight: isOpponentWin && !_lastIsDraw,
                              delayMs: 300,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '다음 라운드 준비 중...',
                      style: TextStyle(
                        color: CandyColors.inkSoft,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
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

    // 랭크전에서는 결과만 표시하고 자동으로 돌아가기
    if (widget.isRanked) {
      GameSessionHelper.scheduleRankedAutoReturn(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
      );
      return GameRankedResultView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: theme.primary,
        isWinner: isWinner,
        isDraw: _isDraw,
      );
    }

    String resultText;
    Color resultColor;
    IconData resultIcon;

    if (_isDraw) {
      resultText = '무승부!';
      resultColor = CandyColors.tangerine;
      resultIcon = Icons.handshake;
    } else if (isWinner) {
      resultText = '승리!';
      resultColor = _accent;
      resultIcon = Icons.emoji_events;
    } else {
      resultText = '아쉬워요...';
      resultColor = CandyColors.inkSoft;
      resultIcon = Icons.sentiment_dissatisfied;
    }

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
                    ? '세 라운드 내내 팽팽하게 맞붙었어요.'
                    : (isWinner
                          ? '손끝 집중력이 끝까지 이어졌어요.'
                          : '다음 판은 시작 템포를 더 빠르게 가져가봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '${_roundWinsOf(_myPlayerIndex)}',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '${_roundWinsOf(1 - _myPlayerIndex)}',
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
                accentColor: _accent,
                opponentLeft: _opponentLeft,
                rematchWaiting: _rematchWaiting,
                isInvitationGame: _isInvitationGame,
                canSendFriendRequest:
                    !_isInvitationGame &&
                    !_opponentLeft &&
                    _opponentUserId != null &&
                    !context.read<FriendProvider>().isFriend(_opponentUserId!),
                onRematchPressed: _rematchWaiting
                    ? _cancelRematch
                    : _requestRematch,
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

  void _showExitDialog(GameTheme theme) {
    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && _status == SpeedTapGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting =
        widget.isRanked &&
        (_status == SpeedTapGameStatus.idle ||
            _status == SpeedTapGameStatus.searching ||
            _status == SpeedTapGameStatus.matched);

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (_status == SpeedTapGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }

    _isExitDialogOpen = true;
    showGameExitDialog(
      context: context,
      accentColor: _accent,
      message: isRankedWaiting
          ? '랭크전 진행 중입니다.\n나가시겠습니까?'
          : '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
      onExit: _leaveGame,
    ).then((_) => _isExitDialogOpen = false);
  }
}

class _RippleData {
  final int id;
  final Offset pos;
  const _RippleData(this.id, this.pos);
}

/// 화면 전체가 탭 영역. 탭한 위치에 파문(+1)이 퍼지고, 눌린 상태를 [builder] 에 알려준다.
/// 상태 변경은 이 위젯 안에서만 일어나므로 화면 전체가 프레임마다 리빌드되지 않는다.
class _TapZone extends StatefulWidget {
  final BoxDecoration decoration;

  /// 탭이 실제로 처리됐으면 true.
  final bool Function() onTap;
  final Widget Function(bool pressed) builder;

  const _TapZone({
    required this.decoration,
    required this.onTap,
    required this.builder,
  });

  @override
  State<_TapZone> createState() => _TapZoneState();
}

class _TapZoneState extends State<_TapZone> {
  final List<_RippleData> _ripples = [];
  int _seq = 0;
  bool _down = false;

  void _remove(int id) {
    if (!mounted) return;
    setState(() => _ripples.removeWhere((r) => r.id == id));
  }

  void _setDown(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        final accepted = widget.onTap();
        setState(() {
          _down = true;
          if (accepted) {
            _ripples.add(_RippleData(_seq++, d.localPosition));
            if (_ripples.length > 8) _ripples.removeAt(0);
          }
        });
      },
      onTapUp: (_) => _setDown(false),
      onTapCancel: () => _setDown(false),
      child: DecoratedBox(
        decoration: widget.decoration,
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.builder(_down),
              for (final r in _ripples)
                Positioned(
                  left: r.pos.dx - 70,
                  top: r.pos.dy - 70,
                  width: 140,
                  height: 140,
                  child: IgnorePointer(
                    child: _RippleView(
                      key: ValueKey(r.id),
                      onDone: () => _remove(r.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RippleView extends StatelessWidget {
  final VoidCallback onDone;

  const _RippleView({super.key, required this.onDone});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOut,
      onEnd: onDone,
      builder: (_, t, _) {
        final fade = (1 - t).clamp(0.0, 1.0);
        final d = 36 + 100 * t;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: d,
              height: d,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.35 * fade),
                border: Border.all(
                  color: CandyColors.ink.withValues(alpha: fade),
                  width: 3,
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(0, -18 - 30 * t),
              child: Opacity(
                opacity: fade,
                child: const Text(
                  '+1',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    shadows: [
                      Shadow(color: CandyColors.ink, offset: Offset(0, 2)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 라운드 결과의 탭 수 카드. 숫자가 0 에서 카운트업된다.
class _TapCountCard extends StatelessWidget {
  final String label;
  final int count;
  final bool highlight;
  final int delayMs;

  const _TapCountCard({
    required this.label,
    required this.count,
    required this.highlight,
    required this.delayMs,
  });

  @override
  Widget build(BuildContext context) {
    const countMs = 700;
    final total = delayMs + countMs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: total),
      curve: Interval(delayMs / total, 1.0, curve: Curves.easeOutCubic),
      builder: (_, v, _) {
        return Transform.scale(
          scale: 1 + (highlight ? 0.08 : 0.0) * math.sin(v * math.pi / 2),
          child: CartoonCard(
            radius: 24,
            color: highlight ? CandyColors.sun : Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.inkSoft,
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${(count * v).round()}',
                    style: const TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w900,
                      color: CandyColors.ink,
                      height: 1.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
