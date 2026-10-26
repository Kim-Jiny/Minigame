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
import '../../widgets/cartoon/cartoon_card.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/pop_in.dart';
import '../common/game_rematch_preparing_view.dart';
import '../common/game_intro_view.dart';
import '../common/game_scaffold.dart';
import '../common/game_duel_header.dart';
import '../common/game_event_helper.dart';
import '../common/game_hardcore_toggle.dart';
import '../common/game_exit_helper.dart';
import '../common/game_reconnect_helper.dart';
import '../common/game_result_action_buttons.dart';
import '../common/game_result_summary.dart';
import '../common/game_screen_transition.dart';
import '../common/game_session_helper.dart';
import '../common/game_waiting_view.dart';

enum NumberBattleGameStatus { idle, searching, matched, playing, finished }

class NumberBattleScreen extends StatefulWidget {
  final bool isRanked;

  const NumberBattleScreen({super.key, this.isRanked = false});

  @override
  State<NumberBattleScreen> createState() => _NumberBattleScreenState();
}

class _NumberBattleScreenState extends State<NumberBattleScreen> {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );
  bool _hasScheduledPop = false;
  bool _isExitDialogOpen = false;

  NumberBattleGameStatus _status = NumberBattleGameStatus.idle;

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
  List<List<int>> _grid = [];
  List<int> _progress = [0, 0]; // 각 플레이어 진행도
  Set<String> _myTappedCells = {}; // 내가 탭한 셀 (row,col) — 일반 모드 dim 표시용
  bool _isHardcore = false; // 하드모드: 1~100, 누른 칸은 +25로 교체
  int get _total => _isHardcore ? 100 : 25; // 목표 숫자

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
          _status = NumberBattleGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🔢 NumberBattleScreen: GameProvider 초기화 실패: $e');
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

  bool get _isGameActive =>
      _status != NumberBattleGameStatus.idle &&
      _status != NumberBattleGameStatus.searching &&
      _status != NumberBattleGameStatus.finished;

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
      setState(() => _status = NumberBattleGameStatus.searching);
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
      _myPlayerIndex = foundIndex < 0 ? 0 : foundIndex;

      setState(() {
        _status = NumberBattleGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        _isHardcore = data['isHardcore'] == true;
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
      if (data['gameType'] != 'numberbattle') return;
      if (data['players'] != null) {
        final players = data['players'] as List;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) {
          _myPlayerIndex = updatedIndex;
        }
      }
      if (_status == NumberBattleGameStatus.finished && !_rematchWaiting) {
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }
      setState(() {
        _status = NumberBattleGameStatus.playing;
        _remainingSeconds = 60; // 재경기 시 이전 게임의 남은 시간 잔상 방지
        _grid = [];
        _progress = [0, 0];
        _myTappedCells = {};
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _opponentLeft = false;
        _isDraw = false;
        _winnerId = null;
      });
    });

    _socketListeners.on('numberbattle_start', (data) {
      final gridData = data['grid'] as List;
      final duration = data['duration'] as int? ?? 60000;
      setState(() {
        _status = NumberBattleGameStatus.playing;
        _isHardcore = data['hardMode'] == true;
        _grid = gridData.map<List<int>>((row) => List<int>.from(row)).toList();
        _progress = [0, 0];
        _myTappedCells = {};
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
    });

    _socketListeners.on('numberbattle_tap', (data) {
      setState(() {
        _progress = List<int>.from(data['progress']);
        final playerIndex = data['playerIndex'] as int;
        // 내 탭만 내 보드에 반영(상대 보드는 별개). 진행도는 둘 다 갱신.
        if (playerIndex == _myPlayerIndex) {
          final row = data['row'] as int;
          final col = data['col'] as int;
          if (_isHardcore) {
            // 누른 칸을 서버가 내려준 다음 숫자(+25, 0이면 빈 칸)로 교체.
            final newNumber = (data['newNumber'] as num?)?.toInt() ?? 0;
            if (row < _grid.length && col < _grid[row].length) {
              _grid[row][col] = newNumber;
            }
          } else {
            _myTappedCells.add('$row,$col');
          }
        }
      });
    });

    _socketListeners.on('numberbattle_timeout', (data) {
      _stopCountdown();
      setState(() {
        _progress = List<int>.from(data['progress']);
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('numberbattle_resumed', (data) {
      final duration = data['duration'] as int? ?? 60000;
      setState(() {
        _status = NumberBattleGameStatus.playing;
        _isHardcore = data['hardMode'] == true;
        // 하드모드는 플레이어별 보드 → grids[내인덱스], 없으면 grid(일반) 폴백.
        final grids = data['grids'] as List?;
        final myGrid = (grids != null && _myPlayerIndex < grids.length)
            ? grids[_myPlayerIndex]
            : data['grid'];
        _grid = (myGrid as List)
            .map<List<int>>((row) => List<int>.from(row))
            .toList();
        _progress = List<int>.from(data['progress']);
        _isWaitingForReconnect = false;
        _restoreTappedCells();
      });
      _startCountdown((duration / 1000).ceil());
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'numberbattle') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      final gridData = data['grid'] as List?;
      final remainingMs = (data['remainingTimeMs'] as num?)?.toInt() ?? 60000;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex =
            (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _isHardcore = data['hardMode'] == true;
        if (gridData != null) {
          _grid = gridData
              .map<List<int>>((row) => List<int>.from(row))
              .toList();
        }
        _progress = List<int>.from(data['progress'] ?? _progress);
        _restoreTappedCells();
        _status = NumberBattleGameStatus.playing;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      _startCountdown((remainingMs / 1000).ceil());
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
      if (_status == NumberBattleGameStatus.finished) return;
      _stopCountdown();
      setState(() {
        _status = NumberBattleGameStatus.finished;
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
      if (_status == NumberBattleGameStatus.idle ||
          _status == NumberBattleGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == NumberBattleGameStatus.finished) {
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
        _status = NumberBattleGameStatus.finished;
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
      'gameType': AppConfig.gameTypeNumberBattle,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = NumberBattleGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeNumberBattle,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = NumberBattleGameStatus.idle);
  }

  // 재접속/재개 시 dim 표시할 탭 완료 셀 복원.
  // 하드모드는 누른 칸이 새 숫자로 교체돼 dim이 없으므로 비운다.
  // 일반 모드는 현재 진행도 이하 숫자 칸을 완료로 표시한다.
  void _restoreTappedCells() {
    _myTappedCells = {};
    if (_isHardcore) return;
    final myProg = _progress[_myPlayerIndex];
    for (int r = 0; r < _grid.length; r++) {
      for (int c = 0; c < _grid[r].length; c++) {
        if (_grid[r][c] <= myProg) {
          _myTappedCells.add('$r,$c');
        }
      }
    }
  }

  /// 정답 칸이면 서버로 전송하고 true, 아니면 false(오답 피드백용).
  bool _tapCell(int row, int col) {
    if (_roomId == null || _grid.isEmpty) return false;
    if (row >= _grid.length || col >= _grid[row].length) return false;
    final targetNumber = _progress[_myPlayerIndex] + 1;
    if (_grid[row][col] != targetNumber) {
      HapticFeedback.lightImpact();
      return false;
    }
    HapticFeedback.selectionClick();

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'tap', 'row': row, 'col': col},
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
      _status = NumberBattleGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _grid = [];
      _progress = [0, 0];
      _myTappedCells = {};
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
              title: '숫자배틀',
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
      icon: Icons.grid_on,
      title: '숫자배틀 준비 중',
      subtitle: '그리드와 타이머를 맞추고 있습니다.',
      statusMessages: const [
        '5x5 그리드를 준비하고 있습니다.',
        '타이머를 동기화하고 있습니다.',
        '상대의 상태를 확인하고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      NumberBattleGameStatus.idle =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildIdleView(theme),
      NumberBattleGameStatus.searching =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildSearchingView(theme),
      NumberBattleGameStatus.matched =>
        widget.isRanked
            ? _buildRankedWaitingView(theme)
            : _buildMatchedView(theme),
      NumberBattleGameStatus.playing => _buildPlayingView(theme),
      NumberBattleGameStatus.finished => _buildFinishedView(theme),
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
                          fontWeight: FontWeight.w900,
                          color: CandyColors.ink,
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
                                const Icon(
                                  Icons.person_off,
                                  size: 48,
                                  color: CandyColors.inkSoft,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '온라인 친구가 없습니다',
                                  style: const TextStyle(
                                    color: CandyColors.inkSoft,
                                    fontWeight: FontWeight.w800,
                                  ),
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
                                        color: CandyColors.mint,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: CandyColors.ink,
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
                                    AppConfig.gameTypeNumberBattle,
                                    isHardcore: _isHardcore,
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
    final accent = _isHardcore ? Colors.red : theme.primary;
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: accent,
      icon: Icons.grid_on,
      title: '숫자배틀',
      descriptions: _isHardcore
          ? const ['1부터 100까지 순서대로 터치!', '누른 칸엔 다음 숫자가 채워져요 (120초 제한)']
          : const ['1부터 25까지 순서대로 터치!', '먼저 완성하면 승리! (60초 제한)'],
      findMatchLabel: _isHardcore ? '하드코어 상대 찾기' : '상대 찾기',
      onFindMatch: _findMatch,
      onInviteFriend: () => _showFriendInviteDialog(context),
      extra: GameHardcoreToggle(
        value: _isHardcore,
        onChanged: (v) => setState(() => _isHardcore = v),
        durationLabel: '(1~100)',
        activeHint: '5x5 보드에서 100까지!',
      ),
    );
  }

  Widget _buildSearchingView(GameTheme theme) {
    return _CandyStatusView(
      accentColor: theme.primary,
      icon: Icons.search_rounded,
      title: '상대를 찾는 중...',
      spinner: true,
      onCancel: _cancelMatch,
    );
  }

  Widget _buildMatchedView(GameTheme theme) {
    return _CandyStatusView(
      accentColor: theme.primary,
      icon: Icons.sports_esports_rounded,
      title: '${_opponentNickname ?? '상대'}님과 매칭!',
      subtitle: '게임이 곧 시작됩니다...',
    );
  }

  Widget _buildPlayingView(GameTheme theme) {
    final accentColor = theme.primary;
    final myProgress = _progress[_myPlayerIndex];
    final opponentProgress = _progress[1 - _myPlayerIndex];

    return Container(
      color: CandyColors.cream,
      child: Column(
        children: [
          GameDuelHeader(
            backgroundColors: [
              accentColor.withValues(alpha: 0.12),
              CandyColors.cream,
            ],
            accentColor: accentColor,
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
              score: myProgress,
              color: accentColor,
            ),
            opponentExtraWidget: GameHeaderScorePill(
              score: opponentProgress,
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
                    myProgress,
                    accentColor,
                    '나',
                    highlight: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildProgressBar(
                    opponentProgress,
                    CandyColors.sky,
                    _opponentNickname ?? '상대',
                  ),
                ),
              ],
            ),
          ),

          // 5x5 그리드
          Expanded(
            child: _grid.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _buildGrid(accentColor),
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
      value: _total <= 0 ? 0 : progress / _total,
      valueText: '$progress/$_total',
      color: color,
      highlight: highlight,
    );
  }

  Widget _buildGrid(Color accentColor) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        const boardPad = 10.0;
        final side = math.min(
          constraints.maxWidth - 32,
          constraints.maxHeight - 24,
        );
        final inner = side - boardPad * 2 - 6 - 5;
        final cellSize = math.max(20.0, (inner - gap * 4) / 5);
        final boardSide = cellSize * 5 + gap * 4;

        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: PopIn(
              child: CartoonCard(
                color: CandyColors.creamDeep,
                radius: 24,
                padding: const EdgeInsets.all(boardPad),
                child: SizedBox(
                  width: boardSide,
                  height: boardSide,
                  child: GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          crossAxisSpacing: gap,
                          mainAxisSpacing: gap,
                        ),
                    itemCount: 25,
                    itemBuilder: (context, index) {
                      final row = index ~/ 5;
                      final col = index % 5;
                      if (row >= _grid.length || col >= _grid[row].length) {
                        return const SizedBox.shrink();
                      }
                      final number = _grid[row][col];
                      final isTapped = _myTappedCells.contains('$row,$col');
                      // 하드모드: 0 = 다 소진된 빈 칸(누른 숫자가 100을 넘어 채울 게 없음).
                      final isEmpty = number == 0;
                      return _NumberTile(
                        number: number,
                        tapped: isTapped,
                        empty: isEmpty,
                        accent: accentColor,
                        size: cellSize,
                        // 다음 숫자 힌트(컬러 강조) 없음 — 모든 미탭·비어있지 않은 칸을 탭 가능하게
                        // 두고, 정답 숫자만 _tapCell 에서 통과시킨다.
                        onTap: () => _tapCell(row, col),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
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
    final accentColor = theme.primary;

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
      resultColor = accentColor;
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
                    ? '서로 같은 수까지 눌러 무승부입니다.'
                    : (isWinner
                          ? '숫자를 빠르게 찾아 승리했어요!'
                          : '다음엔 숫자 위치를 더 빠르게 파악해봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '${_progress[_myPlayerIndex]}/$_total',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '${_progress[1 - _myPlayerIndex]}/$_total',
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
                accentColor: accentColor,
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
    if (_status == NumberBattleGameStatus.finished) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    if (!widget.isRanked && _status == NumberBattleGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    final isRankedWaiting =
        widget.isRanked &&
        (_status == NumberBattleGameStatus.idle ||
            _status == NumberBattleGameStatus.searching ||
            _status == NumberBattleGameStatus.matched);

    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    if (_status == NumberBattleGameStatus.searching) {
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

/// 숫자 타일: 눌림 스쿼시, 정답 팝, 오답 흔들림 + 빨간 플래시.
class _NumberTile extends StatefulWidget {
  final int number;
  final bool tapped;
  final bool empty;
  final Color accent;
  final double size;
  final bool Function() onTap;

  const _NumberTile({
    required this.number,
    required this.tapped,
    required this.empty,
    required this.accent,
    required this.size,
    required this.onTap,
  });

  @override
  State<_NumberTile> createState() => _NumberTileState();
}

class _NumberTileState extends State<_NumberTile> {
  bool _down = false;
  int _okTick = 0;
  int _wrongTick = 0;

  bool get _enabled => !widget.tapped && !widget.empty;

  void _handleTap() {
    if (!_enabled) return;
    final ok = widget.onTap();
    setState(() {
      if (ok) {
        _okTick++;
      } else {
        _wrongTick++;
      }
    });
  }

  Widget _body(double flash) {
    final Color base = widget.empty
        ? CandyColors.creamDeep.withValues(alpha: 0.5)
        : widget.tapped
        ? CandyColors.mint.withValues(alpha: 0.55)
        : Colors.white;
    final face = Color.lerp(
      base,
      const Color(0xFFFF5A5F),
      flash.clamp(0.0, 1.0),
    )!;
    final raised = _enabled && !_down;
    return AnimatedScale(
      scale: _down && _enabled ? 0.9 : 1.0,
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: face,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: widget.empty
                ? CandyColors.ink.withValues(alpha: 0.25)
                : CandyColors.ink,
            width: 2.5,
          ),
          boxShadow: [
            if (!widget.empty)
              BoxShadow(
                color: CandyColors.ink,
                offset: Offset(0, raised ? 3 : 1),
              ),
          ],
        ),
        child: Center(
          child: widget.empty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.all(3),
                  child: FittedBox(
                    child: Text(
                      widget.tapped ? '✓' : '${widget.number}',
                      style: TextStyle(
                        fontSize: math.max(12, widget.size * 0.42),
                        fontWeight: FontWeight.w900,
                        color: widget.tapped
                            ? CandyColors.mintDeep
                            : CandyColors.ink,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget tile = _wrongTick == 0
        ? _body(0)
        : TweenAnimationBuilder<double>(
            key: ValueKey('wrong$_wrongTick'),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 380),
            builder: (context, t, _) => Transform.translate(
              offset: Offset(math.sin(t * math.pi * 5) * (1 - t) * 7, 0),
              child: _body((1 - t) * 0.9),
            ),
          );
    if (_okTick > 0) {
      tile = TweenAnimationBuilder<double>(
        key: ValueKey('ok$_okTick'),
        tween: Tween(begin: 0.75, end: 1),
        duration: const Duration(milliseconds: 450),
        curve: Curves.elasticOut,
        builder: (context, s, child) => Transform.scale(scale: s, child: child),
        child: tile,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: (_) {
        if (_down) setState(() => _down = false);
      },
      onTapCancel: () {
        if (_down) setState(() => _down = false);
      },
      onTap: _handleTap,
      child: tile,
    );
  }
}
