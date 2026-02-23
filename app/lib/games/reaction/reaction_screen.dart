import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/shop_provider.dart';
import '../../providers/ranked_provider.dart';
import '../../services/socket_service.dart';
import '../../services/socket_listener_registry.dart';
import '../../config/app_config.dart';
import '../../models/shop_item.dart';
import '../../widgets/game_player_profile.dart';
import '../../utils/game_theme.dart';

enum ReactionGameStatus {
  idle,
  searching,
  matched,
  playing,
  finished,
}

enum RoundState {
  waiting,  // 라운드 대기
  ready,    // 빨간불 (누르면 안됨)
  go,       // 초록불 (빨리 눌러!)
  result,   // 결과 표시
}

class ReactionScreen extends StatefulWidget {
  final bool isRanked;

  const ReactionScreen({super.key, this.isRanked = false});

  @override
  State<ReactionScreen> createState() => _ReactionScreenState();
}

class _ReactionScreenState extends State<ReactionScreen> {
  final SocketService _socketService = SocketService();
  final SocketListenerRegistry _socketListeners = SocketListenerRegistry(SocketService());
  bool _hasScheduledPop = false;  // 중복 pop 방지
  bool _isExitDialogOpen = false;  // 나가기 다이얼로그 열림 상태

  ReactionGameStatus _status = ReactionGameStatus.idle;
  RoundState _roundState = RoundState.waiting;

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

  // 라운드 결과
  bool? _lastRoundFalseStart;
  String? _lastRoundWinnerNickname;
  int? _lastReactionTime;
  String? _pressedPlayerNickname;

  // 게임 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;

