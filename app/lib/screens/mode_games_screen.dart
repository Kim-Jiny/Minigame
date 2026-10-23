import 'package:flutter/material.dart';
import '../navigation/game_routes.dart';
import '../utils/game_registry.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';
import 'ranked_screen.dart';

/// 진입 맥락(혼자 연습 / 온라인 대결)별로 즐길 수 있는 게임 목록 화면.
/// 호흡(빠른→전략) 섹션으로 묶어 시선 흐름을 만든다.
class ModeGamesScreen extends StatelessWidget {
  final GameEntryMode entry;

  const ModeGamesScreen({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final games = GameRegistry.forEntry(entry);
    final sections = _groupByTempo(games);
    final entryMode = entry;

    return Scaffold(
      body: FloatingBackground(
       child: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final contentMaxWidth =
                constraints.maxWidth >= 720 ? 640.0 : double.infinity;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: contentMaxWidth),
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(child: _buildHeader(context, games.length)),
                    if (entry == GameEntryMode.versus)
                      SliverToBoxAdapter(child: _buildRankedHighlight(context)),
                    for (final section in sections) ...[
                      SliverToBoxAdapter(
                        child: _buildSectionLabel(section.tempo),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        sliver: SliverList.separated(
                          itemCount: section.games.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 12),
                          itemBuilder: (_, i) => PopIn(
                            delay: Duration(milliseconds: 60 * i),
                            child: _GameRow(game: section.games[i], entryMode: entryMode),
                          ),
                        ),
                      ),
                    ],
                    if (entry == GameEntryMode.solo)
                      SliverToBoxAdapter(child: _buildSoloHint()),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 24 + MediaQuery.of(context).padding.bottom,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
       ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int count) {
    final color = entry == GameEntryMode.versus ? CandyColors.pink : CandyColors.mint;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: ChunkyButton(
              color: Colors.white,
              height: 42,
              radius: 14,
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Icon(Icons.arrow_back_rounded, color: CandyColors.ink),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: CartoonCard(
              color: color,
              radius: 22,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(entry.icon, color: Colors.white, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: -0.5,
                          ),
                        ),
                        Text(
                          '$count개 게임 · ${entry.tagline}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
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

  /// 모드별 랭크전 강조 카드.
  /// 둘이하기 → 2인전 랭크전(ELO Bo3, RankedScreen)으로 이동.
  /// 혼자하기 → 1인전 랭크전 안내(게임을 골라 기록에 도전). 솔로에서만 노출.
  /// 2인전 랭크전 강조 카드 (둘이하기에서만 노출).
  Widget _buildRankedHighlight(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: CartoonCard(
        color: CandyColors.tangerine,
        radius: 22,
        padding: const EdgeInsets.all(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const RankedScreen()),
        ),
        child: const Row(
          children: [
            Icon(Icons.emoji_events_rounded, color: Colors.white, size: 36),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '랭크전 · 2인전',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Bo3 · ELO 기반 매칭',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_rounded, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(GameTempo tempo) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 10),
      child: Row(
        children: [
          Text(
            tempo.label,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: CandyColors.sun,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: CandyColors.ink, width: 2),
            ),
            child: Text(
              tempo.duration,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                color: CandyColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSoloHint() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: CartoonCard(
        color: CandyColors.creamDeep,
        radius: 18,
        shadow: 3,
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: CandyColors.tangerine, size: 22),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '연습 모드는 계속 늘어나요. 더 많은 게임을 혼자서도 즐길 수 있게 준비 중이에요.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  fontWeight: FontWeight.w700,
                  color: CandyColors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<_TempoSection> _groupByTempo(List<GameMeta> games) {
    final sections = <_TempoSection>[];
    for (final tempo in GameTempo.values) {
      final inTempo = games.where((g) => g.tempo == tempo).toList();
      if (inTempo.isNotEmpty) {
        sections.add(_TempoSection(tempo, inTempo));
      }
    }
    return sections;
  }
}

class _TempoSection {
  final GameTempo tempo;
  final List<GameMeta> games;
  const _TempoSection(this.tempo, this.games);
}

class _GameRow extends StatelessWidget {
  final GameMeta game;
  final GameEntryMode entryMode;

  const _GameRow({required this.game, required this.entryMode});

  void _open(BuildContext context) {
    // 헥사곤·수식피라미드는 진입 맥락(솔로/대전)에 따라 버튼이 달라진다.
    final entry = GameRoutes.buildModeEntry(game.id, entryMode);
    if (entry != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => entry));
    } else {
      Navigator.pushNamed(context, game.route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CartoonCard(
      radius: 20,
      padding: const EdgeInsets.all(12),
      shadow: 4,
      onTap: () => _open(context),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: game.color,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: CandyColors.ink, width: 2.5),
            ),
            child: Icon(game.icon, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  game.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  game.tagline,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: CandyColors.inkSoft,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(Icons.play_circle_fill_rounded, color: CandyColors.pink, size: 30),
        ],
      ),
    );
  }
}
