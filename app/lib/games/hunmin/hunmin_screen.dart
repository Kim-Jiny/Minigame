import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../config/app_config.dart';
import '../../providers/auth_provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/socket_service.dart';
import '../../services/socket_listener_registry.dart';
import '../../models/shop_item.dart';
import '../../theme/candy_theme.dart';
import '../../utils/game_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/confetti_burst.dart';
import '../../widgets/cartoon/duo_mascot.dart';
import '../../widgets/cartoon/pop_in.dart';
import '../common/game_rematch_preparing_view.dart';
import '../common/game_intro_view.dart';
import '../common/game_scaffold.dart';
import '../common/game_end_action_panel.dart';
import '../common/game_reconnect_helper.dart';
import '../common/game_result_summary.dart';
import '../common/game_timer_badge.dart';
import '../common/match_status_views.dart';

enum HunminGameStatus { idle, searching, matched, playing, roundEnd, finished }

class HunminScreen extends StatefulWidget {
  const HunminScreen({super.key});

  @override
  State<HunminScreen> createState() => _HunminScreenState();
}

class _HunminScreenState extends State<HunminScreen>
    with TickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );
  // 게임 고유 다크테마 대신 사용자 테마(라이트)를 사용.
  GameTheme get _theme => GameTheme.fromProfileSettings(
    context.read<ShopProvider>().profileSettings,
  );

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
  bool _lastResultOk = true;
  int _confettiTick = 0;

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
      final isInGame =
          _status != HunminGameStatus.idle &&
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
      _players = players
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
      _leftIndices.clear();
      _eliminatedThisRound.clear();

      // 내가 어떤 인덱스인지 찾기
      for (int i = 0; i < players.length; i++) {
        if (players[i]['id'] == _myId ||
            players[i]['id'] == _socketService.socket?.id) {
          _myPlayerIndex = i;
          // 프로필 설정
          if (players[i]['profileSettings'] != null) {
            try {
              _myProfileSettings = UserProfileSettings.fromJson(
                players[i]['profileSettings'],
              );
            } catch (_) {}
          }
        } else {
          _opponentNickname = players[i]['nickname'];
          _opponentAvatarUrl = players[i]['avatarUrl'];
          if (players[i]['profileSettings'] != null) {
            try {
              _opponentProfileSettings = UserProfileSettings.fromJson(
                players[i]['profileSettings'],
              );
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
        _players = players
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList();
        for (int i = 0; i < players.length; i++) {
          if (players[i]['id'] == _myId ||
              players[i]['id'] == _socketService.socket?.id) {
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
        _scores = List<int>.filled(
          _players.isNotEmpty ? _players.length : 2,
          0,
        );
        _usedWords = [];
        _currentTurnPlayer = 0;
        _roundEndReason = null;
        _roundEndWord = null;
        _roundWinnerIndex = null;
        _leftIndices.clear();
        _eliminatedThisRound.clear();
        _wordController.clear();
        _confettiTick = 0;
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

      // 내가 성공시킨 단어면 작은 컨페티
      if (playerIndex == _myPlayerIndex) {
        _confettiTick++;
        HapticFeedback.mediumImpact();
        setState(() {});
      }
      _showResultAnimation(word, CandyColors.mintDeep);
    });

    // 단어 거절
    _socketListeners.on('hunmin_word_rejected', (data) {
      final reason = data['reason'] as String? ?? '';

      setState(() {
        _isSubmitting = false;
      });

      HapticFeedback.heavyImpact();
      _showResultAnimation(
        _getRejectReasonText(reason),
        const Color(0xFFFF5A5F),
        ok: false,
      );
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
      final nextPlayer =
          (data['nextPlayer'] as num?)?.toInt() ?? _currentTurnPlayer;
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
      final who = playerIndex == _myPlayerIndex
          ? '나'
          : _nameForIndex(playerIndex);
      _showResultAnimation(
        '$who 탈락 · ${_getRejectReasonText(reason)}',
        const Color(0xFFFF5A5F),
        ok: false,
      );
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

  void _showResultAnimation(String message, Color color, {bool ok = true}) {
    final animationToken = ++_resultAnimationToken;
    _lastResultMessage = message;
    _lastResultColor = color;
    _lastResultOk = ok;
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

    HapticFeedback.selectionClick();
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
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: CandyColors.ink.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(Icons.person_add, color: _theme.primary),
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
                const Divider(height: 1),
                Flexible(
                  child: onlineFriends.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(40),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.person_off,
                                  size: 48,
                                  color: Colors.grey.shade400,
                                ),
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
                                    backgroundColor: _theme.primary.withValues(
                                      alpha: 0.2,
                                    ),
                                    child: Text(
                                      friend.nickname.isNotEmpty
                                          ? friend.nickname[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(color: _theme.primary),
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
                                        border: Border.all(
                                          color: Colors.white,
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
                                    AppConfig.gameTypeHunmin,
                                    isHardcore: false,
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
                                  backgroundColor: _theme.primary,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                    side: const BorderSide(
                                      color: CandyColors.ink,
                                      width: 2.5,
                                    ),
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
      canPop:
          _status == HunminGameStatus.idle ||
          _status == HunminGameStatus.finished,
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
          child: SafeArea(child: _buildBody()),
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
          ? const [
              '서버가 낸 초성으로 단어 배틀',
              '턴에 실패하면 탈락 · 마지막 1명이 라운드 승',
              '먼저 2라운드 선취 · 한 턴 15초',
            ]
          : const ['서버가 낸 초성으로 단어 배틀', '3판 2선승 · 한 턴 15초'],
      extra: _HunminPlayerCountSelector(
        value: _maxPlayers,
        accent: _theme.primary,
        onChanged: (n) {
          HapticFeedback.selectionClick();
          setState(() => _maxPlayers = n);
        },
      ),
      onFindMatch: _findMatch,
      // 3·4인은 친구 초대 미지원(랜덤 매칭 전용) — 2인일 때만 초대 노출.
      onInviteFriend: _maxPlayers == 2
          ? () => _showFriendInviteDialog(context)
          : null,
    );
  }

  // ====== 매칭 중 ======
  Widget _buildSearchingView() {
    return GameSearchingView(
      theme: _theme,
      isHardcore: false,
      onCancel: _cancelMatch,
    );
  }

  // ====== 매칭 완료 ======
  Widget _buildMatchedView() {
    if (!_isMulti) {
      return GameMatchedView(
        theme: _theme,
        opponentNickname: _opponentNickname,
      );
    }
    return Container(
      decoration: BoxDecoration(gradient: _theme.backgroundGradient),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PopIn(
              child: DuoMascot(
                size: 110,
                color: _theme.primary,
                mood: MascotMood.cheer,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              '${_players.length}명 매칭 완료!',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: _theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '게임이 곧 시작됩니다...',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: CandyColors.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ====== 재연결 ======
  Widget _buildReconnectingView() {
    return Center(
      child: PopIn(
        child: CartoonCard(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: _theme.primary),
              const SizedBox(height: 16),
              const Text(
                '재연결 중...',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ====== 게임 진행 화면 ======
  Widget _buildPlayingView() {
    return Stack(
      children: [
        Column(
          children: [
            // 상단: 라운드
            _buildTopBar(),

            // 플레이어 프로필
            _buildPlayerProfiles(),

            // 초성 표시
            _buildChosungDisplay(),

            // 사용된 단어 리스트
            Expanded(child: _buildWordList()),

            // 타이머
            if (_isMyTurn) _buildTimer(),

            // 입력 영역
            _buildInputArea(),
          ],
        ),
        // 결과 토스트 (레이아웃을 밀지 않도록 오버레이)
        Positioned(
          left: 16,
          right: 16,
          top: 150,
          child: IgnorePointer(child: _buildResultOverlay()),
        ),
        // 단어 성공 컨페티
        if (_confettiTick > 0)
          Positioned.fill(
            child: ConfettiBurst(
              key: ValueKey('confetti-$_confettiTick'),
              count: 22,
              duration: const Duration(milliseconds: 1300),
            ),
          ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: CandyColors.ink, width: 2.5),
                boxShadow: const [
                  BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
                ],
              ),
              child: Text(
                _isMulti
                    ? 'Round $_currentRound  ·  먼저 2라운드 선취'
                    : 'Round $_currentRound/3',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: CandyColors.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(_players.length, (i) {
          final isMe = i == _myPlayerIndex;
          final isTurn = _currentTurnPlayer == i;
          final left = _leftIndices.contains(i);
          final eliminated = _eliminatedThisRound.contains(i);
          final score = i < _scores.length ? _scores[i] : 0;
          final dim = left || eliminated;
          return Expanded(
            child: AnimatedScale(
              scale: isTurn && !dim ? 1.06 : 1.0,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              child: Opacity(
                opacity: dim ? 0.45 : 1,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isTurn && !dim
                        ? Color.lerp(_theme.primary, Colors.white, 0.65)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: CandyColors.ink, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: CandyColors.ink,
                        offset: Offset(0, isTurn && !dim ? 4 : 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Text(
                        isMe ? '나' : _nameForIndex(i),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: isMe ? FontWeight.w900 : FontWeight.w700,
                          color: CandyColors.ink,
                          decoration: dim ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _ScoreBadge(
                        score: score,
                        color: isMe ? _theme.primary : Colors.white,
                        textColor: isMe ? Colors.white : CandyColors.ink,
                        size: 30,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        left
                            ? '이탈'
                            : (eliminated ? '탈락' : (isTurn ? '진행' : '대기')),
                        style: TextStyle(
                          fontSize: 10,
                          color: left || eliminated
                              ? const Color(0xFFE5484D)
                              : CandyColors.inkSoft,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
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
    final score0 = _scores.isNotEmpty ? _scores[0] : 0;
    final score1 = _scores.length > 1 ? _scores[1] : 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: _buildPlayerChip(
              isPlayer0 ? myName : opName,
              score: score0,
              isActive: _currentTurnPlayer == 0,
              isMe: isPlayer0,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'VS',
              style: TextStyle(
                color: CandyColors.inkSoft,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: _buildPlayerChip(
              isPlayer0 ? opName : myName,
              score: score1,
              isActive: _currentTurnPlayer == 1,
              isMe: !isPlayer0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerChip(
    String name, {
    required int score,
    required bool isActive,
    required bool isMe,
  }) {
    return AnimatedScale(
      scale: isActive ? 1.05 : 1.0,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isActive
              ? Color.lerp(_theme.primary, Colors.white, 0.6)
              : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: CandyColors.ink, width: 2.5),
          boxShadow: [
            BoxShadow(
              color: CandyColors.ink,
              offset: Offset(0, isActive ? 4 : 2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isActive)
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: CandyColors.mint,
                  shape: BoxShape.circle,
                  border: Border.all(color: CandyColors.ink, width: 1.5),
                ),
              ),
            Flexible(
              child: Text(
                isMe ? '$name (나)' : name,
                style: TextStyle(
                  color: CandyColors.ink,
                  fontWeight: isActive ? FontWeight.w900 : FontWeight.w700,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _ScoreBadge(
              score: score,
              color: isMe ? _theme.primary : CandyColors.sun,
              textColor: isMe ? Colors.white : CandyColors.ink,
              size: 26,
            ),
          ],
        ),
      ),
    );
  }

  static const List<Color> _tileColors = [
    CandyColors.pink,
    CandyColors.sky,
    CandyColors.sun,
    CandyColors.mint,
    CandyColors.grape,
    CandyColors.tangerine,
  ];

  Widget _buildChosungDisplay() {
    final chars = _currentChosung.split('');
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 14),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 10,
        children: [
          for (int i = 0; i < chars.length; i++)
            PopIn(
              key: ValueKey('chosung-$_currentRound-$i-${chars[i]}'),
              delay: Duration(milliseconds: i * 110),
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: _tileColors[(_currentRound + i) % _tileColors.length],
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: CandyColors.ink, width: 3),
                  boxShadow: const [
                    BoxShadow(color: CandyColors.ink, offset: Offset(0, 5)),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      left: 10,
                      right: 10,
                      top: 6,
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                    Text(
                      chars[i],
                      style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        color: CandyColors.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWordList() {
    if (_usedWords.isEmpty) {
      final turnName = _isMulti
          ? '${_nameForIndex(_currentTurnPlayer)} 차례입니다...'
          : '상대방 차례입니다...';
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            _isMyTurn ? '단어를 입력하세요!' : turnName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CandyColors.inkSoft,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      reverse: true,
      itemCount: _usedWords.length,
      itemBuilder: (context, index) {
        final reversedIndex = _usedWords.length - 1 - index;
        final item = _usedWords[reversedIndex];
        final word = (item['word'] as String?) ?? '';
        final playerIndex = (item['playerIndex'] as int?) ?? -1;
        final isMyWord = playerIndex == _myPlayerIndex;

        return PopIn(
          key: ValueKey('word-$_currentRound-$reversedIndex-$word'),
          duration: const Duration(milliseconds: 420),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: isMyWord
                  ? Color.lerp(_theme.primary, Colors.white, 0.7)
                  : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: CandyColors.ink, width: 2.5),
              boxShadow: const [
                BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: isMyWord ? _theme.primary : CandyColors.sun,
                    shape: BoxShape.circle,
                    border: Border.all(color: CandyColors.ink, width: 2),
                  ),
                  child: Center(
                    child: Text(
                      '${reversedIndex + 1}',
                      style: TextStyle(
                        color: isMyWord ? Colors.white : CandyColors.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    word,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CandyColors.ink,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    playerIndex < 0 ? '' : _nameForIndex(playerIndex),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isMyWord ? _theme.primary : CandyColors.inkSoft,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
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
        final ok = _lastResultOk;
        return Center(
          child: Opacity(
            opacity: _resultAnimController.value.clamp(0.0, 1.0),
            // 성공 = 통통 튀어나옴 / 실패 = 좌우로 흔들림
            child: TweenAnimationBuilder<double>(
              key: ValueKey('toast-$_resultAnimationToken'),
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 600),
              builder: (_, t, child) {
                if (ok) {
                  return Transform.scale(
                    scale: 0.6 + 0.4 * Curves.elasticOut.transform(t),
                    child: child,
                  );
                }
                return Transform.translate(
                  offset: Offset(sin(t * pi * 7) * 9 * (1 - t), 0),
                  child: child,
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _lastResultColor ?? CandyColors.ink,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: CandyColors.ink, width: 3),
                  boxShadow: const [
                    BoxShadow(color: CandyColors.ink, offset: Offset(0, 4)),
                  ],
                ),
                child: Text(
                  _lastResultMessage!,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTimer() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: GameTimerBadge(
          seconds: max(0, _turnRemaining),
          label: '내 차례',
          accentColor: _theme.primary,
          compact: true,
          warningThreshold: 5,
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    final canInput = _isMyTurn && _status == HunminGameStatus.playing;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: CandyColors.ink, width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: _wordController,
              focusNode: _wordFocusNode,
              enabled: canInput,
              style: const TextStyle(
                color: CandyColors.ink,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
              decoration: InputDecoration(
                hintText: canInput
                    ? '2글자 단어 입력'
                    : (_isMyTurn
                          ? '입력 중...'
                          : (_isMulti
                                ? '${_nameForIndex(_currentTurnPlayer)} 차례입니다'
                                : '상대 차례입니다')),
                hintStyle: const TextStyle(
                  color: CandyColors.inkSoft,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
                filled: true,
                fillColor: canInput ? Colors.white : const Color(0xFFF1ECFA),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: CandyColors.ink,
                    width: 2.5,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: CandyColors.ink,
                    width: 2.5,
                  ),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                    color: CandyColors.ink.withValues(alpha: 0.35),
                    width: 2.5,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: _theme.primary, width: 3),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              maxLength: 2,
              buildCounter:
                  (
                    context, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null,
              onSubmitted: canInput ? (_) => _submitWord() : null,
              textInputAction: TextInputAction.send,
            ),
          ),
          const SizedBox(width: 10),
          ChunkyButton(
            height: 48,
            expand: false,
            color: _theme.primary,
            textColor: _theme.textOnPrimary,
            onPressed: canInput && !_isSubmitting ? _submitWord : null,
            child: _isSubmitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    '전송',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: canInput ? _theme.textOnPrimary : Colors.white,
                    ),
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
    final oppIdx = _myPlayerIndex == 0 ? 1 : 0;
    final myScore = _myPlayerIndex < _scores.length
        ? _scores[_myPlayerIndex]
        : 0;
    final oppScore = oppIdx < _scores.length ? _scores[oppIdx] : 0;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopIn(
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: isMyWin ? CandyColors.sun : const Color(0xFFFFD9DC),
                    shape: BoxShape.circle,
                    border: Border.all(color: CandyColors.ink, width: 3),
                    boxShadow: const [
                      BoxShadow(color: CandyColors.ink, offset: Offset(0, 5)),
                    ],
                  ),
                  child: Icon(
                    isMyWin
                        ? Icons.celebration_rounded
                        : Icons.sentiment_dissatisfied_rounded,
                    size: 52,
                    color: CandyColors.ink,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isMyWin ? '라운드 승리!' : '라운드 패배',
                style: TextStyle(
                  fontFamily: CandyTheme.displayFont,
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: isMyWin
                      ? CandyColors.mintDeep
                      : const Color(0xFFE5484D),
                ),
              ),
              const SizedBox(height: 8),
              if (_roundEndWord != null && _roundEndWord!.isNotEmpty) ...[
                Text(
                  '"${_roundEndWord!}"',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                reasonText,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: CandyColors.inkSoft,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Round $_currentRound/3',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: CandyColors.inkSoft,
                ),
              ),
              const SizedBox(height: 8),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '$myScore',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '$oppScore',
                accentColor: _theme.primary,
              ),
              const SizedBox(height: 18),
              CircularProgressIndicator(color: _theme.primary),
              const SizedBox(height: 8),
              const Text(
                '다음 라운드 준비 중...',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: CandyColors.inkSoft,
                ),
              ),
            ],
          ),
        ),
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
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopIn(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: isMyWin ? CandyColors.sun : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: CandyColors.ink, width: 3),
                  boxShadow: const [
                    BoxShadow(color: CandyColors.ink, offset: Offset(0, 5)),
                  ],
                ),
                child: Icon(
                  isMyWin ? Icons.celebration_rounded : Icons.flag_rounded,
                  size: 52,
                  color: isMyWin ? CandyColors.ink : _theme.primary,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              winnerName != null ? '$winnerName 라운드 승!' : '라운드 종료',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: CandyTheme.displayFont,
                fontSize: 28,
                fontWeight: FontWeight.w900,
                color: isMyWin ? CandyColors.mintDeep : CandyColors.ink,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Round $_currentRound',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: CandyColors.inkSoft,
              ),
            ),
            const SizedBox(height: 12),
            // 전원 점수
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: List.generate(_players.length, (i) {
                final left = _leftIndices.contains(i);
                final score = i < _scores.length ? _scores[i] : 0;
                return Opacity(
                  opacity: left ? 0.4 : 1,
                  child: SizedBox(
                    width: 74,
                    child: CartoonCard(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 4,
                      ),
                      radius: 16,
                      shadow: 3,
                      color: i == winnerIdx ? CandyColors.sun : Colors.white,
                      child: Column(
                        children: [
                          Text(
                            i == _myPlayerIndex ? '나' : _nameForIndex(i),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: CandyColors.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          _ScoreBadge(
                            score: score,
                            color: _theme.primary,
                            textColor: Colors.white,
                            size: 34,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 20),
            CircularProgressIndicator(color: _theme.primary),
            const SizedBox(height: 8),
            const Text(
              '다음 라운드 준비 중...',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: CandyColors.inkSoft,
              ),
            ),
          ],
        ),
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
    String? resultSub;
    Color resultColor;
    IconData resultIcon;

    if (_wonByForfeit) {
      resultText = '승리!';
      resultSub = '상대가 나갔습니다';
      resultColor = CandyColors.mintDeep;
      resultIcon = Icons.emoji_events;
    } else if (_isDraw) {
      resultText = '무승부!';
      resultColor = CandyColors.sky;
      resultIcon = Icons.handshake;
    } else if (_winnerId == _myId || _winnerId == _socketService.socket?.id) {
      resultText = '승리!';
      resultColor = CandyColors.mintDeep;
      resultIcon = Icons.emoji_events;
    } else {
      resultText = '패배';
      resultColor = CandyColors.inkSoft;
      resultIcon = Icons.sentiment_dissatisfied;
    }

    final oppIdx = _myPlayerIndex == 0 ? 1 : 0;
    final myScore = _myPlayerIndex < _scores.length
        ? _scores[_myPlayerIndex]
        : 0;
    final oppScore = oppIdx < _scores.length ? _scores[oppIdx] : 0;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GameResultHero(
                icon: resultIcon,
                color: resultColor,
                title: resultText,
                subtitle: resultSub,
              ),
              const SizedBox(height: 18),
              GameResultMatchupRow(
                leftLabel: '나',
                leftValue: '$myScore',
                rightLabel: _opponentNickname ?? '상대',
                rightValue: '$oppScore',
                accentColor: _theme.primary,
              ),
              const SizedBox(height: 24),
              GameEndActionPanel(
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
                acceptColor: CandyColors.tangerine,
                waitingTextColor: CandyColors.inkSoft,
                leaveForegroundColor: CandyColors.ink,
                leaveBorderSide: const BorderSide(
                  color: CandyColors.ink,
                  width: 2.5,
                ),
              ),
            ],
          ),
        ),
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
        if (!isLeft(i)) i,
    ]..sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));
    final leftList = [
      for (var i = 0; i < _players.length; i++)
        if (isLeft(i)) i,
    ];
    final order = [...active, ...leftList];
    int rankOf(int i) =>
        1 + active.where((j) => scoreOf(j) > scoreOf(i)).length;

    final myScore = scoreOf(_myPlayerIndex);
    final iAmActive = !isLeft(_myPlayerIndex);
    final myRank = iAmActive
        ? rankOf(_myPlayerIndex)
        : order.indexOf(_myPlayerIndex) + 1;
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
                    ? CandyColors.tangerine
                    : CandyColors.inkSoft,
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
                return PopIn(
                  delay: Duration(milliseconds: 80 * pos),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isMe
                          ? Color.lerp(accent, Colors.white, 0.75)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: CandyColors.ink, width: 2.5),
                      boxShadow: const [
                        BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
                      ],
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          child: Text(
                            left
                                ? '–'
                                : (r >= 1 && r <= 3 ? medal[r - 1] : '$r'),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: CandyColors.ink,
                            ),
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
                              fontWeight: isMe
                                  ? FontWeight.w900
                                  : FontWeight.w700,
                              color: CandyColors.ink,
                              decoration: left
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        if (left)
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Text(
                              '이탈',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: CandyColors.inkSoft,
                              ),
                            ),
                          ),
                        Text(
                          '$score승',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: isMe ? CandyColors.ink : accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 14),
              ChunkyButton(
                label: '다시 매칭',
                icon: Icons.refresh_rounded,
                color: accent,
                textColor: _theme.textOnPrimary,
                onPressed: () {
                  _resetToIdle();
                  _findMatch();
                },
              ),
              const SizedBox(height: 12),
              ChunkyButton(
                label: '로비로',
                color: Colors.white,
                textColor: CandyColors.ink,
                height: 46,
                fontSize: 16,
                onPressed: _leaveGame,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLeaveConfirmDialog() {
    // 매칭 대기 중에는 큐에서 빠진 뒤 바로 나간다(확인창·패배 처리 불필요).
    if (_status == HunminGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: CandyColors.ink, width: 2.5),
        boxShadow: const [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [2, 3, 4].map((n) {
          final selected = value == n;
          return GestureDetector(
            onTap: () => onChanged(n),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: selected ? CandyColors.ink : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Text(
                '$n인',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: selected ? Colors.white : CandyColors.inkSoft,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// 점수 원형 배지. 점수가 바뀌면 통통 튄다.
class _ScoreBadge extends StatelessWidget {
  final int score;
  final Color color;
  final Color textColor;
  final double size;
  const _ScoreBadge({
    required this.score,
    required this.color,
    required this.textColor,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(score),
      tween: Tween(begin: 1.5, end: 1.0),
      duration: const Duration(milliseconds: 450),
      curve: Curves.elasticOut,
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: CandyColors.ink, width: 2),
        ),
        child: Text(
          '$score',
          style: TextStyle(
            fontSize: size * 0.5,
            fontWeight: FontWeight.w900,
            color: textColor,
          ),
        ),
      ),
    );
  }
}
