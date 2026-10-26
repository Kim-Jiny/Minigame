import 'dart:async';
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
import '../../utils/game_theme.dart';
import '../../theme/candy_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/pop_in.dart';
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

enum TimingGameStatus { idle, searching, matched, playing, finished }

enum TimingRoundPhase { idle, playing, result }

class TimingScreen extends StatefulWidget {
  final bool isRanked;

  const TimingScreen({super.key, this.isRanked = false});

  @override
  State<TimingScreen> createState() => _TimingScreenState();
}

class _TimingScreenState extends State<TimingScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );
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
  int _stopTick = 0;
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
  Color get _accentColor => GameTheme.fromProfileSettings(
    context.read<ShopProvider>().profileSettings,
  ).primary;
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
      final isActiveInvitation =
          game.isInvitationGame &&
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
      final opponent = players.cast<Map<String, dynamic>?>().firstWhere(
        (p) => p!['id'] != _myId,
        orElse: () => null,
      );
      if (opponent == null) return;
      final me = players.firstWhere(
        (p) => p['id'] == _myId,
        orElse: () => null,
      );
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
        (data['positions'] as List).map((e) => (e as num).toDouble()),
      );
      final roundScores = List<int>.from(
        (data['roundScores'] as List).map((e) => (e as num).toInt()),
      );
      final totalScores = List<int>.from(
        (data['totalScores'] as List).map((e) => (e as num).toInt()),
      );
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
        (data['totalScores'] as List).map((e) => (e as num).toInt()),
      );
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
            [0, 0],
      );
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
        _roundPhase = round > 0
            ? TimingRoundPhase.playing
            : TimingRoundPhase.idle;
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
            (data['totalScores'] as List).map((e) => (e as num).toInt()),
          );
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
    if (_hasStopped ||
        _roomId == null ||
        _roundPhase != TimingRoundPhase.playing ||
        !_gaugeController.isAnimating) {
      return;
    }
    final position = _gaugeController.value;
    final distance = (position - 0.5).abs();
    if (distance < 0.05) {
      HapticFeedback.heavyImpact();
    } else if (distance < 0.20) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }
    setState(() {
      _hasStopped = true;
      _stoppedPosition = position;
      _stopTick++;
    });
    _gaugeController.stop();
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'stop', 'position': position},
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
      TimingGameStatus.idle =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildIdleView(theme),
      TimingGameStatus.searching =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildSearchingView(theme),
      TimingGameStatus.matched =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildMatchedView(theme),
      TimingGameStatus.playing => _buildPlayingView(theme),
      TimingGameStatus.finished => _buildFinishedView(theme),
    };
  }

  void _showExitDialog(GameTheme theme) {
    // 결과 화면에서는 패배 처리 경고 없이 바로 나가기
    if (_status == TimingGameStatus.finished) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    if (!widget.isRanked && _status == TimingGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    final isRankedWaiting =
        widget.isRanked &&
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
          final onlineFriends = friendProvider.friends
              .where((f) => f.isOnline)
              .toList();

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.6,
            ),
            decoration: const BoxDecoration(
              color: CandyColors.cream,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(
                top: BorderSide(color: CandyColors.ink, width: 3),
                left: BorderSide(color: CandyColors.ink, width: 3),
                right: BorderSide(color: CandyColors.ink, width: 3),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 44,
                  height: 6,
                  decoration: BoxDecoration(
                    color: CandyColors.ink,
                    borderRadius: BorderRadius.circular(3),
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
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 3, thickness: 3, color: CandyColors.ink),
                Flexible(
                  child: onlineFriends.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(40),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.person_off,
                                  size: 48,
                                  color: Colors.grey.shade400,
                                ),
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
                                    backgroundColor: theme.primary.withValues(
                                      alpha: 0.2,
                                    ),
                                    child: Text(
                                      friend.nickname.isNotEmpty
                                          ? friend.nickname[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(
                                        color: theme.primary,
                                        fontWeight: FontWeight.w900,
                                      ),
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
                                          color: Colors.white,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              title: Text(
                                friend.nickname,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle:
                                  friend.memo != null && friend.memo!.isNotEmpty
                                  ? Text(
                                      friend.memo!,
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 12,
                                      ),
                                    )
                                  : null,
                              trailing: ElevatedButton(
                                onPressed: () {
                                  friendProvider.inviteToGame(
                                    friend.id,
                                    AppConfig.gameTypeTiming,
                                    isHardcore: false,
                                  );
                                  Navigator.pop(dialogContext);
                                  ScaffoldMessenger.of(
                                    context,
                                  ).clearSnackBars();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '${friend.nickname}님에게 초대를 보냈습니다!',
                                      ),
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
                  height: MediaQuery.of(dialogContext).padding.bottom + 16,
                ),
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
    return _CandyStatusView(
      accentColor: _accentColor,
      icon: Icons.search_rounded,
      title: '상대를 찾는 중...',
      spinner: true,
      onCancel: _cancelMatch,
    );
  }

  Widget _buildMatchedView(GameTheme theme) {
    return _CandyStatusView(
      accentColor: _accentColor,
      icon: Icons.sports_esports_rounded,
      title: '${_opponentNickname ?? '상대'}님과 매칭!',
      subtitle: '게임이 곧 시작됩니다...',
    );
  }

  Widget _buildPlayingView(GameTheme theme) {
    return Container(
      color: CandyColors.cream,
      child: Column(
        children: [
          GameDuelHeader(
            backgroundColors: [
              _accentColor.withValues(alpha: 0.12),
              CandyColors.cream,
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
              color: CandyColors.inkSoft,
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
                final dot = AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone
                        ? CandyColors.mint
                        : isActive
                        ? CandyColors.sun
                        : Colors.white,
                    border: Border.all(color: CandyColors.ink, width: 2.5),
                    boxShadow: [
                      if (isActive || isDone)
                        const BoxShadow(
                          color: CandyColors.ink,
                          offset: Offset(0, 3),
                        ),
                    ],
                  ),
                  child: Center(
                    child: isDone
                        ? const Icon(
                            Icons.check_rounded,
                            size: 20,
                            color: Colors.white,
                          )
                        : Text(
                            '$roundNum',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: isActive
                                  ? CandyColors.ink
                                  : CandyColors.inkSoft,
                            ),
                          ),
                  ),
                );
                if (!isActive) return dot;
                return TweenAnimationBuilder<double>(
                  key: ValueKey('rd$_currentRound'),
                  tween: Tween(begin: 0.6, end: 1),
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.elasticOut,
                  builder: (context, s, child) =>
                      Transform.scale(scale: s, child: child),
                  child: dot,
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
      ),
    );
  }

  Color _getZoneColor(double position) => _zoneColorFor(position);

  String _getGrade(double position) {
    final distance = (position - 0.5).abs();
    if (distance < 0.05) return 'PERFECT!';
    if (distance < 0.12) return 'GREAT!';
    if (distance < 0.20) return 'GOOD';
    if (distance < 0.30) return 'OK';
    return 'MISS';
  }

  int _getScore(double position) {
    final distance = (position - 0.5).abs();
    if (distance < 0.05) return 100;
    if (distance < 0.12) return 75;
    if (distance < 0.20) return 50;
    if (distance < 0.30) return 25;
    return 0;
  }

  /// 등급 말풍선 — 통 튀며 등장.
  Widget _gradePill(double position, {double fontSize = 28}) {
    final color = _getZoneColor(position);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: CandyColors.ink, width: 3),
        boxShadow: const [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, 4)),
        ],
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          _getGrade(position),
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: 1,
            shadows: const [
              Shadow(color: CandyColors.ink, offset: Offset(0, 2)),
              Shadow(color: CandyColors.ink, offset: Offset(1.5, 0)),
              Shadow(color: CandyColors.ink, offset: Offset(-1.5, 0)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGaugeView() {
    final stopped = _hasStopped && _stoppedPosition != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _onStopTap(),
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 등급 팝 영역(높이 고정으로 레이아웃 흔들림 방지)
                SizedBox(
                  height: 96,
                  child: Center(
                    child: stopped
                        ? TweenAnimationBuilder<double>(
                            key: ValueKey('grade$_stopTick'),
                            tween: Tween(begin: 0.2, end: 1),
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.elasticOut,
                            builder: (context, s, child) =>
                                Transform.scale(scale: s, child: child),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _gradePill(_stoppedPosition!),
                                const SizedBox(height: 6),
                                Text(
                                  '+${_getScore(_stoppedPosition!)}점',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    color: _getZoneColor(_stoppedPosition!),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Text(
                            _roundPhase == TimingRoundPhase.playing
                                ? '가운데에 맞춰 멈춰요!'
                                : '라운드 준비 중...',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: CandyColors.inkSoft,
                            ),
                          ),
                  ),
                ),

                // 게이지 바
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: RepaintBoundary(
                    child: SizedBox(
                      height: 88,
                      child: stopped
                          ? _buildStaticGauge(_stoppedPosition!)
                          : AnimatedBuilder(
                              animation: _gaugeController,
                              builder: (context, child) {
                                return _buildGaugeBar(_gaugeController.value);
                              },
                            ),
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                if (_hasStopped) ...[
                  Text(
                    _opponentStopped ? '곧 결과가 공개됩니다...' : '상대를 기다리는 중...',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                  if (_opponentStopped) _opponentDonePill(),
                ] else ...[
                  if (_roundPhase == TimingRoundPhase.playing)
                    IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 52,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          color: _accentColor,
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(color: CandyColors.ink, width: 4),
                          boxShadow: const [
                            BoxShadow(
                              color: CandyColors.ink,
                              offset: Offset(0, 7),
                            ),
                          ],
                        ),
                        child: const Text(
                          'STOP!',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                    ),
                  if (_opponentStopped) _opponentDonePill(),
                  const SizedBox(height: 14),
                  const Text(
                    '화면을 터치해서 멈추세요!',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _opponentDonePill() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: PopIn(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: CandyColors.mint,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: CandyColors.ink, width: 2.5),
          ),
          child: const Text(
            '상대 완료!',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGaugeBar(double value) {
    return CustomPaint(
      painter: _GaugePainter(value: value, stoppedValue: null, flash: 0),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildStaticGauge(double value) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('flash$_stopTick'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 560),
      curve: Curves.easeOut,
      builder: (context, t, _) => CustomPaint(
        painter: _GaugePainter(value: value, stoppedValue: value, flash: t),
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _buildRoundResultView() {
    final myPos = _lastPositions[_myPlayerIndex];
    final opPos = _lastPositions[1 - _myPlayerIndex];
    final myRoundScore = _lastRoundScores[_myPlayerIndex];
    final opRoundScore = _lastRoundScores[1 - _myPlayerIndex];

    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: box.maxHeight > 48 ? box.maxHeight - 48 : 0.0,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PopIn(
                child: Text(
                  'Round $_currentRound 결과',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _accentColor,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 내 결과
              PopIn(
                delay: const Duration(milliseconds: 120),
                child: _buildPlayerResult(
                  _myNickname ?? '나',
                  myPos,
                  myRoundScore,
                  _accentColor,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'VS',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.inkSoft,
                ),
              ),
              const SizedBox(height: 12),

              // 상대 결과
              PopIn(
                delay: const Duration(milliseconds: 300),
                child: _buildPlayerResult(
                  _opponentNickname ?? '상대',
                  opPos,
                  opRoundScore,
                  CandyColors.sky,
                ),
              ),

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '총점  $_myScore',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: _accentColor,
                    ),
                  ),
                  const Text(
                    '  :  ',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                  Text(
                    '$_opponentScore',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: CandyColors.inkSoft,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              if (_currentRound < _maxRounds)
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
  }

  Widget _buildPlayerResult(
    String name,
    double position,
    int score,
    Color color,
  ) {
    return CartoonCard(
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: CandyColors.ink, width: 2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _gradePill(position, fontSize: 15),
          const SizedBox(width: 10),
          Text(
            '+$score',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
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
        extra: Text(
          '$_myScore : $_opponentScore',
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: CandyColors.inkSoft,
          ),
        ),
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
          colors: [resultColor.withValues(alpha: 0.18), CandyColors.cream],
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
                    : (isWinner ? '정확한 타이밍으로 승리했어요!' : '다음엔 더 정확하게 멈춰봐요.'),
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
}

const Color _kPerfectColor = CandyColors.mint;
const Color _kGreatColor = Color(0xFF9BE15D);
const Color _kGoodColor = CandyColors.sun;
const Color _kOkColor = CandyColors.tangerine;
const Color _kMissColor = Color(0xFFFF6F7D);

Color _zoneColorFor(double position) {
  final distance = (position - 0.5).abs();
  if (distance < 0.05) return _kPerfectColor;
  if (distance < 0.12) return _kGreatColor;
  if (distance < 0.20) return _kGoodColor;
  if (distance < 0.30) return _kOkColor;
  return _kMissColor;
}

class _GaugePainter extends CustomPainter {
  final double value;
  final double? stoppedValue;

  /// 정지 직후 터지는 링 이펙트 진행도(0~1). 0이면 그리지 않는다.
  final double flash;

  _GaugePainter({required this.value, this.stoppedValue, this.flash = 0});

  @override
  void paint(Canvas canvas, Size size) {
    const barHeight = 44.0;
    final barY = (size.height - barHeight) / 2;
    final barRect = Rect.fromLTWH(0, barY, size.width, barHeight);
    final rrect = RRect.fromRectAndRadius(barRect, const Radius.circular(16));
    final ink = CandyColors.ink;

    // 하드 섀도우
    canvas.drawRRect(rrect.shift(const Offset(0, 5)), Paint()..color = ink);

    // 구간별 색상 배경
    final zones = <_Zone>[
      const _Zone(0.0, 0.20, _kMissColor),
      const _Zone(0.20, 0.30, _kOkColor),
      const _Zone(0.30, 0.38, _kGoodColor),
      const _Zone(0.38, 0.45, _kGreatColor),
      const _Zone(0.45, 0.55, _kPerfectColor),
      const _Zone(0.55, 0.62, _kGreatColor),
      const _Zone(0.62, 0.70, _kGoodColor),
      const _Zone(0.70, 0.80, _kOkColor),
      const _Zone(0.80, 1.0, _kMissColor),
    ];

    canvas.save();
    canvas.clipRRect(rrect);
    for (final zone in zones) {
      final left = size.width * zone.start;
      final right = size.width * zone.end;
      canvas.drawRect(
        Rect.fromLTWH(left, barY, right - left, barHeight),
        Paint()..color = zone.color,
      );
      if (zone.start > 0) {
        canvas.drawLine(
          Offset(left, barY),
          Offset(left, barY + barHeight),
          Paint()
            ..color = ink.withValues(alpha: 0.25)
            ..strokeWidth = 2,
        );
      }
    }
    // 광택
    canvas.drawRect(
      Rect.fromLTWH(0, barY + 4, size.width, 5),
      Paint()..color = Colors.white.withValues(alpha: 0.28),
    );
    // 중심선
    canvas.drawLine(
      Offset(size.width * 0.5, barY),
      Offset(size.width * 0.5, barY + barHeight),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 3,
    );
    canvas.restore();

    // 아웃라인
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5,
    );

    // 중심 표시 삼각형(위)
    final tri = Path()
      ..moveTo(size.width * 0.5 - 7, barY - 10)
      ..lineTo(size.width * 0.5 + 7, barY - 10)
      ..lineTo(size.width * 0.5, barY - 1)
      ..close();
    canvas.drawPath(tri, Paint()..color = ink);

    // 마커
    final markerX = size.width * value.clamp(0.0, 1.0);
    final markerCenter = Offset(markerX, barY + barHeight / 2);
    final markerColor = stoppedValue != null
        ? _zoneColorFor(value)
        : CandyColors.pink;

    canvas.drawCircle(markerCenter.translate(0, 3), 17, Paint()..color = ink);
    canvas.drawCircle(markerCenter, 17, Paint()..color = ink);
    canvas.drawCircle(markerCenter, 13.5, Paint()..color = markerColor);
    canvas.drawCircle(markerCenter, 5, Paint()..color = Colors.white);

    // 정지 직후 링 플래시
    if (stoppedValue != null && flash > 0 && flash < 1) {
      final ringColor = _zoneColorFor(value);
      canvas.drawCircle(
        markerCenter,
        17 + 46 * flash,
        Paint()
          ..color = ringColor.withValues(alpha: (1 - flash) * 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6 * (1 - flash) + 1,
      );
      canvas.drawRRect(
        rrect,
        Paint()..color = Colors.white.withValues(alpha: (1 - flash) * 0.45),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.stoppedValue != stoppedValue ||
      oldDelegate.flash != flash;
}

class _Zone {
  final double start;
  final double end;
  final Color color;
  const _Zone(this.start, this.end, this.color);
}

/// 캔디 스타일 매칭 대기/성사 화면.
class _CandyStatusView extends StatelessWidget {
  final Color accentColor;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool spinner;
  final VoidCallback? onCancel;

  const _CandyStatusView({
    required this.accentColor,
    required this.icon,
    required this.title,
    this.subtitle,
    this.spinner = false,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accentColor.withValues(alpha: 0.16), CandyColors.cream],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: PopIn(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    if (spinner)
                      SizedBox(
                        width: 112,
                        height: 112,
                        child: CircularProgressIndicator(
                          color: accentColor,
                          strokeWidth: 6,
                        ),
                      ),
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: CandyColors.ink, width: 3),
                        boxShadow: const [
                          BoxShadow(
                            color: CandyColors.ink,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Icon(icon, size: 42, color: accentColor),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: accentColor,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: CandyColors.inkSoft,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                if (onCancel != null) ...[
                  const SizedBox(height: 36),
                  SizedBox(
                    width: 180,
                    child: ChunkyButton(
                      label: '취소',
                      color: Colors.white,
                      textColor: CandyColors.ink,
                      height: 48,
                      onPressed: onCancel,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
