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

enum RpsGameStatus { idle, searching, matched, playing, finished }

enum RpsChoice { rock, paper, scissors }

class RpsScreen extends StatefulWidget {
  final bool isRanked;

  const RpsScreen({super.key, this.isRanked = false});

  @override
  State<RpsScreen> createState() => _RpsScreenState();
}

class _RpsScreenState extends State<RpsScreen> {
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

  RpsGameStatus _status = RpsGameStatus.idle;

  String? _roomId;
  String? _myId;
  String? _myNickname;
  String? _myAvatarUrl;
  String? _opponentNickname;
  String? _opponentAvatarUrl;
  int? _opponentUserId;
  bool _isInvitationGame = false;
  final bool _isHardcore = false;
  UserProfileSettings? _myProfileSettings;
  UserProfileSettings? _opponentProfileSettings;

  int _currentRound = 0;
  List<int> _scores = [0, 0]; // [player0, player1]
  int _myPlayerIndex = 0;

  // 현재 라운드 상태
  RpsChoice? _myChoice;
  bool _opponentChosen = false;
  bool _waitingForResult = false;

  // 라운드 결과
  String? _lastPlayer0Choice;
  String? _lastPlayer1Choice;
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
        '🎮 RpsScreen _initFromGameProvider: isInvitation=${game.isInvitationGame}, roomId=${game.roomId}, opponentNickname=${game.opponentNickname}, status=${game.status}',
      );
      final isActiveInvitation =
          game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched ||
              game.status == GameStatus.playing);
      if (isActiveInvitation) {
        debugPrint('🎮 RpsScreen: 초대 게임 초기화 from GameProvider');
        _set(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = RpsGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 RpsScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
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

  bool get _isGameActive =>
      _status != RpsGameStatus.idle &&
      _status != RpsGameStatus.searching &&
      _status != RpsGameStatus.finished;

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
              _reset();
            },
          );
        },
      );
    });

    _socketListeners.on('waiting_for_match', (_) {
      _set(() => _status = RpsGameStatus.searching);
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
        _status = RpsGameStatus.matched;
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
      if (data['gameType'] == 'rps') {
        if (data['players'] != null) {
          final players = data['players'] as List;
          final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
          if (updatedIndex != -1) {
            _myPlayerIndex = updatedIndex;
          }
        }
        // finished 상태에서 재경기 요청 안 했으면 무시
        if (_status == RpsGameStatus.finished && !_rematchWaiting) {
          debugPrint('🎮 game_start ignored: not waiting for rematch');
          return;
        }
        // 게임 시작 시 모든 SnackBar 제거 (중복 알림 방지)
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
        }
        _set(() {
          _status = RpsGameStatus.playing;
          _remainingSeconds = 10; // 재경기 시 이전 게임의 남은 시간 잔상 방지
          _currentRound = 0;
          _scores = [0, 0];
          _myChoice = null;
          _opponentChosen = false;
          _waitingForResult = false;
          // 이전 라운드 결과 리셋
          _lastPlayer0Choice = null;
          _lastPlayer1Choice = null;
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

    _socketListeners.on('rps_round_start', (data) {
      final timeLimit = data['timeLimit'] as int? ?? 10000;
      _set(() {
        // rps_round_start가 오면 확실히 게임 중인 상태
        _status = RpsGameStatus.playing;
        _currentRound = data['round'];
        _scores = List<int>.from(data['scores']);
        _myChoice = null;
        _opponentChosen = false;
        _waitingForResult = false;
        _lastPlayer0Choice = null;
        _lastPlayer1Choice = null;
        _lastWinnerIndex = null;
        _lastIsDraw = false;
        _isWaitingForReconnect = false;
      });
      _startCountdown(timeLimit ~/ 1000);
    });

    _socketListeners.on('rps_player_chosen', (data) {
      if (data['playerId'] != _myId) {
        _set(() => _opponentChosen = true);
      }
    });

    _socketListeners.on('rps_round_result', (data) {
      _stopCountdown();
      _set(() {
        _lastPlayer0Choice = data['player0Choice'];
        _lastPlayer1Choice = data['player1Choice'];
        _lastWinnerIndex = data['winnerIndex'];
        _lastIsDraw = data['isDraw'] ?? false;
        _scores = List<int>.from(data['scores']);
        _waitingForResult = false;
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('rps_round_timeout', (data) {
      _stopCountdown();
      _set(() {
        _waitingForResult = false;
      });
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'rps') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      _set(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex =
            (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _currentRound = (data['round'] as num?)?.toInt() ?? _currentRound;
        if (data['scores'] != null) {
          _scores = List<int>.from(data['scores']);
        }
        _status = RpsGameStatus.playing;
        _myChoice = switch (data['myChoice']) {
          'rock' => RpsChoice.rock,
          'paper' => RpsChoice.paper,
          'scissors' => RpsChoice.scissors,
          _ => null,
        };
        _opponentChosen = data['opponentChosen'] == true;
        _waitingForResult = _myChoice != null && _opponentChosen;
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
          _reset();
        },
        message: '20초 안에 연결을 복구하지 못해 게임에서 제외되었습니다.',
      );
    });

    _socketListeners.on('opponent_disconnected', (_) {
      if (!_isGameActive) return;
      _stopCountdown();
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
      if (_status == RpsGameStatus.finished) return;
      _stopCountdown();
      _set(() {
        _status = RpsGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        if (data['scores'] != null) {
          _scores = List<int>.from(data['scores']);
        }
      });
      _waitingReconnectTimer?.cancel();
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == RpsGameStatus.idle || _status == RpsGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == RpsGameStatus.finished) {
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
        _status = RpsGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      _waitingReconnectTimer?.cancel();
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
      'gameType': AppConfig.gameTypeRps,
      'isHardcore': _isHardcore,
    });
    _set(() => _status = RpsGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeRps,
      'isHardcore': _isHardcore,
    });
    _set(() => _status = RpsGameStatus.idle);
  }

  void _makeChoice(RpsChoice choice) {
    if (_myChoice != null || _roomId == null) return;

    _set(() {
      _myChoice = choice;
      _waitingForResult = _opponentChosen;
    });

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'choice': choice.name},
    });
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
      _status = RpsGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentUserId = null;
      _currentRound = 0;
      _scores = [0, 0];
      _myChoice = null;
      _opponentChosen = false;
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
              title: '가위바위보',
              backgroundColor: theme.primary,
              onBack: () => _showExitDialog(theme),
            ),
            body: Stack(
              children: [
                GameScreenTransition(
                  transitionKey:
                      '${_status.name}-$_currentRound-${_myChoice?.name ?? 'none'}-${_lastWinnerIndex ?? -1}-$_lastIsDraw',
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
      icon: Icons.front_hand,
      title: '가위바위보 준비 중',
      subtitle: '매치 정보를 정리한 뒤 바로 시작합니다.',
      statusMessages: const [
        '상대의 입장 상태를 확인하고 있습니다.',
        '첫 라운드 선택 창을 준비하고 있습니다.',
        '점수판과 규칙을 불러오고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      RpsGameStatus.idle =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildIdleView(theme),
      RpsGameStatus.searching =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildSearchingView(theme),
      RpsGameStatus.matched =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildMatchedView(theme),
      RpsGameStatus.playing => _buildPlayingView(theme),
      RpsGameStatus.finished => _buildFinishedView(theme),
    };
  }

  void _showFriendInviteDialog(BuildContext context) {
    showGameInviteSheet(
      context: context,
      accent: _accent,
      gameType: AppConfig.gameTypeRps,
      refresh: true, // 친구 목록 새로고침
    );
  }

  Widget _buildIdleView(GameTheme theme) {
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: _accent,
      emoji: '✌️',
      title: '가위바위보',
      descriptions: const ['3판 2선승'],
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
    final bool showResult =
        _lastPlayer0Choice != null && _lastPlayer1Choice != null;

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Column(
        children: [
          // 프로필 & 점수판
          GameDuelHeader(
            backgroundColors: [
              theme.cardGradient.colors.first,
              theme.cardGradient.colors.last,
            ],
            accentColor: _accent,
            centerLabel: 'R$_currentRound',
            centerSubtitle: '3판 2선승',
            myName: _myNickname ?? '나',
            opponentName: _opponentNickname ?? '상대',
            myAvatarUrl: _myAvatarUrl,
            opponentAvatarUrl: _opponentAvatarUrl,
            myActive: true,
            opponentActive: false,
            myProfileSettings: _myProfileSettings,
            opponentProfileSettings: _opponentProfileSettings,
            myExtraWidget: _buildScoreWidget(_scoreOf(_myPlayerIndex), true),
            opponentExtraWidget: _buildScoreWidget(
              _scoreOf(1 - _myPlayerIndex),
              false,
            ),
          ),

          // 게임 영역
          Expanded(
            child: _currentRound == 0
                ? _buildWaitingForRoundView()
                : (showResult ? _buildResultView() : _buildChoiceView()),
          ),
        ],
      ),
    );
  }

  /// 점수 배열 범위 밖 접근 방지.
  int _scoreOf(int index) =>
      (index >= 0 && index < _scores.length) ? _scores[index] : 0;

  Widget _buildScoreWidget(int score, bool isMe) {
    return GameHeaderScorePill(
      score: score,
      color: isMe ? _accent : CandyColors.inkSoft,
    );
  }

  Widget _buildWaitingForRoundView() {
    return Center(
      child: GameStagePanel(
        icon: Icons.back_hand_rounded,
        title: '준비 중...',
        subtitle: '첫 선택 창을 열고 상대 상태를 맞추고 있습니다.',
        accentColor: _accent,
        content: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(color: _accent, strokeWidth: 3),
        ),
      ),
    );
  }

  Widget _buildChoiceView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 타이머
                  GameTimerBadge(
                    seconds: _remainingSeconds,
                    label: '선택 남은 시간',
                    accentColor: _accent,
                  ),
                  const SizedBox(height: 18),

                  // 상대 상태
                  _buildOpponentStatusPill(),
                  const SizedBox(height: 24),

                  // 내 선택 상태 또는 선택 버튼
                  if (_myChoice != null)
                    _buildMyChoiceShown(_myChoice!)
                  else
                    Column(
                      children: [
                        const Text(
                          '선택하세요!',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            color: CandyColors.ink,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: LayoutBuilder(
                            builder: (context, c) {
                              final size = math.max(
                                64.0,
                                math.min(108.0, (c.maxWidth - 24) / 3),
                              );
                              return Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  _RpsHandButton(
                                    emoji: _getChoiceEmoji(RpsChoice.rock),
                                    label: _getChoiceName(RpsChoice.rock),
                                    color: CandyColors.sky,
                                    size: size,
                                    bounceMs: 900,
                                    onTap: () => _makeChoice(RpsChoice.rock),
                                  ),
                                  _RpsHandButton(
                                    emoji: _getChoiceEmoji(RpsChoice.scissors),
                                    label: _getChoiceName(RpsChoice.scissors),
                                    color: CandyColors.sun,
                                    size: size,
                                    bounceMs: 760,
                                    onTap: () =>
                                        _makeChoice(RpsChoice.scissors),
                                  ),
                                  _RpsHandButton(
                                    emoji: _getChoiceEmoji(RpsChoice.paper),
                                    label: _getChoiceName(RpsChoice.paper),
                                    color: CandyColors.mint,
                                    size: size,
                                    bounceMs: 1040,
                                    onTap: () => _makeChoice(RpsChoice.paper),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOpponentStatusPill() {
    final chosen = _opponentChosen;
    final name = _opponentNickname ?? '상대';
    return TweenAnimationBuilder<double>(
      key: ValueKey(chosen),
      tween: Tween(begin: chosen ? 0.75 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 450),
      curve: Curves.elasticOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: chosen ? CandyColors.mint : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: CandyColors.ink, width: 2.5),
          boxShadow: const [
            BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              chosen
                  ? Icons.check_circle_rounded
                  : Icons.hourglass_empty_rounded,
              color: chosen ? CandyColors.ink : CandyColors.inkSoft,
              size: 20,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                chosen ? '$name 선택 완료!' : '$name 선택 중...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: chosen ? CandyColors.ink : CandyColors.inkSoft,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMyChoiceShown(RpsChoice choice) {
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          key: ValueKey(choice),
          tween: Tween(begin: 0.3, end: 1.0),
          duration: const Duration(milliseconds: 600),
          curve: Curves.elasticOut,
          builder: (_, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Container(
            width: 148,
            height: 148,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: CandyColors.ink, width: 3),
              boxShadow: const [
                BoxShadow(color: CandyColors.ink, offset: Offset(0, 6)),
              ],
            ),
            child: Text(
              _getChoiceEmoji(choice),
              style: const TextStyle(fontSize: 76),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          '${_getChoiceName(choice)} 선택!',
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w900,
            color: CandyColors.ink,
          ),
        ),
        if (_waitingForResult || !_opponentChosen) ...[
          const SizedBox(height: 12),
          const Text(
            '상대방 대기 중...',
            style: TextStyle(
              color: CandyColors.inkSoft,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildResultView() {
    final myChoice = _myPlayerIndex == 0
        ? _lastPlayer0Choice
        : _lastPlayer1Choice;
    final opponentChoice = _myPlayerIndex == 0
        ? _lastPlayer1Choice
        : _lastPlayer0Choice;
    final isMyWin = _lastWinnerIndex == _myPlayerIndex;
    final isOpponentWin = _lastWinnerIndex == (1 - _myPlayerIndex);
    final stateColor = _lastIsDraw
        ? CandyColors.sunDeep
        : (isMyWin ? CandyColors.mintDeep : CandyColors.pinkDeep);

    return LayoutBuilder(
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
                              ? Icons.emoji_events_rounded
                              : Icons.sentiment_dissatisfied_rounded),
                    title: _lastIsDraw ? '무승부!' : (isMyWin ? '이겼다!' : '졌다...'),
                    subtitle: '선택을 모두 확인했고, 다음 라운드를 준비하고 있어요.',
                    accentColor: stateColor,
                    compact: true,
                  ),
                  const SizedBox(height: 24),

                  // 선택 비교 (카드가 뒤집히며 공개)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: _RpsRevealCard(
                            emoji: _getChoiceEmojiFromString(myChoice),
                            label: '나',
                            isWinner: isMyWin && !_lastIsDraw,
                            isDraw: _lastIsDraw,
                            delayMs: 150,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 44, left: 8, right: 8),
                          child: Text(
                            'VS',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: CandyColors.inkSoft,
                            ),
                          ),
                        ),
                        Flexible(
                          child: _RpsRevealCard(
                            emoji: _getChoiceEmojiFromString(opponentChoice),
                            label: _opponentNickname ?? '상대',
                            isWinner: isOpponentWin && !_lastIsDraw,
                            isDraw: _lastIsDraw,
                            delayMs: 450,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
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
    );
  }

  String _getChoiceEmoji(RpsChoice choice) {
    return switch (choice) {
      RpsChoice.rock => '✊',
      RpsChoice.scissors => '✌️',
      RpsChoice.paper => '✋',
    };
  }

  String _getChoiceEmojiFromString(String? choice) {
    return switch (choice) {
      'rock' => '✊',
      'scissors' => '✌️',
      'paper' => '✋',
      _ => '❓',
    };
  }

  String _getChoiceName(RpsChoice choice) {
    return switch (choice) {
      RpsChoice.rock => '바위',
      RpsChoice.scissors => '가위',
      RpsChoice.paper => '보',
    };
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
                    ? '끝까지 쉽게 예측할 수 없는 승부였어요.'
                    : (isWinner
                          ? '이번 판은 선택 타이밍이 좋았어요.'
                          : '상대의 흐름을 읽어 다음 판을 노려봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '${_scoreOf(_myPlayerIndex)}',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '${_scoreOf(1 - _myPlayerIndex)}',
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
    // 결과 화면에서는 패배 처리 경고 없이 바로 나가기
    if (_status == RpsGameStatus.finished) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && _status == RpsGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting =
        widget.isRanked &&
        (_status == RpsGameStatus.idle ||
            _status == RpsGameStatus.searching ||
            _status == RpsGameStatus.matched);

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (_status == RpsGameStatus.searching) {
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

/// 가위/바위/보 선택 버튼. 평소엔 통통 떠 있고, 누르면 눌리며 햅틱이 울린다.
class _RpsHandButton extends StatefulWidget {
  final String emoji;
  final String label;
  final Color color;
  final double size;
  final int bounceMs;
  final VoidCallback onTap;

  const _RpsHandButton({
    required this.emoji,
    required this.label,
    required this.color,
    required this.size,
    required this.bounceMs,
    required this.onTap,
  });

  @override
  State<_RpsHandButton> createState() => _RpsHandButtonState();
}

class _RpsHandButtonState extends State<_RpsHandButton> {
  bool _down = false;

  void _setDown(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final tint = Color.alphaBlend(
      widget.color.withValues(alpha: 0.45),
      Colors.white,
    );
    return CandyPulse(
      duration: Duration(milliseconds: widget.bounceMs),
      builder: (_, t, child) =>
          Transform.translate(offset: Offset(0, -6 * t), child: child),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setDown(true),
        onTapCancel: () => _setDown(false),
        onTapUp: (_) => _setDown(false),
        onTap: () {
          HapticFeedback.mediumImpact();
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _down ? 0.88 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: widget.size,
                height: widget.size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tint,
                  shape: BoxShape.circle,
                  border: Border.all(color: CandyColors.ink, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: CandyColors.ink,
                      offset: Offset(0, _down ? 1 : 5),
                    ),
                  ],
                ),
                child: Text(
                  widget.emoji,
                  style: TextStyle(fontSize: widget.size * 0.46),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: CandyColors.ink, width: 2),
                ),
                child: Text(
                  widget.label,
                  maxLines: 1,
                  style: const TextStyle(
                    color: CandyColors.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
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

/// 라운드 결과 공개 카드. 물음표 카드가 3D 로 뒤집히며 손 모양이 나타난다.
class _RpsRevealCard extends StatefulWidget {
  final String emoji;
  final String label;
  final bool isWinner;
  final bool isDraw;
  final int delayMs;

  const _RpsRevealCard({
    required this.emoji,
    required this.label,
    required this.isWinner,
    required this.isDraw,
    required this.delayMs,
  });

  @override
  State<_RpsRevealCard> createState() => _RpsRevealCardState();
}

class _RpsRevealCardState extends State<_RpsRevealCard>
    with SingleTickerProviderStateMixin {
  static const int _flipMs = 650;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.delayMs + _flipMs),
  );
  late final Animation<double> _flip = CurvedAnimation(
    parent: _c,
    curve: Interval(
      widget.delayMs / (widget.delayMs + _flipMs),
      1.0,
      curve: Curves.easeOutBack,
    ),
  );

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        HapticFeedback.lightImpact();
      }
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color chipColor = widget.isDraw
        ? CandyColors.sun
        : (widget.isWinner ? CandyColors.mint : CandyColors.pink);
    final Color faceColor = widget.isWinner ? CandyColors.sun : Colors.white;

    final back = Container(
      decoration: BoxDecoration(
        color: CandyColors.grape,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: CandyColors.ink, width: 3),
        boxShadow: const [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, 5)),
        ],
      ),
      alignment: Alignment.center,
      child: const FittedBox(
        child: Padding(
          padding: EdgeInsets.all(26),
          child: Text(
            '?',
            style: TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );

    final front = Container(
      decoration: BoxDecoration(
        color: faceColor,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: CandyColors.ink, width: 3),
        boxShadow: const [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, 5)),
        ],
      ),
      alignment: Alignment.center,
      child: FittedBox(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Text(widget.emoji, style: const TextStyle(fontSize: 60)),
        ),
      ),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 132),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _flip,
                builder: (context, _) {
                  final v = _flip.value;
                  final angle = v * math.pi;
                  final showFront = angle > math.pi / 2;
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0012)
                      ..rotateY(angle),
                    child: showFront
                        ? Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.rotationY(math.pi),
                            child: front,
                          )
                        : back,
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          AnimatedBuilder(
            animation: _flip,
            builder: (context, child) {
              final o = ((_flip.value - 0.6) / 0.4).clamp(0.0, 1.0);
              return Opacity(opacity: o, child: child);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: chipColor,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: CandyColors.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
