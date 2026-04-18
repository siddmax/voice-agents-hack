import 'package:flutter_test/flutter_test.dart';

import 'package:syndai/main.dart';
import 'chat_screen_test.dart' as chat_tests;

void main() {
  testWidgets('Syndai app boots to chat shell', (tester) async {
    await tester.pumpWidget(SyndaiApp(agentFactory: chat_tests.fakeAgent));
    await tester.pump();
    expect(find.text('Syndai'), findsOneWidget);
  });
}
