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
import '../common/game_stage_panel.dart';
import '../common/game_timer_badge.dart';
import '../common/game_waiting_view.dart';

enum SpeedTapGameStatus {
  idle,
  searching,
  matched,
  playing,
  finished,
}

class SpeedTapScreen extends StatefulWidget {
  final bool isRanked;

  const SpeedTapScreen({super.key, this.isRanked = false});

  @override
  State<SpeedTapScreen> createState() => _SpeedTapScreenState();
}

class _SpeedTapScreenState extends State<SpeedTapScreen> with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accent =>
      GameTheme.fromProfileSettings(context.read<ShopProvider>().profileSettings).primary;
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;  // 중복 pop 방지
  bool _isExitDialogOpen = false;  // 나가기 다이얼로그 열림 상태

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
  int _reconnectSecondsRemaining = GameReconnectHelper.reconnectGraceDuration.inSeconds;

  // 타이머
  Timer? _countdownTimer;
  int _remainingSeconds = 10;
  int _preRoundCountdown = 0; // 3-2-1 카운트다운
  Timer? _startCountdownTimer;

  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 50),
      vsync: this,
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
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
      debugPrint('🎮 SpeedTapScreen _initFromGameProvider: isInvitation=${game.isInvitationGame}, roomId=${game.roomId}, opponentNickname=${game.opponentNickname}, status=${game.status}');
      final isActiveInvitation = game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched || game.status == GameStatus.playing);
      if (isActiveInvitation) {
        debugPrint('🎮 SpeedTapScreen: 초대 게임 초기화 from GameProvider');
        setState(() {
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
    _animController.dispose();
    _socketListeners.offAll();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != SpeedTapGameStatus.idle &&
      _status != SpeedTapGameStatus.searching &&
      _status != SpeedTapGameStatus.finished;

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    _remainingSeconds = seconds;
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

  void _startWaitingReconnectCountdown() {
    _waitingReconnectTimer?.cancel();
    _waitingReconnectTimer = GameReconnectHelper.startVisualCountdown(
      onTick: (seconds) {
        if (!mounted || !_isWaitingForReconnect) return;
        setState(() => _reconnectSecondsRemaining = seconds);
      },
    );
  }

  void _runStartCountdown(int from) {
    _startCountdownTimer?.cancel();
    _preRoundCountdown = from;
    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_preRoundCountdown > 1) {
        setState(() => _preRoundCountdown--);
      } else {
        timer.cancel();
        setState(() => _preRoundCountdown = 0);
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
              _stopCountdown();
              _startCountdownTimer?.cancel();
              _reset();
            },
          );
        },
      );
    });

    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = SpeedTapGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.cast<Map<String, dynamic>?>().firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = SpeedTapGameStatus.matched;
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
        setState(() {
          _status = SpeedTapGameStatus.playing;
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
      setState(() {
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
      final duration = data['duration'] as int? ?? 10000;
      setState(() {
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
      setState(() {
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
      setState(() {
        _taps = List<int>.from(data['taps']);
      });
    });

    _socketListeners.on('speedtap_round_result', (data) {
      _stopCountdown();
      setState(() {
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
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
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
      if (_status == SpeedTapGameStatus.finished) return;
      _stopCountdown();
      setState(() {
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
        setState(() {
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
      setState(() {
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

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeSpeedTap,
      'isHardcore': false,
    });
    setState(() => _status = SpeedTapGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeSpeedTap,
      'isHardcore': false,
    });
    setState(() => _status = SpeedTapGameStatus.idle);
  }

  void _tap() {
    if (!_roundInProgress || _roomId == null) return;

    _animController.forward().then((_) => _animController.reverse());

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'tap'},
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
    setState(() {
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
                  transitionKey: '${_status.name}-$_currentRound-$_preRoundCountdown-$_roundInProgress-${_lastWinnerIndex ?? -1}-$_lastIsDraw',
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
      SpeedTapGameStatus.idle => widget.isRanked ? _buildRankedWaitingView(theme) : _buildIdleView(theme),
      SpeedTapGameStatus.searching => widget.isRanked ? _buildRankedWaitingView(theme) : _buildSearchingView(theme),
      SpeedTapGameStatus.matched => widget.isRanked ? _buildRankedWaitingView(theme) : _buildMatchedView(theme),
      SpeedTapGameStatus.playing => _buildPlayingView(theme),
      SpeedTapGameStatus.finished => _buildFinishedView(theme),
    };
  }

  void _showFriendInviteDialog(BuildContext context) {
    // 친구 목록 새로고침
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
                      Icon(Icons.person_add, color: theme.primary),
                      const SizedBox(width: 12),
                      const Text(
                        '친구 초대',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
                                    backgroundColor: theme.primary.withValues(alpha: 0.2),
                                    child: Text(
                                      friend.nickname.isNotEmpty ? friend.nickname[0].toUpperCase() : '?',
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
                                    AppConfig.gameTypeSpeedTap,
                                    isHardcore: false,
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
                SizedBox(height: MediaQuery.of(dialogContext).padding.bottom + 16),
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
      accentColor: theme.primary,
      icon: Icons.touch_app,
      title: '스피드 탭',
      descriptions: const ['10초 동안 빠르게 터치!', '3라운드 중 2라운드 승리!'],
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
            _accent.withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: _accent,
            ),
            const SizedBox(height: 24),
            Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: _accent,
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
            _accent.withValues(alpha: 0.1),
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
              decoration: const BoxDecoration(
                color: Color(0xFFE0F7FA),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sports_esports,
                size: 64,
                color: _accent,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: _accent,
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
    final bool showResult = _lastPlayer0Taps != null && !_roundInProgress;

    return Column(
      children: [
        // 프로필 & 점수판
        GameDuelHeader(
          backgroundColors: const [Color(0xFFE0F7FA), Color(0xFFF0FAFA)],
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
          myExtraWidget: _buildTapScoreWidget(_taps[_myPlayerIndex], _roundScores[_myPlayerIndex], true),
          opponentExtraWidget: _buildTapScoreWidget(_taps[1 - _myPlayerIndex], _roundScores[1 - _myPlayerIndex], false),
        ),

        // 게임 영역
        Expanded(
          child: _preRoundCountdown > 0
              ? _buildCountdownView()
              : (showResult ? _buildResultView() : _buildTapView()),
        ),
      ],
    );
  }

  Widget _buildTapScoreWidget(int tapCount, int roundWins, bool isMe) {
    return Column(
      children: [
        GameHeaderScorePill(
          score: tapCount,
          color: isMe ? _accent : Colors.grey,
        ),
        const SizedBox(height: 2),
        GameHeaderStarTrack(
          total: 2,
          active: roundWins,
          activeColor: Colors.amber,
        ),
      ],
    );
  }

  Widget _buildCountdownView() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _accent.withValues(alpha: 0.3),
            _accent.withValues(alpha: 0.1),
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '준비!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: _accent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.5),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  '$_preRoundCountdown',
                  style: const TextStyle(
                    fontSize: 64,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '터치 준비하세요!',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTapView() {
    return GestureDetector(
      onTapDown: (_) => _tap(),
      child: AnimatedBuilder(
        animation: _scaleAnim,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnim.value,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _accent.withValues(alpha: 0.3),
                    _accent.withValues(alpha: 0.6),
                  ],
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 타이머
                    GameTimerBadge(
                      seconds: _remainingSeconds,
                      label: '탭 남은 시간',
                      accentColor: _accent,
                      showLabel: false,
                    ),
                    const SizedBox(height: 40),
                    // 탭 아이콘
                    Container(
                      padding: const EdgeInsets.all(40),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.touch_app,
                        size: 80,
                        color: _accent.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '터치!',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
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

  Widget _buildResultView() {
    final myTaps = _myPlayerIndex == 0 ? _lastPlayer0Taps : _lastPlayer1Taps;
    final opponentTaps = _myPlayerIndex == 0 ? _lastPlayer1Taps : _lastPlayer0Taps;
    final isMyWin = _lastWinnerIndex == _myPlayerIndex;
    final isOpponentWin = _lastWinnerIndex == (1 - _myPlayerIndex);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            (_lastIsDraw ? Colors.orange : (isMyWin ? Colors.green : Colors.red)).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GameStagePanel(
            icon: _lastIsDraw
                ? Icons.handshake_rounded
                : (isMyWin ? Icons.flash_on_rounded : Icons.timer_off_rounded),
            title: _lastIsDraw ? '무승부!' : (isMyWin ? '라운드 승리!' : '라운드 패배'),
            subtitle: '탭 수를 집계했고, 다음 라운드로 넘어갈 준비를 하고 있어요.',
            accentColor: _lastIsDraw ? Colors.orange : (isMyWin ? Colors.green : Colors.red),
            compact: true,
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Column(
                children: [
                  Text(
                    '$myTaps',
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: isMyWin ? Colors.green : Colors.grey,
                    ),
                  ),
                  const Text('나', style: TextStyle(fontSize: 16)),
                ],
              ),
              const SizedBox(width: 40),
              const Text(':', style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
              const SizedBox(width: 40),
              Column(
                children: [
                  Text(
                    '$opponentTaps',
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: isOpponentWin ? Colors.green : Colors.grey,
                    ),
                  ),
                  Text(_opponentNickname ?? '상대', style: const TextStyle(fontSize: 16)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 32),
          Text('다음 라운드 준비 중...', style: TextStyle(color: Colors.grey.shade600)),
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
      resultColor = Colors.orange;
      resultIcon = Icons.handshake;
    } else if (isWinner) {
      resultText = '승리!';
      resultColor = _accent;
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
                    ? '세 라운드 내내 팽팽하게 맞붙었어요.'
                    : (isWinner ? '손끝 집중력이 끝까지 이어졌어요.' : '다음 판은 시작 템포를 더 빠르게 가져가봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '${_roundScores[_myPlayerIndex]}',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '${_roundScores[1 - _myPlayerIndex]}',
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
              accentColor: _accent,
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

  void _showExitDialog(GameTheme theme) {
    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && _status == SpeedTapGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting = widget.isRanked &&
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
