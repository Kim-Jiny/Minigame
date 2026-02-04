import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/game_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';
import '../../models/shop_item.dart';
import '../../widgets/game_player_profile.dart';
import '../../utils/game_theme.dart';

enum SequenceGameStatus {
  idle,
  searching,
  matched,
  showing, // 시퀀스 보여주는 중
  playing, // 입력 대기 중
  waiting, // 상대 입력 대기 중
  finished,
}

class SequenceScreen extends StatefulWidget {
  final bool isRanked;

  const SequenceScreen({super.key, this.isRanked = false});

  @override
  State<SequenceScreen> createState() => _SequenceScreenState();
}

class _SequenceScreenState extends State<SequenceScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  bool _hasScheduledPop = false;  // 중복 pop 방지

  SequenceGameStatus _status = SequenceGameStatus.idle;

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

  int _gridSize = 9; // 3x3
  List<int> _sequence = [];
  int _currentLevel = 0;
  int _showingIndex = -1; // 현재 보여주고 있는 시퀀스 인덱스
  int _showDelay = 600;
  bool _isHardcore = false; // 하드코어 모드

  List<int> _myInputs = [];
  bool _myFailed = false;
  bool _opponentFailed = false;
  int _myMaxLevel = 0;
  int _opponentMaxLevel = 0;

  // 게임 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;

  // 타이머
  int _timeLimit = 0; // ms
  int _remainingSeconds = 0;
  Timer? _countdownTimer;

  // 애니메이션
  Timer? _showTimer;
  int? _lastInputPosition;
  bool? _lastInputCorrect;
  Timer? _feedbackTimer;

  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
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
      if (game.isInvitationGame && game.roomId != null && game.opponentNickname != null) {
        debugPrint('🎮 SequenceScreen: 초대 게임 초기화 from GameProvider');
        setState(() {
          _roomId = game.roomId;
          _opponentNickname = game.opponentNickname;
          _opponentAvatarUrl = game.opponentAvatarUrl;
          _opponentUserId = game.opponentUserId;
          _isInvitationGame = true;
          _status = SequenceGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 SequenceScreen: GameProvider 초기화 실패: $e');
    }
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _feedbackTimer?.cancel();
    _countdownTimer?.cancel();
    _animController.dispose();
    _removeSocketListeners();
    super.dispose();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _remainingSeconds = (_timeLimit / 1000).ceil();
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

  void _setupSocketListeners() {
    _socketService.on('waiting_for_match', (_) {
      setState(() => _status = SequenceGameStatus.searching);
    });

    _socketService.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = SequenceGameStatus.matched;
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

    _socketService.on('game_start', (data) {
      debugPrint('🎮 game_start received: $data');
      debugPrint('🎮 gameType: ${data['gameType']}');
      if (data['gameType'] == 'sequence') {
        // finished 상태에서 재경기 요청 안 했으면 무시
        if (_status == SequenceGameStatus.finished && !_rematchWaiting) {
          debugPrint('game_start ignored: not waiting for rematch');
          return;
        }
        debugPrint('🎮 Starting sequence game!');
        setState(() {
          _gridSize = data['gridSize'] ?? 9;
          _sequence = List<int>.from(data['sequence'] ?? []);
          _currentLevel = data['level'] ?? _sequence.length;
          _showDelay = data['showDelay'] ?? 600;
          _timeLimit = data['timeLimit'] ?? 9000;
          _remainingSeconds = (_timeLimit / 1000).ceil();
          _isHardcore = data['isHardcore'] ?? false;
          _myInputs = [];
          _myFailed = false;
          _opponentFailed = false;
          _myMaxLevel = 0;
          _opponentMaxLevel = 0;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
        });
        _showSequence();
      }
    });

    _socketService.on('sequence_show', (data) {
      setState(() {
        _sequence = List<int>.from(data['sequence']);
        _currentLevel = data['level'];
        _showDelay = data['showDelay'] ?? 600;
        _timeLimit = data['timeLimit'] ?? 9000;
        _remainingSeconds = (_timeLimit / 1000).ceil();
        _myInputs = [];
      });
      _showSequence();
    });

    _socketService.on('sequence_timeout', (data) {
      final playerIndex = data['playerIndex'] as int;
      if (playerIndex == _myPlayerIndex) {
        _stopCountdown();
        setState(() {
          _myFailed = true;
          _status = SequenceGameStatus.waiting;
        });
      } else {
        setState(() => _opponentFailed = true);
      }
    });

    _socketService.on('sequence_input', (data) {
      final playerIndex = data['playerIndex'] as int;
      final failed = data['failed'] as bool;

      if (playerIndex != _myPlayerIndex) {
        // 상대방 입력
        if (failed) {
          setState(() => _opponentFailed = true);
        }
      }
    });

    _socketService.on('sequence_round_complete', (data) {
      // 둘 다 성공 - 다음 라운드 대기
      setState(() {
        _myMaxLevel = _currentLevel;
        _status = SequenceGameStatus.waiting;
      });
    });

    _socketService.on('game_end', (data) {
      _showTimer?.cancel();
      _stopCountdown();
      setState(() {
        _status = SequenceGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        if (data['maxLevels'] != null) {
          final maxLevels = List<int>.from(data['maxLevels']);
          _myMaxLevel = maxLevels[_myPlayerIndex];
          _opponentMaxLevel = maxLevels[1 - _myPlayerIndex];
        } else {
          _myMaxLevel = data['player${_myPlayerIndex}Level'] ?? 0;
          _opponentMaxLevel = data['player${1 - _myPlayerIndex}Level'] ?? 0;
        }
      });
    });

    _socketService.on('opponent_left', (_) {
      setState(() {
        _status = SequenceGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
      });
    });

    _socketService.on('rematch_waiting', (data) {
      setState(() => _rematchWaiting = data['waiting'] ?? false);
    });

    _socketService.on('rematch_requested', (_) {
      setState(() => _opponentWantsRematch = true);
    });

    _socketService.on('rematch_cancelled', (_) {
      setState(() => _opponentWantsRematch = false);
    });
  }

  void _removeSocketListeners() {
    _socketService.off('waiting_for_match');
    _socketService.off('match_found');
    _socketService.off('game_start');
    _socketService.off('sequence_show');
    _socketService.off('sequence_input');
    _socketService.off('sequence_timeout');
    _socketService.off('sequence_round_complete');
    _socketService.off('game_end');
    _socketService.off('opponent_left');
    _socketService.off('rematch_waiting');
    _socketService.off('rematch_requested');
    _socketService.off('rematch_cancelled');
  }

  void _showSequence() {
    debugPrint('🎮 _showSequence called! sequence: $_sequence');
    setState(() {
      _status = SequenceGameStatus.showing;
      _showingIndex = -1;
    });
    debugPrint('🎮 Status changed to showing');

    int index = 0;
    final int gapDuration = _isHardcore ? 100 : 180; // 하드코어는 gap도 짧게
    _showTimer?.cancel();

    void showNext() {
      if (!mounted) return;

      if (index < _sequence.length) {
        // 칸 켜기
        setState(() => _showingIndex = index);

        // showDelay 후 칸 끄기
        Future.delayed(Duration(milliseconds: _showDelay), () {
          if (!mounted) return;
          setState(() => _showingIndex = -1);

          // gap 후 다음 칸
          Future.delayed(Duration(milliseconds: gapDuration), () {
            index++;
            showNext();
          });
        });
      } else {
        // 시퀀스 다 보여준 후 입력 모드
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            setState(() {
              _showingIndex = -1;
              _status = SequenceGameStatus.playing;
            });
            _startCountdown();
          }
        });
      }
    }

    // 첫 번째 시작
    Future.delayed(const Duration(milliseconds: 500), showNext);
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeSequence,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = SequenceGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeSequence,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = SequenceGameStatus.idle);
  }

  void _onCellTap(int position) {
    if (_status != SequenceGameStatus.playing || _myFailed || _roomId == null) {
      return;
    }

    final inputIndex = _myInputs.length;
    final expectedPosition = _sequence[inputIndex];
    final isCorrect = position == expectedPosition;

    setState(() {
      _myInputs.add(position);
      _lastInputPosition = position;
      _lastInputCorrect = isCorrect;
    });

    // 피드백 타이머
    _feedbackTimer?.cancel();
    _feedbackTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        setState(() {
          _lastInputPosition = null;
          _lastInputCorrect = null;
        });
      }
    });

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'position': position},
    });

    if (!isCorrect) {
      _stopCountdown();
      setState(() {
        _myFailed = true;
        _myMaxLevel = _currentLevel - 1;
        _status = SequenceGameStatus.waiting;
      });
    } else if (_myInputs.length == _sequence.length) {
      // 현재 레벨 완료
      _stopCountdown();
      setState(() {
        _myMaxLevel = _currentLevel;
        _status = SequenceGameStatus.waiting;
      });
    }
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
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    _reset();
  }

  void _reset() {
    _showTimer?.cancel();
    _feedbackTimer?.cancel();
    setState(() {
      _status = SequenceGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _sequence = [];
      _currentLevel = 0;
      _myInputs = [];
      _myFailed = false;
      _opponentFailed = false;
      _winnerId = null;
      _isDraw = false;
      _opponentLeft = false;
      _rematchWaiting = false;
      _opponentWantsRematch = false;
      _isInvitationGame = false;
    });
  }

  GameTheme get _theme => GameTheme.fromProfileSettings(_myProfileSettings);

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitDialog();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('순서 기억하기'),
          backgroundColor: theme.primary,
          foregroundColor: theme.textOnPrimary,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _showExitDialog,
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildRankedWaitingView() {
    return Container(
      decoration: BoxDecoration(gradient: _theme.backgroundGradient),
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

  Widget _buildBody() {
    return switch (_status) {
      SequenceGameStatus.idle => widget.isRanked ? _buildRankedWaitingView() : _buildIdleView(),
      SequenceGameStatus.searching => widget.isRanked ? _buildRankedWaitingView() : _buildSearchingView(),
      SequenceGameStatus.matched => widget.isRanked ? _buildRankedWaitingView() : _buildMatchedView(),
      SequenceGameStatus.showing => _buildShowingView(),
      SequenceGameStatus.playing => _buildPlayingView(),
      SequenceGameStatus.waiting => _buildWaitingView(),
      SequenceGameStatus.finished => _buildFinishedView(),
    };
  }

  void _showFriendInviteDialog(BuildContext context) {
    final friendProvider = context.read<FriendProvider>();
    final onlineFriends = friendProvider.friends.where((f) => f.isOnline).toList();
    final theme = _theme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
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
                                AppConfig.gameTypeSequence,
                                isHardcore: _isHardcore,
                              );
                              Navigator.pop(context);
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
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  Widget _buildIdleView() {
    final theme = _theme;
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
                Icons.psychology,
                size: 64,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              '순서 기억하기',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '깜빡이는 순서를 기억하세요!',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '더 많이 기억한 사람이 승리!',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade500,
              ),
            ),
            const SizedBox(height: 32),
            // 하드코어 모드 토글
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _isHardcore
                    ? Colors.red.shade50
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _isHardcore ? Colors.red.shade300 : Colors.grey.shade300,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.local_fire_department,
                    color: _isHardcore ? Colors.red : Colors.grey,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '하드코어',
                    style: TextStyle(
                      color: _isHardcore ? Colors.red : Colors.grey.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: _isHardcore,
                    onChanged: (value) => setState(() => _isHardcore = value),
                    activeColor: Colors.red,
                    activeTrackColor: Colors.red.shade200,
                  ),
                ],
              ),
            ),
            if (_isHardcore)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '2배 빠른 속도!',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.red.shade400,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _findMatch,
                  icon: const Icon(Icons.search),
                  label: Text(_isHardcore ? '하드코어 상대 찾기' : '상대 찾기'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isHardcore ? Colors.red : theme.primary,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
                    foregroundColor: _isHardcore ? Colors.red : theme.primary,
                    side: BorderSide(
                      color: _isHardcore ? Colors.red : theme.primary,
                    ),
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

  Widget _buildSearchingView() {
    final theme = _theme;
    return Container(
      decoration: BoxDecoration(
        gradient: theme.backgroundGradient,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: theme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: theme.primary,
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

  Widget _buildMatchedView() {
    final theme = _theme;
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

  Widget _buildShowingView() {
    final theme = _theme;
    final totalSeconds = (_timeLimit / 1000).ceil();
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: theme.backgroundGradient,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 타이머 미리보기 (카운트다운 전)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.timer,
                        size: 20,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$totalSeconds초',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '순서를 기억하세요!',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: theme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                _buildGrid(enabled: false),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlayingView() {
    final theme = _theme;
    final isLowTime = _remainingSeconds <= 3;
    return Column(
      children: [
        _buildHeader(),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: theme.backgroundGradient,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 타이머 표시
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isLowTime ? Colors.red.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: isLowTime ? Colors.red : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.timer,
                        size: 20,
                        color: isLowTime ? Colors.red : Colors.grey.shade600,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$_remainingSeconds초',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isLowTime ? Colors.red : Colors.grey.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '순서대로 터치! (${_myInputs.length}/${_sequence.length})',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: theme.primary,
                  ),
                ),
                const SizedBox(height: 24),
                _buildGrid(enabled: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWaitingView() {
    final message = _myFailed ? '틀렸습니다! 상대를 기다리는 중...' : '완료! 상대를 기다리는 중...';
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
                  (_myFailed ? Colors.red : Colors.green).withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _myFailed ? Icons.close : Icons.check_circle,
                    size: 64,
                    color: _myFailed ? Colors.red : Colors.green,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: _myFailed ? Colors.red : Colors.green,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(color: Color(0xFF9B59B6)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF3E5F5), Color(0xFFFCE4EC)],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: GamePlayerProfile(
              name: _myNickname ?? '나',
              avatarUrl: _myAvatarUrl,
              isActive: !_myFailed,
              isMe: true,
              profileSettings: _myProfileSettings,
              activeColor: const Color(0xFF9B59B6),
              extraWidget: _buildStatusWidget(_myFailed),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF9B59B6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Lv.$_currentLevel',
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
                    color: Color(0xFF9B59B6),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GamePlayerProfile(
              name: _opponentNickname ?? '상대',
              avatarUrl: _opponentAvatarUrl,
              isActive: !_opponentFailed,
              isMe: false,
              profileSettings: _opponentProfileSettings,
              activeColor: const Color(0xFF9B59B6),
              extraWidget: _buildStatusWidget(_opponentFailed),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusWidget(bool failed) {
    if (!failed) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'OUT',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildGrid({required bool enabled}) {
    // gridSize: 9 = 3x3, 16 = 4x4
    final gridDimension = _gridSize == 16 ? 4 : 3;
    final cellSize = MediaQuery.of(context).size.width / (gridDimension + 1.5);

    return Center(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF9B59B6).withValues(alpha: 0.2),
              blurRadius: 20,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(gridDimension, (row) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(gridDimension, (col) {
                final position = row * gridDimension + col;
                return _buildCell(
                  position,
                  cellSize,
                  enabled: enabled,
                );
              }),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildCell(int position, double size, {required bool enabled}) {
    final isShowing =
        _showingIndex >= 0 && _sequence[_showingIndex] == position;
    final isLastInput = _lastInputPosition == position;
    final isCorrectInput = isLastInput && _lastInputCorrect == true;
    final isWrongInput = isLastInput && _lastInputCorrect == false;
    final alreadyInput = _myInputs.contains(position) && !isLastInput;

    Color cellColor = Colors.grey.shade200;
    if (isShowing) {
      cellColor = const Color(0xFF9B59B6);
    } else if (isCorrectInput) {
      cellColor = Colors.green;
    } else if (isWrongInput) {
      cellColor = Colors.red;
    } else if (alreadyInput) {
      cellColor = const Color(0xFF9B59B6).withValues(alpha: 0.3);
    }

    return GestureDetector(
      onTap: enabled ? () => _onCellTap(position) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size - 8,
        height: size - 8,
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: cellColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: isShowing
              ? [
                  BoxShadow(
                    color: const Color(0xFF9B59B6).withValues(alpha: 0.5),
                    blurRadius: 15,
                    spreadRadius: 2,
                  )
                ]
              : null,
        ),
        child: Center(
          child: isShowing
              ? const Icon(Icons.star, color: Colors.white, size: 32)
              : null,
        ),
      ),
    );
  }

  Widget _buildFinishedView() {
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
        decoration: BoxDecoration(gradient: _theme.backgroundGradient),
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
                  color: _isDraw ? Colors.orange : (isWinner ? _theme.primary : Colors.grey),
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
            // 최고 레벨 비교
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLevelCard('나', _myMaxLevel, true),
                const SizedBox(width: 32),
                const Text(':',
                    style:
                        TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(width: 32),
                _buildLevelCard(_opponentNickname ?? '상대', _opponentMaxLevel, false),
              ],
            ),
            const SizedBox(height: 24),
            if (_opponentLeft)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.exit_to_app,
                        size: 16, color: Colors.grey.shade600),
                    const SizedBox(width: 8),
                    Text('상대방이 나갔습니다',
                        style: TextStyle(color: Colors.grey.shade600)),
                  ],
                ),
              ),
            if (_opponentWantsRematch && !_opponentLeft)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.hourglass_top,
                        size: 16, color: Colors.green.shade700),
                    const SizedBox(width: 8),
                    Text(
                      '$_opponentNickname님이 대기 중...',
                      style: TextStyle(
                          color: Colors.green.shade700,
                          fontWeight: FontWeight.w500),
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
                    onPressed:
                        _rematchWaiting ? _cancelRematch : _requestRematch,
                    icon: Icon(
                        _rematchWaiting ? Icons.hourglass_top : Icons.replay),
                    label: Text(_rematchWaiting ? '대기 중...' : '재경기'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _rematchWaiting
                          ? Colors.orange
                          : const Color(0xFF9B59B6),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
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
                      foregroundColor: const Color(0xFF9B59B6),
                      side: const BorderSide(color: Color(0xFF9B59B6)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
                if (!_isInvitationGame &&
                    !_opponentLeft &&
                    _opponentUserId != null &&
                    !context.read<FriendProvider>().isFriend(_opponentUserId!))
                  OutlinedButton.icon(
                    onPressed: () {
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
                    icon: const Icon(Icons.person_add),
                    label: const Text('친구 요청'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green,
                      side: const BorderSide(color: Colors.green),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
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
                        borderRadius: BorderRadius.circular(30)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLevelCard(String name, int level, bool isMe) {
    return Column(
      children: [
        Text(
          name,
          style: TextStyle(
            fontSize: 14,
            color: isMe ? const Color(0xFF9B59B6) : Colors.grey.shade600,
            fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFF9B59B6) : Colors.grey,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            'Lv.$level',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  void _showExitDialog() {
    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && _status == SequenceGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크 게임에서 대기 중인 상태인지 확인
    final isRankedWaiting = widget.isRanked &&
        (_status == SequenceGameStatus.idle ||
            _status == SequenceGameStatus.searching ||
            _status == SequenceGameStatus.matched);

    // 랭크전 대기 중이면 경고 없이 나가기
    if (isRankedWaiting) {
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (_status == SequenceGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.exit_to_app, color: Color(0xFF9B59B6)),
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
              backgroundColor: const Color(0xFF9B59B6),
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
