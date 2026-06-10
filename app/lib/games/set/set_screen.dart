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
import 'set_card.dart';

enum SetGameStatus { idle, searching, matched, playing, finished }

class SetScreen extends StatefulWidget {
  final bool isRanked;

  const SetScreen({super.key, this.isRanked = false});

  @override
  State<SetScreen> createState() => _SetScreenState();
}

class _SetScreenState extends State<SetScreen> {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners =
      SocketListenerRegistry(_socketService);
  bool _hasScheduledPop = false;
  bool _isExitDialogOpen = false;

  SetGameStatus _status = SetGameStatus.idle;

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
  List<int> _board = []; // 카드 id 목록(12~18)
  List<int> _scores = [0, 0]; // 각자 모은 세트 수
  int _deckRemaining = 0;
  int _scoreToWin = 6;
  final List<int> _selected = []; // 선택한 카드 id(최대 3)
  bool _claimLocked = false; // 클레임 응답 대기/패널티 중 입력 잠금
  bool _lastClaimFailed = false; // 직전 내 클레임 실패(빨강 피드백)
  Timer? _penaltyTimer;

  // 게임 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  bool _wonByForfeit = false;
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
  int _remainingSeconds = 120;

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
          (game.status == GameStatus.matched ||
              game.status == GameStatus.playing);
      if (isActiveInvitation) {
        setState(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = SetGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🃏 SetScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _reconnectTimer?.cancel();
    _waitingReconnectTimer?.cancel();
    _penaltyTimer?.cancel();
    _socketListeners.offAll();
    super.dispose();
  }

  bool get _isGameActive =>
      _status != SetGameStatus.idle &&
      _status != SetGameStatus.searching &&
      _status != SetGameStatus.finished;

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
      setState(() => _status = SetGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players
          .cast<Map<String, dynamic>?>()
          .firstWhere((p) => p!['id'] != _myId, orElse: () => null);
      if (opponent == null) return;
      final me =
          players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = SetGameStatus.matched;
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
          _myProfileSettings = UserProfileSettings.fromJson(me['profileSettings']);
        }
      });
    });

    _socketListeners.on('game_start', (data) {
      if (data['gameType'] != 'set') return;
      if (data['players'] != null) {
        final players = data['players'] as List;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) _myPlayerIndex = updatedIndex;
      }
      if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
      setState(() {
        _status = SetGameStatus.playing;
        _board = [];
        _scores = [0, 0];
        _selected.clear();
        _claimLocked = false;
        _lastClaimFailed = false;
        _winnerId = null;
        _isDraw = false;
        _opponentLeft = false;
        _wonByForfeit = false;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
      });
    });

    _socketListeners.on('set_start', (data) {
      final duration = (data['duration'] as num?)?.toInt() ?? 120000;
      setState(() {
        _status = SetGameStatus.playing;
        _board = List<int>.from(data['board'] ?? []);
        _scores = List<int>.from(data['scores'] ?? [0, 0]);
        _deckRemaining = (data['deckRemaining'] as num?)?.toInt() ?? 0;
        _scoreToWin = (data['scoreToWin'] as num?)?.toInt() ?? 6;
        _selected.clear();
        _claimLocked = false;
        _lastClaimFailed = false;
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
    });

    _socketListeners.on('set_claimed', (data) {
      _penaltyTimer?.cancel();
      setState(() {
        _board = List<int>.from(data['board'] ?? _board);
        _scores = List<int>.from(data['scores'] ?? _scores);
        _deckRemaining = (data['deckRemaining'] as num?)?.toInt() ?? _deckRemaining;
        _selected.clear();
        _claimLocked = false;
        _lastClaimFailed = false;
      });
    });

    _socketListeners.on('set_claim_rejected', (data) {
      // 점수 동기화(오답 -1 반영) — 양쪽 플레이어 모두
      if (data['scores'] != null) {
        setState(() => _scores = List<int>.from(data['scores']));
      }
      final playerIndex = (data['playerIndex'] as num?)?.toInt();
      if (playerIndex != _myPlayerIndex) return;
      // 내 클레임 실패 → 선택 해제 + 짧은 잠금. 실제 오답일 때만 빨강 피드백.
      final isWrongSet = data['reason'] == 'not_a_set';
      setState(() {
        _lastClaimFailed = isWrongSet;
        _claimLocked = true;
      });
      _penaltyTimer?.cancel();
      _penaltyTimer = Timer(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        setState(() {
          _selected.clear();
          _claimLocked = false;
          _lastClaimFailed = false;
        });
      });
    });

    _socketListeners.on('set_timeout', (data) {
      _stopCountdown();
      setState(() {
        _scores = List<int>.from(data['scores'] ?? _scores);
        _isWaitingForReconnect = false;
      });
    });

    _socketListeners.on('set_resumed', (data) {
      final duration = (data['duration'] as num?)?.toInt() ?? 120000;
      setState(() {
        _status = SetGameStatus.playing;
        _board = List<int>.from(data['board'] ?? _board);
        _scores = List<int>.from(data['scores'] ?? _scores);
        _deckRemaining = (data['deckRemaining'] as num?)?.toInt() ?? _deckRemaining;
        _selected.clear();
        _claimLocked = false;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      _startCountdown((duration / 1000).ceil());
    });

    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'set') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;
      final remainingMs = (data['remainingTimeMs'] as num?)?.toInt() ?? 120000;
      setState(() {
        _roomId = data['roomId'] as String?;
        _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? _myPlayerIndex;
        _board = List<int>.from(data['board'] ?? _board);
        _scores = List<int>.from(data['scores'] ?? _scores);
        _deckRemaining = (data['deckRemaining'] as num?)?.toInt() ?? _deckRemaining;
        _scoreToWin = (data['scoreToWin'] as num?)?.toInt() ?? _scoreToWin;
        _selected.clear();
        _claimLocked = false;
        _status = SetGameStatus.playing;
        _isReconnecting = false;
        _isWaitingForReconnect = false;
      });
      _startCountdown((remainingMs / 1000).ceil());
      GameReconnectHelper.completeReconnect(context: context, onRecovered: () {});
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
      if (_status == SetGameStatus.finished) return;
      _stopCountdown();
      setState(() {
        _status = SetGameStatus.finished;
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
      if (_status == SetGameStatus.idle || _status == SetGameStatus.searching) {
        return;
      }
      if (_status == SetGameStatus.finished) {
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
        _status = SetGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
        _wonByForfeit = true;
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
      onRematchWaiting: (waiting) => setState(() => _rematchWaiting = waiting),
      onOpponentRematchChanged: (wantsRematch) =>
          setState(() => _opponentWantsRematch = wantsRematch),
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
      'gameType': AppConfig.gameTypeSet,
      'isHardcore': false,
    });
    setState(() => _status = SetGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeSet,
      'isHardcore': false,
    });
    setState(() => _status = SetGameStatus.idle);
  }

  void _onCardTap(int cardId) {
    if (_status != SetGameStatus.playing || _claimLocked) return;
    setState(() {
      _lastClaimFailed = false;
      if (_selected.contains(cardId)) {
        _selected.remove(cardId);
      } else if (_selected.length < 3) {
        _selected.add(cardId);
      }
    });
    if (_selected.length == 3) _claim();
  }

  void _claim() {
    if (_roomId == null || _selected.length != 3) return;
    _claimLocked = true; // 응답까지 추가 입력 방지
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'claim', 'cards': List<int>.from(_selected)},
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
    _penaltyTimer?.cancel();
    setState(() {
      _status = SetGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _board = [];
      _scores = [0, 0];
      _selected.clear();
      _claimLocked = false;
      _lastClaimFailed = false;
      _winnerId = null;
      _isDraw = false;
      _opponentLeft = false;
      _wonByForfeit = false;
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
              title: 'Set',
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

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      SetGameStatus.idle => _buildIdleView(theme),
      SetGameStatus.searching => _buildSearchingView(theme),
      SetGameStatus.matched => _buildMatchedView(theme),
      SetGameStatus.playing => _buildPlayingView(theme),
      SetGameStatus.finished => _buildFinishedView(theme),
    };
  }

  Widget _buildIdleView(GameTheme theme) {
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: theme.primary,
      icon: Icons.style_rounded,
      title: 'Set',
      descriptions: const [
        '4속성이 모두 같거나 모두 다른 카드 3장!',
        '먼저 6세트 승리 · 틀리면 -1점 (120초)',
      ],
      onFindMatch: _findMatch,
      onInviteFriend: () => _showFriendInviteDialog(context),
    );
  }

  Widget _buildSearchingView(GameTheme theme) {
    final accent = theme.primary;
    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: accent),
            const SizedBox(height: 24),
            Text('상대를 찾는 중...',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold, color: accent)),
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
    final accent = theme.primary;
    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(Icons.sports_esports, size: 64, color: accent),
            ),
            const SizedBox(height: 16),
            Text('$_opponentNickname님과 매칭!',
                style: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.bold, color: accent)),
            const SizedBox(height: 8),
            Text('게임이 곧 시작됩니다...',
                style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayingView(GameTheme theme) {
    final accent = theme.primary;
    final myScore = _scores.length > _myPlayerIndex ? _scores[_myPlayerIndex] : 0;
    final opScore = _scores.length > (1 - _myPlayerIndex) ? _scores[1 - _myPlayerIndex] : 0;

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: Column(
        children: [
          GameDuelHeader(
            backgroundColors: const [Colors.white, Colors.white],
            accentColor: accent,
            centerLabel: '$_remainingSeconds',
            centerSubtitle: '남은 시간',
            myName: _myNickname ?? '나',
            opponentName: _opponentNickname ?? '상대',
            myAvatarUrl: _myAvatarUrl,
            opponentAvatarUrl: _opponentAvatarUrl,
            myActive: true,
            opponentActive: true,
            myProfileSettings: _myProfileSettings,
            opponentProfileSettings: _opponentProfileSettings,
            myExtraWidget: GameHeaderScorePill(
                score: myScore, color: accent, margin: const EdgeInsets.only(top: 4)),
            opponentExtraWidget: GameHeaderScorePill(
                score: opScore,
                color: Colors.grey.shade500,
                margin: const EdgeInsets.only(top: 4)),
          ),
          // 진행 안내
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '세트 3장 선택 · 남은 카드 $_deckRemaining장',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBoard(accent)),
        ],
      ),
    );
  }

  Widget _buildBoard(Color accent) {
    const cols = 3;
    const spacing = 10.0;
    // 안드로이드 시스템 네비게이션 바와 겹치지 않도록 하단 인셋만큼 비운다.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final padding = EdgeInsets.fromLTRB(14, 6, 14, 14 + bottomInset);
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = _board.length;
        if (count == 0) return const SizedBox.shrink();
        // 행 수에 맞춰 카드 종횡비를 계산 → 스크롤 없이 한 화면에 모두 표시.
        final rows = (count / cols).ceil();
        final availW = constraints.maxWidth - padding.horizontal;
        final availH = constraints.maxHeight - padding.vertical;
        final cardW = (availW - spacing * (cols - 1)) / cols;
        final cardH = (availH - spacing * (rows - 1)) / rows;
        final aspect = (cardH > 0 && cardW > 0) ? cardW / cardH : 0.74;
        return GridView.builder(
          padding: padding,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: aspect,
          ),
          itemCount: count,
          itemBuilder: (context, index) {
            final id = _board[index];
            final selected = _selected.contains(id);
            return SetCard(
              cardId: id,
              selected: selected,
              failed: selected && _lastClaimFailed,
              accent: accent,
              onTap: () => _onCardTap(id),
            );
          },
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
    final accent = theme.primary;

    if (widget.isRanked) {
      GameSessionHelper.scheduleRankedAutoReturn(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
      );
      return GameRankedResultView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: accent,
        isWinner: isWinner,
        isDraw: _isDraw,
      );
    }

    String resultText;
    Color resultColor;
    IconData resultIcon;
    if (_wonByForfeit) {
      resultText = '승리!';
      resultColor = accent;
      resultIcon = Icons.emoji_events;
    } else if (_isDraw) {
      resultText = '무승부!';
      resultColor = Colors.orange;
      resultIcon = Icons.handshake;
    } else if (isWinner) {
      resultText = '승리!';
      resultColor = accent;
      resultIcon = Icons.emoji_events;
    } else {
      resultText = '아쉬워요...';
      resultColor = Colors.grey;
      resultIcon = Icons.sentiment_dissatisfied;
    }

    final myScore = _scores.length > _myPlayerIndex ? _scores[_myPlayerIndex] : 0;
    final opScore = _scores.length > (1 - _myPlayerIndex) ? _scores[1 - _myPlayerIndex] : 0;

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
                    ? '같은 수의 세트를 모았어요.'
                    : (isWinner ? '더 많은 세트를 찾았어요!' : '다음엔 패턴을 더 빠르게 찾아봐요.'),
              ),
              const SizedBox(height: 22),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '$myScore세트',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '$opScore세트',
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
                accentColor: accent,
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
                        context
                            .read<FriendProvider>()
                            .sendFriendRequestByUserId(_opponentUserId!);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('$_opponentNickname님에게 친구 요청을 보냈습니다'),
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
                maxHeight: MediaQuery.of(dialogContext).size.height * 0.6),
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
                      borderRadius: BorderRadius.circular(2)),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(Icons.person_add, color: theme.primary),
                      const SizedBox(width: 12),
                      const Text('친구 초대',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
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
                                Text('온라인 친구가 없습니다',
                                    style: TextStyle(color: Colors.grey.shade600)),
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
                              leading: CircleAvatar(
                                backgroundColor: theme.primary.withValues(alpha: 0.2),
                                child: Text(
                                  friend.nickname.isNotEmpty
                                      ? friend.nickname[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(color: theme.primary),
                                ),
                              ),
                              title: Text(friend.nickname,
                                  style:
                                      const TextStyle(fontWeight: FontWeight.w600)),
                              trailing: ElevatedButton(
                                onPressed: () {
                                  friendProvider.inviteToGame(
                                    friend.id,
                                    AppConfig.gameTypeSet,
                                    isHardcore: false,
                                  );
                                  Navigator.pop(dialogContext);
                                  ScaffoldMessenger.of(context).clearSnackBars();
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
                                ),
                                child: const Text('초대'),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showExitDialog(GameTheme theme) {
    if (!widget.isRanked && _status == SetGameStatus.idle) {
      Navigator.pop(context);
      return;
    }
    final isRankedWaiting = widget.isRanked &&
        (_status == SetGameStatus.idle ||
            _status == SetGameStatus.searching ||
            _status == SetGameStatus.matched);
    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }
    if (_status == SetGameStatus.searching) {
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
