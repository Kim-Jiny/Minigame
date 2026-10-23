import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/game_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/shop_provider.dart';
import '../../providers/ranked_provider.dart';
import '../../services/socket_service.dart';
import '../../config/app_config.dart';
import '../../theme/candy_theme.dart';
import '../../utils/game_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/confetti_burst.dart';
import '../../widgets/cartoon/duo_mascot.dart';
import '../../widgets/cartoon/pop_in.dart';
import '../common/game_hardcore_toggle.dart';
import '../common/game_intro_view.dart';
import '../common/game_scaffold.dart';
import '../common/game_result_summary.dart';
import '../common/game_timer_badge.dart';
import '../common/match_status_views.dart';
import '../common/game_duel_header.dart';
import '../common/game_result_action_buttons.dart';
import '../common/game_session_helper.dart';

// ---------------------------------------------------------------------------
// 보드 게임 공용 캔디 위젯 (틱택토 · 무한 틱택토 · 오목 · 다른 게임 초대 시트가 함께 쓴다)
// ---------------------------------------------------------------------------

/// 0..1 을 왕복하는 가벼운 펄스. 자기 자신만 다시 그린다.
class CandyPulse extends StatefulWidget {
  final Duration duration;
  final Widget? child;
  final Widget Function(BuildContext context, double t, Widget? child) builder;

  const CandyPulse({
    super.key,
    this.duration = const Duration(milliseconds: 700),
    this.child,
    required this.builder,
  });

  @override
  State<CandyPulse> createState() => _CandyPulseState();
}

class _CandyPulseState extends State<CandyPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) =>
          widget.builder(context, Curves.easeInOut.transform(_c.value), child),
    );
  }
}

/// "내 차례 / 상대 차례" 알약. 바뀔 때마다 통통 튄다.
class CandyTurnChip extends StatelessWidget {
  final bool isMine;
  final Color accent;

  const CandyTurnChip({super.key, required this.isMine, required this.accent});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(isMine),
      tween: Tween(begin: 0.7, end: 1.0),
      duration: const Duration(milliseconds: 450),
      curve: Curves.elasticOut,
      builder: (_, scale, child) => Transform.scale(scale: scale, child: child),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: isMine ? accent : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: CandyColors.ink, width: 2.5),
          boxShadow: const [
            BoxShadow(color: CandyColors.ink, offset: Offset(0, 2)),
          ],
        ),
        child: Text(
          isMine ? '내 차례' : '상대 차례',
          maxLines: 1,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: isMine ? Colors.white : CandyColors.inkSoft,
          ),
        ),
      ),
    );
  }
}

/// 상단 안내 띠(시간 초과 알림 등).
class CandyNoticeBar extends StatelessWidget {
  final String text;

