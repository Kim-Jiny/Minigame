import 'package:flutter/material.dart';
import '../games/common/game_intro_view.dart';
import '../navigation/game_routes.dart';
import '../theme/candy_theme.dart';
import '../utils/game_registry.dart';
import 'cartoon/chunky_button.dart';

/// 로비에서 게임 카드를 눌렀을 때 올라오는 시작 시트.
/// 대전: 바로 시작(자동 매칭) / 옵션 설정(하드코어·인원 등 게임별 인트로).
/// 혼자: 게임 화면으로 바로 진입.
Future<void> showGameLaunchSheet(
  BuildContext context,
  GameMeta game,
  GameEntryMode mode,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => _GameLaunchSheet(game: game, mode: mode),
  );
}

/// 게임 화면으로 이동. [autoStart] 이면 인트로를 건너뛰고 매칭을 바로 시작한다.
void openGame(
  BuildContext context,
  GameMeta game,
  GameEntryMode mode, {
  bool autoStart = false,
}) {
  final entry = GameRoutes.buildModeEntry(game.id, mode);
  if (entry != null) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => entry,
        settings: RouteSettings(
          arguments: GameLaunchArgs(autoStart: autoStart),
        ),
      ),
    );
    return;
  }
  Navigator.pushNamed(
    context,
    game.route,
    arguments: GameLaunchArgs(autoStart: autoStart),
  );
}

class _GameLaunchSheet extends StatelessWidget {
  final GameMeta game;
  final GameEntryMode mode;

  const _GameLaunchSheet({required this.game, required this.mode});

  @override
  Widget build(BuildContext context) {
    final versus = mode == GameEntryMode.versus;
    final nav = Navigator.of(context);
    final parent = nav.context;

    void go({required bool autoStart}) {
      nav.pop();
      openGame(parent, game, mode, autoStart: autoStart);
    }

    return Container(
      decoration: const BoxDecoration(
        color: CandyColors.cream,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(
          top: BorderSide(color: CandyColors.ink, width: CandyTheme.outline),
          left: BorderSide(color: CandyColors.ink, width: CandyTheme.outline),
          right: BorderSide(color: CandyColors.ink, width: CandyTheme.outline),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        20 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: CandyColors.inkSoft.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: game.color,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: CandyColors.ink, width: 3),
              boxShadow: const [
                BoxShadow(color: CandyColors.ink, offset: Offset(0, 4)),
              ],
            ),
            child: Icon(game.icon, color: Colors.white, size: 44),
          ),
          const SizedBox(height: 14),
          Text(
            game.name,
            style: const TextStyle(
              fontFamily: CandyTheme.displayFont,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${game.tagline} · ${game.tempo.duration}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: CandyColors.inkSoft,
            ),
          ),
          const SizedBox(height: 22),
          if (versus) ...[
            ChunkyButton(
              label: '바로 대전!',
              icon: Icons.bolt_rounded,
              color: game.color,
              onPressed: () => go(autoStart: true),
            ),
            const SizedBox(height: 10),
            ChunkyButton(
              label: '옵션 설정 · 친구 초대',
              icon: Icons.tune_rounded,
              color: Colors.white,
              textColor: CandyColors.ink,
              height: 48,
              fontSize: 15,
              onPressed: () => go(autoStart: false),
            ),
          ] else
            ChunkyButton(
              label: versus ? '시작하기' : '혼자 시작',
              icon: Icons.play_arrow_rounded,
              color: game.color,
              onPressed: () => go(autoStart: false),
            ),
        ],
      ),
    );
  }
}
