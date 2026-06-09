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

enum RpsGameStatus {
  idle,
  searching,
  matched,
  playing,
  finished,
}

enum RpsChoice {
  rock,
  paper,
  scissors,
}

class RpsScreen extends StatefulWidget {
  final bool isRanked;

  const RpsScreen({super.key, this.isRanked = false});

  @override
  State<RpsScreen> createState() => _RpsScreenState();
}

class _RpsScreenState extends State<RpsScreen> with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;  // 중복 pop 방지
  bool _isExitDialogOpen = false;  // 나가기 다이얼로그 열림 상태

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
  int _reconnectSecondsRemaining = GameReconnectHelper.reconnectGraceDuration.inSeconds;

  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  // 타이머
  Timer? _countdownTimer;
  int _remainingSeconds = 10;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.9).animate(
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
      debugPrint('🎮 RpsScreen _initFromGameProvider: isInvitation=${game.isInvitationGame}, roomId=${game.roomId}, opponentNickname=${game.opponentNickname}, status=${game.status}');
      final isActiveInvitation = game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched || game.status == GameStatus.playing);
      if (isActiveInvitation) {
        debugPrint('🎮 RpsScreen: 초대 게임 초기화 from GameProvider');
        setState(() {
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
    _animController.dispose();
    _socketListeners.offAll();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != RpsGameStatus.idle &&
      _status != RpsGameStatus.searching &&
      _status != RpsGameStatus.finished;

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
              _reset();
            },
          );
        },
      );
    });

    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = RpsGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.cast<Map<String, dynamic>?>().firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = RpsGameStatus.matched;
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
        setState(() {
          _status = RpsGameStatus.playing;
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
      setState(() {
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
        setState(() => _opponentChosen = true);
      }
    });

    _socketListeners.on('rps_round_result', (data) {
      _stopCountdown();
      setState(() {
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
      setState(() {
        _waitingForResult = false;
      });
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'rps') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
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
      if (_status == RpsGameStatus.finished) return;
      _stopCountdown();
      setState(() {
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
      if (_status == RpsGameStatus.idle ||
          _status == RpsGameStatus.searching ||
          _status == RpsGameStatus.finished) {
        return;
      }
      // 나가기 다이얼로그가 열려있으면 먼저 닫기
      if (_isExitDialogOpen && mounted) {
        Navigator.of(context).pop();
        _isExitDialogOpen = false;
      }
      setState(() {
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
      'gameType': AppConfig.gameTypeRps,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = RpsGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeRps,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = RpsGameStatus.idle);
  }

  void _makeChoice(RpsChoice choice) {
    if (_myChoice != null || _roomId == null) return;

    setState(() {
      _myChoice = choice;
      _waitingForResult = _opponentChosen;
    });

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {
        'choice': choice.name,
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
    _waitingReconnectTimer?.cancel();
    setState(() {
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
                  transitionKey: '${_status.name}-$_currentRound-${_myChoice?.name ?? 'none'}-${_lastWinnerIndex ?? -1}-$_lastIsDraw',
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
      RpsGameStatus.idle => widget.isRanked ? _buildRankedWaitingView(theme) : _buildIdleView(theme),
      RpsGameStatus.searching => widget.isRanked ? _buildRankedWaitingView(theme) : _buildSearchingView(theme),
      RpsGameStatus.matched => widget.isRanked ? _buildRankedWaitingView(theme) : _buildMatchedView(theme),
      RpsGameStatus.playing => _buildPlayingView(theme),
      RpsGameStatus.finished => _buildFinishedView(theme),
    };
  }

  void _showFriendInviteDialog(BuildContext context) {
    // 친구 목록 새로고침
    context.read<FriendProvider>().getFriends();

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
                      const Icon(Icons.person_add, color: Color(0xFF9B59B6)),
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
                                    backgroundColor: const Color(0xFF9B59B6).withValues(alpha: 0.2),
                                    child: Text(
                                      friend.nickname.isNotEmpty ? friend.nickname[0].toUpperCase() : '?',
                                      style: const TextStyle(color: Color(0xFF9B59B6)),
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
                                    AppConfig.gameTypeRps,
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
                                  backgroundColor: const Color(0xFF9B59B6),
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
      backgroundGradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x1A9B59B6), Colors.white],
      ),
      accentColor: const Color(0xFF9B59B6),
      emoji: '✊✌️✋',
      title: '가위바위보',
      descriptions: const ['3판 2선승'],
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
            const Color(0xFF9B59B6).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              color: Color(0xFF9B59B6),
            ),
            const SizedBox(height: 24),
            const Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9B59B6),
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
            const Color(0xFF9B59B6).withValues(alpha: 0.1),
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
                color: Color(0xFFE8DAEF),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.sports_esports,
                size: 64,
                color: Color(0xFF9B59B6),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9B59B6),
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
    final bool showResult = _lastPlayer0Choice != null && _lastPlayer1Choice != null;

    return Column(
      children: [
        // 프로필 & 점수판
        GameDuelHeader(
          backgroundColors: const [Color(0xFFF5EEF8), Color(0xFFEDE7F6)],
          accentColor: const Color(0xFF9B59B6),
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
          myExtraWidget: _buildScoreWidget(_scores[_myPlayerIndex], true),
          opponentExtraWidget: _buildScoreWidget(_scores[1 - _myPlayerIndex], false),
        ),

        // 게임 영역
        Expanded(
          child: _currentRound == 0
              ? _buildWaitingForRoundView()
              : (showResult ? _buildResultView() : _buildChoiceView()),
        ),
      ],
    );
  }

  Widget _buildScoreWidget(int score, bool isMe) {
    return GameHeaderScorePill(
      score: score,
      color: isMe ? const Color(0xFF9B59B6) : Colors.grey,
    );
  }

  Widget _buildWaitingForRoundView() {
    return Center(
      child: GameStagePanel(
        icon: Icons.back_hand_rounded,
        title: '준비 중...',
        subtitle: '첫 선택 창을 열고 상대 상태를 맞추고 있습니다.',
        accentColor: const Color(0xFF9B59B6),
        content: const SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            color: Color(0xFF9B59B6),
            strokeWidth: 3,
          ),
        ),
      ),
    );
  }

  Widget _buildChoiceView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 타이머
        GameTimerBadge(
          seconds: _remainingSeconds,
          label: '선택 남은 시간',
          accentColor: const Color(0xFF9B59B6),
        ),
        const SizedBox(height: 24),

        // 상대 상태
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: _opponentChosen ? Colors.green.shade50 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _opponentChosen ? Colors.green : Colors.grey.shade300,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _opponentChosen ? Icons.check_circle : Icons.hourglass_empty,
                color: _opponentChosen ? Colors.green : Colors.grey,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                _opponentChosen ? '$_opponentNickname 선택 완료!' : '$_opponentNickname 선택 중...',
                style: TextStyle(
                  color: _opponentChosen ? Colors.green.shade700 : Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),

        // 내 선택 상태 또는 선택 버튼
        if (_myChoice != null)
          Column(
            children: [
              Text(
                _getChoiceEmoji(_myChoice!),
                style: const TextStyle(fontSize: 80),
              ),
              const SizedBox(height: 16),
              Text(
                '${_getChoiceName(_myChoice!)} 선택!',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF9B59B6),
                ),
              ),
              if (_waitingForResult || !_opponentChosen) ...[
                const SizedBox(height: 16),
                Text(
                  '상대방 대기 중...',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ],
            ],
          )
        else
          Column(
            children: [
              const Text(
                '선택하세요!',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF9B59B6),
                ),
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildChoiceButton(RpsChoice.rock),
                  _buildChoiceButton(RpsChoice.scissors),
                  _buildChoiceButton(RpsChoice.paper),
                ],
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildChoiceButton(RpsChoice choice) {
    return GestureDetector(
      onTapDown: (_) => _animController.forward(),
      onTapUp: (_) {
        _animController.reverse();
        _makeChoice(choice);
      },
      onTapCancel: () => _animController.reverse(),
      child: AnimatedBuilder(
        animation: _scaleAnim,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnim.value,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF9B59B6).withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  _getChoiceEmoji(choice),
                  style: const TextStyle(fontSize: 48),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildResultView() {
    final myChoice = _myPlayerIndex == 0 ? _lastPlayer0Choice : _lastPlayer1Choice;
    final opponentChoice = _myPlayerIndex == 0 ? _lastPlayer1Choice : _lastPlayer0Choice;
    final isMyWin = _lastWinnerIndex == _myPlayerIndex;
    final isOpponentWin = _lastWinnerIndex == (1 - _myPlayerIndex);

    return Column(
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
          accentColor: _lastIsDraw ? Colors.orange : (isMyWin ? Colors.green : Colors.red),
          compact: true,
        ),
        const SizedBox(height: 28),

        // 선택 비교
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 내 선택
            Column(
              children: [
                Text(
                  _getChoiceEmojiFromString(myChoice),
                  style: const TextStyle(fontSize: 64),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isMyWin ? Colors.green : (_lastIsDraw ? Colors.orange : Colors.red),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '나',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 40),
            const Text(
              'VS',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(width: 40),
            // 상대 선택
            Column(
              children: [
                Text(
                  _getChoiceEmojiFromString(opponentChoice),
                  style: const TextStyle(fontSize: 64),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isOpponentWin ? Colors.green : (_lastIsDraw ? Colors.orange : Colors.red),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _opponentNickname ?? '상대',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 32),
        Text(
          '다음 라운드 준비 중...',
          style: TextStyle(color: Colors.grey.shade600),
        ),
      ],
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
      resultColor = const Color(0xFF9B59B6);
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
                    ? '끝까지 쉽게 예측할 수 없는 승부였어요.'
                    : (isWinner ? '이번 판은 선택 타이밍이 좋았어요.' : '상대의 흐름을 읽어 다음 판을 노려봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '${_scores[_myPlayerIndex]}',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '${_scores[1 - _myPlayerIndex]}',
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
              accentColor: const Color(0xFF9B59B6),
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
    if (!widget.isRanked && _status == RpsGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting = widget.isRanked &&
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
      accentColor: const Color(0xFF9B59B6),
      message: isRankedWaiting
          ? '랭크전 진행 중입니다.\n나가시겠습니까?'
          : '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
      onExit: _leaveGame,
    ).then((_) => _isExitDialogOpen = false);
  }
}
