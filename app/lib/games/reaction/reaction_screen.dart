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
import '../common/game_waiting_view.dart';
import '../common/match_status_views.dart';
import '../tictactoe/tictactoe_screen.dart'
    show CandyPulse, showGameInviteSheet;

enum ReactionGameStatus { idle, searching, matched, playing, finished }

enum RoundState {
  waiting, // 라운드 대기
  ready, // 빨간불 (누르면 안됨)
  go, // 초록불 (빨리 눌러!)
  result, // 결과 표시
}

class ReactionScreen extends StatefulWidget {
  final bool isRanked;

  const ReactionScreen({super.key, this.isRanked = false});

  @override
  State<ReactionScreen> createState() => _ReactionScreenState();
}

class _ReactionScreenState extends State<ReactionScreen> {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );
  bool _hasScheduledPop = false; // 중복 pop 방지
  bool _isExitDialogOpen = false; // 나가기 다이얼로그 열림 상태

  ReactionGameStatus _status = ReactionGameStatus.idle;
  RoundState _roundState = RoundState.waiting;

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

  // 라운드 결과
  bool? _lastRoundFalseStart;
  String? _lastRoundWinnerNickname;
  int? _lastReactionTime;
  String? _pressedPlayerNickname;

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
        '🎮 ReactionScreen _initFromGameProvider: isInvitation=${game.isInvitationGame}, roomId=${game.roomId}, opponentNickname=${game.opponentNickname}, status=${game.status}',
      );
      final isActiveInvitation =
          game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched ||
              game.status == GameStatus.playing);
      if (isActiveInvitation) {
        debugPrint('🎮 ReactionScreen: 초대 게임 초기화 from GameProvider');
        _set(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = ReactionGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 ReactionScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _socketListeners.offAll();
    super.dispose();
  }

  /// 소켓 콜백 등 비동기 경로에서 안전하게 쓰는 setState (dispose 이후 호출 방지).
  void _set(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  bool get _isGameActive =>
      _status != ReactionGameStatus.idle &&
      _status != ReactionGameStatus.searching &&
      _status != ReactionGameStatus.finished;

  void _startReconnectFlow() {
    if (!_isGameActive || _roomId == null) return;
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
      context: context,
      showFailureSnackBar: false,
      onEnterWaiting: () {
        if (!mounted) return;
        _set(() {
          _isReconnecting = true;
          _isWaitingForReconnect = false;
          _reconnectSecondsRemaining =
              GameReconnectHelper.reconnectGraceDuration.inSeconds;
        });
      },
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
          beforeNavigate: _reset,
        );
      },
    );
  }

  void _showReconnectOverlay({required bool reconnecting}) {
    if (reconnecting) {
      _waitingReconnectTimer?.cancel();
    }
    if (!mounted) return;
    _set(() {
      _reconnectSecondsRemaining =
          GameReconnectHelper.reconnectGraceDuration.inSeconds;
      _isReconnecting = reconnecting;
      _isWaitingForReconnect = !reconnecting;
    });
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
    debugPrint('🎮 [ReactionScreen] Setting up socket listeners, myId=$_myId');

    _socketListeners.on('connect', (_) {
      _myId = _socketService.socket?.id;
      _startReconnectFlow();
    });

    _socketListeners.on('waiting_for_match', (_) {
      debugPrint('🎮 [ReactionScreen] waiting_for_match received');
      _set(() => _status = ReactionGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      debugPrint('🎮 [ReactionScreen] match_found received: $data');
      debugPrint('🎮 [ReactionScreen] Current _myId=$_myId');
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
      debugPrint('🎮 [ReactionScreen] myPlayerIndex=$_myPlayerIndex, me=$me');

      _set(() {
        _status = ReactionGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        // 프로필 설정
        if (me != null && me['profileSettings'] != null) {
          _myProfileSettings = UserProfileSettings.fromJson(
            me['profileSettings'],
          );
        }
        if (opponent['profileSettings'] != null) {
          _opponentProfileSettings = UserProfileSettings.fromJson(
            opponent['profileSettings'],
          );
        }
      });
      debugPrint('🎮 [ReactionScreen] Status changed to matched');
    });

    _socketListeners.on('game_start', (data) {
      debugPrint('🎮 [ReactionScreen] game_start received: $data');
      debugPrint(
        '🎮 [ReactionScreen] Current status=$_status, rematchWaiting=$_rematchWaiting',
      );
      if (data['gameType'] == 'reaction') {
        if (data['players'] != null) {
          final players = data['players'] as List;
          final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
          if (updatedIndex != -1) {
            _myPlayerIndex = updatedIndex;
          }
        }
        // finished 상태에서 재경기 요청 안 했으면 무시
        if (_status == ReactionGameStatus.finished && !_rematchWaiting) {
          debugPrint(
            '🎮 [ReactionScreen] ❌ game_start ignored: not waiting for rematch',
          );
          return;
        }
        // 게임 시작 시 모든 SnackBar 제거 (중복 알림 방지)
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
        }
        debugPrint('🎮 [ReactionScreen] ✅ Processing game_start for reaction');
        _set(() {
          _status = ReactionGameStatus.playing;
          _currentRound = 0;
          _scores = [0, 0];
          _roundState = RoundState.waiting;
          // 이전 라운드 결과 리셋
          _lastRoundFalseStart = null;
          _lastRoundWinnerNickname = null;
          _lastReactionTime = null;
          _pressedPlayerNickname = null;
          // 재경기 상태 리셋
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
        });
        debugPrint('🎮 [ReactionScreen] Status changed to playing');
      } else {
        debugPrint(
          '🎮 [ReactionScreen] game_start ignored: gameType is ${data['gameType']}, not reaction',
        );
      }
    });

    _socketListeners.on('reaction_round_ready', (data) {
      _set(() {
        _currentRound = data['round'];
        _scores = List<int>.from(data['scores']);
        _roundState = RoundState.ready;
        _lastRoundFalseStart = null;
        _lastRoundWinnerNickname = null;
        _lastReactionTime = null;
        _pressedPlayerNickname = null;
      });
    });

    _socketListeners.on('reaction_round_go', (data) {
      HapticFeedback.mediumImpact();
      _set(() {
        _roundState = RoundState.go;
      });
    });

    _socketListeners.on('reaction_round_result', (data) {
      // 내가 부정출발이면 묵직한 진동
      if (data['falseStart'] == true &&
          data['pressedPlayerNickname'] != _opponentNickname) {
        HapticFeedback.heavyImpact();
      }
      _set(() {
        _roundState = RoundState.result;
        _lastRoundFalseStart = data['falseStart'];
        _lastRoundWinnerNickname = data['winnerNickname'];
        _lastReactionTime = data['reactionTime'];
        _pressedPlayerNickname = data['pressedPlayerNickname'];
        _scores = List<int>.from(data['scores']);
      });
    });

    _socketListeners.on('reaction_round_timeout', (data) {
      _set(() {
        _roundState = RoundState.result;
        _lastRoundFalseStart = false;
        _lastRoundWinnerNickname = null; // 무승부
        _lastReactionTime = null;
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'reaction') return;
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
        final roundState = data['roundState'] as String?;
        _roundState = switch (roundState) {
          'ready' => RoundState.ready,
          'go' => RoundState.go,
          'finished' => RoundState.result,
          _ => RoundState.waiting,
        };
        _status = ReactionGameStatus.playing;
      });
      GameReconnectHelper.completeReconnect(
        context: context,
        onRecovered: () => _set(() {
          _isReconnecting = false;
          _isWaitingForReconnect = false;
          _reconnectSecondsRemaining =
              GameReconnectHelper.reconnectGraceDuration.inSeconds;
        }),
      );
    });

    _socketListeners.on('reconnect_failed', (_) {
      _reconnectTimer?.cancel();
      GameSessionHelper.handleReconnectTimeout(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
        beforeNavigate: _reset,
        message: '20초 안에 연결을 복구하지 못해 게임에서 제외되었습니다.',
      );
    });

    _socketListeners.on('opponent_disconnected', (data) {
      if (!_isGameActive) return;
      _showReconnectOverlay(reconnecting: false);
      _startWaitingReconnectCountdown();
    });

    _socketListeners.on('opponent_reconnected', (_) {
      if (!_isGameActive) return;
      _waitingReconnectTimer?.cancel();
      _set(() => _isWaitingForReconnect = false);
      GameReconnectHelper.showOpponentReconnected(context);
    });

    _socketListeners.on('game_end', (data) {
      if (_status == ReactionGameStatus.finished) return;
      _set(() {
        _status = ReactionGameStatus.finished;
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
      if (_status == ReactionGameStatus.idle ||
          _status == ReactionGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == ReactionGameStatus.finished) {
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
        _status = ReactionGameStatus.finished;
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
      'gameType': AppConfig.gameTypeReaction,
      'isHardcore': _isHardcore,
    });
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeReaction,
      'isHardcore': _isHardcore,
    });
    _set(() => _status = ReactionGameStatus.idle);
  }

  void _pressButton() {
    if (_roundState != RoundState.ready && _roundState != RoundState.go) return;
    if (_roomId == null) return;
    HapticFeedback.lightImpact();

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'press'},
    });
  }

  void _requestRematch() {
    _socketService.emit('rematch_request', {'roomId': _roomId});
  }

  void _cancelRematch() {
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
      _status = ReactionGameStatus.idle;
      _roundState = RoundState.waiting;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _currentRound = 0;
      _scores = [0, 0];
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
    final shop = context.watch<ShopProvider>();
    final theme = GameTheme.fromProfileSettings(shop.profileSettings);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitDialog();
      },
      child: Scaffold(
        appBar: gameAppBar(
          title: '반응속도',
          backgroundColor: theme.primary,
          onBack: _showExitDialog,
        ),
        body: Stack(
          children: [
            GameScreenTransition(
              transitionKey:
                  '${_status.name}-${_roundState.name}-$_currentRound-${_lastReactionTime ?? -1}-${_lastRoundFalseStart ?? false}',
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
  }

  Widget _buildRankedWaitingView(GameTheme theme) {
    return GameWaitingView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: theme.primary,
      icon: Icons.flash_on,
      title: '반응속도 준비 중',
      subtitle: '상대와 게임 상태를 맞추고 있습니다.',
      statusMessages: const [
        '매칭 정보를 확인하고 있습니다.',
        '라운드 순서를 동기화하고 있습니다.',
        '시작 신호를 준비하고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      ReactionGameStatus.idle =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildIdleView(theme),
      ReactionGameStatus.searching =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildSearchingView(theme),
      ReactionGameStatus.matched =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildMatchedView(theme),
      ReactionGameStatus.playing => _buildPlayingView(theme),
      ReactionGameStatus.finished => _buildFinishedView(theme),
    };
  }

  void _showFriendInviteDialog(BuildContext context) {
    final theme = GameTheme.fromProfileSettings(
      context.read<ShopProvider>().profileSettings,
    );
    showGameInviteSheet(
      context: context,
      accent: theme.primary,
      gameType: AppConfig.gameTypeReaction,
      refresh: true, // 친구 목록 새로고침
    );
  }

  Widget _buildIdleView(GameTheme theme) {
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: theme.primary,
      icon: Icons.flash_on,
      title: '반응속도',
      descriptions: const ['초록불이 켜지면 빨리 터치!', '5라운드 중 먼저 3점!'],
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

  int _scoreOf(int index) =>
      (index >= 0 && index < _scores.length) ? _scores[index] : 0;

  Widget _buildPlayingView(GameTheme theme) {
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
            accentColor: theme.primary,
            centerLabel: 'R$_currentRound/5',
            centerSubtitle: '반응속도',
            myName: _myNickname ?? '나',
            opponentName: _opponentNickname ?? '상대',
            myAvatarUrl: _myAvatarUrl,
            opponentAvatarUrl: _opponentAvatarUrl,
            myActive: true,
            opponentActive: true,
            myProfileSettings:
                _myProfileSettings ??
                context.read<ShopProvider>().profileSettings,
            opponentProfileSettings: _opponentProfileSettings,
            myExtraWidget: _buildScoreWidget(_scoreOf(_myPlayerIndex), true),
            opponentExtraWidget: _buildScoreWidget(
              _scoreOf(1 - _myPlayerIndex),
              false,
            ),
          ),

          // 게임 영역: 큰 카툰 패드 전체가 터치 영역
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _pressButton,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  width: double.infinity,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: _padColor(),
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: CandyColors.ink, width: 3),
                    boxShadow: const [
                      BoxShadow(color: CandyColors.ink, offset: Offset(0, 6)),
                    ],
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GameScreenTransition(
                        transitionKey:
                            '${_roundState.name}-${_lastReactionTime ?? -1}-${_lastRoundFalseStart ?? false}-${_lastRoundWinnerNickname ?? 'none'}',
                        beginOffset: const Offset(0, 0.02),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: _buildRoundContent(),
                            ),
                          ),
                        ),
                      ),
                      // GO! 순간 번쩍이는 플래시
                      if (_roundState == RoundState.go)
                        IgnorePointer(
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey('flash-$_currentRound'),
                            tween: Tween(begin: 0.85, end: 0.0),
                            duration: const Duration(milliseconds: 380),
                            curve: Curves.easeOut,
                            builder: (_, v, _) => ColoredBox(
                              color: Colors.white.withValues(alpha: v),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreWidget(int score, bool isMe) {
    return GameHeaderScorePill(
      score: score,
      color: isMe ? CandyColors.pink : CandyColors.sky,
      margin: const EdgeInsets.only(top: 4),
    );
  }

  Color _padColor() {
    return switch (_roundState) {
      RoundState.waiting => const Color(0xFFEDE7FF),
      RoundState.ready => CandyColors.pink,
      RoundState.go => CandyColors.mint,
      RoundState.result => Colors.white,
    };
  }

  /// 상태 메시지(원형 아이콘 칩 + 제목 + 보조문구) 공통 레이아웃.
  Widget _stateMessage({
    required IconData icon,
    required String title,
    String? subtitle,
    required Color fg,
    Color? chipIconColor,
    bool onColor = false,
    double titleSize = 34,
    Widget? badge,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.55, end: 1.0),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (badge != null) ...[badge, const SizedBox(height: 12)],
          Container(
            width: 116,
            height: 116,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(color: CandyColors.ink, width: 3),
              boxShadow: const [
                BoxShadow(color: CandyColors.ink, offset: Offset(0, 5)),
              ],
            ),
            child: Icon(icon, size: 58, color: chipIconColor ?? fg),
          ),
          const SizedBox(height: 22),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: titleSize,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
              color: fg,
              shadows: onColor
                  ? const [Shadow(color: CandyColors.ink, offset: Offset(0, 3))]
                  : null,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: onColor ? Colors.white : CandyColors.inkSoft,
                shadows: onColor
                    ? const [
                        Shadow(color: CandyColors.ink, offset: Offset(0, 2)),
                      ]
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRoundContent() {
    return switch (_roundState) {
      RoundState.waiting => _stateMessage(
        icon: Icons.hourglass_bottom_rounded,
        title: '준비...',
        fg: CandyColors.inkSoft,
        chipIconColor: CandyColors.grape,
        titleSize: 30,
      ),
      RoundState.ready => CandyPulse(
        duration: const Duration(milliseconds: 520),
        builder: (_, t, child) =>
            Transform.rotate(angle: (t - 0.5) * 0.08, child: child),
        child: _stateMessage(
          icon: Icons.pan_tool_rounded,
          title: '기다려!',
          subtitle: '초록불이 켜지면 터치',
          fg: Colors.white,
          chipIconColor: CandyColors.pinkDeep,
          onColor: true,
          titleSize: 38,
        ),
      ),
      RoundState.go => _stateMessage(
        icon: Icons.touch_app_rounded,
        title: '터치!',
        fg: Colors.white,
        chipIconColor: CandyColors.mintDeep,
        onColor: true,
        titleSize: 56,
        badge: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          decoration: BoxDecoration(
            color: CandyColors.sun,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: CandyColors.ink, width: 3),
            boxShadow: const [
              BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
            ],
          ),
          child: const Text(
            'GO!',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
        ),
      ),
      RoundState.result => _buildResultContent(),
    };
  }

  Widget _buildResultContent() {
    if (_lastRoundFalseStart == true) {
      final isMeFalseStart = _pressedPlayerNickname != _opponentNickname;
      final c = isMeFalseStart ? CandyColors.pinkDeep : CandyColors.mintDeep;
      final message = _stateMessage(
        icon: Icons.warning_amber_rounded,
        title: isMeFalseStart ? '부정출발!' : '상대 부정출발!',
        subtitle: isMeFalseStart ? '상대방 +1점' : '나 +1점',
        fg: c,
        titleSize: 30,
      );
      // 내가 부정출발하면 화면이 좌우로 부르르 흔들린다.
      if (!isMeFalseStart) return message;
      return TweenAnimationBuilder<double>(
        key: ValueKey('shake-$_currentRound'),
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 550),
        builder: (_, t, child) => Transform.translate(
          offset: Offset(math.sin(t * math.pi * 7) * 14 * (1 - t), 0),
          child: child,
        ),
        child: message,
      );
    }

    if (_lastReactionTime != null) {
      final isMyWin = _lastRoundWinnerNickname != _opponentNickname;
      final c = isMyWin ? CandyColors.sunDeep : CandyColors.inkSoft;
      final ms = _lastReactionTime!;
      return Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _stateMessage(
            icon: isMyWin
                ? Icons.emoji_events_rounded
                : Icons.sentiment_dissatisfied_rounded,
            title: isMyWin ? '승리!' : '아쉬워요',
            fg: c,
            titleSize: 30,
          ),
          const SizedBox(height: 20),
          // 반응속도 히어로 표시 (숫자가 카운트업)
          CartoonCard(
            radius: 20,
            color: CandyColors.sun.withValues(alpha: 0.35),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(
                  Icons.bolt_rounded,
                  size: 26,
                  color: CandyColors.tangerine,
                ),
                const SizedBox(width: 6),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: ms.toDouble()),
                  duration: const Duration(milliseconds: 550),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, _) => Text(
                    '${v.round()}',
                    style: const TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      color: CandyColors.ink,
                      letterSpacing: -1,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'ms',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return _stateMessage(
      icon: Icons.timer_off_rounded,
      title: '시간 초과',
      fg: CandyColors.inkSoft,
      chipIconColor: CandyColors.grape,
      titleSize: 30,
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
      resultColor = theme.primary;
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
                    ? '끝까지 팽팽한 승부였어요.'
                    : (isWinner
                          ? '좋은 흐름으로 라운드를 가져갔어요.'
                          : '다음 판에서 바로 뒤집을 수 있어요.'),
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
                accentColor: theme.primary,
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

  void _showExitDialog() {
    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && _status == ReactionGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting =
        widget.isRanked &&
        (_status == ReactionGameStatus.idle ||
            _status == ReactionGameStatus.searching ||
            _status == ReactionGameStatus.matched);

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (_status == ReactionGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }

    _isExitDialogOpen = true;
    showGameExitDialog(
      context: context,
      accentColor: GameTheme.fromProfileSettings(
        context.read<ShopProvider>().profileSettings,
      ).primary,
      message: isRankedWaiting
          ? '랭크전 진행 중입니다.\n나가시겠습니까?'
          : '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
      onExit: _leaveGame,
    ).then((_) => _isExitDialogOpen = false);
  }
}
