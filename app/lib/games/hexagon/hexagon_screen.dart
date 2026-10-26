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

enum HexagonGameStatus {
  idle,
  searching,
  matched,
  memorizing,
  playing,
  buzzing,
  roundEnd,
  finished,
}

/// 헥사곤 셀 데이터
class HexCell {
  final int index;
  final int number;
  final String letter;

  HexCell({required this.index, required this.number, required this.letter});
}

/// 찾은 조합
class FoundCombo {
  final List<int> cells;
  final String letters;
  final int playerIndex;

  FoundCombo({
    required this.cells,
    required this.letters,
    required this.playerIndex,
  });
}

class HexagonCellPainter extends CustomPainter {
  final Color fillColor;
  final Color borderColor;
  final double borderWidth;
  final double shadowOffset;

  HexagonCellPainter({
    required this.fillColor,
    required this.borderColor,
    required this.borderWidth,
    this.shadowOffset = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.5, 0)
      ..lineTo(size.width, size.height * 0.25)
      ..lineTo(size.width, size.height * 0.75)
      ..lineTo(size.width * 0.5, size.height)
      ..lineTo(0, size.height * 0.75)
      ..lineTo(0, size.height * 0.25)
      ..close();

    if (shadowOffset > 0) {
      // 만화풍 단단한 그림자
      final shadowPath = path.shift(Offset(0, shadowOffset));
      canvas.drawPath(shadowPath, Paint()..color = borderColor);
      canvas.drawPath(
        shadowPath,
        Paint()
          ..color = borderColor
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = borderWidth,
      );
    }

    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = borderWidth;

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant HexagonCellPainter oldDelegate) {
    return oldDelegate.fillColor != fillColor ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.borderWidth != borderWidth ||
        oldDelegate.shadowOffset != shadowOffset;
  }
}

class HexagonScreen extends StatefulWidget {
  /// 진입 맥락. 혼자하기 → 랭킹 도전/보기만, 둘이하기 → 대전/친구초대만.
  final GameEntryMode entryMode;

  const HexagonScreen({super.key, this.entryMode = GameEntryMode.versus});

  @override
  State<HexagonScreen> createState() => _HexagonScreenState();
}

