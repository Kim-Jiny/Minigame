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
import '../common/game_waiting_view.dart';

enum MathraceGameStatus {
  idle,
  searching,
  matched,
  playing,
  finished,
}

class MathraceScreen extends StatefulWidget {
  final bool isRanked;

  const MathraceScreen({super.key, this.isRanked = false});

  @override
  State<MathraceScreen> createState() => _MathraceScreenState();
}

class _MathraceScreenState extends State<MathraceScreen> {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;
  bool _isExitDialogOpen = false;

  MathraceGameStatus _status = MathraceGameStatus.idle;

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
  List<Map<String, dynamic>> _problems = [];
  List<int> _progress = [0, 0];
  String _inputText = '';
  bool _isNegative = false;
  bool? _lastAnswerCorrect;
  Timer? _feedbackTimer;

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
  int _remainingSeconds = 60;

  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accentColor =>
      GameTheme.fromProfileSettings(context.read<ShopProvider>().profileSettings).primary;

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
      final isActiveInvitation = game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched || game.status == GameStatus.playing);
      if (isActiveInvitation) {
        setState(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = MathraceGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🧮 MathraceScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _feedbackTimer?.cancel();
    _socketListeners.offAll();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != MathraceGameStatus.idle &&
      _status != MathraceGameStatus.searching &&
      _status != MathraceGameStatus.finished;

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
      setState(() => _status = MathraceGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.cast<Map<String, dynamic>?>().firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      final foundIndex = players.indexWhere((p) => p['id'] == _myId);
      if (foundIndex != -1) _myPlayerIndex = foundIndex;

      setState(() {
        _status = MathraceGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        if (opponent['profileSettings'] != null) {
          _opponentProfileSettings = UserProfileSettings.fromJson(opponent['profileSettings']);
        }
        if (me != null && me['profileSettings'] != null) {
          _myProfileSettings = UserProfileSettings.fromJson(me['profileSettings']);
        }
      });
    });

    _socketListeners.on('game_start', (data) {
      if (data['gameType'] != 'mathrace') return;
      if (data['players'] != null) {
        final players = data['players'] as List;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) {
          _myPlayerIndex = updatedIndex;
        }
      }
      if (_status == MathraceGameStatus.finished && !_rematchWaiting) {
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }
      setState(() {
        _status = MathraceGameStatus.playing;
        _problems = [];
        _progress = [0, 0];
        _inputText = '';
        _isNegative = false;
        _lastAnswerCorrect = null;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _opponentLeft = false;
        _isDraw = false;
        _winnerId = null;
      });
    });

    _socketListeners.on('mathrace_start', (data) {
      final problemsData = data['problems'] as List;
      final duration = data['duration'] as int? ?? 60000;
      setState(() {
        _status = MathraceGameStatus.playing;
        _problems = problemsData.map<Map<String, dynamic>>((p) => Map<String, dynamic>.from(p)).toList();
        _progress = [0, 0];
        _inputText = '';
        _isNegative = false;
        _lastAnswerCorrect = null;
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
    });

    _socketListeners.on('mathrace_answer', (data) {
      final playerIndex = data['playerIndex'] as int;
      final correct = data['correct'] as bool;
      setState(() {
        _progress = List<int>.from(data['progress']);
        if (playerIndex == _myPlayerIndex) {
          _lastAnswerCorrect = correct;
          if (correct) {
            _inputText = '';
            _isNegative = false;
          }
          _feedbackTimer?.cancel();
          _feedbackTimer = Timer(const Duration(milliseconds: 800), () {
            if (mounted) setState(() => _lastAnswerCorrect = null);
          });
        }
      });
    });

    _socketListeners.on('mathrace_timeout', (data) {
      _stopCountdown();
      setState(() {
        _progress = List<int>.from(data['progress']);
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('mathrace_resumed', (data) {
      final problemsData = data['problems'] as List;
      final duration = data['duration'] as int? ?? 60000;
      setState(() {
        _status = MathraceGameStatus.playing;
        _problems = problemsData.map<Map<String, dynamic>>((p) => Map<String, dynamic>.from(p)).toList();
        _progress = List<int>.from(data['progress']);
        _inputText = '';
        _isNegative = false;
        _lastAnswerCorrect = null;
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'mathrace') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      final problemsData = data['problems'] as List?;
      final remainingMs = (data['remainingTimeMs'] as num?)?.toInt() ?? 60000;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        if (problemsData != null) {
          _problems = problemsData.map<Map<String, dynamic>>((p) => Map<String, dynamic>.from(p)).toList();
        }
        _progress = List<int>.from(data['progress'] ?? _progress);
        _inputText = '';
        _isNegative = false;
        _lastAnswerCorrect = null;
        _status = MathraceGameStatus.playing;
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
      if (_status == MathraceGameStatus.finished) return;
      _stopCountdown();
      setState(() {
        _status = MathraceGameStatus.finished;
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
      if (_status == MathraceGameStatus.idle ||
          _status == MathraceGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == MathraceGameStatus.finished) {
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
        _status = MathraceGameStatus.finished;
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
      'gameType': AppConfig.gameTypeMathrace,
      'isHardcore': false,
    });
    setState(() => _status = MathraceGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeMathrace,
      'isHardcore': false,
    });
    setState(() => _status = MathraceGameStatus.idle);
  }

  void _submitAnswer() {
    if (_roomId == null || _problems.isEmpty || _inputText.isEmpty) return;
    final myProg = _progress[_myPlayerIndex];
    if (myProg >= _problems.length) return;

    final answerStr = _isNegative ? '-$_inputText' : _inputText;
    final answer = int.tryParse(answerStr);
    if (answer == null) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'answer', 'problemIndex': myProg, 'answer': answer},
    });
  }

  void _onKeyPressed(String key) {
    if (key == '=') {
      _submitAnswer();
      return;
    }
    setState(() {
      if (key == 'C') {
        _inputText = '';
        _isNegative = false;
      } else if (key == '⌫') {
        if (_inputText.isNotEmpty) {
          _inputText = _inputText.substring(0, _inputText.length - 1);
        }
        if (_inputText.isEmpty) _isNegative = false;
      } else if (key == '±') {
        _isNegative = !_isNegative;
      } else {
        if (_inputText.length < 4) {
          _inputText += key;
        }
      }
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
      _status = MathraceGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _problems = [];
      _progress = [0, 0];
      _inputText = '';
      _isNegative = false;
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
              title: '사칙연산',
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
      icon: Icons.calculate,
      title: '사칙연산 준비 중',
      subtitle: '문제와 타이머를 맞추고 있습니다.',
      statusMessages: const [
        '문제를 준비하고 있습니다.',
        '타이머를 동기화하고 있습니다.',
        '상대의 상태를 확인하고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      MathraceGameStatus.idle => widget.isRanked ? _buildRankedWaitingView(theme) : _buildIdleView(theme),
      MathraceGameStatus.searching => widget.isRanked ? _buildRankedWaitingView(theme) : _buildSearchingView(theme),
      MathraceGameStatus.matched => widget.isRanked ? _buildRankedWaitingView(theme) : _buildMatchedView(theme),
      MathraceGameStatus.playing => _buildPlayingView(theme),
      MathraceGameStatus.finished => _buildFinishedView(theme),
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
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
                                    AppConfig.gameTypeMathrace,
                                    isHardcore: false,
                                  );
                                  Navigator.pop(dialogContext);
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
      accentColor: _accentColor,
      icon: Icons.calculate,
      title: '사칙연산 스피드',
      descriptions: const ['10문제를 먼저 풀어라!', '+, -, ×, ÷ 사칙연산 (60초 제한)'],
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
    final myProgress = _progress[_myPlayerIndex];
    final opponentProgress = _progress[1 - _myPlayerIndex];

    return Column(
      children: [
        GameDuelHeader(
          backgroundColors: [_accentColor.withValues(alpha: 0.08), const Color(0xFFFFF5F5)],
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
            score: myProgress,
            color: _accentColor,
          ),
          opponentExtraWidget: GameHeaderScorePill(
            score: opponentProgress,
            color: Colors.grey,
          ),
        ),

        // 진행도 바
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: _buildProgressBar(myProgress, _accentColor, '나'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildProgressBar(opponentProgress, Colors.grey.shade500, _opponentNickname ?? '상대'),
              ),
            ],
          ),
        ),

        // 문제 영역
        Expanded(
          child: _problems.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _buildProblemArea(),
        ),
      ],
    );
  }

  Widget _buildProgressBar(int progress, Color color, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            Text(
              '$progress/10',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress / 10,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 6,
          ),
        ),
      ],
    );
  }

  Widget _buildProblemArea() {
    final myProg = _progress[_myPlayerIndex];
    final isComplete = myProg >= _problems.length;

    if (isComplete) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, size: 64, color: _accentColor),
            const SizedBox(height: 16),
            Text(
              '모든 문제 완료!',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _accentColor),
            ),
            const SizedBox(height: 8),
            const Text('결과를 기다리는 중...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    final problem = _problems[myProg];
    final num1 = problem['num1'];
    final num2 = problem['num2'];
    final operator = problem['operator'] as String;
    final displayInput = _isNegative ? '-$_inputText' : _inputText;

    return Column(
      children: [
        // 진행 인디케이터
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(10, (i) {
              return Container(
                width: 24,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: i < myProg
                      ? _accentColor
                      : i == myProg
                          ? _accentColor.withValues(alpha: 0.4)
                          : Colors.grey.shade200,
                ),
              );
            }),
          ),
        ),

        const SizedBox(height: 8),

        // 문제
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              Text(
                '문제 ${myProg + 1}/10',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$num1 $operator $num2 = ?',
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // 입력 필드 + 피드백
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: _lastAnswerCorrect == null
                ? Colors.grey.shade100
                : _lastAnswerCorrect!
                    ? Colors.green.shade50
                    : Colors.red.shade50,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _lastAnswerCorrect == null
                  ? Colors.grey.shade300
                  : _lastAnswerCorrect!
                      ? Colors.green.shade300
                      : Colors.red.shade300,
              width: 2,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_lastAnswerCorrect != null)
                Icon(
                  _lastAnswerCorrect! ? Icons.check_circle : Icons.cancel,
                  color: _lastAnswerCorrect! ? Colors.green : Colors.red,
                  size: 24,
                ),
              if (_lastAnswerCorrect != null) const SizedBox(width: 8),
              Text(
                displayInput.isEmpty ? '답을 입력하세요' : displayInput,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: displayInput.isEmpty ? Colors.grey.shade400 : const Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
        ),

        const Spacer(),

        // 키패드
        _buildKeypad(),

        SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
      ],
    );
  }

  Widget _buildKeypad() {
    const keys = [
      ['7', '8', '9', '⌫'],
      ['4', '5', '6', 'C'],
      ['1', '2', '3', '±'],
      ['0', '='],
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: keys.map((row) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: row.map((key) {
                final isSubmit = key == '=';
                final isAction = key == '⌫' || key == 'C' || key == '±';
                final flex = isSubmit ? 2 : 1;

                return Expanded(
                  flex: flex,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Material(
                      color: isSubmit
                          ? _accentColor
                          : isAction
                              ? Colors.grey.shade200
                              : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      elevation: isSubmit ? 2 : 0,
                      child: InkWell(
                        onTap: () => _onKeyPressed(key),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          height: 52,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: isSubmit ? null : Border.all(color: Colors.grey.shade300),
                          ),
                          child: Center(
                            child: Text(
                              isSubmit ? '제출' : key,
                              style: TextStyle(
                                fontSize: isSubmit ? 18 : 20,
                                fontWeight: FontWeight.w700,
                                color: isSubmit ? Colors.white : const Color(0xFF1A1A2E),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFinishedView(GameTheme theme) {
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
                    ? '서로 같은 수까지 풀어 무승부입니다.'
                    : (isWinner ? '빠른 암산으로 승리했어요!' : '다음엔 더 빠르게 풀어봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '${_progress[_myPlayerIndex]}/10',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '${_progress[1 - _myPlayerIndex]}/10',
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
                accentColor: _accentColor,
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
    if (!widget.isRanked && _status == MathraceGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    final isRankedWaiting = widget.isRanked &&
        (_status == MathraceGameStatus.idle ||
            _status == MathraceGameStatus.searching ||
            _status == MathraceGameStatus.matched);

    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    if (_status == MathraceGameStatus.searching) {
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
