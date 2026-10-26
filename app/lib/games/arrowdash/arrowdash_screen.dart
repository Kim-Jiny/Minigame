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
import '../../utils/game_theme.dart';
import '../../theme/candy_theme.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/pop_in.dart';
import '../../widgets/cartoon/duo_mascot.dart';
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

enum ArrowdashGameStatus { idle, searching, matched, playing, finished }

class ArrowdashScreen extends StatefulWidget {
  final bool isRanked;

  const ArrowdashScreen({super.key, this.isRanked = false});

  @override
  State<ArrowdashScreen> createState() => _ArrowdashScreenState();
}

class _ArrowdashScreenState extends State<ArrowdashScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );
  bool _hasScheduledPop = false;
  bool _isExitDialogOpen = false;

  ArrowdashGameStatus _status = ArrowdashGameStatus.idle;

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
  List<String> _arrows = [];
  List<int> _progress = [0, 0];
  bool? _lastAnswerCorrect;
  Timer? _feedbackTimer;
  int _feedbackTick = 0;

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
  int _remainingSeconds = 60;

  // 애니메이션
  late AnimationController _arrowAnimController;
  late Animation<double> _arrowScaleAnim;

  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accentColor => GameTheme.fromProfileSettings(
    context.read<ShopProvider>().profileSettings,
  ).primary;
  static const _totalArrows = 30;

  @override
  void initState() {
    super.initState();
    _arrowAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _arrowScaleAnim = CurvedAnimation(
      parent: _arrowAnimController,
      curve: Curves.elasticOut,
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
          _status = ArrowdashGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('ArrowdashScreen: GameProvider init failed: $e');
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _feedbackTimer?.cancel();
    _socketListeners.offAll();
    _arrowAnimController.dispose();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != ArrowdashGameStatus.idle &&
      _status != ArrowdashGameStatus.searching &&
      _status != ArrowdashGameStatus.finished;

  int get _myProgress => _progress[_myPlayerIndex];
  int get _opponentProgress => _progress[1 - _myPlayerIndex];

  Duration _getAnimationDuration() {
    final ms = math.max(150, 500 - (_myProgress * 12));
    return Duration(milliseconds: ms);
  }

  void _playArrowAnimation() {
    _arrowAnimController.duration = _getAnimationDuration();
    _arrowAnimController.reset();
    _arrowAnimController.forward();
  }

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
      setState(() => _status = ArrowdashGameStatus.searching);
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
        _status = ArrowdashGameStatus.matched;
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
      if (data['gameType'] != 'arrowdash') return;
      if (data['players'] != null) {
        final players = data['players'] as List;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) {
          _myPlayerIndex = updatedIndex;
        }
      }
      if (_status == ArrowdashGameStatus.finished && !_rematchWaiting) {
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }
      setState(() {
        _status = ArrowdashGameStatus.playing;
        _remainingSeconds = 60; // 재경기 시 이전 게임의 남은 시간 잔상 방지
        _arrows = [];
        _progress = [0, 0];
        _lastAnswerCorrect = null;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _opponentLeft = false;
        _isDraw = false;
        _winnerId = null;
      });
    });

    _socketListeners.on('arrowdash_start', (data) {
      final arrowsData = data['arrows'] as List;
      final duration = data['duration'] as int? ?? 60000;
      setState(() {
        _status = ArrowdashGameStatus.playing;
        _arrows = arrowsData
            .map<String>(
              (a) => (a as Map<String, dynamic>)['direction'] as String,
            )
            .toList();
        _progress = [0, 0];
        _lastAnswerCorrect = null;
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
      _playArrowAnimation();
    });

    _socketListeners.on('arrowdash_answer', (data) {
      final playerIndex = data['playerIndex'] as int;
      final correct = data['correct'] as bool;
      final arrowIndex = data['arrowIndex'] as int;
      final newProgress = List<int>.from(data['progress']);
      setState(() {
        _progress = newProgress;
        if (playerIndex == _myPlayerIndex) {
          // stale 응답 무시: 빠른 스와이프로 인한 지난 화살표 응답 필터링
          final currentArrow = newProgress[_myPlayerIndex];
          final isRelevant = correct
              ? (arrowIndex == currentArrow - 1) // 정답: 방금 이 화살표를 넘긴 것
              : (arrowIndex == currentArrow); // 오답: 아직 이 화살표에 있음
          if (isRelevant) {
            _lastAnswerCorrect = correct;
            _feedbackTick++;
            if (correct) {
              HapticFeedback.mediumImpact();
              _playArrowAnimation();
            } else {
              HapticFeedback.heavyImpact();
            }
            _feedbackTimer?.cancel();
            _feedbackTimer = Timer(const Duration(milliseconds: 600), () {
              if (mounted) setState(() => _lastAnswerCorrect = null);
            });
          }
        }
      });
    });

    _socketListeners.on('arrowdash_timeout', (data) {
      _stopCountdown();
      setState(() {
        _progress = List<int>.from(data['progress']);
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('arrowdash_resumed', (data) {
      final arrowsData = data['arrows'] as List;
      final duration = data['duration'] as int? ?? 60000;
      setState(() {
        _status = ArrowdashGameStatus.playing;
        _arrows = arrowsData
            .map<String>(
              (a) => (a as Map<String, dynamic>)['direction'] as String,
            )
            .toList();
        _progress = List<int>.from(data['progress']);
        _lastAnswerCorrect = null;
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
      _playArrowAnimation();
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'arrowdash') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      final arrowsData = data['arrows'] as List?;
      final remainingMs = (data['remainingTimeMs'] as num?)?.toInt() ?? 60000;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex =
            (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        if (arrowsData != null) {
          _arrows = arrowsData
              .map<String>(
                (a) => (a as Map<String, dynamic>)['direction'] as String,
              )
              .toList();
        }
        _progress = List<int>.from(data['progress'] ?? _progress);
        _lastAnswerCorrect = null;
        _status = ArrowdashGameStatus.playing;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      _startCountdown((remainingMs / 1000).ceil());
      _playArrowAnimation();
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
      if (_status == ArrowdashGameStatus.finished) return;
      _stopCountdown();
      setState(() {
        _status = ArrowdashGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        if (data['progress'] != null) {
          _progress = List<int>.from(data['progress']);
        }
      });
      _waitingReconnectTimer?.cancel();
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == ArrowdashGameStatus.idle ||
          _status == ArrowdashGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == ArrowdashGameStatus.finished) {
        setState(() {
          _opponentLeft = true;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
        });
        return;
      }
      _stopCountdown();
      if (_isExitDialogOpen && mounted) {
        Navigator.of(context).pop();
        _isExitDialogOpen = false;
      }
      setState(() {
        _status = ArrowdashGameStatus.finished;
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

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeArrowDash,
      'isHardcore': false,
    });
    setState(() => _status = ArrowdashGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeArrowDash,
      'isHardcore': false,
    });
    setState(() => _status = ArrowdashGameStatus.idle);
  }

  void _submitDirection(String direction) {
    if (_roomId == null || _arrows.isEmpty) return;
    if (_myProgress >= _arrows.length) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {
        'type': 'direction',
        'arrowIndex': _myProgress,
        'direction': direction,
      },
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
    _countdownTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _feedbackTimer?.cancel();
    setState(() {
      _status = ArrowdashGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _arrows = [];
      _progress = [0, 0];
      _lastAnswerCorrect = null;
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
              title: '방향 맞추기',
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
      icon: Icons.swipe,
      title: '방향 맞추기 준비 중',
      subtitle: '화살표와 타이머를 맞추고 있습니다.',
      statusMessages: const [
        '화살표를 준비하고 있습니다.',
        '타이머를 동기화하고 있습니다.',
        '상대의 상태를 확인하고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      ArrowdashGameStatus.idle =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildIdleView(theme),
      ArrowdashGameStatus.searching =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildSearchingView(theme),
      ArrowdashGameStatus.matched =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildMatchedView(theme),
      ArrowdashGameStatus.playing => _buildPlayingView(theme),
      ArrowdashGameStatus.finished => _buildFinishedView(theme),
    };
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
                                    AppConfig.gameTypeArrowDash,
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
      icon: Icons.swipe,
      title: '방향 맞추기',
      descriptions: const ['30개 화살표를 먼저 맞춰라!', '화살표 방향으로 스와이프 (60초 제한)'],
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
            centerLabel: '$_remainingSeconds',
            centerSubtitle: '남은 시간',
            myName: _myNickname ?? '나',
            opponentName: _opponentNickname ?? '상대',
            myAvatarUrl: _myAvatarUrl,
            opponentAvatarUrl: _opponentAvatarUrl,
            myActive: true,
            opponentActive: false,
            myProfileSettings: _myProfileSettings,
            opponentProfileSettings: _opponentProfileSettings,
            myExtraWidget: GameHeaderScorePill(
              score: _myProgress,
              color: _accentColor,
            ),
            opponentExtraWidget: GameHeaderScorePill(
              score: _opponentProgress,
              color: CandyColors.inkSoft,
            ),
          ),

          // 진행도 바
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: _buildProgressBar(
                    _myProgress,
                    _accentColor,
                    '나',
                    highlight: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildProgressBar(
                    _opponentProgress,
                    CandyColors.sky,
                    _opponentNickname ?? '상대',
                  ),
                ),
              ],
            ),
          ),

          // 화살표 영역
          Expanded(
            child: _arrows.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _buildArrowArea(),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(
    int progress,
    Color color,
    String label, {
    bool highlight = false,
  }) {
    return _RaceLane(
      name: label,
      value: progress / _totalArrows,
      valueText: '$progress/$_totalArrows',
      color: color,
      highlight: highlight,
    );
  }

  IconData _arrowIcon(String direction) {
    return switch (direction) {
      'up' => Icons.arrow_upward_rounded,
      'down' => Icons.arrow_downward_rounded,
      'left' => Icons.arrow_back_rounded,
      'right' => Icons.arrow_forward_rounded,
      _ => Icons.help_outline,
    };
  }

  Widget _buildArrowArea() {
    final isComplete = _myProgress >= _arrows.length;

    if (isComplete) {
      return Center(
        child: PopIn(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DuoMascot(size: 110, color: _accentColor, mood: MascotMood.cheer),
              const SizedBox(height: 16),
              Text(
                '모든 화살표 완료!',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: _accentColor,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '결과를 기다리는 중...',
                style: TextStyle(
                  color: CandyColors.inkSoft,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final currentDirection = _arrows[_myProgress];
    final result = _lastAnswerCorrect;
    final Color faceColor = result == null
        ? _accentColor
        : result
        ? CandyColors.mint
        : const Color(0xFFFF5A5F);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanEnd: (details) {
        final dx = details.velocity.pixelsPerSecond.dx;
        final dy = details.velocity.pixelsPerSecond.dy;
        const minVelocity = 200.0;

        String? direction;
        if (dx.abs() > dy.abs() && dx.abs() > minVelocity) {
          direction = dx > 0 ? 'right' : 'left';
        } else if (dy.abs() > dx.abs() && dy.abs() > minVelocity) {
          direction = dy > 0 ? 'down' : 'up';
        }
        if (direction != null) {
          HapticFeedback.selectionClick();
          _submitDirection(direction);
        }
      },
      child: LayoutBuilder(
        builder: (context, box) {
          final bigSize = math.min(190.0, math.max(110.0, box.maxHeight - 190));
          return Column(
            children: [
              // 진행 인디케이터
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 3,
                  runSpacing: 3,
                  children: List.generate(_totalArrows, (i) {
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _myProgress
                            ? CandyColors.mint
                            : i == _myProgress
                            ? CandyColors.sun
                            : Colors.white,
                        border: Border.all(color: CandyColors.ink, width: 1.5),
                      ),
                    );
                  }),
                ),
              ),

              const SizedBox(height: 6),

              // 문제 번호
              Text(
                '${_myProgress + 1}/$_totalArrows',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.inkSoft,
                ),
              ),

              // 큰 화살표
              Expanded(
                child: Center(
                  child: _buildFeedbackShake(
                    ScaleTransition(
                      scale: _arrowScaleAnim,
                      child: SizedBox(
                        width: bigSize + 16,
                        height: bigSize + 16,
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.center,
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              width: bigSize,
                              height: bigSize,
                              decoration: BoxDecoration(
                                color: faceColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: CandyColors.ink,
                                  width: 4,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: CandyColors.ink,
                                    offset: Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Icon(
                                _arrowIcon(currentDirection),
                                size: bigSize * 0.55,
                                color: Colors.white,
                              ),
                            ),
                            if (result != null)
                              Positioned(
                                right: 0,
                                top: 0,
                                child: PopIn(
                                  key: ValueKey('badge$_feedbackTick'),
                                  duration: const Duration(milliseconds: 380),
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: CandyColors.ink,
                                        width: 2.5,
                                      ),
                                    ),
                                    child: Icon(
                                      result
                                          ? Icons.check_rounded
                                          : Icons.close_rounded,
                                      color: result
                                          ? CandyColors.mintDeep
                                          : const Color(0xFFE5484D),
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // 다음 화살표 미리보기
              _buildUpcomingArrows(),

              const SizedBox(height: 10),

              // 스와이프 힌트
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.swipe_rounded,
                      size: 26,
                      color: CandyColors.inkSoft,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '화살표 방향으로 스와이프하세요!',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: CandyColors.inkSoft,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
            ],
          );
        },
      ),
    );
  }

  /// 오답이면 좌우로 흔들고, 정답이면 가볍게 튕기는 래퍼.
  Widget _buildFeedbackShake(Widget child) {
    final result = _lastAnswerCorrect;
    if (result == null) return child;
    return TweenAnimationBuilder<double>(
      key: ValueKey('fb$_feedbackTick'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 480),
      child: child,
      builder: (context, t, child) {
        if (result) {
          final s = 1 + 0.07 * math.sin(Curves.easeOut.transform(t) * math.pi);
          return Transform.scale(scale: s, child: child);
        }
        return Transform.translate(
          offset: Offset(math.sin(t * math.pi * 6) * (1 - t) * 10, 0),
          child: child,
        );
      },
    );
  }

  Widget _buildUpcomingArrows() {
    final upcoming = <String>[];
    for (
      int i = _myProgress + 1;
      i < _arrows.length && upcoming.length < 3;
      i++
    ) {
      upcoming.add(_arrows[i]);
    }
    if (upcoming.isEmpty) return const SizedBox(height: 40);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'NEXT',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: CandyColors.inkSoft,
          ),
        ),
        const SizedBox(width: 8),
        for (int i = 0; i < upcoming.length; i++)
          Container(
            key: ValueKey('up${_myProgress + 1 + i}'),
            width: 40 - i * 4.0,
            height: 40 - i * 4.0,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CandyColors.ink, width: 2.5),
              boxShadow: const [
                BoxShadow(color: CandyColors.ink, offset: Offset(0, 2)),
              ],
            ),
            child: Icon(
              _arrowIcon(upcoming[i]),
              size: 24 - i * 3.0,
              color: _accentColor.withValues(alpha: 1 - i * 0.25),
            ),
          ),
      ],
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
                    ? '서로 같은 수까지 맞춰 무승부입니다.'
                    : (isWinner ? '빠른 스와이프로 승리했어요!' : '다음엔 더 빠르게 스와이프해봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '${_progress[_myPlayerIndex]}/$_totalArrows',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '${_progress[1 - _myPlayerIndex]}/$_totalArrows',
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

  void _showExitDialog(GameTheme theme) {
    // 결과 화면에서는 패배 처리 경고 없이 바로 나가기
    if (_status == ArrowdashGameStatus.finished) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    if (!widget.isRanked && _status == ArrowdashGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    final isRankedWaiting =
        widget.isRanked &&
        (_status == ArrowdashGameStatus.idle ||
            _status == ArrowdashGameStatus.searching ||
            _status == ArrowdashGameStatus.matched);

    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    if (_status == ArrowdashGameStatus.searching) {
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

/// 두 플레이어의 진행 상황을 보여주는 레이스 트랙(부드럽게 차오르는 바 + 아바타 마커).
class _RaceLane extends StatelessWidget {
  final String name;
  final double value;
  final String valueText;
  final Color color;
  final bool highlight;

  const _RaceLane({
    required this.name,
    required this.value,
    required this.valueText,
    required this.color,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : String.fromCharCode(name.runes.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: highlight ? CandyColors.ink : CandyColors.inkSoft,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              valueText,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 30,
          child: LayoutBuilder(
            builder: (context, box) {
              const m = 26.0;
              final w = box.maxWidth;
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: value.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) {
                  final fillW = ((w - m) * v + m / 2).clamp(0.0, w);
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 7,
                        height: 16,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: CandyColors.ink,
                              width: 2.5,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 7,
                        height: 16,
                        width: fillW,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: CandyColors.ink,
                              width: 2.5,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: (w - m) * v,
                        top: 2,
                        child: Container(
                          width: m,
                          height: m,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: CandyColors.ink,
                              width: 2.5,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: CandyColors.ink,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            initial,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
