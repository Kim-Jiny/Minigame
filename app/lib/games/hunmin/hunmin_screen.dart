import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../config/app_config.dart';
import '../../providers/auth_provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/socket_service.dart';
import '../../services/socket_listener_registry.dart';
import '../../models/shop_item.dart';
import '../../utils/game_theme.dart';
import '../common/game_intro_view.dart';
import '../common/game_scaffold.dart';
import '../common/game_end_action_panel.dart';
import '../common/game_reconnect_helper.dart';

enum HunminGameStatus {
  idle,
  searching,
  matched,
  playing,
  roundEnd,
  finished,
}

class HunminScreen extends StatefulWidget {
  const HunminScreen({super.key});

  @override
  State<HunminScreen> createState() => _HunminScreenState();
}

class _HunminScreenState extends State<HunminScreen> with TickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);
  // 게임 고유 다크테마 대신 사용자 테마(라이트)를 사용.
  GameTheme get _theme =>
      GameTheme.fromProfileSettings(context.read<ShopProvider>().profileSettings);

  // 게임 상태
  HunminGameStatus _status = HunminGameStatus.idle;
  // ignore: unused_field
  bool _isInvitationGame = false;

  // 플레이어 정보
  String? _myId;
  String? _myNickname;
  // ignore: unused_field
  String? _myAvatarUrl;
  int _myPlayerIndex = 0;
  String? _opponentNickname;
  // ignore: unused_field
  String? _opponentAvatarUrl;
  // ignore: unused_field
  UserProfileSettings? _myProfileSettings;
  // ignore: unused_field
  UserProfileSettings? _opponentProfileSettings;

  // 방 정보
  String? _roomId;

  // 게임 데이터
  String _currentChosung = '';
  int _currentRound = 0;
  List<int> _scores = [0, 0];
  List<Map<String, dynamic>> _usedWords = []; // {word, playerIndex}
  int _currentTurnPlayer = 0;

  // 입력
  final TextEditingController _wordController = TextEditingController();
  final FocusNode _wordFocusNode = FocusNode();
  bool _isSubmitting = false;

  // 타이머
  Timer? _turnTimer;
  int _turnRemaining = 15;
  static const int _turnTimeLimit = 15;

  // 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  String? _roundEndReason;
  String? _roundEndWord;
  int? _roundWinnerIndex;

  // 재연결
  bool _isReconnecting = false;
  Timer? _reconnectTimer;

  // 리매치
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;

  // 애니메이션
  late AnimationController _resultAnimController;
  String? _lastResultMessage;
  Color? _lastResultColor;
  int _resultAnimationToken = 0;

  @override
  void initState() {
    super.initState();
    _resultAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      _myId = auth.socketId;
      _myNickname = auth.nickname;
      _myAvatarUrl = auth.avatarUrl;
      _myPlayerIndex = 0;

      final shopProvider = context.read<ShopProvider>();
      _myProfileSettings = shopProvider.profileSettings;

      _initFromGameProvider();
      _setupSocketListeners();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _socketListeners.offAll();
    _turnTimer?.cancel();
    _reconnectTimer?.cancel();
    _resultAnimController.dispose();
    _wordController.dispose();
    _wordFocusNode.dispose();
    super.dispose();
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
          _isInvitationGame = true;
          _status = HunminGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('📝 HunminScreen: GameProvider 초기화 실패: $e');
    }
  }

  void _setupSocketListeners() {
    // 소켓 재연결 감지
    _socketListeners.on('connect', (_) {
      final isInGame = _status != HunminGameStatus.idle &&
          _status != HunminGameStatus.finished &&
          _status != HunminGameStatus.searching;
      if (isInGame && _roomId != null) {
        _reconnectTimer?.cancel();
        _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
          context: context,
          onEnterWaiting: () => setState(() => _isReconnecting = true),
          onTimeout: () {
            _turnTimer?.cancel();
            setState(() {
              _isReconnecting = false;
              _status = HunminGameStatus.finished;
              _opponentLeft = true;
            });
          },
        );
      }
    });

    // 재연결 시 게임 상태 복원
    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'hunmin') return;
      _reconnectTimer?.cancel();
      _myId = _socketService.socket?.id;

      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      final usedWordsData = data['usedWords'] as List<dynamic>? ?? [];

      _currentChosung = data['chosung'] as String? ?? '';
      _currentRound = (data['round'] as num?)?.toInt() ?? 0;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? 0;
      _roomId = data['roomId'] as String?;
      _currentTurnPlayer = (data['currentTurnPlayer'] as num?)?.toInt() ?? 0;
      _usedWords = []; // 재연결 시 단어 목록은 리셋

      // usedWords 복원 (서버에서 단어만 보내므로 playerIndex는 번갈아가며)
      for (int i = 0; i < usedWordsData.length; i++) {
        _usedWords.add({
          'word': usedWordsData[i],
          'playerIndex': -1, // 알 수 없음
        });
      }

      _turnTimer?.cancel();
      if (data['roundState'] == 'playing') {
        _status = HunminGameStatus.playing;
        _startTurnTimer();
      }

      GameReconnectHelper.completeReconnect(
        context: context,
        onRecovered: () => setState(() => _isReconnecting = false),
      );
    });

    // 상대방 재연결 알림
    _socketListeners.on('opponent_reconnected', (_) {
      GameReconnectHelper.showOpponentReconnected(context);
    });

    _socketListeners.on('waiting_for_match', (_) {
      setState(() => _status = HunminGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      final players = data['players'] as List<dynamic>;
      _roomId = data['roomId'] as String?;

      // 내가 어떤 인덱스인지 찾기
      for (int i = 0; i < players.length; i++) {
        if (players[i]['id'] == _myId || players[i]['id'] == _socketService.socket?.id) {
          _myPlayerIndex = i;
          // 프로필 설정
          if (players[i]['profileSettings'] != null) {
            try {
              _myProfileSettings = UserProfileSettings.fromJson(players[i]['profileSettings']);
            } catch (_) {}
          }
        } else {
          _opponentNickname = players[i]['nickname'];
          _opponentAvatarUrl = players[i]['avatarUrl'];
          if (players[i]['profileSettings'] != null) {
            try {
              _opponentProfileSettings = UserProfileSettings.fromJson(players[i]['profileSettings']);
            } catch (_) {}
          }
        }
      }

      setState(() {
        _status = HunminGameStatus.matched;
      });
    });

    _socketListeners.on('game_start', (data) {
      if (data['gameType'] != 'hunmin') return;
      // 재경기 시 플레이어 순서가 바뀌므로 인덱스 갱신
      if (data['players'] != null) {
        final players = data['players'] as List<dynamic>;
        for (int i = 0; i < players.length; i++) {
          if (players[i]['id'] == _myId || players[i]['id'] == _socketService.socket?.id) {
            _myPlayerIndex = i;
            break;
          }
        }
      }
      setState(() {
        _status = HunminGameStatus.playing;
        _isSubmitting = false;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _winnerId = null;
        _isDraw = false;
        _opponentLeft = false;
      });
    });

    // 라운드 시작
    _socketListeners.on('hunmin_round_start', (data) {
      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      setState(() {
        _currentRound = (data['round'] as num?)?.toInt() ?? 0;
        _currentChosung = data['chosung'] as String? ?? '';
        _currentTurnPlayer = (data['firstPlayer'] as num?)?.toInt() ?? 0;
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
        _usedWords = [];
        _wordController.clear();
        _roundEndReason = null;
        _roundEndWord = null;
        _roundWinnerIndex = null;
        _status = HunminGameStatus.playing;
      });
    });

    // 턴 시작
    _socketListeners.on('hunmin_turn_start', (data) {
      final playerIndex = (data['playerIndex'] as num?)?.toInt() ?? 0;
      setState(() {
        _currentTurnPlayer = playerIndex;
        _wordController.clear();
        _isSubmitting = false;
      });
      _startTurnTimer();

      // 내 턴이면 포커스
      if (playerIndex == _myPlayerIndex && mounted) {
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _wordFocusNode.requestFocus();
        });
      }
    });

    // 단어 수락
    _socketListeners.on('hunmin_word_accepted', (data) {
      final word = data['word'] as String? ?? '';
      final playerIndex = (data['playerIndex'] as num?)?.toInt() ?? 0;
      final nextPlayer = (data['nextPlayer'] as num?)?.toInt() ?? 0;

      setState(() {
        _usedWords.add({'word': word, 'playerIndex': playerIndex});
        _currentTurnPlayer = nextPlayer;
        _isSubmitting = false;
      });

      _showResultAnimation(word, const Color(0xFF4CAF50));
    });

    // 단어 거절
    _socketListeners.on('hunmin_word_rejected', (data) {
      final reason = data['reason'] as String? ?? '';

      setState(() {
        _isSubmitting = false;
      });

      _showResultAnimation(_getRejectReasonText(reason), Colors.red);
    });

    // 라운드 종료
    _socketListeners.on('hunmin_round_end', (data) {
      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      final winnerIndex = (data['winnerIndex'] as num?)?.toInt();
      final reason = data['reason'] as String? ?? '';
      final failedWord = data['failedWord'] as String?;

      _turnTimer?.cancel();

      setState(() {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
        _roundWinnerIndex = winnerIndex;
        _roundEndReason = reason;
        _roundEndWord = failedWord;
        _status = HunminGameStatus.roundEnd;
      });
    });

    // 게임 종료
    _socketListeners.on('game_end', (data) {
      if (_status == HunminGameStatus.finished ||
          _status == HunminGameStatus.idle ||
          _status == HunminGameStatus.searching) {
        return;
      }
      _turnTimer?.cancel();

      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      setState(() {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
        _winnerId = data['winner'] as String?;
        _isDraw = data['isDraw'] == true;
        _status = HunminGameStatus.finished;
      });
    });

    // 상대 퇴장
    _socketListeners.on('opponent_left', (_) {
      if (_status == HunminGameStatus.idle ||
          _status == HunminGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == HunminGameStatus.finished) {
        setState(() {
          _opponentLeft = true;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
        });
        return;
      }
      _turnTimer?.cancel();
      setState(() {
        _opponentLeft = true;
        _status = HunminGameStatus.finished;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
      });
    });

    // 리매치
    _socketListeners.on('rematch_requested', (data) {
      setState(() => _opponentWantsRematch = true);
    });

    _socketListeners.on('rematch_waiting', (data) {
      setState(() => _rematchWaiting = data['waiting'] == true);
    });

    _socketListeners.on('rematch_cancelled', (_) {
      setState(() => _opponentWantsRematch = false);
    });

    _socketListeners.on('match_cancelled', (_) {
      setState(() => _status = HunminGameStatus.idle);
    });
  }

  void _startTurnTimer() {
    _turnTimer?.cancel();
    _turnRemaining = _turnTimeLimit;
    _turnTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _turnRemaining--;
        if (_turnRemaining <= 0) {
          timer.cancel();
        }
      });
    });
  }

  String _getRejectReasonText(String reason) {
    switch (reason) {
      case 'chosung_mismatch':
        return '초성 불일치!';
      case 'duplicate_word':
        return '중복 단어!';
      case 'not_in_dictionary':
        return '사전에 없는 단어!';
      case 'invalid_length':
        return '2글자만 가능!';
      case 'not_korean':
        return '한글만 가능!';
      case 'timeout':
        return '시간 초과!';
      default:
        return reason;
    }
  }

  void _showResultAnimation(String message, Color color) {
    final animationToken = ++_resultAnimationToken;
    _lastResultMessage = message;
    _lastResultColor = color;
    _resultAnimController.forward(from: 0);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && animationToken == _resultAnimationToken) {
        _resultAnimController.reverse();
      }
    });
  }

  // ====== 액션 ======

  void _findMatch() {
    _socketService.emit('find_match', {'gameType': AppConfig.gameTypeHunmin});
    setState(() => _status = HunminGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {'gameType': AppConfig.gameTypeHunmin});
    setState(() => _status = HunminGameStatus.idle);
  }

  void _submitWord() {
    final word = _wordController.text.trim();
    if (word.isEmpty || _isSubmitting) return;
    if (_currentTurnPlayer != _myPlayerIndex) return;
    if (_roomId == null) return;

    setState(() => _isSubmitting = true);
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'submit_word', 'word': word},
    });
    _wordController.clear();
  }

  void _requestRematch() {
    if (_roomId == null) return;
    _socketService.emit('rematch_request', {'roomId': _roomId});
    setState(() => _rematchWaiting = true);
  }

  void _cancelRematch() {
    if (_roomId == null) return;
    _socketService.emit('rematch_cancel', {'roomId': _roomId});
    setState(() {
      _rematchWaiting = false;
    });
  }

  void _showFriendInviteDialog(BuildContext context) {
    context.read<FriendProvider>().getFriends();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (dialogContext) => Consumer<FriendProvider>(
        builder: (context, friendProvider, child) {
          final onlineFriends = friendProvider.friends.where((f) => f.isOnline).toList();
          return Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(dialogContext).size.height * 0.6),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(children: [
                    Icon(Icons.person_add, color: _theme.primary),
                    const SizedBox(width: 12),
                    const Text('친구 초대', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ]),
                ),
                const Divider(height: 1),
                Flexible(
                  child: onlineFriends.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(40),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.person_off, size: 48, color: Colors.grey.shade400),
                              const SizedBox(height: 16),
                              Text('온라인 친구가 없습니다', style: TextStyle(color: Colors.grey.shade600)),
                            ]),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: onlineFriends.length,
                          itemBuilder: (context, index) {
                            final friend = onlineFriends[index];
                            return ListTile(
                              leading: Stack(children: [
                                CircleAvatar(
                                  backgroundColor: _theme.primary.withValues(alpha: 0.2),
                                  child: Text(
                                    friend.nickname.isNotEmpty ? friend.nickname[0].toUpperCase() : '?',
                                    style: TextStyle(color: _theme.primary),
                                  ),
                                ),
                                Positioned(
                                  right: 0, bottom: 0,
                                  child: Container(
                                    width: 12, height: 12,
                                    decoration: BoxDecoration(
                                      color: Colors.green, shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 2),
                                    ),
                                  ),
                                ),
                              ]),
                              title: Text(friend.nickname, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: friend.memo != null && friend.memo!.isNotEmpty
                                  ? Text(friend.memo!, style: TextStyle(color: Colors.grey.shade600, fontSize: 12))
                                  : null,
                              trailing: ElevatedButton(
                                onPressed: () {
                                  friendProvider.inviteToGame(friend.id, AppConfig.gameTypeHunmin, isHardcore: false);
                                  Navigator.pop(dialogContext);
                                  ScaffoldMessenger.of(context).clearSnackBars();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('${friend.nickname}님에게 초대를 보냈습니다!'), backgroundColor: Colors.green),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _theme.primary, foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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

  void _leaveGame() {
    _turnTimer?.cancel();
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  bool get _isMyTurn => _currentTurnPlayer == _myPlayerIndex;

  // ====== UI ======

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _status == HunminGameStatus.idle || _status == HunminGameStatus.finished,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _showLeaveConfirmDialog();
        }
      },
      child: Scaffold(
        appBar: gameAppBar(
          title: '훈민정음',
          backgroundColor: _theme.primary,
          onBack: _handleBack,
        ),
        body: Container(
          decoration: BoxDecoration(gradient: _theme.backgroundGradient),
          child: SafeArea(
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  void _handleBack() {
    if (_status == HunminGameStatus.idle ||
        _status == HunminGameStatus.finished) {
      Navigator.pop(context);
    } else {
      _showLeaveConfirmDialog();
    }
  }

  Widget _buildBody() {
    if (_isReconnecting) return _buildReconnectingView();

    switch (_status) {
      case HunminGameStatus.idle:
        return _buildIdleView();
      case HunminGameStatus.searching:
        return _buildSearchingView();
      case HunminGameStatus.matched:
        return _buildMatchedView();
      case HunminGameStatus.playing:
        return _buildPlayingView();
      case HunminGameStatus.roundEnd:
        return _buildRoundEndView();
      case HunminGameStatus.finished:
        return _buildFinishedView();
    }
  }

  // ====== 대기 화면 ======
  Widget _buildIdleView() {
    return GameIntroView(
      backgroundGradient: _theme.backgroundGradient,
      accentColor: _theme.primary,
      icon: Icons.translate_rounded,
      title: '훈민정음',
      descriptions: const ['서버가 낸 초성으로 단어 배틀', '3판 2선승 · 한 턴 15초'],
      onFindMatch: _findMatch,
      onInviteFriend: () => _showFriendInviteDialog(context),
    );
  }

  // ====== 매칭 중 ======
  Widget _buildSearchingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 60, height: 60,
            child: CircularProgressIndicator(
              color: _theme.primary,
              strokeWidth: 4,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            '상대를 찾고 있습니다...',
            style: TextStyle(fontSize: 18, color: Color(0xFF1A1D23)),
          ),
          const SizedBox(height: 32),
          OutlinedButton(
            onPressed: _cancelMatch,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.grey.shade600,
              side: BorderSide(color: Colors.grey.shade400),
            ),
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  // ====== 매칭 완료 ======
  Widget _buildMatchedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle, size: 60, color: Color(0xFF4CAF50)),
          const SizedBox(height: 16),
          const Text(
            '매칭 완료!',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1A1D23)),
          ),
          const SizedBox(height: 8),
          Text(
            'vs $_opponentNickname',
            style: TextStyle(fontSize: 18, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          CircularProgressIndicator(color: _theme.primary),
        ],
      ),
    );
  }

  // ====== 재연결 ======
  Widget _buildReconnectingView() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.orange),
          SizedBox(height: 16),
          Text(
            '재연결 중...',
            style: TextStyle(fontSize: 18, color: Color(0xFF1A1D23)),
          ),
        ],
      ),
    );
  }

  // ====== 게임 진행 화면 ======
  Widget _buildPlayingView() {
    return Column(
      children: [
        // 상단: 라운드/스코어 + 나가기
        _buildTopBar(),

        // 플레이어 프로필
        _buildPlayerProfiles(),

        // 초성 표시
        _buildChosungDisplay(),

        // 사용된 단어 리스트
        Expanded(child: _buildWordList()),

        // 결과 애니메이션 오버레이
        _buildResultOverlay(),

        // 타이머
        if (_isMyTurn) _buildTimer(),

        // 입력 영역
        _buildInputArea(),
      ],
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF1F4),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Round $_currentRound/3    ${_scores[0]} : ${_scores[1]}',
              style: const TextStyle(
                color: Color(0xFF1A1D23),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerProfiles() {
    final isPlayer0 = _myPlayerIndex == 0;
    final myName = _myNickname ?? '나';
    final opName = _opponentNickname ?? '상대';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: _buildPlayerChip(
              isPlayer0 ? myName : opName,
              isActive: _currentTurnPlayer == 0,
              isMe: isPlayer0,
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('VS', style: TextStyle(color: Colors.grey.shade400, fontSize: 14, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: _buildPlayerChip(
              isPlayer0 ? opName : myName,
              isActive: _currentTurnPlayer == 1,
              isMe: !isPlayer0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerChip(String name, {required bool isActive, required bool isMe}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isActive
            ? _theme.primary.withValues(alpha: 0.3)
            : const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(12),
        border: isActive
            ? Border.all(color: _theme.primary, width: 2)
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isActive)
            Container(
              width: 8, height: 8,
              margin: const EdgeInsets.only(right: 6),
              decoration: const BoxDecoration(
                color: Color(0xFF4CAF50),
                shape: BoxShape.circle,
              ),
            ),
          Flexible(
            child: Text(
              isMe ? '$name (나)' : name,
              style: TextStyle(
                color: isActive ? const Color(0xFF1A1D23) : Colors.grey.shade500,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                fontSize: 14,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChosungDisplay() {
    final chars = _currentChosung.split('');
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: chars.map((ch) {
          return Container(
            width: 64,
            height: 64,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _theme.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _theme.primary, width: 2),
            ),
            child: Center(
              child: Text(
                ch,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1D23),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildWordList() {
    if (_usedWords.isEmpty) {
      return Center(
        child: Text(
          _isMyTurn ? '단어를 입력하세요!' : '상대방 차례입니다...',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      reverse: true,
      itemCount: _usedWords.length,
      itemBuilder: (context, index) {
        final reversedIndex = _usedWords.length - 1 - index;
        final item = _usedWords[reversedIndex];
        final word = item['word'] as String;
        final playerIndex = item['playerIndex'] as int;
        final isMyWord = playerIndex == _myPlayerIndex;

        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: isMyWord
                ? _theme.primary.withValues(alpha: 0.15)
                : const Color(0xFFF1F2F4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isMyWord
                  ? _theme.primary.withValues(alpha: 0.3)
                  : const Color(0xFFEFF1F4),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: isMyWord
                      ? _theme.primary.withValues(alpha: 0.3)
                      : const Color(0xFFEFF1F4),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '${reversedIndex + 1}',
                    style: TextStyle(
                      color: isMyWord ? _theme.primary : Colors.grey.shade500,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                word,
                style: const TextStyle(
                  color: Color(0xFF1A1D23),
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Text(
                playerIndex == _myPlayerIndex
                    ? (_myNickname ?? '나')
                    : (_opponentNickname ?? '상대'),
                style: TextStyle(
                  color: isMyWord ? _theme.primary : Colors.grey.shade400,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildResultOverlay() {
    return AnimatedBuilder(
      animation: _resultAnimController,
      builder: (context, child) {
        if (_resultAnimController.value == 0 || _lastResultMessage == null) {
          return const SizedBox.shrink();
        }
        return Center(
          child: Opacity(
            opacity: _resultAnimController.value,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: (_lastResultColor ?? Colors.white).withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _lastResultMessage!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTimer() {
    final isUrgent = _turnRemaining <= 5;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.timer,
            color: isUrgent ? Colors.red : Colors.grey.shade600,
            size: 20,
          ),
          const SizedBox(width: 6),
          Text(
            '$_turnRemaining초',
            style: TextStyle(
              color: isUrgent ? Colors.red : Colors.grey.shade600,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    final canInput = _isMyTurn && _status == HunminGameStatus.playing;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F8),
        border: Border(top: BorderSide(color: const Color(0xFFEFF1F4))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _wordController,
              focusNode: _wordFocusNode,
              enabled: canInput,
              style: const TextStyle(color: Color(0xFF1A1D23), fontSize: 18),
              decoration: InputDecoration(
                hintText: canInput ? '2글자 단어 입력' : (_isMyTurn ? '입력 중...' : '상대 차례입니다'),
                hintStyle: TextStyle(color: Colors.grey.shade600),
                filled: true,
                fillColor: canInput
                    ? const Color(0xFFEFF1F4)
                    : const Color(0xFFFAFBFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
              maxLength: 2,
              buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
              onSubmitted: canInput ? (_) => _submitWord() : null,
              textInputAction: TextInputAction.send,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: canInput && !_isSubmitting ? _submitWord : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _theme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              child: _isSubmitting
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('전송', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  // ====== 라운드 종료 ======
  Widget _buildRoundEndView() {
    final isMyWin = _roundWinnerIndex == _myPlayerIndex;
    final reasonText = _getRejectReasonText(_roundEndReason ?? '');

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isMyWin ? Icons.celebration : Icons.sentiment_dissatisfied,
            size: 64,
            color: isMyWin ? const Color(0xFFFFC107) : Colors.red,
          ),
          const SizedBox(height: 16),
          Text(
            isMyWin ? '라운드 승리!' : '라운드 패배',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: isMyWin ? const Color(0xFFFFC107) : Colors.red,
            ),
          ),
          const SizedBox(height: 8),
          if (_roundEndWord != null && _roundEndWord!.isNotEmpty) ...[
            Text(
              '"${_roundEndWord!}"',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1A1D23)),
            ),
            const SizedBox(height: 4),
          ],
          Text(
            reasonText,
            style: TextStyle(fontSize: 16, color: Colors.grey.shade400),
          ),
          const SizedBox(height: 24),
          Text(
            'Round $_currentRound/3',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            '${_scores[0]} : ${_scores[1]}',
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1D23),
            ),
          ),
          const SizedBox(height: 16),
          CircularProgressIndicator(color: _theme.primary),
          const SizedBox(height: 8),
          Text(
            '다음 라운드 준비 중...',
            style: TextStyle(color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  // ====== 게임 종료 ======
  Widget _buildFinishedView() {
    String resultText;
    Color resultColor;
    IconData resultIcon;

    if (_opponentLeft) {
      resultText = '상대가 나갔습니다\n승리!';
      resultColor = const Color(0xFF4CAF50);
      resultIcon = Icons.emoji_events;
    } else if (_isDraw) {
      resultText = '무승부!';
      resultColor = Colors.grey;
      resultIcon = Icons.handshake;
    } else if (_winnerId == _myId || _winnerId == _socketService.socket?.id) {
      resultText = '승리!';
      resultColor = const Color(0xFF4CAF50);
      resultIcon = Icons.emoji_events;
    } else {
      resultText = '패배';
      resultColor = Colors.red;
      resultIcon = Icons.sentiment_dissatisfied;
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(resultIcon, size: 80, color: resultColor),
          const SizedBox(height: 16),
          Text(
            resultText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: resultColor,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '최종 스코어: ${_scores[0]} : ${_scores[1]}',
            style: const TextStyle(fontSize: 20, color: Color(0xFF1A1D23)),
          ),
          const SizedBox(height: 32),

          SizedBox(
            width: 280,
            child: GameEndActionPanel(
              showRematchActions: !_opponentLeft,
              opponentLeft: _opponentLeft,
              opponentWantsRematch: _opponentWantsRematch,
              rematchWaiting: _rematchWaiting,
              primaryColor: _theme.primary,
              primaryForegroundColor: Colors.white,
              onRequestRematch: _requestRematch,
              onCancelRematch: _cancelRematch,
              onLeave: _leaveGame,
              rematchLabel: '재대결',
              acceptRematchLabel: '재대결',
              waitingText: '재대결 대기 중...',
              cancelLabel: '취소',
              leaveLabel: '나가기',
              opponentRequestMessage: '상대방이 재대결을 원합니다!',
              rematchIcon: Icons.refresh,
              leaveIcon: Icons.exit_to_app,
              acceptColor: Colors.orange,
              waitingTextColor: Colors.grey.shade600,
              leaveForegroundColor: Colors.grey.shade600,
              leaveBorderSide: BorderSide(color: Colors.grey.shade400),
            ),
          ),
        ],
      ),
    );
  }

  void _showLeaveConfirmDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('게임 나가기'),
        content: const Text('게임에서 나가면 패배 처리됩니다.\n정말 나가시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _leaveGame();
            },
            child: const Text('나가기', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
