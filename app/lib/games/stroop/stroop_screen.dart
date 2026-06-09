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

enum StroopGameStatus {
  idle,
  searching,
  matched,
  playing,
  waiting,
  finished,
}

class StroopScreen extends StatefulWidget {
  final bool isRanked;

  const StroopScreen({super.key, this.isRanked = false});

  @override
  State<StroopScreen> createState() => _StroopScreenState();
}

class _StroopScreenState extends State<StroopScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accent =>
      GameTheme.fromProfileSettings(context.read<ShopProvider>().profileSettings).primary;
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;  // 중복 pop 방지
  bool _isExitDialogOpen = false;  // 나가기 다이얼로그 열림 상태

  StroopGameStatus _status = StroopGameStatus.idle;

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
  String _currentWord = '';
  String _currentColor = '';
  int _currentRound = 0;
  List<int> _scores = [0, 0];
  bool _isHardcore = false;
  List<String> _colors = ['red', 'blue', 'green', 'yellow'];

  // 결과
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

  // 연승 정보
  int _myStreak = 0;
  int _opponentStreak = 0;

  // 하드코어 타이머
  Timer? _hardcoreTimer;
  int _remainingTime = 2;

  // 색상 매핑
  static const Map<String, Color> colorValues = {
    'red': Color(0xFFE74C3C),
    'blue': Color(0xFF3498DB),
    'green': Color(0xFF2ECC71),
    'yellow': Color(0xFFF1C40F),
    'orange': Color(0xFFE67E22),
    'purple': Color(0xFF9B59B6),
  };

  static const Map<String, String> colorNames = {
    'red': '빨강',
    'blue': '파랑',
    'green': '초록',
    'yellow': '노랑',
    'orange': '주황',
    'purple': '보라',
  };

  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.elasticOut),
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
      debugPrint('🎮 StroopScreen _initFromGameProvider: isInvitation=${game.isInvitationGame}, roomId=${game.roomId}, opponentNickname=${game.opponentNickname}, status=${game.status}');
      // GameProvider의 status가 matched 또는 playing일 때만 초대 게임으로 인식
      // (이전 게임 상태가 남아있는 경우 방지)
      final isActiveInvitation = game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched || game.status == GameStatus.playing);
      if (isActiveInvitation) {
        debugPrint('🎮 StroopScreen: 초대 게임 초기화 from GameProvider');
        setState(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = StroopGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 StroopScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _hardcoreTimer?.cancel();
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _animController.dispose();
    _socketListeners.offAll();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != StroopGameStatus.idle &&
      _status != StroopGameStatus.searching &&
      _status != StroopGameStatus.finished;

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
      _hardcoreTimer?.cancel();
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
              _hardcoreTimer?.cancel();
              _reset();
            },
          );
        },
      );
    });

    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = StroopGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.cast<Map<String, dynamic>?>().firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = StroopGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        _isHardcore = data['isHardcore'] == true;
        // 연승 정보
        _myStreak = me != null ? (me['streak'] ?? 0) : 0;
        _opponentStreak = opponent['streak'] ?? 0;
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
      debugPrint('game_start received: $data');
      if (data['gameType'] == 'stroop') {
        if (data['players'] != null) {
          final players = data['players'] as List;
          final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
          if (updatedIndex != -1) {
            _myPlayerIndex = updatedIndex;
          }
        }
        // finished 상태에서 재경기 요청 안 했으면 무시
        if (_status == StroopGameStatus.finished && !_rematchWaiting) {
          debugPrint('game_start ignored: not waiting for rematch');
          return;
        }
        // 게임 시작 시 모든 SnackBar 제거 (중복 알림 방지)
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
        }
        setState(() {
          _isHardcore = data['isHardcore'] ?? false;
          _colors = List<String>.from(data['colors'] ?? ['red', 'blue', 'green', 'yellow']);
          _scores = [0, 0];
          _currentRound = 0;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
        });
      }
    });

    _socketListeners.on('stroop_show', (data) {
      debugPrint('🎨 stroop_show received: $data');
      debugPrint('🎨 current status: $_status, mounted: $mounted');

      if (!mounted) return;

      setState(() {
        _currentWord = data['word'];
        _currentColor = data['color'];
        _currentRound = data['round'];
        _scores = List<int>.from(data['scores'] ?? [0, 0]);
        _isHardcore = data['isHardcore'] ?? false;
        if (data['colors'] != null) {
          _colors = List<String>.from(data['colors']);
        }
        _status = StroopGameStatus.playing;
        _isWaitingForReconnect = false;
      });

      debugPrint('🎨 status changed to: $_status');

      // 애니메이션 시작
      _animController.reset();
      _animController.forward();

      // 하드코어 모드 타이머 시작
      if (_isHardcore) {
        _startHardcoreTimer((data['remainingTimeMs'] as num?)?.toInt() ?? 2000);
      }
    });

    _socketListeners.on('stroop_result', (data) {
      debugPrint('🎨 stroop_result received: $data');

      if (!mounted) return;

      _hardcoreTimer?.cancel();
      final winnerId = data['winnerId'];
      final scores = List<int>.from(data['scores'] ?? [0, 0]);
      final pressedPlayerId = data['pressedPlayerId'];
      final isCorrect = data['correct'] as bool? ?? false;

      setState(() {
        _scores = scores;
        _status = StroopGameStatus.waiting;
        _isWaitingForReconnect = false;
      });

      debugPrint('🎨 status changed to waiting, scores: $_scores');

      // 결과 스낵바 표시
      if (mounted) {
        final isMyWin = winnerId == _myId;
        final iMadeAction = pressedPlayerId == _myId;
        final correctAnswer = data['correctAnswer'] as String;

        String message;
        Color bgColor;

        if (isMyWin) {
          if (iMadeAction && isCorrect) {
            // 내가 정답을 맞춰서 점수 획득
            message = '정답! 점수 획득';
            bgColor = Colors.green;
          } else {
            // 상대가 틀려서 내가 점수 획득
            message = '상대 오답! 점수 획득';
            bgColor = Colors.teal;
          }
        } else {
          if (iMadeAction) {
            // 내가 틀림
            message = '오답... 정답: ${colorNames[correctAnswer] ?? correctAnswer}';
            bgColor = Colors.red;
          } else {
            // 상대가 정답을 맞춤
            message = '상대 정답! 정답: ${colorNames[correctAnswer] ?? correctAnswer}';
            bgColor = Colors.orange;
          }
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message, textAlign: TextAlign.center),
            backgroundColor: bgColor,
            duration: const Duration(seconds: 1),
          ),
        );
      }
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'stroop') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      final roundState = data['roundState'] as String?;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _currentRound = (data['round'] as num?)?.toInt() ?? _currentRound;
        _scores = List<int>.from(data['scores'] ?? _scores);
        _currentWord = data['word'] as String? ?? _currentWord;
        _currentColor = data['color'] as String? ?? _currentColor;
        _isHardcore = data['isHardcore'] == true;
        _colors = List<String>.from(data['colors'] ?? _colors);
        _status = roundState == 'showing'
            ? StroopGameStatus.playing
            : StroopGameStatus.waiting;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      if (data['isHardcore'] == true && roundState == 'showing') {
        _startHardcoreTimer((data['remainingTimeMs'] as num?)?.toInt() ?? 2000);
      } else {
        _hardcoreTimer?.cancel();
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
          _hardcoreTimer?.cancel();
          _reset();
        },
        message: '20초 안에 연결을 복구하지 못해 게임에서 제외되었습니다.',
      );
    });

    _socketListeners.on('opponent_disconnected', (_) {
      if (!_isGameActive) return;
      _hardcoreTimer?.cancel();
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
      if (_status == StroopGameStatus.finished) return;
      debugPrint('🎨 StroopScreen game_end received: $data');
      _hardcoreTimer?.cancel();
      setState(() {
        _status = StroopGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        _scores = List<int>.from(data['scores'] ?? [0, 0]);
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      _waitingReconnectTimer?.cancel();
      debugPrint('🎨 StroopScreen status changed to finished');
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == StroopGameStatus.idle ||
          _status == StroopGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == StroopGameStatus.finished) {
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
      _hardcoreTimer?.cancel();
      setState(() {
        _status = StroopGameStatus.finished;
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
      beforeNavigate: () => _hardcoreTimer?.cancel(),
    );
  }

  void _startHardcoreTimer([int remainingTimeMs = 2000]) {
    _hardcoreTimer?.cancel();
    _remainingTime = (remainingTimeMs / 1000).ceil();
    _hardcoreTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_remainingTime > 0) {
        setState(() => _remainingTime--);
      } else {
        timer.cancel();
      }
    });
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeStroop,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = StroopGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeStroop,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = StroopGameStatus.idle);
  }

  void _selectColor(String color) {
    if (_status != StroopGameStatus.playing || _roomId == null) return;

    _hardcoreTimer?.cancel();
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'selectedColor': color},
    });

    setState(() => _status = StroopGameStatus.waiting);
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
    _hardcoreTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    setState(() {
      _status = StroopGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _currentWord = '';
      _currentColor = '';
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
              title: '스트룹 테스트',
              backgroundColor: theme.primary,
              onBack: () => _showExitDialog(theme),
            ),
            body: Stack(
              children: [
                GameScreenTransition(
                  transitionKey: '${_status.name}-$_currentRound-$_currentWord-$_currentColor-${_winnerId ?? 'none'}-$_isDraw',
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
      icon: Icons.palette,
      title: '스트룹 준비 중',
      subtitle: '다음 라운드를 시작할 준비를 하고 있습니다.',
      statusMessages: const [
        '색상 카드와 단어 조합을 준비하고 있습니다.',
        '하드코어 타이머를 맞추고 있습니다.',
        '상대와 현재 점수를 동기화하고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      StroopGameStatus.idle => widget.isRanked ? _buildRankedWaitingView(theme) : _buildIdleView(theme),
      StroopGameStatus.searching => widget.isRanked ? _buildRankedWaitingView(theme) : _buildSearchingView(theme),
      StroopGameStatus.matched => widget.isRanked ? _buildRankedWaitingView(theme) : _buildMatchedView(theme),
      StroopGameStatus.playing => _buildPlayingView(theme),
      StroopGameStatus.waiting => _buildWaitingView(theme),
      StroopGameStatus.finished => _buildFinishedView(theme),
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
                                    AppConfig.gameTypeStroop,
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

  Widget _buildIdleView(GameTheme theme) {
    final accent = _isHardcore ? Colors.red : theme.primary;
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: accent,
      icon: Icons.palette,
      title: '스트룹 테스트',
      descriptions: const ['글자가 아닌 색깔을 맞추세요!', '예: "빨강"이 파란색이면 → 파랑 선택'],
      findMatchLabel: _isHardcore ? '하드코어 상대 찾기' : '상대 찾기',
      onFindMatch: _findMatch,
      onInviteFriend: () => _showFriendInviteDialog(context),
      extra: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text('빨강', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: colorValues['blue'])),
                const SizedBox(height: 4),
                Text('정답: 파랑 (글자색)', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          GameHardcoreToggle(
            value: _isHardcore,
            onChanged: (v) => setState(() => _isHardcore = v),
            activeHint: '6색 + 2초 제한!',
          ),
        ],
      ),
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
            const SizedBox(height: 16),
            // 연승 정보 표시
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildStreakBadge('나', _myStreak, true),
                const SizedBox(width: 24),
                const Text(
                  'VS',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(width: 24),
                _buildStreakBadge(_opponentNickname ?? '상대', _opponentStreak, false),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '게임이 곧 시작됩니다...',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreakBadge(String name, int streak, bool isMe) {
    final color = isMe ? _accent : Colors.orange;
    return Column(
      children: [
        Text(
          name.length > 6 ? '${name.substring(0, 6)}...' : name,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.grey.shade700,
          ),
        ),
        const SizedBox(height: 4),
        if (streak > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_fire_department, size: 16, color: color),
                const SizedBox(width: 4),
                Text(
                  '$streak연승 중',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '연승 없음',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade500,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPlayingView(GameTheme theme) {
    final wordKorean = colorNames[_currentWord] ?? _currentWord;
    final displayColor = colorValues[_currentColor] ?? Colors.black;

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
                  _accent.withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 하드코어 타이머
                if (_isHardcore)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: GameTimerBadge(
                      seconds: _remainingTime,
                      label: '정답 입력 시간',
                      accentColor: _accent,
                      compact: true,
                      warningThreshold: 1,
                    ),
                  ),
                // 색상 단어 표시
                ScaleTransition(
                  scale: _scaleAnimation,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: displayColor.withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Text(
                      wordKorean,
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: displayColor,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '글자의 색깔을 선택하세요!',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 32),
                // 색상 버튼들
                _buildColorButtons(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildColorButtons() {
    final buttonColors = _colors;
    final crossAxisCount = _isHardcore ? 3 : 2;
    final horizontalPadding = _isHardcore ? 16.0 : 32.0;
    final aspectRatio = _isHardcore ? 1.8 : 2.5;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: GridView.count(
        shrinkWrap: true,
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: aspectRatio,
        children: buttonColors.map((color) {
          return _buildColorButton(color, isHardcore: _isHardcore);
        }).toList(),
      ),
    );
  }

  Widget _buildColorButton(String color, {bool isHardcore = false}) {
    final buttonColor = colorValues[color] ?? Colors.grey;
    final buttonName = colorNames[color] ?? color;
    final fontSize = isHardcore ? 14.0 : 18.0;

    return ElevatedButton(
      onPressed: () => _selectColor(color),
      style: ElevatedButton.styleFrom(
        backgroundColor: buttonColor,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(
          horizontal: isHardcore ? 4 : 8,
          vertical: isHardcore ? 4 : 8,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 4,
        shadowColor: buttonColor.withValues(alpha: 0.5),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          buttonName,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingView(GameTheme theme) {
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
                  _accent.withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
            child: Center(
              child: GameStagePanel(
                icon: Icons.palette_outlined,
                title: '다음 라운드 대기 중...',
                subtitle: '상대 입력과 결과를 정리한 뒤 바로 이어서 시작합니다.',
                accentColor: _accent,
                content: SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(
                    color: _accent,
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
      backgroundColors: const [Color(0xFFE0F7FA), Color(0xFFB2EBF2)],
      accentColor: _accent,
      centerLabel: 'R$_currentRound',
      centerSubtitle: _isHardcore ? '하드코어' : '색깔 대결',
      myName: _myNickname ?? '나',
      opponentName: _opponentNickname ?? '상대',
      myAvatarUrl: _myAvatarUrl,
      opponentAvatarUrl: _opponentAvatarUrl,
      myActive: true,
      opponentActive: false,
      myProfileSettings: _myProfileSettings,
      opponentProfileSettings: _opponentProfileSettings,
      myExtraWidget: _buildScoreWidget(_scores.isNotEmpty ? _scores[_myPlayerIndex] : 0, true),
      opponentExtraWidget: _buildScoreWidget(_scores.length > 1 ? _scores[1 - _myPlayerIndex] : 0, false),
    );
  }

  Widget _buildScoreWidget(int score, bool isMe) {
    return GameHeaderScorePill(
      score: score,
      color: isMe ? _accent : Colors.grey,
      margin: const EdgeInsets.only(top: 4),
    );
  }

  Widget _buildFinishedView(GameTheme theme) {
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
                  ? '색과 단어를 끝까지 집중해서 맞붙었어요.'
                  : (isWinner ? '빠른 판단과 집중력이 잘 이어졌어요.' : '다음 판은 색상 전환 타이밍에 더 집중해봐요.'),
            ),
            const SizedBox(height: 22),
            GameResultMatchupRow(
              leftLabel: '나',
              leftValue: '${_scores.isNotEmpty ? _scores[_myPlayerIndex] : 0}',
              rightLabel: _opponentNickname ?? '상대',
              rightValue: '${_scores.length > 1 ? _scores[1 - _myPlayerIndex] : 0}',
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

  void _showExitDialog(GameTheme theme) {
    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && _status == StroopGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting = widget.isRanked &&
        (_status == StroopGameStatus.idle ||
            _status == StroopGameStatus.searching ||
            _status == StroopGameStatus.matched);

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (_status == StroopGameStatus.searching) {
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
