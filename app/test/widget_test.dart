import 'package:flutter_test/flutter_test.dart';
import 'package:minigame_app/main.dart';

void main() {
  testWidgets('App starts with login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MinigameApp());
    await tester.pumpAndSettle();

    // 로그인 화면이 나타나는지 확인
    expect(find.text('미니게임 천국'), findsOneWidget);
    expect(find.text('게스트로 시작'), findsOneWidget);
  });
}
