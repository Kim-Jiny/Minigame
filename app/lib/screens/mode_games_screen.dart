import 'package:flutter/material.dart';
import '../navigation/game_routes.dart';
import '../utils/game_registry.dart';
import 'ranked_screen.dart';

/// 모드(혼자/둘이)별로 즐길 수 있는 게임 목록 화면.
/// 호흡(빠른→전략) 섹션으로 묶어 시선 흐름을 만든다.
class ModeGamesScreen extends StatelessWidget {
  final PlayMode mode;

  const ModeGamesScreen({super.key, required this.mode});

  @override
  Widget build(BuildContext context) {
    final games = GameRegistry.forMode(mode);
    final sections = _groupByTempo(games);
    final entryMode = GameEntryMode.fromPlayMode(mode);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7FB),
      body: SafeArea(
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
                    if (mode == PlayMode.duo)
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
                          itemBuilder: (_, i) =>
                              _GameRow(game: section.games[i], entryMode: entryMode),
                        ),
                      ),
                    ],
                    if (mode == PlayMode.solo)
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
    );
  }

  Widget _buildHeader(BuildContext context, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                color: const Color(0xFF1F2430),
              ),
              const Spacer(),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: mode.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(mode.icon, color: mode.color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mode.title,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1F2430),
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$count개 게임 · ${mode.tagline}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// 모드별 랭크전 강조 카드.
  /// 둘이하기 → 2인전 랭크전(ELO Bo3, RankedScreen)으로 이동.
  /// 혼자하기 → 1인전 랭크전 안내(게임을 골라 기록에 도전). 솔로에서만 노출.
  /// 2인전 랭크전 강조 카드 (둘이하기에서만 노출).
  Widget _buildRankedHighlight(BuildContext context) {
    const color = Color(0xFFEA580C);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RankedScreen()),
          ),
          child: Ink(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.28),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.emoji_events_rounded, color: Colors.white),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '랭크전 · 2인전',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Bo3 · ELO 기반 매칭',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_rounded, color: Colors.white),
              ],
            ),
          ),
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
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1F2430),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            tempo.duration,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade400,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSoloHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF0EA5A6).withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded,
                color: const Color(0xFF0EA5A6).withValues(alpha: 0.9), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '연습 모드는 계속 늘어나요. 더 많은 게임을 혼자서도 즐길 수 있게 준비 중이에요.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey.shade700,
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
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _open(context),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEDEDF2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: game.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(game.icon, color: game.color, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      game.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2430),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      game.tagline,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.grey.shade300,
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
