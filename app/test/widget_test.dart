import 'package:flutter_test/flutter_test.dart';
import 'package:minigame_app/main.dart';
import 'package:minigame_app/services/remote_config_service.dart';

void main() {
  testWidgets('App starts with login screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      MinigameApp(remoteConfigService: RemoteConfigService()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 로그인 화면이 나타나는지 확인
    expect(find.text('듀오아레나'), findsOneWidget);
    expect(find.text('게임 시작하기'), findsOneWidget);
  });
}
