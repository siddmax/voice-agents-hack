import 'package:flutter_test/flutter_test.dart';

import 'package:syndai/main.dart';

void main() {
  testWidgets('Syndai app boots to scaffold placeholder', (tester) async {
    await tester.pumpWidget(const SyndaiApp());
    expect(find.textContaining('Syndai'), findsOneWidget);
  });
}
