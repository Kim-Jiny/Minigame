import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../common/game_intro_view.dart';
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
import '../../utils/game_registry.dart';
import '../../widgets/cartoon/cartoon_card.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/confetti_burst.dart';
import '../../widgets/cartoon/pop_in.dart';
import '../../widgets/game_player_profile.dart';
import '../common/game_rematch_preparing_view.dart';
import '../common/game_end_action_panel.dart';
import '../common/game_scaffold.dart';
import '../common/match_status_views.dart';
import '../common/game_reconnect_helper.dart';
import '../common/game_result_summary.dart';
import '../common/game_timer_badge.dart';

enum PyramidGameStatus {
  idle,
  searching,
  matched,
  playing,
  buzzing,
  roundEnd,
  finished,
}

/// 피라미드 카드 데이터
class PyramidCard {
  final int position; // 0-9
  final int row; // 0-3
  final int col; // 0~row
  final String operator; // +, -, *
  final int value; // 1-9

  PyramidCard({
    required this.position,
    required this.row,
    required this.col,
    required this.operator,
    required this.value,
  });

  String get displayText {
    final op = operator == '*' ? '\u00D7' : operator;
    return '$op$value';
  }
}

/// 부모-자식 관계 매핑
const Map<int, List<int>> childrenMap = {
  0: [1, 2],
  1: [3, 4],
  2: [4, 5],
  3: [6, 7],
  4: [7, 8],
  5: [8, 9],
};

class PyramidScreen extends StatefulWidget {
  /// 진입 맥락. 혼자하기 → 랭킹 도전/보기만, 둘이하기 → 대전/친구초대만.
  final GameEntryMode entryMode;

  const PyramidScreen({super.key, this.entryMode = GameEntryMode.versus});

  @override
  State<PyramidScreen> createState() => _PyramidScreenState();
}

