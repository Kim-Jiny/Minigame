import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minigame_app/widgets/cartoon/chunky_button.dart';

void main() {
  testWidgets('expand:false 버튼은 라벨 폭만큼 보인다(다이얼로그 actions 포함)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AlertDialog(
              title: const Text('t'),
              actions: [
                TextButton(onPressed: () {}, child: const Text('취소')),
                ChunkyButton(
                  label: '탈퇴하기',
                  expand: false,
                  height: 44,
                  fontSize: 15,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(ChunkyButton));
    expect(size.width, greaterThan(60));
    expect(size.height, greaterThan(40));
    expect(find.text('탈퇴하기'), findsWidgets);
  });
}