  @override
  void initState() {
    super.initState();
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
      debugPrint('🎮 ReactionScreen _initFromGameProvider: isInvitation=${game.isInvitationGame}, roomId=${game.roomId}, opponentNickname=${game.opponentNickname}, status=${game.status}');
      final isActiveInvitation = game.isInvitationGame &&
          game.roomId != null &&
          game.opponentNickname != null &&
          (game.status == GameStatus.matched || game.status == GameStatus.playing);
      if (isActiveInvitation) {
        debugPrint('🎮 ReactionScreen: 초대 게임 초기화 from GameProvider');
        setState(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = ReactionGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 ReactionScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _socketListeners.offAll();
    super.dispose();
  }

  void _setupSocketListeners() {
    debugPrint('🎮 [ReactionScreen] Setting up socket listeners, myId=$_myId');

    _socketListeners.on('waiting_for_match', (_) {
      debugPrint('🎮 [ReactionScreen] waiting_for_match received');
      setState(() => _status = ReactionGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      debugPrint('🎮 [ReactionScreen] match_found received: $data');
      debugPrint('🎮 [ReactionScreen] Current _myId=$_myId');
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);
      debugPrint('🎮 [ReactionScreen] myPlayerIndex=$_myPlayerIndex, me=$me');

      setState(() {
        _status = ReactionGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        // 프로필 설정
        if (me != null && me['profileSettings'] != null) {
          _myProfileSettings = UserProfileSettings.fromJson(me['profileSettings']);
        }
        if (opponent['profileSettings'] != null) {
          _opponentProfileSettings = UserProfileSettings.fromJson(opponent['profileSettings']);
        }
      });
      debugPrint('🎮 [ReactionScreen] Status changed to matched');
    });

    _socketListeners.on('game_start', (data) {
      debugPrint('🎮 [ReactionScreen] game_start received: $data');
      debugPrint('🎮 [ReactionScreen] Current status=$_status, rematchWaiting=$_rematchWaiting');
      if (data['gameType'] == 'reaction') {
        // finished 상태에서 재경기 요청 안 했으면 무시
        if (_status == ReactionGameStatus.finished && !_rematchWaiting) {
          debugPrint('🎮 [ReactionScreen] ❌ game_start ignored: not waiting for rematch');
          return;
        }
        // 게임 시작 시 모든 SnackBar 제거 (중복 알림 방지)
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
        }
        debugPrint('🎮 [ReactionScreen] ✅ Processing game_start for reaction');
        setState(() {
          _status = ReactionGameStatus.playing;
          _currentRound = 0;
          _scores = [0, 0];
          _roundState = RoundState.waiting;
          // 이전 라운드 결과 리셋
          _lastRoundFalseStart = null;
          _lastRoundWinnerNickname = null;
          _lastReactionTime = null;
          _pressedPlayerNickname = null;
          // 재경기 상태 리셋
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
        });
        debugPrint('🎮 [ReactionScreen] Status changed to playing');
      } else {
        debugPrint('🎮 [ReactionScreen] game_start ignored: gameType is ${data['gameType']}, not reaction');
      }
    });

    _socketListeners.on('reaction_round_ready', (data) {
      setState(() {
        _currentRound = data['round'];
        _scores = List<int>.from(data['scores']);
        _roundState = RoundState.ready;
        _lastRoundFalseStart = null;
        _lastRoundWinnerNickname = null;
        _lastReactionTime = null;
        _pressedPlayerNickname = null;
      });
    });

    _socketListeners.on('reaction_round_go', (data) {
      setState(() {
        _roundState = RoundState.go;
      });
    });

    _socketListeners.on('reaction_round_result', (data) {
      setState(() {
        _roundState = RoundState.result;
        _lastRoundFalseStart = data['falseStart'];
        _lastRoundWinnerNickname = data['winnerNickname'];
        _lastReactionTime = data['reactionTime'];
        _pressedPlayerNickname = data['pressedPlayerNickname'];
        _scores = List<int>.from(data['scores']);
      });
    });

    _socketListeners.on('reaction_round_timeout', (data) {
      setState(() {
        _roundState = RoundState.result;
        _lastRoundFalseStart = false;
        _lastRoundWinnerNickname = null; // 무승부
        _lastReactionTime = null;
      });
    });

    _socketListeners.on('game_end', (data) {
      if (_status == ReactionGameStatus.finished) return;
      setState(() {
        _status = ReactionGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        if (data['scores'] != null) {
          _scores = List<int>.from(data['scores']);
        }
      });
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == ReactionGameStatus.idle ||
          _status == ReactionGameStatus.searching ||
          _status == ReactionGameStatus.finished) return;
      // 나가기 다이얼로그가 열려있으면 먼저 닫기
      if (_isExitDialogOpen && mounted) {
        Navigator.of(context).pop();
        _isExitDialogOpen = false;
      }
      setState(() {
        _status = ReactionGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
      });
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

    _socketListeners.on('rematch_waiting', (data) {
      setState(() => _rematchWaiting = data['waiting'] ?? false);
    });

    _socketListeners.on('rematch_requested', (_) {
      setState(() => _opponentWantsRematch = true);
    });

    _socketListeners.on('rematch_cancelled', (_) {
      setState(() => _opponentWantsRematch = false);
    });

    // 에러 처리 (방이 없어진 경우 등)
    _socketListeners.on('error', (data) {
      final message = data['message'] ?? '';
      if (message.toString().contains('Invalid room') ||
          message.toString().contains('not in progress')) {
        _handleRoomInvalid();
      }
    });
  }

  void _handleRoomInvalid() {
    if (!mounted || _hasScheduledPop) return;
    _hasScheduledPop = true;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('연결이 끊어져 게임이 종료되었습니다.'),
        backgroundColor: Colors.orange,
      ),
    );

    // GameProvider 초기화 후 로비로 이동
    try {
      context.read<GameProvider>().reset();
    } catch (_) {}

    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeReaction,
      'isHardcore': _isHardcore,
    });
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeReaction,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = ReactionGameStatus.idle);
  }

  void _pressButton() {
    if (_roundState != RoundState.ready && _roundState != RoundState.go) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'press'},
    });
  }

  void _requestRematch() {
    _socketService.emit('rematch_request', {'roomId': _roomId});
  }

  void _cancelRematch() {
    _socketService.emit('rematch_cancel', {'roomId': _roomId});
    setState(() => _rematchWaiting = false);
  }

  void _leaveGame() {
    String? roomId = _roomId;
    if (widget.isRanked && roomId == null) {
      try {
        roomId = context.read<RankedProvider>().roomId;
      } catch (_) {}
    }
    if (roomId != null) {
      _socketService.emit('leave_room', {'roomId': roomId});
    }
    // GameProvider 상태도 초기화
    try {
      context.read<GameProvider>().reset();
    } catch (_) {}
    _reset();
  }

  void _reset() {
    setState(() {
      _status = ReactionGameStatus.idle;
      _roundState = RoundState.waiting;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _currentRound = 0;
      _scores = [0, 0];
      _winnerId = null;
      _isDraw = false;
      _opponentLeft = false;
      _rematchWaiting = false;
      _opponentWantsRematch = false;
      _isInvitationGame = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final shop = context.watch<ShopProvider>();
    final theme = GameTheme.fromProfileSettings(shop.profileSettings);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitDialog();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('반응속도'),
          backgroundColor: theme.primary,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _showExitDialog,
          ),
        ),
        body: _buildBody(theme),
      ),
    );
  }

  Widget _buildRankedWaitingView(GameTheme theme) {
    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('게임 준비 중...', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      ReactionGameStatus.idle => widget.isRanked ? _buildRankedWaitingView(theme) : _buildIdleView(theme),
      ReactionGameStatus.searching => widget.isRanked ? _buildRankedWaitingView(theme) : _buildSearchingView(theme),
      ReactionGameStatus.matched => widget.isRanked ? _buildRankedWaitingView(theme) : _buildMatchedView(theme),
      ReactionGameStatus.playing => _buildPlayingView(theme),
      ReactionGameStatus.finished => _buildFinishedView(theme),
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
                                    AppConfig.gameTypeReaction,
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
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.flash_on,
                size: 80,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '반응속도',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '초록불이 켜지면 빨리 터치!',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '5라운드 중 먼저 3점!',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade500,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _findMatch,
                  icon: const Icon(Icons.search),
                  label: const Text('상대 찾기'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primary,
                    foregroundColor: theme.textOnPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => _showFriendInviteDialog(context),
                  icon: const Icon(Icons.person_add),
                  label: const Text('친구 초대'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.primary,
                    side: BorderSide(color: theme.primary),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchingView(GameTheme theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                color: theme.primary,
                strokeWidth: 4,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey.shade700,
              ),
            ),
            const SizedBox(height: 48),
            OutlinedButton(
              onPressed: _cancelMatch,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.primary,
                side: BorderSide(color: theme.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
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
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.background1,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.sports_esports,
                size: 64,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: theme.primary,
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
        // 프로필 & 점수판
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFFADADA), Color(0xFFFFF0F0)],
            ),
          ),
          child: Row(
            children: [
              // 내 프로필
              Expanded(
                child: GamePlayerProfile(
                  name: _myNickname ?? '나',
                  avatarUrl: _myAvatarUrl,
                  isActive: true,
                  isMe: true,
                  profileSettings: _myProfileSettings ?? context.read<ShopProvider>().profileSettings,
                  activeColor: const Color(0xFFE74C3C),
                  extraWidget: _buildScoreWidget(_scores[_myPlayerIndex]),
                ),
              ),
              // 라운드 표시
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE74C3C),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'R$_currentRound/5',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'VS',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFE74C3C),
                      ),
                    ),
                  ],
                ),
              ),
              // 상대 프로필
              Expanded(
                child: GamePlayerProfile(
                  name: _opponentNickname ?? '상대',
                  avatarUrl: _opponentAvatarUrl,
                  isActive: true,
                  isMe: false,
                  profileSettings: _opponentProfileSettings,
                  activeColor: const Color(0xFFE74C3C),
                  extraWidget: _buildScoreWidget(_scores[1 - _myPlayerIndex]),
                ),
              ),
            ],
          ),
        ),

        // 게임 영역
        Expanded(
          child: GestureDetector(
            onTap: _pressButton,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: _getBackgroundColor(),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildRoundContent(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildScoreWidget(int score) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFE74C3C),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '$score',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Color _getBackgroundColor() {
    return switch (_roundState) {
      RoundState.waiting => Colors.grey.shade300,
      RoundState.ready => const Color(0xFFE74C3C), // 빨간색
      RoundState.go => const Color(0xFF27AE60), // 초록색
      RoundState.result => Colors.grey.shade200,
    };
  }

  Widget _buildRoundContent() {
    return switch (_roundState) {
      RoundState.waiting => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.hourglass_empty, size: 80, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            Text(
              '준비...',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
      RoundState.ready => const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pan_tool, size: 80, color: Colors.white),
            SizedBox(height: 16),
            Text(
              '기다려!',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 8),
            Text(
              '초록불이 켜지면 터치',
              style: TextStyle(
                fontSize: 18,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      RoundState.go => const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.touch_app, size: 80, color: Colors.white),
            SizedBox(height: 16),
            Text(
              '터치!',
              style: TextStyle(
                fontSize: 48,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      RoundState.result => _buildResultContent(),
    };
  }

  Widget _buildResultContent() {
    if (_lastRoundFalseStart == true) {
      final isMeFalseStart = _pressedPlayerNickname != _opponentNickname;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.warning,
            size: 80,
            color: isMeFalseStart ? Colors.red : Colors.green,
          ),
          const SizedBox(height: 16),
          Text(
            isMeFalseStart ? '부정출발!' : '상대 부정출발!',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: isMeFalseStart ? Colors.red : Colors.green,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isMeFalseStart ? '상대방 +1점' : '나 +1점',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey.shade700,
            ),
          ),
        ],
      );
    }

    if (_lastReactionTime != null) {
      final isMyWin = _lastRoundWinnerNickname != _opponentNickname;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isMyWin ? Icons.emoji_events : Icons.sentiment_dissatisfied,
            size: 80,
            color: isMyWin ? Colors.amber : Colors.grey,
          ),
          const SizedBox(height: 16),
          Text(
            isMyWin ? '승리!' : '아쉬워요',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: isMyWin ? Colors.amber.shade700 : Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_lastReactionTime}ms',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.timer_off, size: 80, color: Colors.grey.shade600),
        const SizedBox(height: 16),
        Text(
          '시간 초과',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade700,
          ),
        ),
      ],
    );
  }

  Widget _buildScoreCard(String name, int score, bool isMe) {
    return Column(
      children: [
        Text(
          name,
          style: TextStyle(
            fontSize: 14,
            color: isMe ? const Color(0xFFE74C3C) : Colors.grey.shade600,
            fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFFE74C3C) : Colors.grey,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$score',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFinishedView(GameTheme theme) {
    final isWinner = _winnerId == _myId;

    // 랭크전에서는 결과만 표시하고 자동으로 돌아가기
    if (widget.isRanked) {
      if (!_hasScheduledPop) {
        _hasScheduledPop = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted) Navigator.pop(context);
          });
        });
      }
      return Container(
        decoration: BoxDecoration(gradient: theme.backgroundGradient),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isDraw ? Icons.handshake : (isWinner ? Icons.emoji_events : Icons.sentiment_dissatisfied),
                size: 80,
                color: _isDraw ? Colors.orange : (isWinner ? Colors.amber : Colors.grey),
              ),
              const SizedBox(height: 16),
              Text(
                _isDraw ? '무승부!' : (isWinner ? '승리!' : '패배'),
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: _isDraw ? Colors.orange : (isWinner ? theme.primary : Colors.grey),
                ),
              ),
              const SizedBox(height: 24),
              const Text('잠시 후 다음 게임...', style: TextStyle(color: Colors.grey)),
            ],
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
      resultColor = const Color(0xFFE74C3C);
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: resultColor.withValues(alpha: 0.3),
                    blurRadius: 20,
                  ),
                ],
              ),
              child: Icon(resultIcon, size: 64, color: resultColor),
            ),
            const SizedBox(height: 24),
            Text(
              resultText,
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: resultColor,
              ),
            ),
            const SizedBox(height: 16),
            // 최종 점수
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildScoreCard('나', _scores[_myPlayerIndex], true),
                const SizedBox(width: 32),
                const Text(
                  ':',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 32),
                _buildScoreCard(_opponentNickname ?? '상대', _scores[1 - _myPlayerIndex], false),
              ],
            ),
            const SizedBox(height: 24),
            if (_opponentLeft)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.exit_to_app, size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 8),
                    Text(
                      '상대방이 나갔습니다',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            if (_opponentWantsRematch && !_opponentLeft)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.hourglass_top, size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 8),
                    Text(
                      '$_opponentNickname님이 대기 중...',
                      style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!_opponentLeft)
                  ElevatedButton.icon(
                    onPressed: _rematchWaiting ? _cancelRematch : _requestRematch,
                    icon: Icon(_rematchWaiting ? Icons.hourglass_top : Icons.replay),
                    label: Text(_rematchWaiting ? '대기 중...' : '재경기'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _rematchWaiting ? Colors.orange : const Color(0xFFE74C3C),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  ),
                if (!_isInvitationGame)
                  OutlinedButton.icon(
                    onPressed: () {
                      _leaveGame();
                      _findMatch();
                    },
                    icon: const Icon(Icons.search),
                    label: const Text('다시 찾기'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE74C3C),
                      side: const BorderSide(color: Color(0xFFE74C3C)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  ),
                if (!_isInvitationGame && !_opponentLeft && _opponentUserId != null && !context.read<FriendProvider>().isFriend(_opponentUserId!))
                  OutlinedButton.icon(
                    onPressed: () {
                      context.read<FriendProvider>().sendFriendRequestByUserId(_opponentUserId!);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('$_opponentNickname님에게 친구 요청을 보냈습니다'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.person_add),
                    label: const Text('친구 요청'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green,
                      side: const BorderSide(color: Colors.green),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () {
                    _leaveGame();
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.home),
                  label: const Text('로비'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey,
                    side: BorderSide(color: Colors.grey.shade400),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showExitDialog() {
    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && _status == ReactionGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting = widget.isRanked &&
        (_status == ReactionGameStatus.idle ||
            _status == ReactionGameStatus.searching ||
            _status == ReactionGameStatus.matched);

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    if (isRankedWaiting) {
      _leaveGame();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (_status == ReactionGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }

    _isExitDialogOpen = true;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.exit_to_app, color: Color(0xFFE74C3C)),
            SizedBox(width: 8),
            Text('게임 나가기'),
          ],
        ),
        content: Text(
          isRankedWaiting
              ? '랭크전 진행 중입니다.\n나가시겠습니까?'
              : '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              _leaveGame();
              Navigator.pop(context);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE74C3C),
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    ).then((_) => _isExitDialogOpen = false);
  }
}
