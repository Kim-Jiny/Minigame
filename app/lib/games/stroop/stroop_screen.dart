import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';
import '../../models/shop_item.dart';
import '../../utils/game_theme.dart';
import '../../widgets/game_player_profile.dart';

enum StroopGameStatus {
  idle,
  searching,
  matched,
  playing,
  waiting,
  finished,
}

class StroopScreen extends StatefulWidget {
  const StroopScreen({super.key});

  @override
  State<StroopScreen> createState() => _StroopScreenState();
}

class _StroopScreenState extends State<StroopScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();

  StroopGameStatus _status = StroopGameStatus.idle;

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
  String _currentWord = '';
  String _currentColor = '';
  int _currentRound = 0;
  List<int> _scores = [0, 0];
  bool _isHardcore = false;
  List<String> _colors = ['red', 'blue', 'green', 'yellow'];

  // 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;

  // 연승 정보
  int _myStreak = 0;
  int _opponentStreak = 0;

  // 하드코어 타이머
  Timer? _hardcoreTimer;
  int _remainingTime = 2;

  // 색상 매핑
  static const Map<String, Color> colorValues = {
    'red': Color(0xFFE74C3C),
    'blue': Color(0xFF3498DB),
    'green': Color(0xFF2ECC71),
    'yellow': Color(0xFFF1C40F),
    'orange': Color(0xFFE67E22),
    'purple': Color(0xFF9B59B6),
  };

  static const Map<String, String> colorNames = {
    'red': '빨강',
    'blue': '파랑',
    'green': '초록',
    'yellow': '노랑',
    'orange': '주황',
    'purple': '보라',
  };

  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.elasticOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      _myId = auth.socketId;
      _myNickname = auth.nickname;
      _myAvatarUrl = auth.avatarUrl;
      _setupSocketListeners();
    });
  }

  @override
  void dispose() {
    _hardcoreTimer?.cancel();
    _animController.dispose();
    _removeSocketListeners();
    super.dispose();
  }

  void _setupSocketListeners() {
    _socketService.on('waiting_for_match', (_) {
      setState(() => _status = StroopGameStatus.searching);
    });

    _socketService.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
      final me = players.firstWhere((p) => p['id'] == _myId, orElse: () => null);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = StroopGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
        _isHardcore = data['isHardcore'] == true;
        // 연승 정보
        _myStreak = me != null ? (me['streak'] ?? 0) : 0;
        _opponentStreak = opponent['streak'] ?? 0;
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
      debugPrint('game_start received: $data');
      if (data['gameType'] == 'stroop') {
        // finished 상태에서 재경기 요청 안 했으면 무시
        if (_status == StroopGameStatus.finished && !_rematchWaiting) {
          debugPrint('game_start ignored: not waiting for rematch');
          return;
        }
        setState(() {
          _isHardcore = data['isHardcore'] ?? false;
          _colors = List<String>.from(data['colors'] ?? ['red', 'blue', 'green', 'yellow']);
          _scores = [0, 0];
          _currentRound = 0;
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
        });
      }
    });

    _socketService.on('stroop_show', (data) {
      debugPrint('🎨 stroop_show received: $data');
      debugPrint('🎨 current status: $_status, mounted: $mounted');

      if (!mounted) return;

      setState(() {
        _currentWord = data['word'];
        _currentColor = data['color'];
        _currentRound = data['round'];
        _scores = List<int>.from(data['scores'] ?? [0, 0]);
        _isHardcore = data['isHardcore'] ?? false;
        if (data['colors'] != null) {
          _colors = List<String>.from(data['colors']);
        }
        _status = StroopGameStatus.playing;
      });

      debugPrint('🎨 status changed to: $_status');

      // 애니메이션 시작
      _animController.reset();
      _animController.forward();

      // 하드코어 모드 타이머 시작
      if (_isHardcore) {
        _startHardcoreTimer();
      }
    });

    _socketService.on('stroop_result', (data) {
      debugPrint('🎨 stroop_result received: $data');

      if (!mounted) return;

      _hardcoreTimer?.cancel();
      final winnerId = data['winnerId'];
      final scores = List<int>.from(data['scores'] ?? [0, 0]);
      final pressedPlayerId = data['pressedPlayerId'];
      final isCorrect = data['correct'] as bool? ?? false;

      setState(() {
        _scores = scores;
        _status = StroopGameStatus.waiting;
      });

      debugPrint('🎨 status changed to waiting, scores: $_scores');

      // 결과 스낵바 표시
      if (mounted) {
        final isMyWin = winnerId == _myId;
        final iMadeAction = pressedPlayerId == _myId;
        final correctAnswer = data['correctAnswer'] as String;

        String message;
        Color bgColor;

        if (isMyWin) {
          if (iMadeAction && isCorrect) {
            // 내가 정답을 맞춰서 점수 획득
            message = '정답! 점수 획득';
            bgColor = Colors.green;
          } else {
            // 상대가 틀려서 내가 점수 획득
            message = '상대 오답! 점수 획득';
            bgColor = Colors.teal;
          }
        } else {
          if (iMadeAction) {
            // 내가 틀림
            message = '오답... 정답: ${colorNames[correctAnswer] ?? correctAnswer}';
            bgColor = Colors.red;
          } else {
            // 상대가 정답을 맞춤
            message = '상대 정답! 정답: ${colorNames[correctAnswer] ?? correctAnswer}';
            bgColor = Colors.orange;
          }
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message, textAlign: TextAlign.center),
            backgroundColor: bgColor,
            duration: const Duration(seconds: 1),
          ),
        );
      }
    });

    _socketService.on('game_end', (data) {
      _hardcoreTimer?.cancel();
      setState(() {
        _status = StroopGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        _scores = List<int>.from(data['scores'] ?? [0, 0]);
      });
    });

    _socketService.on('opponent_left', (_) {
      _hardcoreTimer?.cancel();
      setState(() {
        _status = StroopGameStatus.finished;
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
    _socketService.off('stroop_show');
    _socketService.off('stroop_result');
    _socketService.off('game_end');
    _socketService.off('opponent_left');
    _socketService.off('rematch_waiting');
    _socketService.off('rematch_requested');
    _socketService.off('rematch_cancelled');
  }

  void _startHardcoreTimer() {
    _hardcoreTimer?.cancel();
    _remainingTime = 2;
    _hardcoreTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingTime > 0) {
        setState(() => _remainingTime--);
      } else {
        timer.cancel();
      }
    });
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeStroop,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = StroopGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeStroop,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = StroopGameStatus.idle);
  }

  void _selectColor(String color) {
    if (_status != StroopGameStatus.playing || _roomId == null) return;

    _hardcoreTimer?.cancel();
    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {'selectedColor': color},
    });

    setState(() => _status = StroopGameStatus.waiting);
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
    _hardcoreTimer?.cancel();
    setState(() {
      _status = StroopGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentAvatarUrl = null;
      _opponentUserId = null;
      _currentWord = '';
      _currentColor = '';
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
              title: const Text('스트룹 테스트'),
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

  Widget _buildBody(GameTheme theme) {
    return switch (_status) {
      StroopGameStatus.idle => _buildIdleView(theme),
      StroopGameStatus.searching => _buildSearchingView(theme),
      StroopGameStatus.matched => _buildMatchedView(theme),
      StroopGameStatus.playing => _buildPlayingView(theme),
      StroopGameStatus.waiting => _buildWaitingView(theme),
      StroopGameStatus.finished => _buildFinishedView(theme),
    };
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
                Icons.palette,
                size: 64,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              '스트룹 테스트',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: theme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '글자가 아닌 색깔을 맞추세요!',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '예: "빨강"이 파란색이면 → 파랑 선택',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade500,
              ),
            ),
            const SizedBox(height: 32),
            // 예시 보여주기
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(
                    '빨강',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: colorValues['blue'],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '정답: 파랑 (글자색)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            // 하드코어 모드 토글
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _isHardcore ? Colors.red.shade50 : Colors.grey.shade100,
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
                    activeThumbColor: Colors.red,
                    activeTrackColor: Colors.red.shade200,
                  ),
                ],
              ),
            ),
            if (_isHardcore)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '6색 + 2초 제한!',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.red.shade400,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _findMatch,
              icon: const Icon(Icons.search),
              label: const Text('상대 찾기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isHardcore ? Colors.red : theme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
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
            const SizedBox(height: 16),
            // 연승 정보 표시
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildStreakBadge('나', _myStreak, true),
                const SizedBox(width: 24),
                const Text(
                  'VS',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(width: 24),
                _buildStreakBadge(_opponentNickname ?? '상대', _opponentStreak, false),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '게임이 곧 시작됩니다...',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreakBadge(String name, int streak, bool isMe) {
    final color = isMe ? const Color(0xFF00CEC9) : Colors.orange;
    return Column(
      children: [
        Text(
          name.length > 6 ? '${name.substring(0, 6)}...' : name,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.grey.shade700,
          ),
        ),
        const SizedBox(height: 4),
        if (streak > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_fire_department, size: 16, color: color),
                const SizedBox(width: 4),
                Text(
                  '$streak연승 중',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '연승 없음',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade500,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPlayingView(GameTheme theme) {
    final wordKorean = colorNames[_currentWord] ?? _currentWord;
    final displayColor = colorValues[_currentColor] ?? Colors.black;

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
                  const Color(0xFF00CEC9).withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 하드코어 타이머
                if (_isHardcore)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      color: _remainingTime <= 1 ? Colors.red.shade50 : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _remainingTime <= 1 ? Colors.red : Colors.grey.shade300,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.timer,
                          size: 20,
                          color: _remainingTime <= 1 ? Colors.red : Colors.grey.shade600,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$_remainingTime초',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: _remainingTime <= 1 ? Colors.red : Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                // 색상 단어 표시
                ScaleTransition(
                  scale: _scaleAnimation,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: displayColor.withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Text(
                      wordKorean,
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: displayColor,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '글자의 색깔을 선택하세요!',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 32),
                // 색상 버튼들
                _buildColorButtons(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildColorButtons() {
    final buttonColors = _colors;
    final crossAxisCount = _isHardcore ? 3 : 2;
    final horizontalPadding = _isHardcore ? 16.0 : 32.0;
    final aspectRatio = _isHardcore ? 1.8 : 2.5;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: GridView.count(
        shrinkWrap: true,
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: aspectRatio,
        children: buttonColors.map((color) {
          return _buildColorButton(color, isHardcore: _isHardcore);
        }).toList(),
      ),
    );
  }

  Widget _buildColorButton(String color, {bool isHardcore = false}) {
    final buttonColor = colorValues[color] ?? Colors.grey;
    final buttonName = colorNames[color] ?? color;
    final fontSize = isHardcore ? 14.0 : 18.0;

    return ElevatedButton(
      onPressed: () => _selectColor(color),
      style: ElevatedButton.styleFrom(
        backgroundColor: buttonColor,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(
          horizontal: isHardcore ? 4 : 8,
          vertical: isHardcore ? 4 : 8,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 4,
        shadowColor: buttonColor.withValues(alpha: 0.5),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          buttonName,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingView(GameTheme theme) {
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
                  const Color(0xFF00CEC9).withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00CEC9)),
                  SizedBox(height: 16),
                  Text(
                    '다음 라운드 대기 중...',
                    style: TextStyle(
                      fontSize: 18,
                      color: Color(0xFF00CEC9),
                    ),
                  ),
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
          colors: [Color(0xFFE0F7FA), Color(0xFFB2EBF2)],
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
              extraWidget: _buildScoreWidget(_scores.isNotEmpty ? _scores[_myPlayerIndex] : 0, true),
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
                    'Round $_currentRound',
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
              extraWidget: _buildScoreWidget(_scores.length > 1 ? _scores[1 - _myPlayerIndex] : 0, false),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreWidget(int score, bool isMe) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFF00CEC9) : Colors.grey,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$score',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildFinishedView(GameTheme theme) {
    final isWinner = _winnerId == _myId;

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
            // 점수 표시
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildScoreCard('나', _scores.isNotEmpty ? _scores[_myPlayerIndex] : 0, true),
                const SizedBox(width: 32),
                const Text(
                  ':',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 32),
                _buildScoreCard(
                  _opponentNickname ?? '상대',
                  _scores.length > 1 ? _scores[1 - _myPlayerIndex] : 0,
                  false,
                ),
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
                      style: TextStyle(
                        color: Colors.green.shade700,
                        fontWeight: FontWeight.w500,
                      ),
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
                      foregroundColor: const Color(0xFF00CEC9),
                      side: const BorderSide(color: Color(0xFF00CEC9)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  ),
                if (!_isInvitationGame &&
                    !_opponentLeft &&
                    _opponentUserId != null &&
                    !context.read<FriendProvider>().isFriend(_opponentUserId!))
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

  Widget _buildScoreCard(String name, int score, bool isMe) {
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
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
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
    if (_status == StroopGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

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
        content: const Text('정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.'),
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
    );
  }
}