  const CandyNoticeBar({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: PopIn(
        key: ValueKey(text),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: CandyColors.sun,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: CandyColors.ink, width: 2.5),
            boxShadow: const [
              BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
            ],
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CandyColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

/// 결과 화면 레이아웃: 위는 보드, 아래는 결과 패널.
/// 패널이 화면의 55% 를 넘으면 패널만 스크롤되어 오버플로우가 나지 않는다.
class BoardFinishedLayout extends StatelessWidget {
  final Widget board;
  final Widget panel;

  const BoardFinishedLayout({
    super.key,
    required this.board,
    required this.panel,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxPanel = c.maxHeight.isFinite ? c.maxHeight * 0.55 : 400.0;
        return Column(
          children: [
            Expanded(child: board),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxPanel),
              child: SingleChildScrollView(
                clipBehavior: Clip.none,
                child: panel,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 보드 게임 결과 패널 (마스코트 + 결과 + 재경기 대기 + 액션 버튼).
class BoardResultPanel extends StatelessWidget {
  final bool isDraw;
  final bool isWinner;
  final Color accent;
  final bool showRematchWaiting;
  final String? opponentNickname;
  final Widget actions;

  const BoardResultPanel({
    super.key,
    required this.isDraw,
    required this.isWinner,
    required this.accent,
    required this.showRematchWaiting,
    required this.opponentNickname,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final won = isWinner && !isDraw;
    final title = isDraw ? '무승부!' : (isWinner ? '승리!' : '아쉬워요...');
    final mood = isDraw
        ? MascotMood.wink
        : (isWinner ? MascotMood.cheer : MascotMood.sad);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (won)
            const Positioned(
              left: -100,
              right: -100,
              top: -300,
              height: 460,
              child: ConfettiBurst(),
            ),
          CartoonCard(
            radius: 28,
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    PopIn(
                      child: DuoMascot(
                        size: 72,
                        color: won
                            ? accent
                            : (isDraw ? CandyColors.sun : CandyColors.sky),
                        mood: mood,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                            color: won ? accent : CandyColors.ink,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (showRematchWaiting)
                  GameResultStatusPill(
                    icon: Icons.hourglass_top_rounded,
                    text: '${opponentNickname ?? '상대'}님이 대기 중...',
                    color: const Color(0xFF15803D),
                  ),
                actions,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 온라인 친구 초대 바텀시트 (카툰 스타일). 모든 보드/대전 게임에서 공용으로 쓴다.
void showGameInviteSheet({
  required BuildContext context,
  required Color accent,
  required String gameType,
  bool isHardcore = false,
  bool refresh = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  if (refresh) {
    context.read<FriendProvider>().getFriends();
  }

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Consumer<FriendProvider>(
      builder: (_, friendProvider, _) {
        final onlineFriends = friendProvider.friends
            .where((f) => f.isOnline)
            .toList();

        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.6,
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
                margin: const EdgeInsets.only(top: 10),
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: CandyColors.ink.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                child: Row(
                  children: [
                    Icon(Icons.person_add_rounded, color: accent),
                    const SizedBox(width: 10),
                    const Text(
                      '친구 초대',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: CandyColors.ink,
                      ),
                    ),
                    const Spacer(),
                    if (isHardcore)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: CandyColors.tangerine,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: CandyColors.ink, width: 2),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.local_fire_department_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                            SizedBox(width: 4),
                            Text(
                              '하드코어',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 3, thickness: 3, color: CandyColors.ink),
              Flexible(
                child: onlineFriends.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(36),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.person_off_rounded,
                                size: 48,
                                color: CandyColors.inkSoft,
                              ),
                              const SizedBox(height: 14),
                              const Text(
                                '온라인 친구가 없습니다',
                                style: TextStyle(
                                  color: CandyColors.inkSoft,
                                  fontWeight: FontWeight.w800,
                                ),
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
                                Container(
                                  width: 40,
                                  height: 40,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.25),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: CandyColors.ink,
                                      width: 2.5,
                                    ),
                                  ),
                                  child: Text(
                                    friend.nickname.isNotEmpty
                                        ? friend.nickname[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                      color: CandyColors.ink,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 13,
                                    height: 13,
                                    decoration: BoxDecoration(
                                      color: CandyColors.mint,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: CandyColors.ink,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            title: Text(
                              friend.nickname,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                color: CandyColors.ink,
                              ),
                            ),
                            subtitle:
                                friend.memo != null && friend.memo!.isNotEmpty
                                ? Text(
                                    friend.memo!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: CandyColors.inkSoft,
                                      fontSize: 12,
                                    ),
                                  )
                                : null,
                            trailing: SizedBox(
                              width: 76,
                              child: ChunkyButton(
                                label: '초대',
                                height: 38,
                                radius: 14,
                                fontSize: 14,
                                color: isHardcore
                                    ? CandyColors.tangerine
                                    : accent,
                                onPressed: () {
                                  friendProvider.inviteToGame(
                                    friend.id,
                                    gameType,
                                    isHardcore: isHardcore,
                                  );
                                  Navigator.pop(sheetContext);
                                  messenger.clearSnackBars();
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '${friend.nickname}님에게 초대를 보냈습니다!',
                                      ),
                                      backgroundColor: CandyColors.mintDeep,
                                    ),
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
              ),
              SizedBox(height: MediaQuery.of(sheetContext).padding.bottom + 16),
            ],
          ),
        );
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// 3x3 보드
// ---------------------------------------------------------------------------

const List<List<int>> _tttLines = [
  [0, 1, 2],
  [3, 4, 5],
  [6, 7, 8],
  [0, 3, 6],
  [1, 4, 7],
  [2, 5, 8],
  [0, 4, 8],
  [2, 4, 6],
];

/// 3개가 한 줄로 이어졌으면 그 칸 인덱스를, 아니면 null.
List<int>? tttWinLine(List<int?> board) {
  if (board.length < 9) return null;
  for (final line in _tttLines) {
    final v = board[line[0]];
    if (v != null && board[line[1]] == v && board[line[2]] == v) return line;
  }
  return null;
}

/// 틱택토 / 무한 틱택토 공용 보드.
class TttBoard extends StatelessWidget {
  final List<int?> board;
  final bool canPlay;
  final ValueChanged<int> onCellTap;
  final Color accent;
  final Color p0Color;
  final Color p1Color;

  /// 무한모드에서 다음에 사라질 칸.
  final int? fadingIndex;

  const TttBoard({
    super.key,
    required this.board,
    required this.canPlay,
    required this.onCellTap,
    required this.accent,
    required this.p0Color,
    required this.p1Color,
    this.fadingIndex,
  });

  @override
  Widget build(BuildContext context) {
    final winLine = tttWinLine(board);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 320.0;
        final h = c.maxHeight.isFinite ? c.maxHeight : 320.0;
        final side = math.max(90.0, math.min(math.min(w, h) - 32, 420.0));
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  accent.withValues(alpha: 0.22),
                  Colors.white,
                ),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: CandyColors.ink, width: 3),
                boxShadow: const [
                  BoxShadow(color: CandyColors.ink, offset: Offset(0, 6)),
                ],
              ),
              child: Column(
                children: [
                  for (var r = 0; r < 3; r++)
                    Expanded(
                      child: Row(
                        children: [
                          for (var col = 0; col < 3; col++)
                            Expanded(child: _buildCell(r * 3 + col, winLine)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCell(int index, List<int>? winLine) {
    final value = index < board.length ? board[index] : null;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: _TttCell(
        value: value,
        playable: canPlay && value == null,
        isWin: winLine != null && winLine.contains(index),
        isFading: fadingIndex == index,
        accent: accent,
        p0Color: p0Color,
        p1Color: p1Color,
        onTap: () => onCellTap(index),
      ),
    );
  }
}

class _TttCell extends StatefulWidget {
  final int? value;
  final bool playable;
  final bool isWin;
  final bool isFading;
  final Color accent;
  final Color p0Color;
  final Color p1Color;
  final VoidCallback onTap;

  const _TttCell({
    required this.value,
    required this.playable,
    required this.isWin,
    required this.isFading,
    required this.accent,
    required this.p0Color,
    required this.p1Color,
    required this.onTap,
  });

  @override
  State<_TttCell> createState() => _TttCellState();
}

class _TttCellState extends State<_TttCell> {
  bool _down = false;

  void _setDown(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final lift = _down ? 3.0 : 0.0;
    final Color face;
    if (widget.isWin) {
      face = CandyColors.sun;
    } else if (widget.isFading) {
      face = CandyColors.creamDeep;
    } else if (widget.playable) {
      face = Color.alphaBlend(
        widget.accent.withValues(alpha: 0.10),
        Colors.white,
      );
    } else {
      face = Colors.white;
    }

    Widget? mark;
    if (widget.value != null) {
      final player = widget.value!;
      final color = player == 0 ? widget.p0Color : widget.p1Color;
      Widget m = TttMark(
        key: ValueKey('mark-$player'),
        player: player,
        color: color,
      );
      if (widget.isWin) {
        m = CandyPulse(
          duration: const Duration(milliseconds: 520),
          builder: (_, t, child) =>
              Transform.scale(scale: 1 + 0.14 * t, child: child),
          child: m,
        );
      } else if (widget.isFading) {
        m = CandyPulse(
          duration: const Duration(milliseconds: 600),
          builder: (_, t, child) =>
              Opacity(opacity: 0.45 + 0.45 * t, child: child),
          child: m,
        );
      }
      mark = m;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.playable ? (_) => _setDown(true) : null,
      onTapCancel: widget.playable ? () => _setDown(false) : null,
      onTapUp: widget.playable ? (_) => _setDown(false) : null,
      onTap: widget.playable
          ? () {
              HapticFeedback.lightImpact();
              widget.onTap();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, lift, 0),
        decoration: BoxDecoration(
          color: face,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: CandyColors.ink, width: 3),
          boxShadow: [
            BoxShadow(color: CandyColors.ink, offset: Offset(0, 4 - lift)),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (mark != null) Center(child: mark),
            if (widget.isFading)
              Positioned(
                top: 3,
                right: 3,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: CandyColors.sun,
                    shape: BoxShape.circle,
                    border: Border.all(color: CandyColors.ink, width: 2),
                  ),
                  child: const Icon(
                    Icons.timer_rounded,
                    size: 12,
                    color: CandyColors.ink,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 보드 위의 말. 0 = 동그라미, 1 = 세모. 놓일 때 위에서 "톡" 떨어지며 튕긴다.
class TttMark extends StatelessWidget {
  final int player;
  final Color color;

  const TttMark({super.key, required this.player, required this.color});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      builder: (_, t, child) => Opacity(
        opacity: math.min(1.0, t * 4).clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - t) * -16),
          child: Transform.scale(scale: t.clamp(0.0, 1.4), child: child),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final s = math.max(
            16.0,
            math.min(c.maxWidth.isFinite ? c.maxWidth : 60, 70) * 0.62,
          );
          return SizedBox(
            width: s,
            height: s,
            child: player == 0
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: CandyColors.ink, width: 3.5),
                    ),
                    child: Align(
                      alignment: const Alignment(-0.4, -0.45),
                      child: Container(
                        width: s * 0.22,
                        height: s * 0.12,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  )
                : CustomPaint(painter: _TrianglePainter(color)),
          );
        },
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color fill;
  _TrianglePainter(this.fill);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w / 2, h * 0.07)
      ..lineTo(w * 0.95, h * 0.9)
      ..lineTo(w * 0.05, h * 0.9)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = CandyColors.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawLine(
      Offset(w * 0.4, h * 0.45),
      Offset(w * 0.5, h * 0.3),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.6)
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.fill != fill;
}

/// 무한모드 남은 말 개수 점 3개.
class TttPieceDots extends StatelessWidget {
  final int count;
  final Color color;

  const TttPieceDots({super.key, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        final on = index < count;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.elasticOut,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: on ? 15 : 12,
          height: on ? 15 : 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? color : Colors.white,
            border: Border.all(
              color: on ? CandyColors.ink : CandyColors.inkSoft,
              width: 2,
            ),
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// 틱택토 화면
// ---------------------------------------------------------------------------

class TicTacToeScreen extends StatefulWidget {
  final bool isRanked;

  const TicTacToeScreen({super.key, this.isRanked = false});

  @override
  State<TicTacToeScreen> createState() => _TicTacToeScreenState();
}

class _TicTacToeScreenState extends State<TicTacToeScreen> {
  bool _hasScheduledPop = false; // 중복 pop 방지
  bool _wasMyTurn = false; // 내 턴 전환 감지(햅틱)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final auth = context.read<AuthProvider>();
      final game = context.read<GameProvider>();

      // 초대 게임으로 이미 playing 상태면 리셋하지 않음
      if (!widget.isRanked && game.status != GameStatus.playing) {
        game.reset();
      }

      if (auth.socketId != null) {
        game.initialize(auth.socketId!);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<GameProvider, ShopProvider>(
      builder: (context, game, shop, child) {
        final theme = GameTheme.fromProfileSettings(shop.profileSettings);

        // 내 차례가 되면 살짝 진동
        final myTurnNow = game.status == GameStatus.playing && game.isMyTurn;
        if (myTurnNow && !_wasMyTurn) {
          HapticFeedback.selectionClick();
        }
        _wasMyTurn = myTurnNow;

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _showExitDialog(context);
          },
          child: Scaffold(
            appBar: gameAppBar(
              title: '틱택토',
              backgroundColor: theme.primary,
              onBack: () => _showExitDialog(context),
            ),
            body: switch (game.status) {
              GameStatus.idle =>
                widget.isRanked
                    ? _buildRankedWaitingView(theme)
                    : _buildIdleView(game, theme),
              GameStatus.searching =>
                widget.isRanked
                    ? _buildRankedWaitingView(theme)
                    : _buildSearchingView(game, theme),
              GameStatus.matched =>
                widget.isRanked
                    ? _buildRankedWaitingView(theme)
                    : _buildMatchedView(game, theme),
              GameStatus.playing => _buildPlayingView(game, theme),
              GameStatus.finished => _buildFinishedView(game, theme),
            },
          ),
        );
      },
    );
  }

  String _getMatchButtonLabel(GameProvider game) {
    if (game.isInfiniteMode && game.isHardcore) {
      return '무한 하드코어 상대 찾기';
    } else if (game.isInfiniteMode) {
      return '무한모드 상대 찾기';
    } else if (game.isHardcore) {
      return '하드코어 상대 찾기';
    }
    return '상대 찾기';
  }

  void _showFriendInviteDialog(BuildContext context, GameProvider game) {
    showGameInviteSheet(
      context: context,
      accent: game.isHardcore ? CandyColors.tangerine : CandyColors.pink,
      gameType: game.isInfiniteMode
          ? AppConfig.gameTypeInfiniteTicTacToe
          : AppConfig.gameTypeTicTacToe,
      isHardcore: game.isHardcore,
    );
  }

  Widget _buildPieceCounter(String label, int count, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: CandyColors.inkSoft,
          ),
        ),
        const SizedBox(height: 4),
        TttPieceDots(count: count, color: color),
      ],
    );
  }

  Widget _buildIdleView(GameProvider game, GameTheme theme) {
    final accent = game.isHardcore
        ? CandyColors.tangerine
        : (game.isInfiniteMode ? CandyColors.grape : theme.primary);
    return GameIntroView(
      backgroundGradient: theme.backgroundGradient,
      accentColor: accent,
      icon: game.isInfiniteMode ? Icons.all_inclusive : Icons.grid_3x3,
      title: game.isInfiniteMode ? '무한 틱택토' : '틱택토',
      descriptions: [
        game.isInfiniteMode
            ? '각 플레이어는 최대 3개의 말만!\n가장 오래된 말이 사라집니다'
            : '3개를 연속으로 놓으면 승리!',
      ],
      findMatchLabel: _getMatchButtonLabel(game),
      onFindMatch: () => game.findMatch(AppConfig.gameTypeTicTacToe),
      onInviteFriend: () => _showFriendInviteDialog(context, game),
      extra: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CartoonCard(
            radius: 20,
            shadow: 3,
            color: game.isInfiniteMode
                ? CandyColors.grape.withValues(alpha: 0.18)
                : Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.all_inclusive,
                  color: game.isInfiniteMode
                      ? CandyColors.grapeDeep
                      : CandyColors.inkSoft,
                ),
                const SizedBox(width: 8),
                Text(
                  '무한모드',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: game.isInfiniteMode
                        ? CandyColors.grapeDeep
                        : CandyColors.inkSoft,
                  ),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: game.isInfiniteMode,
                  onChanged: (value) {
                    HapticFeedback.selectionClick();
                    game.setInfiniteMode(value);
                  },
                  activeThumbColor: CandyColors.grape,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GameHardcoreToggle(
            value: game.isHardcore,
            onChanged: (v) => game.setHardcoreMode(v),
            durationLabel: '(10초)',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchingView(GameProvider game, GameTheme theme) {
    return GameSearchingView(
      theme: theme,
      isHardcore: game.isHardcore,
      onCancel: () => game.cancelMatch(AppConfig.gameTypeTicTacToe),
    );
  }

  Widget _buildMatchedView(GameProvider game, GameTheme theme) {
    return GameMatchedView(
      theme: theme,
      opponentNickname: game.opponentNickname,
    );
  }

  Color _p1Color(GameTheme theme) => CandyColors.sky;

  Widget _buildBoardFor(GameProvider game, GameTheme theme, bool canPlay) {
    return TttBoard(
      board: game.board,
      canPlay: canPlay,
      accent: theme.primary,
      p0Color: theme.primary,
      p1Color: _p1Color(theme),
      fadingIndex: game.isInfiniteGame && game.status == GameStatus.playing
          ? game.nextToDisappear
          : null,
      onCellTap: (index) {
        if (index < game.board.length &&
            game.board[index] == null &&
            game.isMyTurn) {
          game.makeMove(index);
        }
      },
    );
  }

  Widget _buildPlayingView(GameProvider game, GameTheme theme) {
    final auth = context.read<AuthProvider>();
    final myIdx = game.myPlayerIndex ?? 0;
    final myColor = myIdx == 0 ? theme.primary : _p1Color(theme);
    final oppColor = myIdx == 0 ? _p1Color(theme) : theme.primary;

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // 프로필 & 턴 표시
            GameDuelHeader(
              backgroundColors: [
                (theme.cardGradient.colors.first),
                (theme.cardGradient.colors.last),
              ],
              accentColor: theme.primary,
              centerLabel: '',
              myName: auth.nickname ?? '나',
              opponentName: game.opponentNickname ?? '상대',
              myAvatarUrl: auth.avatarUrl,
              opponentAvatarUrl: game.opponentAvatarUrl,
              myActive: game.isMyTurn,
              opponentActive: !game.isMyTurn,
              myProfileSettings:
                  game.myProfileSettings ??
                  context.read<ShopProvider>().profileSettings,
              opponentProfileSettings: game.opponentProfileSettings,
              centerWidget: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTimer(game, theme),
                    const SizedBox(height: 6),
                    CandyTurnChip(isMine: game.isMyTurn, accent: theme.primary),
                  ],
                ),
              ),
            ),

            // 타임아웃 알림
            if (game.timeoutPlayerNickname != null)
              CandyNoticeBar(
                text: '${game.timeoutPlayerNickname}님 시간 초과! 랜덤 위치에 배치됨',
              ),

            // 무한모드: 말 개수 표시
            if (game.isInfiniteGame)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildPieceCounter('내 말', game.myPieceCount, myColor),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: CandyColors.grape,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: CandyColors.ink, width: 2.5),
                      ),
                      child: const Text(
                        '무한모드',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    _buildPieceCounter(
                      '상대 말',
                      game.opponentPieceCount,
                      oppColor,
                    ),
                  ],
                ),
              ),

            // 게임 보드
            Expanded(child: _buildBoardFor(game, theme, game.isMyTurn)),
          ],
        ),
      ),
    );
  }

  Widget _buildTimer(GameProvider game, GameTheme theme) {
    return GameTimerBadge(
      seconds: game.remainingTime,
      label: '',
      accentColor: theme.primary,
      compact: true,
      showLabel: false,
      warningThreshold: 5,
    );
  }

  Widget _buildRankedWaitingView(GameTheme theme) {
    return GameRankedPreparingView(theme: theme);
  }

  Widget _buildFinishedView(GameProvider game, GameTheme theme) {
    // 랭크전에서는 결과만 표시하고 자동으로 돌아가기
    if (widget.isRanked) {
      GameSessionHelper.scheduleRankedAutoReturn(
        context: context,
        mounted: mounted,
        hasScheduledPop: _hasScheduledPop,
        markScheduledPop: () => _hasScheduledPop = true,
      );
      final isWinner = game.isWinner;
      final isDraw = game.isDraw;
      return GameRankedResultView(
        backgroundGradient: theme.backgroundGradient,
        accentColor: theme.primary,
        isWinner: isWinner,
        isDraw: isDraw,
      );
    }

    return Container(
      decoration: BoxDecoration(gradient: theme.backgroundGradient),
      child: SafeArea(
        top: false,
        child: BoardFinishedLayout(
          // 최종 보드 상태 (승리 라인 강조)
          board: _buildBoardFor(game, theme, false),
          panel: BoardResultPanel(
            isDraw: game.isDraw,
            isWinner: game.isWinner,
            accent: theme.primary,
            showRematchWaiting: game.opponentWantsRematch && !game.opponentLeft,
            opponentNickname: game.opponentNickname,
            actions: GameResultActionButtons(
              accentColor: theme.primary,
              opponentLeft: game.opponentLeft,
              rematchWaiting: game.rematchWaiting,
              isInvitationGame: game.isInvitationGame,
              canSendFriendRequest:
                  !game.isInvitationGame &&
                  !game.opponentLeft &&
                  game.opponentUserId != null &&
                  !context.read<FriendProvider>().isFriend(
                    game.opponentUserId!,
                  ),
              onRematchPressed: game.rematchWaiting
                  ? () => game.cancelRematch()
                  : () => game.requestRematch(),
              onSearchAgainPressed: () {
                game.leaveGame();
                game.findMatch(AppConfig.gameTypeTicTacToe);
              },
              onLobbyPressed: () {
                GameSessionHelper.leaveGameAndReturnToLobby(
                  context: context,
                  socketService: SocketService(),
                  roomId: game.roomId,
                  isRanked: widget.isRanked,
                  resetState: game.reset,
                );
              },
              onFriendRequestPressed: game.opponentUserId == null
                  ? null
                  : () {
                      context.read<FriendProvider>().sendFriendRequestByUserId(
                        game.opponentUserId!,
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '${game.opponentNickname}님에게 친구 요청을 보냈습니다',
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
            ),
          ),
        ),
      ),
    );
  }

  void _showExitDialog(BuildContext context) {
    final game = context.read<GameProvider>();

    // 일반 게임에서 idle 상태면 바로 나가기
    if (!widget.isRanked && game.status == GameStatus.idle) {
      Navigator.pop(context);
      return;
    }

    // 랭크전 대기 중이면 경고 없이 나가기 (하지만 leave_room은 보내야 함)
    final isRankedWaiting =
        widget.isRanked &&
        (game.status == GameStatus.idle ||
            game.status == GameStatus.searching ||
            game.status == GameStatus.matched);

    if (isRankedWaiting) {
      // 랭크전에서는 RankedProvider의 roomId를 사용해야 함
      String? roomId = game.roomId;
      if (widget.isRanked && roomId == null) {
        try {
          roomId = context.read<RankedProvider>().roomId;
        } catch (_) {}
      }
      if (roomId != null) {
        SocketService().emit('leave_room', {'roomId': roomId});
      }
      game.reset();
      Navigator.pop(context);
      return;
    }

    // 일반 게임에서 searching 상태면 매칭 취소하고 나가기
    if (game.status == GameStatus.searching) {
      final gameType = game.isInfiniteMode
          ? AppConfig.gameTypeInfiniteTicTacToe
          : AppConfig.gameTypeTicTacToe;
      game.cancelMatch(gameType);
      Navigator.pop(context);
      return;
    }

    final shop = context.read<ShopProvider>();
    final theme = GameTheme.fromProfileSettings(shop.profileSettings);

    // matched 또는 playing 상태면 확인 다이얼로그
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.exit_to_app, color: theme.primary),
            const SizedBox(width: 8),
            const Text('게임 나가기'),
          ],
        ),
        content: Text(
          game.status == GameStatus.matched
              ? '매칭이 완료되었습니다. 나가시겠습니까?'
              : '정말 게임을 나가시겠습니까?\n진행 중인 게임은 패배 처리됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              game.leaveGame();
              Navigator.pop(dialogContext);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
  }
}
