import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';

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
  const SequenceScreen({super.key});

  @override
  State<SequenceScreen> createState() => _SequenceScreenState();
}

class _SequenceScreenState extends State<SequenceScreen>
    with SingleTickerProviderStateMixin {
  final SocketService _socketService = SocketService();

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

  int _gridSize = 9; // 3x3
  List<int> _sequence = [];
  int _currentLevel = 0;
  int _showingIndex = -1; // 현재 보여주고 있는 시퀀스 인덱스
  int _showDelay = 600;

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
    });
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _feedbackTimer?.cancel();
    _animController.dispose();
    _removeSocketListeners();
    super.dispose();
  }

  void _setupSocketListeners() {
    _socketService.on('waiting_for_match', (_) {
      setState(() => _status = SequenceGameStatus.searching);
    });

    _socketService.on('match_found', (data) {
      final players = data['players'] as List;
      final opponent = players.firstWhere((p) => p['id'] != _myId);
      _myPlayerIndex = players.indexWhere((p) => p['id'] == _myId);

      setState(() {
        _status = SequenceGameStatus.matched;
        _roomId = data['roomId'];
        _opponentNickname = opponent['nickname'];
        _opponentAvatarUrl = opponent['avatarUrl'];
        _opponentUserId = opponent['userId'];
        _isInvitationGame = data['isInvitation'] == true;
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
        _myInputs = [];
      });
      _showSequence();
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
    _showTimer?.cancel();
    _showTimer = Timer.periodic(Duration(milliseconds: _showDelay), (timer) {
      if (index < _sequence.length) {
        setState(() => _showingIndex = index);
        index++;
      } else {
        timer.cancel();
        // 시퀀스 다 보여준 후 입력 모드
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            setState(() {
              _showingIndex = -1;
              _status = SequenceGameStatus.playing;
            });
          }
        });
      }
    });
  }

  void _findMatch() {
    _socketService.emit('find_match', {
      'gameType': AppConfig.gameTypeSequence,
      'isHardcore': false,
    });
    setState(() => _status = SequenceGameStatus.searching);
  }

  void _cancelMatch() {
    _socketService.emit('cancel_match', {
      'gameType': AppConfig.gameTypeSequence,
      'isHardcore': false,
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
      setState(() {
        _myFailed = true;
        _myMaxLevel = _currentLevel - 1;
        _status = SequenceGameStatus.waiting;
      });
    } else if (_myInputs.length == _sequence.length) {
      // 현재 레벨 완료
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
          title: const Text('순서 기억하기'),
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
      SequenceGameStatus.idle => _buildIdleView(),
      SequenceGameStatus.searching => _buildSearchingView(),
      SequenceGameStatus.matched => _buildMatchedView(),
      SequenceGameStatus.showing => _buildShowingView(),
      SequenceGameStatus.playing => _buildPlayingView(),
      SequenceGameStatus.waiting => _buildWaitingView(),
      SequenceGameStatus.finished => _buildFinishedView(),
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
              child: const Icon(
                Icons.psychology,
                size: 64,
                color: Color(0xFF9B59B6),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              '순서 기억하기',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9B59B6),
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
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: _findMatch,
              icon: const Icon(Icons.search),
              label: const Text('상대 찾기'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9B59B6),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
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
                color: Color(0xFFF3E5F5),
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

  Widget _buildShowingView() {
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
                  const Color(0xFF9B59B6).withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  '순서를 기억하세요!',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF9B59B6),
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
                  const Color(0xFF9B59B6).withValues(alpha: 0.1),
                  Colors.white,
                ],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '순서대로 터치! (${_myInputs.length}/${_sequence.length})',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF9B59B6),
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
            child: _buildPlayerProfile(
              _myNickname ?? '나',
              _myAvatarUrl,
              _myMaxLevel,
              _myFailed,
              true,
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
            child: _buildPlayerProfile(
              _opponentNickname ?? '상대',
              _opponentAvatarUrl,
              _opponentMaxLevel,
              _opponentFailed,
              false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerProfile(
      String name, String? avatarUrl, int level, bool failed, bool isMe) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: failed
                  ? Colors.red
                  : (isMe ? const Color(0xFF9B59B6) : Colors.grey.shade400),
              width: 3,
            ),
          ),
          child: CircleAvatar(
            radius: 24,
            backgroundColor:
                isMe ? const Color(0xFFF3E5F5) : Colors.grey.shade200,
            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
            child: avatarUrl == null
                ? Icon(
                    Icons.person,
                    size: 24,
                    color: isMe ? const Color(0xFF9B59B6) : Colors.grey,
                  )
                : null,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          name,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: isMe ? const Color(0xFF9B59B6) : Colors.grey.shade700,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        if (failed)
          Container(
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
          ),
      ],
    );
  }

  Widget _buildGrid({required bool enabled}) {
    final gridDimension = _gridSize == 9 ? 3 : 2;
    final cellSize = MediaQuery.of(context).size.width / (gridDimension + 1);

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
    if (_status == SequenceGameStatus.idle) {
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
