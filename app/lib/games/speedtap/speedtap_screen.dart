import 'dart:async';
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
import '../../utils/game_theme.dart';
import '../../widgets/game_player_profile.dart';

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
  final SocketListenerRegistry _socketListeners = SocketListenerRegistry(SocketService());
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
    _animController.dispose();
    _socketListeners.offAll();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    _remainingSeconds = seconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
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

  void _runStartCountdown(int from) {
    _startCountdownTimer?.cancel();
    _preRoundCountdown = from;
    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_preRoundCountdown > 1) {
        setState(() => _preRoundCountdown--);
      } else {
        timer.cancel();
        setState(() => _preRoundCountdown = 0);
      }
    });
  }

  void _setupSocketListeners() {
    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = SpeedTapGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
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
      });
      _startCountdown(duration ~/ 1000);
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
      });
    });

    _socketListeners.on('game_end', (data) {
      if (_status == SpeedTapGameStatus.finished) return;
      _stopCountdown();
      setState(() {
        _status = SpeedTapGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        if (data['roundScores'] != null) {
          _roundScores = List<int>.from(data['roundScores']);
        }
      });
    });

    _socketListeners.on('opponent_left', (data) {
      if (_status == SpeedTapGameStatus.idle ||
          _status == SpeedTapGameStatus.searching) return;
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
      });
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
    // 랭크전인 경우 RankedProvider에서 roomId 가져오기
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
            appBar: AppBar(
              title: const Text('스피드 탭'),
              backgroundColor: theme.primary,
              foregroundColor: Colors.white,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _showExitDialog(theme),
              ),
            ),
            body: _buildBody(theme),
          ),
        );
      },
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
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: theme.primary.withValues(alpha: 0.3),
                    blurRadius: 20,
                  ),
                ],
              ),
              child: Icon(
                Icons.touch_app,
                size: 64,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              '스피드 탭',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '10초 동안 빠르게 터치!',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '3라운드 중 2라운드 승리!',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade500,
              ),
            ),
            const SizedBox(height: 48),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _findMatch,
                  icon: const Icon(Icons.search),
                  label: const Text('상대 찾기'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primary,
                    foregroundColor: Colors.white,
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
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF00CEC9).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              color: Color(0xFF00CEC9),
            ),
            const SizedBox(height: 24),
            const Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF00CEC9),
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
            const Color(0xFF00CEC9).withValues(alpha: 0.1),
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
              child: const Icon(
                Icons.sports_esports,
                size: 64,
                color: Color(0xFF00CEC9),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF00CEC9),
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFE0F7FA), Color(0xFFF0FAFA)],
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: GamePlayerProfile(
                  name: _myNickname ?? '나',
                  avatarUrl: _myAvatarUrl,
                  isActive: true,
                  isMe: true,
                  profileSettings: _myProfileSettings,
                  activeColor: const Color(0xFF00CEC9),
                  extraWidget: _buildTapScoreWidget(_taps[_myPlayerIndex], _roundScores[_myPlayerIndex], true),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00CEC9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'R$_currentRound',
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
                        color: Color(0xFF00CEC9),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GamePlayerProfile(
                  name: _opponentNickname ?? '상대',
                  avatarUrl: _opponentAvatarUrl,
                  isActive: false,
                  isMe: false,
                  profileSettings: _opponentProfileSettings,
                  activeColor: const Color(0xFF00CEC9),
                  extraWidget: _buildTapScoreWidget(_taps[1 - _myPlayerIndex], _roundScores[1 - _myPlayerIndex], false),
                ),
              ),
            ],
          ),
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
        // 탭 카운트
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFF00CEC9) : Colors.grey,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$tapCount',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 2),
        // 라운드 승리 수
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(2, (index) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Icon(
                index < roundWins ? Icons.star : Icons.star_border,
                size: 14,
                color: index < roundWins ? Colors.amber : Colors.grey.shade300,
              ),
            );
          }),
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
            const Color(0xFF00CEC9).withValues(alpha: 0.3),
            const Color(0xFF00CEC9).withValues(alpha: 0.1),
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
                color: const Color(0xFF00CEC9),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00CEC9).withValues(alpha: 0.5),
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
    final bool isLowTime = _remainingSeconds <= 3;

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
                    const Color(0xFF00CEC9).withValues(alpha: 0.3),
                    const Color(0xFF00CEC9).withValues(alpha: 0.6),
                  ],
                ),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 타이머
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      decoration: BoxDecoration(
                        color: isLowTime ? Colors.red : Colors.white,
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: (isLowTime ? Colors.red : const Color(0xFF00CEC9)).withValues(alpha: 0.3),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Text(
                        '$_remainingSeconds',
                        style: TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          color: isLowTime ? Colors.white : const Color(0xFF00CEC9),
                        ),
                      ),
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
                        color: const Color(0xFF00CEC9).withValues(alpha: 0.8),
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
          Text(
            _lastIsDraw ? '무승부!' : (isMyWin ? '라운드 승리!' : '라운드 패배'),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: _lastIsDraw ? Colors.orange : (isMyWin ? Colors.green : Colors.red),
            ),
          ),
          const SizedBox(height: 32),
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
          Text(
            '다음 라운드 준비 중...',
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ],
      ),
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
      resultColor = const Color(0xFF00CEC9);
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
                _buildFinalScoreCard('나', _roundScores[_myPlayerIndex], true),
                const SizedBox(width: 32),
                const Text(':', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(width: 32),
                _buildFinalScoreCard(_opponentNickname ?? '상대', _roundScores[1 - _myPlayerIndex], false),
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
                    Text('상대방이 나갔습니다', style: TextStyle(color: Colors.grey.shade600)),
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
                      backgroundColor: _rematchWaiting ? Colors.orange : const Color(0xFF00CEC9),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
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
                      foregroundColor: const Color(0xFF00CEC9),
                      side: const BorderSide(color: Color(0xFF00CEC9)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
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
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFinalScoreCard(String name, int score, bool isMe) {
    return Column(
      children: [
        Text(
          name,
          style: TextStyle(
            fontSize: 14,
            color: isMe ? const Color(0xFF00CEC9) : Colors.grey.shade600,
            fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFF00CEC9) : Colors.grey,
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.exit_to_app, color: Color(0xFF00CEC9)),
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
              backgroundColor: const Color(0xFF00CEC9),
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    ).then((_) => _isExitDialogOpen = false);
  }
}