class _HexagonScreenState extends State<HexagonScreen>
    with TickerProviderStateMixin {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );

  // 게임 상태
  HexagonGameStatus _status = HexagonGameStatus.idle;
  bool _isSolo = false;
  // ignore: unused_field
  bool _isInvitationGame = false;

  // 랭킹
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
  List<HexCell> _board = [];
  List<String> _letters = [];
  int _targetNumber = 0;
  int _currentRound = 0;
  int _totalCombinations = 0;
  int _remainingCombinations = 0;
  List<int> _scores = [0, 0];
  List<FoundCombo> _foundCombinations = [];

  // 선택 상태
  List<int> _selectedCells = [];
  int? _buzzingPlayerIndex;

  // 타이머
  Timer? _memorizeTimer;
  Timer? _idleTimer;
  Timer? _buzzTimer;
  int _memorizeRemaining = 30;
  int _idleRemaining = 60;
  int _buzzRemaining = 10;

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

  // 정답/오답 셀 반짝임 + 컨페티
  List<int> _flashCells = [];
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

      // 초대 게임 체크
      _initFromGameProvider();

      _setupSocketListeners();
      _fetchRankings();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _socketListeners.offAll();
    _rankingsListenable.dispose();
    _memorizeTimer?.cancel();
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
          _status = HexagonGameStatus.matched;
          _opponentProfileSettings = game.opponentProfileSettings;
          _myProfileSettings = game.myProfileSettings;
        });
      }
    } catch (e) {
      debugPrint('🎮 HexagonScreen: GameProvider 초기화 실패: $e');
    }
  }

  void _setupSocketListeners() {
    // 소켓 재연결 감지: 게임 중이었으면 재연결 대기
    _socketListeners.on('connect', (_) {
      final isInGame =
          _status != HexagonGameStatus.idle &&
          _status != HexagonGameStatus.finished &&
          _status != HexagonGameStatus.searching;
      if (isInGame && _roomId != null) {
        if (!_isSolo) {
          _reconnectTimer?.cancel();
          _reconnectTimer = GameReconnectHelper.startReconnectTimeout(
            context: context,
            onEnterWaiting: () => setState(() => _isReconnecting = true),
            onTimeout: () {
              _memorizeTimer?.cancel();
              _idleTimer?.cancel();
              _buzzTimer?.cancel();
              setState(() {
                _isReconnecting = false;
                _status = HexagonGameStatus.finished;
                _opponentLeft = true;
              });
            },
          );
        } else {
          // 솔로 모드: 즉시 종료
          _memorizeTimer?.cancel();
          _idleTimer?.cancel();
          _buzzTimer?.cancel();
          setState(() {
            _status = HexagonGameStatus.finished;
            _opponentLeft = true;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('연결이 끊겨 게임이 종료되었습니다'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      }
    });

    // 재연결 시 게임 상태 복원
    _socketListeners.on('rejoin_game_state', (data) {
      if (data['gameType'] != 'hexagon') return;
      _reconnectTimer?.cancel();

      // 소켓 ID 업데이트 (재연결로 변경됨)
      _myId = _socketService.socket?.id;

      final boardData = data['board'] as List<dynamic>? ?? [];
      final lettersData = data['letters'] as List<dynamic>? ?? [];
      final foundData = data['foundCombinations'] as List<dynamic>? ?? [];
      final scoreData = data['scores'] as List<dynamic>? ?? [0, 0];
      final roundState = data['roundState'] as String? ?? 'playing';

      _board = boardData
          .asMap()
          .entries
          .map(
            (e) => HexCell(
              index: e.key,
              number: (e.value['number'] as num).toInt(),
              letter: e.value['letter'] as String,
            ),
          )
          .toList();
      _letters = lettersData.map((l) => l as String).toList();
      _targetNumber = (data['targetNumber'] as num?)?.toInt() ?? 0;
      _currentRound = (data['round'] as num?)?.toInt() ?? 0;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _totalCombinations = (data['totalCombinations'] as num?)?.toInt() ?? 0;
      _remainingCombinations =
          (data['remainingCombinations'] as num?)?.toInt() ?? 0;
      _isSolo = data['isSolo'] as bool? ?? false;
      _myPlayerIndex = (data['playerIndex'] as num?)?.toInt() ?? 0;
      _roomId = data['roomId'] as String?;
      _selectedCells = [];

      _foundCombinations = foundData
          .map(
            (fc) => FoundCombo(
              cells: (fc['cells'] as List<dynamic>)
                  .map((c) => (c as num).toInt())
                  .toList(),
              letters: fc['letters'] as String,
              playerIndex: (fc['playerIndex'] as num).toInt(),
            ),
          )
          .toList();

      _buzzingPlayerIndex = data['buzzingPlayer'] != null
          ? (data['buzzingPlayer'] as num).toInt()
          : null;

      // 타이머 초기화
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();

      // 라운드 상태에 따라 게임 상태 복원
      switch (roundState) {
        case 'memorizing':
          _startMemorizeTimer();
          _status = HexagonGameStatus.memorizing;
          break;
        case 'playing':
          _startIdleTimer();
          _status = HexagonGameStatus.playing;
          break;
        case 'buzzing':
          if (_buzzingPlayerIndex == _myPlayerIndex) {
            _startBuzzTimer();
          }
          _status = HexagonGameStatus.buzzing;
          break;
        default:
          _startIdleTimer();
          _status = HexagonGameStatus.playing;
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
      setState(() => _status = HexagonGameStatus.searching);
    });

    _socketListeners.on('match_found', (data) {
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
      setState(() => _status = HexagonGameStatus.matched);
    });

    _socketListeners.on('game_start', (data) {
      if (data['players'] != null) {
        final players = data['players'] as List<dynamic>;
        final updatedIndex = players.indexWhere((p) => p['id'] == _myId);
        if (updatedIndex != -1) {
          _myPlayerIndex = updatedIndex;
        }
      }
      setState(() {
        _scores = [0, 0];
        _currentRound = 0;
        _foundCombinations = [];
        _isSolo = data['isSolo'] == true;
        _opponentLeft = false;
        _wonByForfeit = false;
        _rematchWaiting = false;
        _opponentWantsRematch = false;
        _winnerId = null;
        _isDraw = false;
      });
    });

    _socketListeners.on('hexagon_solo_ready', (data) {
      _roomId = data['roomId'] as String?;
    });

    _socketListeners.on('hexagon_round_start', (data) {
      final boardData = data['board'] as List<dynamic>;
      _board = boardData
          .asMap()
          .entries
          .map(
            (e) => HexCell(
              index: e.key,
              number: (e.value['number'] as num).toInt(),
              letter: e.value['letter'] as String,
            ),
          )
          .toList();
      _targetNumber = (data['targetNumber'] as num).toInt();
      _currentRound = (data['round'] as num).toInt();
      _totalCombinations = (data['totalCombinations'] as num).toInt();
      _remainingCombinations = _totalCombinations;
      _foundCombinations = [];
      _selectedCells = [];
      _buzzingPlayerIndex = null;
      _skipAvailable = false;
      _mySkipVoted = false;
      _opponentSkipVoted = false;
      _flashCells = [];
      _confettiTick = 0;
      _lastResultMessage = null;

      final scoreData = data['scores'] as List<dynamic>?;
      if (scoreData != null) {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
      }

      _startMemorizeTimer();
      setState(() => _status = HexagonGameStatus.memorizing);
    });

    _socketListeners.on('hexagon_play_start', (data) {
      final lettersData = data['letters'] as List<dynamic>;
      _letters = lettersData.map((l) => l as String).toList();
      _selectedCells = [];

      _memorizeTimer?.cancel();
      _startIdleTimer();
      setState(() => _status = HexagonGameStatus.playing);
    });

    _socketListeners.on('hexagon_skip_available', (_) {
      setState(() => _skipAvailable = true);
    });

    _socketListeners.on('hexagon_skip_voted', (_) {
      setState(() => _opponentSkipVoted = true);
    });

    _socketListeners.on('hexagon_buzz', (data) {
      _buzzingPlayerIndex = (data['playerIndex'] as num).toInt();
      _idleTimer?.cancel();
      // 버저 누르면 스킵 상태 초기화
      _skipAvailable = false;
      _mySkipVoted = false;
      _opponentSkipVoted = false;

      if (_buzzingPlayerIndex == _myPlayerIndex) {
        _startBuzzTimer();
      }

      setState(() => _status = HexagonGameStatus.buzzing);
    });

    _socketListeners.on('hexagon_answer_result', (data) {
      final correct = data['correct'] as bool;
      final letters = data['letters'] as String? ?? '';
      final playerIdx = (data['playerIndex'] as num).toInt();
      final nickname = data['playerNickname'] as String? ?? '';
      final alreadyFound = data['alreadyFound'] as bool? ?? false;

      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _remainingCombinations = (data['remainingCombinations'] as num).toInt();

      // 찾은 조합 업데이트
      final foundData = data['foundCombinations'] as List<dynamic>?;
      if (foundData != null) {
        _foundCombinations = foundData
            .map(
              (fc) => FoundCombo(
                cells: (fc['cells'] as List<dynamic>)
                    .map((c) => (c as num).toInt())
                    .toList(),
                letters: fc['letters'] as String,
                playerIndex: (fc['playerIndex'] as num).toInt(),
              ),
            )
            .toList();
      }

      final prevSelected = List<int>.from(_selectedCells);
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;
      _selectedCells = [];

      // 정답/오답 셀 반짝임
      List<int> flash = const [];
      if (correct) {
        final claimed = _foundCombinations
            .where((fc) => fc.letters == letters)
            .toList();
        flash = claimed.isNotEmpty ? claimed.last.cells : const [];
      } else if (playerIdx == _myPlayerIndex) {
        flash = prevSelected;
      }
      _triggerFlash(
        flash,
        correct,
        celebrate: correct && playerIdx == _myPlayerIndex,
      );
      if (playerIdx == _myPlayerIndex) {
        if (correct) {
          HapticFeedback.mediumImpact();
        } else {
          HapticFeedback.heavyImpact();
        }
      }

      // 결과 메시지
      if (correct) {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '정답! $letters (+1)'
            : '$nickname: $letters (+1)';
        _lastResultColor = playerIdx == _myPlayerIndex
            ? CandyColors.mintDeep
            : CandyColors.tangerine;
      } else if (alreadyFound) {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '이미 찾은 조합! (-1)'
            : '$nickname: 이미 찾은 조합 (-1)';
        _lastResultColor = const Color(0xFFFF5A5F);
      } else {
        _lastResultMessage = playerIdx == _myPlayerIndex
            ? '오답! (-1)'
            : '$nickname: 오답 (-1)';
        _lastResultColor = const Color(0xFFFF5A5F);
      }
      _resultAnimController.forward(from: 0);

      setState(() => _status = HexagonGameStatus.playing);
      _startIdleTimer();
    });

    _socketListeners.on('hexagon_buzz_timeout', (data) {
      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;
      _selectedCells = [];

      _lastResultMessage = '시간 초과! (-1)';
      _lastResultColor = const Color(0xFFFF5A5F);
      _resultAnimController.forward(from: 0);

      setState(() => _status = HexagonGameStatus.playing);
      _startIdleTimer();
    });

    _socketListeners.on('hexagon_round_end', (data) {
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      _buzzingPlayerIndex = null;

      final scoreData = data['scores'] as List<dynamic>;
      _scores = scoreData.map((s) => (s as num).toInt()).toList();

      final foundData = data['foundCombinations'] as List<dynamic>?;
      if (foundData != null) {
        _foundCombinations = foundData
            .map(
              (fc) => FoundCombo(
                cells: (fc['cells'] as List<dynamic>)
                    .map((c) => (c as num).toInt())
                    .toList(),
                letters: fc['letters'] as String,
                playerIndex: (fc['playerIndex'] as num).toInt(),
              ),
            )
            .toList();
      }

      // 보드 데이터 복원 (라운드 종료 시 숫자 보여주기)
      final boardData = data['board'] as List<dynamic>?;
      if (boardData != null) {
        _board = boardData
            .asMap()
            .entries
            .map(
              (e) => HexCell(
                index: e.key,
                number: (e.value['number'] as num).toInt(),
                letter: e.value['letter'] as String,
              ),
            )
            .toList();
      }

      setState(() => _status = HexagonGameStatus.roundEnd);
    });

    _socketListeners.on('game_end', (data) {
      if (_status == HexagonGameStatus.finished ||
          _status == HexagonGameStatus.idle ||
          _status == HexagonGameStatus.searching) {
        return;
      }
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();

      final scoreData = data['scores'] as List<dynamic>?;
      if (scoreData != null) {
        _scores = scoreData.map((s) => (s as num).toInt()).toList();
      }

      setState(() {
        _status = HexagonGameStatus.finished;
        _winnerId = data['winner'] as String?;
        _isDraw = data['isDraw'] as bool? ?? false;
      });
    });

    _socketListeners.on('opponent_left', (_) {
      if (_status == HexagonGameStatus.idle ||
          _status == HexagonGameStatus.searching) {
        return;
      }
      // 결과 화면에서 상대가 나간 경우: 결과는 유지하고 재대결만 불가 처리
      if (_status == HexagonGameStatus.finished) {
        setState(() {
          _opponentLeft = true;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
        });
        return;
      }
      _memorizeTimer?.cancel();
      _idleTimer?.cancel();
      _buzzTimer?.cancel();
      setState(() {
        _status = HexagonGameStatus.finished;
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

    _socketListeners.on('hexagon_rankings', (data) {
      final rankingsData = data['rankings'] as List<dynamic>? ?? [];
      setState(() {
        _rankings = rankingsData
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
      });
      _rankingsListenable.value = _rankings; // 열려 있는 랭킹 시트 갱신
    });

    _socketListeners.on('error', (data) {
      final message = data['message'] as String? ?? '';
      if (message.contains('room') && message.contains('invalid')) {
        _handleRoomInvalid();
      }
    });
  }

  void _triggerFlash(List<int> cells, bool correct, {bool celebrate = false}) {
    _flashTimer?.cancel();
    if (celebrate) _confettiTick++;
    if (cells.isEmpty) return;
    _flashCells = List<int>.from(cells);
    _flashCorrect = correct;
    _flashTick++;
    _flashTimer = Timer(const Duration(milliseconds: 750), () {
      if (!mounted) return;
      setState(() => _flashCells = []);
    });
  }

  // 타이머들
  void _startMemorizeTimer() {
    _memorizeTimer?.cancel();
    _memorizeRemaining = 30;
    _memorizeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_memorizeRemaining > 0) {
        setState(() => _memorizeRemaining--);
      } else {
        timer.cancel();
      }
    });
  }

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
    _buzzRemaining = 10;
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

  // 액션들
  void _findMatch() {
    _socketService.emit('find_match', {'gameType': AppConfig.gameTypeHexagon});
    setState(() => _status = HexagonGameStatus.searching);
  }

  void _startSolo() {
    _socketService.emit('hexagon_solo_start', {});
    _isSolo = true;
    setState(() => _status = HexagonGameStatus.matched);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeHexagon,
    });
    setState(() => _status = HexagonGameStatus.idle);
  }

  void _buzz() {
    if (_status != HexagonGameStatus.playing || _roomId == null) return;
    HapticFeedback.heavyImpact();
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'buzz'},
    });
  }

  void _submitAnswer() {
    if (_status != HexagonGameStatus.buzzing || _roomId == null) return;
    if (_selectedCells.length != 3) return;
    if (_buzzingPlayerIndex != _myPlayerIndex) return;

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'type': 'answer', 'cellIndices': _selectedCells},
    });
  }

  void _toggleCellSelection(int index) {
    if (_status != HexagonGameStatus.buzzing) return;
    if (_buzzingPlayerIndex != _myPlayerIndex) return;

    setState(() {
      if (_selectedCells.contains(index)) {
        _selectedCells.remove(index);
      } else if (_selectedCells.length < 3) {
        _selectedCells.add(index);
      }
    });
  }

  void _skipRound() {
    if (_roomId == null || _mySkipVoted) return;
    _socketService.emit('hexagon_skip_round', {'roomId': _roomId});
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

  void _endSoloChallenge() {
    if (_roomId == null) return;
    _memorizeTimer?.cancel();
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    _socketService.emit('hexagon_solo_end', {'roomId': _roomId});
    // game_end 이벤트를 기다리지 않고 바로 finished 상태로 전환
    setState(() {
      _status = HexagonGameStatus.finished;
    });
  }

  void _fetchRankings() {
    _socketService.emit('hexagon_get_rankings', {'limit': 20});
  }

  void _handleRoomInvalid() {
    _memorizeTimer?.cancel();
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    setState(() {
      _status = HexagonGameStatus.idle;
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
              _status == HexagonGameStatus.idle ||
              _status == HexagonGameStatus.finished,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              _showExitDialog(theme);
            }
          },
          child: Scaffold(
            backgroundColor: theme.background2,
            appBar: gameAppBar(
              title: '헥사곤',
              backgroundColor: theme.primary,
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
                                  CircularProgressIndicator(
                                    color: theme.primary,
                                  ),
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
      case HexagonGameStatus.idle:
        return _buildIdleView(theme);
      case HexagonGameStatus.searching:
        return _buildSearchingView(theme);
      case HexagonGameStatus.matched:
        return _buildMatchedView(theme);
      case HexagonGameStatus.memorizing:
        return _buildMemorizingView(theme);
      case HexagonGameStatus.playing:
      case HexagonGameStatus.buzzing:
        return _buildPlayingView(theme);
      case HexagonGameStatus.roundEnd:
        return _buildRoundEndView(theme);
      case HexagonGameStatus.finished:
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
                        Icons.hexagon_rounded,
                        size: 58,
                        color: theme.primary,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                '헥사곤',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '숫자를 외우고, 합이 맞는 3칸을 찾아라!',
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
                      _ruleRow('1', '19칸 보드의 숫자를 30초간 암기', theme.primary),
                      _ruleRow('2', '뒤집힌 후 타겟 넘버가 제시', theme.primary),
                      _ruleRow('3', '일직선 3칸의 합 = 타겟을 찾으세요', theme.primary),
                      _ruleRow('4', '버저를 누르고 10초 내 답변', theme.primary),
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
                  color: theme.primary,
                  textColor: theme.textOnPrimary,
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
                  color: theme.primary,
                  textColor: theme.textOnPrimary,
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
    return GameSoloSearchingView(
      accentColor: theme.primary,
      onCancel: _cancelMatch,
    );
  }

  // ==================== MATCHED ====================
  Widget _buildMatchedView(GameTheme theme) {
    return GameSoloMatchedView(
      accentColor: theme.primary,
      opponentNickname: _opponentNickname,
      isSolo: _isSolo,
    );
  }

  // ==================== MEMORIZING ====================
  Widget _buildMemorizingView(GameTheme theme) {
    return Column(
      children: [
        _buildHeader(theme),
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 6,
            children: [
              _CandyPill(
                text: '숫자를 외우세요!',
                color: theme.primary,
                icon: Icons.visibility_rounded,
              ),
              GameTimerBadge(
                seconds: _memorizeRemaining,
                label: '남은 시간',
                accentColor: theme.primary,
                compact: true,
                showLabel: false,
                warningThreshold: 5,
              ),
            ],
          ),
        ),
        // 보드 (숫자 보이기)
        Expanded(child: _buildHexBoard(theme, showNumbers: true)),
      ],
    );
  }

  // ==================== PLAYING / BUZZING ====================
  Widget _buildPlayingView(GameTheme theme) {
    final iAmBuzzing =
        _status == HexagonGameStatus.buzzing &&
        _buzzingPlayerIndex == _myPlayerIndex;
    final otherBuzzing =
        _status == HexagonGameStatus.buzzing &&
        _buzzingPlayerIndex != _myPlayerIndex;

    return Column(
      children: [
        _buildHeader(theme),
        // 타겟 넘버 + 타이머/버저 상태
        Padding(
          padding: const EdgeInsets.only(top: 8),
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
                    color: theme.primary,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: CandyColors.ink, width: 2.5),
                    boxShadow: const [
                      BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
                    ],
                  ),
                  child: Text(
                    '타겟 $_targetNumber',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: theme.textOnPrimary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: _status == HexagonGameStatus.playing
                    ? GameTimerBadge(
                        seconds: _idleRemaining,
                        label: '',
                        accentColor: theme.primary,
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
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '남은 조합 $_remainingCombinations/$_totalCombinations',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: CandyColors.inkSoft,
            ),
          ),
        ),
        // 보드 (알파벳) + 결과 토스트 + 컨페티
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _buildHexBoard(theme, showNumbers: false)),
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
        // 하단 액션
        _buildActionBar(theme, iAmBuzzing, otherBuzzing),
      ],
    );
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
          // 선택된 셀 표시
          if (iAmBuzzing) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < 3; i++)
                  _AnswerSlot(
                    letter:
                        (i < _selectedCells.length &&
                            _selectedCells[i] < _letters.length)
                        ? _letters[_selectedCells[i]]
                        : null,
                    color: theme.primary,
                  ),
                const SizedBox(width: 12),
                Flexible(
                  child: ChunkyButton(
                    label: '제출',
                    icon: Icons.check_rounded,
                    color: CandyColors.mint,
                    height: 48,
                    fontSize: 17,
                    expand: false,
                    onPressed: _selectedCells.length == 3
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
          if (otherBuzzing)
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
    return Column(
      children: [
        _buildHeader(theme),
        const SizedBox(height: 12),
        PopIn(
          child: _CandyPill(
            text: '라운드 $_currentRound 종료',
            color: theme.primary,
            icon: Icons.flag_rounded,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '찾은 조합: ${_foundCombinations.length}/$_totalCombinations',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: CandyColors.inkSoft,
          ),
        ),
        const SizedBox(height: 4),
        // 보드 (숫자 다시 보이기)
        Expanded(child: _buildHexBoard(theme, showNumbers: true)),
        // 찾은 조합 리스트
        if (_foundCombinations.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: CandyColors.ink, width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '찾은 조합',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 84),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: _foundCombinations.map((fc) {
                        final isMe = fc.playerIndex == _myPlayerIndex;
                        return _ComboChip(
                          text: fc.letters,
                          color: isMe ? theme.primary : const Color(0xFFE9E4F5),
                          textColor: isMe
                              ? theme.textOnPrimary
                              : CandyColors.ink,
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: const Text(
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
      hero = GameResultHero(
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

    final myCombos = _foundCombinations
        .where((fc) => fc.playerIndex == _myPlayerIndex)
        .toList();
    final oppCombos = _foundCombinations
        .where((fc) => fc.playerIndex != _myPlayerIndex)
        .toList();

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
                                color: theme.primary,
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
                      accentColor: theme.primary,
                    ),
                  const SizedBox(height: 20),
                  // 찾은 조합 표시
                  if (_foundCombinations.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: CartoonCard(
                        padding: const EdgeInsets.all(14),
                        child: SizedBox(
                          width: double.infinity,
                          child: Column(
                            children: [
                              const Text(
                                '찾은 조합',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                  color: CandyColors.ink,
                                ),
                              ),
                              const SizedBox(height: 8),
                              // 내 조합
                              if (myCombos.isNotEmpty) ...[
                                Text(
                                  _myNickname ?? '나',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: theme.primary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: myCombos
                                      .map(
                                        (fc) => _ComboChip(
                                          text: fc.letters,
                                          color: theme.primary,
                                          textColor: theme.textOnPrimary,
                                        ),
                                      )
                                      .toList(),
                                ),
                              ],
                              // 상대 조합 (2인 모드)
                              if (!_isSolo && oppCombos.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(
                                  _opponentNickname ?? '상대',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: CandyColors.inkSoft,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: oppCombos
                                      .map(
                                        (fc) => _ComboChip(
                                          text: fc.letters,
                                          color: const Color(0xFFE9E4F5),
                                          textColor: CandyColors.ink,
                                        ),
                                      )
                                      .toList(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  GameEndActionPanel(
                    showRematchActions: !_isSolo && !_opponentLeft,
                    opponentLeft: !_isSolo && _opponentLeft,
                    opponentWantsRematch: _opponentWantsRematch,
                    rematchWaiting: _rematchWaiting,
                    primaryColor: theme.primary,
                    primaryForegroundColor: theme.textOnPrimary,
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
    final myScore = _scores.isNotEmpty && _myPlayerIndex < _scores.length
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
          // 나
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
          // 중앙 정보
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: theme.primary,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: CandyColors.ink, width: 2),
                ),
                child: Text(
                  'R$_currentRound',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: theme.textOnPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (_isSolo)
                _ScorePop(score: myScore, suffix: '점', color: theme.primary)
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ScorePop(score: myScore, color: theme.primary),
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
          // 상대
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
    final myFoundCombos = _foundCombinations
        .where((fc) => fc.playerIndex == playerIndex)
        .toList();

    return Column(
      children: [
        GamePlayerProfile(
          name: name,
          avatarUrl: avatarUrl,
          isActive: _buzzingPlayerIndex == playerIndex,
          isMe: isMe,
          profileSettings: profileSettings,
          activeColor: theme.primary,
        ),
        // 찾은 조합 표시
        if (myFoundCombos.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            children: myFoundCombos
                .map(
                  (fc) => Text(
                    fc.letters,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: isMe ? CandyColors.ink : CandyColors.inkSoft,
                    ),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }

  // ==================== HEX BOARD ====================
  Widget _buildHexBoard(GameTheme theme, {required bool showNumbers}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - 24;
        final availableHeight = constraints.maxHeight - 16;
        // 셀 크기 계산: 5열이 들어가야 함
        final cellSize = max(
          8.0,
          min(availableWidth / 6.2, availableHeight / 6.2),
        );
        final hexWidth = cellSize * 0.95;
        final hexHeight = cellSize * 1.1;

        // 행별 셀 수
        const rowSizes = [3, 4, 5, 4, 3];
        const rowStarts = [0, 3, 7, 12, 16];

        return RepaintBoundary(
          child: Center(
            child: SizedBox(
              width: hexWidth * 5 + 24,
              height: hexHeight * 4.35 + 24,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  for (int row = 0; row < 5; row++)
                    for (int col = 0; col < rowSizes[row]; col++)
                      _buildHexCell(
                        theme,
                        rowStarts[row] + col,
                        row,
                        col,
                        rowSizes[row],
                        hexWidth,
                        hexHeight,
                        showNumbers,
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHexCell(
    GameTheme theme,
    int index,
    int row,
    int col,
    int rowSize,
    double hexWidth,
    double hexHeight,
    bool showNumbers,
  ) {
    // 위치 계산
    const maxCols = 5;
    final offset = (maxCols - rowSize) / 2.0;
    final x = (offset + col) * hexWidth * 0.98 + 12;
    final y = row * hexHeight * 0.78 + 12;

    final selIdx = _selectedCells.indexOf(index);
    final isSelected = selIdx >= 0;
    final foundByMe = _foundCombinations.any(
      (fc) => fc.cells.contains(index) && fc.playerIndex == _myPlayerIndex,
    );
    final foundByOpponent = _foundCombinations.any(
      (fc) => fc.cells.contains(index) && fc.playerIndex != _myPlayerIndex,
    );
    final canTap =
        _status == HexagonGameStatus.buzzing &&
        _buzzingPlayerIndex == _myPlayerIndex;
    final flashing = _flashCells.contains(index);

    Color bgColor;
    if (flashing) {
      bgColor = _flashCorrect ? CandyColors.mint : const Color(0xFFFF5A5F);
    } else if (isSelected) {
      bgColor = CandyColors.sun;
    } else if (foundByMe) {
      bgColor = Color.lerp(theme.primary, Colors.white, 0.45)!;
    } else if (foundByOpponent) {
      bgColor = const Color(0xFFE2D9F7);
    } else {
      bgColor = Colors.white;
    }

    String displayText;
    if (showNumbers && index < _board.length) {
      // 암기 단계는 숫자만 노출
      displayText = '${_board[index].number}';
    } else if (!showNumbers && index < _letters.length) {
      displayText = _letters[index];
    } else {
      displayText = '';
    }

    final w = hexWidth * 0.9;
    final h = hexHeight * 0.9;

    Widget tile = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: bgColor),
      duration: const Duration(milliseconds: 150),
      builder: (_, c, _) => CustomPaint(
        painter: HexagonCellPainter(
          fillColor: c ?? bgColor,
          borderColor: CandyColors.ink,
          borderWidth: 2.5,
          shadowOffset: isSelected ? 5 : 3,
        ),
        child: Center(
          child: Text(
            displayText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: showNumbers ? hexWidth * 0.23 : hexWidth * 0.3,
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
      offset: isSelected ? const Offset(0, -0.06) : Offset.zero,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        scale: isSelected ? 1.12 : 1.0,
        child: tile,
      ),
    );

    // 정답 = 통통 튀기 / 오답 = 흔들기
    tile = TweenAnimationBuilder<double>(
      key: ValueKey('hexflash-$index-${flashing ? _flashTick : 0}'),
      tween: Tween(begin: flashing ? 0.0 : 1.0, end: 1.0),
      duration: const Duration(milliseconds: 520),
      builder: (_, t, child) {
        if (!flashing) return child!;
        if (_flashCorrect) {
          return Transform.scale(
            scale:
                0.8 + 0.2 * Curves.elasticOut.transform(t) + 0.12 * sin(t * pi),
            child: child,
          );
        }
        return Transform.translate(
          offset: Offset(sin(t * pi * 6) * 5 * (1 - t), 0),
          child: child,
        );
      },
      child: tile,
    );

    return Positioned(
      left: x,
      top: y,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canTap
            ? () {
                HapticFeedback.selectionClick();
                _toggleCellSelection(index);
              }
            : null,
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: tile),
              if (isSelected)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: CandyColors.ink, width: 2),
                    ),
                    child: Text(
                      '${selIdx + 1}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: theme.textOnPrimary,
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
                      Icon(Icons.leaderboard, color: theme.primary),
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
                                      color: theme.primary,
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
    final shop = context.read<ShopProvider>();
    final theme = GameTheme.fromProfileSettings(shop.profileSettings);

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
                      Icon(Icons.person_add, color: theme.primary),
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
                                    backgroundColor: theme.primary.withValues(
                                      alpha: 0.2,
                                    ),
                                    child: Text(
                                      friend.nickname.isNotEmpty
                                          ? friend.nickname[0].toUpperCase()
                                          : '?',
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
                                    AppConfig.gameTypeHexagon,
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
                                  backgroundColor: theme.primary,
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
    _memorizeTimer?.cancel();
    _idleTimer?.cancel();
    _buzzTimer?.cancel();
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _showExitDialog(GameTheme theme) {
    if (_status == HexagonGameStatus.idle ||
        _status == HexagonGameStatus.finished) {
      Navigator.pop(context);
      return;
    }
    if (_status == HexagonGameStatus.searching) {
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

/// 찾은 조합 칩.
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

/// 정답 입력 칸. 글자가 채워지면 통통 튄다.
class _AnswerSlot extends StatelessWidget {
  final String? letter;
  final Color color;
  const _AnswerSlot({required this.letter, required this.color});

  @override
  Widget build(BuildContext context) {
    final filled = letter != null;
    return TweenAnimationBuilder<double>(
      key: ValueKey('slot-${letter ?? ''}'),
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
        child: Text(
          letter ?? '?',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: filled ? CandyColors.ink : CandyColors.inkSoft,
          ),
        ),
      ),
    );
  }
}
