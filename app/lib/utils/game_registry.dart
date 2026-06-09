import 'package:flutter/material.dart';
import 'game_catalog.dart';

/// 플레이 모드 — 메인 랜딩의 3개 진입점과 게임 필터링에 사용
enum PlayMode {
  solo(
    title: '혼자하기',
    tagline: '연습하며 기록에 도전',
    icon: Icons.self_improvement_rounded,
    color: Color(0xFF0EA5A6),
  ),
  duo(
    title: '둘이하기',
    tagline: '실시간 1:1 대결',
    icon: Icons.people_alt_rounded,
    color: Color(0xFF6C5CE7),
  ),
  multi(
    title: '여럿이하기',
    tagline: '곧 만나요',
    icon: Icons.groups_rounded,
    color: Color(0xFF94A3B8),
  );

  const PlayMode({
    required this.title,
    required this.tagline,
    required this.icon,
    required this.color,
  });

  final String title;
  final String tagline;
  final IconData icon;
  final Color color;
}

/// 게임 진입 맥락 — 혼자하기(solo)로 들어오면 랭킹 도전/보기,
/// 둘이하기(versus)로 들어오면 대전/친구 초대 버튼만 노출한다.
enum GameEntryMode {
  solo,
  versus;

  static GameEntryMode fromPlayMode(PlayMode mode) =>
      mode == PlayMode.solo ? GameEntryMode.solo : GameEntryMode.versus;
}

/// 게임의 진행 호흡(소요 시간대) — 시선 흐름을 위한 묶음 기준
enum GameTempo {
  blitz('빠른 게임', '1~3분'),
  word('단어 게임', '3~5분'),
  brain('두뇌 게임', '5~15분'),
  strategy('전략 게임', '10~20분');

  const GameTempo(this.label, this.duration);
  final String label;
  final String duration;
}

/// 게임 한 종의 표시 메타데이터 + 지원 모드.
/// 화면별로 흩어져 있던 아이콘/색/부제를 한 곳으로 통합한 단일 출처.
class GameMeta {
  final String id;
  final String tagline;
  final IconData icon;
  final Color color;
  final GameTempo tempo;
  final Set<PlayMode> modes;

  const GameMeta({
    required this.id,
    required this.tagline,
    required this.icon,
    required this.color,
    required this.tempo,
    required this.modes,
  });

  String get name => GameCatalog.nameFor(id);
  String get route => GameCatalog.routeFor(id);
  bool supports(PlayMode mode) => modes.contains(mode);
}

/// 전체 게임 메타데이터의 단일 출처.
class GameRegistry {
  const GameRegistry._();

  // 현재 서버에 솔로(연습) 이벤트가 구현된 게임. 추후 확장 시 modes에 solo 추가.
  static const List<GameMeta> all = [
    GameMeta(
      id: 'reaction',
      tagline: '터치 반응속도 대결',
      icon: Icons.flash_on_rounded,
      color: Color(0xFFE17055),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'rps',
      tagline: '가위바위보 3판 2선',
      icon: Icons.front_hand_rounded,
      color: Color(0xFF9B59B6),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'speedtap',
      tagline: '누가 더 빠르게 탭하나',
      icon: Icons.touch_app_rounded,
      color: Color(0xFF00CEC9),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'sequence',
      tagline: '순서를 기억하라',
      icon: Icons.psychology_rounded,
      color: Color(0xFFE056FD),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'stroop',
      tagline: '색과 글자의 함정',
      icon: Icons.palette_rounded,
      color: Color(0xFF00B894),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'numberbattle',
      tagline: '1부터 25까지 빠르게',
      icon: Icons.grid_on_rounded,
      color: Color(0xFFFF6B6B),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'mathrace',
      tagline: '사칙연산 스피드',
      icon: Icons.calculate_rounded,
      color: Color(0xFFE74C3C),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'arrowdash',
      tagline: '방향을 빠르게 스와이프',
      icon: Icons.swipe_rounded,
      color: Color(0xFF00B894),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'timing',
      tagline: '정확한 순간에 멈춰라',
      icon: Icons.timer_rounded,
      color: Color(0xFF6C5CE7),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'tictactoe',
      tagline: '3개를 연속으로',
      icon: Icons.grid_3x3_rounded,
      color: Color(0xFF6C5CE7),
      tempo: GameTempo.blitz,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'hunmin',
      tagline: '초성 단어 배틀 3판 2선',
      icon: Icons.translate_rounded,
      color: Color(0xFF1E88E5),
      tempo: GameTempo.word,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'cardflip',
      tagline: '짝 맞추기 기억력 대결',
      icon: Icons.style_rounded,
      color: Color(0xFF8E44AD),
      tempo: GameTempo.brain,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'hexagon',
      tagline: '숫자를 외우고 합을 맞춰라',
      icon: Icons.hexagon_rounded,
      color: Color(0xFF0984E3),
      tempo: GameTempo.brain,
      modes: {PlayMode.solo, PlayMode.duo},
    ),
    GameMeta(
      id: 'pyramid',
      tagline: '카드를 골라 목표 숫자로',
      icon: Icons.change_history_rounded,
      color: Color(0xFFE67E22),
      tempo: GameTempo.brain,
      modes: {PlayMode.solo, PlayMode.duo},
    ),
    GameMeta(
      id: 'infinite_tictactoe',
      tagline: '돌이 사라지는 틱택토',
      icon: Icons.all_inclusive_rounded,
      color: Color(0xFF2D3436),
      tempo: GameTempo.brain,
      modes: {PlayMode.duo},
    ),
    GameMeta(
      id: 'gomoku',
      tagline: '5개를 먼저 연속으로',
      icon: Icons.circle_outlined,
      color: Color(0xFF636E72),
      tempo: GameTempo.strategy,
      modes: {PlayMode.duo},
    ),
  ];

  static final Map<String, GameMeta> _byId = {
    for (final g in all) g.id: g,
  };

  static GameMeta? byId(String id) => _byId[id];

  /// 미등록 게임에도 안전한 색/아이콘 (기록·리스트 등 표시용 단일 출처).
  static Color colorOf(String id) =>
      _byId[id]?.color ?? const Color(0xFF74B9FF);

  static IconData iconOf(String id) =>
      _byId[id]?.icon ?? Icons.sports_esports_rounded;

  /// 해당 모드를 지원하는 게임을, 호흡(빠른→전략) 순서로 반환.
  static List<GameMeta> forMode(PlayMode mode) {
    final list = all.where((g) => g.supports(mode)).toList();
    list.sort((a, b) => a.tempo.index.compareTo(b.tempo.index));
    return list;
  }

  static int countForMode(PlayMode mode) =>
      all.where((g) => g.supports(mode)).length;
}
