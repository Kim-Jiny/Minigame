import 'package:flutter/material.dart';
import 'cartoon/title_icon_art.dart';
import '../models/shop_item.dart';
import 'cartoon/avatar_art.dart';
import 'cartoon/pet_mascot.dart';
import '../theme/candy_theme.dart';

class GamePlayerProfile extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final bool isActive;
  final bool isMe;
  final UserProfileSettings? profileSettings;
  final Color activeColor;
  final Widget? extraWidget; // 말 개수 등 추가 위젯

  const GamePlayerProfile({
    super.key,
    required this.name,
    this.avatarUrl,
    required this.isActive,
    required this.isMe,
    this.profileSettings,
    this.activeColor = const Color(0xFFFF6B9D),
    this.extraWidget,
  });

  @override
  Widget build(BuildContext context) {
    // 프레임 스타일 (nested 또는 flat 구조 모두 지원)
    Color? frameColor;
    Color? glowColor;
    bool isRainbow = false;

    if (profileSettings != null) {
      // getFrameColors()가 flat/nested 모두 처리
      final frameColors = profileSettings!.getFrameColors();
      if (frameColors != null) {
        frameColor = frameColors.$1;
        glowColor = frameColors.$2;
      }
      // Rainbow 체크 (nested 또는 flat)
      if (profileSettings!.activeFrame != null) {
        isRainbow = profileSettings!.activeFrame!.isRainbow;
      } else if (profileSettings!.activeFramePreviewData != null) {
        isRainbow = profileSettings!.activeFramePreviewData!['borderColor'] == 'rainbow';
      }
    }

    // 칭호 정보 (nested 또는 flat 구조 모두 지원)
    String? titleText;
    String? titleIcon;
    List<Color>? titleGradientColors;

    if (profileSettings != null) {
      // nested 구조
      if (profileSettings!.activeTitle != null) {
        final title = profileSettings!.activeTitle!;
        titleText = title.name;
        titleIcon = title.titleIcon;
        titleGradientColors = title.titleGradient;
      }
      // flat 구조
      else if (profileSettings!.activeTitleName != null) {
        titleText = profileSettings!.activeTitleName;
        titleIcon = profileSettings!.activeTitlePreviewData?['icon'];
        final gradient = profileSettings!.getTitleGradient();
        if (gradient != null) {
          titleGradientColors = [gradient.$1, gradient.$2];
        }
      }
    }

    return Column(
      children: [
        // 프레임이 적용된 아바타
        _withPet(_buildFramedAvatar(frameColor, glowColor, isRainbow)),
        const SizedBox(height: 4),
        // 닉네임
        Text(
          name,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: isActive ? activeColor : const Color(0xFF3A2D5C),
          ),
          overflow: TextOverflow.ellipsis,
        ),
        // 칭호
        if (titleText != null)
          _buildTitleWidget(titleText, titleIcon, titleGradientColors),
        // 추가 위젯 (말 개수 등)
        if (extraWidget != null) extraWidget!,
      ],
    );
  }

  /// 아바타 모서리에 걸쳐 펫처럼 따라다니는 마스코트. 내 쪽은 오른쪽, 상대 쪽은 왼쪽(화면 안쪽)에 둔다.
  Widget _withPet(Widget avatar) {
    final mascot = profileSettings?.getMascotInfo();
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        avatar,
        Positioned(
          right: isMe ? -18 : null,
          left: isMe ? null : -18,
          bottom: -6,
          child: PetMascot(
            size: 34,
            color: mascot?.$1 ?? CandyColors.pink,
            accessory: mascot?.$2,
            active: isActive,
            // 내 쪽(왼쪽 프로필)은 왼쪽을, 상대 쪽은 오른쪽을 향하게 해서 마주 보는 느낌.
            faceLeft: !isMe,
          ),
        ),
      ],
    );
  }

  Widget _buildFramedAvatar(Color? frameColor, Color? glowColor, bool isRainbow) {
    // 아바타 정보 가져오기
    final avatarArt = profileSettings?.getAvatarArt();

    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: (glowColor ?? activeColor).withValues(alpha: 0.4),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isRainbow
              ? const SweepGradient(
                  colors: [
                    Colors.red,
                    Colors.orange,
                    Colors.yellow,
                    Colors.green,
                    Colors.blue,
                    Colors.purple,
                    Colors.red,
                  ],
                )
              : null,
          border: !isRainbow
              ? Border.all(
                  color: frameColor ?? (isActive ? activeColor : Colors.grey.shade300),
                  width: isActive ? 3 : 2,
                )
              : null,
        ),
        child: avatarArt != null
            ? AvatarArt(
                itemKey: avatarArt.key,
                emoji: avatarArt.emoji,
                bgColor: avatarArt.bg,
                size: 48,
                outline: false,
              )
            : CircleAvatar(
                radius: 24,
                backgroundColor: isMe ? activeColor.withValues(alpha: 0.2) : Colors.grey.shade200,
                child: Icon(
                  Icons.person,
                  size: 24,
                  color: isMe ? activeColor : Colors.grey,
                ),
              ),
      ),
    );
  }

  Widget _buildTitleWidget(String title, String? icon, List<Color>? gradient) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            TitleIconArt(icon: icon, size: 13),
            const SizedBox(width: 2),
          ],
          Flexible(
            child: ShaderMask(
              shaderCallback: (bounds) {
                if (gradient != null && gradient.length >= 2) {
                  return LinearGradient(colors: gradient).createShader(bounds);
                }
                return LinearGradient(colors: [Colors.grey, Colors.grey]).createShader(bounds);
              },
              child: Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
