import 'package:flutter/material.dart';
import '../../theme/candy_theme.dart';
import '../../widgets/cartoon/cartoon_card.dart';
import '../../widgets/cartoon/chunky_button.dart';
import '../../widgets/cartoon/duo_mascot.dart';
import '../../widgets/cartoon/pop_in.dart';

/// 로비 시트에서 "바로 시작"으로 들어왔을 때 라우트 arguments 로 전달되는 값.
/// 첫 번째 [GameIntroView] 가 한 번만 소비하므로, 결과 후 idle 로 돌아와도 자동 재매칭되지 않는다.
class GameLaunchArgs {
  final bool autoStart;
  bool _consumed = false;

  GameLaunchArgs({this.autoStart = false});

  bool takeAutoStart() {
    if (!autoStart || _consumed) return false;
    _consumed = true;
    return true;
  }
}

/// 게임 진입(대기) 화면 공통 위젯.
/// 부드러운 히어로 아이콘 + 제목/설명 + 풀폭 1차 CTA(상대 찾기) + 토널 보조(친구 초대).
/// 게임마다 아이콘·제목·설명만 다르고 배치는 동일하게 통일한다.
class GameIntroView extends StatefulWidget {
  final Gradient backgroundGradient;
  final Color accentColor;

  /// 히어로에 표시할 아이콘. emoji 가 있으면 무시된다.
  final IconData? icon;

  /// 아이콘 대신 이모지(예: 가위바위보)를 쓰고 싶을 때.
  final String? emoji;

  final String title;
  final List<String> descriptions;

  final VoidCallback onFindMatch;

  /// 친구 초대 콜백. null 이면 친구 초대 버튼을 숨긴다.
  final VoidCallback? onInviteFriend;
  final String findMatchLabel;

  /// 버튼 위에 끼워 넣을 추가 위젯(예: 하드코어 토글).
  final Widget? extra;

  const GameIntroView({
    super.key,
    required this.backgroundGradient,
    required this.accentColor,
    this.icon,
    this.emoji,
    required this.title,
    required this.descriptions,
    required this.onFindMatch,
    this.onInviteFriend,
    this.findMatchLabel = '상대 찾기',
    this.extra,
  });

  @override
  State<GameIntroView> createState() => _GameIntroViewState();
}

class _GameIntroViewState extends State<GameIntroView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is GameLaunchArgs && args.takeAutoStart()) {
        widget.onFindMatch();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final backgroundGradient = widget.backgroundGradient;
    final accentColor = widget.accentColor;
    final icon = widget.icon;
    final emoji = widget.emoji;
    final title = widget.title;
    final descriptions = widget.descriptions;
    final onFindMatch = widget.onFindMatch;
    final onInviteFriend = widget.onInviteFriend;
    final findMatchLabel = widget.findMatchLabel;
    final extra = widget.extra;
    return Container(
      decoration: BoxDecoration(gradient: backgroundGradient),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 히어로: 게임 아이콘 카드 + 응원하는 마스코트
                  Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      PopIn(
                        child: CartoonCard(
                          color: Colors.white,
                          radius: 30,
                          padding: EdgeInsets.zero,
                          child: SizedBox(
                            width: 104,
                            height: 104,
                            child: Center(
                              child: emoji != null
                                  ? Text(
                                      emoji,
                                      style: const TextStyle(fontSize: 48),
                                    )
                                  : Icon(icon, size: 52, color: accentColor),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: -62,
                        bottom: -10,
                        child: PopIn(
                          delay: const Duration(milliseconds: 250),
                          child: DuoMascot(
                            size: 64,
                            color: accentColor,
                            mood: MascotMood.happy,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 26),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: CandyColors.ink,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final d in descriptions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        d,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          fontWeight: FontWeight.w700,
                          color: CandyColors.inkSoft,
                        ),
                      ),
                    ),
                  if (extra != null) ...[const SizedBox(height: 24), extra],
                  const SizedBox(height: 36),
                  // 1차 CTA — 상대 찾기 (풀폭)
                  ChunkyButton(
                    label: findMatchLabel,
                    icon: Icons.search_rounded,
                    color: accentColor,
                    onPressed: onFindMatch,
                  ),
                  if (onInviteFriend != null) ...[
                    const SizedBox(height: 10),
                    ChunkyButton(
                      label: '친구 초대',
                      icon: Icons.person_add_rounded,
                      color: Colors.white,
                      textColor: accentColor,
                      height: 50,
                      fontSize: 16,
                      onPressed: onInviteFriend,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
