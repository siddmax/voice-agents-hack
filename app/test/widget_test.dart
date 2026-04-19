import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:syndai/main.dart';
import 'package:syndai/ui/jarvis_screen.dart';
import 'jarvis_screen_test.dart' as jarvis_tests;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.resetPhysicalSize();
    binding.platformDispatcher.views.first.resetDevicePixelRatio();
  });

  testWidgets('Syndai app boots to Jarvis screen', (tester) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(SyndaiApp(agentFactory: jarvis_tests.fakeAgent));
    await tester.pump();
    expect(find.byType(JarvisScreen), findsOneWidget);
  });
}
