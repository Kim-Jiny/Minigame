import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';

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
  const ReactionScreen({super.key});

  @override
  State<ReactionScreen> createState() => _ReactionScreenState();
}

class _ReactionScreenState extends State<ReactionScreen> {
  final SocketService _socketService = SocketService();

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
    });
  }

  @override
  void dispose() {
    _removeSocketListeners();
    super.dispose();
  }

  void _setupSocketListeners() {
    _socketService.on('waiting_for_match', (_) {
      setState(() => _status = ReactionGameStatus.searching);
    });

    _socketService.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = ReactionGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
      });
    });

    _socketService.on('game_start', (data) {
      if (data['gameType'] == 'reaction') {
        setState(() {
          _status = ReactionGameStatus.playing;
          _currentRound = 0;
          _scores = [0, 0];
          _roundState = RoundState.waiting;
          // 재경기 상태 리셋
          _rematchWaiting = false;
          _opponentWantsRematch = false;
          _opponentLeft = false;
          _isDraw = false;
          _winnerId = null;
        });
      }
    });

    _socketService.on('reaction_round_ready', (data) {
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

    _socketService.on('reaction_round_go', (data) {
      setState(() {
        _roundState = RoundState.go;
      });
    });

    _socketService.on('reaction_round_result', (data) {
      setState(() {
        _roundState = RoundState.result;
        _lastRoundFalseStart = data['falseStart'];
        _lastRoundWinnerNickname = data['winnerNickname'];
        _lastReactionTime = data['reactionTime'];
        _pressedPlayerNickname = data['pressedPlayerNickname'];
        _scores = List<int>.from(data['scores']);
      });
    });

    _socketService.on('reaction_round_timeout', (data) {
      setState(() {
        _roundState = RoundState.result;
        _lastRoundFalseStart = false;
        _lastRoundWinnerNickname = null; // 무승부
        _lastReactionTime = null;
      });
    });

    _socketService.on('game_end', (data) {
      setState(() {
        _status = ReactionGameStatus.finished;
        _winnerId = data['winner'];
        _isDraw = data['isDraw'] ?? false;
        if (data['scores'] != null) {
          _scores = List<int>.from(data['scores']);
        }
      });
    });

    _socketService.on('opponent_left', (_) {
      setState(() {
        _status = ReactionGameStatus.finished;
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
    _socketService.off('reaction_round_ready');
    _socketService.off('reaction_round_go');
    _socketService.off('reaction_round_result');
    _socketService.off('reaction_round_timeout');
    _socketService.off('game_end');
    _socketService.off('opponent_left');
    _socketService.off('rematch_waiting');
    _socketService.off('rematch_requested');
    _socketService.off('rematch_cancelled');
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
    if (_roomId != null) {
      _socketService.emit('leave_room', {'roomId': _roomId});
    }
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _showExitDialog();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('반응속도'),
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
      ReactionGameStatus.idle => _buildIdleView(),
      ReactionGameStatus.searching => _buildSearchingView(),
      ReactionGameStatus.matched => _buildMatchedView(),
      ReactionGameStatus.playing => _buildPlayingView(),
      ReactionGameStatus.finished => _buildFinishedView(),
    };
  }

  Widget _buildIdleView() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFE74C3C).withValues(alpha: 0.1),
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
                color: const Color(0xFFE74C3C).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.flash_on,
                size: 80,
                color: Color(0xFFE74C3C),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '반응속도',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Color(0xFFE74C3C),
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
            ElevatedButton.icon(
              onPressed: _findMatch,
              icon: const Icon(Icons.search),
              label: const Text('상대 찾기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE74C3C),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
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
            const Color(0xFFE74C3C).withValues(alpha: 0.1),
            Colors.white,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                color: Color(0xFFE74C3C),
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
                foregroundColor: const Color(0xFFE74C3C),
                side: const BorderSide(color: Color(0xFFE74C3C)),
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

  Widget _buildMatchedView() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFE74C3C).withValues(alpha: 0.1),
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
                color: Color(0xFFFADADA),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.sports_esports,
                size: 64,
                color: Color(0xFFE74C3C),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '$_opponentNickname님과 매칭!',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFFE74C3C),
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
                child: _buildPlayerProfile(
                  _myNickname ?? '나',
                  _myAvatarUrl,
                  _scores[_myPlayerIndex],
                  true,
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

  Widget _buildPlayerProfile(String name, String? avatarUrl, int score, bool isMe) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isMe ? const Color(0xFFE74C3C) : Colors.grey.shade400,
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: (isMe ? const Color(0xFFE74C3C) : Colors.grey).withValues(alpha: 0.3),
                blurRadius: 8,
              ),
            ],
          ),
          child: CircleAvatar(
            radius: 28,
            backgroundColor: isMe ? const Color(0xFFFADADA) : Colors.grey.shade200,
            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
            child: avatarUrl == null
                ? Icon(
                    Icons.person,
                    size: 28,
                    color: isMe ? const Color(0xFFE74C3C) : Colors.grey,
                  )
                : null,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          name,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: isMe ? const Color(0xFFE74C3C) : Colors.grey.shade700,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFFE74C3C) : Colors.grey,
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
    if (_status == ReactionGameStatus.idle) {
      Navigator.pop(context);
      return;
    }

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
              backgroundColor: const Color(0xFFE74C3C),
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
