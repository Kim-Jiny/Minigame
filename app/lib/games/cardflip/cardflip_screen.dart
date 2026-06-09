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

enum CardFlipGameStatus {
  idle,
  searching,
  matched,
  playing,
  finished,
}

class CardFlipScreen extends StatefulWidget {
  final bool isRanked;

  const CardFlipScreen({super.key, this.isRanked = false});

  @override
  State<CardFlipScreen> createState() => _CardFlipScreenState();
}

class _CardFlipScreenState extends State<CardFlipScreen> {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;
  bool _isExitDialogOpen = false;

  CardFlipGameStatus _status = CardFlipGameStatus.idle;

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
  Map<int, String> _revealedCards = {}; // position -> symbol (현재 보이는 카드)
  Set<int> _matchedPositions = {};
  List<int> _scores = [0, 0];
  int _currentTurn = 0;
  int _totalPairs = 10;

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

  // 카드 뒤집기 애니메이션 중인지
  bool _isProcessingFlip = false;

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
          _status = CardFlipGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🃏 CardFlipScreen: GameProvider 초기화 실패: $e');
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
      _status != CardFlipGameStatus.idle &&
      _status != CardFlipGameStatus.searching &&
      _status != CardFlipGameStatus.finished;

  bool get _isMyTurn => _currentTurn == _myPlayerIndex;

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
      setState(() => _status = CardFlipGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.cast<Map<String, dynamic>?>().firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = CardFlipGameStatus.matched;
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
      if (data['gameType'] != 'cardflip') return;
      if (data['players'] != null) {
        final players = data['players'] as List;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) {
          _myPlayerIndex = updatedIndex;
        }
      }
      if (_status == CardFlipGameStatus.finished && !_rematchWaiting) {
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }
      setState(() {
        _status = CardFlipGameStatus.playing;
        _revealedCards = {};
        _matchedPositions = {};
        _scores = [0, 0];
        _currentTurn = 0;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _opponentLeft = false;
        _isDraw = false;
        _winnerId = null;
        _isProcessingFlip = false;
      });
    });

    _socketListeners.on('cardflip_start', (data) {
      setState(() {
        _status = CardFlipGameStatus.playing;
        _currentTurn = data['currentTurn'] as int? ?? 0;
        _totalPairs = data['totalPairs'] as int? ?? 10;
        _revealedCards = {};
        _matchedPositions = {};
        _scores = [0, 0];
        _isWaitingForReconnect = false;
        _isProcessingFlip = false;
      });
      // cardflip_turn이 바로 뒤에 오므로 여기서는 카운트다운 시작 안 함
    });

    _socketListeners.on('cardflip_turn', (data) {
      final turnTime = (data['turnTime'] as int?) ?? 10000;
      setState(() {
        _currentTurn = data['currentTurn'] as int;
        _isProcessingFlip = false;
      });
      _startCountdown((turnTime / 1000).ceil());
    });

    _socketListeners.on('cardflip_flip', (data) {
      final position = data['position'] as int;
      final symbol = data['symbol'] as String;
      setState(() {
        _revealedCards[position] = symbol;
        // 뒤집힌 비매칭 카드가 2장이면 결과 대기 중 → 추가 탭 차단
        final flippedCount = _revealedCards.keys
            .where((pos) => !_matchedPositions.contains(pos))
            .length;
        if (flippedCount >= 2) {
          _isProcessingFlip = true;
          _stopCountdown(); // 결과 대기 중 카운트다운 정지
        }
      });
    });

    _socketListeners.on('cardflip_result', (data) {
      final matched = data['matched'] as bool;
      final positions = List<int>.from(data['positions'] ?? []);
      final scores = List<int>.from(data['scores']);
      final nextTurn = data['nextTurn'] as int;
      final matchedPositions = data['matchedPositions'] as List?;

      setState(() {
        _scores = scores;
        _currentTurn = nextTurn;

        if (matched && matchedPositions != null) {
          for (int i = 0; i < matchedPositions.length; i++) {
            if (matchedPositions[i] == true) {
              _matchedPositions.add(i);
            }
          }
        }

        if (!matched) {
          // 불일치 → 카드 뒤집기 (서버에서 딜레이 후 보냄)
          for (final pos in positions) {
            _revealedCards.remove(pos);
          }
        }

        _isProcessingFlip = false;
      });
    });

    _socketListeners.on('cardflip_timeout', (data) {
      final positions = List<int>.from(data['positions'] ?? []);
      final nextTurn = data['nextTurn'] as int;
      setState(() {
        for (final pos in positions) {
          _revealedCards.remove(pos);
        }
        _currentTurn = nextTurn;
        _isProcessingFlip = false;
      });
    });

    _socketListeners.on('cardflip_resumed', (data) {
      final cards = List<String>.from(data['cards']);
      final matched = List<bool>.from(data['matched']);
      final scores = List<int>.from(data['scores']);
      final currentTurn = data['currentTurn'] as int;
      final flippedCards = List<int>.from(data['flippedCards'] ?? []);
      final flippedSymbols = List<String>.from(data['flippedSymbols'] ?? []);
      final turnTime = (data['turnTime'] as int?) ?? 10000;
      final isPhaseWaiting = data['isPhaseWaiting'] == true;

      setState(() {
        _status = CardFlipGameStatus.playing;
        _scores = scores;
        _currentTurn = currentTurn;
        _isWaitingForReconnect = false;
        // 2장 뒤집힌 채 결과 대기 중이면 _isProcessingFlip 유지
        _isProcessingFlip = isPhaseWaiting;

        _matchedPositions = {};
        _revealedCards = {};
        for (int i = 0; i < matched.length; i++) {
          if (matched[i]) {
            _matchedPositions.add(i);
            _revealedCards[i] = cards[i];
          }
        }
        for (int i = 0; i < flippedCards.length; i++) {
          _revealedCards[flippedCards[i]] = flippedSymbols[i];
        }
      });
      if (!isPhaseWaiting) {
        // 정상 턴 → 남은 시간으로 카운트다운 시작
        _startCountdown((turnTime / 1000).ceil());
      } else {
        // 결과 대기 중 → 카운트다운 불필요 (곧 cardflip_result → cardflip_turn이 옴)
        _stopCountdown();
      }
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'cardflip') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;

      final cards = List<String>.from(data['cards'] ?? []);
      final matched = List<bool>.from(data['matched'] ?? []);
      final scores = List<int>.from(data['scores'] ?? [0, 0]);
      final currentTurn = (data['currentTurn'] as num?)?.toInt() ?? 0;
      final flippedCards = List<int>.from(data['flippedCards'] ?? []);
      final flippedSymbols = List<String>.from(data['flippedSymbols'] ?? []);
      final remainingMs = (data['remainingTimeMs'] as num?)?.toInt() ?? 10000;

      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _scores = scores;
        _currentTurn = currentTurn;

        _matchedPositions = {};
        _revealedCards = {};
        for (int i = 0; i < matched.length; i++) {
          if (matched[i]) {
            _matchedPositions.add(i);
            _revealedCards[i] = cards[i];
          }
        }
        for (int i = 0; i < flippedCards.length; i++) {
          _revealedCards[flippedCards[i]] = flippedSymbols[i];
        }

        _status = CardFlipGameStatus.playing;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
        _isProcessingFlip = false;
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
      if (_status == CardFlipGameStatus.finished) return;
      _stopCountdown();
      setState(() {
        _status = CardFlipGameStatus.finished;
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
      if (_status == CardFlipGameStatus.idle ||
          _status == CardFlipGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == CardFlipGameStatus.finished) {
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
        _status = CardFlipGameStatus.finished;
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
      'gameType': AppConfig.gameTypeCardFlip,
      'isHardcore': false,
    });
    setState(() => _status = CardFlipGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeCardFlip,
      'isHardcore': false,
    });
    setState(() => _status = CardFlipGameStatus.idle);
  }

  void _flipCard(int position) {
    if (_roomId == null) return;
    if (!_isMyTurn) return;
    if (_matchedPositions.contains(position)) return;
    if (_revealedCards.containsKey(position)) return;
    if (_isProcessingFlip) return;

    // 이미 내 턴에 뒤집힌 비매칭 카드가 2장 이상이면 무시
    final flippedCount = _revealedCards.keys
        .where((pos) => !_matchedPositions.contains(pos))
        .length;
    if (flippedCount >= 2) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'flip', 'position': position},
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
      _status = CardFlipGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _revealedCards = {};
      _matchedPositions = {};
      _scores = [0, 0];
      _currentTurn = 0;
      _winnerId = null;
      _isDraw = false;
      _opponentLeft = false;
      _rematchWaiting = false;
      _opponentWantsRematch = false;
      _isInvitationGame = false;
      _isReconnecting = false;
      _isWaitingForReconnect = false;
      _isProcessingFlip = false;
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
              title: '카드 뒤집기',
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
      icon: Icons.style,
      title: '카드 뒤집기 준비 중',
      subtitle: '카드를 섞고 있습니다.',
      statusMessages: const [
        '카드를 배치하고 있습니다.',
        '게임을 준비하고 있습니다.',
        '상대의 상태를 확인하고 있습니다.',
      ],
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      CardFlipGameStatus.idle => widget.isRanked ? _buildRankedWaitingView(theme) : _buildIdleView(theme),
      CardFlipGameStatus.searching => widget.isRanked ? _buildRankedWaitingView(theme) : _buildSearchingView(theme),
      CardFlipGameStatus.matched => widget.isRanked ? _buildRankedWaitingView(theme) : _buildMatchedView(theme),
      CardFlipGameStatus.playing => _buildPlayingView(theme),
      CardFlipGameStatus.finished => _buildFinishedView(theme),
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
                                    AppConfig.gameTypeCardFlip,
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
      accentColor: theme.primary,
      icon: Icons.style,
      title: '카드 뒤집기',
      descriptions: const ['짝이 맞는 카드를 찾아라!', '4x5 그리드 / 턴당 10초'],
      onFindMatch: _findMatch,
      onInviteFriend: () => _showFriendInviteDialog(context),
    );
  }

  Widget _buildSearchingView(GameTheme theme) {
    final accentColor = theme.primary;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accentColor.withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: accentColor,
            ),
            const SizedBox(height: 24),
            Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: accentColor,
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
    final accentColor = theme.primary;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accentColor.withValues(alpha: 0.1),
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
                color: accentColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sports_esports,
                size: 64,
                color: accentColor,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: accentColor,
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
    final accentColor = theme.primary;
    final myScore = _scores[_myPlayerIndex];
    final opponentScore = _scores[1 - _myPlayerIndex];

    return Column(
      children: [
        GameDuelHeader(
          backgroundColors: [accentColor.withValues(alpha: 0.08), const Color(0xFFF5F3FF)],
          accentColor: accentColor,
          centerLabel: '$_remainingSeconds',
          centerSubtitle: _isMyTurn ? '내 턴' : '상대 턴',
          myName: _myNickname ?? '나',
          opponentName: _opponentNickname ?? '상대',
          myAvatarUrl: _myAvatarUrl,
          opponentAvatarUrl: _opponentAvatarUrl,
          myActive: _isMyTurn,
          opponentActive: !_isMyTurn,
          myProfileSettings: _myProfileSettings,
          opponentProfileSettings: _opponentProfileSettings,
          myExtraWidget: GameHeaderScorePill(
            score: myScore,
            color: accentColor,
          ),
          opponentExtraWidget: GameHeaderScorePill(
            score: opponentScore,
            color: Colors.grey,
          ),
        ),

        // 턴 표시 바
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _isMyTurn
                ? accentColor.withValues(alpha: 0.1)
                : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isMyTurn
                  ? accentColor.withValues(alpha: 0.3)
                  : Colors.grey.shade300,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isMyTurn ? Icons.touch_app : Icons.hourglass_top,
                size: 18,
                color: _isMyTurn ? accentColor : Colors.grey.shade600,
              ),
              const SizedBox(width: 8),
              Text(
                _isMyTurn ? '카드 2장을 선택하세요!' : '상대가 카드를 고르는 중...',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _isMyTurn ? accentColor : Colors.grey.shade600,
                ),
              ),
              const Spacer(),
              Text(
                '${myScore + opponentScore}/$_totalPairs',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),

        // 4x5 카드 그리드
        Expanded(
          child: _buildCardGrid(accentColor),
        ),
      ],
    );
  }

  Widget _buildCardGrid(Color accentColor) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - 32; // padding
        final availableHeight = constraints.maxHeight - 16;
        final cellWidth = (availableWidth - 3 * 6) / 5; // 5 cols, 4 gaps
        final cellHeight = (availableHeight - 3 * 6) / 4; // 4 rows, 3 gaps
        final cellSize = cellWidth < cellHeight ? cellWidth : cellHeight;

        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: cellSize * 5 + 4 * 6,
              height: cellSize * 4 + 3 * 6,
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                ),
                itemCount: 20,
                itemBuilder: (context, index) {
                  final isMatched = _matchedPositions.contains(index);
                  final isRevealed = _revealedCards.containsKey(index);
                  final symbol = _revealedCards[index];
                  final canTap = _isMyTurn && !isMatched && !isRevealed && !_isProcessingFlip;

                  return GestureDetector(
                    onTap: canTap ? () => _flipCard(index) : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        color: isMatched
                            ? accentColor.withValues(alpha: 0.12)
                            : isRevealed
                                ? Colors.white
                                : canTap
                                    ? accentColor.withValues(alpha: 0.06)
                                    : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isMatched
                              ? accentColor.withValues(alpha: 0.3)
                              : isRevealed
                                  ? accentColor
                                  : canTap
                                      ? accentColor.withValues(alpha: 0.3)
                                      : Colors.grey.shade300,
                          width: isRevealed ? 2 : 1,
                        ),
                        boxShadow: isRevealed && !isMatched
                            ? [
                                BoxShadow(
                                  color: accentColor.withValues(alpha: 0.2),
                                  blurRadius: 6,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: Center(
                        child: isMatched
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    symbol ?? '',
                                    style: TextStyle(fontSize: cellSize * 0.3),
                                  ),
                                  Icon(
                                    Icons.check_circle,
                                    size: 14,
                                    color: accentColor.withValues(alpha: 0.5),
                                  ),
                                ],
                              )
                            : isRevealed
                                ? Text(
                                    symbol ?? '',
                                    style: TextStyle(fontSize: cellSize * 0.4),
                                  )
                                : Icon(
                                    Icons.question_mark_rounded,
                                    size: cellSize * 0.3,
                                    color: canTap
                                        ? accentColor.withValues(alpha: 0.5)
                                        : Colors.grey.shade400,
                                  ),
                      ),
                    ),
                  );
                },
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
                    ? '서로 같은 수의 쌍을 찾아 무승부입니다.'
                    : (isWinner ? '더 많은 짝을 찾아 승리했어요!' : '다음엔 카드 위치를 더 잘 기억해봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '${_scores[_myPlayerIndex]}쌍',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '${_scores[1 - _myPlayerIndex]}쌍',
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
    if (!widget.isRanked && _status == CardFlipGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    final isRankedWaiting = widget.isRanked &&
        (_status == CardFlipGameStatus.idle ||
            _status == CardFlipGameStatus.searching ||
            _status == CardFlipGameStatus.matched);

    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    if (_status == CardFlipGameStatus.searching) {
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
