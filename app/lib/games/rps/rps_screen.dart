import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';

enum RpsGameStatus {
  idle,
  searching,
  matched,
  playing,
  finished,
}

enum RpsChoice {
  rock,
  paper,
  scissors,
}

class RpsScreen extends StatefulWidget {
  const RpsScreen({super.key});

  @override
  State<RpsScreen> createState() => _RpsScreenState();
}

class _RpsScreenState extends State<RpsScreen> with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();

  RpsGameStatus _status = RpsGameStatus.idle;

  String? _roomId;
  String? _myId;
  String? _myNickname;
  String? _myAvatarUrl;
  String? _opponentNickname;
  String? _opponentAvatarUrl;
  int? _opponentUserId;
  bool _isInvitationGame = false;
  final bool _isHardcore = false;

  int _currentRound = 0;
  List<int> _scores = [0, 0]; // [player0, player1]
  int _myPlayerIndex = 0;

  // 현재 라운드 상태
  RpsChoice? _myChoice;
  bool _opponentChosen = false;
  bool _waitingForResult = false;

  // 라운드 결과
  String? _lastPlayer0Choice;
  String? _lastPlayer1Choice;
  int? _lastWinnerIndex;
  bool _lastIsDraw = false;

  // 게임 결과
  String? _winnerId;
  bool _isDraw = false;
  bool _opponentLeft = false;
  bool _rematchWaiting = false;
  bool _opponentWantsRematch = false;

  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  // 타이머
  Timer? _countdownTimer;
  int _remainingSeconds = 10;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
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
    _countdownTimer?.cancel();
    _animController.dispose();
    _removeSocketListeners();
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

  void _setupSocketListeners() {
    _socketService.on('waiting_for_match', (_) {
      setState(() => _status = RpsGameStatus.searching);
    });

    _socketService.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = RpsGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
      });
    });

    _socketService.on('game_start', (data) {
      if (data['gameType'] == 'rps') {
        setState(() {
          _status = RpsGameStatus.playing;
          _currentRound = 0;
          _scores = [0, 0];
          _myChoice = null;
          _opponentChosen = false;
          _waitingForResult = false;
          // 재경기 상태 리셋
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
        });
      }
    });

    _socketService.on('rps_round_start', (data) {
      final timeLimit = data['timeLimit'] as int? ?? 10000;
      setState(() {
        // rps_round_start가 오면 확실히 게임 중인 상태
        _status = RpsGameStatus.playing;
        _currentRound = data['round'];
        _scores = List<int>.from(data['scores']);
        _myChoice = null;
        _opponentChosen = false;
        _waitingForResult = false;
        _lastPlayer0Choice = null;
        _lastPlayer1Choice = null;
        _lastWinnerIndex = null;
        _lastIsDraw = false;
      });
      _startCountdown(timeLimit ~/ 1000);
    });

    _socketService.on('rps_player_chosen', (data) {
      if (data['playerId'] != _myId) {
        setState(() => _opponentChosen = true);
      }
    });

    _socketService.on('rps_round_result', (data) {
      _stopCountdown();
      setState(() {
        _lastPlayer0Choice = data['player0Choice'];
        _lastPlayer1Choice = data['player1Choice'];
        _lastWinnerIndex = data['winnerIndex'];
        _lastIsDraw = data['isDraw'] ?? false;
        _scores = List<int>.from(data['scores']);
        _waitingForResult = false;
      });
    });

    _socketService.on('rps_round_timeout', (data) {
      _stopCountdown();
      setState(() {
        _waitingForResult = false;
      });
    });

    _socketService.on('game_end', (data) {
      _stopCountdown();
      setState(() {
        _status = RpsGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        if (data['scores'] != null) {
          _scores = List<int>.from(data['scores']);
        }
      });
    });

    _socketService.on('opponent_left', (_) {
      setState(() {
        _status = RpsGameStatus.finished;
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
    _socketService.off('rps_round_start');
    _socketService.off('rps_player_chosen');
    _socketService.off('rps_round_result');
    _socketService.off('rps_round_timeout');
    _socketService.off('game_end');
    _socketService.off('opponent_left');
    _socketService.off('rematch_waiting');
    _socketService.off('rematch_requested');
    _socketService.off('rematch_cancelled');
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeRps,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = RpsGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeRps,
      'isHardcore': _isHardcore,
    });
    setState(() => _status = RpsGameStatus.idle);
  }

  void _makeChoice(RpsChoice choice) {
    if (_myChoice != null || _roomId == null) return;

    setState(() {
      _myChoice = choice;
      _waitingForResult = _opponentChosen;
    });

    _socketService.emit('game_action', {
      'roomId': _roomId,
      'action': {
        'choice': choice.name,
      },
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
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
    _reset();
  }

  void _reset() {
    setState(() {
      _status = RpsGameStatus.idle;
      _roomId = null;
      _opponentNickname = null;
      _opponentUserId = null;
      _currentRound = 0;
      _scores = [0, 0];
      _myChoice = null;
      _opponentChosen = false;
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitDialog();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('가위바위보'),
          backgroundColor: const Color(0xFF9B59B6),
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _showExitDialog,
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    return switch (_status) {
      RpsGameStatus.idle => _buildIdleView(),
      RpsGameStatus.searching => _buildSearchingView(),
      RpsGameStatus.matched => _buildMatchedView(),
      RpsGameStatus.playing => _buildPlayingView(),
      RpsGameStatus.finished => _buildFinishedView(),
    };
  }

  Widget _buildIdleView() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF9B59B6).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 게임 아이콘
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF9B59B6).withValues(alpha: 0.3),
                    blurRadius: 20,
                  ),
                ],
              ),
              child: const Text(
                '✊✌️✋',
                style: TextStyle(fontSize: 48),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              '가위바위보',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9B59B6),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '3판 2선승',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: _findMatch,
              icon: const Icon(Icons.search),
              label: const Text('상대 찾기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9B59B6),
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

  Widget _buildSearchingView() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF9B59B6).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              color: Color(0xFF9B59B6),
            ),
            const SizedBox(height: 24),
            const Text(
              '상대를 찾는 중...',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9B59B6),
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
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF9B59B6).withValues(alpha: 0.1),
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
                color: Color(0xFFE8DAEF),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.sports_esports,
                size: 64,
                color: Color(0xFF9B59B6),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9B59B6),
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

  Widget _buildPlayingView() {
    final bool showResult = _lastPlayer0Choice != null && _lastPlayer1Choice != null;

    return Column(
      children: [
        // 프로필 & 점수판
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFF5EEF8), Color(0xFFEDE7F6)],
            ),
          ),
          child: Row(
            children: [
              // 내 프로필
              Expanded(
                child: _buildPlayerProfile(
                  _myNickname ?? '나',
                  _myAvatarUrl,
                  _scores[_myPlayerIndex],
                  true,
                ),
              ),
              // VS & 라운드
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF9B59B6),
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
                        color: Color(0xFF9B59B6),
                      ),
                    ),
                  ],
                ),
              ),
              // 상대 프로필
              Expanded(
                child: _buildPlayerProfile(
                  _opponentNickname ?? '상대',
                  _opponentAvatarUrl,
                  _scores[1 - _myPlayerIndex],
                  false,
                ),
              ),
            ],
          ),
        ),

        // 게임 영역
        Expanded(
          child: showResult ? _buildResultView() : _buildChoiceView(),
        ),
      ],
    );
  }

  Widget _buildPlayerProfile(String name, String? avatarUrl, int score, bool isMe) {
    return Column(
      children: [
        // 아바타
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isMe ? const Color(0xFF9B59B6) : Colors.grey.shade400,
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: (isMe ? const Color(0xFF9B59B6) : Colors.grey).withValues(alpha: 0.3),
                blurRadius: 8,
              ),
            ],
          ),
          child: CircleAvatar(
            radius: 28,
            backgroundColor: isMe ? const Color(0xFFE8DAEF) : Colors.grey.shade200,
            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
            child: avatarUrl == null
                ? Icon(
                    Icons.person,
                    size: 28,
                    color: isMe ? const Color(0xFF9B59B6) : Colors.grey,
                  )
                : null,
          ),
        ),
        const SizedBox(height: 6),
        // 이름
        Text(
          name,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: isMe ? const Color(0xFF9B59B6) : Colors.grey.shade700,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        // 점수
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFF9B59B6) : Colors.grey,
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
      ],
    );
  }

  Widget _buildChoiceView() {
    final bool isLowTime = _remainingSeconds <= 3;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 타이머
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: isLowTime ? Colors.red.shade50 : const Color(0xFFF5EEF8),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isLowTime ? Colors.red : const Color(0xFF9B59B6),
              width: 2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.timer,
                color: isLowTime ? Colors.red : const Color(0xFF9B59B6),
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                '$_remainingSeconds초',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: isLowTime ? Colors.red : const Color(0xFF9B59B6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // 상대 상태
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: _opponentChosen ? Colors.green.shade50 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _opponentChosen ? Colors.green : Colors.grey.shade300,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _opponentChosen ? Icons.check_circle : Icons.hourglass_empty,
                color: _opponentChosen ? Colors.green : Colors.grey,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                _opponentChosen ? '$_opponentNickname 선택 완료!' : '$_opponentNickname 선택 중...',
                style: TextStyle(
                  color: _opponentChosen ? Colors.green.shade700 : Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),

        // 내 선택 상태 또는 선택 버튼
        if (_myChoice != null)
          Column(
            children: [
              Text(
                _getChoiceEmoji(_myChoice!),
                style: const TextStyle(fontSize: 80),
              ),
              const SizedBox(height: 16),
              Text(
                '${_getChoiceName(_myChoice!)} 선택!',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF9B59B6),
                ),
              ),
              if (_waitingForResult || !_opponentChosen) ...[
                const SizedBox(height: 16),
                Text(
                  '상대방 대기 중...',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ],
            ],
          )
        else
          Column(
            children: [
              const Text(
                '선택하세요!',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF9B59B6),
                ),
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildChoiceButton(RpsChoice.rock),
                  _buildChoiceButton(RpsChoice.scissors),
                  _buildChoiceButton(RpsChoice.paper),
                ],
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildChoiceButton(RpsChoice choice) {
    return GestureDetector(
      onTapDown: (_) => _animController.forward(),
      onTapUp: (_) {
        _animController.reverse();
        _makeChoice(choice);
      },
      onTapCancel: () => _animController.reverse(),
      child: AnimatedBuilder(
        animation: _scaleAnim,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnim.value,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF9B59B6).withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  _getChoiceEmoji(choice),
                  style: const TextStyle(fontSize: 48),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildResultView() {
    final myChoice = _myPlayerIndex == 0 ? _lastPlayer0Choice : _lastPlayer1Choice;
    final opponentChoice = _myPlayerIndex == 0 ? _lastPlayer1Choice : _lastPlayer0Choice;
    final isMyWin = _lastWinnerIndex == _myPlayerIndex;
    final isOpponentWin = _lastWinnerIndex == (1 - _myPlayerIndex);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 결과 텍스트
        Text(
          _lastIsDraw ? '무승부!' : (isMyWin ? '이겼다!' : '졌다...'),
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: _lastIsDraw
                ? Colors.orange
                : (isMyWin ? Colors.green : Colors.red),
          ),
        ),
        const SizedBox(height: 32),

        // 선택 비교
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 내 선택
            Column(
              children: [
                Text(
                  _getChoiceEmojiFromString(myChoice),
                  style: const TextStyle(fontSize: 64),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isMyWin ? Colors.green : (_lastIsDraw ? Colors.orange : Colors.red),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '나',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 40),
            const Text(
              'VS',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(width: 40),
            // 상대 선택
            Column(
              children: [
                Text(
                  _getChoiceEmojiFromString(opponentChoice),
                  style: const TextStyle(fontSize: 64),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: isOpponentWin ? Colors.green : (_lastIsDraw ? Colors.orange : Colors.red),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _opponentNickname ?? '상대',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
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
    );
  }

  String _getChoiceEmoji(RpsChoice choice) {
    return switch (choice) {
      RpsChoice.rock => '✊',
      RpsChoice.scissors => '✌️',
      RpsChoice.paper => '✋',
    };
  }

  String _getChoiceEmojiFromString(String? choice) {
    return switch (choice) {
      'rock' => '✊',
      'scissors' => '✌️',
      'paper' => '✋',
      _ => '❓',
    };
  }

  String _getChoiceName(RpsChoice choice) {
    return switch (choice) {
      RpsChoice.rock => '바위',
      RpsChoice.scissors => '가위',
      RpsChoice.paper => '보',
    };
  }

  Widget _buildScoreCard(String name, int score, bool isMe) {
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

  Widget _buildFinishedView() {
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
                      backgroundColor: _rematchWaiting ? Colors.orange : const Color(0xFF9B59B6),
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
                      foregroundColor: const Color(0xFF9B59B6),
                      side: const BorderSide(color: Color(0xFF9B59B6)),
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
    if (_status == RpsGameStatus.idle) {
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
