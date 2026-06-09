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

enum TimingGameStatus {
  idle,
  searching,
  matched,
  playing,
  finished,
}

enum TimingRoundPhase {
  idle,
  playing,
  result,
}

class TimingScreen extends StatefulWidget {
  final bool isRanked;

  const TimingScreen({super.key, this.isRanked = false});

  @override
  State<TimingScreen> createState() => _TimingScreenState();
}

class _TimingScreenState extends State<TimingScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners =
      SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;
  bool _isExitDialogOpen = false;

  TimingGameStatus _status = TimingGameStatus.idle;

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

  // 게임 상태
  int _currentRound = 0;
  List<int> _totalScores = [0, 0];
  // ignore: unused_field
  int _currentSpeed = 2000; // 서버 게이지 속도(향후 사용 대비 보관)
  bool _hasStopped = false;
  bool _opponentStopped = false;
  double? _stoppedPosition;
  TimingRoundPhase _roundPhase = TimingRoundPhase.idle;
  List<int> _lastRoundScores = [0, 0];
  List<double> _lastPositions = [0.5, 0.5];

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

  // 애니메이션
  late AnimationController _gaugeController;

  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accentColor =>
      GameTheme.fromProfileSettings(context.read<ShopProvider>().profileSettings).primary;
  static const _maxRounds = 5;

  @override
  void initState() {
    super.initState();
    _gaugeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
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
          _status = TimingGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('TimingScreen: GameProvider init failed: $e');
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _socketListeners.offAll();
    _gaugeController.dispose();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != TimingGameStatus.idle &&
      _status != TimingGameStatus.searching &&
      _status != TimingGameStatus.finished;

  int get _myScore => _totalScores[_myPlayerIndex];
  int get _opponentScore => _totalScores[1 - _myPlayerIndex];

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
            beforeNavigate: _reset,
          );
        },
      );
    });

    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = TimingGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players
          .cast<Map<String, dynamic>?>()
          .firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me =
          players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      final foundIndex = players.indexWhere((p) => p['id'] == _myId);
      if (foundIndex != -1) _myPlayerIndex = foundIndex;

      setState(() {
        _status = TimingGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        if (opponent['profileSettings'] != null) {
          _opponentProfileSettings =
              UserProfileSettings.fromJson(opponent['profileSettings']);
        }
        if (me != null && me['profileSettings'] != null) {
          _myProfileSettings =
              UserProfileSettings.fromJson(me['profileSettings']);
        }
      });
    });

    _socketListeners.on('game_start', (data) {
      if (data['gameType'] != 'timing') return;
      if (data['players'] != null) {
        final players = data['players'] as List;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) {
          _myPlayerIndex = updatedIndex;
        }
      }
      if (_status == TimingGameStatus.finished && !_rematchWaiting) {
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }
      setState(() {
        _status = TimingGameStatus.playing;
        _currentRound = 0;
        _totalScores = [0, 0];
        _hasStopped = false;
        _opponentStopped = false;
        _stoppedPosition = null;
        _roundPhase = TimingRoundPhase.idle;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _opponentLeft = false;
        _isDraw = false;
        _winnerId = null;
      });
    });

    _socketListeners.on('timing_round_start', (data) {
      if (!mounted) return;
      final round = (data['round'] as num).toInt();
      final speed = (data['speed'] as num).toInt();
      setState(() {
        _currentRound = round;
        _currentSpeed = speed;
        _hasStopped = false;
        _opponentStopped = false;
        _stoppedPosition = null;
        _roundPhase = TimingRoundPhase.playing;
        _isWaitingForReconnect = false;
      });
      _startGaugeAnimation(speed);
    });

    _socketListeners.on('timing_player_stopped', (data) {
      final playerIndex = (data['playerIndex'] as num).toInt();
      if (playerIndex != _myPlayerIndex) {
        setState(() => _opponentStopped = true);
      }
    });

    _socketListeners.on('timing_round_result', (data) {
      if (!mounted) return;
      _gaugeController.stop();
      final positions = List<double>.from(
          (data['positions'] as List).map((e) => (e as num).toDouble()));
      final roundScores = List<int>.from(
          (data['roundScores'] as List).map((e) => (e as num).toInt()));
      final totalScores = List<int>.from(
          (data['totalScores'] as List).map((e) => (e as num).toInt()));
      setState(() {
        _totalScores = totalScores;
        _lastRoundScores = roundScores;
        _lastPositions = positions;
        _roundPhase = TimingRoundPhase.result;
      });
    });

    _socketListeners.on('timing_resumed', (data) {
      if (!mounted) return;
      final round = (data['round'] as num).toInt();
      final totalScores = List<int>.from(
          (data['totalScores'] as List).map((e) => (e as num).toInt()));
      final speed = (data['speed'] as num).toInt();
      setState(() {
        _status = TimingGameStatus.playing;
        _currentRound = round;
        _totalScores = totalScores;
        _currentSpeed = speed;
        _hasStopped = false;
        _opponentStopped = false;
        _stoppedPosition = null;
        _roundPhase = TimingRoundPhase.playing;
        _isWaitingForReconnect = false;
      });
      _startGaugeAnimation(speed);
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'timing') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      final totalScores = List<int>.from(
          (data['totalScores'] as List?)?.map((e) => (e as num).toInt()) ??
              [0, 0]);
      final round = (data['round'] as num?)?.toInt() ?? 0;
      final speed = (data['speed'] as num?)?.toInt() ?? 2000;
      final hasStopped = data['hasPlayerStopped'] as bool? ?? false;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex =
            (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _currentRound = round;
        _totalScores = totalScores;
        _currentSpeed = speed;
        _hasStopped = hasStopped;
        _opponentStopped = false;
        _roundPhase =
            round > 0 ? TimingRoundPhase.playing : TimingRoundPhase.idle;
        _status = TimingGameStatus.playing;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      if (round > 0 && !hasStopped) {
        _startGaugeAnimation(speed);
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
        beforeNavigate: _reset,
        message: '20초 안에 연결을 복구하지 못해 게임에서 제외되었습니다.',
      );
    });

    _socketListeners.on('opponent_disconnected', (_) {
      if (!_isGameActive) return;
      _gaugeController.stop();
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
      if (_status == TimingGameStatus.finished) return;
      _gaugeController.stop();
      setState(() {
        _status = TimingGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        if (data['totalScores'] != null) {
          _totalScores = List<int>.from(
              (data['totalScores'] as List).map((e) => (e as num).toInt()));
        }
      });
      _waitingReconnectTimer?.cancel();
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == TimingGameStatus.idle ||
          _status == TimingGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == TimingGameStatus.finished) {
        setState(() {
          _opponentLeft = true;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
        });
        return;
      }
      _gaugeController.stop();
      if (_isExitDialogOpen && mounted) {
        Navigator.of(context).pop();
        _isExitDialogOpen = false;
      }
      setState(() {
        _status = TimingGameStatus.finished;
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
    );
  }

  void _startGaugeAnimation(int speedMs) {
    _gaugeController.stop();
    _gaugeController.duration = Duration(milliseconds: speedMs ~/ 2);
    _gaugeController.value = 0.0;
    _gaugeController.repeat(reverse: true);
  }

  void _onStopTap() {
    if (_hasStopped || _roomId == null || _roundPhase != TimingRoundPhase.playing || !_gaugeController.isAnimating) return;
    final position = _gaugeController.value;
    setState(() {
      _hasStopped = true;
      _stoppedPosition = position;
    });
    _gaugeController.stop();
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {
        'type': 'stop',
        'position': position,
      },
    });
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeTiming,
      'isHardcore': false,
    });
    setState(() => _status = TimingGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeTiming,
      'isHardcore': false,
    });
    setState(() => _status = TimingGameStatus.idle);
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
    _gaugeController.stop();
    setState(() {
      _status = TimingGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _currentRound = 0;
      _totalScores = [0, 0];
      _hasStopped = false;
      _opponentStopped = false;
      _stoppedPosition = null;
      _roundPhase = TimingRoundPhase.idle;
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
              title: '타이밍 맞추기',
              backgroundColor: theme.primary,
              onBack: () => _showExitDialog(theme),
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

  Widget _buildRankedWaitingView(GameTheme theme) {
    return GameWaitingView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: theme.primary,
      icon: Icons.timer,
      title: '타이밍 맞추기 준비 중',
      subtitle: '게이지와 타이머를 맞추고 있습니다.',
      statusMessages: const [
        '게이지를 준비하고 있습니다.',
        '타이머를 동기화하고 있습니다.',
        '상대의 상태를 확인하고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      TimingGameStatus.idle => widget.isRanked
          ? _buildRankedWaitingView(theme)
          : _buildIdleView(theme),
      TimingGameStatus.searching => widget.isRanked
          ? _buildRankedWaitingView(theme)
          : _buildSearchingView(theme),
      TimingGameStatus.matched => widget.isRanked
          ? _buildRankedWaitingView(theme)
          : _buildMatchedView(theme),
      TimingGameStatus.playing => _buildPlayingView(theme),
      TimingGameStatus.finished => _buildFinishedView(theme),
    };
  }

  void _showExitDialog(GameTheme theme) {
    if (!widget.isRanked && _status == TimingGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    final isRankedWaiting = widget.isRanked &&
        (_status == TimingGameStatus.idle ||
            _status == TimingGameStatus.searching ||
            _status == TimingGameStatus.matched);

    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    if (_status == TimingGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }

    _isExitDialogOpen = true;
    showGameExitDialog(
      context: context,
      accentColor: _accentColor,
      message: '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
      onExit: _leaveGame,
    ).then((_) => _isExitDialogOpen = false);
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
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.6,
            ),
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
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(Icons.person_add, color: theme.primary),
                      const SizedBox(width: 12),
                      const Text(
                        '친구 초대',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold),
                      ),
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
                                Text(
                                  '온라인 친구가 없습니다',
                                  style:
                                      TextStyle(color: Colors.grey.shade600),
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
                                    backgroundColor:
                                        theme.primary.withValues(alpha: 0.2),
                                    child: Text(
                                      friend.nickname.isNotEmpty
                                          ? friend.nickname[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(color: theme.primary),
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
                                        border: Border.all(
                                            color: Colors.white, width: 2),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              title: Text(friend.nickname,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              subtitle: friend.memo != null &&
                                      friend.memo!.isNotEmpty
                                  ? Text(friend.memo!,
                                      style: TextStyle(
                                          color: Colors.grey.shade600,
                                          fontSize: 12))
                                  : null,
                              trailing: ElevatedButton(
                                onPressed: () {
                                  friendProvider.inviteToGame(
                                    friend.id,
                                    AppConfig.gameTypeTiming,
                                    isHardcore: false,
                                  );
                                  Navigator.pop(dialogContext);
                                  ScaffoldMessenger.of(context)
                                      .clearSnackBars();
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
                SizedBox(
                    height: MediaQuery.of(dialogContext).padding.bottom + 16),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildIdleView(GameTheme theme) {
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: _accentColor,
      icon: Icons.timer,
      title: '타이밍 맞추기',
      descriptions: const ['게이지 중심을 정확히 멈춰라!', '5라운드, 점점 빨라지는 게이지'],
      onFindMatch: _findMatch,
      onInviteFriend: () => _showFriendInviteDialog(context),
    );
  }

  Widget _buildSearchingView(GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _accentColor.withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: _accentColor,
            ),
            const SizedBox(height: 24),
            Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: _accentColor,
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

  Widget _buildMatchedView(GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _accentColor.withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _accentColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sports_esports,
                size: 64,
                color: _accentColor,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: _accentColor,
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

  Widget _buildPlayingView(GameTheme theme) {
    return Column(
      children: [
        GameDuelHeader(
          backgroundColors: [
            _accentColor.withValues(alpha: 0.08),
            const Color(0xFFF0F0FF),
          ],
          accentColor: _accentColor,
          centerLabel: 'R$_currentRound',
          centerSubtitle: '$_maxRounds 라운드',
          myName: _myNickname ?? '나',
          opponentName: _opponentNickname ?? '상대',
          myAvatarUrl: _myAvatarUrl,
          opponentAvatarUrl: _opponentAvatarUrl,
          myActive: !_hasStopped,
          opponentActive: !_opponentStopped,
          myProfileSettings: _myProfileSettings,
          opponentProfileSettings: _opponentProfileSettings,
          myExtraWidget: GameHeaderScorePill(
            score: _myScore,
            color: _accentColor,
          ),
          opponentExtraWidget: GameHeaderScorePill(
            score: _opponentScore,
            color: Colors.grey,
          ),
        ),

        // 라운드 인디케이터
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_maxRounds, (i) {
              final roundNum = i + 1;
              final isActive = roundNum == _currentRound;
              final isDone = roundNum < _currentRound;
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone
                      ? _accentColor
                      : isActive
                          ? _accentColor.withValues(alpha: 0.3)
                          : Colors.grey.shade200,
                  border: isActive
                      ? Border.all(color: _accentColor, width: 2)
                      : null,
                ),
                child: Center(
                  child: Text(
                    '$roundNum',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isDone || isActive
                          ? (isDone ? Colors.white : _accentColor)
                          : Colors.grey.shade500,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),

        Expanded(
          child: _roundPhase == TimingRoundPhase.result
              ? _buildRoundResultView()
              : _buildGaugeView(),
        ),
      ],
    );
  }

  Color _getZoneColor(double position) {
    final distance = (position - 0.5).abs();
    if (distance < 0.05) return Colors.green;
    if (distance < 0.12) return const Color(0xFF7CB342);
    if (distance < 0.20) return Colors.amber;
    if (distance < 0.30) return Colors.orange;
    return Colors.red;
  }

  String _getGrade(double position) {
    final distance = (position - 0.5).abs();
    if (distance < 0.05) return 'Perfect!';
    if (distance < 0.12) return 'Great!';
    if (distance < 0.20) return 'Good';
    if (distance < 0.30) return 'OK';
    return 'Miss';
  }

  int _getScore(double position) {
    final distance = (position - 0.5).abs();
    if (distance < 0.05) return 100;
    if (distance < 0.12) return 75;
    if (distance < 0.20) return 50;
    if (distance < 0.30) return 25;
    return 0;
  }

  Widget _buildGaugeView() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _onStopTap(),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_hasStopped && _stoppedPosition != null) ...[
            Text(
              _getGrade(_stoppedPosition!),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: _getZoneColor(_stoppedPosition!),
              ),
            ),
            Text(
              '+${_getScore(_stoppedPosition!)}점',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: _getZoneColor(_stoppedPosition!),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // 게이지 바
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: SizedBox(
              height: 80,
              child: (_hasStopped && _stoppedPosition != null)
                  ? _buildStaticGauge(_stoppedPosition!)
                  : AnimatedBuilder(
                      animation: _gaugeController,
                      builder: (context, child) {
                        return _buildGaugeBar(_gaugeController.value);
                      },
                    ),
            ),
          ),

          const SizedBox(height: 32),

          if (_hasStopped) ...[
            Text(
              _opponentStopped
                  ? '곧 결과가 공개됩니다...'
                  : '상대를 기다리는 중...',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            if (_opponentStopped)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '상대 완료!',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _accentColor,
                  ),
                ),
              ),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 20),
              decoration: BoxDecoration(
                color: _accentColor,
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  BoxShadow(
                    color: _accentColor.withValues(alpha: 0.4),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Text(
                'STOP!',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 4,
                ),
              ),
            ),
            if (_opponentStopped)
              Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  '상대 완료!',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _accentColor,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '화면을 터치해서 멈추세요!',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGaugeBar(double value) {
    return CustomPaint(
      painter: _GaugePainter(value: value, stoppedValue: null),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildStaticGauge(double value) {
    return CustomPaint(
      painter: _GaugePainter(value: value, stoppedValue: value),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildRoundResultView() {
    final myPos = _lastPositions[_myPlayerIndex];
    final opPos = _lastPositions[1 - _myPlayerIndex];
    final myRoundScore = _lastRoundScores[_myPlayerIndex];
    final opRoundScore = _lastRoundScores[1 - _myPlayerIndex];

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Round $_currentRound 결과',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: _accentColor,
            ),
          ),
          const SizedBox(height: 24),

          // 내 결과
          _buildPlayerResult(
            _myNickname ?? '나',
            myPos,
            myRoundScore,
            _accentColor,
          ),
          const SizedBox(height: 16),
          const Text('VS', style: TextStyle(fontSize: 16, color: Colors.grey)),
          const SizedBox(height: 16),

          // 상대 결과
          _buildPlayerResult(
            _opponentNickname ?? '상대',
            opPos,
            opRoundScore,
            Colors.grey.shade600,
          ),

          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '총점  $_myScore',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _accentColor,
                ),
              ),
              const Text('  :  ',
                  style: TextStyle(fontSize: 18, color: Colors.grey)),
              Text(
                '$_opponentScore',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          if (_currentRound < _maxRounds)
            Text(
              '다음 라운드 준비 중...',
              style: TextStyle(color: Colors.grey.shade500),
            ),
        ],
      ),
    );
  }

  Widget _buildPlayerResult(
      String name, double position, int score, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          const SizedBox(width: 16),
          Text(
            _getGrade(position),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: _getZoneColor(position),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '+$score',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
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
      extra: Text('$_myScore : $_opponentScore', style: const TextStyle(fontSize: 20, color: Colors.grey)),
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
      resultColor = _accentColor;
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
                    ? '동점! 집중력이 비슷하네요.'
                    : (isWinner
                        ? '정확한 타이밍으로 승리했어요!'
                        : '다음엔 더 정확하게 멈춰봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '$_myScore점',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '$_opponentScore점',
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
                accentColor: _accentColor,
                opponentLeft: _opponentLeft,
                rematchWaiting: _rematchWaiting,
                isInvitationGame: _isInvitationGame,
                canSendFriendRequest: !_isInvitationGame &&
                    !_opponentLeft &&
                    _opponentUserId != null &&
                    !context
                        .read<FriendProvider>()
                        .isFriend(_opponentUserId!),
                onRematchPressed:
                    _rematchWaiting ? _cancelRematch : _requestRematch,
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
                            content: Text(
                                '$_opponentNickname님에게 친구 요청을 보냈습니다'),
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
}

class _GaugePainter extends CustomPainter {
  final double value;
  final double? stoppedValue;

  _GaugePainter({required this.value, this.stoppedValue});

  @override
  void paint(Canvas canvas, Size size) {
    final barHeight = 40.0;
    final barY = (size.height - barHeight) / 2;
    final barRect = Rect.fromLTWH(0, barY, size.width, barHeight);

    // 구간별 색상 배경
    final zones = <_Zone>[
      _Zone(0.0, 0.20, Colors.red),
      _Zone(0.20, 0.30, Colors.orange),
      _Zone(0.30, 0.38, Colors.amber),
      _Zone(0.38, 0.45, const Color(0xFF7CB342)),
      _Zone(0.45, 0.55, Colors.green),
      _Zone(0.55, 0.62, const Color(0xFF7CB342)),
      _Zone(0.62, 0.70, Colors.amber),
      _Zone(0.70, 0.80, Colors.orange),
      _Zone(0.80, 1.0, Colors.red),
    ];

    // 배경 (라운드 rect)
    final bgRRect =
        RRect.fromRectAndRadius(barRect, const Radius.circular(8));
    canvas.clipRRect(bgRRect);

    for (final zone in zones) {
      final left = size.width * zone.start;
      final right = size.width * zone.end;
      final paint = Paint()..color = zone.color.withValues(alpha: 0.25);
      canvas.drawRect(Rect.fromLTWH(left, barY, right - left, barHeight), paint);
    }

    // 중심선
    final centerPaint = Paint()
      ..color = Colors.green
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width * 0.5, barY),
      Offset(size.width * 0.5, barY + barHeight),
      centerPaint,
    );

    // 마커
    final markerX = size.width * value;
    final markerPaint = Paint()
      ..color = stoppedValue != null
          ? _getColorForPosition(value)
          : const Color(0xFF6C5CE7)
      ..style = PaintingStyle.fill;
    final markerShadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.2)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    canvas.drawCircle(Offset(markerX, barY + barHeight / 2), 14, markerShadow);
    canvas.drawCircle(Offset(markerX, barY + barHeight / 2), 12, markerPaint);

    final innerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(markerX, barY + barHeight / 2), 5, innerPaint);
  }

  Color _getColorForPosition(double pos) {
    final dist = (pos - 0.5).abs();
    if (dist < 0.05) return Colors.green;
    if (dist < 0.12) return const Color(0xFF7CB342);
    if (dist < 0.20) return Colors.amber;
    if (dist < 0.30) return Colors.orange;
    return Colors.red;
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.stoppedValue != stoppedValue;
}

class _Zone {
  final double start;
  final double end;
  final Color color;
  const _Zone(this.start, this.end, this.color);
}
