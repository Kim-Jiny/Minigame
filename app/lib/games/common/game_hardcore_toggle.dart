import 'package:flutter/material.dart';

/// 진입 화면의 하드코어 모드 토글. 켜지면 붉은 톤 + 선택적 안내 문구.
class GameHardcoreToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  /// '하드코어' 옆 부가 라벨(예: '(10초)'). 없으면 생략.
  final String? durationLabel;

  /// 켜졌을 때 토글 아래에 보여줄 안내(예: '6색 + 2초 제한!').
  final String? activeHint;

  const GameHardcoreToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.durationLabel,
    this.activeHint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: value ? Colors.red.shade50 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: value ? Colors.red.shade300 : Colors.grey.shade300,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.local_fire_department,
                color: value ? Colors.red : Colors.grey,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                '하드코어',
                style: TextStyle(
                  color: value ? Colors.red : Colors.grey.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (durationLabel != null) ...[
                const SizedBox(width: 4),
                Text(
                  durationLabel!,
                  style: TextStyle(
                    fontSize: 12,
                    color: value ? Colors.red.shade400 : Colors.grey,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: Colors.red,
                activeTrackColor: Colors.red.shade200,
              ),
            ],
          ),
        ),
        if (value && activeHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              activeHint!,
              style: TextStyle(
                fontSize: 12,
                color: Colors.red.shade400,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }
}
