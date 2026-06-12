import 'package:flutter/material.dart';
import 'game_catalog.dart';

/// 게임 진입 맥락이자 메인 랜딩의 2개 진입점.
/// 혼자 연습(solo)으로 들어오면 랭킹 도전/보기,
/// 온라인 대결(versus)로 들어오면 대전/친구 초대(+인원 선택)만 노출한다.
/// 인원 수(2·3·4)는 versus 안의 옵션이지 별도 진입점이 아니다.
enum GameEntryMode {
  versus(
    title: '온라인 대결',
    tagline: '실시간으로 겨루기',
    icon: Icons.people_alt_rounded,
    color: Color(0xFF6C5CE7),
  ),
  solo(
    title: '혼자 연습',
    tagline: '연습하며 기록에 도전',
    icon: Icons.self_improvement_rounded,
    color: Color(0xFF0EA5A6),
  );

  const GameEntryMode({
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
///
/// 지원 인원은 두 축으로 선언한다:
///  - [solo]   : 혼자 연습(랭킹 도전) 지원 여부
///  - [versus] : 온라인 대결에서 지원하는 인원 수 집합(예: {2}, {2,3,4}).
///               비어 있으면 대결 미지원. 길이가 2 이상이면 진입 시 인원 칩을 노출한다.
class GameMeta {
  final String id;
  final String tagline;
  final IconData icon;
  final Color color;
  final GameTempo tempo;
  final bool solo;
  final Set<int> versus;

  const GameMeta({
    required this.id,
    required this.tagline,
    required this.icon,
    required this.color,
    required this.tempo,
    this.solo = false,
    this.versus = const {},
  });

  String get name => GameCatalog.nameFor(id);
  String get route => GameCatalog.routeFor(id);

  /// 온라인 대결 지원 여부.
  bool get hasVersus => versus.isNotEmpty;

  /// 해당 진입 맥락을 지원하는가.
  bool supports(GameEntryMode entry) =>
      entry == GameEntryMode.solo ? solo : hasVersus;
}

/// 전체 게임 메타데이터의 단일 출처.
class GameRegistry {
  const GameRegistry._();

  // 현재 모든 대결 게임은 2인(versus: {2}). 특정 게임을 3·4인으로 열 때
  // 그 게임의 versus 집합에 인원을 추가하면 진입 화면에 인원 칩이 노출된다.
  // solo: true 인 게임만 '혼자 연습' 그리드에 등장한다.
  static const List<GameMeta> all = [
    GameMeta(
      id: 'reaction',
      tagline: '터치 반응속도 대결',
      icon: Icons.flash_on_rounded,
      color: Color(0xFFE17055),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'rps',
      tagline: '가위바위보 3판 2선',
      icon: Icons.front_hand_rounded,
      color: Color(0xFF9B59B6),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'speedtap',
      tagline: '누가 더 빠르게 탭하나',
      icon: Icons.touch_app_rounded,
      color: Color(0xFF00CEC9),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'sequence',
      tagline: '순서를 기억하라',
      icon: Icons.psychology_rounded,
      color: Color(0xFFE056FD),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'stroop',
      tagline: '색과 글자의 함정',
      icon: Icons.palette_rounded,
      color: Color(0xFF00B894),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'numberbattle',
      tagline: '1부터 25까지 빠르게',
      icon: Icons.grid_on_rounded,
      color: Color(0xFFFF6B6B),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'mathrace',
      tagline: '사칙연산 스피드',
      icon: Icons.calculate_rounded,
      color: Color(0xFFE74C3C),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'arrowdash',
      tagline: '방향을 빠르게 스와이프',
      icon: Icons.swipe_rounded,
      color: Color(0xFF00B894),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'timing',
      tagline: '정확한 순간에 멈춰라',
      icon: Icons.timer_rounded,
      color: Color(0xFF6C5CE7),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'tictactoe',
      tagline: '3개를 연속으로',
      icon: Icons.grid_3x3_rounded,
      color: Color(0xFF6C5CE7),
      tempo: GameTempo.blitz,
      versus: {2},
    ),
    GameMeta(
      id: 'set',
      tagline: '같거나 모두 다른 3장 찾기',
      icon: Icons.style_rounded,
      color: Color(0xFF00897B),
      tempo: GameTempo.brain,
      solo: true,
      versus: {2, 3, 4},
    ),
    GameMeta(
      id: 'hunmin',
      tagline: '초성 단어 배틀 3판 2선',
      icon: Icons.translate_rounded,
      color: Color(0xFF1E88E5),
      tempo: GameTempo.word,
      versus: {2},
    ),
    GameMeta(
      id: 'cardflip',
      tagline: '짝 맞추기 기억력 대결',
      icon: Icons.style_rounded,
      color: Color(0xFF8E44AD),
      tempo: GameTempo.brain,
      versus: {2},
    ),
    GameMeta(
      id: 'hexagon',
      tagline: '숫자를 외우고 합을 맞춰라',
      icon: Icons.hexagon_rounded,
      color: Color(0xFF0984E3),
      tempo: GameTempo.brain,
      solo: true,
      versus: {2},
    ),
    GameMeta(
      id: 'pyramid',
      tagline: '카드를 골라 목표 숫자로',
      icon: Icons.change_history_rounded,
      color: Color(0xFFE67E22),
      tempo: GameTempo.brain,
      solo: true,
      versus: {2},
    ),
    GameMeta(
      id: 'infinite_tictactoe',
      tagline: '돌이 사라지는 틱택토',
      icon: Icons.all_inclusive_rounded,
      color: Color(0xFF2D3436),
      tempo: GameTempo.brain,
      versus: {2},
    ),
    GameMeta(
      id: 'gomoku',
      tagline: '5개를 먼저 연속으로',
      icon: Icons.circle_outlined,
      color: Color(0xFF636E72),
      tempo: GameTempo.strategy,
      versus: {2},
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

  /// 해당 진입 맥락(연습/대결)을 지원하는 게임을, 호흡(빠른→전략) 순서로 반환.
  static List<GameMeta> forEntry(GameEntryMode entry) {
    final list = all.where((g) => g.supports(entry)).toList();
    list.sort((a, b) => a.tempo.index.compareTo(b.tempo.index));
    return list;
  }

  static int countForEntry(GameEntryMode entry) =>
      all.where((g) => g.supports(entry)).length;
}
