import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:syndai/main.dart';
import 'package:syndai/ui/jarvis_screen.dart';
import 'jarvis_screen_test.dart' as jarvis_tests;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Syndai app boots to Jarvis screen', (tester) async {
    await tester.pumpWidget(SyndaiApp(agentFactory: jarvis_tests.fakeAgent));
    await tester.pump();
    expect(find.byType(JarvisScreen), findsOneWidget);
  });
}