class _PyramidScreenState extends State<PyramidScreen>
    with TickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  // 게임 고유색 대신 사용자 테마 컬러를 accent로 사용.
  Color get _accent => GameTheme.fromProfileSettings(
    context.read<ShopProvider>().profileSettings,
  ).primary;
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );

  // 게임 상태
  PyramidGameStatus _status = PyramidGameStatus.idle;
  // ignore: unused_field
  bool _isInvitationGame = false;
  bool _isSolo = false;
  List<Map<String, dynamic>> _rankings = [];
  // 랭킹 시트는 모달(별도 라우트)이라 화면 setState로는 갱신되지 않는다.
  // 비동기 응답이 도착하면 시트를 다시 그리도록 ValueNotifier로 구동한다.
  final ValueNotifier<List<Map<String, dynamic>>> _rankingsListenable =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  // 플레이어 정보
  String? _myId;
  String? _myNickname;
  String? _myAvatarUrl;
  int _myPlayerIndex = 0;
  String? _opponentNickname;
  String? _opponentAvatarUrl;
  UserProfileSettings? _myProfileSettings;
  UserProfileSettings? _opponentProfileSettings;

  // 방 정보
  String? _roomId;

  // 게임 데이터
  List<PyramidCard> _cards = [];
  int _targetNumber = 0;
  int _currentRound = 0;
  List<int> _scores = [0, 0];
  List<List<int>> _validPaths = [];
  List<int> _myAnswerPath = []; // 내가 맞춘 정답 경로

  // 선택 상태
  List<int> _selectedSequence = []; // 버저 후 선택한 카드 인덱스 순서
  int? _buzzingPlayerIndex;

  // 타이머
  Timer? _idleTimer;
  Timer? _buzzTimer;
  int _idleRemaining = 60;
  int _buzzRemaining = 15;

  // 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  bool _wonByForfeit = false; // 상대 mid-game 이탈로 인한 몰수승(결과 표시용)

  // 재연결
  bool _isReconnecting = false;
  Timer? _reconnectTimer;

  // 라운드 스킵
  bool _skipAvailable = false;
  bool _mySkipVoted = false;
  bool _opponentSkipVoted = false;

  // 리매치
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;

  // 애니메이션
  late AnimationController _resultAnimController;
  String? _lastResultMessage;
  Color? _lastResultColor;

  // 정답/오답 카드 반짝임 + 컨페티
  List<int> _flashCards = [];
  bool _flashCorrect = true;
  int _flashTick = 0;
  int _confettiTick = 0;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    // 로비의 '바로 대전'/빠른 시작이면 인트로를 건너뛰고 바로 상대를 찾는다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.entryMode != GameEntryMode.versus) return;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is GameLaunchArgs && args.takeAutoStart()) _findMatch();
    });
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
    _rankingsListenable.dispose();
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    _reconnectTimer?.cancel();
    _flashTimer?.cancel();
    _resultAnimController.dispose();
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
          _status = PyramidGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🔺 PyramidScreen: GameProvider 초기화 실패: $e');
    }
  }

  void _setupSocketListeners() {
    // 소켓 재연결 감지: 게임 중이었으면 재연결 대기
    _socketListeners.on('connect', (_) {
      final isInGame =
          _status != PyramidGameStatus.idle &&
          _status != PyramidGameStatus.finished &&
          _status != PyramidGameStatus.searching;
      if (isInGame && _roomId != null) {
        _reconnectTimer?.cancel();
        _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
          context: context,
          onEnterWaiting: () => setState(() => _isReconnecting = true),
          onTimeout: () {
            _idleTimer?.cancel();
            _buzzTimer?.cancel();
            setState(() {
              _isReconnecting = false;
              _status = PyramidGameStatus.finished;
              _opponentLeft = true;
            });
          },
        );
      }
    });

    // 재연결 시 게임 상태 복원
    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'pyramid') return;
      _reconnectTimer?.cancel();

      // 소켓 ID 업데이트 (재연결로 변경됨)
      _myId = _socketService.socket?.id;

      final cardsData = data['cards'] as List<dynamic>? ?? [];
      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      final roundState = data['roundState'] as String? ?? 'playing';

      _cards = cardsData
          .map(
            (c) => PyramidCard(
              position: (c['position'] as num).toInt(),
              row: (c['row'] as num).toInt(),
              col: (c['col'] as num).toInt(),
              operator: c['operator'] as String,
              value: (c['value'] as num).toInt(),
            ),
          )
          .toList();
      _targetNumber = (data['targetNumber'] as num?)?.toInt() ?? 0;
      _currentRound = (data['round'] as num?)?.toInt() ?? 0;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? 0;
      _roomId = data['roomId'] as String?;
      _selectedSequence = [];

      final validPathsData = data['validPaths'] as List<dynamic>?;
      if (validPathsData != null) {
        _validPaths = validPathsData
            .map(
              (p) =>
                  (p as List<dynamic>).map((v) => (v as num).toInt()).toList(),
            )
            .toList();
      }

      _buzzingPlayerIndex = data['buzzingPlayer'] != null
          ? (data['buzzingPlayer'] as num).toInt()
          : null;

      // 타이머 초기화
      _idleTimer?.cancel();
      _buzzTimer?.cancel();

      // 라운드 상태에 따라 게임 상태 복원
      switch (roundState) {
        case 'playing':
          _startIdleTimer();
          _status = PyramidGameStatus.playing;
          break;
        case 'buzzing':
          if (_buzzingPlayerIndex == _myPlayerIndex) {
            _startBuzzTimer();
          }
          _status = PyramidGameStatus.buzzing;
          break;
        default:
          _startIdleTimer();
          _status = PyramidGameStatus.playing;
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
      setState(() => _status = PyramidGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
      debugPrint('🔺 pyramid match_found 수신: roomId=${data['roomId']}');
      final players = data['players'] as List<dynamic>;
      _roomId = data['roomId'] as String?;
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);
      if (_myPlayerIndex == -1) _myPlayerIndex = 0;
      final opponentIdx = _myPlayerIndex == 0 ? 1 : 0;
      if (opponentIdx < players.length) {
        _opponentNickname = players[opponentIdx]['nickname'] as String?;
        _opponentAvatarUrl = players[opponentIdx]['avatarUrl'] as String?;
        final profileSettings = players[opponentIdx]['profileSettings'];
        if (profileSettings != null) {
          _opponentProfileSettings = UserProfileSettings.fromJson(
            profileSettings,
          );
        }
      }
      setState(() => _status = PyramidGameStatus.matched);
    });

    _socketListeners.on('pyramid_solo_ready', (data) {
      _roomId = data['roomId'] as String?;
    });

    _socketListeners.on('pyramid_rankings', (data) {
      final list = data['rankings'] as List<dynamic>? ?? [];
      setState(() {
        _rankings = list
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
      });
      _rankingsListenable.value = _rankings; // 열려 있는 랭킹 시트 갱신
    });

    _socketListeners.on('game_start', (data) {
      debugPrint('🔺 pyramid game_start 수신: $data');
      if (data['players'] != null) {
        final players = data['players'] as List<dynamic>;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) {
          _myPlayerIndex = updatedIndex;
        }
      }
      setState(() {
        _isSolo = data['isSolo'] as bool? ?? false;
        _scores = _isSolo ? [0] : [0, 0];
        _currentRound = 0;
        _opponentLeft = false;
        _wonByForfeit = false;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _winnerId = null;
        _isDraw = false;
      });
    });

    _socketListeners.on('pyramid_round_start', (data) {
      debugPrint(
        '🔺 pyramid_round_start 수신: round=${data['round']}, target=${data['targetNumber']}',
      );
      final cardsData = data['cards'] as List<dynamic>;
      _cards = cardsData
          .map(
            (c) => PyramidCard(
              position: (c['position'] as num).toInt(),
              row: (c['row'] as num).toInt(),
              col: (c['col'] as num).toInt(),
              operator: c['operator'] as String,
              value: (c['value'] as num).toInt(),
            ),
          )
          .toList();
      _targetNumber = (data['targetNumber'] as num).toInt();
      _currentRound = (data['round'] as num).toInt();
      _selectedSequence = [];
      _myAnswerPath = [];
      _flashCards = [];
      _lastResultMessage = null;
      _buzzingPlayerIndex = null;
      _skipAvailable = false;
      _mySkipVoted = false;
      _opponentSkipVoted = false;

      final validPathsData = data['validPaths'] as List<dynamic>?;
      if (validPathsData != null) {
        _validPaths = validPathsData
            .map(
              (p) =>
                  (p as List<dynamic>).map((v) => (v as num).toInt()).toList(),
            )
            .toList();
      }

      final scoreData = data['scores'] as List<dynamic>?;
      if (scoreData != null) {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
      }

      _startIdleTimer();
      setState(() => _status = PyramidGameStatus.playing);
    });

    _socketListeners.on('pyramid_skip_available', (_) {
      setState(() => _skipAvailable = true);
    });

    _socketListeners.on('pyramid_skip_voted', (_) {
      setState(() => _opponentSkipVoted = true);
    });

    _socketListeners.on('pyramid_buzz', (data) {
      _buzzingPlayerIndex = (data['playerIndex'] as num).toInt();
      _idleTimer?.cancel();
      // 버저 누르면 스킵 상태 초기화
      _skipAvailable = false;
      _mySkipVoted = false;
      _opponentSkipVoted = false;

      if (_buzzingPlayerIndex == _myPlayerIndex) {
        _startBuzzTimer();
      }

      setState(() => _status = PyramidGameStatus.buzzing);
    });

    _socketListeners.on('pyramid_answer_result', (data) {
      final correct = data['correct'] as bool;
      final playerIdx = (data['playerIndex'] as num).toInt();
      final nickname = data['playerNickname'] as String? ?? '';

      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();

      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;
      final prevSelected = List<int>.from(_selectedSequence);
      if (correct && playerIdx == _myPlayerIndex) {
        _myAnswerPath = List.from(_selectedSequence);
      }
      _selectedSequence = [];

      // 정답/오답 카드 반짝임 (내 답일 때만 어떤 카드인지 안다)
      if (playerIdx == _myPlayerIndex) {
        _triggerFlash(prevSelected, correct, celebrate: correct);
        if (correct) {
          HapticFeedback.mediumImpact();
        } else {
          HapticFeedback.heavyImpact();
        }
      }

      if (correct) {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '정답! (+1)'
            : '$nickname: 정답! (+1)';
        _lastResultColor = playerIdx == _myPlayerIndex
            ? CandyColors.mintDeep
            : CandyColors.tangerine;
      } else {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '오답! (-1)'
            : '$nickname: 오답 (-1)';
        _lastResultColor = const Color(0xFFFF5A5F);
      }
      _resultAnimController.forward(from: 0);

      // 정답이면 라운드 종료 이벤트가 올 것이므로 playing 유지
      if (!correct) {
        setState(() => _status = PyramidGameStatus.playing);
        _startIdleTimer();
      } else {
        setState(() {});
      }
    });

    _socketListeners.on('pyramid_buzz_timeout', (data) {
      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;
      _selectedSequence = [];

      _lastResultMessage = '시간 초과! (-1)';
      _lastResultColor = const Color(0xFFFF5A5F);
      _resultAnimController.forward(from: 0);

      setState(() => _status = PyramidGameStatus.playing);
      _startIdleTimer();
    });

    _socketListeners.on('pyramid_round_end', (data) {
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;

      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();

      final validPathsData = data['validPaths'] as List<dynamic>?;
      if (validPathsData != null) {
        _validPaths = validPathsData
            .map(
              (p) =>
                  (p as List<dynamic>).map((v) => (v as num).toInt()).toList(),
            )
            .toList();
        // 내가 맞춘 경로를 맨 앞으로 (보드에서 하이라이트됨)
        if (_myAnswerPath.isNotEmpty) {
          _validPaths.removeWhere(
            (p) =>
                p.length == _myAnswerPath.length &&
                List.generate(
                  p.length,
                  (i) => p[i] == _myAnswerPath[i],
                ).every((v) => v),
          );
          _validPaths.insert(0, _myAnswerPath);
          _myAnswerPath = [];
        }
      }

      final cardsData = data['cards'] as List<dynamic>?;
      if (cardsData != null) {
        _cards = cardsData
            .map(
              (c) => PyramidCard(
                position: (c['position'] as num).toInt(),
                row: (c['row'] as num).toInt(),
                col: (c['col'] as num).toInt(),
                operator: c['operator'] as String,
                value: (c['value'] as num).toInt(),
              ),
            )
            .toList();
      }

      // 시각적으로 같은 수식(순열만 다른 경로, 동일 value+operator 카드로 인한
      // 같은 문자열 등)은 하나만 남긴다. 카드 정보가 이미 업데이트된 이 시점에
      // 실행해야 _pathToString이 현재 라운드 기준으로 키를 만든다.
      if (_validPaths.isNotEmpty && _cards.isNotEmpty) {
        final seen = <String>{};
        _validPaths = _validPaths
            .where((p) => seen.add(_pathToString(p)))
            .toList();
      }

      setState(() => _status = PyramidGameStatus.roundEnd);
    });

    _socketListeners.on('game_end', (data) {
      if (_status == PyramidGameStatus.finished ||
          _status == PyramidGameStatus.idle ||
          _status == PyramidGameStatus.searching) {
        return;
      }
      _idleTimer?.cancel();
      _buzzTimer?.cancel();

      final scoreData = data['scores'] as List<dynamic>?;
      if (scoreData != null) {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
      }

      setState(() {
        _status = PyramidGameStatus.finished;
        _winnerId = data['winner'] as String?;
        _isDraw = data['isDraw'] as bool? ?? false;
      });
    });

    _socketListeners.on('opponent_left', (_) {
      if (_status == PyramidGameStatus.idle ||
          _status == PyramidGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == PyramidGameStatus.finished) {
        setState(() {
          _opponentLeft = true;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
        });
        return;
      }
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      setState(() {
        _status = PyramidGameStatus.finished;
        _winnerId = _myId;
        _opponentLeft = true;
        _wonByForfeit = true;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('상대방이 나갔습니다'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    });

    _socketListeners.on('rematch_waiting', (data) {
      setState(() => _rematchWaiting = data['waiting'] as bool? ?? true);
    });

    _socketListeners.on('rematch_requested', (_) {
      setState(() => _opponentWantsRematch = true);
    });

    _socketListeners.on('rematch_cancelled', (_) {
      setState(() => _opponentWantsRematch = false);
    });

    _socketListeners.on('error', (data) {
      final message = data['message'] as String? ?? '';
      if (message.contains('room') && message.contains('invalid')) {
        _handleRoomInvalid();
      }
    });
  }

  void _triggerFlash(List<int> cards, bool correct, {bool celebrate = false}) {
    _flashTimer?.cancel();
    if (celebrate) _confettiTick++;
    if (cards.isEmpty) return;
    _flashCards = List<int>.from(cards);
    _flashCorrect = correct;
    _flashTick++;
    _flashTimer = Timer(const Duration(milliseconds: 750), () {
      if (!mounted) return;
      setState(() => _flashCards = []);
    });
  }

  // 타이머
  void _startIdleTimer() {
    _idleTimer?.cancel();
    _idleRemaining = 60;
    _idleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_idleRemaining > 0) {
        setState(() => _idleRemaining--);
      } else {
        timer.cancel();
      }
    });
  }

  void _startBuzzTimer() {
    _buzzTimer?.cancel();
    _buzzRemaining = 15;
    _buzzTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_buzzRemaining > 0) {
        setState(() => _buzzRemaining--);
      } else {
        timer.cancel();
      }
    });
  }

  // 액션
  void _findMatch() {
    _socketService.emit('find_match', {'gameType': AppConfig.gameTypePyramid});
    setState(() => _status = PyramidGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypePyramid,
    });
    setState(() => _status = PyramidGameStatus.idle);
  }

  void _startSolo() {
    _socketService.emit('pyramid_solo_start', {});
    _isSolo = true;
    setState(() => _status = PyramidGameStatus.matched);
  }

  void _endSoloChallenge() {
    if (_roomId == null) return;
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    _socketService.emit('pyramid_solo_end', {'roomId': _roomId});
    setState(() {
      _status = PyramidGameStatus.finished;
    });
  }

  void _fetchRankings() {
    _socketService.emit('pyramid_get_rankings', {'limit': 20});
  }

  void _buzz() {
    if (_status != PyramidGameStatus.playing || _roomId == null) return;
    HapticFeedback.heavyImpact();
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'buzz'},
    });
  }

  void _submitAnswer() {
    if (_status != PyramidGameStatus.buzzing || _roomId == null) return;
    if (_selectedSequence.length != 3) return;
    if (_buzzingPlayerIndex != _myPlayerIndex) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'answer', 'sequence': _selectedSequence},
    });
  }

  /// 카드가 현재 선택 가능한지
  bool _isCardSelectable(int cardIdx) {
    // 이미 선택했으면 불가
    if (_selectedSequence.contains(cardIdx)) return false;

    // 모든 카드 자유롭게 선택 가능
    return true;
  }

  void _toggleCardSelection(int cardIdx) {
    if (_status != PyramidGameStatus.buzzing) return;
    if (_buzzingPlayerIndex != _myPlayerIndex) return;

    setState(() {
      if (_selectedSequence.isNotEmpty && _selectedSequence.last == cardIdx) {
        // 마지막 선택 취소 (되돌리기)
        _selectedSequence.removeLast();
      } else if (!_selectedSequence.contains(cardIdx) &&
          _isCardSelectable(cardIdx) &&
          _selectedSequence.length < 3) {
        _selectedSequence.add(cardIdx);
      }
    });
  }

  void _skipRound() {
    if (_roomId == null || _mySkipVoted) return;
    _socketService.emit('pyramid_skip_round', {'roomId': _roomId});
    setState(() => _mySkipVoted = true);
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

  void _handleRoomInvalid() {
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    setState(() {
      _status = PyramidGameStatus.idle;
      _roomId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ShopProvider>(
      builder: (context, shopProvider, _) {
        final theme = shopProvider.profileSettings != null
            ? GameTheme.fromProfileSettings(shopProvider.profileSettings)
            : GameTheme.defaultTheme;

        return PopScope(
          canPop:
              _status == PyramidGameStatus.idle ||
              _status == PyramidGameStatus.finished,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _showExitDialog(theme);
            }
          },
          child: Scaffold(
            backgroundColor: theme.background2,
            appBar: gameAppBar(
              title: '수식피라미드',
              backgroundColor: _accent,
              boldTitle: true,
            ),
            body: Container(
              decoration: BoxDecoration(gradient: theme.backgroundGradient),
              child: SafeArea(
                child: Stack(
                  children: [
                    _buildBody(theme),
                    if (_isReconnecting)
                      Container(
                        color: CandyColors.ink.withValues(alpha: 0.6),
                        child: Center(
                          child: PopIn(
                            child: CartoonCard(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 28,
                                vertical: 22,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(color: _accent),
                                  const SizedBox(height: 16),
                                  const Text(
                                    '재연결 중...',
                                    style: TextStyle(
                                      color: CandyColors.ink,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    // 정답 컨페티 (화면 전환에도 유지)
                    if (_confettiTick > 0)
                      Positioned.fill(
                        child: ConfettiBurst(
                          key: ValueKey('confetti-$_confettiTick'),
                          count: 30,
                          duration: const Duration(milliseconds: 1600),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(GameTheme theme) {
    switch (_status) {
      case PyramidGameStatus.idle:
        return _buildIdleView(theme);
      case PyramidGameStatus.searching:
        return _buildSearchingView(theme);
      case PyramidGameStatus.matched:
        return _buildMatchedView(theme);
      case PyramidGameStatus.playing:
      case PyramidGameStatus.buzzing:
        return _buildPlayingView(theme);
      case PyramidGameStatus.roundEnd:
        return _buildRoundEndView(theme);
      case PyramidGameStatus.finished:
        return _buildFinishedView(theme);
    }
  }

  // ==================== IDLE ====================
  Widget _buildIdleView(GameTheme theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopIn(
                child: CartoonCard(
                  color: Colors.white,
                  radius: 30,
                  padding: EdgeInsets.zero,
                  child: SizedBox(
                    width: 104,
                    height: 104,
                    child: Center(
                      child: Icon(
                        Icons.change_history_rounded,
                        size: 58,
                        color: _accent,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                '수식피라미드',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '카드를 골라 목표 숫자를 맞춰라!',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: CandyColors.inkSoft,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              PopIn(
                delay: const Duration(milliseconds: 120),
                child: CartoonCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ruleRow('1', '피라미드에서 아래줄부터 카드 선택', _accent),
                      _ruleRow('2', '정확히 3장을 골라 조합!', _accent),
                      _ruleRow('3', '첫 카드 = 시작값, 이후 연산 적용', _accent),
                      _ruleRow('4', '결과가 타겟 넘버와 같으면 정답!', _accent),
                      _ruleRow('5', '버저를 누르고 15초 내 답변', _accent),
                      _ruleRow('★', '정답 +1점 / 오답 -1점', CandyColors.tangerine),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // 혼자하기로 진입 → 랭킹 도전 + 솔로 랭킹 보기
              if (widget.entryMode == GameEntryMode.solo) ...[
                ChunkyButton(
                  label: '랭킹 도전 (솔로)',
                  icon: Icons.person_rounded,
                  color: _accent,
                  onPressed: _startSolo,
                ),
                const SizedBox(height: 14),
                ChunkyButton(
                  label: '솔로 랭킹 보기',
                  icon: Icons.leaderboard_rounded,
                  color: Colors.white,
                  textColor: CandyColors.ink,
                  height: 48,
                  fontSize: 16,
                  onPressed: () => _showRankingSheet(theme),
                ),
              ],
              // 둘이하기로 진입 → 대전 + 친구 초대
              if (widget.entryMode == GameEntryMode.versus) ...[
                ChunkyButton(
                  label: '대전 (2인)',
                  icon: Icons.people_rounded,
                  color: _accent,
                  onPressed: _findMatch,
                ),
                const SizedBox(height: 14),
                ChunkyButton(
                  label: '친구 초대',
                  icon: Icons.person_add_rounded,
                  color: Colors.white,
                  textColor: CandyColors.ink,
                  height: 48,
                  fontSize: 16,
                  onPressed: () => _showFriendInviteDialog(context),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _ruleRow(String num, String text, Color badge) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: badge,
              shape: BoxShape.circle,
              border: Border.all(color: CandyColors.ink, width: 2),
            ),
            child: Text(
              num,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: CandyColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== SEARCHING ====================
  Widget _buildSearchingView(GameTheme theme) {
    return GameSoloSearchingView(accentColor: _accent, onCancel: _cancelMatch);
  }

  // ==================== MATCHED ====================
  Widget _buildMatchedView(GameTheme theme) {
    return GameSoloMatchedView(
      accentColor: _accent,
      opponentNickname: _opponentNickname,
      isSolo: _isSolo,
    );
  }

  // ==================== PLAYING / BUZZING ====================
  Widget _buildPlayingView(GameTheme theme) {
    final iAmBuzzing =
        _status == PyramidGameStatus.buzzing &&
        _buzzingPlayerIndex == _myPlayerIndex;
    final otherBuzzing =
        _status == PyramidGameStatus.buzzing &&
        _buzzingPlayerIndex != _myPlayerIndex;

    return Column(
      children: [
        _buildHeader(theme),
        // 타겟 넘버 + 타이머/버저 상태
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                key: ValueKey('target-$_currentRound-$_targetNumber'),
                tween: Tween(begin: 0.6, end: 1.0),
                duration: const Duration(milliseconds: 520),
                curve: Curves.elasticOut,
                builder: (_, s, child) =>
                    Transform.scale(scale: s, child: child),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: CandyColors.ink, width: 2.5),
                    boxShadow: const [
                      BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
                    ],
                  ),
                  child: Text(
                    '🎯 타겟 $_targetNumber',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: _status == PyramidGameStatus.playing
                    ? GameTimerBadge(
                        seconds: _idleRemaining,
                        label: '',
                        accentColor: _accent,
                        compact: true,
                        showLabel: false,
                        warningThreshold: 10,
                      )
                    : _CandyPill(
                        text: iAmBuzzing
                            ? '답변하세요! $_buzzRemaining초'
                            : '${_getPlayerNickname(_buzzingPlayerIndex ?? 0)} 답변 중...',
                        color: iAmBuzzing
                            ? CandyColors.tangerine
                            : CandyColors.sky,
                        icon: iAmBuzzing
                            ? Icons.bolt_rounded
                            : Icons.hourglass_top_rounded,
                      ),
              ),
            ],
          ),
        ),
        // 피라미드 보드 + 결과 토스트
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _buildPyramidBoard(theme)),
              if (_lastResultMessage != null)
                Positioned(
                  top: 2,
                  left: 12,
                  right: 12,
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _resultAnimController,
                      builder: (_, _) {
                        final t = _resultAnimController.value;
                        final pop = Curves.elasticOut.transform(
                          (t * 2.2).clamp(0.0, 1.0),
                        );
                        final opacity = t < 0.7
                            ? 1.0
                            : (1.0 - (t - 0.7) / 0.3).clamp(0.0, 1.0);
                        return Opacity(
                          opacity: opacity,
                          child: Transform.scale(
                            scale: 0.6 + 0.4 * pop,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: _lastResultColor ?? CandyColors.ink,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: CandyColors.ink,
                                    width: 2.5,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: CandyColors.ink,
                                      offset: Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  _lastResultMessage!,
                                  maxLines: 2,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
        // 액션바
        _buildActionBar(theme, iAmBuzzing, otherBuzzing),
      ],
    );
  }

  PyramidCard? _cardAt(int position) {
    for (final c in _cards) {
      if (c.position == position) return c;
    }
    return null;
  }

  Widget _buildActionBar(GameTheme theme, bool iAmBuzzing, bool otherBuzzing) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: CandyColors.ink, width: 3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iAmBuzzing) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 되돌리기 버튼
                _UndoButton(
                  enabled: _selectedSequence.isNotEmpty,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      if (_selectedSequence.isNotEmpty) {
                        _selectedSequence.removeLast();
                      }
                    });
                  },
                ),
                const SizedBox(width: 6),
                // 선택한 카드 슬롯 (첫 카드 = 시작값)
                for (int i = 0; i < 3; i++)
                  Builder(
                    builder: (_) {
                      final card = i < _selectedSequence.length
                          ? _cardAt(_selectedSequence[i])
                          : null;
                      return _AnswerSlot(
                        label: card == null
                            ? null
                            : (i == 0 ? '${card.value}' : card.displayText),
                        color: _accent,
                      );
                    },
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: ChunkyButton(
                    label: '제출',
                    icon: Icons.check_rounded,
                    color: CandyColors.mint,
                    height: 48,
                    fontSize: 17,
                    expand: false,
                    onPressed: _selectedSequence.length == 3
                        ? _submitAnswer
                        : null,
                  ),
                ),
              ],
            ),
          ],
          if (!iAmBuzzing && !otherBuzzing) ...[
            ChunkyButton(
              label: '버저!',
              icon: Icons.notifications_active_rounded,
              color: const Color(0xFFFF5A5F),
              height: 60,
              fontSize: 24,
              onPressed: _buzz,
            ),
            // 20초 무활동 시 라운드 넘기기 버튼
            // 4-state UI:
            //  - 아무도 안 누름: "라운드 넘기기"
            //  - 상대만 누름: "상대가 넘기기 요청" (탭해서 동의 가능)
            //  - 나만 누름: "상대방 대기 중..." (비활성)
            //  - 둘 다 누름: "라운드 넘기는 중..." (비활성)
            if (_skipAvailable && !_isSolo) ...[
              const SizedBox(height: 8),
              ChunkyButton(
                label: _mySkipVoted
                    ? (_opponentSkipVoted ? '라운드 넘기는 중...' : '상대방 대기 중...')
                    : (_opponentSkipVoted ? '상대가 넘기기 요청' : '라운드 넘기기'),
                icon: _mySkipVoted
                    ? Icons.check_rounded
                    : (_opponentSkipVoted
                          ? Icons.notification_important_rounded
                          : Icons.skip_next_rounded),
                color: (!_mySkipVoted && _opponentSkipVoted)
                    ? CandyColors.tangerine
                    : Colors.white,
                textColor: (!_mySkipVoted && _opponentSkipVoted)
                    ? Colors.white
                    : CandyColors.ink,
                height: 42,
                fontSize: 15,
                onPressed: _mySkipVoted ? null : _skipRound,
              ),
            ],
          ],
          if (otherBuzzing && !_isSolo)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '상대방이 답변 중...',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: CandyColors.inkSoft,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ==================== ROUND END ====================
  Widget _buildRoundEndView(GameTheme theme) {
    final maxRounds = _isSolo ? 10 : 3;
    return Column(
      children: [
        _buildHeader(theme),
        const SizedBox(height: 12),
        PopIn(
          child: _CandyPill(
            text: '라운드 $_currentRound/$maxRounds 종료',
            color: _accent,
            icon: Icons.flag_rounded,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '타겟: $_targetNumber  ·  정답 경로: ${_validPaths.length}개',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: CandyColors.inkSoft,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(child: _buildPyramidBoard(theme, showPaths: true)),
        // 정답 경로 표시
        if (_validPaths.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: CandyColors.ink, width: 3)),
            ),
            constraints: const BoxConstraints(maxHeight: 118),
            child: ListView(
              shrinkWrap: true,
              children: _validPaths.take(3).toList().asMap().entries.map((e) {
                final first = e.key == 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _ComboChip(
                      text: _pathToString(e.value),
                      color: first ? CandyColors.mint : const Color(0xFFF1ECFA),
                      textColor: CandyColors.ink,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        const Padding(
          padding: EdgeInsets.all(10),
          child: Text(
            '다음 라운드 준비 중...',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: CandyColors.inkSoft,
            ),
          ),
        ),
      ],
    );
  }

  String _pathToString(List<int> path) {
    if (path.isEmpty || _cards.isEmpty) return '';
    if (path.any((i) => i < 0 || i >= _cards.length)) return '';
    final buf = StringBuffer();
    final first = _cards[path[0]];
    buf.write('${first.value}');
    num current = first.value;

    for (int i = 1; i < path.length; i++) {
      final card = _cards[path[i]];
      final op = card.operator == '*' ? '×' : card.operator;
      switch (card.operator) {
        case '+':
          current = current + card.value;
          break;
        case '-':
          current = current - card.value;
          break;
        case '*':
          current = current * card.value;
          break;
      }
      buf.write(' $op${card.value}');
    }
    buf.write(' = $current');
    return buf.toString();
  }

  // ==================== FINISHED ====================
  Widget _buildFinishedView(GameTheme theme) {
    if (_rematchWaiting) {
      return GameRematchPreparingView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: theme.primary,
        onCancel: _cancelRematch,
      );
    }
    final isWinner = _winnerId == _myId;
    final isSoloDone = _isSolo;
    final myScore = _scores.length > _myPlayerIndex
        ? _scores[_myPlayerIndex]
        : 0;
    final oppScore = _scores.length > 1
        ? _scores[_myPlayerIndex == 0 ? 1 : 0]
        : 0;

    final Widget hero;
    if (isSoloDone) {
      hero = const GameResultHero(
        icon: Icons.emoji_events,
        color: CandyColors.sunDeep,
        title: '도전 종료!',
        subtitle: '수고했어요, 기록이 저장돼요.',
      );
    } else if (_wonByForfeit) {
      hero = const GameResultHero(
        icon: Icons.emoji_events,
        color: CandyColors.mintDeep,
        title: '승리!',
        subtitle: '상대방이 나갔습니다',
      );
    } else if (_isDraw) {
      hero = const GameResultHero(
        icon: Icons.handshake,
        color: CandyColors.sky,
        title: '무승부',
      );
    } else if (isWinner) {
      hero = const GameResultHero(
        icon: Icons.emoji_events,
        color: CandyColors.mintDeep,
        title: '승리!',
      );
    } else {
      hero = const GameResultHero(
        icon: Icons.sentiment_dissatisfied,
        color: CandyColors.inkSoft,
        title: '패배',
      );
    }

    return Stack(
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  hero,
                  const SizedBox(height: 16),
                  if (isSoloDone)
                    CartoonCard(
                      child: Column(
                        children: [
                          const Text(
                            '최종 점수',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: CandyColors.inkSoft,
                            ),
                          ),
                          TweenAnimationBuilder<double>(
                            tween: Tween(
                              begin: 0,
                              end: (_scores.isNotEmpty ? _scores[0] : 0)
                                  .toDouble(),
                            ),
                            duration: const Duration(milliseconds: 900),
                            curve: Curves.easeOutCubic,
                            builder: (_, v, _) => Text(
                              '${v.round()}점',
                              style: TextStyle(
                                fontSize: 48,
                                fontWeight: FontWeight.w900,
                                color: _accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_scores.length >= 2)
                    GameResultMatchupRow(
                      leftLabel: '나',
                      leftValue: '$myScore점',
                      rightLabel: _opponentNickname ?? '상대',
                      rightValue: '$oppScore점',
                      accentColor: _accent,
                    ),
                  const SizedBox(height: 24),
                  GameEndActionPanel(
                    showRematchActions: !isSoloDone && !_opponentLeft,
                    opponentLeft: !isSoloDone && _opponentLeft,
                    opponentWantsRematch: _opponentWantsRematch,
                    rematchWaiting: _rematchWaiting,
                    primaryColor: _accent,
                    primaryForegroundColor: Colors.white,
                    onRequestRematch: _requestRematch,
                    onCancelRematch: _cancelRematch,
                    onLeave: _leaveGame,
                    rematchLabel: '재대결',
                    acceptRematchLabel: '재대결 수락',
                    waitingText: '상대방 응답 대기 중...',
                    cancelLabel: '취소',
                    leaveLabel: '로비로',
                    leaveIcon: Icons.home,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ==================== HEADER ====================
  Widget _buildHeader(GameTheme theme) {
    final maxRounds = _isSolo ? 10 : 3;
    final myScore = _scores.length > _myPlayerIndex
        ? _scores[_myPlayerIndex]
        : 0;
    final oppIdx = _myPlayerIndex == 0 ? 1 : 0;
    final oppScore = _scores.length > oppIdx ? _scores[oppIdx] : 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: CandyColors.ink, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildPlayerColumn(
              theme,
              _myNickname ?? '나',
              _myAvatarUrl,
              true,
              _myPlayerIndex,
              _myProfileSettings,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: CandyColors.ink, width: 2),
                ),
                child: Text(
                  'R$_currentRound/$maxRounds',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (_isSolo)
                _ScorePop(score: myScore, suffix: '점', color: _accent)
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ScorePop(score: myScore, color: _accent),
                    const Text(
                      ' : ',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: CandyColors.ink,
                      ),
                    ),
                    _ScorePop(score: oppScore, color: CandyColors.inkSoft),
                  ],
                ),
            ],
          ),
          if (!_isSolo)
            Expanded(
              child: _buildPlayerColumn(
                theme,
                _opponentNickname ?? '상대',
                _opponentAvatarUrl,
                false,
                oppIdx,
                _opponentProfileSettings,
              ),
            )
          else
            const Expanded(child: SizedBox()),
        ],
      ),
    );
  }

  Widget _buildPlayerColumn(
    GameTheme theme,
    String name,
    String? avatarUrl,
    bool isMe,
    int playerIndex,
    UserProfileSettings? profileSettings,
  ) {
    return Column(
      children: [
        GamePlayerProfile(
          name: name,
          avatarUrl: avatarUrl,
          isActive: _buzzingPlayerIndex == playerIndex,
          isMe: isMe,
          profileSettings: profileSettings,
          activeColor: _accent,
        ),
      ],
    );
  }

  // ==================== PYRAMID BOARD ====================
  Widget _buildPyramidBoard(GameTheme theme, {bool showPaths = false}) {
    if (_cards.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - 32;
        final availableHeight = constraints.maxHeight - 16;

        // 육각형 크기: 4열(맨 아래)이 들어가야 함
        final hexSize = max(
          8.0,
          min(availableWidth / 5.0, availableHeight / 5.0),
        );
        // 콘텐츠 실제 크기 (4열 기준)
        final contentWidth = 3 * hexSize * 1.1 + hexSize;
        final contentHeight = 3 * hexSize * 1.05 + hexSize;

        return RepaintBoundary(
          child: Center(
            child: SizedBox(
              width: contentWidth,
              height: contentHeight,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  for (final card in _cards)
                    _buildPyramidCard(theme, card, hexSize, showPaths),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 연산자별 카드 색 (면, 선택 시 진한 색)
  static (Color, Color) _opColors(String op) {
    switch (op) {
      case '+':
        return (const Color(0xFFD3F7EA), CandyColors.mint);
      case '-':
        return (const Color(0xFFFFDCE8), CandyColors.pink);
      default:
        return (const Color(0xFFD7EEFF), CandyColors.sky);
    }
  }

  Widget _buildPyramidCard(
    GameTheme theme,
    PyramidCard card,
    double hexSize,
    bool showPaths,
  ) {
    // 피라미드 배치: 각 행의 중앙 정렬
    const maxCols = 4; // Row 3 has 4 cards
    final rowSize = card.row + 1;
    final offset = (maxCols - rowSize) / 2.0;
    final x = (offset + card.col) * hexSize * 1.1;
    final y = card.row * hexSize * 1.05;

    final isSelected = _selectedSequence.contains(card.position);
    final selectionOrder = _selectedSequence.indexOf(card.position);
    final canSelect =
        _status == PyramidGameStatus.buzzing &&
        _buzzingPlayerIndex == _myPlayerIndex &&
        _isCardSelectable(card.position);
    final isLastSelected =
        _selectedSequence.isNotEmpty && _selectedSequence.last == card.position;
    final flashing = _flashCards.contains(card.position);

    // 정답 경로 하이라이트 (라운드 종료 시)
    final isInPath =
        showPaths &&
        _validPaths.isNotEmpty &&
        _validPaths.first.contains(card.position);

    final (soft, strong) = _opColors(card.operator);
    Color bgColor;
    if (flashing) {
      bgColor = _flashCorrect ? CandyColors.mint : const Color(0xFFFF5A5F);
    } else if (isSelected) {
      bgColor = strong;
    } else if (isInPath) {
      bgColor = CandyColors.sun;
    } else {
      bgColor = soft;
    }

    final lifted = isSelected || isInPath;

    Widget tile = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: bgColor),
      duration: const Duration(milliseconds: 150),
      builder: (_, c, _) => CustomPaint(
        painter: _HexagonPainter(
          fillColor: c ?? bgColor,
          borderColor: CandyColors.ink,
          borderWidth: 2.5,
          shadowOffset: lifted ? 5 : 3,
        ),
        child: Center(
          child: Text(
            card.displayText,
            style: TextStyle(
              fontSize: hexSize * 0.3,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
        ),
      ),
    );

    // 선택: 위로 들리며 살짝 커짐
    tile = AnimatedSlide(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutBack,
      offset: lifted ? const Offset(0, -0.06) : Offset.zero,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        scale: lifted ? 1.1 : 1.0,
        child: tile,
      ),
    );

    // 정답 = 통통 튀기 / 오답 = 흔들기 / 라운드 종료 정답 경로 = 한 번 통통
    final bounce = flashing ? _flashCorrect : isInPath;
    final shake = flashing && !_flashCorrect;
    final animKey = flashing
        ? 'f$_flashTick'
        : (isInPath ? 'p$_currentRound' : '0');
    tile = TweenAnimationBuilder<double>(
      key: ValueKey('pyrflash-${card.position}-$animKey'),
      tween: Tween(begin: (bounce || shake) ? 0.0 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 520),
      builder: (_, t, child) {
        if (shake) {
          return Transform.translate(
            offset: Offset(sin(t * pi * 6) * 5 * (1 - t), 0),
            child: child,
          );
        }
        if (bounce) {
          return Transform.scale(
            scale:
                0.8 + 0.2 * Curves.elasticOut.transform(t) + 0.1 * sin(t * pi),
            child: child,
          );
        }
        return child!;
      },
      child: tile,
    );

    return Positioned(
      left: x,
      top: y,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (isLastSelected || canSelect) {
            HapticFeedback.selectionClick();
            _toggleCardSelection(card.position);
          }
        },
        child: SizedBox(
          width: hexSize,
          height: hexSize,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Positioned.fill(child: tile),
              // 선택 순서 번호
              if (isSelected && selectionOrder >= 0)
                Positioned(
                  top: hexSize * 0.06,
                  right: hexSize * 0.06,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: _accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: CandyColors.ink, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${selectionOrder + 1}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== HELPERS ====================
  String _getPlayerNickname(int playerIndex) {
    if (playerIndex == _myPlayerIndex) return _myNickname ?? '나';
    return _opponentNickname ?? '상대';
  }

  void _showRankingSheet(GameTheme theme) {
    _fetchRankings();
    _rankingsListenable.value = _rankings;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: CandyColors.cream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: CandyColors.ink, width: 3),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.leaderboard, color: _accent),
                      const SizedBox(width: 8),
                      const Text(
                        '솔로 랭킹',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: CandyColors.ink,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: _rankingsListenable,
                    builder: (context, rankings, _) {
                      return rankings.isEmpty
                          ? const Center(
                              child: Text(
                                '아직 기록이 없습니다',
                                style: TextStyle(
                                  color: CandyColors.inkSoft,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: rankings.length,
                              itemBuilder: (_, index) {
                                final r = rankings[index];
                                final nickname =
                                    r['nickname'] as String? ?? '???';
                                final score = r['score'] as int? ?? 0;
                                final isTop3 = index < 3;
                                return ListTile(
                                  leading: Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: isTop3
                                          ? [
                                              CandyColors.sun,
                                              const Color(0xFFC9C3D9),
                                              CandyColors.tangerine,
                                            ][index]
                                          : Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: CandyColors.ink,
                                        width: 2,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${index + 1}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: CandyColors.ink,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    nickname,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: CandyColors.ink,
                                    ),
                                  ),
                                  trailing: Text(
                                    '$score점',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      color: _accent,
                                    ),
                                  ),
                                );
                              },
                            );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
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
                      Icon(Icons.person_add, color: _accent),
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
                                    backgroundColor: _accent.withValues(
                                      alpha: 0.2,
                                    ),
                                    child: Text(
                                      friend.nickname.isNotEmpty
                                          ? friend.nickname[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(color: _accent),
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
                                    AppConfig.gameTypePyramid,
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
                                  backgroundColor: _accent,
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
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _showExitDialog(GameTheme theme) {
    if (_status == PyramidGameStatus.idle ||
        _status == PyramidGameStatus.finished) {
      Navigator.pop(context);
      return;
    }
    if (_status == PyramidGameStatus.searching) {
      _cancelMatch();
      Navigator.pop(context);
      return;
    }
    final isSoloInGame = _isSolo && _roomId != null;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isSoloInGame ? '도전 종료' : '게임 나가기'),
        content: Text(
          isSoloInGame ? '여기까지의 기록을 저장하고 종료하시겠습니까?' : '진행 중인 게임을 포기하시겠습니까?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (isSoloInGame) {
                _endSoloChallenge();
              } else {
                _leaveGame();
              }
            },
            child: Text(
              isSoloInGame ? '종료' : '나가기',
              style: TextStyle(
                color: isSoloInGame ? Colors.orange : Colors.red,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 육각형 카드 페인터 (두꺼운 잉크 아웃라인 + 단단한 그림자)
class _HexagonPainter extends CustomPainter {
  final Color fillColor;
  final Color borderColor;
  final double borderWidth;
  final double shadowOffset;

  _HexagonPainter({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
    required this.shadowOffset,
  });

  Path _hexPath(Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;
    // Flat-top hexagon: 6 vertices
    final r = min(w, h) / 2 * 0.93;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (pi / 180) * (60 * i - 30);
      final x = cx + r * cos(angle);
      final y = cy + r * sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _hexPath(size);

    // 단단한 그림자
    if (shadowOffset > 0) {
      final shadow = path.shift(Offset(0, shadowOffset));
      canvas.drawPath(shadow, Paint()..color = borderColor);
      canvas.drawPath(
        shadow,
        Paint()
          ..color = borderColor
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = borderWidth,
      );
    }

    // Fill
    canvas.drawPath(
      path,
      Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill,
    );

    // 광택
    final shine = Path()
      ..moveTo(size.width * 0.28, size.height * 0.3)
      ..lineTo(size.width * 0.5, size.height * 0.18)
      ..lineTo(size.width * 0.66, size.height * 0.27);
    canvas.drawPath(
      shine,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 3,
    );

    // Border
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = borderWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _HexagonPainter oldDelegate) {
    return fillColor != oldDelegate.fillColor ||
        borderColor != oldDelegate.borderColor ||
        borderWidth != oldDelegate.borderWidth ||
        shadowOffset != oldDelegate.shadowOffset;
  }

  @override
  bool hitTest(Offset position) {
    // Only respond to taps inside the hexagon
    return true;
  }
}

// ───────────────────────── 캔디 카툰 보조 위젯 ─────────────────────────

/// 두꺼운 아웃라인 + 단단한 그림자의 알약형 안내 라벨.
class _CandyPill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;
  final double fontSize;
  const _CandyPill({
    required this.text,
    required this.color,
    required this.icon,
    this.fontSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: CandyColors.ink, width: 2.5),
        boxShadow: const [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: fontSize + 4),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 점수가 바뀔 때마다 통통 튀는 숫자.
class _ScorePop extends StatelessWidget {
  final int score;
  final String suffix;
  final Color color;
  const _ScorePop({required this.score, required this.color, this.suffix = ''});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(score),
      tween: Tween(begin: 1.5, end: 1.0),
      duration: const Duration(milliseconds: 450),
      curve: Curves.elasticOut,
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: Text(
        '$score$suffix',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }
}

/// 정답 경로 등 짧은 라벨 칩.
class _ComboChip extends StatelessWidget {
  final String text;
  final Color color;
  final Color textColor;
  const _ComboChip({
    required this.text,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CandyColors.ink, width: 2),
        boxShadow: const [
          BoxShadow(color: CandyColors.ink, offset: Offset(0, 2)),
        ],
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w900,
          color: textColor,
        ),
      ),
    );
  }
}

/// 선택한 카드 칸. 채워지면 통통 튄다.
class _AnswerSlot extends StatelessWidget {
  final String? label;
  final Color color;
  const _AnswerSlot({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final filled = label != null;
    return TweenAnimationBuilder<double>(
      key: ValueKey('slot-${label ?? ''}'),
      tween: Tween(begin: filled ? 0.6 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 380),
      curve: Curves.elasticOut,
      builder: (_, s, child) => Transform.scale(scale: s, child: child),
      child: Container(
        width: 46,
        height: 46,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? CandyColors.sun : const Color(0xFFF1ECFA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CandyColors.ink, width: 2.5),
          boxShadow: const [
            BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
          ],
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label ?? '?',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w900,
              color: filled ? CandyColors.ink : CandyColors.inkSoft,
            ),
          ),
        ),
      ),
    );
  }
}

/// 되돌리기 버튼.
class _UndoButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  const _UndoButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enabled ? 1.0 : 0.4,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: CandyColors.ink, width: 2.5),
            boxShadow: const [
              BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
            ],
          ),
          child: const Icon(
            Icons.undo_rounded,
            size: 22,
            color: CandyColors.ink,
          ),
        ),
      ),
    );
  }
}
