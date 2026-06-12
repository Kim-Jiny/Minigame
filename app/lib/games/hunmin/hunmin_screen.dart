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
import '../common/game_rematch_preparing_view.dart';
import '../common/game_intro_view.dart';
import '../common/game_scaffold.dart';
import '../common/game_end_action_panel.dart';
import '../common/game_reconnect_helper.dart';
import '../common/game_result_summary.dart';

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

  // [N인] 멀티플레이 상태 (SET과 동일 — 2인은 기존 1:1 경로 유지)
  int _maxPlayers = 2; // 진입화면 인원 선택(2·3·4)
  List<Map<String, dynamic>> _players = []; // match_found 전원 정보(인덱스=점수 인덱스)
  final Set<int> _leftIndices = {}; // 도중 영구 이탈한 플레이어 인덱스
  final Set<int> _eliminatedThisRound = {}; // 이번 라운드 탈락(탈락제)
  bool get _isMulti => _players.length > 2;

  /// 플레이어 인덱스 → 표시 이름. 멀티는 _players, 2인은 기존 닉네임 사용.
  String _nameForIndex(int i) {
    if (i == _myPlayerIndex) return _myNickname ?? '나';
    if (_isMulti && i >= 0 && i < _players.length) {
      return (_players[i]['nickname'] as String?) ?? '?';
    }
    return _opponentNickname ?? '상대';
  }

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
  bool _wonByForfeit = false; // 상대 mid-game 이탈로 인한 몰수승(결과 표시용)
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
      // N인: 탈락/이탈 상태 복원(_players 는 match_found 이후 유지됨)
      final elimData = data['eliminated'] as List<dynamic>? ?? [];
      final leftData = data['leftPlayers'] as List<dynamic>? ?? [];
      _eliminatedThisRound
        ..clear()
        ..addAll(elimData.map((e) => (e as num).toInt()));
      _leftIndices
        ..clear()
        ..addAll(leftData.map((e) => (e as num).toInt()));

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
      // 멀티(3·4인) 표시용 전원 정보. 인덱스 = 점수 인덱스.
      _players = players.map((p) => Map<String, dynamic>.from(p as Map)).toList();
      _leftIndices.clear();
      _eliminatedThisRound.clear();

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
        _players = players.map((p) => Map<String, dynamic>.from(p as Map)).toList();
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
        _wonByForfeit = false;
        // 재경기 시 hunmin_round_start 가 오기 전까지 이전 게임 내용이 잠깐
        // 보이지 않도록 라운드 콘텐츠도 초기화한다(첫 게임 시작과 동일한 빈 상태).
        _currentChosung = '';
        _currentRound = 0;
        _scores = List<int>.filled(_players.isNotEmpty ? _players.length : 2, 0);
        _usedWords = [];
        _currentTurnPlayer = 0;
        _roundEndReason = null;
        _roundEndWord = null;
        _roundWinnerIndex = null;
        _leftIndices.clear();
        _eliminatedThisRound.clear();
        _wordController.clear();
      });
    });

    // 라운드 시작
    _socketListeners.on('hunmin_round_start', (data) {
      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      final eliminated = data['eliminated'] as List<dynamic>? ?? [];
      setState(() {
        _currentRound = (data['round'] as num?)?.toInt() ?? 0;
        _currentChosung = data['chosung'] as String? ?? '';
        _currentTurnPlayer = (data['firstPlayer'] as num?)?.toInt() ?? 0;
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
        // 이번 라운드 탈락자 = 영구 이탈자(서버가 eliminated로 내려줌)로 초기화
        _eliminatedThisRound
          ..clear()
          ..addAll(eliminated.map((e) => (e as num).toInt()));
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

    // [N인] 라운드 도중 탈락 — 라운드는 계속, 탈락자 표시 후 다음 턴으로.
    _socketListeners.on('hunmin_player_eliminated', (data) {
      final playerIndex = (data['playerIndex'] as num?)?.toInt() ?? -1;
      final nextPlayer = (data['nextPlayer'] as num?)?.toInt() ?? _currentTurnPlayer;
      final reason = data['reason'] as String? ?? '';
      final scoreData = data['scores'] as List<dynamic>?;
      setState(() {
        if (playerIndex >= 0) _eliminatedThisRound.add(playerIndex);
        _currentTurnPlayer = nextPlayer;
        if (scoreData != null) {
          _scores = scoreData.map((s) => (s as num).toInt()).toList();
        }
        _isSubmitting = false;
      });
      final who = playerIndex == _myPlayerIndex ? '나' : _nameForIndex(playerIndex);
      _showResultAnimation('$who 탈락 · ${_getRejectReasonText(reason)}', Colors.red);
    });

    // [N인] 도중 영구 이탈 — 표시만 갱신(게임은 계속 진행).
    _socketListeners.on('hunmin_player_left', (data) {
      final idx = (data['playerIndex'] as num?)?.toInt();
      if (idx == null) return;
      setState(() {
        _leftIndices.add(idx);
        _eliminatedThisRound.add(idx);
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

    // 상대 퇴장 (2인 전용 — 3·4인은 hunmin_player_left 로 게임 계속 진행)
    _socketListeners.on('opponent_left', (_) {
      if (_isMulti) return;
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
        _wonByForfeit = true;
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
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeHunmin,
      'maxPlayers': _maxPlayers,
    });
    setState(() => _status = HunminGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeHunmin,
      'maxPlayers': _maxPlayers,
    });
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

  /// 화면에 머문 채 방을 떠나 대기 상태로 초기화(멀티 '다시 매칭'용).
  void _resetToIdle() {
    _turnTimer?.cancel();
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    setState(() {
      _status = HunminGameStatus.idle;
      _roomId = null;
      _players = [];
      _leftIndices.clear();
      _eliminatedThisRound.clear();
      _scores = [0, 0];
      _usedWords = [];
      _currentChosung = '';
      _currentRound = 0;
      _currentTurnPlayer = 0;
      _winnerId = null;
      _isDraw = false;
      _opponentLeft = false;
      _wonByForfeit = false;
      _rematchWaiting = false;
      _opponentWantsRematch = false;
    });
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
      descriptions: _maxPlayers > 2
          ? const ['서버가 낸 초성으로 단어 배틀', '턴에 실패하면 탈락 · 마지막 1명이 라운드 승', '먼저 2라운드 선취 · 한 턴 15초']
          : const ['서버가 낸 초성으로 단어 배틀', '3판 2선승 · 한 턴 15초'],
      extra: _HunminPlayerCountSelector(
        value: _maxPlayers,
        accent: _theme.primary,
        onChanged: (n) => setState(() => _maxPlayers = n),
      ),
      onFindMatch: _findMatch,
      // 3·4인은 친구 초대 미지원(랜덤 매칭 전용) — 2인일 때만 초대 노출.
      onInviteFriend:
          _maxPlayers == 2 ? () => _showFriendInviteDialog(context) : null,
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
            _isMulti ? '${_players.length}명 매칭 완료!' : 'vs $_opponentNickname',
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
    final scoreText = _isMulti
        ? '먼저 2라운드 선취'
        : '${_scores.isNotEmpty ? _scores[0] : 0} : ${_scores.length > 1 ? _scores[1] : 0}';
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
              _isMulti
                  ? 'Round $_currentRound    $scoreText'
                  : 'Round $_currentRound/3    $scoreText',
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

  // [N인] 진행 중 플레이어 바 — 점수·현재턴·탈락/이탈 표시.
  Widget _buildMultiPlayerBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(_players.length, (i) {
          final isMe = i == _myPlayerIndex;
          final isTurn = _currentTurnPlayer == i;
          final left = _leftIndices.contains(i);
          final eliminated = _eliminatedThisRound.contains(i);
          final score = i < _scores.length ? _scores[i] : 0;
          final dim = left || eliminated;
          return Expanded(
            child: Opacity(
              opacity: dim ? 0.4 : 1,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                decoration: BoxDecoration(
                  color: isTurn
                      ? _theme.primary.withValues(alpha: 0.15)
                      : const Color(0xFFF5F6F8),
                  borderRadius: BorderRadius.circular(12),
                  border: isTurn
                      ? Border.all(color: _theme.primary, width: 2)
                      : null,
                ),
                child: Column(
                  children: [
                    Text(
                      isMe ? '나' : _nameForIndex(i),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isMe ? FontWeight.w800 : FontWeight.w600,
                        color: isTurn ? _theme.primary : Colors.grey.shade600,
                        decoration: dim ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isMe
                            ? _theme.primary
                            : _theme.primary.withValues(alpha: 0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$score',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: isMe ? Colors.white : _theme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      left ? '이탈' : (eliminated ? '탈락' : (isTurn ? '진행' : '대기')),
                      style: TextStyle(
                        fontSize: 10,
                        color: left || eliminated
                            ? Colors.red.shade300
                            : (isTurn ? _theme.primary : Colors.grey.shade400),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildPlayerProfiles() {
    if (_isMulti) return _buildMultiPlayerBar();
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
      final turnName = _isMulti
          ? '${_nameForIndex(_currentTurnPlayer)} 차례입니다...'
          : '상대방 차례입니다...';
      return Center(
        child: Text(
          _isMyTurn ? '단어를 입력하세요!' : turnName,
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
                playerIndex < 0 ? '' : _nameForIndex(playerIndex),
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
                hintText: canInput
                    ? '2글자 단어 입력'
                    : (_isMyTurn
                        ? '입력 중...'
                        : (_isMulti
                            ? '${_nameForIndex(_currentTurnPlayer)} 차례입니다'
                            : '상대 차례입니다')),
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
    if (_isMulti) return _buildMultiRoundEndView();
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

  // [N인] 라운드 종료 — 생존자(라운드 승자) + 전원 점수.
  Widget _buildMultiRoundEndView() {
    final winnerIdx = _roundWinnerIndex;
    final isMyWin = winnerIdx == _myPlayerIndex;
    final winnerName = (winnerIdx != null && winnerIdx >= 0)
        ? (isMyWin ? '나' : _nameForIndex(winnerIdx))
        : null;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isMyWin ? Icons.celebration : Icons.flag_rounded,
            size: 64,
            color: isMyWin ? const Color(0xFFFFC107) : _theme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            winnerName != null ? '$winnerName 라운드 승!' : '라운드 종료',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: isMyWin ? const Color(0xFFFFC107) : const Color(0xFF1A1D23),
            ),
          ),
          const SizedBox(height: 24),
          Text('Round $_currentRound',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade500)),
          const SizedBox(height: 12),
          // 전원 점수
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(_players.length, (i) {
                final left = _leftIndices.contains(i);
                final score = i < _scores.length ? _scores[i] : 0;
                return Opacity(
                  opacity: left ? 0.4 : 1,
                  child: Column(
                    children: [
                      Text(i == _myPlayerIndex ? '나' : _nameForIndex(i),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                      const SizedBox(height: 4),
                      Text('$score',
                          style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: _theme.primary)),
                    ],
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 20),
          CircularProgressIndicator(color: _theme.primary),
          const SizedBox(height: 8),
          Text('다음 라운드 준비 중...',
              style: TextStyle(color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  // ====== 게임 종료 ======
  Widget _buildFinishedView() {
    if (_isMulti) return _buildMultiFinishedView();
    if (_rematchWaiting) {
      return GameRematchPreparingView(
        backgroundGradient: _theme.backgroundGradient,
        accentColor: _theme.primary,
        onCancel: _cancelRematch,
      );
    }
    String resultText;
    Color resultColor;
    IconData resultIcon;

    if (_wonByForfeit) {
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

  // [N인] 결과 순위표 — 라운드 승수 기준, 이탈자는 등수 제외(SET 결과와 동일 구조).
  Widget _buildMultiFinishedView() {
    final accent = _theme.primary;
    int scoreOf(int i) => i < _scores.length ? _scores[i] : 0;
    bool isLeft(int i) => _leftIndices.contains(i);
    final active = [
      for (var i = 0; i < _players.length; i++)
        if (!isLeft(i)) i
    ]..sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));
    final leftList = [
      for (var i = 0; i < _players.length; i++)
        if (isLeft(i)) i
    ];
    final order = [...active, ...leftList];
    int rankOf(int i) => 1 + active.where((j) => scoreOf(j) > scoreOf(i)).length;

    final myScore = scoreOf(_myPlayerIndex);
    final iAmActive = !isLeft(_myPlayerIndex);
    final myRank =
        iAmActive ? rankOf(_myPlayerIndex) : order.indexOf(_myPlayerIndex) + 1;
    final topScore = active.isNotEmpty ? scoreOf(active.first) : 0;
    final topCount = active.where((i) => scoreOf(i) == topScore).length;
    final iAmTop = iAmActive && myScore == topScore;
    final isSoleWinner = iAmTop && topCount == 1;
    final isTopDraw = iAmTop && topCount > 1;

    return Container(
      decoration: BoxDecoration(gradient: _theme.backgroundGradient),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GameResultHero(
                icon: isSoleWinner
                    ? Icons.emoji_events_rounded
                    : isTopDraw
                        ? Icons.handshake_rounded
                        : Icons.flag_rounded,
                color: isSoleWinner
                    ? accent
                    : isTopDraw
                        ? const Color(0xFFEA8A00)
                        : Colors.grey,
                title: isSoleWinner
                    ? '승리!'
                    : isTopDraw
                        ? '무승부!'
                        : '$myRank등',
                subtitle: isTopDraw
                    ? '${_players.length}명 중 공동 1등 · $myScore승'
                    : '${_players.length}명 중 $myRank등 · $myScore승',
              ),
              const SizedBox(height: 22),
              ...List.generate(order.length, (pos) {
                final i = order[pos];
                final isMe = i == _myPlayerIndex;
                final left = isLeft(i);
                final score = scoreOf(i);
                final r = left ? -1 : rankOf(i);
                final medal = ['🥇', '🥈', '🥉'];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isMe ? accent.withValues(alpha: 0.10) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isMe
                          ? accent.withValues(alpha: 0.4)
                          : const Color(0xFFEDEDF2),
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 30,
                        child: Text(
                          left ? '–' : (r <= 3 ? medal[r - 1] : '$r'),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isMe ? '나' : _nameForIndex(i),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                isMe ? FontWeight.w800 : FontWeight.w600,
                            color: isMe ? accent : const Color(0xFF1F2430),
                            decoration:
                                left ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      if (left)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text('이탈',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade400)),
                        ),
                      Text('$score승',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: accent)),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    _resetToIdle();
                    _findMatch();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('다시 매칭'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _leaveGame,
                child:
                    Text('로비로', style: TextStyle(color: Colors.grey.shade600)),
              ),
            ],
          ),
        ),
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

/// 훈민정음 진입 화면의 인원(2·3·4) 선택 토글. SET과 동일한 UX.
/// 3·4인은 탈락제 랜덤 매칭(친구 초대 미지원).
class _HunminPlayerCountSelector extends StatelessWidget {
  final int value;
  final Color accent;
  final ValueChanged<int> onChanged;

  const _HunminPlayerCountSelector({
    required this.value,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [2, 3, 4].map((n) {
          final selected = value == n;
          return GestureDetector(
            onTap: () => onChanged(n),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$n인',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: selected ? Colors.white : Colors.grey.shade600,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
